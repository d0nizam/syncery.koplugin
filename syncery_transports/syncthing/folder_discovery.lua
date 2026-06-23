-- =============================================================================
-- syncery_transports/syncthing/folder_discovery.lua
-- =============================================================================
--
-- REST folder discovery for the manual Syncthing provider.
--
-- The manual provider talks to a standalone Syncthing daemon over REST. Until
-- now the user had to find and type the folder_id by hand (digging through
-- Syncthing's GUI) — the one painful step, since the URL and API key are
-- needed anyway. This module asks the daemon directly: it GETs the folder
-- config and turns it into a { folder_id, path } list, exactly the shape the
-- KOSyncthing+ provider already produces via its API.
--
-- THIS IS PLATFORM-AGNOSTIC. Syncthing's REST API is served on the GUI port
-- (default 127.0.0.1:8384) on every platform it runs on — Linux, macOS,
-- Windows, Android (Termux / Syncthing-Android), a NAS, an SSH box. The old
-- plan called this "Android config.xml discovery", which conflated WHY REST is
-- needed on Android (the sandbox hides config.xml from the filesystem) with
-- WHERE REST works (everywhere). Discovery over REST serves anyone running a
-- standalone Syncthing reachable over HTTP.
--
-- ENDPOINT COMPATIBILITY: modern Syncthing exposes GET /rest/config/folders,
-- which returns the folder array directly. Older builds only have
-- GET /rest/system/config (now deprecated), whose body is the whole config
-- object with a `.folders` array. `parse_folders` accepts BOTH shapes, so the
-- same code works across versions; the caller tries the modern path first and
-- can fall back to the legacy one.
--
-- This file is PURE + dependency-injected: `parse_folders` is a pure
-- JSON-shape -> list transform, and `discover` takes an injected REST client
-- (anything with :get(path, cb)) plus a JSON decoder, so the whole thing is
-- unit-testable without a live daemon. No KOReader-widget requires.
-- =============================================================================


local FolderDiscovery = {}

-- The endpoints, modern first. Exposed so the caller / tests can see them.
FolderDiscovery.ENDPOINT_MODERN = "/rest/config/folders"
FolderDiscovery.ENDPOINT_LEGACY = "/rest/system/config"


-- ---------------------------------------------------------------------------
-- Pure: turn a decoded JSON body into a { {folder_id, path}, ... } list.
--
-- Accepts either shape:
--   * a folder array            (GET /rest/config/folders)
--   * a config object with
--     a `.folders` array        (GET /rest/system/config)
--
-- Folders without an `id` are skipped (an id is required to scan). `path`
-- may be nil — discovery is still useful for the id alone. Returns nil when
-- there is nothing usable (so callers can fall back cleanly), never an empty
-- list, to keep "no folders" a single sentinel.
-- ---------------------------------------------------------------------------
function FolderDiscovery.parse_folders(decoded)
    if type(decoded) ~= "table" then return nil end

    -- Normalise to the folder array.
    local list = decoded
    if decoded.folders ~= nil then
        list = decoded.folders
    end
    if type(list) ~= "table" then return nil end

    local out = {}
    for _, f in ipairs(list) do
        if type(f) == "table" and type(f.id) == "string" and f.id ~= "" then
            out[#out + 1] = {
                folder_id = f.id,
                path      = (type(f.path) == "string" and f.path ~= "") and f.path or nil,
                label     = (type(f.label) == "string" and f.label ~= "") and f.label or nil,
                -- The REST config carries `paused` (a config flag); the live
                -- state ("syncing"/"error"/...) comes from a separate
                -- /rest/db/status fetch (see enrich_live_state).  Seed paused
                -- here so a paused folder is flagged even if that fetch fails.
                state     = (f.paused == true) and "paused" or nil,
            }
        end
    end

    if #out == 0 then return nil end
    return out
end


-- ---------------------------------------------------------------------------
-- Discover folders over REST. Asynchronous, callback-based — same contract as
-- the HttpClient verbs it sits on top of.
--
-- `deps`:
--   client       table     a REST client with :get(path, cb); cb receives
--                           (ok, err, body) exactly like HttpClient.
--   decode       function  json string -> (table | nil); e.g. a safe wrapper
--                           around rapidjson.decode.
--   on_done      function  (folders | nil, err | nil) -> ()  result callback.
--
-- Tries the modern endpoint first; on a NON-auth failure (unreachable /
-- rejected / 404 on an old daemon) it falls back to the legacy endpoint.
-- An auth failure is terminal — retrying the other endpoint with the same
-- bad key is pointless — so it is reported straight away.
-- ---------------------------------------------------------------------------
function FolderDiscovery.discover(deps)
    local client  = deps.client
    local decode  = deps.decode
    local on_done = deps.on_done or function() end

    local function handle(ok, err, body, allow_fallback)
        if ok then
            local decoded = decode and decode(body) or nil
            local folders = FolderDiscovery.parse_folders(decoded)
            if folders then
                on_done(folders, nil)
            else
                on_done(nil, "no_folders")
            end
            return
        end

        -- Auth failure: the key is wrong; the legacy endpoint won't differ.
        if err == "auth_failed" then
            on_done(nil, err)
            return
        end

        if allow_fallback then
            client:get(FolderDiscovery.ENDPOINT_LEGACY, function(ok2, err2, body2)
                handle(ok2, err2, body2, false)
            end)
        else
            on_done(nil, err or "unreachable")
        end
    end

    client:get(FolderDiscovery.ENDPOINT_MODERN, function(ok, err, body)
        handle(ok, err, body, true)
    end)
end


-- ---------------------------------------------------------------------------
-- Pure: extract the live folder state from a decoded /rest/db/status body.
-- Returns the state string ("idle"/"syncing"/"scanning"/"error"/...) or nil
-- when the body carries no usable state.
-- ---------------------------------------------------------------------------
function FolderDiscovery.parse_status(decoded)
    if type(decoded) == "table"
       and type(decoded.state) == "string" and decoded.state ~= "" then
        return decoded.state
    end
    return nil
end


-- ---------------------------------------------------------------------------
-- Enrich a folder list with live state from /rest/db/status (one GET per
-- folder).  Best-effort and order-preserving: a folder whose status fetch
-- fails OR reports "idle" keeps whatever state it already had (the config
-- `paused` flag, or nil) so healthy rows stay clean; any non-idle live state
-- (syncing/scanning/error) overrides with the live truth.  Calls
-- on_done(folders) once every folder has been visited.
--
-- `deps`:
--   client        a REST client with :get(path, cb); cb gets (ok, err, body).
--   decode        function  json string -> (table | nil).
--   encode_query  function  s -> percent-encoded query value (the folder_id).
-- ---------------------------------------------------------------------------
function FolderDiscovery.enrich_live_state(deps, folders, on_done)
    deps = deps or {}
    local client = deps.client
    local decode = deps.decode
    local enc    = deps.encode_query or function(s) return s end
    on_done = on_done or function() end

    if type(folders) ~= "table" or #folders == 0 or not (client and client.get) then
        on_done(folders); return
    end

    local i = 0
    local function step()
        i = i + 1
        if i > #folders then on_done(folders); return end
        local f = folders[i]
        client:get("/rest/db/status?folder=" .. enc(f.folder_id), function(ok, _err, body)
            if ok then
                local st = FolderDiscovery.parse_status(decode and decode(body) or nil)
                if st and st ~= "idle" then f.state = st end
            end
            step()
        end)
    end
    step()
end


return FolderDiscovery
