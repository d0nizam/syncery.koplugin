-- =============================================================================
-- spec/transport_http_client_spec.lua
-- =============================================================================
--
-- Tests for syncery_transports/http_client.lua.
--
-- The client is dependency-injected at construction (request_fn), so
-- these tests never touch the network.  Every test builds an
-- HttpClient with a fake request_fn that returns canned (body, code)
-- pairs and asserts on the resulting callback shape.
--
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_http_client_spec_" .. tostring(os.time()))

local HttpClient = require("syncery_transports/http_client")
local Interface  = require("syncery_transports/interface")


-- ----------------------------------------------------------------------------
-- url_encode: standard percent-encoding behaviour.
-- ----------------------------------------------------------------------------


do
    h.assert_equal(HttpClient.url_encode("abc123"), "abc123",
        "unreserved chars pass through")
    h.assert_equal(HttpClient.url_encode("hello world"), "hello%20world",
        "space → %20")
    h.assert_equal(HttpClient.url_encode("a/b"), "a%2Fb",
        "slash is encoded (use url_encode_path if you want it preserved)")
    h.assert_equal(HttpClient.url_encode(nil), "",
        "nil → empty string (so it composes safely)")
    h.assert_equal(HttpClient.url_encode(""), "",
        "empty → empty")
end


-- ----------------------------------------------------------------------------
-- url_encode_path: preserves slashes; encodes each segment.
-- ----------------------------------------------------------------------------


do
    h.assert_equal(HttpClient.url_encode_path("Library/Foo.epub"), "Library/Foo.epub",
        "simple path passes through")
    h.assert_equal(HttpClient.url_encode_path("Hello World/file name.txt"),
        "Hello%20World/file%20name.txt", "spaces encoded per-segment, slashes preserved")
    h.assert_equal(HttpClient.url_encode_path(nil), "", "nil → empty")
    h.assert_equal(HttpClient.url_encode_path(""), "", "empty → empty")
end


-- ----------------------------------------------------------------------------
-- classify_response: every documented status → expected (ok, err).
-- ----------------------------------------------------------------------------


do
    local ok, err = HttpClient.classify_response("", 200)
    h.assert_true(ok,                 "200 → ok")
    h.assert_nil(err,                 "200 → no err")
end

do
    local ok, err = HttpClient.classify_response('{"x":1}', 201)
    h.assert_true(ok,                 "201 → ok")
    h.assert_nil(err,                 "201 → no err")
end

do
    local ok, err = HttpClient.classify_response("", 204)
    h.assert_true(ok,                 "204 → ok")
    h.assert_nil(err,                 "204 → no err")
end

do
    local ok, err = HttpClient.classify_response("Unauthorized", 401)
    h.assert_false(ok,                            "401 → not ok")
    h.assert_equal(err, Interface.ERRORS.AUTH_FAILED, "401 → AUTH_FAILED")
end

do
    local ok, err = HttpClient.classify_response("Forbidden", 403)
    h.assert_false(ok,                            "403 → not ok")
    h.assert_equal(err, Interface.ERRORS.AUTH_FAILED, "403 → AUTH_FAILED")
end

do
    local ok, err = HttpClient.classify_response("Not Found", 404)
    h.assert_false(ok,                          "404 → not ok")
    h.assert_equal(err, Interface.ERRORS.REJECTED, "404 → REJECTED")
end

do
    local ok, err = HttpClient.classify_response("Conflict", 409)
    h.assert_false(ok,                          "409 → not ok")
    h.assert_equal(err, Interface.ERRORS.REJECTED, "any 4xx → REJECTED")
end

do
    local ok, err = HttpClient.classify_response("Server Error", 500)
    h.assert_false(ok,                              "500 → not ok")
    h.assert_equal(err, Interface.ERRORS.UNREACHABLE,
        "5xx → UNREACHABLE (transient — retry will hit it)")
end

do
    local ok, err = HttpClient.classify_response("Bad Gateway", 502)
    h.assert_false(ok,                              "502 → not ok")
    h.assert_equal(err, Interface.ERRORS.UNREACHABLE, "502 → UNREACHABLE")
end

do
    -- Network failure: LuaSocket returns (nil, "timeout") shape.
    local ok, err = HttpClient.classify_response(nil, "timeout")
    h.assert_false(ok,                              "nil+string → not ok")
    h.assert_equal(err, Interface.ERRORS.UNREACHABLE, "nil+string → UNREACHABLE")
end

do
    local ok, err = HttpClient.classify_response(nil, nil)
    h.assert_false(ok,                              "nil+nil → not ok")
    h.assert_equal(err, Interface.ERRORS.UNREACHABLE, "nil+nil → UNREACHABLE")
end

do
    -- Defensive: empty-body + string-code (unusual but seen in edge
    -- proxy configs).  Treated as unreachable for safety.
    local ok, err = HttpClient.classify_response("", "connection refused")
    h.assert_false(ok,                              "empty+string → not ok")
    h.assert_equal(err, Interface.ERRORS.UNREACHABLE, "treated as unreachable")
end


-- ----------------------------------------------------------------------------
-- Constructor: requires base_url and api_key; normalizes trailing slash.
-- ----------------------------------------------------------------------------


do
    -- Trailing slash normalized away.
    local ok = pcall(HttpClient.new, { base_url = "http://x:8384/", api_key = "" })
    h.assert_true(ok, "trailing slash construction succeeds")
    -- We can't directly inspect _base_url without breaking encapsulation,
    -- but the request test below exercises the normalized URL.
end

do
    -- Missing base_url is loud (assert).
    local ok = pcall(HttpClient.new, { api_key = "x" })
    h.assert_false(ok, "missing base_url rejected")
end

do
    -- Empty base_url is loud (an empty base would silently make every
    -- request go to a relative URL — much worse than a clear error).
    local ok = pcall(HttpClient.new, { base_url = "", api_key = "x" })
    h.assert_false(ok, "empty base_url rejected")
end

do
    -- Auth headers now optional (was required in chunk 3).  Both no
    -- auth (probably hits a 401 from the server, but we still allow
    -- construction) and empty api_key are accepted.
    local ok1 = pcall(HttpClient.new, { base_url = "http://x" })
    h.assert_true(ok1, "no auth headers is allowed (server will 401; we map it)")

    local ok2 = pcall(HttpClient.new, { base_url = "http://x", api_key = "" })
    h.assert_true(ok2, "empty api_key allowed")

    -- Non-string api_key is a programmer-error type bug → loud.
    local ok3 = pcall(HttpClient.new, { base_url = "http://x", api_key = 42 })
    h.assert_false(ok3, "non-string api_key rejected")

    -- Non-table headers → also loud.
    local ok4 = pcall(HttpClient.new,
        { base_url = "http://x", headers = "not a table" })
    h.assert_false(ok4, "non-table headers rejected")
end


-- ----------------------------------------------------------------------------
-- Custom headers (the REST use case): headers table is merged into
-- the per-request header set.
-- ----------------------------------------------------------------------------


do
    local got_req
    local client = HttpClient.new({
        base_url   = "http://x",
        headers    = {
            ["x-auth-user"] = "alice",
            ["x-auth-key"]  = "deadbeef",
        },
        request_fn = function(req) got_req = req; return "", 200 end,
    })
    client:get("/foo", function() end)

    h.assert_equal(got_req.headers["x-auth-user"], "alice",
        "custom header passed through")
    h.assert_equal(got_req.headers["x-auth-key"], "deadbeef",
        "second custom header passed through")
    h.assert_nil(got_req.headers["X-API-Key"],
        "no X-API-Key when api_key not given")
end


-- ----------------------------------------------------------------------------
-- Custom headers override the api_key shortcut for X-API-Key if both
-- are passed (explicit beats implicit).
-- ----------------------------------------------------------------------------


do
    local got_req
    local client = HttpClient.new({
        base_url   = "http://x",
        api_key    = "default",
        headers    = { ["X-API-Key"] = "explicit" },
        request_fn = function(req) got_req = req; return "", 200 end,
    })
    client:get("/foo", function() end)
    h.assert_equal(got_req.headers["X-API-Key"], "explicit",
        "explicit X-API-Key in headers wins over api_key shortcut")
end


-- ----------------------------------------------------------------------------
-- A second request doesn't see headers leaked from the previous one
-- (the base_headers table is copied per request).
-- ----------------------------------------------------------------------------


do
    local seen = {}
    local client = HttpClient.new({
        base_url   = "http://x",
        api_key    = "k",
        request_fn = function(req) table.insert(seen, req); return "", 200 end,
    })
    -- First a POST (which adds Content-Length: 0).
    client:post("/foo", function() end)
    h.assert_equal(seen[1].headers["Content-Length"], "0",
        "POST sets Content-Length: 0")

    -- Then a GET — must NOT have Content-Length.
    client:get("/bar", function() end)
    h.assert_nil(seen[2].headers["Content-Length"],
        "GET does not inherit POST's Content-Length (per-request header copy)")
end


-- ----------------------------------------------------------------------------
-- A successful GET fires callback with (true, nil, body).
-- ----------------------------------------------------------------------------


do
    local got_req, got_ok, got_err, got_body
    local fake_request_fn = function(req)
        got_req = req
        return '{"ping":"pong"}', 200
    end
    local client = HttpClient.new({
        base_url   = "http://127.0.0.1:8384/",   -- trailing slash to verify normalization
        api_key    = "secret",
        request_fn = fake_request_fn,
    })

    client:get("/rest/system/ping", function(ok, err, body)
        got_ok, got_err, got_body = ok, err, body
    end)

    h.assert_true(got_req ~= nil, "request_fn was called")
    h.assert_equal(got_req.url, "http://127.0.0.1:8384/rest/system/ping",
        "trailing slash in base_url was normalized")
    h.assert_equal(got_req.method, "GET", "method passed through")
    h.assert_equal(got_req.headers["X-API-Key"], "secret",
        "API key in X-API-Key header")
    h.assert_equal(got_req.headers["Connection"], "close",
        "Connection: close set")

    h.assert_true(got_ok,                       "callback ok=true")
    h.assert_nil(got_err,                       "callback err=nil")
    h.assert_equal(got_body, '{"ping":"pong"}',   "body passed through")
end


-- ----------------------------------------------------------------------------
-- A POST request sets Content-Length: 0 on bodyless POSTs.
-- ----------------------------------------------------------------------------


do
    local got_req
    local client = HttpClient.new({
        base_url   = "http://127.0.0.1:8384",
        api_key    = "k",
        request_fn = function(req) got_req = req; return "", 204 end,
    })
    client:post("/rest/db/scan?folder=default", function() end)

    h.assert_equal(got_req.method, "POST", "POST method")
    h.assert_equal(got_req.headers["Content-Length"], "0",
        "Content-Length: 0 on bodyless POST (strict proxies need it)")
end


-- ----------------------------------------------------------------------------
-- 401 → AUTH_FAILED in the callback.
-- ----------------------------------------------------------------------------


do
    local got_ok, got_err
    local client = HttpClient.new({
        base_url   = "http://x",
        api_key    = "wrong",
        request_fn = function() return "Unauthorized", 401 end,
    })
    client:get("/rest/system/ping", function(ok, err) got_ok, got_err = ok, err end)
    h.assert_false(got_ok,                          "401 → ok=false")
    h.assert_equal(got_err, Interface.ERRORS.AUTH_FAILED, "err=AUTH_FAILED")
end


-- ----------------------------------------------------------------------------
-- Network failure (nil body + string code) → UNREACHABLE.
-- ----------------------------------------------------------------------------


do
    local got_ok, got_err
    local client = HttpClient.new({
        base_url   = "http://nope",
        api_key    = "k",
        request_fn = function() return nil, "connection refused" end,
    })
    client:get("/rest/system/ping", function(ok, err) got_ok, got_err = ok, err end)
    h.assert_false(got_ok,                          "network failure → ok=false")
    h.assert_equal(got_err, Interface.ERRORS.UNREACHABLE, "err=UNREACHABLE")
end


-- ----------------------------------------------------------------------------
-- A request_fn that THROWS → INTERNAL.  The client must not propagate.
-- ----------------------------------------------------------------------------


do
    local got_ok, got_err
    local client = HttpClient.new({
        base_url   = "http://x",
        api_key    = "k",
        request_fn = function() error("kaboom") end,
    })
    local call_ok = pcall(function()
        client:get("/foo", function(ok, err) got_ok, got_err = ok, err end)
    end)
    h.assert_true(call_ok,                         "throw is contained")
    h.assert_false(got_ok,                         "callback reports failure")
    h.assert_equal(got_err, Interface.ERRORS.INTERNAL, "err=INTERNAL")
end


-- ----------------------------------------------------------------------------
-- Callback fires exactly once per call (smoke test of the contract).
-- ----------------------------------------------------------------------------


do
    local count = 0
    local client = HttpClient.new({
        base_url   = "http://x",
        api_key    = "k",
        request_fn = function() return "", 200 end,
    })
    client:get("/foo", function() count = count + 1 end)
    h.assert_equal(count, 1, "GET fires callback exactly once")
end


do
    local count = 0
    local client = HttpClient.new({
        base_url   = "http://x",
        api_key    = "k",
        request_fn = function() return nil, "timeout" end,
    })
    client:get("/foo", function() count = count + 1 end)
    h.assert_equal(count, 1, "GET-with-failure also fires exactly once")
end


-- ── timeout_for: the {block, total} derivation (#1 socketutil fix) ────────────
-- The synchronous socket.http.request blocks the UI on a slow/half-open
-- server; get_default_request_fn wraps it in a socketutil set/reset using
-- these values.  timeout_for is the pure derivation, exposed for testing.
do
    local b, t = HttpClient.timeout_for(5)
    h.assert_equal(b, 5,  "timeout_for(5): block = 5")
    h.assert_equal(t, 10, "timeout_for(5): total = 10 (2x block)")

    local b2, t2 = HttpClient.timeout_for(nil)
    h.assert_equal(b2, 5,  "timeout_for(nil): defaults block 5")
    h.assert_equal(t2, 10, "timeout_for(nil): defaults total 10")

    local b3, t3 = HttpClient.timeout_for(12)
    h.assert_equal(b3, 12, "timeout_for(12): block follows the knob")
    h.assert_equal(t3, 24, "timeout_for(12): total = 2x knob")
end


-- ── gating: injected request_fns must NOT receive the timeout fields ─────────
-- The timeout is threaded onto req only on the default (real-network) path
-- (`not self._request_fn`); injected fns own their own timeouts per the
-- constructor contract.  This guards against the fix leaking into the test
-- seam (and into every other injected caller).
do
    local captured
    local client = HttpClient.new({
        base_url   = "http://x",
        api_key    = "k",
        request_fn = function(req) captured = req; return "", 200 end,
    })
    client:get("/foo", function() end)
    h.assert_nil(captured._block_timeout,
        "injected request_fn: _block_timeout not set (default-path gate)")
    h.assert_nil(captured._total_timeout,
        "injected request_fn: _total_timeout not set (default-path gate)")
end


-- ----------------------------------------------------------------------------
-- HTTPS support (Phase: BasicSync / TLS Syncthing daemons).  A client built
-- with an https:// base_url tags requests with LuaSec TLS params (verify=
-- "none" for self-signed, confirmed 200 OK against BasicSync) so ssl.https
-- accepts the cert; an http:// client must NOT carry these params (socket.http
-- ignores them, but absence proves the scheme gate works).
-- ----------------------------------------------------------------------------
do
    -- https client → req carries verify="none" + protocol/options.
    local captured
    local client = HttpClient.new({
        base_url   = "https://192.168.0.103:8384",
        api_key    = "k",
        request_fn = function(req) captured = req; return "", 200 end,
    })
    client:get("/rest/system/status", function() end)
    h.assert_equal(captured.verify, "none",
        "https client: req.verify='none' (accepts Syncthing self-signed cert)")
    h.assert_equal(captured.protocol, "any",
        "https client: req.protocol='any' (negotiate modern TLS)")
    h.assert_equal(captured.options, "all",
        "https client: req.options='all'")
    -- X-API-Key still present over https (auth unchanged — 200 OK confirmed).
    h.assert_equal(captured.headers["X-API-Key"], "k",
        "https client: X-API-Key header unchanged")
end

do
    -- http client → NO TLS params (scheme gate keeps http path clean).
    local captured
    local client = HttpClient.new({
        base_url   = "http://127.0.0.1:8384",
        api_key    = "k",
        request_fn = function(req) captured = req; return "", 200 end,
    })
    client:get("/rest/system/status", function() end)
    h.assert_nil(captured.verify,
        "http client: req.verify not set (scheme gate)")
    h.assert_nil(captured.protocol,
        "http client: req.protocol not set (scheme gate)")
end

do
    -- No-scheme base_url defaults to http (no TLS params) — preserves prior
    -- behaviour for any caller that passed a bare host.
    local captured
    local client = HttpClient.new({
        base_url   = "10.0.0.5:8384",
        api_key    = "k",
        request_fn = function(req) captured = req; return "", 200 end,
    })
    client:get("/x", function() end)
    h.assert_nil(captured.verify,
        "no-scheme base_url: treated as http (no verify param)")
end


-- ----------------------------------------------------------------------------
-- Bodyless GET: response body captured from sink (not from return value).
--
-- socket.http / ssl.https in complex form (table argument) ALWAYS return
-- (1, code, ...) on success — the body is NOT in the return values; it is
-- drained into the caller-supplied sink.  A strict fake simulates this:
-- it pumps the body into req.sink and returns (1, 200), exactly like the
-- real socket.http.  Without the ltn12-sink fix the body would be "1" (the
-- number) instead of the real JSON string.
-- ----------------------------------------------------------------------------
do
    -- Strict fake: body goes into req.sink ONLY; return shape is (1, code).
    -- If req.sink is absent (fix not applied) the body is silently discarded.
    local BODY = '{"version":"v1.27.0","codename":"Fermium Fox"}'
    local function strict_socket_fake(req)
        if req.sink then
            req.sink(BODY, nil)  -- push one body chunk
            req.sink(nil,  nil)  -- end of stream
        end
        return 1, 200            -- socket.http complex-form return shape
    end
    local client = HttpClient.new({
        base_url   = "https://127.0.0.1:8384",
        api_key    = "k",
        request_fn = strict_socket_fake,
    })
    local got_ok, got_err, got_body
    client:get("/rest/system/version", function(ok, err, body)
        got_ok, got_err, got_body = ok, err, body
    end)
    h.assert_true(got_ok,              "strict-socket GET: ok (200)")
    h.assert_nil(got_err,              "strict-socket GET: no error")
    h.assert_equal(got_body, BODY,
        "strict-socket GET: body captured from sink (not the number 1)")
end


do
    -- Network failure: socket.http returns (nil, "error msg") — no sink pump.
    -- Body should be empty string (table.concat of empty chunks), and
    -- classify_response sees nil code → UNREACHABLE.
    local function failing_socket_fake(_req)
        return nil, "connection refused"
    end
    local client = HttpClient.new({
        base_url   = "https://127.0.0.1:8384",
        api_key    = "k",
        request_fn = failing_socket_fake,
    })
    local got_ok, got_err
    client:get("/rest/system/version", function(ok, err, _body)
        got_ok, got_err = ok, err
    end)
    h.assert_false(got_ok,             "strict-socket GET failure: not ok")
    h.assert_equal(got_err, "unreachable",
        "strict-socket GET failure: unreachable")
end
