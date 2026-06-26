-- spec/menu_test_support.lua
--
-- Shared helper for the menu_*_spec files.  Installs the KOReader-side
-- stubs the menu modules require (UIManager, dialog widgets, etc.) and
-- the syncery-side stubs (Settings, transports/api, data, ui).
--
-- Loaded from each menu spec via:
--   local h        = require("spec.test_helpers")
--   local menu_support = require("spec.menu_test_support")
--   h.setup()
--   menu_support.install_stubs()
--
-- After that, `require("syncery_ui/menu/...")` works.
--
-- Note: this is intentionally NOT in spec/test_helpers because those
-- helpers are kept platform-neutral.  The menu's stubs touch UI
-- modules and the transport-API surface, which other specs don't need.

local M = {}


--- Recording stub for the InfoMessage / ConfirmBox / TextViewer
--- widgets.  Each `new` call captures its args in a list so tests
--- can assert "InfoMessage was shown with text X".
local function recording_widget()
    local shown = {}
    return {
        new = function(_, args)
            local rec = args or {}
            rec._is_widget = true
            table.insert(shown, rec)
            return rec
        end,
        _shown = shown,
    }
end


--- Build the InputDialog mock — same shape as recording_widget but
--- also has the methods InputDialog instances expose (onShowKeyboard,
--- getInputText, close).
local function recording_input_dialog()
    local shown = {}
    return {
        new = function(_, args)
            local rec = args or {}
            rec._is_widget = true
            rec.onShowKeyboard = function() end
            rec.getInputText   = function() return rec.input or "" end
            table.insert(shown, rec)
            return rec
        end,
        _shown = shown,
    }
end


--- A recording UIManager: every show()/close() call captured.
local function recording_uimanager()
    local events = {}
    return {
        show          = function(_, w) table.insert(events, { kind="show",  widget=w }) end,
        close         = function(_, w) table.insert(events, { kind="close", widget=w }) end,
        broadcastEvent = function() end,
        scheduleIn    = function() end,
        unschedule    = function() end,
        _events       = events,
    }
end


--- Install ALL the stubs the menu modules need.  Returns a `stubs`
--- table with the recording widgets exposed so tests can poke at
--- them.  Idempotent across multiple installs (replaces prior stubs).
function M.install_stubs(opts)
    opts = opts or {}

    local stubs = {}
    stubs.uimgr        = recording_uimanager()
    stubs.info         = recording_widget()
    stubs.confirm      = recording_widget()
    stubs.buttondialog = recording_widget()
    stubs.textviewer   = recording_widget()
    stubs.inputdialog  = recording_input_dialog()
    stubs.qrmessage    = recording_widget()
    stubs.menu         = recording_widget()

    -- G_reader_settings stub.  Without this, the menu code's
    -- `if G_reader_settings then ... end` guards short-circuit and
    -- writes are silently swallowed — which is exactly how the
    -- transport-section toggle bug (D-3 in DEAD_CODE_AUDIT) hid for
    -- so long.  Records every saveSetting call so specs can assert
    -- the menu writes the keys it claims to.
    local grs_storage = {}
    local grs_save_calls = {}
    _G.G_reader_settings = {
        readSetting = function(_, k) return grs_storage[k] end,
        saveSetting = function(_, k, v)
            grs_storage[k] = v
            table.insert(grs_save_calls, { key = k, value = v })
        end,
        delSetting  = function(_, k) grs_storage[k] = nil end,
        isTrue      = function(_, k) return grs_storage[k] == true end,
        isFalse     = function(_, k) return grs_storage[k] == false end,
        nilOrTrue   = function(_, k) return grs_storage[k] == nil or grs_storage[k] == true end,
    }
    stubs.grs_storage    = grs_storage
    stubs.grs_save_calls = grs_save_calls

    package.loaded["ui/uimanager"]            = stubs.uimgr
    package.loaded["ui/widget/infomessage"]   = stubs.info
    package.loaded["ui/widget/confirmbox"]    = stubs.confirm
    package.loaded["ui/widget/buttondialog"]  = stubs.buttondialog
    package.loaded["ui/widget/textviewer"]    = stubs.textviewer
    package.loaded["ui/widget/inputdialog"]   = stubs.inputdialog
    package.loaded["ui/widget/qrmessage"]     = stubs.qrmessage
    package.loaded["ui/widget/menu"]          = stubs.menu
    -- Device stub: maintenance_section reads Device.screen:getWidth/getHeight
    -- to size the device-ID QR code. Ensure a fake screen exists even if an
    -- earlier spec already populated package.loaded["device"] without one
    -- (the suite shares Lua state, so a bare prior stub must not win).
    local dev = package.loaded["device"]
    if type(dev) ~= "table" then
        dev = {}
        package.loaded["device"] = dev
    end
    if type(dev.screen) ~= "table" then
        dev.screen = {
            getWidth  = function() return 600 end,
            getHeight = function() return 800 end,
        }
    end
    package.loaded["ui/event"]                = {
        new = function(_, name) return { name = name } end,
    }

    package.loaded["syncery_util"] = opts.util or {
        trim = function(s)
            if not s then return "" end
            return (s:gsub("^%s+", ""):gsub("%s+$", ""))
        end,
        get_device_label = function() return "TestDevice" end,
        -- Mimics the canonical-return contract (F3): returns what would
        -- have been saved (trimmed), or false for empty input.
        set_device_label = function(t)
            t = t and (t:gsub("^%s+", ""):gsub("%s+$", "")) or ""
            if #t == 0 then return false end
            return t
        end,
        get_device_id    = function() return "abcdef0123456789abcdef0123456789" end,
        get_lfs          = function() return require("lfs") end,
        state_dir        = function() return "/tmp/syncery_state/" end,
    }

    package.loaded["syncery_i18n"] = {
        translate = function(s) return s end,
        ngettext  = function(s, p, n) if n == 1 then return s else return p end end,
    }

    -- annotations_section requires syncery_ui/trash/init directly
    -- (the syncery_ui shim was removed in Phase 12.1).  Stub that
    -- module's surface; keep the legacy bare-name key too for any
    -- other caller that still resolves through it.
    package.loaded["syncery_ui/trash/init"] = { show = function() end }
    package.loaded["syncery_ui/trash"]      = package.loaded["syncery_ui/trash/init"]
    package.loaded["syncery_ui"] = {
        Trash    = package.loaded["syncery_ui/trash/init"],
        StatusUI = { showJumpDialog = function() end },
    }

    package.loaded["syncery_progress/paths"] = {
        shared_progress_path    = function() return nil end,
        last_sync_progress_path = function() return nil end,
    }

    -- Settings stub: every getter returns its no-op default unless
    -- the test overrides it via the `settings` opt.
    local settings_defaults = {
        get_syncthing_url         = "",
        get_syncthing_api_key     = "",
        get_syncthing_folder_id   = "default",
        get_syncthing_folder      = nil,
        get_syncthing_port        = 8384,
        get_syncthing_scheme      = "http",
        is_cloud_configured       = false,
        describe_cloud_server     = nil,
    }
    local settings_overrides = opts.settings or {}
    -- Record set_* calls so specs can assert on the menu's writes.
    -- Each Settings.set_<x>(v) call records {key="set_<x>", value=v}.
    local settings_set_calls = {}
    local settings_stub = setmetatable({}, {
        __index = function(_, k)
            -- set_* keys: return a recording function.  Specs read
            -- the recorded log via stubs.settings_set_calls.
            if k:sub(1, 4) == "set_" then
                return function(v)
                    table.insert(settings_set_calls, { key = k, value = v })
                end
            end
            -- everything else: a getter that returns defaults/overrides.
            return function()
                if settings_overrides[k] ~= nil then return settings_overrides[k] end
                if settings_defaults[k] ~= nil   then return settings_defaults[k]   end
                return nil
            end
        end,
    })
    -- The set_* functions are no-ops; the get_* functions return
    -- whatever's in defaults/overrides.
    package.loaded["syncery_settings"] = settings_stub
    stubs.settings_set_calls = settings_set_calls

    package.loaded["syncery_transports/http_client"] = {
        new = function() return nil end,
    }
    package.loaded["syncery_transports/log"] = setmetatable({}, {
        __index = function() return function() end end,
    })
    package.loaded["syncery_transports/policy"] = {
        CLASSES = { CONFIG_NEEDED = "config_needed" },
    }

    return stubs
end


--- Build a recording fake plugin with the surface menu sections read.
--- Tests can override fields via `opts` and add extra methods after
--- construction.
function M.make_fake_plugin(opts)
    opts = opts or {}
    local plugin = {
        -- transport toggles
        use_syncthing = opts.use_syncthing or false,
        use_cloud     = opts.use_cloud     or false,

        -- what-to-sync toggles
        sync_progress    = opts.sync_progress    ~= false,
        sync_annotations = opts.sync_annotations or false,
        sync_highlights  = opts.sync_highlights  or false,
        sync_notes       = opts.sync_notes       or false,
        sync_bookmarks   = opts.sync_bookmarks   or false,
        sync_metadata    = opts.sync_metadata    or false,
        sync_status      = opts.sync_status      or false,
        sync_rating      = opts.sync_rating      or false,
        sync_collections = opts.sync_collections or false,
        sync_custom_metadata = opts.sync_custom_metadata or false,
        sync_handmade_toc    = opts.sync_handmade_toc    or false,
        sync_extensions  = opts.sync_extensions  or "*",

        -- behaviour toggles
        adapt_highlight_style = opts.adapt_highlight_style or false,
        jump_mode             = opts.jump_mode             or "ask",
        sync_summary          = opts.sync_summary          or false,
        sync_render_settings  = opts.sync_render_settings  or false,

        -- trigger-only DB sync (Statistics / Vocabulary)
        db_sync_enabled  = opts.db_sync_enabled  or false,
        db_sync_stats    = opts.db_sync_stats    ~= false,
        db_sync_vocab    = opts.db_sync_vocab    ~= false,
        sync_font_face        = opts.sync_font_face         or false,
        sync_font_size        = opts.sync_font_size         or false,
        sync_line_spacing     = opts.sync_line_spacing      or false,
        sync_font_weight      = opts.sync_font_weight       or false,
        sync_margins          = opts.sync_margins           or false,

        -- per-book state
        pre_jump_until = opts.pre_jump_until,

        -- config
        storage_mode   = opts.storage_mode or "sdr",
        cloud_upload_delay = opts.cloud_upload_delay or 60,
        tombstone_ttl_days = opts.tombstone_ttl_days or 30,
        device_id    = opts.device_id    or "dev1",
        device_label = opts.device_label or "TestDevice",

        -- transports
        _transport = opts._transport,

        -- ui (doc_settings present iff a "book" is open)
        ui = opts.ui,

        -- recorder for calls into the plugin
        _calls = {},
    }

    -- Stub plugin methods.  Each records into _calls so tests can
    -- assert "the menu's callback fired this method".
    local function record(name)
        return function(self, ...)
            self._calls[name] = (self._calls[name] or 0) + 1
            self._calls[name .. "_args"] = { ... }
        end
    end
    plugin.maybeShowFirstRunDialog = function() end
    plugin._statusBadge        = function() return opts.status_badge or "no sync" end
    plugin.getCurrentState     = function() return opts.current_state end
    plugin.showSyncStatus      = record("showSyncStatus")
    plugin.resolveStatusProblem = record("resolveStatusProblem")
    plugin.syncNow             = record("syncNow")
    plugin.pushHandmadeToc     = record("pushHandmadeToc")
    plugin._undoLastJump       = record("_undoLastJump")
    plugin._rescanAllFolders   = record("_rescanAllFolders")
    plugin._cleanupOrphans     = record("_cleanupOrphans")
    plugin._showActivityLog    = record("_showActivityLog")
    plugin._resetAll           = record("_resetAll")
    plugin._configureKOSyncthingPlusConflicts = record("_configureKOSyncthingPlusConflicts")
    plugin._isSyncthingPluginInstalled = function() return opts.kosyncthing_installed or false end
    plugin._syncBookViaOrchestrator = record("_syncBookViaOrchestrator")
    plugin.clearAnnotationCache = record("clearAnnotationCache")
    plugin._deleteAllAnnotationsForCurrentBook = record("_deleteAllAnnotationsForCurrentBook")
    plugin._migrateAllBooks    = record("_migrateAllBooks")
    plugin.setStorageMode      = function(self, mode)
        self._calls.setStorageMode = (self._calls.setStorageMode or 0) + 1
        self.storage_mode = mode
    end
    plugin.cancelPendingSync   = record("cancelPendingSync")
    plugin._logActivity        = record("_logActivity")
    plugin._rebuildExtensionCache       = record("_rebuildExtensionCache")

    return plugin
end


--- Build a minimal fake transport that returns a fixed status map.
--- Used by tests that exercise Pattern 1 / Pattern 3 — they pass
--- different status maps to drive the dynamic labels.
--- Build a fake transport (the `plugin._transport` bridge surface).
---
--- `status_map` backs `get_status()`.  Optional `per_book_map` backs
--- `peek_transport_books(transport_id)` — a map of transport_id → list
--- of `{ book_file, state }` records, the shape the status panel
--- (Phase 6) consumes.  When `per_book_map` is omitted,
--- `peek_transport_books` returns an empty list for every id.
function M.make_fake_transport(status_map, per_book_map)
    return {
        get_status = function(_) return status_map or {} end,
        peek_transport_books = function(_, transport_id)
            if not per_book_map then return {} end
            return per_book_map[transport_id] or {}
        end,
    }
end


--- Build a fake `ui` object that simulates a book being open.
--- doc_settings is a real-ish table with readSetting/saveSetting,
--- backed by an in-memory map under `_settings`.
function M.make_fake_ui(opts)
    opts = opts or {}
    local settings_storage = opts.settings or {}
    return {
        paging  = opts.paging or false,
        rolling = (not opts.paging) and { stub = true } or nil,
        doc_settings = {
            readSetting = function(_, k) return settings_storage[k] end,
            saveSetting = function(_, k, v) settings_storage[k] = v end,
            flush       = function() end,
        },
        _settings = settings_storage,
    }
end


--- Walk a menu items table and find a row by text or text_func()
--- value.  Returns the row or nil.
function M.find_row(items, text)
    for _, row in ipairs(items) do
        local label
        if row.text_func then label = row.text_func() end
        label = label or row.text
        if label == text then return row end
    end
    return nil
end


--- Walk and return ALL rows matching the predicate.
function M.filter_rows(items, predicate)
    local out = {}
    for _, row in ipairs(items) do
        if predicate(row) then table.insert(out, row) end
    end
    return out
end


--- Resolve a row's label, whether it's a string or text_func.
function M.label_of(row)
    if row.text_func then return row.text_func() end
    return row.text or ""
end


return M
