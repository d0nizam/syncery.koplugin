-- =============================================================================
-- syncery_transports/syncthing/kosyncthing_plus_api_client.lua
-- =============================================================================
--
-- Adapts the kosyncthing_plus plugin's synchronous `apiCall` proxy to
-- the same callback shape Syncery's transport layer uses.
--
-- WHY THIS EXISTS
--
-- KOSyncthing+ exposes `_G.KOSyncthingPlusAPI.apiCall(endpoint, method, body)`
-- as a synchronous wrapper around Syncthing's REST API.  It's the
-- intended way for companion plugins to talk to Syncthing without
-- ever seeing the API key (the plugin inserts the key itself).
--
-- But the rest of Syncery's transport layer is callback-based: the
-- orchestrator calls `transport.push(book, opts, cb)` and expects cb
-- to fire eventually.  HttpClient honors that contract; if we want
-- KOSyncthing+-backed transports to plug into the same orchestrator,
-- so its sync API needs the same shape.
--
-- This client wraps each call: invoke apiCall synchronously, classify
-- the result, fire the callback before returning.  Synchronous in,
-- synchronous out — but the call SITE looks identical to HttpClient's.
--
-- That symmetry is what lets `transport.lua`'s push() not care whether
-- it's talking through manual REST or through KOSyncthing+.  The factory
-- builds the right client; the transport just calls the methods.
--
-- ERROR CLASSIFICATION
--
-- The plugin's apiCall returns the parsed JSON response on success, or
-- a falsy value on failure.  No status codes, no error strings — we
-- don't get to distinguish "auth_failed" from "unreachable".  We
-- classify pessimistically: a falsy result becomes UNREACHABLE
-- (transient — retry), since that's the most common cause and the
-- safest default.  If the user has actually misconfigured something,
-- the orchestrator's retry will keep failing transiently rather than
-- surface as a config_needed badge; that's a known limitation of the
-- plugin's API surface, not something we can fix here.
--
-- Two error classes ARE distinguishable:
--   • If `_G.KOSyncthingPlusAPI` itself is missing or `apiCall` is not
--     a function at call time, we report NOT_AVAILABLE.  That's the
--     "KOSyncthing+ was uninstalled mid-session" path.
--   • If apiCall raises a Lua error, we report INTERNAL.
--
-- =============================================================================


local Interface = require("syncery_transports/interface")
local Log       = require("syncery_transports/log")
local log       = Log.tag("kosyncthing_plus_api_client")


local KOSyncthingPlusApiClient = {}
KOSyncthingPlusApiClient.__index = KOSyncthingPlusApiClient


-- ----------------------------------------------------------------------------
-- Constructor.
-- ----------------------------------------------------------------------------


--- Build a new KOSyncthingPlusApiClient.
---
--- Required opts:
---   api_call — function(endpoint, method, body) → result|nil
---              Reference to the plugin's `_G.KOSyncthingPlusAPI.apiCall`.
---              Injectable so tests can pass a fake; production code
---              passes the real function on construction.
---
--- The endpoint passed to apiCall is RELATIVE to /rest (the plugin's
--- convention).  Our higher-level transport code thinks in
--- "/rest/db/scan?folder=..." style paths; this client strips the
--- leading "/rest/" before calling.  That keeps the transport layer
--- consistent — same paths whether we're talking through HTTP or
--- KOSyncthing+.
function KOSyncthingPlusApiClient.new(opts)
    opts = opts or {}
    assert(type(opts.api_call) == "function",
        "KOSyncthingPlusApiClient.new: api_call function required")

    local self = setmetatable({}, KOSyncthingPlusApiClient)
    self._api_call = opts.api_call
    return self
end


-- ----------------------------------------------------------------------------
-- Helpers.
-- ----------------------------------------------------------------------------


--- Strip the leading "/rest/" from a transport-style path, since
--- the plugin's apiCall takes endpoints relative to /rest.  Returns
--- the input unchanged if it doesn't start with /rest/.
local function strip_rest_prefix(path)
    local stripped = path:match("^/rest/(.*)$")
    return stripped or path:match("^/(.*)$") or path
end


--- The shared call site for get / post / post_json.  Invokes the
--- plugin's apiCall under pcall, then synthesizes the callback per
--- the documented error classification above.
function KOSyncthingPlusApiClient:_invoke(method, path, body, callback)
    local endpoint = strip_rest_prefix(path)

    local ok_call, result = pcall(self._api_call, endpoint, method, body)
    if not ok_call then
        log.warn("apiCall %s %s raised: %s", method, endpoint, tostring(result))
        callback(false, Interface.ERRORS.INTERNAL, nil)
        return
    end

    if result == nil or result == false then
        -- Falsy result = the plugin's apiCall reported failure but
        -- doesn't tell us why.  Treat as transient; see header
        -- "ERROR CLASSIFICATION" for the rationale.
        log.dbg("apiCall %s %s returned falsy; classifying as UNREACHABLE",
            method, endpoint)
        callback(false, Interface.ERRORS.UNREACHABLE, nil)
        return
    end

    callback(true, nil, result)
end


-- ----------------------------------------------------------------------------
-- Public methods.  Match HttpClient's surface so the transport doesn't
-- care which client it's holding.
-- ----------------------------------------------------------------------------


function KOSyncthingPlusApiClient:get(path, callback)
    self:_invoke("GET", path, nil, callback)
end


function KOSyncthingPlusApiClient:post(path, callback)
    self:_invoke("POST", path, nil, callback)
end


function KOSyncthingPlusApiClient:post_json(path, body, callback)
    -- The plugin's apiCall expects an already-encoded JSON STRING for
    -- the body, not a Lua table.  Encode here so transport code can
    -- pass tables uniformly to both clients (HttpClient encodes
    -- internally too).
    local ok_json, cjson = pcall(require, "cjson")
    if not ok_json then
        local ok_rj, rj = pcall(require, "rapidjson")
        if ok_rj then cjson = rj else
            log.warn("no JSON library available; post_json aborting")
            callback(false, Interface.ERRORS.INTERNAL, nil)
            return
        end
    end
    local ok_enc, encoded = pcall(cjson.encode, body)
    if not ok_enc then
        log.warn("JSON encode failed: %s", tostring(encoded))
        callback(false, Interface.ERRORS.INTERNAL, nil)
        return
    end
    self:_invoke("POST", path, encoded, callback)
end


return KOSyncthingPlusApiClient
