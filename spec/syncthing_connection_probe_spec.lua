-- =============================================================================
-- spec/syncthing_connection_probe_spec.lua
-- =============================================================================
--
-- Locks H.test_syncthing_connection's scheme auto-probe (Option A):
--   • tries https first, then http on a NO-RESPONSE miss,
--   • persists the working scheme so normal operation skips re-probing,
--   • a daemon that ANSWERS on https (even to reject the key) confirms https —
--     http is NOT probed in that case.
--
-- The real function is exercised; only the HTTP client is faked (via the
-- injectable client_factory parameter), and the menu_test_support Settings
-- stub is patched into a tiny configurable store so we can drive inputs and
-- observe the persisted scheme.  No sockets, no real Syncthing.
-- =============================================================================


local h            = require("spec.test_helpers")
local menu_support = require("spec.menu_test_support")
h.setup("/tmp/syncery_conn_probe_spec_" .. tostring(os.time()))
menu_support.install_stubs()   -- _helpers requires UIManager/InfoMessage/logger

-- _helpers captured Settings = the menu_test_support stub TABLE.  Patch that
-- same table's syncthing accessors to a small store (the stub lacks scheme/port
-- accessors and only records set_* calls), so the probe reads our inputs and we
-- can read back what it persisted.  `store` is reassigned per test; the closures
-- capture the variable, so they always see the current table.
local Settings = package.loaded["syncery_settings"]
local store = {}
Settings.get_syncthing_api_key = function() return store.api_key or "" end
Settings.get_syncthing_port    = function() return store.port or 8384 end
Settings.get_syncthing_scheme  = function() return store.scheme or "http" end
Settings.set_syncthing_scheme  = function(v) store.scheme = v end

local H = require("syncery_ui/menu/_helpers")


-- Fake client factory.  `script` maps a scheme ("http"/"https") to the result
-- its :get should deliver: { ok = bool, err = string|nil, status = number|nil }.
-- A scheme absent from the script behaves as a no-response miss.
local function fake_factory(script)
    return function(opts)
        local scheme = opts.base_url:match("^(https?)://")
        return {
            get = function(_self, _path, cb)
                local r = script[scheme] or { ok = false, err = "unreachable" }
                cb(r.ok, r.err, nil, r.status)
            end,
        }
    end
end


-- Run the probe synchronously (the fake :get calls back inline); collect the
-- callback args plus the scheme that ended up persisted.
local function run(api_key, script, initial_scheme)
    store = { api_key = api_key, scheme = initial_scheme }
    local got = {}
    H.test_syncthing_connection(function(ok, code, diag)
        got.ok, got.code, got.diag = ok, code, diag
    end, fake_factory(script))
    got.scheme = store.scheme
    return got
end


-- 1. No API key → no_api_key, before any network attempt.
do
    local r = run("", {})
    h.assert_false(r.ok, "no api key → not ok")
    h.assert_equal(r.diag, "no_api_key", "diag is no_api_key")
end


-- 2. https answers OK → success; scheme persisted as https.
do
    local r = run("k", { https = { ok = true, status = 200 } })
    h.assert_true(r.ok, "https OK → success")
    h.assert_equal(r.code, 200, "status 200 surfaced")
    h.assert_equal(r.diag, "ok", "diag ok")
    h.assert_equal(r.scheme, "https", "https persisted")
end


-- 3. https misses (no response), http answers OK → success; scheme → http.
do
    local r = run("k", { https = { ok = false, err = "unreachable" },
                         http  = { ok = true,  status = 200 } })
    h.assert_true(r.ok, "http OK after https miss → success")
    h.assert_equal(r.scheme, "http", "http persisted after https miss")
end


-- 4. both schemes miss → unreachable; scheme NOT upgraded (stays as it was).
do
    local r = run("k", { http  = { ok = false, err = "unreachable" },
                         https = { ok = false, err = "unreachable" } }, "http")
    h.assert_false(r.ok, "both miss → not ok")
    h.assert_equal(r.diag, "unreachable", "diag unreachable")
    h.assert_equal(r.scheme, "http", "neither stored → scheme unchanged")
end


-- 5. https RESPONDS but rejects the key (401) → auth_failed; scheme persisted
--    https; http is NOT probed even though it WOULD succeed here.
do
    local r = run("k", { https = { ok = false, err = "rejected", status = 401 },
                         http  = { ok = true,  status = 200 } })  -- must NOT be reached
    h.assert_false(r.ok, "401 → not ok")
    h.assert_equal(r.code, 401, "status 401 surfaced")
    h.assert_equal(r.diag, "auth_failed", "diag auth_failed")
    h.assert_equal(r.scheme, "https",
        "an https response confirms the scheme; http not probed")
end
