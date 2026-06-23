-- =============================================================================
-- spec/transport_plugin_sync_spec.lua
-- =============================================================================
--
-- Tests for syncery_transports/plugin_sync.lua — the plugin-facing
-- transport glue relocated out of main.lua in Phase 9.3.
--
-- The four functions are guard-heavy: most of the surface is "bail
-- early when a toggle is off / unconfigured / offline".  These tests
-- exercise those gates plus the happy-path dispatch onto a fake
-- transport.  Every dependency (Settings, the transport, the wifi
-- backoff, network probe) is stubbed — no KOReader code, no network.
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_plugin_sync_spec_" .. tostring(os.time()))


-- ---------------------------------------------------------------------------
-- Stub syncery_settings BEFORE requiring plugin_sync.  The defaults
-- below describe a fully-configured cloud setup; individual tests flip
-- a flag to exercise the unconfigured paths.
-- ---------------------------------------------------------------------------

local settings_state = {
    cloud_configured  = true,
}

package.loaded["syncery_settings"] = {
    is_cloud_configured   = function() return settings_state.cloud_configured  end,
}


local PluginSync = require("syncery_transports/plugin_sync")


-- ---------------------------------------------------------------------------
-- Fake plugin builder.  Records every transport call and timer schedule
-- so tests can assert on them.  `opts` overrides the defaults.
-- ---------------------------------------------------------------------------

local function make_plugin(opts)
    opts = opts or {}
    local p = {
        use_cloud    = opts.use_cloud    ~= false,
        sync_progress = opts.sync_progress ~= false,
        destroyed    = opts.destroyed or false,
        is_saving    = opts.is_saving or false,
        sync_state   = opts.sync_state or "idle",
        _active_sync_box = opts.active_sync_box,
        device_label = "TestDevice",
        cloud_upload_delay = 60,
        ui = opts.ui,
        _online = opts.online ~= false,
        _cloud_online = opts.cloud_online ~= false,

        -- recorders
        _calls    = {},
        _schedules = {},
    }

    -- A transport that records each push.
    p._transport = opts.no_transport and nil or {
        push_cloud_files = function(_, file, entries)
            table.insert(p._calls, { m = "push_cloud_files", file = file, entries = entries })
        end,
    }

    function p:_isNetworkOnline() return self._online end
    function p:_isCloudReachable() return self._cloud_online end
    function p:getCurrentState()  return opts.state end
    function p:_isFileTypeSynced() return opts.file_type_synced ~= false end
    function p:_promptJump(args)
        table.insert(self._calls, { m = "_promptJump", args = args })
    end
    function p:_schedule(slot, delay, fn)
        table.insert(self._schedules, { slot = slot, delay = delay, fn = fn })
    end

    -- wifi backoff recorders (link-scoped + cloud-scoped)
    p._wifi_backoff = {
        attempt = function(_, a)
            table.insert(p._calls, { m = "wifi_attempt", label = a.label, run = a.run })
        end,
    }
    p._cloud_wifi_backoff = {
        attempt = function(_, a)
            table.insert(p._calls, { m = "cloud_wifi_attempt", label = a.label, run = a.run })
        end,
    }

    return p
end

local function called(p, method)
    for _, c in ipairs(p._calls) do
        if c.m == method then return c end
    end
    return nil
end


-- ===========================================================================
-- schedule_cloud_upload
-- ===========================================================================

-- use_cloud off → nothing scheduled.
do
    local p = make_plugin{ use_cloud = false }
    PluginSync.schedule_cloud_upload(p, { file = "/b.epub" })
    h.assert_equal(#p._schedules, 0, "cloud schedule: use_cloud off → nothing scheduled")
end

-- nil state → nothing scheduled.
do
    local p = make_plugin{}
    PluginSync.schedule_cloud_upload(p, nil)
    h.assert_equal(#p._schedules, 0, "cloud schedule: nil state → nothing scheduled")
end

-- Configured + state → schedules on the _cloud_upload_action slot.
do
    local p = make_plugin{}
    PluginSync.schedule_cloud_upload(p, { file = "/b.epub" })
    h.assert_equal(#p._schedules, 1, "cloud schedule: one timer scheduled")
    h.assert_equal(p._schedules[1].slot, "_cloud_upload_action",
        "cloud schedule: uses the _cloud_upload_action slot")
    h.assert_equal(p._schedules[1].delay, 60,
        "cloud schedule: uses cloud_upload_delay")
end

-- Unconfigured → nothing scheduled.
do
    settings_state.cloud_configured = false
    local p = make_plugin{}
    PluginSync.schedule_cloud_upload(p, { file = "/b.epub" })
    h.assert_equal(#p._schedules, 0, "cloud schedule: unconfigured → nothing scheduled")
    settings_state.cloud_configured = true
end


-- ===========================================================================
-- do_cloud_upload
-- ===========================================================================

-- use_cloud off → no-op.
do
    local p = make_plugin{ use_cloud = false }
    PluginSync.do_cloud_upload(p, { file = "/b.epub" })
    h.assert_nil(called(p, "push_cloud_files"), "cloud upload: use_cloud off → no push")
end

-- No transport → no-op.
do
    local p = make_plugin{ no_transport = true }
    PluginSync.do_cloud_upload(p, { file = "/b.epub" })
    -- no transport object to record onto; just assert it didn't crash
    h.assert_true(true, "cloud upload: missing transport → safe no-op")
end

-- Unconfigured → no upload dispatched.
do
    settings_state.cloud_configured = false
    local p = make_plugin{}
    PluginSync.do_cloud_upload(p, { file = "/b.epub" })
    -- The dead cloud_last_upload_ok flag was removed in Phase 12.1;
    -- the observable contract is simply that nothing is pushed.
    h.assert_nil(called(p, "push_cloud_files"),
        "cloud upload: unconfigured → no upload dispatched")
    h.assert_nil(p.cloud_last_upload_ok,
        "cloud upload: unconfigured → dead cloud_last_upload_ok flag not set")
    settings_state.cloud_configured = true
end

-- Cloud unreachable (link up but no route, or the server down) → defer via the
-- cloud-scoped backoff, do not push.  This pins the wiring: do_cloud_upload
-- must gate on _isCloudReachable + _cloud_wifi_backoff (real reachability), NOT
-- the link-only _isNetworkOnline + _wifi_backoff that Syncthing (localhost)
-- uses.  `online` stays true here, so ONLY the cloud-reachability gate can defer.
do
    local p = make_plugin{ cloud_online = false }
    PluginSync.do_cloud_upload(p, { file = "/b.epub" })
    local c = called(p, "cloud_wifi_attempt")
    h.assert_true(c ~= nil,
        "cloud upload: unreachable cloud → cloud-scoped backoff scheduled")
    h.assert_equal(c.label, "cloud upload", "cloud upload: backoff labelled")
    h.assert_nil(called(p, "push_cloud_files"),
        "cloud upload: unreachable cloud → no push")
    h.assert_nil(called(p, "wifi_attempt"),
        "cloud upload: unreachable cloud → uses the cloud backoff, not the link one")
end

-- Online + configured, but both files absent on disk → no push
-- (the entries list is empty, so do_cloud_upload returns before
-- touching the transport).
do
    local p = make_plugin{}
    PluginSync.do_cloud_upload(p, { file = "/no/such/book.epub" })
    h.assert_nil(called(p, "push_cloud_files"),
        "cloud upload: no files on disk → empty entries → no push")
end


h.teardown()
