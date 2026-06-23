-- =============================================================================
-- syncery_transports/http_client.lua
-- =============================================================================
--
-- A small, dependency-injectable HTTP client.  Used by every transport
-- that talks to a real server (Syncthing's REST;
-- Cloud has its own KOReader-supplied path).
--
-- The client does ONE thing: send one request, classify the response,
-- fire one callback.  Anything else — retries, backoff, reachability
-- caching, scheduling — belongs in the orchestrator or in policy.
-- Keeping http_client this narrow is what lets it be the same code
-- for Syncthing and any future REST transport.
--
-- WHAT GETS INJECTED, WHY
--
-- The constructor takes an OPTIONAL `request_fn`.  When provided, the
-- client uses it instead of `socket.http.request`.  Two reasons:
--
--   1. Tests.  Real HTTP is the last thing a unit test should touch.
--      Passing a fake `request_fn` lets us assert "called with this
--      URL, returns this canned body".  No network, no daemon.
--
--   2. KOReader portability.  Some KOReader builds proxy network IO
--      through a different layer.  The injection point gives the
--      plugin a single seam to swap it out if the default ever stops
--      working on a target.
--
-- The default `request_fn` is socket.http.request, lazy-loaded on
-- first use — we don't `require("socket.http")` at module load
-- because the test environment doesn't have it.
--
-- ERROR CLASSIFICATION
--
-- All non-success responses are mapped onto the documented
-- `Interface.ERRORS` strings.  Mapping lives in `classify_response`,
-- exposed as a module-level pure function so policy/tests can call it
-- without instantiating a client.
--
--   200 / 201 / 204                  → ok (true, nil)
--   401 / 403                        → AUTH_FAILED  (config_needed)
--   404                              → REJECTED     (permanent)
--   any other 4xx                    → REJECTED
--   5xx, 1xx, 3xx                    → UNREACHABLE  (transient — try again)
--   nil body / non-numeric code      → UNREACHABLE  (network failure)
--   the request_fn itself raised     → INTERNAL     (transient — try again)
--
-- The "non-numeric code" branch covers LuaSocket's behavior of
-- returning (nil, "timeout") or (nil, "connection refused") on
-- network failures.
--
-- =============================================================================


local Log       = require("syncery_transports/log")
local Interface = require("syncery_transports/interface")
local log       = Log.tag("http_client")


local HttpClient = {}
HttpClient.__index = HttpClient


-- ----------------------------------------------------------------------------
-- URL encoding (pure helpers).  Exposed because transports may need
-- to assemble URLs themselves (e.g. building a "sub" query parameter
-- from a book path).
-- ----------------------------------------------------------------------------


--- Percent-encode every byte that isn't unreserved.
function HttpClient.url_encode(s)
    if not s then return "" end
    return (s:gsub("[^%w%-%.%_%~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end


--- Encode a path-shaped string: percent-encode each segment but keep
--- slashes intact.  Required by Syncthing's `sub` parameter, which
--- expects a relative path like "Library/Foo.epub" with the slashes
--- preserved.
function HttpClient.url_encode_path(p)
    if not p or p == "" then return "" end
    local parts = {}
    for part in p:gmatch("[^/]+") do
        table.insert(parts, HttpClient.url_encode(part))
    end
    return table.concat(parts, "/")
end


-- ----------------------------------------------------------------------------
-- Response classification (pure).
-- ----------------------------------------------------------------------------


--- Map (body, code) to (ok, error_class).  Pure: same inputs → same
--- outputs, no side effects.
---@param body string|nil   the response body (or nil if no response)
---@param code number|string|nil  HTTP status code, or LuaSocket error string
---@return boolean ok
---@return string|nil error_class   one of Interface.ERRORS or nil on ok
--- Derive {block, total} socket-timeout seconds from a single timeout_sec
--- knob.  {ts, ts*2} — the {5, 10} shape KOSyncClient uses for short
--- user-initiated requests (its AUTH_TIMEOUTS).  Exposed as a pure function
--- so policy/tests can call it without instantiating a client; `_request`
--- threads the result onto the default-path req table.
---@param timeout_sec number|nil   the per-client knob (constructor default 5)
---@return number block_timeout
---@return number total_timeout
function HttpClient.timeout_for(timeout_sec)
    local ts = timeout_sec or 5
    return ts, ts * 2
end


function HttpClient.classify_response(body, code)
    -- Network failure: body is nil and code is either nil or a string
    -- (LuaSocket's error message).  We treat both shapes the same.
    if body == nil and type(code) ~= "number" then
        return false, Interface.ERRORS.UNREACHABLE
    end
    if type(code) ~= "number" then
        -- Some socket setups return body="" with a string code; treat
        -- as unreachable for safety.
        return false, Interface.ERRORS.UNREACHABLE
    end

    if code == 200 or code == 201 or code == 204 then
        return true, nil
    end
    if code == 401 or code == 403 then
        return false, Interface.ERRORS.AUTH_FAILED
    end
    if code >= 400 and code < 500 then
        -- 404 and any other 4xx: client error, won't fix itself by retrying.
        return false, Interface.ERRORS.REJECTED
    end
    -- 5xx, 1xx, 3xx (if redirect_following is off): treat as transient.
    return false, Interface.ERRORS.UNREACHABLE
end


-- ----------------------------------------------------------------------------
-- Default request_fn resolver.
--
-- We don't load socket.http at module load — the test environment
-- doesn't have it, and we don't want to crash on `require` in tests
-- that never call into the network code anyway.  Instead, we resolve
-- it lazily on first use by a client that didn't inject one.
-- ----------------------------------------------------------------------------


local _resolved_http_fn  = nil
local _resolved_https_fn = nil

-- Build the socketutil-wrapped request function for a given underlying
-- request implementation (socket.http.request or ssl.https.request).  The
-- wrapper applies KOReader's bounded socket timeout (block/total ride on the
-- req table, set by _request) so a slow/half-open server can't hang the UI.
local function wrap_with_timeout(request_impl)
    local ok_su, socketutil = pcall(require, "socketutil")
    return function(req)
        if ok_su then
            socketutil:set_timeout(req._block_timeout or 5, req._total_timeout or 10)
        end
        local a, b, c = request_impl(req)
        if ok_su then socketutil:reset_timeout() end
        return a, b, c
    end
end

local function get_http_request_fn()
    if _resolved_http_fn then return _resolved_http_fn end
    local ok_http, http = pcall(require, "socket.http")
    if not ok_http or not http or type(http.request) ~= "function" then
        error("HttpClient: socket.http unavailable; pass request_fn explicitly")
    end
    _resolved_http_fn = wrap_with_timeout(http.request)
    return _resolved_http_fn
end

local function get_https_request_fn()
    if _resolved_https_fn then return _resolved_https_fn end
    local ok_https, https = pcall(require, "ssl.https")
    if not ok_https or not https or type(https.request) ~= "function" then
        error("HttpClient: ssl.https unavailable; this platform/build lacks "
            .. "LuaSec, so https:// endpoints cannot be reached")
    end
    -- luasec's ssl.https forces its own _M.TIMEOUT (default 60s) onto the
    -- socket inside its create function, which would override socketutil
    -- and let a TLS handshake to a dead/slow daemon block for a minute.
    -- Clamp it to the bounded total so https behaves like http on failure.
    -- (pcall: TIMEOUT is a plain field on the module table; guard anyway.)
    pcall(function() https.TIMEOUT = 10 end)
    _resolved_https_fn = wrap_with_timeout(https.request)
    return _resolved_https_fn
end

-- Scheme-aware resolver: "https" → ssl.https, anything else → socket.http.
local function get_default_request_fn(scheme)
    if scheme == "https" then return get_https_request_fn() end
    return get_http_request_fn()
end


-- ----------------------------------------------------------------------------
-- Constructor.
-- ----------------------------------------------------------------------------


--- Build a new HttpClient.
--- Required opts:
---   base_url — string, the protocol+host[:port] prefix.  Trailing
---              slashes are normalized away.  Example: "http://127.0.0.1:8384".
---
--- Authentication shape — pass ONE of:
---   api_key  — string, sets the `X-API-Key` header.  Syncthing-style.
---              Empty string allowed (Syncthing rejects with 403, which
---              classify_response maps to AUTH_FAILED — the right thing).
---   headers  — table of additional headers to merge into every request.
---              Used for transports whose auth shape isn't a single
---              X-API-Key header.
---
--- Passing both is allowed; explicit entries in `headers` win over
--- `api_key`'s X-API-Key shortcut.  Passing neither is also allowed
--- — Connect-then-401 flows go through classify_response normally.
---
--- Optional opts:
---   request_fn   — see "WHAT GETS INJECTED, WHY" at the top of file.
---   timeout_sec  — request timeout in seconds.  Default 10.
---                  (Used only when the default request_fn is in play;
---                  injected fns are responsible for their own timeouts.)
function HttpClient.new(opts)
    opts = opts or {}
    assert(type(opts.base_url) == "string" and opts.base_url ~= "",
        "HttpClient.new: base_url required (non-empty string)")
    -- One of api_key OR headers must be present (or neither — for tests).
    -- api_key with a non-string is loud; headers with a non-table is loud.
    if opts.api_key ~= nil then
        assert(type(opts.api_key) == "string",
            "HttpClient.new: api_key must be a string when provided")
    end
    if opts.headers ~= nil then
        assert(type(opts.headers) == "table",
            "HttpClient.new: headers must be a table when provided")
    end

    -- Build the default header set once.  Each request copies and
    -- augments (no mutation of the shared base) so a per-request
    -- Content-Length addition doesn't leak.
    local base_headers = { ["Connection"] = "close" }
    if opts.api_key then base_headers["X-API-Key"] = opts.api_key end
    if opts.headers then
        for k, v in pairs(opts.headers) do base_headers[k] = v end
    end

    local self = setmetatable({}, HttpClient)
    self._base_url     = opts.base_url:gsub("/+$", "")
    self._base_headers = base_headers
    self._timeout_sec  = opts.timeout_sec or 5
    self._request_fn   = opts.request_fn   -- nil → lazy resolve at call time
    -- Scheme decides which transport the lazy resolver picks: "http" →
    -- socket.http (plain), "https" → ssl.https (TLS).  Recorded per-client
    -- so an http and an https client can coexist without a shared cache
    -- choosing the wrong one.  Defaults to "http" when the URL has no
    -- recognizable scheme (keeps the previous behaviour).
    self._scheme       = opts.base_url:match("^(https?)://") or "http"
    return self
end


-- ----------------------------------------------------------------------------
-- The single internal request entry point.  Builds the req_table the
-- way socket.http expects, calls request_fn under pcall, and classifies
-- the result.
-- ----------------------------------------------------------------------------


function HttpClient:_request(method, path, callback, opts)
    opts = opts or {}
    local req_fn = self._request_fn or get_default_request_fn(self._scheme)

    -- Shallow-copy the base headers; per-request additions (Content-Length,
    -- Content-Type) live on the copy so the shared base stays clean
    -- and a future PUT call doesn't see stale Content-Length from a
    -- previous POST.
    local headers = {}
    for k, v in pairs(self._base_headers) do headers[k] = v end

    local req = {
        url     = self._base_url .. path,
        method  = method,
        headers = headers,
    }

    -- Default (real-network) path only: thread the bounded timeout onto req
    -- so the socketutil wrapper in get_default_request_fn can apply it.
    -- Injected request_fns own their own timeouts (constructor contract), so
    -- they never see these fields.  block = _timeout_sec (default 5), total =
    -- 2× that — the {5, 10} shape KOSyncClient uses for user-initiated short
    -- requests (its AUTH_TIMEOUTS).
    if not self._request_fn then
        req._block_timeout, req._total_timeout =
            HttpClient.timeout_for(self._timeout_sec)
    end

    -- For https clients, hand the TLS parameters to whatever request_fn runs
    -- (ssl.https on the default path; an injected fn otherwise).  verify=
    -- "none" accepts Syncthing's self-signed / Syncthing-generated cert (the
    -- documented `curl -k` case; confirmed 200 OK against BasicSync).
    -- protocol="any" + options="all" mirror luasec's own string-URL defaults
    -- so a modern TLS version is negotiated.  socket.http ignores these on
    -- the http path, so setting them only for https is both sufficient and
    -- harmless.  Set regardless of injection: a real https request_fn needs
    -- them, and it keeps the behaviour observable/testable.
    if self._scheme == "https" then
        req.protocol = "any"
        req.verify   = "none"
        req.options  = "all"
    end

    -- Body handling.  Three cases:
    --   no body          → Content-Length: 0 on POST/PUT
    --   text body        → caller supplied a string; pass as-is
    --   table body       → caller wants JSON; we encode and set Content-Type
    --
    -- We don't encode unless `opts.body` AND `opts.json == true` because
    -- some transports (Syncthing's /rest/db/scan) want bodyless POSTs
    -- and a spurious Content-Type: application/json header is documented
    -- to occasionally trip strict reverse proxies.
    local body_str = nil
    if opts.body ~= nil then
        if opts.json then
            local ok_json, cjson = pcall(require, "cjson")
            if not ok_json then
                -- KOReader bundles rapidjson; try that.
                local ok_rj, rj = pcall(require, "rapidjson")
                if ok_rj then cjson = rj else
                    log.warn("no JSON library; aborting request to %s", req.url)
                    callback(false, Interface.ERRORS.INTERNAL, nil)
                    return
                end
            end
            local ok_enc, encoded = pcall(cjson.encode, opts.body)
            if not ok_enc then
                log.warn("JSON encode failed for %s: %s", req.url, tostring(encoded))
                callback(false, Interface.ERRORS.INTERNAL, nil)
                return
            end
            body_str = encoded
            req.headers["Content-Type"] = "application/json"
        elseif type(opts.body) == "string" then
            body_str = opts.body
        else
            -- non-string, non-json body: programmer error.  Fail loudly
            -- via callback so we don't silently send the wrong thing.
            log.warn("body must be string or json-encodable table; got %s",
                type(opts.body))
            callback(false, Interface.ERRORS.INTERNAL, nil)
            return
        end
    end

    if body_str then
        req.source = (function()
            -- LuaSocket expects a "source" function or ltn12 source for
            -- request bodies.  An ltn12 source from a string is the
            -- minimal form: it returns the string once, then nil.
            local consumed = false
            return function()
                if consumed then return nil end
                consumed = true
                return body_str
            end
        end)()
        req.headers["Content-Length"] = tostring(#body_str)
        -- We need a sink to capture the response body when sending one.
        local response_chunks = {}
        req.sink = function(chunk, err)
            if chunk then table.insert(response_chunks, chunk) end
            if err then return nil, err end
            return 1
        end

        local ok_call, num_or_err, code = pcall(req_fn, req)
        if not ok_call then
            log.warn("%s %s raised: %s", method, req.url, tostring(num_or_err))
            callback(false, Interface.ERRORS.INTERNAL, nil)
            return
        end
        -- When the caller provides a sink, LuaSocket's request() returns
        -- (1, code) on success; the body was already drained into our sink.
        local body_response = table.concat(response_chunks)
        local result_ok, result_err = HttpClient.classify_response(
            body_response, num_or_err == 1 and code or num_or_err)
        if not result_ok then
            log.dbg("%s %s → %s (code=%s)",
                method, req.url, tostring(result_err), tostring(code))
        end
        callback(result_ok, result_err, body_response)
        return
    end

    -- Bodyless path.
    if method == "POST" or method == "PUT" then
        req.headers["Content-Length"] = "0"
    end

    -- Attach a response-body sink so the body is captured.  socket.http and
    -- ssl.https in the complex form (table argument) ALWAYS return
    -- (1, code, ...) on success — the body is NOT in the return values.
    -- Without an explicit sink the body is silently discarded, leaving JSON
    -- callers (folder discovery, status checks, version probe) with `1` to
    -- decode instead of a real JSON string.  ltn12 is part of LuaSocket and
    -- is always present when socket.http is available; the pcall guard
    -- handles unusual embeddings.  Mirrors the body-with-sink path above.
    local chunks = {}
    local ok_ltn12, ltn12 = pcall(require, "ltn12")
    if ok_ltn12 then
        req.sink = ltn12.sink.table(chunks)
    else
        -- ltn12 unavailable (no luasocket); use a manual sink so injected
        -- fakes that pump req.sink still work.
        req.sink = function(chunk, err)
            if chunk then table.insert(chunks, chunk) end
            if err then return nil, err end
            return 1
        end
    end

    local ok_call, num_or_err, code = pcall(req_fn, req)
    if not ok_call then
        log.warn("%s %s raised: %s", method, req.url, tostring(num_or_err))
        callback(false, Interface.ERRORS.INTERNAL, nil)
        return
    end

    -- Determine which return shape we received.
    --   Real socket.http with sink: returns (1, code, ...) — num_or_err==1,
    --     code is a number, body was drained into chunks.
    --   Injected test fakes (old shape): return (body_string, code) directly,
    --     no sink pump.
    -- We use the sink body only when the real socket.http shape is detected;
    -- old-style fakes bypass the sink so their canned bodies still reach callers.
    local body_response, http_code
    if num_or_err == 1 and type(code) == "number" and (ok_ltn12 or #chunks > 0) then
        -- Real socket.http path: body is in the sink (or empty body).
        body_response = table.concat(chunks)
        http_code     = code
    else
        -- Old-shape injected fake (or ltn12 unavailable): first return is body.
        body_response = num_or_err
        http_code     = code
    end
    local result_ok, result_err = HttpClient.classify_response(body_response, http_code)
    if not result_ok then
        log.dbg("%s %s → %s (code=%s)",
            method, req.url, tostring(result_err), tostring(http_code))
    end
    callback(result_ok, result_err, body_response)
end


-- ----------------------------------------------------------------------------
-- Public methods.  Verb-named for grep-ability.  Each one is a thin
-- wrapper around _request that exists only to make call sites read
-- clearly: `client:get("/rest/system/ping", cb)` is more informative
-- at the call site than `client:request("GET", "/rest/system/ping", cb)`.
-- ----------------------------------------------------------------------------


function HttpClient:get(path, callback)
    self:_request("GET", path, callback)
end


function HttpClient:post(path, callback)
    self:_request("POST", path, callback)
end


function HttpClient:put(path, callback)
    self:_request("PUT", path, callback)
end


--- POST with a JSON-encoded body.  Used by setFolderIgnore and other
--- endpoints where Syncthing expects a structured payload.  The body
--- argument is encoded via the JSON library (cjson or rapidjson,
--- whichever is available); a non-table body or a failed encoding
--- becomes an INTERNAL error in the callback.
function HttpClient:post_json(path, body, callback)
    self:_request("POST", path, callback, { body = body, json = true })
end


--- PUT with a JSON-encoded body.  A REST endpoint
--- is PUT; same body-encoding semantics as post_json.
function HttpClient:put_json(path, body, callback)
    self:_request("PUT", path, callback, { body = body, json = true })
end


return HttpClient
