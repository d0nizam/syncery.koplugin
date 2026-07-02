-- main.lua
-- =============================================================================
-- Syncery — plugin entry point and runtime orchestrator
-- =============================================================================
--
-- WHAT THIS FILE IS
--
-- The subsystems live in their own packages — `syncery_ann/`
-- (annotations), `syncery_progress/` (progress + merge),
-- `syncery_transports/` (the sync transports), `syncery_lifecycle/`
-- (event router + timers), `syncery_ui/` (menu, status, booklist,
-- trash).  What stays here is the part that ties them together:
-- `main.lua` is the KOReader `WidgetContainer`, the event sink, and
-- the runtime *orchestrator* that drives those subsystems.  It is long
-- because orchestrating this many parts is genuinely a lot of glue —
-- not because a subsystem is hiding in here.
--
-- This file is a set of methods on the `Syncery` object.  The map
-- below names the concern-clusters so "where does responsibility X
-- live?" has an answer better than "grep main.lua".  It deliberately
-- names representative ENTRY-POINT methods rather than line numbers —
-- line numbers drift on every edit; method names do not.
--
-- METHOD-CLUSTER MAP
--
--   Bootstrap & config
--     init, maybeShowFirstRunDialog, _loadFirstrunFlag,
--     _rebuildExtensionCache, onDispatcherRegisterActions,
--     addToMainMenu, deletePluginSettings
--
--   Storage-mode migration  (run-once-per-mode-change; cold path)
--     setStorageMode, _migrateAllBooks,
--     _migrateBookFiles, migrateSingleBook
--       NOTE: the file-move helpers here move files across
--       directories via Util.move_file — os.rename with a
--       copy-then-delete fallback for the Android FUSE/SAF
--       cross-volume case.
--       A failed move is still safe (source intact, that file
--       skipped).
--
--   Document state & the Jump feature
--     onReaderReady, getCurrentState, getBookTitle, _doJump,
--     _promptJump, _undoLastJump
--       When jump_mode is "ask", _promptJump raises a non-blocking invite
--       through the notification coordinator (syncery_ui/notify.lua +
--       toast_widget.lua); the short message text comes from
--       syncery_ui/jump_toast.lua. "See all positions" lives in the status
--       panel (syncery_ui/status_ui/init.lua:showJumpDialog), not on the toast.
--
--   Save pipeline
--     _writeSave, _save, _autoSave, doSave,
--     _debouncedScan, _doTriggerScan, scheduleAutoSave,
--     _syncBookViaOrchestrator
--
--   Annotation sync  (KOReader highlight/note/bookmark)
--     onAnnotationsModified, onToggleBookmark — thin delegators that
--     trigger a save; the syncery_ann/ orchestrator owns the merge,
--     conflict resolution, and tombstone lifecycle.
--       _syncBookViaOrchestrator is the single call into the engine.
--
--   Transport sync triggers
--     syncNow, checkRemote, _setupKOSyncthingPlusIntegration,
--     _configureKOSyncthingPlusConflicts.
--       _scheduleCloudUpload /
--       _doCloudUpload are one-line delegators into
--       syncery_transports/plugin_sync.
--
--   Maintenance / GC
--     _cleanupOrphans, _rescanAllFolders,
--     _resetAll, _deleteAllAnnotationsForCurrentBook
--
--   Status surface  (thin — most logic now lives in syncery_ui/)
--     showSyncStatus    → delegates to syncery_ui/status_ui/init.lua
--     _showActivityLog, _logActivity
--
--   Lifecycle event forwarders  (one-liners → syncery_lifecycle/)
--     onCloseDocument, onSuspend, onResume, onPowerOff, onQuit,
--     onPageUpdate, onPosUpdate, onFlushSettings
--
-- WHAT IS DELIBERATELY *NOT* HERE
--
--   The merge model, the transport contract, the menu construction,
--   the timer machinery — all extracted, all tested in their own
--   packages.  Do not pull logic back into main.lua; do not add a new
--   subsystem here.  New cross-subsystem glue is the only thing that
--   belongs in this file.
--
-- =============================================================================
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local Device          = require("device")
local InfoMessage     = require("ui/widget/infomessage")
local ConfirmBox      = require("ui/widget/confirmbox")
local InputDialog     = require("ui/widget/inputdialog")
local Event           = require("ui/event")
local Dispatcher      = require("dispatcher")
local logger          = require("logger")
local json 			  = require("rapidjson")
local Trapper 		  = require("ui/trapper")

local BookList 	  = require("syncery_ui/booklist/init")
local I18n        = require("syncery_i18n")
local Util        = require("syncery_util")
local sanitize_for_lua = Util.sanitize_for_lua

-- Transport layer.  The bridge is the single entry point
-- main.lua uses for all push paths; the orchestrator handles retries,
-- debouncing, and per-(transport, book) state internally.  The
-- Transports.build factory wires the production stack (Syncthing +
-- Cloud) and returns a ready-to-use bridge.  See
-- syncery_transports/README.md for the full architecture.
local Transports = require("syncery_transports/init")
local Stignore   = require("syncery_transports/stignore")
local Settings   = require("syncery_settings")
local DbSync     = require("syncery_db_sync")
local ConfigUnify = require("syncery_db_sync_unify")   -- Tier 2 unified-config decision core
local DataStorage = require("datastorage")             -- Tier 2: derive the plugins' `.sync` paths
local PluginSync = require("syncery_transports/plugin_sync")
local CloudStorageProvider = require("syncery_transports/cloud/providers/cloudstorage_provider")

-- ----------------------------------------------------------------------------
-- Periodic DB-sync timer (Statistics / Vocabulary Builder), opt-in via the
-- DB-sync master toggle.  MODULE-LEVEL (not an instance method) so the schedule
-- survives FileManager<->Reader navigation: PluginLoader dofile's main.lua once,
-- so this state outlives the plugin instances that come and go as you move
-- between the reader and the file manager.  Modelled on the core AutoStandby
-- plugin (timer state on the module, not the instance) -- the established
-- KOReader idiom for a background task that must persist across navigation.
-- Both sibling plugins load in either UI (not is_doc_only) and their cloud sync
-- is whole-DB (book-independent), so the tick works in the reader AND the file
-- manager -- the point of this design: DB sync no longer needs a book open, only
-- KOReader running.  (Genuinely impossible only when KOReader is fully quit /
-- the device is suspended -- Syncery has no background daemon; the sync runs
-- inside KOReader's event loop.)  Not unit-loadable (needs the UI) -> device-
-- validated.
local _db_sync_armed = false   -- is the module tick currently scheduled?
-- The last actionable DB-sync issue surfaced this session (a stable signature
-- string), so the periodic tick toasts a persistent issue ONCE, not every
-- interval.  nil = nothing outstanding.  Module-level (shared across the reader
-- and file-manager instances) so navigation doesn't reset the de-dupe.
local _db_sync_last_surfaced = nil
local _db_sync_tick            -- forward declaration (self-rescheduling)
-- Dispatch a sibling plugin's declared sync action by Event name.  Uses
-- broadcastEvent, NOT sendEvent: sendEvent only reaches the topmost non-toast
-- widget, so a trigger from Syncery's own menu ("Sync now") or a background tick
-- with any modal on top would miss the plugin entirely.  broadcastEvent reaches
-- ALL window-level widgets (the plugin is a registerModule child of ReaderUI /
-- FileManager, so ReaderUI:handleEvent propagates the event down to it),
-- regardless of what is on top.  Used as DbSync.run's `send_event` dep.
local function _dbSyncSendEvent(name)
    UIManager:broadcastEvent(Event:new(name))
end

_db_sync_tick = function()
    -- The tick has no instance, so resolve the LIVE active UI at fire time:
    -- ReaderUI.instance in the reader, FileManager.instance in the file manager.
    -- During a brief FM<->Reader transition both can be nil -> skip this tick and
    -- re-arm (the next one resolves the settled UI).  Read via package.loaded to
    -- avoid a circular require (both modules load long before any tick fires).
    local RUI = package.loaded["apps/reader/readerui"]
    local FM  = package.loaded["apps/filemanager/filemanager"]
    local active_ui = (RUI and RUI.instance) or (FM and FM.instance)
    if active_ui and Settings.get_db_sync_enabled() then
        -- Gate on cloud reachability (a NON-BLOCKING cached verdict).  The
        -- plugins' DB sync (ReaderStatistics / VocabBuilder -> cloudstorage:sync)
        -- ALSO runs SYNCHRONOUSLY on the UI thread, so a no-internet tick would
        -- freeze the UI exactly like a cloud upload.  Reuse the cloud-upload gate
        -- on the live Syncery instance (isConnected link pre-gate + verdict); it
        -- targets Syncery's server as an internet-up PROXY -- a different plugins'
        -- server that's down is still a bounded socketutil hang, not the
        -- catastrophic no-route freeze.  Absent instance / method -> don't gate
        -- (fail open).  When gated out we skip the run but still re-arm below, so
        -- the next interval retries.
        local inst = active_ui.syncery
        local reachable = (not inst)
            or type(inst._isCloudReachable) ~= "function"
            or inst:_isCloudReachable()
        if reachable then
            xpcall(function()
                if inst and type(inst._unifyDbSyncConfig) == "function" then
                    inst:_unifyDbSyncConfig()                  -- Tier 2: assert unified config first
                end
                local report = DbSync.run({ ui = active_ui, settings = Settings, gset = G_reader_settings, send_event = _dbSyncSendEvent })
                if inst and type(inst._surfaceDbSyncReport) == "function" then
                    inst:_surfaceDbSyncReport(report, false)   -- de-duped (periodic)
                end
            end, function(e) logger.warn("Syncery DB-sync tick failed:", e) end)
        end
    end
    -- Re-arm while enabled; otherwise drop the schedule so a later toggle-on
    -- (menu, or the next init) can restart it.
    if Settings.get_db_sync_enabled() then
        UIManager:scheduleIn(Settings.get_db_sync_interval_min() * 60, _db_sync_tick)
    else
        _db_sync_armed = false
    end
end

-- Arm the module timer at most once.  init() calls this on EVERY plugin instance
-- (reader and file manager), but a tick already running is left untouched -> the
-- interval is never reset by navigation and never double-scheduled.
local function _armDbSyncTimer()
    if _db_sync_armed then return end
    if not Settings.get_db_sync_enabled() then return end
    _db_sync_armed = true
    UIManager:scheduleIn(Settings.get_db_sync_interval_min() * 60, _db_sync_tick)
end

-- Stop the module timer immediately: drop any pending tick and clear the armed
-- flag so a later arm (master toggle on, interval change, or next init) starts a
-- fresh schedule.  Safe when nothing is scheduled (unschedule is a no-op).
local function _disarmDbSyncTimer()
    UIManager:unschedule(_db_sync_tick)
    _db_sync_armed = false
end
local SyncthingProviders   = require("syncery_transports/syncthing/providers/init")
local StorageMigration  = require("syncery_migration/storage_mode")
local StorageMode       = require("syncery_storage_mode")

local MenuBuilder = require("syncery_ui/menu/init")
local StatusUI    = require("syncery_ui/status_ui/init")
local Wizard          = require("syncery_ui/wizard")
local WizardPresenter = require("syncery_ui/wizard_presenter")
local JumpToast       = require("syncery_ui/jump_toast")
local ActionBar       = require("syncery_ui/action_bar")
local JumpPolicy      = require("syncery_ui/jump_policy")
local Notify          = require("syncery_ui/notify")
local ToastWidget     = require("syncery_ui/toast_widget")
local WizardWindow    = require("syncery_ui/wizard_window")

-- Position the Syncery entry in the reader Tools tab (next to Cloud
-- storage) rather than at the bottom of the list. Guarded so a KOReader
-- build without these order tables can't break plugin load.
pcall(require, "insert_menu")

-- Annotation-sync engine.  The
-- orchestrator drives 3-way merge, conflict resolution, and per-section
-- persistence — it is the ONLY annotation path.  AnnPaths needs to be
-- told the current storage mode (sdr | hash) at init and on every change.
local Orchestrator = require("syncery_ann/sync_orchestrator")
local AnnPaths     = require("syncery_ann/paths")
local MtimeGate    = require("syncery_ann/mtime_gate")
local AnnStateStore = require("syncery_ann/state_store")
local AnnTimeFormat = require("syncery_ann/time_format")
local AnnDocSettingsBridge = require("syncery_ann/doc_settings_bridge")

-- Progress-sync engine.  Same shape as the annotation
-- subsystem: a top-level orchestrator that owns the full save flow
-- (conflict resolution → 3-way merge → atomic persist), plus pure
-- helpers for the cases where main.lua just needs to read the file
-- or pick a "best" entry for the UI.
--
-- WHY FIVE MODULES (not one namespace): responsibilities are split
-- deliberately, so no single symbol does path-resolution, merging,
-- and destructive pruning all at once:
--
--   ProgressOrchestrator      — the only place sync actually happens.
--   ProgressPaths             — where files live on disk; storage mode.
--   ProgressStateStore        — load/save with shape validation.
--   ProgressConflictResolver  — handles `*.sync-conflict-*` files.
--   ProgressBridge            — KOReader's live state → entry; view-only
--                               freshness filter (NEVER deletes from disk).
--
-- If you find yourself reaching for a function that doesn't seem to
-- exist on any of these, that's the design — go read the SKILL.md-
-- style header comments at the top of each module.  Bridge is the
-- only path from the orchestrator's "save" phase back to KOReader
-- state, and it has no API for "delete this device's entry" —
-- intentional: a delete can be undone by Syncthing re-syncing the
-- entry from a device that hasn't checked in lately, so the shared
-- file keeps every entry and the UI filters stale ones at view time.
local ProgressOrchestrator     = require("syncery_progress/sync_orchestrator")
local ProgressPaths            = require("syncery_progress/paths")
local ScanTarget               = require("syncery_progress/scan_target")
local ProgressStateStore       = require("syncery_progress/state_store")
local ProgressConflictResolver = require("syncery_progress/conflict_resolver")
local ProgressBridge           = require("syncery_progress/progress_bridge")

-- The per-book sync journal: a device-local, append-only, bounded
-- record of annotation-merge events.  `_syncBookViaOrchestrator`
-- feeds each merge result in, so "my annotation disappeared" becomes
-- diagnosable.  Device-local (never synced) and Android-safe by
-- construction (append mode, no os.rename) — see the module header.
local SyncJournal              = require("syncery_progress/sync_journal")

-- Lifecycle / event-router scaffolding.  Owns the debounced
-- timer slots, the central `_flushPersistedState` sequence, and the
-- KOReader event-handler delegators (onCloseDocument, onSuspend,
-- onResume, onPowerOff, onQuit, onFlushSettings).  Constructed once in
-- Syncery:init and held as `self._lifecycle`; the per-method
-- delegators on the plugin (`_schedule`, `_cancelAllTimers`,
-- `_flushPersistedState`, `scheduleAutoSave`, `on*`) all route here.
local Lifecycle = require("syncery_lifecycle/init")

-- WiFi exponential-backoff retry scheduling.  On a WiFi drop the
-- offline-sync paths schedule a retry with exponential backoff
-- (3s → 6s → … capped, absolute timeout) instead of just waiting for
-- the next reader-ready event to coincide with WiFi returning.  A
-- lifecycle/scheduling concern, not a transport one.  Constructed once
-- in init with an injected scheduler (UIManager) — see the module header.
local WifiBackoff = require("syncery_lifecycle/wifi_backoff")
-- Pure, dependency-injected "is the cloud server reachable now?" check.  Wired
-- into the cloud-upload gate so an enabled-but-unreachable cloud DEFERS (via the
-- backoff) instead of dispatching a UI-freezing synchronous WebDAV transfer.
local CloudReachability = require("syncery_transports/cloud/cloud_reachability")

local _  = I18n.translate
local _n = I18n.ngettext

-- ============================================================================
-- Jump-prompt policy lives in `syncery_ui/jump_policy.lua`
--
-- The "is a remote position different enough to interrupt the read with
-- a jump prompt?" decision — and its thresholds (PERCENT_EPSILON /
-- SYNC_TRIGGER_DELTA) — are a pure, unit-tested function
-- (`JumpPolicy.should_prompt`).  It is UI policy, deliberately kept OUT
-- of the `syncery_progress/` data engine: "where the data is" and "the
-- human-attention threshold" are separate concerns.
-- ============================================================================

-- ============================================================================
-- JSON & Data Helpers
-- ============================================================================

local function restore_geoms(val)
    if type(val) == "table" then
        if val.x and val.y and val.w and val.h then
            local Geom = require("ui/geometry")
            return Geom:new{ x = val.x, y = val.y, w = val.w, h = val.h }
        else
            local res = {}
            for k, v in pairs(val) do
                res[k] = restore_geoms(v)
            end
            return res
        end
    end
    return val
end

-- is_cre: true for EPUB/rolling docs (CRE engine), false for paging docs.
-- CRE: every bookmark MUST carry a string xpointer; page alone is not safe because
-- credocument.lua:getPageFromXPointer() is called on every page turn and crashes on
-- nil/non-string input.
local function sanitize_bookmarks(bkmks, is_cre)
    local clean = {}
    for __, b in ipairs(bkmks or {}) do
        local xp_ok = (type(b.xpointer) == "string" and b.xpointer ~= "")
        if is_cre then
            if xp_ok then table.insert(clean, b) end
        else
            if xp_ok or b.page then table.insert(clean, b) end
        end
    end
    return clean
end

-- ============================================================================
-- Logging & Caching Helpers
-- ============================================================================

local _activity_log = {}
-- The activity-log cap. A module-level upvalue (the log functions are
-- free functions, not plugin methods), applied at init via
-- `set_activity_log_max` below. Defaults to 20; no menu row, so a saved
-- `syncery_activity_log_max` is the only override.
local ACTIVITY_LOG_MAX = 20
local ACTIVITY_LOG_FILE = "syncery_activity.json"

local function set_activity_log_max(n)
    if type(n) == "number" and n >= 10 and n <= 100 then
        ACTIVITY_LOG_MAX = n
        while #_activity_log > ACTIVITY_LOG_MAX do
            table.remove(_activity_log)
        end
    end
end

local function save_activity_log()
    local path = Util.state_dir() .. ACTIVITY_LOG_FILE
    local ok, encoded = pcall(json.encode, _activity_log, { pretty = true })
    if not ok then return end
    local f = io.open(path, "w")
    if f then f:write(encoded); f:close() end
end

local function load_activity_log()
    local path = Util.state_dir() .. ACTIVITY_LOG_FILE
    local f = io.open(path, "r")
    if not f then return end
    local raw = f:read("*a"); f:close()
    local ok, data = pcall(json.decode, raw)
    if ok and type(data) == "table" then
        _activity_log = data
        while #_activity_log > ACTIVITY_LOG_MAX do
            table.remove(_activity_log)
        end
    end
end

local function log_activity(kind, detail)
    table.insert(_activity_log, 1, {
        time = os.time(),
        kind = kind,
        detail = detail or ""
    })
    if #_activity_log > ACTIVITY_LOG_MAX then
        table.remove(_activity_log)
    end
    save_activity_log()
end

local _ann_count_cache = {}

local function _syncthing_plugin_path()
    local lfs = Util.get_lfs()
    if not lfs then return nil end

    local ok_ds, DataStorage = pcall(require, "datastorage")
    local bases = {}
    if ok_ds and DataStorage then
        table.insert(bases, DataStorage:getFullDataDir() .. "/plugins")
    end
    local this_dir = (debug.getinfo(1, "S").source:match("@?(.*[/\\])") or "./")
    table.insert(bases, this_dir .. "..")

    for __, base in ipairs(bases) do
        local sep = (base:sub(-1) == "/" or base:sub(-1) == "\\") and "" or "/"
        -- Check both plugin names
        for __, name in ipairs({"kosyncthing_plus.koplugin", "syncthing.koplugin"}) do
            local candidate = base .. sep .. name
            if lfs.attributes(candidate, "mode") == "directory" then
                return candidate
            end
        end
    end
    return nil
end

-- ============================================================================
-- Plugin Class Definition
-- ============================================================================

local _firstrun_done = false
local DEFAULT_SYNC_EXTENSIONS = "*"

-- Reload-handoff slot: the identity of a position-jump bar still showing
-- when the user tapped [Reload]. MODULE-LEVEL on purpose — reloadDocument()
-- recreates the plugin instance (a `self` field would be lost) and its
-- reopen re-stamps our progress recency (so the reopened checkRemote would
-- rank US most-recent and drop the still-valid jump); a module-level local
-- survives the reopen. Single { file, device_id } slot, file-matched on
-- read so a lingering slot can't fire for the wrong book. Do NOT move onto
-- `self`.
local _pending_jump_handoff = nil

local Syncery = WidgetContainer:extend{
    name                     = "syncery",
    -- false: the menu loads in the file browser too, not only while
    -- reading. Per-book rows gray out there via their `has_doc`
    -- enabled_func (FileManager has no `doc_settings`); global rows stay
    -- usable. Document-touching code is event-driven or guarded, so
    -- loading in both contexts is safe.
    is_doc_only              = false,
    -- Debounce window (s) for folding a burst of annotation edits into ONE
    -- coalesced save. A fixed constant, deliberately NOT min_save_interval:
    -- that progress-save floor a user may raise for battery must not
    -- silently defer annotations.
    autosave_delay           = 3,
    min_save_interval        = 5,
    save_now_cooldown        = 3,
    -- Set-once tuning defaults (no menu rows); a previously-saved value
    -- still overrides these at init (below).
    journal_max_entries      = 300,
    activity_log_max         = 20,
    progress_freshness_days  = 90,
    sync_state               = "idle",
    device_id                = nil,
    device_label             = nil,
    is_saving                = false,
    last_save_time           = 0,
    last_manual_save         = 0,
    destroyed                = false,
    last_sync_diagnosis      = nil,
    sync_failure_toast_shown = false,

    -- No eager class default for sync_progress / sync_annotations: they are
    -- consent-first (default OFF), set from settings in init().  The annotation
    -- sub-toggles below stay ON — gated behind the sync_annotations master.
    sync_highlights       = true,
    sync_notes            = true,
    sync_bookmarks        = true,
    use_syncthing         = false,
    use_cloud             = false,
    jump_mode             = "ask",  -- "auto" | "ask" | "never": how a newer remote position is received
    adapt_highlight_style = false,
    sync_extensions       = DEFAULT_SYNC_EXTENSIONS,

    sync_metadata         = true,
    sync_status           = true,
    sync_rating           = true,
    sync_collections      = true,
    -- New optional book-level metadata sync, both default OFF — these
    -- cover edge cases (user-overridden titles, hand-built TOCs) that
    -- most users don't need, and turning them on is a deliberate choice.
    sync_custom_metadata  = false,
    sync_handmade_toc     = false,

    -- Whole-book user note ("summary").  Default OFF — the engine
    -- supports it but users have to opt in.
    sync_summary          = false,
    -- Per-book render settings.  Master defaults OFF; even when on, each
    -- field is its own opt-in sub-toggle (also OFF) — render settings are
    -- device-specific, so the user picks exactly which fields travel.
    sync_render_settings  = false,
    sync_font_face        = false,
    sync_font_size        = false,
    sync_line_spacing     = false,
    sync_font_weight      = false,
    sync_margins          = false,

    storage_mode      = "sdr",
    _active_sync_box  = nil,
    -- Autosave-block state, two independent mechanisms ORed by
    -- _isAutosaveBlocked():
    --   blocking_autosave       — INDEFINITE; held until explicitly cleared
    --     (cancelPendingSync's destructive reset must outlast any timer).
    --   blocking_autosave_until — SELF-HEALING window (epoch second) that
    --     lapses on its own, so post-jump suppression survives a skipped
    --     recovery save.
    blocking_autosave = false,
    blocking_autosave_until = 0,
    pre_jump_page     = nil,
    pre_jump_xpath    = nil,
    pre_jump_until    = 0,
    _ann_mtime_cache  = 0,

    -- Cloud auxiliary transport.  Runs alongside Syncthing rather than
    -- instead of it (cloud ⇒ a fallback for users without Syncthing).
    -- Both can be enabled at once; the data layer is single-source-of-
    -- truth so there's no double-merge to worry about.
    cloud_last_upload_at = 0,
    cloud_upload_delay = 60,     -- seconds; cloud uploads are debounced
    journal_max_entries = nil,   -- nil = use SyncJournal.MAX_ENTRIES default
    activity_log_max = nil,      -- nil = use ACTIVITY_LOG_MAX default
    progress_freshness_days = nil, -- nil = use status-UI default 90
}


-- ============================================================================
-- Settings-key inventory — single source of truth
--
-- `_resetAll` (the menu's "Reset all settings", a SOFT reset of local
-- preferences) and `deletePluginSettings` (a HARD purge for uninstall/
-- deep clean that also wipes the state directory) both derive their
-- key list from these tables, so the two can't drift apart — a
-- hand-maintained list on each would (and once did) fall out of sync.
--
-- PREFERENCE_KEYS — every user-facing preference in G_reader_settings.
--   This is what a SOFT reset clears. It deliberately does NOT include
--   `syncery_device_id`: a soft "forget my settings" should keep this
--   device's network identity, so peers still recognise it. (Per-book
--   keys like `syncery_disabled` / `syncery_bm_state` live in the book's
--   doc_settings, not here, so they are correctly absent.)
local PREFERENCE_KEYS = {
    -- what-to-sync
    "syncery_sync_progress", "syncery_sync_annotations",
    "syncery_sync_highlights", "syncery_sync_notes", "syncery_sync_bookmarks",
    "syncery_sync_metadata", "syncery_sync_status", "syncery_sync_rating",
    "syncery_sync_collections", "syncery_sync_custom_metadata",
    "syncery_sync_handmade_toc", "syncery_sync_summary",
    "syncery_sync_render_settings",
    "syncery_sync_font_face", "syncery_sync_font_size",
    "syncery_sync_line_spacing", "syncery_sync_font_weight",
    "syncery_sync_margins",
    "syncery_sync_extensions",
    -- behaviour / display
    "syncery_jump_mode", "syncery_adapt_highlight_style",
    -- storage + diagnostics
    "syncery_storage_mode",
    "syncery_tombstone_ttl_days", "syncery_progress_freshness_days",
    "syncery_journal_max_entries", "syncery_activity_log_max",
    "syncery_min_save_interval",
    -- device label + first-run flag
    "syncery_device_label", "syncery_firstrun_done",
    -- Syncthing
    "syncery_use_syncthing",
    "syncery_syncthing_api_key", "syncery_syncthing_folder_id",
    "syncery_syncthing_folder",
    "syncery_syncthing_port", "syncery_syncthing_scheme",
    -- Cloud
    "syncery_use_cloud", "syncery_cloud_server", "syncery_cloud_upload_delay",
    -- DB sync (Reading Statistics + Vocabulary Builder)
    "syncery_db_sync_enabled", "syncery_db_sync_stats", "syncery_db_sync_vocab",
    "syncery_db_sync_unify", "syncery_db_sync_interval_min",
}

-- FULL_PURGE_KEYS — PREFERENCE_KEYS plus this device's identity. Used by
-- the hard uninstall/deep-clean path, which is wiping everything anyway.
local FULL_PURGE_KEYS = { "syncery_device_id" }
for _, k in ipairs(PREFERENCE_KEYS) do FULL_PURGE_KEYS[#FULL_PURGE_KEYS + 1] = k end

-- ============================================================================
-- Timer delegators
--
-- The `_cancelAllTimers` and `_schedule` machinery lives in
-- `syncery_lifecycle/timers.lua`.  The methods on Syncery: stay as
-- one-line delegators because ~25 call sites across this file read
-- `self:_schedule(...)` directly, and ~10 call sites also read the
-- slot field (`self._debounce_scan_action`) for "is a scan pending?"
-- semantics.  The Timers module preserves both: it mirrors the action
-- token onto `self[slot]` and the static slot list lives there as
-- Timers.SLOTS.
-- ============================================================================

function Syncery:_cancelAllTimers()
    if self._lifecycle then self._lifecycle:cancel_all_timers() end
end

function Syncery:_schedule(slot, delay, body)
    if self._lifecycle then self._lifecycle:schedule(slot, delay, body) end
end

function Syncery:_rebuildExtensionCache()
    local pattern = (self.sync_extensions or DEFAULT_SYNC_EXTENSIONS):gsub("%s+", "")
    local cache = { wildcard = false, exts = {} }
    if pattern == "" or pattern == "*" then
        cache.wildcard = true
    else
        for token in pattern:gmatch("[^,]+") do
            token = token:lower()
            if token == "*" then
                cache.wildcard = true
            elseif token ~= "" then
                cache.exts[token] = true
            end
        end
    end
    self._ext_cache = cache
end

function Syncery:_isFileTypeSynced(book_file)
    -- Per‑book opt‑out
    if self.ui and self.ui.document and self.ui.document.file == book_file then
        if self.ui.doc_settings:readSetting("syncery_disabled") then
            return false
        end
    end

    -- Build cache on first use (or after invalidation)
    if not self._ext_cache then
        self:_rebuildExtensionCache()
    end
    local cache = self._ext_cache
    if cache.wildcard then return true end
    local ext = Util.file_extension(book_file)
    return ext ~= "" and cache.exts[ext] == true
end

function Syncery:_getScanTarget(book_file, cfg)
    -- Accepts either a `cfg` table (from `Syncthing.getActiveConfig()`)
    -- or nil (read straight from Settings).  Prefer nil at callsites;
    -- a passed-in cfg is honoured for paths that already hold one.
    if not cfg then
        cfg = {
            folder_id = Settings.get_syncthing_folder_id(),
            folder    = Settings.get_syncthing_folder(),
        }
    end
    local sync_path = ProgressPaths.shared_progress_path(book_file)
    -- The path-math (folder match + per-mode sub-dir) lives in the
    -- testable ScanTarget module — main.lua is loadfile-only in the suite,
    -- so this replication-critical logic is unit-tested there instead.
    return ScanTarget.compute(sync_path, cfg, self.storage_mode)
end

function Syncery:_loadFirstrunFlag()
    if not _firstrun_done and G_reader_settings then
        _firstrun_done = G_reader_settings:readSetting("syncery_firstrun_done") or false
    end
end

function Syncery:maybeShowFirstRunDialog()
    self:_loadFirstrunFlag()

    -- The full first-run wizard. The "show once" gate is the persisted
    -- firstrun-done flag ALONE (checked inside Wizard.run via
    -- deps.firstrun_done). Do NOT re-add a "device already has a
    -- non-default label -> skip" short-circuit: it would skip the consent
    -- step for anyone who had merely renamed a device, leaving them syncing
    -- nothing under consent-first defaults. The flag being the sole gate is
    -- also why this doesn't re-appear every menu open — completing the
    -- wizard persists it.
    local deps = WizardPresenter.makeDeps{
        plugin   = self,
        settings = G_reader_settings,
        util     = Util,
        kosyncthing_resolver = function()
            -- rawget so we never trip an __index metatable side effect; this
            -- mirrors kosyncthing_plus_provider's own resolver. A present KOSyncthing+ supplies
            -- the API key + folder; the transport step is ALWAYS shown (it
            -- only enriches the Syncthing row — F1), and a detected KOSyncthing+
            -- skips just the inline API-key sub-step.
            return rawget(_G, "KOSyncthingPlusAPI")
        end,
        config_xml_key_resolver = function()
            -- The OTHER auto source the wizard can skip the API-key step for:
            -- a local-daemon Syncthing plugin's config.xml under DataStorage.
            -- Cheap (one file read); reuses the real provider so the wizard's
            -- answer can't drift from what the transport chain will do.
            return SyncthingProviders.config_xml_key_available()
        end,
        -- Inline Syncthing sub-step plumbing without KOSyncthing+: the key
        -- persists via Settings (saved-first) and the async test reuses the
        -- menu's canonical helper + diagnostics.
        get_syncthing_api_key = function()
            return Settings.get_syncthing_api_key()
        end,
        save_syncthing_api_key = function(key)
            Settings.set_syncthing_api_key(key)
        end,
        is_online = function() return self:_isNetworkOnline() end,
        test_syncthing = function(cb)
            require("syncery_ui/menu/_helpers").test_syncthing_connection(cb)
        end,
        is_first_run_done = function() return _firstrun_done end,
        persist_first_run_done = function()
            _firstrun_done = true
            if G_reader_settings then
                G_reader_settings:saveSetting("syncery_firstrun_done", true)
            end
        end,
        -- The coherent slide-up window (injection point, like ToastWidget in
        -- Notify). The presenter swaps its body per step; text steps use the
        -- InputDialog below.
        make_wizard_window = function(spec) return WizardWindow.new(spec) end,
        -- Bare white full-screen backdrop shown behind the text-step InputDialog
        -- (device name / API key) so the wizard's white background persists
        -- while the system keyboard is up.
        make_backdrop = function() return WizardWindow.new_backdrop() end,
        widgets = {
            InputDialog  = InputDialog,
            InfoMessage  = InfoMessage,
            UIManager    = UIManager,
        },
        notify = function(text) Notify.notifyL2(text) end,
    }
    Wizard.run(deps)
end

function Syncery:init()
	local ok_meta, meta = pcall(require, "_meta")
	if ok_meta and meta and meta.version then
        self.version = meta.version
        logger.info("Syncery version " .. tostring(meta.version) .. " started")
    end
	load_activity_log()
    self.destroyed    = false
    -- Close-time annotation stash (G): defensive clear.  Fresh per-book plugin
    -- instances start nil (PluginLoader:createPluginInstance) and
    -- on_save_settings consumes the stash on delivery; this only guards the
    -- edge where a destroying flush stashed without a final SaveSettings to
    -- consume it.  See ANNOTATION_DELIVERY_DESIGN.md S2 / G-wiring.
    self._pending_anns = nil
    self.device_id    = Util.get_device_id()
    self.device_label = Util.get_device_label()

    -- Wire the notification coordinator to the real UIManager and
    -- the shared bottom toast. Call sites use Notify.notifyL1/L2/Invite; the
    -- coordinator serialises L2 toasts (one at a time, with a gap) so e-ink
    -- never has to render two at once.
    Notify.configure{
        scheduleIn = function(secs, fn) UIManager:scheduleIn(secs, fn); return fn end,
        unschedule = function(task) if task then UIManager:unschedule(task) end end,
        present    = function(item, on_tap)
            local w = ToastWidget.present(item, on_tap)
            if w then UIManager:show(w) end
            return w
        end,
        dismiss    = function(widget) if widget then UIManager:close(widget) end end,
        log        = function(msg) logger.info("Syncery notify: " .. tostring(msg)) end,
    }

    if G_reader_settings then
        local read_bool = function(key, default)
            local v = G_reader_settings:readSetting(key)
            return (v == nil) and default or (v == true)
		end

        -- Consent-first defaults: nothing syncs until the user opts in
        -- (via the wizard, or the menu toggles), so these start OFF.
        -- The annotation sub-toggles (highlights/notes/bookmarks) default
        -- ON because they are gated behind the sync_annotations master:
        -- they only do anything once annotations is turned on, so leaving
        -- them ON means "when you enable annotations, you get all of it".
        self.sync_progress         = read_bool("syncery_sync_progress",         false)
        self.sync_annotations      = read_bool("syncery_sync_annotations",      false)
        self.sync_highlights       = read_bool("syncery_sync_highlights",       true)
        self.sync_notes            = read_bool("syncery_sync_notes",            true)
        self.sync_bookmarks        = read_bool("syncery_sync_bookmarks",        true)
        self.use_syncthing         = read_bool("syncery_use_syncthing",         false)
        self.use_cloud             = read_bool("syncery_use_cloud",             false)
        -- Trigger-only sync of the sibling Statistics / Vocabulary plugins.
        -- These live fields back the What's-synced toggles; syncery_db_sync
        -- reads the matching G_reader_settings keys (which the toggles persist).
        self.db_sync_enabled       = read_bool("syncery_db_sync_enabled",       false)
        self.db_sync_stats         = read_bool("syncery_db_sync_stats",         true)
        self.db_sync_vocab         = read_bool("syncery_db_sync_vocab",         true)
        self.db_sync_unify         = read_bool("syncery_db_sync_unify",         false)
        self.db_sync_interval_min  = Settings.get_db_sync_interval_min()
        self.jump_mode             = G_reader_settings:readSetting("syncery_jump_mode") or "ask"
        self.adapt_highlight_style = read_bool("syncery_adapt_highlight_style", false)
        self.sync_metadata         = read_bool("syncery_sync_metadata",          false)
        self.sync_status           = read_bool("syncery_sync_status",            true)
        self.sync_rating           = read_bool("syncery_sync_rating",            true)
        self.sync_collections      = read_bool("syncery_sync_collections",       true)
        self.sync_custom_metadata  = read_bool("syncery_sync_custom_metadata",  false)
        self.sync_handmade_toc     = read_bool("syncery_sync_handmade_toc",     false)

        -- Annotation-engine companion toggles.  Read here so the user
        -- has a single coherent settings surface and so we can forward
        -- them to the orchestrator without re-deriving anything.
        self.sync_summary        = read_bool("syncery_sync_summary",         false)
        self.sync_render_settings = read_bool("syncery_sync_render_settings", false)
        self.sync_font_face      = read_bool("syncery_sync_font_face",       false)
        self.sync_font_size      = read_bool("syncery_sync_font_size",       false)
        self.sync_line_spacing   = read_bool("syncery_sync_line_spacing",    false)
        self.sync_font_weight    = read_bool("syncery_sync_font_weight",     false)
        self.sync_margins        = read_bool("syncery_sync_margins",         false)

        -- Cloud upload debounce (seconds): wait this long after the last
        -- save before uploading, so a burst of saves coalesces into one
        -- upload.  Kept generous to protect rate-limited providers like
        -- Dropbox; min 15 to avoid foot-guns.  NOT a fixed interval — it
        -- re-arms on each save.
        local cu = G_reader_settings:readSetting("syncery_cloud_upload_delay")
        if type(cu) == "number" and cu >= 15 then
            self.cloud_upload_delay = cu
        end

        -- Orphan-setting reads: tuning knobs with no menu UI.  Read from
        -- settings when a previously-saved value is present, else their
        -- built-in defaults apply.  Same guarded shape as cloud_upload_delay.
        local jme = G_reader_settings:readSetting("syncery_journal_max_entries")
        if type(jme) == "number" and jme >= 50 and jme <= 1000 then
            self.journal_max_entries = jme
        end

        local alm = G_reader_settings:readSetting("syncery_activity_log_max")
        if type(alm) == "number" and alm >= 10 and alm <= 100 then
            self.activity_log_max = alm
        end
        -- Apply to the module-level cap.
        set_activity_log_max(self.activity_log_max)

        -- Book data save interval (seconds): how often _save persists
        -- progress + annotations during reading (it also throttles the
        -- reading-path Syncthing scan, which fires inside _save).  Same
        -- guarded-default shape as the orphan knobs above.
        local msi = G_reader_settings:readSetting("syncery_min_save_interval")
        if type(msi) == "number" and msi >= 5 and msi <= 120 then
            self.min_save_interval = msi
        end

        local pfd = G_reader_settings:readSetting("syncery_progress_freshness_days")
        if type(pfd) == "number" and pfd >= 7 and pfd <= 365 then
            self.progress_freshness_days = pfd
        end

        self.storage_mode = G_reader_settings:readSetting("syncery_storage_mode") or "sdr"
        AnnPaths.set_storage_mode(self.storage_mode)
        ProgressPaths.set_storage_mode(self.storage_mode)

        local ext = G_reader_settings:readSetting("syncery_sync_extensions")
        self.sync_extensions = (type(ext) == "string" and ext ~= "") and ext or DEFAULT_SYNC_EXTENSIONS
		self:_rebuildExtensionCache()
    end

    self.tombstone_ttl_days = (G_reader_settings and G_reader_settings:readSetting("syncery_tombstone_ttl_days")) or 90

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- Register our Dispatcher actions at load time, NOT only via the one-shot
    -- DispatcherRegisterActions broadcast: that event fires once per session
    -- (guarded by Dispatcher.initialized), so a plugin loaded after it already
    -- ran never registers and its actions never appear in the gesture/hotkey
    -- pickers. Calling it here (idempotent — registerAction de-dups by name)
    -- mirrors what cloudlibrary/KOReader plugins do and makes the actions
    -- reliably bindable. (The broadcast still works as a fallback.)
    self:onDispatcherRegisterActions()

    -- Build the transport stack.  This is the only place
    -- main.lua talks to the orchestrator directly — all push paths go
    -- through `self._transport:push_*`.  The factory wires defaults
    -- (settings reader, scheduler, etc.) and returns a Bridge instance
    -- that proxies into the orchestrator.
    self._transport = Transports.build({
        doc_id_fn = function(file, _doc_settings)
            -- doc_id derivation.  AnnPaths._book_content_id reads
            -- KOReader's `partial_md5_checksum` from the active
            -- doc_settings, or recomputes it via util.partialMD5 when
            -- the cached value isn't available.  Last-resort fallback
            -- (neither reachable — filesystem broken / file missing):
            -- it hashes the basename directly.  That only fires when
            -- the book file has gone, so there's no live position to
            -- push for it anyway; the next time KOReader can open the
            -- book it gets a fresh partialMD5.
            --
            -- The doc_settings parameter is intentionally ignored
            -- here — AnnPaths opens doc_settings internally via the
            -- book_path, which means callers without a doc_settings
            -- in hand (background scans, menu actions on closed
            -- books) get the same answer as callers who do.
            return AnnPaths._book_content_id(file)
        end,
        on_status_change = function()
            -- Wire to KOReader's event bus so the menu redraws when
            -- transport status shifts (e.g. a push failed, a retry is
            -- now pending).  Best-effort: when there's no UIManager
            -- (test contexts that load this file directly), this is
            -- a no-op.
            if UIManager and UIManager.broadcastEvent and Event then
                local ok, ev = pcall(Event.new, Event, "SynceryStatusChanged")
                if ok then UIManager:broadcastEvent(ev) end
            end
        end,
        -- Fired by the Cloud transport when the server RESPONDS to a sync (the
        -- merge callback running == the remote object was downloaded).  Marks
        -- the reachability verdict fresh and caches the server IP at that
        -- proven network-up moment, so the cloud-upload gate's probe stays
        -- non-blocking.  Guarded: the instance exists by the time a sync can
        -- fire (both are built in init), but stay defensive.
        on_server_responded = function()
            if self._cloud_reachability then
                self._cloud_reachability:note_success()
            end
        end,
        -- A cloud PULL reconciled remote annotation data into the shared file
        -- (this fires from inside the merge callback, the moment the download
        -- landed and merged).  Re-run checkRemote so the orchestrator picks the
        -- freshly-pulled data up and offers the [Reload] toast IN-SESSION --
        -- even on a fresh device that had NO annotations before.  Without this
        -- the pulled data sat in the shared file undelivered until a later
        -- open (delivery lagged the pull by a full open/close cycle).
        -- checkRemote self-guards on `destroyed` (a pull that lands during
        -- teardown is a harmless no-op) and MtimeGate no-ops when the file did
        -- not actually change, so an unchanged sync costs nothing.
        on_reconciled = function()
            self:_schedule("_post_pull_check", 0.5, function() self:checkRemote() end)
        end,
        -- Resolver for hius07's "Cloud storage+" plugin, reached
        -- as a method on the live plugin instance (ui.cloudstorage:sync).
        -- Lazy + UI-independent: the transport gets a resolver, never the
        -- ui itself. Read at sync time, so self.ui being unset at build is
        -- fine; the helper yields nil (the cloudstorage backend reports
        -- unavailable, selector falls back to syncservice) until the plugin is present.
        -- Body lives in CloudStorageProvider.resolve_ui_instance so this one
        -- line is regression-locked (cloudstorage_provider_spec) — main.lua
        -- itself isn't unit-loadable.
        ui_cloudstorage_resolver = function()
            return CloudStorageProvider.resolve_ui_instance(self.ui)
        end,
    })

    -- Lifecycle dispatcher.  Built AFTER self._transport
    -- because Teardown.flush reaches `plugin._transport:shutdown()` on
    -- a destroying flush.  Held for the lifetime of the plugin object;
    -- timers inside it get cancel_all'd on each teardown but the
    -- dispatcher itself outlives individual onReaderReady cycles.
    self._lifecycle = Lifecycle.new{
        plugin     = self,
        ui_manager = UIManager,
        util_now   = Util.now,
        logger     = logger,
    }

    -- The network-backoff scheduler.  Shared by every
    -- offline-sync path (`_doCloudUpload`,
    -- `_rescanAllFolders`).  The scheduler is injected as
    -- `UIManager:scheduleIn` (the same surface Timers uses); the
    -- connectivity probe is `Syncery:_isNetworkOnline` (which is true
    -- for ANY connection — WiFi, mobile data, Ethernet — see the
    -- wifi_backoff.lua name note).  `wake_network` is left unset:
    -- KOReader's NetworkMgr auto-manages connectivity on the platforms
    -- we target, and the retry does not depend on actively bringing it
    -- up — the next scheduled probe is what re-checks.
    self._wifi_backoff = WifiBackoff.new{
        scheduler = function(delay, fn) UIManager:scheduleIn(delay, fn) end,
        clock     = Util.now,
        is_online = function() return self:_isNetworkOnline() end,
        logger    = logger,
    }

    -- A SECOND backoff for the CLOUD path only.  Identical scheduler/clock,
    -- but its connectivity probe is `_isCloudReachable` (real reachability +
    -- the per-server TCP probe), not `_isNetworkOnline` (link-only).  A
    -- SEPARATE instance — not a per-attempt override of `_wifi_backoff` —
    -- because the two carry different connectivity semantics: Syncthing (the
    -- shared `_wifi_backoff`) talks to localhost and must stay on the link
    -- check; the cloud path must gate on internet + server reachability.
    -- Sharing one instance would also infinite-loop: with the link up the
    -- shared backoff runs the cloud action immediately, which re-defers on
    -- reachability, which the shared backoff (link still up) runs again…
    self._cloud_wifi_backoff = WifiBackoff.new{
        scheduler = function(delay, fn) UIManager:scheduleIn(delay, fn) end,
        clock     = Util.now,
        is_online = function() return self:_isCloudReachable() end,
        logger    = logger,
    }

    -- Async cloud-reachability verdict.  Replaces the SYNCHRONOUS per-upload
    -- DNS probe in `_isCloudReachable`: a cached verdict, moved by transfer
    -- outcomes (note_success) + NetworkMgr events + a NON-BLOCKING connect
    -- probe (settimeout(0)+connect polled with select(0) across UIManager
    -- ticks), so the cloud-upload gate never blocks the UI thread on DNS.
    -- DNS is kept off the probe path entirely: the only resolve is in
    -- note_success (post-server-response, network proven up -> fast), and the
    -- probe connects to the cached IP.  Socket/UIManager absent (headless) ->
    -- probe I/O is nil -> the module fails OPEN, exactly like the old
    -- synchronous path.  Read by `_isCloudReachable` (the cloud-upload gate) and
    -- fed by `on_server_responded` (note_success) + the network event handlers.
    local _cr_resolve, _cr_connect_start, _cr_connect_poll, _cr_connect_close, _cr_connect_blocking
    local _cr_sok, _cr_socket = pcall(require, "socket")
    if _cr_sok and _cr_socket then
        _cr_resolve = function(host) return _cr_socket.dns.toip(host) end
        _cr_connect_start = function(ip, port)
            local s = _cr_socket.tcp()
            if not s then return nil end
            s:settimeout(0)                       -- non-blocking connect
            local r, err = s:connect(ip, port)
            -- in-progress reports "timeout"/"Operation already in progress";
            -- an immediate hard error means we cannot probe this target.
            if r == nil and err ~= "timeout"
                    and err ~= "Operation already in progress" then
                s:close(); return nil
            end
            return s
        end
        _cr_connect_poll = function(s)
            local _, w = _cr_socket.select(nil, { s }, 0)   -- 0 = instant poll
            if w[s] then
                return s:getpeername() and "ok" or "fail"   -- writable: peer => connected
            end
            return "wait"
        end
        _cr_connect_close = function(s) pcall(function() s:close() end) end
        -- BLOCKING bounded connect, used ONLY by warm_blocking() at teardown's
        -- close-time push (a terminal moment with no future tick for the async
        -- probe).  settimeout bounds it; it connects to the CACHED IP, so no DNS.
        _cr_connect_blocking = function(ip, port, timeout)
            local s = _cr_socket.tcp()
            if not s then return false end
            s:settimeout(timeout)
            local r = s:connect(ip, port)
            s:close()
            return r == 1 or r == true
        end
    end
    -- Seed the probe target from the persisted IP cache so it is non-blocking
    -- from the FIRST call of the session (closes the per-session bootstrap
    -- fail-open).  The module re-resolves + re-persists on host change / IP
    -- staleness via note_success, so a stale or server-changed entry self-heals.
    local _cr_ipcache = Settings.get_cloud_server_ip()
    self._cloud_reachability = CloudReachability.new{
        now           = Util.now,
        get_server    = function() return Settings.get_cloud_server() end,
        resolve       = _cr_resolve,
        connect_start = _cr_connect_start,
        connect_poll  = _cr_connect_poll,
        connect_close = _cr_connect_close,
        connect_blocking = _cr_connect_blocking,
        schedule      = function(delay, fn)
            if UIManager and UIManager.scheduleIn then
                UIManager:scheduleIn(delay, fn)
            end
        end,
        persist_ip    = function(host, ip)
            Settings.set_cloud_server_ip(host, ip)
        end,
        initial_ip    = _cr_ipcache and _cr_ipcache.ip,
        initial_host  = _cr_ipcache and _cr_ipcache.host,
    }

    -- Tie into kosyncthing_plus's public API when it's present.  This is
    -- the cleanest way to:
    --   • have our `*.sync-conflict-*` JSON files excluded from the
    --     KOSyncthing+'s user-visible conflict counter (we resolve them in RAM);
    --   • react instantly when syncthing starts or new conflicts appear,
    --     instead of waiting for the next book open or the next save.
    -- Safe no-op when KOSyncthing+ isn't installed.
    self:_setupKOSyncthingPlusIntegration()

    -- Arm the periodic DB-sync timer (module-level; runs in the reader AND the
    -- file manager, persists across navigation -- see the _db_sync_tick comment).
    _armDbSyncTimer()
end

function Syncery:setStorageMode(mode)
    if mode ~= "sdr" and mode ~= "hash" then
        mode = "sdr"
    end
    if self.storage_mode == mode then return end

    local old_mode = self.storage_mode
    self.storage_mode = mode
    if G_reader_settings then
        G_reader_settings:saveSetting("syncery_storage_mode", mode)
    end

    AnnPaths.set_storage_mode(mode)
    ProgressPaths.set_storage_mode(mode)

    local state = self:getCurrentState()
    if state then
        self:_migrateBookFiles(state.file, old_mode, mode)
    end

    if mode == "hash" then
        -- Show the real hash root (override-aware), not Util.state_dir()
        -- which would display the default even if the user moved it.
        local hash_dir = AnnPaths._syncery_state_dir()
        UIManager:show(InfoMessage:new{
            text = string.format(_(
                "Synceryhash storage mode enabled.\n\n"
                .. "Syncery now saves progress and annotations to:\n  %s\n\n"
                .. "Synceryhash mode automatically ensures identical file paths on "
                .. "every device, regardless of the KOReader 'Book metadata location' "
                .. "setting. No extra configuration is required.\n\n"
                .. "Make sure Syncthing is configured to sync that folder "
                .. "so your files reach other devices."), hash_dir),
            timeout = 10,
        })
    end
end

-- ============================================================================
-- Storage-mode migration — thin delegators into syncery_migration/storage_mode.
--
-- The SDR↔hash file-moving logic lives in
-- `syncery_migration/storage_mode.lua` (plugin-parameter functions, the
-- teardown.lua pattern).  The one-line methods below keep the live UI
-- callers — `syncery_ui/booklist/`, `syncery_ui/menu/maintenance_section`,
-- and `setStorageMode` above — working unchanged.
-- ============================================================================

function Syncery:_migrateAllBooks(old_mode)
    return StorageMigration.migrate_all_books(self, old_mode)
end

function Syncery:_migrateBookFiles(book_file, from_mode, to_mode)
    return StorageMigration.migrate_book_files(self, book_file, from_mode, to_mode)
end

function Syncery:migrateSingleBook(book)
    return StorageMigration.migrate_single_book(self, book)
end


-- Scan all books for native annotations and ingest them into
-- Syncery without opening each book. On-demand only. Idempotent (skips books
-- that already have a Syncery annotations file). Runs inside Trapper so it
-- shows a progress dialog like the storage migration.
function Syncery:_bulkIngestAnnotations()
    local Scan = require("syncery_ui/booklist/scan")
    -- Like "Manage all synced books" and the migration tool: roots for the
    -- "doc"-location walk come from two sources, merged — the user's Syncthing
    -- folders AND the folders of recently-opened books (history).  The "dir"
    -- and "hash" metadata trees are fixed and scanned WITHOUT roots, so the
    -- picker is only a last resort (offered inside _runBulkIngest if the scan
    -- finds nothing AND there were no roots), not a first-line prompt.
    local roots = Scan.getScanRoots()
    local seen_root = {}
    for __, r in ipairs(roots) do seen_root[r] = true end
    for __, r in ipairs(Scan.deriveRootsFromHistory()) do
        if not seen_root[r] then
            seen_root[r] = true
            roots[#roots + 1] = r
        end
    end
    self:_runBulkIngest(roots, #roots == 0)
end

function Syncery:_runBulkIngest(roots, offer_picker_if_empty)
    local BulkIngest        = require("syncery_ann/bulk_ingest")
    local HashLocationFinder = require("syncery_ann/hash_location_finder")
    local DocSettings       = require("docsettings")
    local DocSettingsBridge = require("syncery_ann/doc_settings_bridge")
    local MetadataBridge    = require("syncery_ann/metadata_bridge")
    local RenderBridge      = require("syncery_ann/render_settings_bridge")
    local lfs               = Util.get_lfs()
    local device_id         = self.device_id
    local device_label      = self.device_label

    -- Item 10: the backfill captures pre-Syncery DATA, not just annotations.
    -- Read native metadata + render the same way a normal sync would,
    -- respecting the master + per-field toggles (a disabled section reads
    -- back empty, so a type the user turned off is never backfilled).
    local md_toggles        = MetadataBridge.make_toggles_from_plugin(self)
    local render_toggles    = RenderBridge.make_toggles_from_plugin(self)

    local deps = {
        find_books = function()
            -- Three sources, de-duplicated by real book path via a shared
            -- `seen` table (a book with sidecars in more than one location
            -- appears once):
            --   1. the .sdr walk over the roots (the user's Syncthing folders
            --      PLUS history-derived roots — books whose sidecars sit
            --      beside them, "doc" metadata mode);
            --   2. KOReader's central "dir" metadata tree (fixed path,
            --      works with no roots configured);
            --   3. KOReader's "hash" metadata tree (`hashdocsettings/`),
            --      enumerated by HashLocationFinder.  The hash-named .sdr
            --      carries no book name, so the book is reconstructed from
            --      the `doc_path` stored INSIDE each metadata file; the
            --      shared existence guard skips any whose book no longer
            --      exists on disk (stale doc_path), so no orphan/duplicate
            --      sidecar is written.
            local seen = {}
            local books = BulkIngest.find_sdr_books(roots, lfs, seen)
            local dir_books = BulkIngest.find_books_in_metadata_dir(lfs, seen)
            for _, b in ipairs(dir_books) do
                books[#books + 1] = b
            end
            local hash_books = HashLocationFinder.find_native_books(lfs, seen)
            for _, b in ipairs(hash_books) do
                books[#books + 1] = b
            end
            return books
        end,
        already_ingested = function(book)
            -- Use the _for_read variant: it checks all sidecar locations
            -- (doc / dir / hash), not just the canonical write path.  A book
            -- whose Syncery file lives at a non-canonical location (e.g. after
            -- a storage-mode change) would otherwise be re-ingested, producing
            -- a duplicate.  See paths_spec.lua "P4 guard" assertions.
            local p = AnnPaths.shared_annotations_path_for_read(book)
            return p ~= nil and lfs and lfs.attributes(p, "mode") == "file"
        end,
        open_ui = function(book)
            local ok, ds = pcall(function() return DocSettings:open(book) end)
            if not ok or not ds then return nil end
            return { doc_settings = ds }   -- no .paging: the bridge reads both keys
        end,
        read_map = function(ui)
            return DocSettingsBridge.read_annotations_as_map(ui)
        end,
        stamp = function(map)
            return Orchestrator._stamp_local_annotations(map, device_id, device_label)
        end,
        write_initial = function(book, map, ui)
            local state = AnnStateStore.load_shared(book)   -- empty state if absent
            state.annotations = map
            -- Item 10: also capture pre-existing metadata + render from the
            -- same DocSettings the annotations came from, so a fresh install
            -- backfills the full reading state, not just highlights.  Each
            -- section is toggle-gated (off -> {}); a first backfill has no
            -- ancestor -> nil (status lattice generation 0).
            state.metadata        = MetadataBridge.read_from_ui(
                ui, book, md_toggles, device_id, device_label, nil)
            state.render_settings = RenderBridge.read_from_ui(ui, render_toggles)
            local ok_save = AnnStateStore.save_shared(book, state)
            -- Journal this per-book backfill (kind="bulk", one line per book);
            -- pcall-isolated so a diagnostic writer never breaks the ingest.
            if ok_save then
                local ingested = 0
                for _k in pairs(map) do ingested = ingested + 1 end
                pcall(function()
                    SyncJournal.record_bulk(AnnPaths._book_content_id(book), {
                        ingested            = ingested,
                        transport           = Util.transport_label(self.use_syncthing, self.use_cloud),
                        max_entries         = self.journal_max_entries,
                        writer_device_label = device_label,
                    })
                end)
            end
            return ok_save
        end,
        on_progress = function(i, total)
            if Trapper and Trapper.info and coroutine.isyieldable() then
                Trapper:info(string.format(
                    _("Scanning books for data…\n%d / %d"), i, total))
            end
        end,
    }

    Trapper:wrap(function()
        Trapper:info(_("Scanning books for data…"))
        local summary = BulkIngest.run(deps)
        Trapper:reset()

        -- Nothing found anywhere (no roots for the doc-walk AND the fixed
        -- dir/hash trees were empty too).  Offer the picker as a true last
        -- resort, and only when we had no roots to look in — otherwise an
        -- empty result is real.  Re-run with picker disabled to avoid loops.
        if summary.total == 0 and offer_picker_if_empty then
            local Scan = require("syncery_ui/booklist/scan")
            Scan.promptForScanRoot(function(chosen)
                self:_runBulkIngest(chosen, false)
            end)
            return
        end

        UIManager:show(InfoMessage:new{
            text = string.format(
                _("Annotation scan complete.\n\n"
                  .. "Newly added: %d\nAlready synced: %d\n"
                  .. "No annotations: %d\nErrors: %d"),
                summary.ingested, summary.skipped_existing,
                summary.skipped_empty, summary.errors),
            timeout = 6,
        })
    end)
end


function Syncery:onReaderReady()
    local ok, err = pcall(function()
        self.destroyed  = false
        self.sync_state = "idle"
        self._pending_anns = nil  -- G: defensive close-time stash clear on (re)open

        -- Sanitize bookmarks for CRE documents immediately on open
        if self.ui and self.ui.doc_settings then
            local is_cre_open = (self.ui.rolling ~= nil)
            local bkmks   = self.ui.doc_settings:readSetting("bookmarks") or {}
            local clean   = sanitize_bookmarks(bkmks, is_cre_open)
            local removed = #bkmks - #clean
            if removed > 0 then
                self.ui.doc_settings:saveSetting("bookmarks", sanitize_for_lua(clean))
                logger.warn("Syncery: removed " .. removed
                    .. " bookmarks without valid xpointer on open (is_cre=" .. tostring(is_cre_open) .. ")")
                -- No UI refresh nudge here on purpose: this sanitizes the LEGACY
                -- `bookmarks` key, which current KOReader only consults during the
                -- one-time migration to `annotations` (in ReaderAnnotation:
                -- onReadSettings, which runs at load, BEFORE this handler).  By the
                -- time we get here the in-memory annotation list is already built
                -- and is not derived from this key, so there is nothing to refresh.
                -- (The previous nudges were both no-ops anyway: `onReadSettings`
                -- lives on ReaderAnnotation, not ReaderBookmark, and KOReader has
                -- no handler for an "UpdateAnnotations" event.)
            end
        end

        local state = self:getCurrentState()
        if state then
            -- Surface the silent cross-device-sync trap.  If building this
            -- book's id had to fall back to a basename hash (no cached
            -- partial_md5_checksum and no live partialMD5), the id differs
            -- per device and the book will sync to nobody.  Warn once per
            -- book per session — getCurrentState already computed the id,
            -- so this just reads the flag paths.lua set.
            if AnnPaths.had_basename_fallback(state.file) then
                self._basename_fallback_warned = self._basename_fallback_warned or {}
                if not self._basename_fallback_warned[state.file] then
                    self._basename_fallback_warned[state.file] = true
                    Notify.notifyL2(_(
                        "Syncery can't identify this book reliably, so it "
                        .. "won't sync across your devices. This usually "
                        .. "means the file couldn't be read fully."))
                end
            end
            -- Hash-mode title cache.  MUST be written through the same
            -- path builder that progress/annotations use
            -- (AnnPaths._shared_book_state_dir), so that (1) it lands under
            -- the `synceryhash/` subdirectory the booklist scan reads, (2) it
            -- uses the fixed hash root, and (3) it uses the SAME
            -- book-id derivation as the data files (so the title sits in
            -- the same per-book directory).  A bespoke partialMD5 +
            -- Util.state_dir() path drifts on all three counts.
            if self.storage_mode == "hash" then
                local book_dir = AnnPaths._shared_book_state_dir(state.file)
                if book_dir then
                    local title_path = book_dir .. "/title.txt"
                    local ok_util, kutil = pcall(require, "util")
                    local safe_title = ok_util and kutil.getSafeFilename(self:getBookTitle(), title_path, 240, 10)
                                       or self:getBookTitle()
                    local f = io.open(title_path, "w")
                    if f then
                        f:write(safe_title)
                        f:close()
                    end
                end
            end

            -- Migration for hash mode if progress file missing
            if self.storage_mode == "hash" then
                local lfs = Util.get_lfs()
                local progress_path = ProgressPaths.shared_progress_path(state.file)
                if progress_path and (not lfs or lfs.attributes(progress_path, "mode") ~= "file") then
                    self:_migrateBookFiles(state.file, "sdr", "hash")
                end
            end

            -- Reset the per-book jump-prompt suppression map.  It holds,
            -- per remote device, the highest revision we have already
            -- prompted the user about (see syncery_ui/jump_policy.lua).
            -- It MUST be (re)initialised HERE, per book — never declared
            -- on the module field literal, which would alias one table
            -- across all plugin instances and leak acks between books.
            --
            -- Book-level metadata application lives in the annotation
            -- orchestrator's load path, so it is deliberately not
            -- duplicated here.
            self.acked_remote_revs = {}

            -- NOTE: there is no scheduled tombstone GC here anymore.
            -- The annotation orchestrator compacts old tombstones on
            -- every sync (compact, never drop), driven by
            -- `tombstone_ttl_days`; a separate scheduled pass would be
            -- redundant.  Likewise no `_pruneStaleProgress`: the shared
            -- progress file keeps every entry forever and staleness is
            -- a view-only filter (ProgressBridge).
        end

        self:_schedule("_check_remote_action", 2.0, function()
            self:checkRemote()
        end)

        -- Open-moment cloud PULL.  The bidirectional cloud sync is the only way
        -- to DOWNLOAD a peer's data, and it normally rides the autosave upload,
        -- which is debounced (cloud_upload_delay) -- on a short open/close that
        -- flush lands only at teardown, too late to deliver this session.  Fire
        -- an immediate pull on open instead: it reconciles remote annotations
        -- into the shared file WHILE the book is open, and on_reconciled then
        -- offers the [Reload] toast in-session -- even on a fresh device with no
        -- local annotations (do_cloud_upload stages an in-memory empty envelope
        -- so the pull runs).  Async (no UI freeze) and reachability-gated inside
        -- _doCloudUpload; a cold probe simply defers to the cloud backoff, which
        -- retries when reachable.
        if self.use_cloud then
            self:_schedule("_open_cloud_pull", 2.5, function()
                local s = self:getCurrentState()
                if s then self:_doCloudUpload(s) end
            end)
        end

        -- Open-moment cloud PULL: download a peer's progress/annotations now,
        -- instead of waiting for the debounced autosave upload (which on a
        -- short open/close only flushes at teardown -- too late to deliver this
        -- session).  The bidirectional sync reconciles remote data into the
        -- shared file; on_reconciled then re-runs checkRemote and offers the
        -- [Reload] toast IN-SESSION, even on a fresh device with no prior
        -- annotations.  Async (no UI freeze) and reachability-gated inside
        -- _doCloudUpload, which also no-ops when nothing changed.
        if self.use_cloud then
            self:_schedule("_open_cloud_pull", 2.5, function()
                local s = self:getCurrentState()
                if s then self:_doCloudUpload(s) end
            end)
        end

        self:_schedule("_autosave_action", 0.5, function()
            if (os.time() - (self.last_save_time or 0)) >= self.min_save_interval then
                self:_autoSave(true)
            end
        end)

        self:_loadFirstrunFlag()
    end)

    if not ok then
        logger.warn("Syncery: onReaderReady error:", tostring(err))
        UIManager:show(ConfirmBox:new{
            text = _("Syncery ran into an unexpected error while opening this book."),
            ok_text = _("Close")
        })
    end
end

-- ============================================================================
-- Document State Extractors
-- ============================================================================

function Syncery:getCurrentState()
    if self.destroyed then return nil end

    local ui  = self.ui
    local doc = ui and ui.document
    if not doc or not doc.file then return nil end

    local props = doc:getProps()
    if not props then return nil end

    local page, total, xpath, percent = nil, nil, nil, nil

    if ui.paging then
        local ok_p, p = pcall(doc.getCurrentPage, doc)
        if ok_p and type(p) == "number" then page = p end

        local ok_t, t = pcall(doc.getPageCount, doc)
        if ok_t and type(t) == "number" and t > 0 then total = t end
    elseif ui.rolling then
        page  = tonumber(ui.rolling.current_page)
        -- ReaderRolling has no total_pages field; the page count comes from the
        -- document (getPageCount), same as the paging branch.  The footer
        -- fallback below still applies if this is unavailable.
        local ok_t, t = pcall(doc.getPageCount, doc)
        if ok_t and type(t) == "number" and t > 0 then total = t end

        if type(ui.rolling.xpointer) == "string" then
            xpath = ui.rolling.xpointer
        else
            local ok_x, x = pcall(doc.getXPointer, doc)
            if ok_x and type(x) == "string" and x ~= "" then
                xpath = x
            end
        end
    else
        local ok_p, p = pcall(doc.getCurrentPage, doc)
        if ok_p and type(p) == "number" then page = p end

        local ok_t, t = pcall(doc.getPageCount, doc)
        if ok_t and type(t) == "number" and t > 0 then total = t end
    end

    local footer = ui.footer or (ui.view and ui.view.footer)
    if footer then
        if type(footer.percent_finished) == "number" then
            percent = footer.percent_finished
        end
        if not page and footer.pageno then
            page = tonumber(footer.pageno)
        end
        if not total and footer.pages then
            total = tonumber(footer.pages)
        end
    end

    if not percent then
        percent = (page and total and total > 0) and ((page - 1) / total) or 0
    end

    return {
        file = doc.file,
        page = page or 1,
        total_pages = total or 0,
        xpath = xpath,
        percent = percent,
        is_rolling = ui.rolling ~= nil
    }
end

function Syncery:getBookTitle()
    local ui = self.ui
    if ui and ui.document then
        local ok, props = pcall(function() return ui.document:getProps() end)
        if ok and props and type(props.title) == "string" and props.title ~= "" then
            return props.title
        end
    end

    if ui and ui.document and ui.document.file then
        local file = ui.document.file
        return file:match("([^/\\]+)%.%w+$") or file:match("([^/\\]+)$") or file
    end

    return _("Unknown")
end

-- ============================================================================
-- Jump & Sync Logic
-- ============================================================================

function Syncery:_doJump(state, r_page, r_percent, r_xpath)
    -- Suppress autosave for a short, SELF-HEALING window rather than
    -- raising an indefinite boolean that a later code path is responsible
    -- for clearing. The clear used to live at the end of _save (after its
    -- pcall), reached only by the scheduled recovery save — but that save
    -- could be skipped (book closed within the window → no state → early
    -- return) or never fire at all (its shared "_autosave_action" slot
    -- overwritten by another schedule), stranding the flag true for the
    -- whole session. A time-boxed window lapses on its own no matter what
    -- happens to the recovery save. 5s comfortably covers the 0.5s
    -- recovery delay; the failure direction is safe (autosave resuming a
    -- touch early just persists a valid position, the opposite of the
    -- silent-freeze bug). os.time() matches the sibling pre_jump_until
    -- below and is scale-compatible with the lifecycle's Util.now clock.
    self.blocking_autosave_until = os.time() + 5
    self.pre_jump_page  = state.page
    self.pre_jump_xpath = state.xpath
    self.pre_jump_until = os.time() + 60

    if r_xpath and r_xpath ~= "" and state.is_rolling
            and ProgressBridge.xpointer_resolves(self.ui and self.ui.document, r_xpath) then
        -- marker_xp == target (see ProgressBridge.gotoxpointer_args): jump
        -- to the last-read position and flash KOReader's margin marker there
        -- for ~1s so the eye finds the line after a reflow.  Purely visual;
        -- the anchor is unchanged, so the jump never skips unread text.
        --
        -- The xpointer_resolves() gate matters cross-edition: a remote xpointer
        -- that does not exist in the copy opened here (different file, or a DOM
        -- paginated differently by another crengine) would otherwise be fed
        -- straight to KOReader, which sets it as self.xpointer and then crashes
        -- getPageFromXPointer on the next page turn.  When it does not resolve
        -- we fall through to the page/percent path below instead of jumping
        -- into a dead anchor.
        UIManager:broadcastEvent(Event:new("GotoXPointer",
            ProgressBridge.gotoxpointer_args(r_xpath)))
        return
    end

    -- Page resolution priority: r_page > r_percent fallback.
    -- Previously percent ALWAYS overrode page when both were present, which
    -- caused a 1-page round-trip asymmetry: (page-1)/total written, then
    -- floor(total * pct + 0.5) read, recovers page-1 in some cases.
    -- r_page is sent alongside r_percent in _writeSave and is the exact
    -- value — only fall back to percent translation when r_page is absent
    -- (e.g. from an old client that didn't send it).
    local target
    if r_page and r_page > 0 then
        target = math.max(1, math.min(state.total_pages or r_page, r_page))
    elseif r_percent and r_percent > 0 and state.total_pages and state.total_pages > 0 then
        target = math.max(1, math.min(state.total_pages,
            math.floor(state.total_pages * r_percent + 0.5)))
    else
        target = 1
    end

    UIManager:broadcastEvent(Event:new("GotoPage", target))
end


--- Journal a jump as the canonical "jumped" event (kind="progress").
--- Called from all three jump paths right after _doJump dispatches its
--- GotoPage/GotoXPointer broadcast (which is synchronous, so this is "after
--- the broadcast").  The jump's follow-up save pushes the adopted position
--- but is dropped by record_progress's event filter (trigger="jump"), so a
--- jump produces exactly ONE journal line, not a "jumped" plus a redundant
--- "merged".  pcall-isolated: a diagnostic writer must never break a jump.
function Syncery:_journalJump(state, winning_label)
    if not (state and state.file) then return end
    local journal_transport = Util.transport_label(self.use_syncthing, self.use_cloud)
    pcall(function()
        SyncJournal.record_jump(
            AnnPaths._book_content_id(state.file),
            { winning_device_label = winning_label,
              transport            = journal_transport,
              max_entries          = self.journal_max_entries,
              writer_device_label  = self.device_label })
    end)
end

-- ============================================================================
-- Unified jump prompt
--
-- One helper renders the jump prompt for every transport, so the same
-- user-facing event ("someone else is at a new position in this book")
-- looks identical no matter which transport fired — and the prompt can
-- say WHICH one spoke.  It gives the user three actions instead of two:
--
--   • Jump      — go to the remote position (primary action)
--   • Show all  — open the full status view to inspect every device
--                 and pick a specific one (handy when multiple devices
--                 report different positions)
--   • Stay      — dismiss
--
-- It also exposes the transport name in the prompt body so the user
-- can tell at a glance whether the position came from Syncthing or
-- cloud.  The "auto" jump mode short-circuits before the prompt and
-- behaves identically across transports.
--
-- opts fields:
--   state          — current document state (required)
--   r_page         — remote page number (1-based)
--   r_percent      — remote percentage 0.0–1.0 (preferred fallback for r_page)
--   r_xpath        — optional CRE xpointer (rolling docs only)
--   r_timestamp    — optional Unix seconds (for "X min ago")
--   remote_label   — device name to show
--   transport      — short transport tag, e.g. "Syncthing"
--   on_jump        — optional callback fired right BEFORE _doJump runs
--                    (Syncthing uses it to record the acknowledged remote
--                     revision in acked_remote_revs)
--   on_dismiss     — optional callback fired when the user picks Stay
-- ============================================================================

-- Resolve a shared xpointer to a chapter title on THIS device's open book, for
-- the jump invite.  `getTocTitleByPage` takes an xpointer directly (an in-memory
-- TOC lookup -- the same one the footer uses), so there is no separate page
-- resolution step.  It can crash on non-string input (credocument) and returns
-- "" when there is no TOC or the position doesn't resolve (e.g. a different
-- edition), so this is string-guarded AND pcall-wrapped and yields nil in those
-- cases -- the invite then shows percent only.
function Syncery:_resolveChapter(xpath)
    if type(xpath) ~= "string" or xpath == "" then return nil end
    local ui = self.ui
    if not (ui and ui.toc and ui.toc.getTocTitleByPage) then return nil end
    local ok, title = pcall(function() return ui.toc:getTocTitleByPage(xpath) end)
    if ok and type(title) == "string" and title ~= "" then return title end
    return nil
end


-- Run the full prompt flow.  Honours jump_mode ("auto"/"ask"/"never"),
-- sets sync_state to
-- "syncing" with a 5-second unlock, and prevents two prompts from ever
-- being on-screen at once (returns false without showing anything when
-- a prompt is already active or sync_state isn't idle).
function Syncery:_promptJump(opts)
    local state = opts.state
    if not state then return false end
    -- "never" receive mode: no automatic jump prompt at all.  An explicit
    -- jump from "Jump to another device now…" is unaffected -- it calls
    -- _doJump directly, not through here -- so the user can still pull a
    -- position on demand.
    if self.jump_mode == "never" then return false end
    if self.sync_state == "syncing" or self._active_sync_box then
        return false
    end

    -- "auto" receive mode: short-circuit straight to the jump (same
    -- behaviour across transports), then confirm with an [Undo] toast.
    if self.jump_mode == "auto" then
        self.sync_state = "syncing"
        self:_schedule("_sync_unlock_action", 5, function()
            if self.sync_state == "syncing" then self.sync_state = "idle" end
        end)
        if opts.on_jump then pcall(opts.on_jump) end
        self:_doJump(state, opts.r_page, opts.r_percent, opts.r_xpath)
        self:_journalJump(state, opts.remote_label)
        self:_schedule("_autosave_action", 0.5, function()
            self:_save({ silent = true, trigger_sync = false, force = true, trigger = "jump" })
            self.sync_state = "idle"
        end)
        -- Confirm via the non-blocking bottom ACTION BAR (a ReaderView view
        -- module + a button touch zone -- see syncery_ui/action_bar.lua),
        -- NOT a toast: a toast/window blocks page turns while it is up. The
        -- bar carries an [Undo] button for the 60s undo window (pre_jump_until)
        -- and lets the reader keep paging the whole time.  ActionBar.show
        -- self-degrades on non-touch to a focusable, auto-dismissing dialog
        -- (the touch-zone button is otherwise unreachable).
        ActionBar.show(self.ui, {
            text         = _("Auto-jumped to new position."),
            button_label = _("Undo"),
            on_action    = function() self:_undoLastJump() end,
            seconds      = 12,
            show_close   = true,  -- [✕] dismisses the bar now (== 12s elapsed)
        })
        return true
    end

    self.sync_state = "syncing"
    self:_schedule("_sync_unlock_action", 5, function()
        if self.sync_state == "syncing" then self.sync_state = "idle" end
    end)

    -- In "ask" mode, invite via the NON-blocking bottom action bar (view
    -- module + button touch zone, syncery_ui/action_bar.lua), NOT a toast:
    -- the reader keeps paging while the invitation is up. Tap [Jump] to go;
    -- timeout (12s) = Stay (safe default -- a missed invite leaves the page
    -- unchanged). "See all positions" lives in the status panel, not here.
    -- `_active_sync_box` is reused as the single-prompt re-entry guard.
    self._active_sync_box = true

    local function stay()
        self._active_sync_box = nil
        self.sync_state = "idle"
        if self._sync_unlock_action then
            UIManager:unschedule(self._sync_unlock_action)
            self._sync_unlock_action = nil
        end
        if opts.on_dismiss then pcall(opts.on_dismiss) end
    end

    local function jump()
        self._active_sync_box = nil
        UIManager:nextTick(function()
            if opts.on_jump then pcall(opts.on_jump) end
            self:_doJump(state, opts.r_page, opts.r_percent, opts.r_xpath)
            self:_journalJump(state, opts.remote_label)
            self:_schedule("_autosave_action", 0.5, function()
                self:_save({ silent = true, trigger_sync = false, force = true, trigger = "jump" })
                self.sync_state = "idle"
            end)
            -- After a prompted ("ask") jump, confirm via the same non-blocking
            -- bottom action bar as "auto" above -- carrying an [Undo] button so
            -- the reader can step back within the undo window (pre_jump_until)
            -- while still paging freely.  ActionBar.show self-degrades on
            -- non-touch to a focusable, auto-dismissing dialog.
            ActionBar.show(self.ui, {
                text         = _("Jumped to new position."),
                button_label = _("Undo"),
                on_action    = function() self:_undoLastJump() end,
                seconds      = 12,
                show_close   = true,  -- [✕] dismisses the bar now (== 12s elapsed)
            })
        end)
    end

    -- Reflowable books (xpath present) re-paginate per device, so the remote
    -- page is meaningless here -- show percent (comparable) plus the chapter
    -- resolved from the shared font-independent xpointer.  Paging docs (PDF)
    -- carry no xpath and a FIXED page that is identical across devices, so that
    -- page is the natural unit to show.
    local jump_opts = { remote_label = opts.remote_label }
    if type(opts.r_xpath) == "string" and opts.r_xpath ~= "" then
        jump_opts.percent = opts.r_percent
        jump_opts.chapter = self:_resolveChapter(opts.r_xpath)
    else
        jump_opts.page = opts.r_page
    end

    -- Non-touch devices (e.g. Kindle 3, 5-way only): the action bar's [Jump] is
    -- a touch zone with no key path, and its 12s auto-dismiss would expire
    -- before a key user could act -- so the invite is both unreachable and too
    -- brief. Use a focusable, no-timeout ButtonDialog with both choices labelled
    -- instead. Touch (and hybrid) devices keep the non-blocking action bar.
    --
    -- [Jump] is FIRST so FocusManager lands on it (and is_enter_default makes a
    -- bare [Press] jump): jumping is the 95% case, and a stray jump is recoverable
    -- via Undo. [Stay] (and Back / tap-outside) is the safe non-action.
    --
    -- Route this modal through the fallback slot so it never covers an active
    -- fallback (it queues) and a reload offer raised in the same checkRemote tick
    -- queues behind it instead of expiring hidden. `release(false)` on Jump frees
    -- the slot WITHOUT draining, so the post-jump undo (scheduled next tick by
    -- jump()) claims it before any queued reload -- undo shown before reload.
    -- ButtonDialog:onClose runs tap_close_callback on Back/tap-outside too, so the
    -- slot is always freed.
    if not Device:isTouchDevice() then
        ActionBar.showExclusive(function(release)
            local ButtonDialog = require("ui/widget/buttondialog")
            local dlg
            dlg = ButtonDialog:new{
                title = JumpToast.message(jump_opts) .. "\n\n"
                    .. _("Annotations are already synced — this only moves your reading position."),
                title_align = "center",
                dismissable = true,
                buttons = { {
                    { text = JumpToast.actionLabel(), is_enter_default = true,  -- "Jump" (default)
                      callback = function() UIManager:close(dlg); release(false); jump() end },
                    { text = _("Stay"),
                      callback = function() UIManager:close(dlg); release(); stay() end },
                } },
                tap_close_callback = function() release(); stay() end,  -- Back / tap-outside = Stay
            }
            UIManager:show(dlg)
            return dlg  -- handed to showExclusive so M.dismiss can close it on teardown
        end)
        return true
    end

    ActionBar.show(self.ui, {
        text = JumpToast.message(jump_opts),
        button_label = JumpToast.actionLabel(),
        on_action    = jump,
        on_timeout   = stay,
        seconds      = 12,
        show_close   = true,  -- [✕] = Stay now (runs on_timeout = stay), instead
                              -- of waiting out the 12s dwell
    })
    return true
end

--- Manual forward jump (Dispatcher action `syncery_jump`): jump straight to
--- the position of whichever OTHER device read most recently, bypassing the
--- prompt and the status panel.  Like the panel's per-device jump (and unlike
--- the reactive checkRemote path) it ignores jump_mode — the user asked for it
--- explicitly.  The forward-only target is the SAME JumpPolicy.pick_jump_target
--- the reactive path uses (most recent other device, or nil if we are the most
--- recent), so the semantics stay identical; only the trigger differs.
function Syncery:_jumpToLatestDevice()
    local state = self:getCurrentState()
    if not state or not state.file then
        UIManager:show(InfoMessage:new{ text = _("No document open."), timeout = 2 })
        return
    end
    local shared = ProgressStateStore.load_shared(state.file)
    local fresh  = ProgressBridge.filter_fresh_for_display(shared.entries or {})
    local best   = JumpPolicy.pick_jump_target(fresh, self.device_id)
    if not best then
        UIManager:show(InfoMessage:new{
            text = _("No newer position from another device to jump to."),
            timeout = 3 })
        return
    end
    self:_doJump(state, best.page or 1, best.percent or 0, best.xpath)
    self:_journalJump(state, best.label or _("Another device"))
    UIManager:show(InfoMessage:new{
        text = _("Jumped to the newest position from another device."),
        timeout = 2 })
    -- Persist the new position (mirrors the status-panel jump).
    self:_schedule("_autosave_action", 0.5, function()
        self:_save({ silent = true, trigger_sync = false, force = true, trigger = "jump" })
    end)
end

function Syncery:_undoLastJump()
    if not self.pre_jump_until or os.time() > self.pre_jump_until then
        UIManager:show(InfoMessage:new{
            text = _("Nothing to undo."),
            timeout = 2
        })
        return
    end

    local state = self:getCurrentState()
    local is_rolling = state and state.is_rolling

    if self.pre_jump_xpath and self.pre_jump_xpath ~= "" and is_rolling then
        -- Same marker_xp trick as the forward jump (see _doJump): flash the
        -- marker at the restored position so the eye finds it (purely visual).
        UIManager:broadcastEvent(Event:new("GotoXPointer",
            ProgressBridge.gotoxpointer_args(self.pre_jump_xpath)))
    elseif self.pre_jump_page then
        UIManager:broadcastEvent(Event:new("GotoPage", self.pre_jump_page))
    end

    self.pre_jump_until = 0
    UIManager:show(InfoMessage:new{
        text = _("Returned to previous position."),
        timeout = 2
    })
end

-- ============================================================================
-- Book-level metadata sync (handmade_toc)
-- ============================================================================
--
-- custom_metadata and the per-field book metadata (status, rating,
-- collections) are synced by the annotation orchestrator's metadata
-- bridge (`syncery_ann/metadata_bridge.lua`) — it reads them from
-- doc_settings on every sync and merges them per-field by
-- `datetime_updated`.  main.lua deliberately carries NO second writer
-- for those: per-field merge only works if a single writer owns the
-- block, otherwise the most-recent whole-block write clobbers fields it
-- never touched (the cause of the old "metadata flickers between
-- devices" behaviour).
--
-- `pushHandmadeToc` below is the one remaining explicit user action:
-- a handmade TOC is large and built once, so it is pushed on demand
-- rather than auto-synced.  It writes straight into the new engine's
-- shared state file under the `metadata.handmade_toc` field.

-- User-triggered push of the local handmade TOC to all other devices.
-- Writes the TOC into the annotation engine's shared state file under
-- `metadata.handmade_toc` so it travels via the normal sync channel.
function Syncery:pushHandmadeToc()
    -- This row is always tappable (it lives in What's Synced, not gated on
    -- document state), so handle "no book open" with a clear message.
    local state = self.ui and self.ui.doc_settings and self:getCurrentState()
    if not state then
        UIManager:show(InfoMessage:new{
            text = _("Open a book first to push its handmade table of contents."),
            timeout = 3,
        })
        return
    end

    -- Reject on paging docs upfront — the xpointers in a handmade TOC are
    -- meaningless on PDF/CBZ and would corrupt anything we wrote there.
    if self.ui.paging then
        UIManager:show(InfoMessage:new{
            text = _("Handmade TOC uses text positions that only work on " ..
                     "reflowable documents (EPUB, FB2). This PDF or image " ..
                     "document cannot share a TOC."),
            timeout = 4,
        })
        return
    end

    -- Read the live handmade TOC — the list KOReader actually renders —
    -- falling back to the persisted handmade_toc doc-setting.  (NOT the
    -- phantom "handmade" key, which KOReader never populates.)
    local toc = self.ui.handmade and self.ui.handmade.toc
    if type(toc) ~= "table" or #toc == 0 then
        toc = self.ui.doc_settings:readSetting("handmade_toc")
    end
    if type(toc) ~= "table" or #toc == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No handmade table of contents found for this book."),
            timeout = 2,
        })
        return
    end

    -- Load the shared state, inject the TOC into the metadata section
    -- (the v2 shape: { value = ..., datetime_updated = "local wall-clock" }),
    -- and write it back atomically via the engine's state store.
    local shared = AnnStateStore.load_shared(state.file)
    shared.metadata = shared.metadata or {}
    shared.metadata.handmade_toc = {
        value            = toc,
        datetime_updated = AnnTimeFormat.now(),
    }

    local ok = AnnStateStore.save_shared(state.file, shared)
    if ok then
        -- Own-push echo is handled receive-side by _apply_handmade_toc's
        -- content guard (it no-ops when the live TOC already matches), so
        -- no separate timestamp record is needed here.
        if self.use_syncthing then
            -- best-effort scan trigger so Syncthing picks up the change
            pcall(function() self:_doTriggerScan(state) end)
        end
        UIManager:show(InfoMessage:new{
            text = _("Handmade TOC will sync to other devices on next sync."),
            timeout = 2,
        })
    else
        UIManager:show(InfoMessage:new{
            text = _("Could not save handmade TOC for sync."),
            timeout = 3,
        })
    end
end

-- Persist the local reading position via the progress orchestrator,
-- which does the whole save flow in one call:
--
--   1. Resolves any `*.sync-conflict-*` files that Syncthing may have
--      dropped next to the shared progress JSON.
--   2. Reads the live position via `ProgressBridge.read_from_live`.
--   3. Reads the shared file and the local last-sync ancestor.
--   4. Applies the WIPE FAILSAFE — refuses to persist a `percent=0,
--      page=1` entry on top of real remote progress (the "progress
--      reset to chapter 1 after suspend" failure mode).
--   5. Stamps a fresh `(revision, timestamp)` and runs a 3-way merge
--      against remote + last-sync, so entries from devices we haven't
--      seen in a while are preserved instead of being clobbered by
--      our local view.
--   6. Atomically writes the merged state to both the shared file and
--      the last-sync ancestor.
--
-- Three things this function deliberately does NOT do:
--
--   * It does not stamp `status`, `rating`, `collections` on the
--     entry.  Those fields are book-level metadata and live in the
--     annotations file's `metadata` section; keeping two writers for
--     the same fields caused cross-device flicker.
--   * It does not bump-and-save its own revision if the orchestrator
--     decided to skip (e.g. wipe failsafe).  Stamping a new revision
--     unconditionally could push a "you're at the start" entry over a
--     real "you're 60% in" one.
--   * It does not call `_pruneStaleProgress` afterwards.  Pruning is
--     destructive in a way Syncthing can undo — re-syncing the entry
--     from a device that hadn't checked in lately produces a
--     delete-resurrect-delete cycle.  We keep every entry in the shared
--     file and use `ProgressBridge.filter_fresh_for_display` as a
--     view-only filter for the UI.
function Syncery:_writeSave(state, now, silent, trigger)
    if not self.sync_progress then return true end

    local sync_result = ProgressOrchestrator.sync_book(self.ui, state.file, {
        device_id     = self.device_id,
        device_label  = self.device_label or Util.get_device_label(),
        sync_progress = true,
    })

    -- Journal the progress sync under kind="progress",
    -- BEFORE the early returns below, so a skipped (wipe failsafe) or failed
    -- sync is still recorded -- a journal that only logs successful pushes
    -- cannot answer "did progress even sync for this book?".  record_progress
    -- drops a PURE noop at its own write site (nothing pushed, no conflict),
    -- so the every-autosave cadence does not flood the ring.  Best-
    -- effort and pcall-isolated: a diagnostic writer must never break the
    -- save pipeline it observes.  Transport is the sync context (Syncthing
    -- and cloud are independent; both can be on), not a transport identity.
    local journal_transport = Util.transport_label(self.use_syncthing, self.use_cloud)
    pcall(function()
        SyncJournal.record_progress(
            AnnPaths._book_content_id(state.file),
            sync_result,
            journal_transport,
            { max_entries         = self.journal_max_entries,
              writer_device_label = self.device_label,
              trigger             = trigger })
    end)

    if sync_result.error then
        logger.warn("Syncery: progress sync failed for "
            .. tostring(state.file) .. ": " .. tostring(sync_result.error))
        return false
    end

    if sync_result.skipped then
        -- The wipe failsafe triggered: live state looks unloaded
        -- (percent=0, page<=1) while the remote has real progress.
        -- This is not a save failure — KOReader's document just hasn't
        -- finished loading yet.  The next save attempt a few seconds
        -- later will succeed with the real position.  Don't surface a
        -- scary "save failed" toast; log and return true.
        logger.info("Syncery: progress save deferred ("
            .. tostring(sync_result.skipped_reason) .. ")")
        return true
    end

    -- (No own_revision cache here: jump-prompt gating lives in
    -- syncery_ui/jump_policy.lua, not in a save-count comparison.)
    self.last_save_time = now

    if not silent then
        UIManager:show(InfoMessage:new{
            text = string.format(_("Syncery: saved at page %d (%.0f%%)"),
                state.page or 1, (state.percent or 0) * 100),
            timeout = 1.5
        })
    end

    -- If we merged conflict files in, the shared file now contains
    -- data that other devices haven't seen yet.  Poke Syncthing so it
    -- propagates the resolved file instead of waiting for the next
    -- periodic scan.  Best-effort: this is a hint, not a guarantee.
    if sync_result.conflicts_merged > 0 and self.use_syncthing then
        pcall(function() self:_doTriggerScan(state) end)
    end

    return true
end

-- The single source of truth for "should a non-forced autosave be
-- suppressed right now?". ORs the two independent block mechanisms (see
-- the init list): the indefinite boolean (cancelPendingSync's reset
-- block) and the self-healing window (the post-jump suppression). Both
-- main.lua's _save gate and the lifecycle's schedule_auto_save consult
-- this same logic, so the three readers can never disagree.
function Syncery:_isAutosaveBlocked()
    if self.blocking_autosave then return true end
    return (self.blocking_autosave_until or 0) > os.time()
end

function Syncery:_save(opts)
    if self.destroyed or self.is_saving then return end
    if self:_isAutosaveBlocked() and not opts.force then return end

    local state = self:getCurrentState()
    if not state or not self:_isFileTypeSynced(state.file) then return end

    if not opts.force
       and (os.time() - (self.last_save_time or 0)) < self.min_save_interval then
        return
    end

    self.is_saving = true

    local ok, err = pcall(function()
        local saved = self:_writeSave(state, Util.now(), opts.silent, opts.trigger)

        -- Annotation back-sync: a single orchestrator call handles
        -- pull + merge + push, including bookmarks (modern KOReader
        -- stores bookmarks as type="bookmark" entries inside the
        -- annotations list).  Gated on the envelope toggles, mirroring
        -- the checkRemote pull gate: the orchestrator owns the shared
        -- annotations.json, so running it with annotations + metadata +
        -- render ALL off would write an empty envelope for a book the
        -- user opted out of syncing.  Progress has its own path below,
        -- so this gate does not touch it.  (The any-on case is unchanged
        -- — e.g. metadata-on already drives the orchestrator today.)
        if self.sync_annotations or self.sync_metadata or self.sync_render_settings then
            self:_syncBookViaOrchestrator(state, { trigger = opts.trigger or "save" })
        end

        if not saved then return end

        -- Auxiliary transport runs regardless of Syncthing: it's a
        -- complement to it, not a replacement.  The helper no-ops cheaply
        -- when its toggle is off.
        if opts.trigger_sync then
            self:_scheduleCloudUpload(state)
        end

        if not opts.trigger_sync or not self.use_syncthing then return end
        if not self:_syncthingFolderConfigured() then return end

        -- Compute sub_dir via _getScanTarget (which reads from
        -- Settings when no cfg is passed).  The bridge dispatches via
        -- the orchestrator; retries and reachability checks live there
        -- now.
        local _folder_id, sub_dir = self:_getScanTarget(state.file, nil)
        if self._transport then
            self._transport:push_syncthing_scan(state.file, { sub = sub_dir })
        end
    end)

    self.is_saving = false
    -- No blocking_autosave clear here, deliberately. The jump window
    -- (blocking_autosave_until) lapses on its own, so a save must NOT be
    -- the thing responsible for un-blocking — an early return above would
    -- then strand the flag. And the INDEFINITE block set by cancelPendingSync
    -- must outlive saves (it guards a destructive reset), so clearing it
    -- here would be wrong regardless.

    if not ok then
        logger.warn("Syncery: _save error:", tostring(err))
    end
end

function Syncery:_debouncedScan(opts)
    -- _debouncedScan does ONE thing: schedule (or, if `force`,
    -- immediately fire) a Syncthing scan trigger.  It must NOT persist
    -- or run annotation/cloud work — _save already did that right before
    -- calling here, so doing it again would be duplicate work.
    if self.destroyed then return end

    local state = self:getCurrentState()
    if not state or not self:_isFileTypeSynced(state.file) then return end

    local trigger_now = opts and opts.force
    if trigger_now then
        if self._debounce_scan_action then
            UIManager:unschedule(self._debounce_scan_action)
            self._debounce_scan_action = nil
        end
        self:_doTriggerScan(state)
    else
        if self._debounce_scan_action then
            UIManager:unschedule(self._debounce_scan_action)
        end
        self:_schedule("_debounce_scan_action", 10, function()
            self:_doTriggerScan(state)
        end)
    end
end

-- True when the Syncthing side has a folder to sync.  The KOSyncthing+ provider
-- self-discovers its folders, so it is always configured; otherwise the user
-- must have chosen a folder (a stored folder record) or set a real folder id.
-- Pre-pick on a fresh manual setup this is false, so the per-event scan
-- triggers skip the push instead of scanning a meaningless "default".
function Syncery:_syncthingFolderConfigured()
    return ScanTarget.is_folder_configured(
        rawget(_G, "KOSyncthingPlusAPI") ~= nil,
        Settings.get_syncthing_folder_id(),
        Settings.get_syncthing_folder())
end

-- opts.force (terminal close-push): bypass the orchestrator's debounce/backoff
-- so the last-chance scan before transport shutdown isn't dropped as in_backoff.
function Syncery:_doTriggerScan(state, opts)
    if not self.use_syncthing then return end
    if not self._transport then return end
    if not self:_syncthingFolderConfigured() then return end

    -- No daemon-up gate here, deliberately.  The orchestrator's
    -- transport.is_available() check covers the same ground (the
    -- Syncthing transport asks the KOSyncthing+ provider's status when
    -- present, falls back to the manual provider's reachability cache
    -- otherwise), and the orchestrator's Policy layer handles the
    -- "don't pile retries on a known-down daemon" backoff — so a manual
    -- reachability short-circuit here would be redundant.
    --
    -- Sub-dir is still computed here because it depends on Syncery's
    -- own folder config (`_getScanTarget` resolves the book against the
    -- user's chosen folder).  The transport doesn't know about that.
    -- Folder config now comes from `Settings.get_syncthing_folder`
    -- via `_getScanTarget`'s nil-cfg branch.
    local folder_id, sub_dir = self:_getScanTarget(state.file, nil)
    self._transport:push_syncthing_scan(state.file,
        { sub = sub_dir, force = opts and opts.force })

    -- Conflict-file suppression rides along here (NOT at startup).  We write
    -- Syncthing's `.stignore` at the folder root so conflict copies don't
    -- replicate; the daemon reads the file on its next scan.  This is a LOCAL
    -- file write — no network, so it can never block the UI (unlike the old
    -- synchronous REST register that caused the startup white-screen lag).
    -- When the folder root isn't known (no folder chosen yet) it silently does
    -- nothing.  See syncery_transports/stignore.lua.
    pcall(function()
        Stignore.ensure_for_folder(folder_id, Settings.get_syncthing_folder)
    end)
end

-- ============================================================================
-- kosyncthing_plus integration
--
-- When the user has the kosyncthing_plus plugin installed, we hook into
-- its public API for three benefits:
--
--   1. Suppress our own conflict files from KOSyncthing+'s user-visible
--      counter (we resolve them in RAM, the user shouldn't see them
--      "pending"). Done via IgnoreRegistry at startup; nothing else
--      to do per-event.
--
--   2. React instantly to `process_started`: when the syncthing
--      daemon comes up, drain any retry-queue entries that have been
--      waiting for it.  Otherwise the queue would tick every 10 s,
--      which is fine but always a bit slower than necessary.
--
--   3. React instantly to `conflicts_changed`: as soon as the plugin
--      sees a new conflict file land on disk, give Syncery's own
--      resolver a chance to handle it.  Without this hook, the user
--      would have to open a book before Syncery noticed.
--
-- All entrypoints are no-ops when KOSyncthing+ isn't installed.
-- ============================================================================

-- ============================================================================
-- KOSyncthing+ integration
--
-- This does ONE thing at startup: hide Syncery's own conflict files
-- from KOSyncthing+'s conflict SCANNER (the Conflicts badge/menu), via
-- `IgnoreRegistry:register` — an in-process call gated on the
-- CONFLICT_IGNORE_REGISTRY capability (KOSyncthing+ only).
--
-- It deliberately does NOT do several things you might expect here:
--   • The DAEMON-side `.stignore` (which stops conflict COPIES from
--     replicating) is written by the non-blocking file writer on the
--     scan path, NOT here — a synchronous setFolderIgnore REST call at
--     startup blocks the UI against an unreachable daemon.
--   • Reachability is read fresh by the transport's `is_available` on
--     every call (no cache to refresh here), and retry backoff is the
--     orchestrator Policy layer's job — so no reachability cache or
--     retry-queue hook belongs here.
--   • There is no conflicts_changed event handler.  The cost is that
--     conflict-detection latency grows to ~the next book open / save
--     (seconds); accepted, to avoid an event-subscription surface on
--     the transport.
-- ============================================================================

function Syncery:_setupKOSyncthingPlusIntegration()
    if not self.use_syncthing then return end
    if not self._transport then return end
    -- Conflict-file suppression is handled by the NON-BLOCKING `.stignore`
    -- writer on the scan path (see _doTriggerScan + syncery_transports/
    -- stignore.lua), NOT by a synchronous REST call here.  The old REST
    -- `register_syncery_ignore_patterns()` call blocked the UI thread for
    -- ~4-10s against an unreachable daemon on every launch (the startup
    -- white-screen lag).  The `.stignore` file is local, never blocks, works
    -- offline, and is durable across restarts.  (The REST register still
    -- exists for the explicit "Conflict-file integration" button, where the
    -- user initiates it and network latency is expected.)

    -- Hide Syncery's own conflict files from KOSyncthing+'s conflict SCANNER
    -- (the Conflicts badge/menu) — the scanner half, separate from `.stignore`
    -- above.  `.stignore` stops conflict COPIES from replicating, but the
    -- local `.sync-conflict-*` file still exists, so the scanner would still
    -- count/list it.  `IgnoreRegistry:register` excludes our pattern from that
    -- scan.  It is an IN-PROCESS table write (no REST, no network), so it is
    -- safe here at startup — it has none of the blocking that a
    -- synchronous REST register would impose.  Best-effort + gated: a no-op
    -- on older KOSyncthing+ without the registry, or the manual/Cloud paths.
    pcall(function()
        self._transport:register_conflict_menu_ignore()
    end)
end

function Syncery:_autoSave(silent)
    -- Periodic autosave: persist progress + flush annotations, and
    -- ask Syncthing to scan.  `_save` handles all three (persistence,
    -- auxiliary transports, scan trigger) in one place — do NOT also
    -- call _debouncedScan here, which would redo _save's work.
    self:_save({
        silent       = silent,
        trigger_sync = true,
        force        = false,
        trigger      = "autosave",
    })
end

function Syncery:doSave(silent, trigger_sync)
    local now = os.time()
    if (now - (self.last_manual_save or 0)) < self.save_now_cooldown then
        -- Already synced very recently; silently ignore duplicate tap.
        return
    end
    self.last_manual_save = now
    self:_save({
        silent       = silent,
        trigger_sync = trigger_sync ~= false,  -- default true for manual save
        force        = true,                   -- bypass min_save_interval
        trigger      = "manual",
    })
end

-- ============================================================================
-- Annotation sync engine — orchestrator entry point
-- ============================================================================
--
-- `_syncBookViaOrchestrator` is the ONLY annotation sync path.  The
-- orchestrator runs the full 3-way merge in one pass: pulls remote,
-- merges with local + last-sync ancestor, compacts old tombstones,
-- applies the result back to KOReader, writes the merged state to the
-- shared file, saves a fresh last-sync ancestor.
--
-- Returns true when the sync produced or applied any data, false
-- otherwise, plus the full result object as a second value.

function Syncery:_syncBookViaOrchestrator(state, opts)
    if not state or not state.file then return false end
    if not self.ui or not self.ui.doc_settings then return false end
    if not self:_isFileTypeSynced(state.file) then return false end

    opts = opts or {}

    local result = Orchestrator.sync_book(self.ui, state.file, {
        device_id    = self.device_id,
        device_label = self.device_label,
        toggles = {
            annotations     = self.sync_annotations,
            highlights      = self.sync_highlights,
            notes           = self.sync_notes,
            bookmarks       = self.sync_bookmarks,
            metadata        = self.sync_metadata,
            status          = self.sync_status,
            rating          = self.sync_rating,
            collections     = self.sync_collections,
            summary         = self.sync_summary,
            custom          = self.sync_custom_metadata,
            handmade        = self.sync_handmade_toc,
            render_settings = self.sync_render_settings,
            font_face       = self.sync_font_face,
            font_size       = self.sync_font_size,
            line_spacing    = self.sync_line_spacing,
            font_weight     = self.sync_font_weight,
            margins         = self.sync_margins,
        },
        adapt_highlight_style = self.adapt_highlight_style,
        tombstone_ttl_days    = self.tombstone_ttl_days,
    })

    -- Journal the merge event.  This happens for EVERY outcome —
    -- merged, no-op, skipped (empty), or failed — BEFORE any of the
    -- early returns below, because a journal that only records
    -- successful non-trivial merges cannot answer "did a merge even run
    -- for this book?".  See the sync_journal.lua header for the
    -- rationale.  Best-effort and pcall-isolated: a diagnostic writer
    -- must never be able to break the save pipeline it observes.
    --
    -- `transport` here is the sync context, not a transport-contract
    -- identity: this is the annotation back-sync path.  Syncthing and
    -- cloud are independent and can both be on (cloud runs alongside),
    -- so the label names whichever carried it -- or "local" when neither.
    local journal_transport = Util.transport_label(self.use_syncthing, self.use_cloud)
    pcall(function()
        SyncJournal.record_merge(
            AnnPaths._book_content_id(state.file),
            result,
            journal_transport,
            { max_entries        = self.journal_max_entries,
              writer_device_label = self.device_label,
              trigger             = opts.trigger })
    end)

    if not result.ok then
        if result.error then
            logger.warn("Syncery: orchestrator sync failed: " .. tostring(result.error))
        end
        return false
    end

    -- Tell Syncthing about the freshly-written shared file so it can
    -- propagate quickly to peers, instead of waiting for the next
    -- periodic scan.
    if (result.annotations_pushed > 0
            or result.conflicts_merged > 0
            or next(result.metadata_applied))
            and self.use_syncthing then
        pcall(function() self:_doTriggerScan(state) end)
    end

    -- Activity log entries when something interesting happened.
    if result.annotations_pulled > 0 or result.annotations_pushed > 0 then
        log_activity(string.format(
            _("Synced annotations (%d pulled, %d pushed)"),
            result.annotations_pulled, result.annotations_pushed), "")
    end
    if result.conflicts_merged > 0 then
        log_activity(string.format(
            _("Resolved %d annotation conflict(s)"), result.conflicts_merged), "")
    end

    -- Remember new incoming annotations so checkRemote can offer a non-blocking
    -- "reload to see them" affordance THIS tick.  The live list is never mutated
    -- mid-session (sync_orchestrator S1 / the inviolable rule); the merged map is
    -- delivered on the next open -- which the [Reload] button triggers.
    if result.annotations_pulled and result.annotations_pulled > 0 then
        self._pending_ann_reload = result.annotations_pulled
    end
    -- Font & layout (render) settings are in the SAME boat: copt_* were written
    -- to doc_settings (+ live Configurable state) but NOT re-rendered in-session,
    -- so the change is only visible at the next open.  Arm the same reload
    -- affordance for them.  Metadata is excluded -- it applies live (doc_props +
    -- browser-cache eviction) and needs no reload.
    if result.render_applied then
        self._pending_render_reload = true
    end

    -- Surface stats to the caller for decision-making.  `had_data`
    -- reports whether the merged state holds anything (annotations,
    -- metadata, or render settings) — callers use it for activity
    -- accounting; the orchestrator owns its own completion state.
    local had_data = (result.annotations_after > 0)
                  or (next(result.metadata_applied) ~= nil)
                  or result.render_applied
    return had_data, result
end


-- ============================================================================
-- Annotation event handlers — thin delegators into the engine
-- ============================================================================
--
-- All annotation work — diffing, id back-fill, deletion detection,
-- 3-way merge, bookmarks, book metadata — lives in the `syncery_ann/`
-- orchestrator.  KOReader routes highlight, note,
-- and bookmark changes to the plugin through two events; both handlers
-- below do the same thing: trigger a save.  The save pipeline calls
-- `_syncBookViaOrchestrator`, which reads the live annotation list out
-- of KOReader's in-memory list (`ui.annotation.annotations`, always
-- current) — doc_settings is only the bulk-ingest fallback — and runs
-- the full merge.

-- KOReader broadcasts `AnnotationsModified` with the full current
-- annotation list whenever a highlight or note is added, edited, or
-- removed.  We do not need the list itself — the orchestrator reads
-- live state directly — so this is a plain "something changed, persist
-- it" trigger.
function Syncery:onAnnotationsModified(items)
    if not self.sync_annotations then return end
    -- Coalesce a burst of annotation edits into ONE save+merge instead of a
    -- full sync_book per modification.  The window is a small fixed constant
    -- (autosave_delay, 3s): coalescing is an implementation detail, not a user
    -- tradeoff, so it is deliberately NOT tied to min_save_interval (a
    -- progress-save floor a user may raise for battery — raising it must not
    -- silently defer annotations, and at high values the per-edit re-arm would
    -- never fire mid-session).  Mirrors the bookmark path
    -- (_sync_bookmarks_action).  Loss-safe: the close/suspend teardown flush
    -- runs a final sync_book against the LIVE list before timers are cancelled,
    -- so a pending coalesce is never dropped.
    self:_schedule("_sync_annotations_action", self.autosave_delay, function()
        self:_save({ silent = true, trigger_sync = false, force = true })
    end)
end

-- Bookmark toggles arrive on their own event.  Modern KOReader stores
-- bookmarks as type="bookmark" entries inside the annotation list, so
-- the orchestrator picks them up on the same merge pass; we just need
-- to schedule a save.
function Syncery:onToggleBookmark()
    -- Mirror onAnnotationsModified's gate: with annotation sync off (master),
    -- a bookmark toggle must not force a save+merge.  (The sub-toggles are
    -- aggregate in the engine -- _annotations_enabled is master AND at least
    -- one sub -- so the master is the correct gate here, exactly as for the
    -- highlight/note path; per-type bookmark filtering is a separate concern.)
    if not self.sync_annotations then return end
    self:_schedule("_sync_bookmarks_action", 0.5, function()
        self:_save({ silent = true, trigger_sync = false, force = true })
    end)
end

-- ============================================================================
-- Remote Checking
-- ============================================================================

--- If this checkRemote tick applied changes that are only VISIBLE at the next
--- open (and no position jump pre-empted), offer a NON-blocking "reload to see
--- them" bar.  Two sections qualify, and they share this one affordance:
---   * annotations -- the live list is never mutated mid-session
---     (sync_orchestrator S1 / the inviolable rule); the merged map is staged
---     into doc_settings at close and loaded by the reopen's onReadSettings.
---   * font & layout (render) -- copt_* are written to doc_settings (+ the live
---     Configurable state) but NOT re-rendered in-session, so the new font /
---     spacing / margins only take effect at the next open.
--- Metadata is deliberately NOT here: it applies LIVE (doc_props updated, the
--- coverbrowser cache evicted), so it needs no reload.
--- [Reload] triggers ReaderUI:reloadDocument -- its onClose runs saveSettings
--- (Syncery stages the merged annotation map; KOReader's ReaderConfig saves the
--- live copt_ state) and the reopen loads BOTH.  Ignoring the bar is safe: every
--- pending change still arrives on the next ordinary close+open; the bar is only
--- an early-delivery shortcut.  The text names exactly which section(s) changed.
function Syncery:_maybeOfferReload()
    local ann_count = self._pending_ann_reload
    local render    = self._pending_render_reload
    self._pending_ann_reload = nil
    self._pending_render_reload = nil
    local has_ann = ann_count ~= nil and ann_count > 0
    if not has_ann and not render then return end
    if not (self.ui and self.ui.reloadDocument) then return end

    local text
    if has_ann and render then
        text = _("New annotations and font & layout from another device")
    elseif has_ann then
        text = string.format(
            _n("%d new annotation from another device",
               "%d new annotations from another device", ann_count), ann_count)
    else
        text = _("New font & layout from another device")
    end

    -- Shared action: reopen the document to apply the synced content.
    local function do_reload()
        -- If a position-jump bar is still showing alongside this reload
        -- bar, hand its identity to the reopened document (see the
        -- _pending_jump_handoff slot + checkRemote ── 3a).  reloadDocument
        -- loses the pending jump (new instance) and its reopen re-stamps
        -- our recency, so the reopened pick_jump_target would otherwise
        -- rank US most-recent and drop the still-valid jump.  Covers
        -- annotation, render, or both -- this is the one reload bar.
        if self._shown_jump then _pending_jump_handoff = self._shown_jump end
        if self.ui and self.ui.reloadDocument then
            self.ui:reloadDocument()
        end
    end

    -- lane 1: the reload bar stacks ABOVE the jump bar (lane 0) and shows
    -- alongside it -- they are independent axes (content vs position), so there
    -- is no queuing/sequencing.  Both visible at once; the user acts on each
    -- freely (e.g. [Jump] adopts the position with no reopen, then [Reload]).
    -- ActionBar.show self-degrades on non-touch to a focusable, auto-dismissing
    -- dialog with [Reload] focused (the touch-zone button is unreachable there).
    ActionBar.show(self.ui, {
        text = text,
        button_label = _("Reload"),
        on_action = do_reload,
        seconds = 12,  -- all action bars share a uniform 12s dwell
        lane = 1,
    })
end


function Syncery:checkRemote()
    if self.destroyed or self.is_saving or self.sync_state == "syncing" or self._active_sync_box then
        return
    end

    local state = self:getCurrentState()
    if not state or not self:_isFileTypeSynced(state.file) then return end

    -- The "new annotations -- reload" offer is decided fresh each tick: the
    -- orchestrator path below sets it if it pulls anything; the jump section
    -- consumes it (offering the bar only when no position jump pre-empts).
    -- Reset here so a stale offer from a previous tick can't leak through.
    self._pending_ann_reload = nil
    self._pending_render_reload = nil

    -- The jump shown (if any) THIS tick, captured for the reload handoff:
    -- cleared fresh each tick so a stale target from a previous tick can never
    -- be stashed when [Reload] is tapped.  Set below once a jump bar goes up;
    -- cleared again the moment that jump is taken or dismissed.
    self._shown_jump = nil

    -- ── 1. Resolve any Syncthing conflict files ────────────────────
    --
    -- Progress and annotation conflicts use different resolvers because
    -- the files have different shapes (per-device map vs. position-keyed
    -- annotation map with three sections).  Both run regardless of the
    -- annotation-engine flag; the progress resolver is universal now.
    local progress_seen, progress_merged = ProgressConflictResolver.resolve_all(state.file)
    if progress_merged > 0 then
        log_activity(_("Resolved progress conflicts"), "")
        if self.use_syncthing then self:_doTriggerScan(state) end
    end

    -- ── 2. Annotation back-sync via the orchestrator ───────────────
    --
    -- Run the merge when the shared annotation file's mtime has
    -- changed since we last looked, or when we have not synced this
    -- book yet this session (mtime cache still 0).  The orchestrator
    -- owns conflict-file resolution for annotations internally.
    --
    -- MtimeGate re-reads the mtime AFTER the merge (which writes the file only
    -- when its content changed -- JsonStore.write is skip-if-unchanged) so the
    -- cache reflects the file's real post-merge mtime; caching the pre-merge
    -- value made the next tick re-run the merge for nothing.  See
    -- syncery_ann/mtime_gate.
    -- The shared annotation envelope carries THREE independent sections --
    -- annotations, metadata, render_settings -- each with its own master
    -- toggle.  Gate the remote-check pull on ANY of them, not just
    -- sync_annotations: with annotations off but metadata or render on, the
    -- orchestrator (which respects each toggle internally) must still run on
    -- open/resume to pull those sections.  (_save runs the orchestrator
    -- unconditionally during reading, so this only closed the open-moment
    -- pull gap; broadening makes the gate match the envelope contents.)
    if self.sync_annotations or self.sync_metadata or self.sync_render_settings then
        local ann_path  = AnnPaths.shared_annotations_path(state.file)
        local ann_mtime = (ann_path and Util.file_mtime(ann_path)) or 0
        self._ann_mtime_cache = MtimeGate.run(
            ann_mtime, self._ann_mtime_cache,
            function() self:_syncBookViaOrchestrator(state, { trigger = "remote_check" }) end,
            function() return (ann_path and Util.file_mtime(ann_path)) or 0 end)
    end

    -- ── 3. Read the shared progress file ────────────────────────────
    --
    -- Find the FORWARD jump candidate: JumpPolicy.pick_jump_target ranks all
    -- fresh entries (including our own) by RECENCY and returns the most recent
    -- OTHER device only if it read more recently than us — i.e. a forward
    -- jump.  If we are the most-recently-read, it returns nil (offering an
    -- older device would be a backward jump, suppressed by default).  Not by
    -- per-device revision/save-count, not by furthest-%.  (Staleness
    -- filtering is a separate view-time concern: a device idle 90 days
    -- tells us nothing.)
    local shared = ProgressStateStore.load_shared(state.file)
    local fresh  = ProgressBridge.filter_fresh_for_display(shared.entries)

    -- ── 3a. Reload handoff: re-offer a jump dropped by [Reload]-first ──
    --
    -- If [Reload] was tapped while a jump bar was still up, its identity was
    -- stashed in _pending_jump_handoff before reloadDocument's close+reopen.
    -- The reopen re-stamps our own recency, so pick_jump_target below would now
    -- rank US as most-recent and return nil -- silently dropping a jump that is
    -- STILL valid.  Take the slot and re-offer it, bypassing ONLY that recency
    -- suppression: we re-read the device's CURRENT target from `fresh` and
    -- re-validate it through should_prompt, so a handoff that has gone stale
    -- (we caught up, or the remote moved on) self-corrects instead of replaying
    -- an outdated jump.  Single-shot -- taking it clears the slot.  File-matched
    -- so a slot left by a different book can't fire here.  (Own acked nil-guard:
    -- this runs before the one below, which guards the normal path.)
    self.acked_remote_revs = self.acked_remote_revs or {}
    local handoff = nil
    if _pending_jump_handoff and _pending_jump_handoff.file == state.file then
        handoff = _pending_jump_handoff
        _pending_jump_handoff = nil  -- single-shot
    end
    if handoff then
        local entry = fresh[handoff.device_id]
        if entry and JumpPolicy.should_prompt(
                entry, handoff.device_id, self.acked_remote_revs,
                state.percent, state.xpath) then
            local hd_id  = handoff.device_id
            local hd_rev = entry.revision or 0
            local shown  = self:_promptJump{
                state        = state,
                r_page       = entry.page    or 1,
                r_percent    = entry.percent or 0,
                r_xpath      = entry.xpath,
                r_timestamp  = entry.timestamp,
                remote_label = entry.label or _("Another device"),
                transport    = _("Syncthing"),
                on_jump      = function()
                    self.acked_remote_revs[hd_id] = hd_rev
                    self._shown_jump = nil
                end,
                on_dismiss   = function()
                    self.acked_remote_revs[hd_id] = hd_rev
                    self._shown_jump = nil
                end,
            }
            if shown then
                self._shown_jump = { file = state.file, device_id = hd_id }
            end
            -- The reload that produced this handoff already delivered its
            -- content, so there is no pending reload to offer this tick.
            return
        end
        -- Stale handoff (caught up / no substantive delta): fall through to the
        -- normal path, which finds no forward jump and offers nothing.
    end

    local best, best_device_id = JumpPolicy.pick_jump_target(fresh, self.device_id)
    if not best then
        -- No forward jump this tick -- offer the annotation reload instead.
        self:_maybeOfferReload()
        return
    end

    -- Conscious nil-guard: checkRemote only runs after onReaderReady (which
    -- (re)initialises the map per book), but guarantee the map exists before
    -- we read OR write it, so a stray early call can never nil-index.
    self.acked_remote_revs = self.acked_remote_revs or {}

    -- Should we interrupt the read with a jump prompt?  Pure, unit-tested
    -- policy in syncery_ui/jump_policy.lua: re-prompt suppression (PER
    -- DEVICE, by revision — not by comparing our own save-count against a
    -- remote's) AND a substantive percent/xpath delta.
    if not JumpPolicy.should_prompt(
            best, best_device_id, self.acked_remote_revs,
            state.percent, state.xpath) then
        -- Jump suppressed (already acked / no substantive delta) -- offer the
        -- annotation reload instead.
        self:_maybeOfferReload()
        return
    end

    local r_rev = best.revision or 0

    -- Hand off to the unified prompt.  It returns true when it actually raises
    -- a jump affordance (the "ask" invite or the "auto" confirm bar) and false
    -- when it declines.  In this context "declines" means only "never" mode:
    -- checkRemote's entry guard already excluded the syncing / active-box
    -- cases, and `state` is non-nil here, so those _promptJump guards cannot
    -- fire.  on_jump / on_dismiss record the acknowledged remote revision PER
    -- DEVICE so we don't re-prompt for the same state next tick.  Both ack:
    -- Stay = "saw it, chose to stay"; Jump = "took it".  (best_device_id is
    -- guaranteed non-nil here -- pick_best sets entry and id together.)
    local jump_shown = self:_promptJump{
        state        = state,
        r_page       = best.page    or 1,
        r_percent    = best.percent or 0,
        r_xpath      = best.xpath,
        r_timestamp  = best.timestamp,
        remote_label = best.label or _("Another device"),
        transport    = _("Syncthing"),
        on_jump      = function()
            self.acked_remote_revs[best_device_id] = r_rev
            self._shown_jump = nil  -- took it: nothing to re-offer after a reload
        end,
        on_dismiss   = function()
            self.acked_remote_revs[best_device_id] = r_rev
            self._shown_jump = nil  -- dismissed (timeout / [✕]): do not re-offer
        end,
    }

    -- Capture the showing jump for the reload handoff: if [Reload] is tapped
    -- while this bar is still up, _maybeOfferReload's handler stashes this so
    -- the reopened document re-offers it (see ── 3a above).  Cleared on
    -- jump/dismiss (closures above) and fresh each tick (top of checkRemote).
    if jump_shown then
        self._shown_jump = { file = state.file, device_id = best_device_id }
    end

    -- Offer the annotation / font & layout reload regardless of whether a jump
    -- bar went up.  _maybeOfferReload -> ActionBar.defer: with a jump bar in the
    -- slot the reload is QUEUED behind it and appears when that bar settles
    -- (tap/timeout) -- the single slot transitions jump -> reload; with no jump
    -- bar (incl. "never" mode) it shows immediately.
    --
    -- Previously a shown jump bar DROPPED the pending reload ("they arrive at the
    -- next open anyway").  But a device reading on the SAME open re-fires the
    -- jump every checkRemote tick, re-dropping the reload each time, so the
    -- "N new annotations -- reload" bar NEVER appeared in-session and the
    -- receiving side re-pulled the same annotations on every close: the live
    -- ui.annotation list (HARD RULE: Syncery never mutates it) was never
    -- refreshed because the user was never offered the reload that triggers it.
    self:_maybeOfferReload()
end

-- ============================================================================
-- Event Hooks
-- ============================================================================

function Syncery:onPageUpdate() self:scheduleAutoSave() end
function Syncery:onPosUpdate()  self:scheduleAutoSave() end

-- ============================================================================
-- Lifecycle event handlers (delegated to syncery_lifecycle)
--
-- The bodies of these methods live in syncery_lifecycle/
-- (init.lua, teardown.lua, timers.lua).  The methods on Syncery: stay
-- as one-line delegators because KOReader's event-dispatcher reaches
-- for them by name on the plugin object — they have to be defined
-- here, even if all they do is forward to self._lifecycle.
--
-- The original full prose lives in syncery_lifecycle/README.md and at
-- the top of each module.
-- ============================================================================

function Syncery:_flushPersistedState(opts)
    if not self._lifecycle then return end  -- defensive: pre-init paths
    self._lifecycle:teardown(opts)
end

function Syncery:onCloseDocument()
    ActionBar.dismiss(self.ui)  -- cancel any open action bar (timer + touch zone)
    self._lifecycle:on_close_document()
end
function Syncery:onSuspend()
    self._lifecycle:on_suspend()
end
function Syncery:onResume()         self._lifecycle:on_resume()          end
function Syncery:onPowerOff()       self._lifecycle:on_power_off()       end
function Syncery:onQuit()           self._lifecycle:on_quit()            end

-- Network transitions feed the cloud-reachability verdict (see
-- _cloud_reachability).  A disconnect makes it unreachable instantly with no
-- I/O; a connect drops it to "unknown" and re-verifies with a non-blocking
-- probe.  KOReader broadcasts these on every link change (NetworkConnected /
-- NetworkDisconnected in ui/network/manager).  Guarded for the (impossible in
-- prod, defensive) case the instance is absent.
function Syncery:onNetworkConnected()
    if self._cloud_reachability then
        self._cloud_reachability:on_network_connected()
    end
end
function Syncery:onNetworkDisconnected()
    if self._cloud_reachability then
        self._cloud_reachability:on_network_disconnected()
    end
end

-- Instance-facing wrapper over the module-level DB-sync timer so menu rows
-- (which hold the plugin instance, not the module locals) can drive it.
-- Reconciles the timer with the current settings (enabled + interval): drop any
-- pending tick, then arm afresh if the master is on.  The master toggle calls it
-- on change (ON -> arms; OFF -> the arm no-ops, so it stops), and the interval
-- row calls it so a new cadence takes effect now rather than next cycle.
function Syncery:_rearmDbSyncTimer()
    _disarmDbSyncTimer()
    _armDbSyncTimer()
end

-- Surface the ONE actionable DB-sync issue (something the user can fix: no cloud
-- server set, or the Cloud storage+ plugin off) as a toast.  Deliberate or
-- transient non-firing reasons stay silent.  `always` (a manual Sync now)
-- surfaces every time the user asks; the periodic tick (always=false) de-dupes
-- on a module-level signature so a persistent issue toasts once per session, not
-- every interval.  Nothing actionable -> clear the signature so a later
-- recurrence surfaces again.
function Syncery:_surfaceDbSyncReport(report, always)
    local summary = DbSync.actionable_summary(report)
    if not summary then
        _db_sync_last_surfaced = nil
        return
    end

    local label = { statistics = _("Statistics"), vocabulary_builder = _("Vocabulary") }
    local signature, msg
    if summary.kind == "cloudstorage_absent" then
        signature = "cloudstorage_absent"
        msg = _("Vocab & Statistics not synced: enable the Cloud storage+ plugin.")
    else  -- "no_server"
        signature = "no_server:" .. table.concat(summary.dbs, ",")   -- ids: locale-stable
        local names = {}
        for _, id in ipairs(summary.dbs) do names[#names + 1] = label[id] or id end
        msg = string.format(_("Not synced (no cloud server set): %s"),
            table.concat(names, ", "))
    end

    if not always and signature == _db_sync_last_surfaced then
        return   -- tick: this exact issue was already surfaced this session
    end
    _db_sync_last_surfaced = signature
    Notify.notifyL2(msg)
end

-- Tier 2: when the unify sub-toggle is ON, point the stats and vocab plugins at
-- Syncery's OWN cloud server (mutating their live settings field by reference --
-- design §11.3) so all three sync to one place.  Idempotent + change-detected:
-- a no-op when a plugin already points at the target; on a genuine change it
-- overwrites the field and drops that DB's stale `.sync` so the next sync is a
-- clean full re-sync.  Runs only for plugins that are LOADED (their settings
-- table exists); an FTP or unset target is refused by ConfigUnify.decide.  Both
-- gates (master + unify) are checked here, so callers may invoke it freely.
function Syncery:_unifyDbSyncConfig()
    if not Settings.get_db_sync_enabled() then return end   -- master gate
    if not Settings.get_db_sync_unify()   then return end   -- Tier 2 opt-in (default OFF)
    if not G_reader_settings then return end
    local ui = self.ui
    if not ui then return end
    local target = Settings.get_cloud_server()
    for _, db in ipairs(DbSync.DBS) do
        if ui[db.ui_key] then                                -- plugin loaded -> its settings table exists
            local tbl = G_reader_settings:readSetting(db.id) -- the plugin's live table (held by reference)
            if type(tbl) == "table" then
                local decision = ConfigUnify.decide(target, tbl[db.server_field])
                if decision.action == "write" then
                    local copy = {}                          -- shallow copy: don't alias Syncery's own descriptor
                    for k, v in pairs(target) do copy[k] = v end
                    tbl[db.server_field] = copy
                    if decision.drop_sync then
                        os.remove(DataStorage:getSettingsDir() .. "/" .. db.db_file .. ".sync")
                    end
                end
            end
        end
    end
end

-- Close-time annotation delivery (G).  Fires on EVERY doc_settings save, so it
-- guards _lifecycle (high-frequency, may precede init on edge paths) and is a
-- cheap no-op unless a destroying teardown stashed a merged list.
function Syncery:onSaveSettings()
    if not self._lifecycle then return end
    self._lifecycle:on_save_settings()
end

function Syncery:onSynceryUndoJump()  self:_undoLastJump() end

function Syncery:onFlushSettings()
    self._lifecycle:on_flush_settings()
end

function Syncery:scheduleAutoSave()
    if not self._lifecycle then return end
    self._lifecycle:schedule_auto_save()
end

function Syncery:syncNow()
    -- Trigger the sibling plugins' own cloud sync first (Statistics /
    -- Vocabulary Builder).  Transport-independent (they use their own cloud, not
    -- Syncery's) and inert when the DB-sync master is OFF -- safe to run before
    -- the transport guards below.
    local _ok_dbrun, _db_report = pcall(DbSync.run, { ui = self.ui, settings = Settings, gset = G_reader_settings, send_event = _dbSyncSendEvent })
    if _ok_dbrun then self:_surfaceDbSyncReport(_db_report, true) end   -- manual -> always answer
    -- Guard the silent no-op cases: "Sync now" is reachable by tap and by
    -- gesture, and with no transport (or nothing enabled to sync) the work
    -- below would do nothing visible.  Tell the user why instead of staying mute.
    if not self.use_syncthing and not self.use_cloud then
        UIManager:show(InfoMessage:new{
            icon    = "notice-info",
            text    = _("No sync transport is set up yet.\n\n"
                     .. "Open Transports to set up Syncthing or cloud storage, "
                     .. "then Sync now can push your changes to your other devices."),
            timeout = 5,
        })
        return
    end
    if not (self.sync_progress or self.sync_annotations or self.sync_metadata) then
        UIManager:show(InfoMessage:new{
            icon    = "notice-info",
            text    = _("Nothing is turned on to sync yet.\n\n"
                     .. "Open \"What's synced\" to enable reading progress, "
                     .. "annotations, or book metadata."),
            timeout = 5,
        })
        return
    end

    -- "Sync now" is routine and expected — Level 1 (silent).
    -- The user initiated it; a toast would be noise. The result surfaces
    -- through checkRemote (which may itself raise a jump invitation).
    Notify.notifyL1("Sync now")

    -- Persist current state regardless of which transport handles the
    -- network side: the JSON files have to be on disk before any scan
    -- (ours or KOSyncthing+'s) can see them.
    self:doSave(false, true)

    -- For the actual scan trigger: when kosyncthing_plus is installed,
    -- delegate to its `quickSync`.  That's strictly better than our
    -- per-folder triggerScan because KOSyncthing+ knows about ALL of
    -- syncthing's folders, not just the active book's.  When the plugin
    -- isn't installed, `requestQuickSync()` returns false and our own
    -- triggerScan inside `_save` does the work.
    if self.use_syncthing and self._transport then
        -- Bridge proxies to the syncthing transport, which calls the
        -- plugin's quickSync when KOSyncthing+ is installed.  When
        -- only the manual provider is available, the bridge returns
        -- nil + "not supported" and the `_save` path's per-book scan
        -- (already triggered by syncNow's enclosing flow) covers it.
        pcall(function() self._transport:request_quick_sync() end)
    end

    self:_schedule("_sync_now_action", 1.0, function()
        self:checkRemote()
    end)
    if self.use_cloud then
        local state = self:getCurrentState()
        if state then self:_doCloudUpload(state) end
    end
end

function Syncery:onSynceryNow()          self:syncNow()           end
function Syncery:onSynceryRescanAll()    self:_rescanAllFolders() end
-- The sync-status panel has a menu entry; this event lets it also be
-- bound to a gesture/button.
function Syncery:onSynceryShowStatus()   self:showSyncStatus(false) end
-- Symmetry with onSynceryUndoJump: a manual FORWARD jump to the latest
-- other device, so the jump (not only its undo) can be bound to a gesture.
function Syncery:onSynceryJump()         self:_jumpToLatestDevice() end

-- The two browsers are otherwise menu-only; expose them as events so they can
-- be bound to a gesture / hardware key (the menu items below call these too).
function Syncery:onSynceryProgressBrowser()
    require("syncery_ui/progress_browser/init").show(self)
end
function Syncery:onSynceryAnnotationBrowser()
    local Viewer = require("syncery_ui/annotation_viewer/viewer_lifted")
    local v = Viewer:new{ ui = self.ui }
    if self.ui and self.ui.document then
        v:showCurrentBookNotes()
    else
        v:showAllNotes()
    end
end

-- ============================================================================
-- UI Delegates
-- ============================================================================

-- ============================================================================
-- Auxiliary transport: cloud storage
--
-- It is opt-in and runs alongside Syncthing (not instead of it).  Cloud
-- sends only reading progress, useful for hand-off to non-KOReader readers
-- like Komga or Calibre-Web.  Cloud uploads Syncery's own JSON files to a
-- Dropbox / WebDAV / FTP destination as a Syncthing-free fallback.
--
-- The save and check-remote pipelines call into the helpers below; the
-- helpers no-op cheaply when the relevant toggle is off, so wiring them
-- in unconditionally is safe.
-- ============================================================================

-- Connectivity probe shared by every offline-sync path.
--
-- Centralizes the "is the device online?" check so the sync triggers
-- below (`_doCloudUpload`, `_rescanAllFolders`) don't each inline a
-- `pcall(require, "ui/network/manager")` + `isConnected` dance.  It
-- fails OPEN (returns true) when NetworkMgr is unavailable, so a
-- missing NetworkMgr lets the sync proceed rather than blocking it.
--
-- `isConnected()` is true for ANY working connection — WiFi, mobile
-- data, Ethernet — so a device on cellular is correctly treated as
-- online (see the name note in wifi_backoff.lua).
--
-- It is also the `is_online` probe injected into `self._wifi_backoff`,
-- so the backoff scheduler and the inline guards agree by construction.
--
-- @return boolean true when online OR when connectivity can't be determined.
function Syncery:_isNetworkOnline()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr
            or type(NetworkMgr.isConnected) ~= "function" then
        -- Can't tell — fail open (treat as online).
        return true
    end
    return NetworkMgr:isConnected() and true or false
end

-- ----------------------------------------------------------------------------
-- Is the CONFIGURED CLOUD SERVER reachable right now?  Stronger than
-- `_isNetworkOnline` (which is link-only, `isConnected`): the cloud gate needs
-- real reachability, because KOReader runs the WebDAV/Dropbox transfer
-- SYNCHRONOUSLY on the UI thread — a link that's up but has no route, or a dead
-- server, freezes the UI for up to ~2 min.  But the OLD check was itself
-- synchronous (a DNS probe on every upload, ~once a minute while reading — a
-- perceptible stutter), so this now reads a CACHED async verdict instead:
--   • a cheap, NON-BLOCKING link pre-gate (`isConnected`, link state only, no
--     DNS) defers instantly when not associated — and stops a doomed cold-start
--     transfer before any event/probe has run;
--   • otherwise the verdict from `_cloud_reachability` (moved by transfer
--     outcomes, NetworkConnected/Disconnected, and a non-blocking connect probe
--     to a cached IP; DNS is kept off the probe path).
-- Fails OPEN when NetworkMgr is absent (desktop / headless) or the instance is
-- missing, exactly like before; the verdict itself fails open when its probe
-- I/O (luasocket / UIManager) is unavailable.  Syncthing keeps `_isNetworkOnline`
-- (it talks to localhost — internet reachability must NOT gate it).
function Syncery:_isCloudReachable()
    -- Cheap, NON-BLOCKING link pre-check.  `isConnected` reads link state only
    -- (no DNS, unlike the old `isOnline`), so it stays off the blocking path.
    -- Not even associated -> defer without consulting the verdict; this also
    -- avoids dispatching a doomed transfer at cold start, before any event or
    -- probe has run, when the link is already down.
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr and type(NetworkMgr.isConnected) == "function"
            and not NetworkMgr:isConnected() then
        return false
    end

    -- Otherwise consult the async reachability verdict (cached; never blocks on
    -- DNS).  The verdict is moved by transfer outcomes (note_success), the
    -- NetworkConnected/Disconnected handlers, and a non-blocking probe; see
    -- _cloud_reachability.  Absent instance (defensive) -> fail open.
    if not self._cloud_reachability then return true end
    return self._cloud_reachability:is_reachable()
end

-- ----------------------------------------------------------------------------
-- Transport glue — thin delegators into syncery_transports/plugin_sync.
--
-- The cloud upload/schedule bodies live in
-- `syncery_transports/plugin_sync.lua` (each function takes the plugin
-- as its first argument — the teardown.lua pattern).  The one-line
-- methods below keep every existing call site — `_save`, `checkRemote`,
-- `teardown.lua` — working unchanged.  `_isNetworkOnline` above stays
-- here: it is also used by `_rescanAllFolders`.
-- ----------------------------------------------------------------------------

function Syncery:_scheduleCloudUpload(state)
    return PluginSync.schedule_cloud_upload(self, state)
end

function Syncery:_doCloudUpload(state)
    return PluginSync.do_cloud_upload(self, state)
end




function Syncery:clearAnnotationCache(book_file)
    if book_file then
        _ann_count_cache[book_file] = nil
    else
        _ann_count_cache = {}
    end
end

function Syncery:_logActivity(kind, detail)
    log_activity(kind, detail)
end

function Syncery:cancelPendingSync()
    self:_cancelAllTimers()
    -- Deliberately the INDEFINITE boolean (not the self-healing window):
    -- this guards a destructive reset and must stay blocked until the
    -- caller explicitly tears down / re-initialises, not lapse on a timer.
    self.blocking_autosave = true
end

function Syncery:showSyncStatus(show_all)
    StatusUI.show(self, show_all)
end

-- The smart header's "⚠ … — tap to resolve" tap lands here (the header
-- is tappable ONLY in that actionable case).  It opens the setup for the
-- transport that actually has the problem, so "resolve" takes the user
-- where they can fix it instead of to the read-only device-positions
-- panel.  The problem transport comes from the SAME source as the header
-- text (`StatusSection.actionable_problem`), so the destination and the
-- displayed `⚠` always agree.  Required lazily to avoid a load-order
-- cycle (the menu modules require main indirectly).
function Syncery:resolveStatusProblem()
    local StatusSection = require("syncery_ui/status_section")
    local problem_id    = StatusSection.actionable_problem(self)

    if problem_id == "syncthing" then
        require("syncery_ui/menu/transport_section").showSyncthingWizard(self)
    elseif problem_id == "cloud" then
        local H = require("syncery_ui/menu/_helpers")
        if H.transport_state(H.status_snapshot(self), "cloud") == "no_backend" then
            -- Re-picking the destination can't fix a MISSING cloud backend
            -- (no "Cloud storage+" and no built-in syncservice) — point the user
            -- at enabling one instead of the destination picker.
            UIManager:show(InfoMessage:new{
                text = _("No cloud backend is available.\n\nEnable the \"Cloud storage+\" plugin (or use a KOReader build with the built-in sync service) so this destination can sync."),
            })
        else
            require("syncery_ui/menu/transport_section").pickCloudDestination(self)
        end
    else
        -- No actionable problem (shouldn't happen — the row is disabled
        -- in that case).  Fall back to the status detail rather than no-op.
        self:showSyncStatus(false)
    end
end

-- ============================================================================
-- Maintenance: Rescan All & Orphan Cleanup
-- ============================================================================

function Syncery:_rescanAllFolders()
    -- Teardown guard: the off-slot wifi_backoff retry below can
    -- re-invoke this method AFTER onCloseDocument has torn the plugin down.
    -- That retry is scheduled via UIManager:scheduleIn (an off-slot channel
    -- that cancel_all does NOT reach), so unlike the slot-driven scan path it
    -- is not cancelled by teardown.  When it fires post-teardown it would
    -- otherwise take the KOSyncthing+ Quick Sync branch, which is a DIRECT plugin-API
    -- call (request_quick_sync → quick_sync_all → api.control.quickSync) that
    -- bypasses Orchestrator:push_book and therefore the _shutdown gate —
    -- waking WiFi, triggering a daemon scan, and showing a toast over the
    -- now-closed book.  None of that loses data (the scan is push-only), but a
    -- destroyed plugin should do none of it.  Mirrors the `if self.destroyed`
    -- guard on `_save`.  The retry's in-session purpose (survive a transient
    -- WiFi drop while reading) is unaffected; destroyed is only ever set by
    -- teardown.
    if self.destroyed then return end

    -- When offline, schedule a backoff retry so the toast below ("scans
    -- will be retried automatically when you're back online") is
    -- accurate: `_wifi_backoff` re-invokes this method with exponential
    -- backoff.  The `_in_flight` guard means tapping "Rescan All"
    -- repeatedly while offline doesn't stack loops.
    if not self:_isNetworkOnline() then
        UIManager:show(InfoMessage:new{
            text = _("No network connection.\nScans will be retried automatically when you're back online."),
            timeout = 4
        })
        self._wifi_backoff:attempt{
            label = "rescan all folders",
            run   = function() self:_rescanAllFolders() end,
        }
        return
    end

    if not self._transport then
        UIManager:show(InfoMessage:new{
            text = _("Transport not initialised."), timeout = 3
        })
        return
    end

    -- Prefer KOSyncthing+'s one-shot Quick Sync when it's available: that's
    -- a single call that scans every Syncery folder the daemon knows
    -- about, exactly what "Rescan All" means.  When the KOSyncthing+ plugin
    -- isn't installed we fall back to a single manual-provider push: the
    -- manual provider's Syncthing transport scans its one configured
    -- folder, so a sentinel under that folder's root approximates a
    -- whole-folder rescan.
    local ok, err = self._transport:request_quick_sync()
    if ok then
        UIManager:show(InfoMessage:new{
            text = _("Quick sync triggered."), timeout = 3
        })
        log_activity(_("Rescan all"), "quick_sync")
        return
    end

    -- KOSyncthing+ path unavailable: fall through to a single manual-provider push.
    local folder = Settings.get_syncthing_folder()

    if not folder or type(folder.path) ~= "string" or folder.path == "" then
        -- No folder chosen (or no path).  One push of the current book hits
        -- the manual provider's "scan whole folder" REST path.
        local state = self:getCurrentState()
        if state and state.file then
            self._transport:push_syncthing_scan(state.file, { sub = nil })
            UIManager:show(InfoMessage:new{
                text = _("Scan triggered."), timeout = 3
            })
            log_activity(_("Rescan all"), "single_folder")
        else
            UIManager:show(InfoMessage:new{
                text = _("No Syncthing folders configured."),
                timeout = 3
            })
            log_activity(_("Rescan all"), "no_folders: " .. tostring(err))
        end
        return
    end

    -- The single chosen folder: a sentinel under its root triggers a
    -- daemon-side scan.  The transport reads its folder_id from the
    -- provider, not from us, so the sentinel path is all we supply.
    local sentinel = folder.path .. "/.syncery-rescan-sentinel"
    self._transport:push_syncthing_scan(sentinel, { sub = nil })

    -- A routine confirmation the user should notice but not have
    -- to dismiss — Level 2 (queued non-blocking toast).
    Notify.notifyL2(_("Scan triggered."))
    log_activity(_("Rescan all"), "single_folder")
end


function Syncery:_cleanupOrphans()
    -- Layered orphan cleanup. Works in ALL storage modes (including
    -- synceryhash) and bases the book set on home_dir, adding any
    -- configured Syncthing folders opportunistically — no folder mapping
    -- is required.
    local OrphanCleanup  = require("syncery_migration/orphan_cleanup")
    local OrphanAdapters = require("syncery_migration/orphan_adapters")

    local lfs = Util.get_lfs()
    if not lfs then
        UIManager:show(InfoMessage:new{ text = _("Filesystem access unavailable.") })
        return
    end

    local deps = OrphanAdapters.build_deps({ lfs = lfs })
    local ok, result = pcall(OrphanCleanup.scan, deps)
    if not ok or type(result) ~= "table" then
        UIManager:show(InfoMessage:new{
            text = _("Could not scan for orphaned sync files."), timeout = 4 })
        return
    end

    local orphans     = result.orphans or {}
    local fail_closed = result.fail_closed or {}

    if #orphans == 0 then
        local msg = _("No orphaned sync files found.")
        if #fail_closed > 0 then
            msg = msg .. "\n\n" .. string.format(_n(
                "%d file was skipped — its book could not be identified, so it was left untouched.",
                "%d files were skipped — their book could not be identified, so they were left untouched.",
                #fail_closed), #fail_closed)
        end
        UIManager:show(InfoMessage:new{ text = msg, timeout = 4 })
        return
    end

    -- Build the confirm-with-names body: the user sees WHICH books are gone, so
    -- they can cancel if one is a book they know still exists (the home_dir-
    -- completeness backstop). Show up to a cap, then "…and N more".
    local SHOW_CAP = 12
    local lines = {}
    for i, path in ipairs(orphans) do
        if i > SHOW_CAP then break end
        -- recover the entry's klass for a good label: re-derive from the path.
        local klass = path:match("/synceryhash/") and "synceryhash"
            or path:match("/hashdocsettings/") and "hashdocsettings"
            or path:match("/docsettings/") and "dir"
            or "doc"
        lines[#lines + 1] = "• " .. OrphanAdapters.display_name({ path = path, klass = klass })
    end
    if #orphans > SHOW_CAP then
        lines[#lines + 1] = string.format(_("…and %d more"), #orphans - SHOW_CAP)
    end

    local body = string.format(_n(
        "Found %d orphaned sync file. The book below was not found:",
        "Found %d orphaned sync files. The books below were not found:",
        #orphans), #orphans)
        .. "\n\n" .. table.concat(lines, "\n")
        .. "\n\n" .. _("Delete these sync files permanently? No book files will be touched.")

    if #fail_closed > 0 then
        body = body .. "\n\n" .. string.format(_n(
            "(%d other file was skipped — its book could not be identified.)",
            "(%d other files were skipped — their book could not be identified.)",
            #fail_closed), #fail_closed)
    end

    UIManager:show(ConfirmBox:new{
        text        = body,
        ok_text     = _("Delete"),
        ok_callback = function()
            local removed = 0
            for __, path in ipairs(orphans) do
                if os.remove(path) then removed = removed + 1 end
            end
            UIManager:show(InfoMessage:new{
                text = string.format(_n(
                    "Removed %d orphaned sync file.",
                    "Removed %d orphaned sync files.", removed), removed),
                timeout = 3,
            })
            log_activity(_("Orphan cleanup"), tostring(removed))
        end,
        cancel_text = _("Cancel"),
    })
end

-- ============================================================================
-- Delete all annotations for the current book
-- ============================================================================
--
-- The "safe" bulk delete: every alive annotation in the shared file
-- becomes a tombstone (deleted = true) with a fresh `datetime_updated`,
-- so the deletion propagates through the 3-way merge and the entries
-- stay restorable from the Trash Bin for the tombstone TTL.  There is
-- no standalone tombstone GC — the orchestrator compacts old
-- tombstones on every sync (compact, never drop).
function Syncery:_deleteAllAnnotationsForCurrentBook()
    local state = self:getCurrentState()
    if not state then
        UIManager:show(InfoMessage:new{ text = _("No document open") })
        return
    end

    local data  = AnnStateStore.load_shared(state.file)
    local alive = 0
    if data and type(data.annotations) == "table" then
        for _key, a in pairs(data.annotations) do
            if a and not a.deleted then alive = alive + 1 end
        end
    end

    if alive == 0 then
        UIManager:show(InfoMessage:new{ text = _("No annotations to delete."), timeout = 2 })
        return
    end

    UIManager:show(ConfirmBox:new{
        text = string.format(_n(
            "Move %d annotation to Trash?\n\nYou can restore it from What's synced \xe2\x86\x92 Annotations \xe2\x86\x92 Trash Bin within 90 days.\n\nNote: this includes annotation made before Syncery was installed.",
            "Move %d annotations to Trash?\n\nYou can restore them from What's synced \xe2\x86\x92 Annotations \xe2\x86\x92 Trash Bin within 90 days.\n\nNote: this includes annotations made before Syncery was installed.",
            alive), alive),
        ok_text     = _("Move to Trash"),
        ok_callback = function()
            local now = AnnTimeFormat.now()
            for _key, a in pairs(data.annotations) do
                if a and not a.deleted then
                    a.deleted          = true
                    a.datetime_updated = now
                    a.device_id        = self.device_id
                    a.device_label     = self.device_label
                end
            end

            local ok_save = AnnStateStore.save_shared(
                state.file, data)
            if not ok_save then
                UIManager:show(InfoMessage:new{
                    text = _("Syncery: could not save changes. Annotations not deleted."),
                    timeout = 4
                })
                return
            end

            -- Clear annotations both on disk and in KOReader's in-memory
            -- list.  The in-memory clear is load-bearing: without it, the
            -- next KOReader save (onSaveSettings writes self.annotations back
            -- to doc_settings) would resurrect the just-deleted annotations
            -- on an open document.  clear_all handles both, defensively
            -- clearing the paging/rolling/bookmarks keys.
            AnnDocSettingsBridge.clear_all(self.ui)

            log_activity(_("Delete all"), tostring(alive))
            _ann_count_cache[state.file] = nil
            UIManager:show(InfoMessage:new{
                text = string.format(
                    _n("%d annotation moved to Trash.", "%d annotations moved to Trash.", alive), alive),
                timeout = 2
            })
        end,
    })
end


function Syncery:_isSyncthingPluginInstalled()
    return _syncthing_plugin_path() ~= nil
end

function Syncery:_configureKOSyncthingPlusConflicts()
    -- Conflict-file suppression normally rides the non-blocking
    -- `.stignore` writer on the scan path (see _doTriggerScan) — there
    -- is no init-time REST registration anymore.
    --
    -- We keep the menu item because users might still want to know
    -- WHAT is happening; this shows a brief status and re-runs the
    -- REST registration by hand, e.g. after installing KOSyncthing+
    -- while Syncery was already running.
    if not self:_isSyncthingPluginInstalled() then
        UIManager:show(InfoMessage:new{
            text = _("The KOSyncthing+ plugin is not installed.\n\n"
                .. "Without it, Syncery still merges conflict files in RAM "
                .. "and deletes the extras — but you'll see them briefly in "
                .. "any file manager between sync and merge."),
            timeout = 6,
        })
        return
    end

    -- Re-run registration via the bridge.
    -- The bridge gates on the syncthing transport being available AND
    -- advertising IGNORE_PATTERNS, which is true for both the KOSyncthing+
    -- provider (when installed) and the manual provider (REST path).
    -- A `false` return means we couldn't dispatch — either the
    -- transport is down or the daemon is unreachable.  In production
    -- this fires asynchronously: the InfoMessage below describes the
    -- DISPATCH, not the daemon-side acknowledgement (which surfaces
    -- in the orchestrator's next status update).
    local ok = self._transport and self._transport:register_syncery_ignore_patterns()
    -- Also register with KOSyncthing+'s conflict SCANNER so the "hidden from
    -- the badge" claim below is backed by an action here too, not only by the
    -- startup registration.  In-process + idempotent; this is the badge/menu
    -- half, the `.stignore` call above is the replication half.
    if self._transport then
        pcall(function() self._transport:register_conflict_menu_ignore() end)
    end
    if ok then
        UIManager:show(InfoMessage:new{
            text = _("Conflict-file integration is active.\n\n"
                .. "Syncery's own conflict files are hidden from the "
                .. "KOSyncthing+ badge — Syncery resolves them in RAM and "
                .. "deletes the extras."),
            timeout = 5,
        })
    else
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Could not register conflict-file patterns with "
                .. "KOSyncthing+.  Its API may have changed; "
                .. "Syncery still merges conflicts locally, but KOSyncthing+ "
                .. "may count them in its badge."),
            timeout = 8,
        })
    end
end

function Syncery:_showActivityLog()
    if #_activity_log == 0 then
        UIManager:show(InfoMessage:new{ text = _("No recent activity recorded."), timeout = 2 })
        return
    end

    local TextViewer = require("ui/widget/textviewer")
    local lines = { _("Recent sync activity (newest first):"), "" }

    for __, ev in ipairs(_activity_log) do
        table.insert(lines, string.format("  %s  %s%s",
            os.date("%H:%M:%S", ev.time),
            ev.kind,
            ev.detail ~= "" and "  —  " .. ev.detail or ""
        ))
    end

    UIManager:show(TextViewer:new{
        title = _("Activity log"),
        text = table.concat(lines, "\n")
    })
end

-- ----------------------------------------------------------------------------
-- Copy diagnostic info
--
-- Gathers a Syncery-shaped troubleshooting snapshot from the live accessors
-- and presents it three ways: a QR code of the essentials (scan with a phone
-- to lift it off an e-ink device that can't easily copy text), the full text
-- in a viewer, and the full text on the clipboard for a bug report.
--
-- This method is the thin GATHERER; all layout / redaction / fault logic lives
-- in the pure, unit-tested `syncery_ui/diagnostic_snapshot`.  Every read is
-- best-effort -- a diagnostic tool must never be able to crash the app it is
-- describing, so a missing accessor degrades to a "?" field, never an error.
--
-- The snapshot TEXT is deliberately English (not translated): it is a
-- technical artefact pasted into a bug report a maintainer reads, so
-- localising "Annotations on" would make it harder to read, not easier.  Only
-- the surrounding UI chrome (menu label, viewer title) is translated.
-- ----------------------------------------------------------------------------
function Syncery:_copyDiagnosticInfo()
    local DiagnosticSnapshot = require("syncery_ui/diagnostic_snapshot")
    local Device     = require("device")
    local TextViewer = require("ui/widget/textviewer")
    local QRMessage  = require("ui/widget/qrmessage")
    local JsonStore  = require("syncery_ann/json_store")
    local AnnConflictResolver = require("syncery_ann/conflict_resolver")

    local function platform_name()
        if Device:isKindle()     then return "Kindle"     end
        if Device:isKobo()       then return "Kobo"       end
        if Device:isAndroid()    then return "Android"    end
        if Device:isPocketBook() then return "PocketBook" end
        return "other"
    end

    local kr_version = "?"
    do
        local ok, V = pcall(require, "version")
        if ok and V and V.getCurrentRevision then
            kr_version = V:getCurrentRevision() or "?"
        end
    end

    local data = {}

    data.meta = {
        plugin_version   = self.version or "?",
        koreader_version = kr_version,
        platform         = platform_name(),
        device_label     = self.device_label,
        device_id        = self.device_id,
        date_str         = os.date("%Y-%m-%d %H:%M"),
    }

    local mode = StorageMode.get()
    data.storage = { mode = mode, root = StorageMode.get_hash_root() }

    data.toggles = {
        progress           = self.sync_progress,
        annotations        = self.sync_annotations,
        highlights         = self.sync_highlights,
        notes              = self.sync_notes,
        bookmarks          = self.sync_bookmarks,
        metadata           = self.sync_metadata,
        status             = self.sync_status,
        rating             = self.sync_rating,
        collections        = self.sync_collections,
        custom_metadata    = self.sync_custom_metadata,
        handmade_toc       = self.sync_handmade_toc,
        render             = self.sync_render_settings,
        render_font_face   = self.sync_font_face,
        render_font_size   = self.sync_font_size,
        render_line_spacing = self.sync_line_spacing,
        render_font_weight = self.sync_font_weight,
        render_margins     = self.sync_margins,
        tombstone_ttl_days = self.tombstone_ttl_days,
        conflict_strategy  = (mode == "sdr") and "sidecar-ignore (SDR)" or nil,
    }

    -- Transports: the same safe one-shot call the status header uses.  Only
    -- syncthing + cloud are orchestrator transports, so the enabled map covers
    -- every id get_status returns (kosync is a separate push path, not here).
    local statuses = {}
    if self._transport and type(self._transport.get_status) == "function" then
        local ok, result = pcall(self._transport.get_status, self._transport)
        if ok and type(result) == "table" then statuses = result end
    end
    local enabled_map = {
        syncthing = Settings.get_syncthing_enabled(),
        cloud     = Settings.get_cloud_enabled(),
    }
    local transports = {}
    for tid, s in pairs(statuses) do
        transports[tid] = {
            name             = s.display_name or tid,
            enabled          = enabled_map[tid],
            available        = s.available,
            summary          = s.summary,
            last_error_class = s.orch_last_error_class,
            pending_retry    = s.orch_any_pending_retry,
        }
    end
    data.transports = transports

    -- Integrity facts.  Left as nil/false unless a check confirms a
    -- value, so the pure fault detector never raises on an unknown.
    local store_exists, store_decode_ok, conflict_count, tombstone_count =
        nil, nil, nil, nil
    local metadata_tombstone_count = nil

    -- This book -- only when one is open.
    if self.ui and self.ui.doc_settings then
        local ds   = self.ui.doc_settings
        local file = self.ui.document and self.ui.document.file or nil

        local ann_count = 0
        local ok_map, map = pcall(AnnDocSettingsBridge.read_annotations_as_map, self.ui)
        if ok_map and type(map) == "table" then
            for _k in pairs(map) do ann_count = ann_count + 1 end
        end

        local shared = false
        if file then
            local p = AnnPaths.shared_annotations_path_for_read(file)
            if p then
                local f = io.open(p, "r")
                if f then f:close(); shared = true end
                -- Store-integrity facts from the same path.  A reason of "ok"
                -- is a healthy store; "invalid_json"/"read_error" means the
                -- file is there but corrupt (a fault); anything else
                -- ("not_found"/"empty"/"no_path") means no store yet.
                local store_data, reason = JsonStore.read(p)
                if reason == "ok" then
                    store_exists, store_decode_ok = true, true
                    tombstone_count = DiagnosticSnapshot.count_tombstones(store_data)
                    metadata_tombstone_count =
                        DiagnosticSnapshot.count_metadata_tombstones(store_data)
                elseif reason == "invalid_json" or reason == "read_error" then
                    store_exists, store_decode_ok = true, false
                else
                    store_exists = false
                end
            end
            local ok_cf, conflicts = pcall(AnnConflictResolver.find_conflict_files, file)
            if ok_cf and type(conflicts) == "table" then conflict_count = #conflicts end
        end

        local id = ds:readSetting("partial_md5_checksum")
        local last_merge = nil
        if id then
            local entries = SyncJournal.read_all() or {}
            for i = #entries, 1, -1 do
                if entries[i].book_id == id then
                    last_merge = entries[i].outcome
                    break
                end
            end
        end

        data.this_book = {
            file          = file,
            id            = id,
            excluded      = ds:readSetting("syncery_disabled") and true or false,
            annotations   = ann_count,
            percent       = ds:readSetting("percent_finished"),
            shared_record = shared,
            last_merge    = last_merge,
        }
    end

    data.journal = SyncJournal.read_all() or {}

    -- The journal stores each merge time as a numeric epoch (compact,
    -- sortable).  The snapshot stays os.date-free for determinism, so we
    -- hand it the formatter: local time (no "!" UTC flag), minute precision.
    data.format_ts = function(ts)
        ts = tonumber(ts)
        if not ts then return nil end
        return os.date("%Y-%m-%d %H:%M", ts)
    end

    data.activity = {}
    for _i, ev in ipairs(_activity_log) do
        data.activity[#data.activity + 1] = {
            when   = os.date("%H:%M:%S", ev.time),
            kind   = ev.kind,
            detail = ev.detail,
        }
    end

    -- .stignore (global): only applicable in SDR mode with a configured folder.
    -- A confirmed-missing file is a fault (sidecar conflict suppression is off);
    -- if the folder root can't be resolved, presence stays nil (unknown).
    local stignore_applicable, stignore_present = false, nil
    if mode == "sdr" then
        local folder = Settings.get_syncthing_folder()
        if type(folder) == "table" then
            stignore_applicable = true
            local root = Stignore.root_for(Settings.get_syncthing_folder_id(), folder)
            if type(root) == "string" and root ~= "" then
                local sip = root:gsub("[/\\]+$", "") .. "/.stignore"
                local f = io.open(sip, "r")
                stignore_present = (f ~= nil)
                if f then f:close() end
            end
        end
    end

    data.integrity = {
        store_exists        = store_exists,
        store_decode_ok     = store_decode_ok,
        conflict_count      = conflict_count,
        tombstone_count     = tombstone_count,
        metadata_tombstone_count = metadata_tombstone_count,
        stignore_applicable = stignore_applicable,
        stignore_present    = stignore_present,
    }

    local snap = DiagnosticSnapshot.build(data)

    -- QR the compact essentials (scannable); full text to viewer + clipboard.
    UIManager:show(QRMessage:new{
        text   = snap.essentials,
        width  = math.floor(Device.screen:getWidth()  * 0.85),
        height = math.floor(Device.screen:getHeight() * 0.85),
        dismiss_callback = function()
            UIManager:show(TextViewer:new{
                title  = _("Diagnostic info (copied to clipboard)"),
                text   = snap.full,
                width  = math.floor(Device.screen:getWidth()  * 0.92),
                height = math.floor(Device.screen:getHeight() * 0.85),
            })
        end,
    })
    if Device.input and Device.input.setClipboardText then
        Device.input.setClipboardText(snap.full)
    end
end

function Syncery:_resetAll()
    UIManager:show(ConfirmBox:new{
        text = _("Reset every Syncery setting on this device?\n\nThe device's Syncery JSON files for books are NOT touched — only this device's local preferences."),
        ok_text = _("Reset"),
        ok_callback = function()
            if G_reader_settings then
                for _, k in ipairs(PREFERENCE_KEYS) do
                    G_reader_settings:delSetting(k)
                end
            end
			
            _firstrun_done = false

            -- New transports re-read settings on every call (no
            -- per-module cache), so there's nothing to invalidate
            -- after the bulk delSetting above.  The orchestrator's
            -- in-process state (per-(transport, book) attempt
            -- timestamps) is intentionally NOT cleared here — a fresh
            -- "you just deleted credentials" state is consistent with
            -- "transports become unavailable; retries cancel naturally
            -- on the next attempt".
            -- Offer a restart that works on EVERY device: restartKOReader()
            -- quits with code 85, which the KOReader launch wrapper recognises
            -- and relaunches.  (askForRestart relies on a platform Restart event
            -- handler that, where absent, only shows an info message -- the
            -- "works on some devices, only describes on others" behaviour.)
            UIManager:show(ConfirmBox:new{
                text        = _(
                    "Syncery settings have been reset.\n\n"
                    .. "Restart KOReader now for the change to take full effect?"),
                ok_text     = _("Restart"),
                cancel_text = _("Later"),
                ok_callback = function() UIManager:restartKOReader() end,
            })
        end,
    })
end

-- ============================================================================
-- Main menu registration
-- ============================================================================

function Syncery:addToMainMenu(menu_items)
    menu_items.syncery = {
        text                = _("Syncery"),
        sorting_hint        = "tools",
        sub_item_table_func = function()
            return MenuBuilder.buildTopMenu(self)
        end,
    }
end

-- ============================================================================
-- Dispatcher actions
-- ============================================================================

function Syncery:onDispatcherRegisterActions()
    Dispatcher:registerAction("syncery_now", {
        category = "none", event = "SynceryNow",
        title = _("Syncery: sync now"), reader = true
    })
    Dispatcher:registerAction("syncery_undo_jump", {
        category = "none", event = "SynceryUndoJump",
        title = _("Syncery: undo last jump"), reader = true
    })
    -- The onSynceryRescanAll handler has no dispatcher action of its own,
    -- so without this users couldn't bind a gesture/button to "rescan
    -- all".  Register it.
    Dispatcher:registerAction("syncery_rescan", {
        category = "none", event = "SynceryRescanAll",
        title = _("Syncery: rescan all folders"), reader = true
    })
    -- The sync-status panel is otherwise menu-only.  Register it so it can
    -- be bound to a gesture or hardware key like the other actions.
    Dispatcher:registerAction("syncery_show_status", {
        category = "none", event = "SynceryShowStatus",
        title = _("Syncery: show sync status"), reader = true
    })
    -- Symmetry with syncery_undo_jump: bindable manual forward jump to the
    -- latest other device (otherwise reachable only via the status panel).
    Dispatcher:registerAction("syncery_jump", {
        category = "none", event = "SynceryJump",
        title = _("Syncery: jump to another device"), reader = true
    })
    -- The two cross-device browsers are otherwise menu-only; expose them so they
    -- can be bound to a gesture / hardware key (useful on non-touch).
    Dispatcher:registerAction("syncery_progress_browser", {
        category = "none", event = "SynceryProgressBrowser",
        title = _("Syncery: progress browser"), reader = true
    })
    Dispatcher:registerAction("syncery_annotation_browser", {
        category = "none", event = "SynceryAnnotationBrowser",
        title = _("Syncery: annotation browser"), reader = true, separator = true
    })
end

--- Plugin-removal hook: deletes settings and local artefacts when the user
--- chooses to remove the plugin via KOReader's plugin manager.
function Syncery:deletePluginSettings()
    -- 1. Clear every Syncery key in G_reader_settings (preferences PLUS
    --    this device's identity — a hard purge wipes everything).
    if G_reader_settings then
        for _, k in ipairs(FULL_PURGE_KEYS) do
            G_reader_settings:delSetting(k)
        end
    end

    -- 2. Delete the entire syncery state directory (activity log, hash data, etc.)
    -- Note: cloud staging files live inside `state_dir/cloud_staging/`,
    -- so the purge below covers them too — no separate cleanupStaging
    -- call required.
    local state_dir = Util.state_dir()
    if state_dir then
        local ffiUtil = require("ffi/util")
        ffiUtil.purgeDir(state_dir)
    end
end

return Syncery