-- =============================================================================
-- syncery_transports/syncthing/providers/kosyncthing_plus_provider.lua
-- =============================================================================
--
-- The KOSyncthing+ Syncthing provider: discovers config via the
-- kosyncthing_plus plugin's published API (`_G.KOSyncthingPlusAPI`)
-- when that plugin is installed.
--
-- THIS PROVIDER IS WHAT MAKES THE KOSYNCTHING+ INSTALLATION BUTTON-FREE.
-- The user installs kosyncthing_plus, opens Syncery, and Syncery just
-- works — no URL or API key to type.  Without kosyncthing_plus_provider, the
-- same user has to dig the GUI port and API key out of KOSyncthing+
-- by hand, then enter them in Syncery's menu.
--
-- KOSyncthing+ wraps the daemon's REST behind its own `apiCall` proxy
-- (the API key never leaves the plugin).  Companions making calls
-- through `apiCall` get the same data they'd get from
-- /rest/<endpoint>, just without ever holding the key.  That's a
-- different REST-client SHAPE from the manual-config provider, which
-- holds URL+API-key for a generic HttpClient.
--
-- We bridge the two with a `rest_client` field on the returned config:
--
--   manual_provider config:  { url, api_key, folder_id, folders }
--   kosyncthing_plus_provider  config:   { rest_client, folder_id, folders, kosyncthing_plus_api }
--
-- The transport's http_client_factory branches on which fields are
-- present: if `rest_client` is supplied, use it; otherwise build
-- HttpClient from URL+key.  Same downstream code either way.
--
--
-- BONUS CAPABILITIES
--
-- KOSyncthing+ exposes several things the bare REST API doesn't:
--
--   • IGNORE_PATTERNS — universal (works via REST too), but the plugin
--     adds the IgnoreRegistry mechanism that handles sync-conflict
--     suppression in its UI badge.
--   • EVENT_SUBSCRIPTION — onStatusChange / offStatusChange listener
--     pattern for `process_started`, `process_stopped`, etc.
--   • CONFLICTS_DETAILED — `info.getConflictsDetailed()` returns
--     structured records; falling back to filesystem scan when this
--     is absent is the scanner's job.
--   • PERIODIC_SYNC — status.isPeriodicSyncEnabled / Interval / NextAt
--     + control.setPeriodicSyncEnabled / Interval + runPeriodicSyncNow.
--   • DAEMON_CONTROL — control.start / control.stop + status.isRunning.
--     Process-level start/stop of the Syncthing daemon.
--
-- We advertise each one via `supports(capability)` — the orchestrator
-- and UI gate features accordingly.
--
--
-- DEPENDENCY INJECTION
--
-- The constructor takes an `api_resolver` function instead of reaching
-- for `_G.KOSyncthingPlusAPI` directly.  In production that resolver
-- returns the global; in tests it returns a fake.  This is the same
-- pattern as the http_client's `request_fn` — one seam at the boundary
-- to global state.
--
-- =============================================================================


local Interface     = require("syncery_transports/interface")
local KOSyncthingPlusApiClient = require("syncery_transports/syncthing/kosyncthing_plus_api_client")
local Log           = require("syncery_transports/log")
local log           = Log.tag("syncthing.kosyncthing_plus_provider")


local KOSyncthingPlusProvider = {}


-- ----------------------------------------------------------------------------
-- Default api_resolver — returns the global if present, nil otherwise.
-- ----------------------------------------------------------------------------


local function default_api_resolver()
    -- rawget so we never trigger a __index metatable side effect.
    return rawget(_G, "KOSyncthingPlusAPI")
end


-- ----------------------------------------------------------------------------
-- Capability detection: given a KOSyncthing+ API table, which of our
-- documented capabilities does it expose?
--
-- This is computed once on construction (and re-checked each call to
-- supports()) so that the plugin being uninstalled mid-session
-- gracefully downgrades.
-- ----------------------------------------------------------------------------


local function kosyncthing_supports(api, capability)
    if type(api) ~= "table" then return false end

    if capability == Interface.CAPABILITIES.IGNORE_PATTERNS then
        -- Two avenues: the IgnoreRegistry (in-plugin conflict
        -- suppression) AND control.setFolderIgnore (talks to Syncthing
        -- via apiCall).  We claim support if EITHER is present, since
        -- the transport's set_folder_ignore() method can pick the
        -- right path.
        return (type(api.IgnoreRegistry) == "table")
            or (api.control and type(api.control.setFolderIgnore) == "function")
    end

    if capability == Interface.CAPABILITIES.EVENT_SUBSCRIPTION then
        return type(api.onStatusChange) == "function"
            and type(api.offStatusChange) == "function"
    end

    if capability == Interface.CAPABILITIES.CONFLICTS_DETAILED then
        return api.info and type(api.info.getConflictsDetailed) == "function"
    end

    if capability == Interface.CAPABILITIES.PERIODIC_SYNC then
        -- Need BOTH read and write sides of the API to claim support;
        -- a read-only API wouldn't let the UI offer the "set interval"
        -- control.  We're strict here on purpose.
        return api.status   and type(api.status.isPeriodicSyncEnabled)  == "function"
           and api.status   and type(api.status.getPeriodicSyncInterval) == "function"
           and api.control  and type(api.control.setPeriodicSyncEnabled) == "function"
    end

    if capability == Interface.CAPABILITIES.QUICK_SYNC then
        -- A single function — `control.quickSync(on_complete)` — per
        -- the KOSyncthing+ published API.  Companions may pass nil (fire
        -- and forget) or a completion callback invoked when the whole
        -- Quick Sync flow finishes.
        return api.control and type(api.control.quickSync) == "function"
    end

    if capability == Interface.CAPABILITIES.DAEMON_CONTROL then
        -- Need the whole start/stop/isRunning surface —
        -- strict, like PERIODIC_SYNC.  A plugin exposing only one half
        -- (say, isRunning but no start) would let the UI render a
        -- button it cannot honour; better to claim no support.
        --   control.start(cb)  — launch the daemon process
        --   control.stop(cb)   — stop it
        --   status.isRunning() — read current process state
        -- (control.toggle exists too, but we drive start/stop
        -- explicitly so the UI label is always correct; toggle is not
        -- required for support.)
        return api.control and type(api.control.start)     == "function"
           and api.control and type(api.control.stop)      == "function"
           and api.status  and type(api.status.isRunning)  == "function"
    end

    if capability == Interface.CAPABILITIES.CONFLICT_IGNORE_REGISTRY then
        -- KOSyncthing+ v1.1.5+ exposes `IgnoreRegistry:register(plugin_id,
        -- pattern)` to exclude a companion's files from the conflict scanner.
        -- Strict: need the registry table AND a callable register method (an
        -- older build with the table but no method would let us claim support
        -- for a call that would error).
        return type(api.IgnoreRegistry) == "table"
            and type(api.IgnoreRegistry.register) == "function"
    end

    return false
end


-- ----------------------------------------------------------------------------
-- Folder discovery.
--
-- Returns a list of {folder_id, path} tuples by reading KOSyncthing+'s
-- info.getFolders() output.  Falls back to nil if the installed version
-- is too old to support that method (the orchestrator then proceeds with
-- the user's manually-chosen folder_id, treated as the default).
-- ----------------------------------------------------------------------------


local function discover_folders(api)
    if not (api and api.info and type(api.info.getFolders) == "function") then
        return nil
    end
    local ok, folders = pcall(api.info.getFolders)
    if not ok or type(folders) ~= "table" or #folders == 0 then return nil end

    local out = {}
    for _, f in ipairs(folders) do
        if type(f) == "table" and f.id then
            table.insert(out, {
                folder_id = f.id,
                path      = f.path,
                label     = (type(f.label) == "string" and f.label ~= "") and f.label or nil,
                -- Surface state so the picker can flag a folder that will not
                -- sync.  f.paused (bool) wins; otherwise the live state string
                -- ("syncing"/"scanning"/"error"/...).  idle/absent -> nil so
                -- healthy rows stay clean.
                state     = (f.paused == true) and "paused"
                            or (type(f.state) == "string" and f.state ~= ""
                                and f.state ~= "idle" and f.state or nil),
            })
        end
    end
    if #out == 0 then return nil end
    return out
end


-- ----------------------------------------------------------------------------
-- Constructor.
-- ----------------------------------------------------------------------------


--- Build a kosyncthing_plus_provider.
---
--- @param opts table
---   .api_resolver  function() → table|nil    — default: rawget(_G, "KOSyncthingPlusAPI")
---   .settings_reader function(key) → any     — reads syncery_syncthing_folder_id
function KOSyncthingPlusProvider.new(opts)
    opts = opts or {}
    local api_resolver    = opts.api_resolver    or default_api_resolver
    local settings_reader = opts.settings_reader or function() return nil end
    assert(type(api_resolver) == "function",
        "KOSyncthingPlusProvider.new: api_resolver must be a function")
    assert(type(settings_reader) == "function",
        "KOSyncthingPlusProvider.new: settings_reader must be a function")

    local p = {}

    function p.id() return "kosyncthing_plus" end

    function p.get_config()
        local api = api_resolver()
        if type(api) ~= "table" or type(api.apiCall) ~= "function" then
            -- KOSyncthing+ not installed (or installed but its API isn't
            -- ready yet — the plugin sets _G.KOSyncthingPlusAPI in its own init).
            return nil
        end

        -- Resolve folder_id: prefer an explicit user setting; else, when the
        -- plugin reports exactly ONE folder, adopt it (unambiguous).  With
        -- several folders we deliberately do NOT guess folders[1] -- the
        -- report order isn't meaningful -- so folder_id stays nil and the
        -- scan guard treats the transport as "folder not configured", letting
        -- the picker choose, exactly like the manual / config.xml providers.
        local folder_id  = settings_reader("syncery_syncthing_folder_id")
        local folders    = discover_folders(api)

        if (type(folder_id) ~= "string" or folder_id == "")
                and folders and #folders == 1 then
            folder_id = folders[1].folder_id
        end

        local client = KOSyncthingPlusApiClient.new({ api_call = api.apiCall })

        return {
            rest_client = client,
            folder_id   = folder_id,
            folders     = folders,
            kosyncthing_plus_api    = api,    -- exposed so the transport can reach
                                  -- onStatusChange / IgnoreRegistry /
                                  -- periodic-sync controls.  Treat as
                                  -- read-only metadata, not state.
        }
    end

    function p.supports(capability)
        return kosyncthing_supports(api_resolver(), capability)
    end

    return p
end


return KOSyncthingPlusProvider
