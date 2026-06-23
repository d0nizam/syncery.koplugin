-- =============================================================================
-- spec/syncthing_kosyncthing_plus_api_client_spec.lua
-- =============================================================================
--
-- Tests for syncery_transports/syncthing/kosyncthing_plus_api_client.lua.
--
-- The client wraps a synchronous `apiCall(endpoint, method, body)`
-- function (the plugin's proxy) into the same callback-shaped surface
-- HttpClient exposes.  These tests inject fake api_call functions
-- so nothing real is required.
--
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_kosyncthing_plus_api_client_spec_" .. tostring(os.time()))

local KOSyncthingPlusApiClient = require("syncery_transports/syncthing/kosyncthing_plus_api_client")
local Interface     = require("syncery_transports/interface")


-- ----------------------------------------------------------------------------
-- Constructor rejects missing api_call.
-- ----------------------------------------------------------------------------


do
    local ok = pcall(KOSyncthingPlusApiClient.new, {})
    h.assert_false(ok, "missing api_call rejected")

    local ok2 = pcall(KOSyncthingPlusApiClient.new, { api_call = "not a function" })
    h.assert_false(ok2, "non-function api_call rejected")
end


-- ----------------------------------------------------------------------------
-- get: strips the /rest/ prefix before calling apiCall (the plugin's
-- convention is endpoint-relative-to-rest).
-- ----------------------------------------------------------------------------


do
    local seen_endpoint, seen_method
    local client = KOSyncthingPlusApiClient.new({
        api_call = function(endpoint, method, _body)
            seen_endpoint = endpoint
            seen_method   = method
            return { ping = "pong" }
        end,
    })

    local got_ok, got_payload
    client:get("/rest/system/ping", function(ok, _err, payload)
        got_ok, got_payload = ok, payload
    end)

    h.assert_equal(seen_endpoint, "system/ping",
        "leading /rest/ stripped before passing to apiCall")
    h.assert_equal(seen_method, "GET",                       "method = GET")
    h.assert_true(got_ok,                                     "callback ok")
    h.assert_equal(got_payload.ping, "pong",                  "payload passed through")
end


-- ----------------------------------------------------------------------------
-- get on a path without /rest/ prefix: strip the leading slash only.
-- ----------------------------------------------------------------------------


do
    local seen_endpoint
    local client = KOSyncthingPlusApiClient.new({
        api_call = function(endpoint) seen_endpoint = endpoint; return {} end,
    })
    client:get("/config", function() end)
    h.assert_equal(seen_endpoint, "config",
        "leading slash stripped when /rest/ not present")
end


-- ----------------------------------------------------------------------------
-- A falsy result from apiCall → UNREACHABLE (the plugin's API doesn't
-- distinguish, see header rationale).
-- ----------------------------------------------------------------------------


do
    local client = KOSyncthingPlusApiClient.new({ api_call = function() return nil end })
    local got_ok, got_err
    client:get("/rest/foo", function(ok, err) got_ok, got_err = ok, err end)
    h.assert_false(got_ok,                          "nil result → not ok")
    h.assert_equal(got_err, Interface.ERRORS.UNREACHABLE,
        "nil classified as transient unreachable")
end


do
    local client = KOSyncthingPlusApiClient.new({ api_call = function() return false end })
    local got_ok, got_err
    client:get("/rest/foo", function(ok, err) got_ok, got_err = ok, err end)
    h.assert_false(got_ok, "false result → not ok")
    h.assert_equal(got_err, Interface.ERRORS.UNREACHABLE, "false → UNREACHABLE")
end


-- ----------------------------------------------------------------------------
-- apiCall raising a Lua error → INTERNAL.
-- ----------------------------------------------------------------------------


do
    local client = KOSyncthingPlusApiClient.new({ api_call = function() error("boom") end })
    local got_ok, got_err
    local call_ok = pcall(function()
        client:get("/rest/foo", function(ok, err) got_ok, got_err = ok, err end)
    end)
    h.assert_true(call_ok,                          "throw contained")
    h.assert_false(got_ok,                          "failure reported")
    h.assert_equal(got_err, Interface.ERRORS.INTERNAL, "err = INTERNAL")
end


-- ----------------------------------------------------------------------------
-- post: POST method passed through, body=nil (bodyless POST).
-- ----------------------------------------------------------------------------


do
    local seen_method, seen_body
    local client = KOSyncthingPlusApiClient.new({
        api_call = function(_e, method, body) seen_method, seen_body = method, body; return true end,
    })
    client:post("/rest/db/scan?folder=default", function() end)
    h.assert_equal(seen_method, "POST",   "post() uses POST")
    h.assert_nil(seen_body,               "no body for bare post()")
end


-- ----------------------------------------------------------------------------
-- post_json: encodes table to JSON string, passes via apiCall.
-- ----------------------------------------------------------------------------


do
    local seen_body
    local client = KOSyncthingPlusApiClient.new({
        api_call = function(_e, _m, body) seen_body = body; return true end,
    })
    client:post_json("/rest/db/ignores?folder=x", { ignore = { "*.json", "tmp/*" } },
        function() end)

    h.assert_equal(type(seen_body), "string", "body encoded to string")
    -- Verify the JSON contains our key — we don't pin exact formatting
    -- (different libs may produce different whitespace).
    h.assert_true(seen_body:match("ignore") ~= nil, "JSON contains 'ignore' key")
    h.assert_true(seen_body:match("%*%.json") ~= nil, "JSON contains *.json pattern")
end


-- ----------------------------------------------------------------------------
-- A successful post_json → callback ok with the result.
-- ----------------------------------------------------------------------------


do
    local client = KOSyncthingPlusApiClient.new({ api_call = function() return { ok = true } end })
    local got_ok, got_payload
    client:post_json("/rest/db/ignores?folder=x", { ignore = {} }, function(ok, _e, p)
        got_ok, got_payload = ok, p
    end)
    h.assert_true(got_ok,                       "success reported")
    h.assert_equal(got_payload.ok, true,         "payload threaded through")
end


-- ----------------------------------------------------------------------------
-- Callback fires exactly once per call.
-- ----------------------------------------------------------------------------


do
    local count = 0
    local client = KOSyncthingPlusApiClient.new({ api_call = function() return {} end })
    client:get("/rest/foo", function() count = count + 1 end)
    h.assert_equal(count, 1, "callback fired exactly once")
end


do
    local count = 0
    local client = KOSyncthingPlusApiClient.new({ api_call = function() return nil end })
    client:get("/rest/foo", function() count = count + 1 end)
    h.assert_equal(count, 1, "callback fired exactly once on failure too")
end
