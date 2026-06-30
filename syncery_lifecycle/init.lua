-- =============================================================================
-- syncery_lifecycle/init.lua
-- =============================================================================
--
-- The Lifecycle dispatcher.  Wires the per-event KOReader handlers
-- (onCloseDocument, onSuspend, onResume, onPowerOff, onQuit, onFlushSettings)
-- onto the central Teardown helper, owns the Timers instance, and
-- exposes the small "schedule the autosave" wrapper that
-- `Syncery:scheduleAutoSave` delegates to.
--
-- This is a façade module: it doesn't reimplement any of the work; it
-- just routes the four+ KOReader events into the right `Teardown.flush`
-- opts and holds the Timers handle that teardown's Step 5 reaches.
--
-- WHY THE METHODS LIVE HERE (and not, say, as a flat events.lua)
--
-- Each handler is a 1–3-line decision: "what teardown opts does this
-- event want?"  Putting them on the dispatcher object means main.lua
-- carries one reference (self._lifecycle) and the handler-to-event
-- mapping is grep-able by method name.  The alternative — separate
-- events.lua holding four near-identical one-liners — would split
-- this knowledge across two files without buying anything.
--
-- CONSTRUCTION
--
-- Lifecycle.new builds and stores a Timers instance.  The plugin holds
-- onto the returned Lifecycle as `self._lifecycle`; its own `init()`
-- only constructs the Lifecycle once, and the timers slot map outlives
-- individual onReaderReady / onCloseDocument cycles (timers get
-- cancel_all'd on each teardown, but the Timers instance itself
-- stays).
-- =============================================================================


local Timers   = require("syncery_lifecycle/timers")
local Teardown = require("syncery_lifecycle/teardown")
local Notify   = require("syncery_ui/notify")
-- Close-time annotation delivery (G): on_save_settings writes the merged list
-- stashed by teardown's destroying flush to doc_settings' base key.
local DocSettingsBridge = require("syncery_ann/doc_settings_bridge")


local Lifecycle = {}
Lifecycle.__index = Lifecycle


-- ----------------------------------------------------------------------------
-- Construction
--
-- opts.plugin     — the Syncery plugin instance.  Required.
-- opts.ui_manager — KOReader's UIManager.  Required.  We forward this
--                   to Timers (which calls :scheduleIn / :unschedule)
--                   and to Teardown (which calls :close / :nextTick).
-- opts.util_now   — function returning current Unix time.  Required.
--                   Threaded through to Teardown so the test suite can
--                   pin time.  In production main.lua wires this to
--                   `Util.now`.
-- opts.logger     — optional logger object exposing .warn(msg).  Used
--                   by both Timers and Teardown for soft errors.
--                   Falls back to a no-op for test contexts.
-- ----------------------------------------------------------------------------


--- Build a new Lifecycle dispatcher for `plugin`.
--- @param opts table
--- @return table
function Lifecycle.new(opts)
    opts = opts or {}
    assert(type(opts.plugin)     == "table",
        "Lifecycle.new: plugin is required")
    assert(type(opts.ui_manager) == "table",
        "Lifecycle.new: ui_manager is required")
    assert(type(opts.util_now)   == "function",
        "Lifecycle.new: util_now (function) is required")

    local self = setmetatable({}, Lifecycle)
    self._plugin     = opts.plugin
    self._ui_manager = opts.ui_manager
    self._util_now   = opts.util_now
    self._logger     = opts.logger or { warn = function() end }

    self.timers = Timers.new{
        ui_manager = self._ui_manager,
        plugin     = self._plugin,
        logger     = self._logger,
    }

    return self
end


-- ============================================================================
-- Teardown wrapper
--
-- The four KOReader events each want a slightly different opts blob.
-- Centralising the call here means main.lua's event handlers are
-- pure one-liners with no fight-or-flight knowledge of what
-- "destroying" means.
-- ============================================================================


--- Run the flush sequence with the given opts.
--- @param opts table?
function Lifecycle:teardown(opts)
    Teardown.flush(self._plugin, self._ui_manager,
                   self._util_now, self._logger, opts or {})
    -- notify schedules off-slot (its own scheduleIn), so Teardown's Step-5
    -- cancel_all does not reach it.  Stop the toast queue here so a pending
    -- auto-dismiss or gap-drain can't fire onto the next screen after close.
    Notify.stopAll()
end


-- ============================================================================
-- KOReader event handlers (delegated from main.lua's Syncery:on*)
-- ============================================================================


--- onCloseDocument — user closed the book.  Last chance for THIS book.
--- Strongest teardown short of a full process exit: mark destroyed so
--- any pending tick can no-op.
function Lifecycle:on_close_document()
    self:teardown{ destroying = true }
end


--- onSuspend — device going to sleep.  Just flush; no destroying.  KOReader
--- DOES broadcast Resume to plugins on wake (see on_resume below), the same
--- way it broadcasts Suspend — but a Resume event never re-runs init(), so we
--- keep the transport stack and the plugin object alive across suspend rather
--- than tearing down, so on_resume has something to work with.
function Lifecycle:on_suspend()
    self:teardown{ suspend = true }
end


-- Resume re-check budget.  WiFi is usually off during suspend and reconnects
-- asynchronously over several seconds after a wake, so we cannot check the
-- moment we resume.  We re-probe connectivity every RESUME_RECHECK_POLL_DELAY
-- seconds, up to RESUME_RECHECK_MAX_TRIES times (~30s), then defer the actual
-- remote check by RESUME_RECHECK_GRACE seconds to let Syncthing pull the
-- peer's files (checkRemote only reads the locally-synced files).
local RESUME_RECHECK_POLL_DELAY = 3
local RESUME_RECHECK_MAX_TRIES  = 10
local RESUME_RECHECK_GRACE      = 2


--- onResume — device woke from suspend.  KOReader broadcasts Resume to
--- plugins (frontend/device/generic/device.lua), exactly as it broadcasts
--- Suspend (which on_suspend above handles) — so this fires on every wake.
--- The book stays open across suspend, so onReaderReady does NOT re-fire and
--- nothing else re-checks whether a peer advanced while we slept.  We re-check
--- here, but gate it on connectivity: checkRemote reads the locally-synced
--- files, which Syncthing can only have refreshed once WiFi is back.  So we
--- poll connectivity on a bounded budget, then defer the check by a short
--- grace.  Reuses the slot scheduler (so teardown's cancel_all stops it on a
--- quick close) and the same _check_remote_action slot onReaderReady uses (so
--- the two coalesce).  Does NOT re-initialise the plugin — an Event never
--- re-runs init(); on_suspend keeps us alive precisely so we are here now.
function Lifecycle:on_resume(tries_left)
    local plugin = self._plugin
    if plugin.destroyed then return end

    if plugin:_isNetworkOnline() then
        self:schedule("_check_remote_action", RESUME_RECHECK_GRACE, function()
            if not plugin.destroyed then plugin:checkRemote() end
        end)
        return
    end

    -- Offline — WiFi still reconnecting.  Re-probe shortly, bounded so a wake
    -- with no network ever returning does not poll forever.
    tries_left = tries_left or RESUME_RECHECK_MAX_TRIES
    if tries_left <= 0 then return end
    self:schedule("_resume_recheck_action", RESUME_RECHECK_POLL_DELAY, function()
        self:on_resume(tries_left - 1)
    end)
end


--- onPowerOff — device shutting down (not the KOReader process).  A
--- non-destroying teardown: flush persisted state, but the plugin
--- survives (no transport shutdown, destroyed stays false).
function Lifecycle:on_power_off()
    self:teardown{}
end


--- onQuit — KOReader process exiting.  Strongest teardown: full
--- destroying flush + transport shutdown.
function Lifecycle:on_quit()
    self:teardown{
        destroying       = true,
    }
end


--- onFlushSettings — KOReader is asking every subsystem to persist.
--- We don't have plugin-owned settings the user changes per-session;
--- instead we use this as a hint to debounce-trigger a Syncthing scan,
--- so any in-flight settings writes by other plugins land first.
---
--- Gated on `plugin.ui.document` being truthy: KOReader emits
--- onFlushSettings during early startup before any document is open,
--- and `_debouncedScan` would otherwise try to compute a scan target
--- from a nil document.
function Lifecycle:on_flush_settings()
    if not self._plugin.ui or not self._plugin.ui.document then return end
    pcall(function() self._plugin:_debouncedScan() end)
end


--- onSaveSettings — KOReader is persisting doc_settings.  Deliver the
--- close-time annotation stash (filled by teardown's DESTROYING flush) to
--- doc_settings' base "annotations" key.
---
--- Ordering (verified against KOReader source): this runs AFTER
--- ReaderAnnotation:onSaveSettings -- plugins are registered after the core
--- modules (readerui.lua), the core handler returns nil (does not stop the
--- SaveSettings broadcast), and no core module's onSaveSettings returns true,
--- so the broadcast reaches us last and our write overwrites the live-list
--- write ReaderAnnotation just made.  KOReader's onReadSettings then loads
--- the base key on the next open (+ annotations_externally_modified triggers
--- a pageno/sort recompute, set inside stage_pending_at_close).
---
--- No stash -> no-op.  The stash is filled only by the destroying teardown
--- path (close-document / quit), so suspend, autosave, power-off and every
--- other ordinary SaveSettings pass straight through.  The stash is consumed
--- exactly once (cleared before the write) so a second save in the same close
--- does not re-deliver.  See ANNOTATION_DELIVERY_DESIGN.md S2 / G-wiring.
function Lifecycle:on_save_settings()
    local plugin  = self._plugin
    local pending = plugin._pending_anns
    if not pending or type(pending.annotations) ~= "table" then return end
    plugin._pending_anns = nil  -- consume exactly once
    if not plugin.ui or not plugin.ui.doc_settings then return end
    pcall(function()
        DocSettingsBridge.stage_pending_at_close(
            plugin.ui, pending.annotations, pending.adapt_highlight_style,
            pending.device_id)
    end)
end


-- ============================================================================
-- Autosave helper
--
-- scheduleAutoSave is just a _schedule call gated on `destroyed` and
-- `blocking_autosave`, only firing _autoSave when sync_state is idle.
-- Lives here so the main.lua-side method is a pure delegator.
-- ============================================================================


--- Debounce an autosave to run after `plugin.autosave_delay` seconds.
--- No-op when the plugin is destroyed or autosave is blocked.
---
--- "blocked" is two things — the indefinite boolean
--- (cancelPendingSync's reset block) OR the self-healing window
--- `blocking_autosave_until` (the post-jump suppression, an epoch second
--- past which it lapses). We check both here so this reader agrees with
--- main.lua's _save gate (`Syncery:_isAutosaveBlocked`). `self._util_now`
--- is the injected clock (production: Util.now, scale-compatible with the
--- os.time() that _doJump uses to set the window).
function Lifecycle:schedule_auto_save()
    local plugin = self._plugin
    if plugin.destroyed or plugin.blocking_autosave
            or (plugin.blocking_autosave_until or 0) > self._util_now() then
        return
    end

    self.timers:schedule("_autosave_action", plugin.autosave_delay, function()
        -- Re-check on fire: blocking_autosave or a transition out of
        -- idle between arm and fire should still suppress the save. The
        -- window is re-checked too — it may have been (re)armed by a jump
        -- between this timer's arm and its fire.
        if plugin.sync_state == "idle"
                and not plugin.blocking_autosave
                and (plugin.blocking_autosave_until or 0) <= self._util_now() then
            plugin:_autoSave(true)
        end
    end)
end


-- ============================================================================
-- Schedule passthrough
--
-- main.lua's `Syncery:_schedule(slot, delay, body)` is called from ~25
-- sites and must keep working.  The wrapper on Syncery: just calls
-- this method, so we keep the same call shape end-to-end.
-- ============================================================================


--- Schedule `body` under `slot` after `delay` seconds.  Cancel any
--- prior arm of the same slot.  See `syncery_lifecycle/timers.lua` for
--- the full contract.
function Lifecycle:schedule(slot, delay, body)
    self.timers:schedule(slot, delay, body)
end


--- Cancel one slot.
function Lifecycle:cancel(slot)
    self.timers:cancel(slot)
end


--- Cancel every armed slot.
function Lifecycle:cancel_all_timers()
    self.timers:cancel_all()
end


return Lifecycle
