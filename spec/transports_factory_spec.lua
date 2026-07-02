-- =============================================================================
-- spec/transports_factory_spec.lua
-- =============================================================================
--
-- Tests for syncery_transports/init.lua — the one-call factory that
-- builds the production transport stack.
--
-- The factory composes already-tested parts (the three transports +
-- orchestrator + bridge), so this spec verifies the COMPOSITION:
--   - doc_id_fn is required
--   - on_status_change is optional
--   - returned object is a Bridge (responds to push_syncthing_scan etc.)
--   - construction failure in one transport doesn't kill the stack
--
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_transports_factory_spec_" .. tostring(os.time()))

local Transports = require("syncery_transports/init")


-- ----------------------------------------------------------------------------
-- doc_id_fn required.
-- ----------------------------------------------------------------------------


do
    local ok, err = pcall(Transports.build, {})
    h.assert_false(ok, "missing doc_id_fn rejected")
    h.assert_true(tostring(err):match("doc_id_fn") ~= nil,
        "error message mentions doc_id_fn")
end


do
    local ok = pcall(Transports.build, nil)
    h.assert_false(ok, "nil opts rejected")
end


-- ----------------------------------------------------------------------------
-- Happy path: factory returns something with the bridge API.
--
-- Note: each transport's defaults pcall their own internals.  In a
-- test environment without G_reader_settings, each transport will be
-- constructible but report `is_available() == false` — which is the
-- right behaviour: no toggle on, no settings, nothing to push to.
-- ----------------------------------------------------------------------------


do
    local stack = Transports.build({ doc_id_fn = function() return "abc" end })
    h.assert_equal(type(stack), "table",                   "got a table back")
    h.assert_equal(type(stack.push_syncthing_scan), "function",
        "exposes push_syncthing_scan")
    h.assert_equal(type(stack.push_cloud_files), "function",
        "exposes push_cloud_files")
    h.assert_equal(type(stack.get_status), "function",     "exposes get_status")
    h.assert_equal(type(stack.shutdown), "function",        "exposes shutdown")
end


-- ----------------------------------------------------------------------------
-- get_status returns a table — even when no transport is configured.
-- ----------------------------------------------------------------------------


do
    local stack = Transports.build({ doc_id_fn = function() return "x" end })
    local s = stack:get_status()
    h.assert_equal(type(s), "table",        "status is a table")
    -- Without G_reader_settings, no transport is `is_available`, but
    -- they're all REGISTERED, so the status table has rows for both.
    h.assert_true(s.syncthing ~= nil,         "syncthing row present")
    h.assert_true(s.cloud     ~= nil,         "cloud row present")
end


-- ----------------------------------------------------------------------------
-- Phase 19: M.build forwards ui_cloudstorage_resolver so the Cloud transport's
-- provider selector can reach cloudstorage. End-to-end — with the cloudstorage
-- backend chosen, an FTP server, and a resolver yielding a :sync-capable
-- object, cloud status reports cloudstorage ACTIVE and AVAILABLE (ftp is syncable
-- on cloudstorage). Proves the wiring build → CloudTransport → selector →
-- cloudstorage, i.e. the production path that makes the feature live.
-- ----------------------------------------------------------------------------


do
    local saved = _G.G_reader_settings
    _G.G_reader_settings = {
        readSetting = function(_, k)
            local v = {
                syncery_use_cloud = true,
                syncery_cloud_server   = { type = "ftp" },
            }
            return v[k]
        end,
    }
    local stack = Transports.build({
        doc_id_fn = function() return "x" end,
        ui_cloudstorage_resolver = function() return { sync = function() end } end,
    })
    local s = stack:get_status()
    _G.G_reader_settings = saved  -- restore before asserting (no leak on failure)

    h.assert_true(s.cloud ~= nil, "cloud row present")
    h.assert_equal(s.cloud.cloud_provider, "cloudstorage",
        "resolver threaded through → cloudstorage selected as the active backend")
    h.assert_true(s.cloud.available,
        "ftp is syncable on cloudstorage → cloud is available end-to-end")
    h.assert_nil(s.cloud.provider_fell_back,
        "no fallback when the cloudstorage resolver is reachable")
end


-- ----------------------------------------------------------------------------
-- Phase 19: without a resolver, a cloudstorage choice falls back to syncservice
-- (the wiring is opt-in; nil resolver is safe). In-harness the syncservice
-- can't load either, so the verdict is no_backend and the fallback note is
-- suppressed rather than flagged (it only appears when the fallback works).
-- ----------------------------------------------------------------------------


do
    local saved = _G.G_reader_settings
    _G.G_reader_settings = {
        readSetting = function(_, k)
            local v = {
                syncery_use_cloud = true,
                syncery_cloud_server   = { type = "ftp" },
            }
            return v[k]
        end,
    }
    -- No ui_cloudstorage_resolver passed → cloudstorage unreachable.
    local stack = Transports.build({ doc_id_fn = function() return "x" end })
    local s = stack:get_status()
    _G.G_reader_settings = saved

    h.assert_equal(s.cloud.cloud_provider, "syncservice",
        "no resolver → cloudstorage unavailable → fell back to syncservice")
    -- In-harness the syncservice fallback can't load either → no working
    -- backend at all, so the fell_back note is suppressed (it would
    -- contradict the no_backend verdict in the status panel).
    h.assert_equal(s.cloud.state, "no_backend",
        "no resolver + unloadable syncservice → state=no_backend")
    h.assert_nil(s.cloud.provider_fell_back,
        "fell_back suppressed when the fallback backend itself is unusable")
    h.assert_false(s.cloud.available,
        "syncservice can't sync ftp → cloud unavailable")
end


-- ----------------------------------------------------------------------------
-- on_status_change is wired into the orchestrator.  We can't trigger
-- a status change without doing a real push, but we can verify it
-- doesn't crash to pass a non-nil one.
-- ----------------------------------------------------------------------------


do
    local change_count = 0
    local stack = Transports.build({
        doc_id_fn        = function() return "x" end,
        on_status_change = function() change_count = change_count + 1 end,
    })
    -- A push to an unconfigured book just no-ops in each transport;
    -- the orchestrator may or may not fire on_status_change depending
    -- on whether any transport ATTEMPTED.  We can't pin the value, but
    -- we can assert no crash:
    local ok = pcall(function() stack:push_syncthing_scan("/x.epub", {}) end)
    h.assert_true(ok, "push with on_status_change set doesn't crash")
end


-- ----------------------------------------------------------------------------
-- shutdown can be called repeatedly without crashing (bridge proxies
-- through; orchestrator handles idempotency).
-- ----------------------------------------------------------------------------


do
    local stack = Transports.build({ doc_id_fn = function() return "x" end })
    local ok1 = pcall(function() stack:shutdown() end)
    local ok2 = pcall(function() stack:shutdown() end)
    h.assert_true(ok1, "first shutdown ok")
    h.assert_true(ok2, "second shutdown ok (orchestrator is idempotent)")
end
