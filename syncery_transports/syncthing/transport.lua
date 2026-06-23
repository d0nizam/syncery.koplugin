-- =============================================================================
-- syncery_transports/syncthing/transport.lua
-- =============================================================================
--
-- The Syncthing transport.  Conforms to the contract in
-- syncery_transports/interface.lua.
--
-- WHAT THIS TRANSPORT DOES
--
-- Syncthing is peer-to-peer file replication.  Syncery doesn't move
-- bytes itself — it writes its progress / annotation files into a
-- folder that Syncthing watches, and asks the daemon to scan that
-- folder.  The daemon does the actual replication to peers whenever
-- the network permits.
--
-- So `push` here means "ask the Syncthing daemon to scan the folder
-- containing the book, picking up our newly-written file".  `pull`
-- is a no-op — the watched folder is always live, files appear when
-- the daemon syncs them, there's no API call we need to make.
--
-- This is what `is_eventually_consistent() == true` is signaling: a
-- successful push doesn't mean any peer has received the bytes.  It
-- only means we asked the daemon to start the journey.
--
-- DECENTRALIZED EXECUTION
--
-- The transport contains zero policy.  No retries, no backoff, no
-- debounce, no "should I attempt" — all of that lives in the
-- orchestrator.  This file does:
--
--   1. Find a provider that can supply Syncthing's URL + API key
--      (delegated to providers/init.lua's discover function).
--   2. Build an HttpClient against that URL + API key.
--   3. On push: POST /rest/db/scan?folder=...&sub=... — one HTTP call.
--   4. On status: report current state.
--
-- That's it.  When the orchestrator decides to retry, it calls push()
-- again; the transport doesn't even know it's a retry.
--
-- INJECTED DEPENDENCIES
--
-- new() takes injectable dependencies so this transport can be tested
-- without a Syncthing daemon, without G_reader_settings, without
-- LuaSocket.  In production the plugin wires the defaults; tests pass
-- fakes.
--
--   settings_reader      — function(key) → value
--   http_client_factory  — function(config) → HttpClient instance
--   provider_discover    — function(opts) → provider | nil
--
-- =============================================================================


local Interface     = require("syncery_transports/interface")
local HttpClient    = require("syncery_transports/http_client")
local Providers     = require("syncery_transports/syncthing/providers/init")
local FolderDiscovery = require("syncery_transports/syncthing/folder_discovery")
local SafeCallback  = require("syncery_transports/safe_callback")
local Log           = require("syncery_transports/log")
local log           = Log.tag("transport:syncthing")


local Transport = {}


-- ----------------------------------------------------------------------------
-- Constants.
-- ----------------------------------------------------------------------------


--- Stable transport id.  This is the key the orchestrator uses for
--- policy lookup (`Policy.config_for("syncthing")`) and for storing
--- per-transport state.  Must not change between releases or persisted
--- state from previous sessions will orphan.
local TRANSPORT_ID = "syncthing"


--- The master toggle key in G_reader_settings.  This is the SAME canonical
--- key the menu checkbox + wizard write (`syncery_use_syncthing`) — collapsed
--- from the old `syncery_sync_via_syncthing` mirror so is_available() can never
--- diverge from the checkbox.  Reading it through the injected settings_reader
--- keeps the transport testable without G_reader_settings.
local TOGGLE_KEY = "syncery_use_syncthing"


-- ----------------------------------------------------------------------------
-- Default implementations of injectables.  Tests override; production
-- gets these.
-- ----------------------------------------------------------------------------


local function default_settings_reader(key)
    if not _G.G_reader_settings then return nil end
    return _G.G_reader_settings:readSetting(key)
end


local function default_http_client_factory(config)
    -- The provider gave us either a pre-built rest_client (kosyncthing_plus_provider's
    -- KOSyncthingPlusApiClient) or URL+api_key for our generic HttpClient.  Branch
    -- on which is present.  Callers don't see this — they just call the
    -- same methods on whichever client comes back.
    if config.rest_client then return config.rest_client end
    return HttpClient.new({
        base_url = config.url,
        api_key  = config.api_key,
    })
end


--- Decode a JSON body into a Lua table, or nil on any failure.  Mirrors
--- the helper the menu's discovery path uses, so the transport can run
--- FolderDiscovery without reaching into the UI layer.  Tries cjson then
--- rapidjson; a missing JSON module yields nil (treated as "no folders").
local function safe_decode(body)
    local ok_j, json = pcall(require, "cjson")
    if not ok_j then
        local ok_rj, rj = pcall(require, "rapidjson")
        if ok_rj then json = rj else return nil end
    end
    local ok_dec, parsed = pcall(json.decode, body or "")
    return ok_dec and parsed or nil
end


-- ----------------------------------------------------------------------------
-- Constructor.
-- ----------------------------------------------------------------------------


--- Build a Syncthing transport.  All opts are optional in production
--- (defaults shown above); tests pass everything explicitly.
---
--- Returns a table satisfying syncery_transports/interface.lua.
function Transport.new(opts)
    opts = opts or {}
    local settings_reader = opts.settings_reader      or default_settings_reader
    local http_factory    = opts.http_client_factory  or default_http_client_factory
    local provider_discover = opts.provider_discover  or Providers.discover

    -- The chosen provider can change between calls to is_available()
    -- if the user enters new settings, so we re-discover on each use.
    -- Discovery is cheap (a few settings lookups); we don't cache.
    local function current_provider()
        return provider_discover({ settings_reader = settings_reader })
    end

    -- Build the transport table via closures over the locals above.
    -- We use closures (not OO with __index) because the interface is
    -- called with `transport.method(args)` not `transport:method(args)`
    -- — the closure form avoids any confusion at call sites about
    -- whether `self` is needed.
    local t = {}

    function t.id() return TRANSPORT_ID end
    function t.display_name() return "Syncthing" end
    function t.is_eventually_consistent() return true end

    function t.is_available()
        -- Cheap by design: read one setting, do one provider discovery.
        -- No HTTP, no filesystem.  The orchestrator calls this on every
        -- push attempt and every status redraw — it cannot be expensive.
        if not settings_reader(TOGGLE_KEY) then return false end
        return current_provider() ~= nil
    end

    --- Return the current Syncthing folder id (whatever the user picked via the
    --- folder picker, or KOSyncthing+ reported; nil when none).  Useful for transport-specific surfaces
    --- that act on a folder — `register_syncery_ignore_patterns` reads
    --- this so the bridge doesn't have to thread folder_id from main.lua.
    --- Returns nil when the transport isn't available (no provider).
    function t.get_folder_id()
        local provider = current_provider()
        local config   = provider and provider.get_config()
        if not config then return nil end
        return config.folder_id
    end

    --- List the active provider's Syncthing folders, live, as
    --- {folder_id, path, label} records — what the folder picker shows.
    --- callback(folders|nil, err|nil); err ∈ not_available / no_http_module
    --- / no_folders / auth_failed / unreachable.
    function t.list_folders(callback)
        local provider = current_provider()
        local config   = provider and provider.get_config()
        if not config then callback(nil, "not_available"); return end

        -- KOSyncthing+: get_config already enumerated folders live via the plugin's
        -- native info.getFolders() (labels kept).  Hand them straight back.
        if config.kosyncthing_plus_api then
            if config.folders then
                callback(config.folders, nil)
            else
                callback(nil, "no_folders")
            end
            return
        end

        -- Manual: live REST fetch.  The manual provider carries no folders in
        -- its config, so we always re-enumerate live through FolderDiscovery.
        local client = http_factory(config)
        if not client then callback(nil, "no_http_module"); return end
        -- Discover the folder list, then enrich each with its live state from
        -- /rest/db/status so the picker can flag paused/error/syncing folders.
        FolderDiscovery.discover{
            client  = client,
            decode  = safe_decode,
            on_done = function(folders, err)
                if not folders then callback(nil, err); return end
                FolderDiscovery.enrich_live_state(
                    { client = client, decode = safe_decode,
                      encode_query = HttpClient.url_encode },
                    folders,
                    function(enriched) callback(enriched, nil) end)
            end,
        }
    end

    --- Provider-aware connectivity probe: ping /rest/system/version through
    --- whichever client the active provider yields — KOSyncthing+'s apiCall
    --- proxy or the generic HttpClient for a URL+key provider (config.xml /
    --- manual).  Unlike the menu's manual-only H.test_syncthing_connection,
    --- this reads no manual key and does no scheme probe: KOSyncthing+ carries
    --- no URL, and config.xml's URL is authoritative.  The menu routes here
    --- only when an automatic provider supplies the key.
    --- callback(ok, code|nil, diag): diag ∈ ok / auth_failed / http_<n> /
    --- unreachable / not_available / no_http_module.
    function t.test_connection(callback)
        local provider = current_provider()
        local config   = provider and provider.get_config()
        if not config then callback(false, nil, "not_available"); return end
        local client = http_factory(config)
        if not client then callback(false, nil, "no_http_module"); return end
        client:get("/rest/system/version", function(ok, err, _body, status)
            if ok then
                callback(true, status or 200, "ok")
            elseif err == "rejected" and (status == 401 or status == 403) then
                callback(false, status, "auth_failed")
            elseif err == "rejected" then
                callback(false, status, "http_" .. tostring(status or "?"))
            else
                -- HttpClient "unreachable", or the KOSyncthing+ client's
                -- INTERNAL / UNREACHABLE / NOT_AVAILABLE — all surface as
                -- "can't reach Syncthing".
                callback(false, status, "unreachable")
            end
        end)
    end

    function t.push(book_file, push_opts, callback)
        if not t.is_available() then
            callback(false, Interface.ERRORS.NOT_AVAILABLE, nil); return
        end

        local provider = current_provider()
        local config   = provider and provider.get_config()
        if not config then
            -- is_available passed but provider vanished between calls
            -- (settings cleared mid-call, e.g.).  Surface as not_configured.
            callback(false, Interface.ERRORS.NOT_CONFIGURED, nil); return
        end

        -- Build the scan URL.  /rest/db/scan?folder=ID[&sub=relative/path].
        -- A successful POST returns 200/204; the daemon now knows to
        -- look at our file.  Replication to peers happens asynchronously
        -- per Syncthing's own logic — we don't observe it.
        local path = "/rest/db/scan?folder=" .. HttpClient.url_encode(config.folder_id)
        local sub  = push_opts and push_opts.sub
        if type(sub) == "string" and sub ~= "" then
            -- Normalize Windows-style separators just in case.
            sub = sub:gsub("\\", "/")
            path = path .. "&sub=" .. HttpClient.url_encode_path(sub)
        end

        log.dbg("push %s via folder=%s sub=%s",
            book_file, tostring(config.folder_id), tostring(sub))

        local ok_call, call_err = pcall(function()
            local client = http_factory(config)
            client:post(path, function(ok, err, _body)
                callback(ok, err, nil)
            end)
        end)
        if not ok_call then
            log.warn("http call raised: %s", tostring(call_err))
            callback(false, Interface.ERRORS.INTERNAL, nil)
        end
    end

    function t.pull(_book_file, _pull_opts, callback)
        -- Syncthing is file-based eventual replication: the watched
        -- folder updates itself when the daemon receives changes.
        -- There's no "pull" REST endpoint for our use case.  We
        -- report success immediately with no payload — the contract
        -- spec already proves the orchestrator handles this correctly
        -- under is_eventually_consistent=true.
        callback(true, nil, nil)
    end

    function t.status()
        local available = t.is_available()
        local summary
        if not available then
            local has_toggle = settings_reader(TOGGLE_KEY)
            if not has_toggle then
                summary = "disabled (toggle off)"
            else
                summary = "not configured"
            end
        else
            -- We could ping here to refine "configured but unreachable"
            -- but is_available is documented as "cheap, no I/O".  The
            -- orchestrator's post-push status decoration handles the
            -- "configured but recent push failed" case using
            -- orch_last_error_class.
            summary = "ready (replication via daemon)"
        end

        return {
            display_name = "Syncthing",
            available    = available,
            summary      = summary,
        }
    end

    function t.supports(capability)
        -- The transport's optional-capability surface is the union of
        -- whatever the current provider supplies + whatever is universal
        -- (i.e. doable via REST regardless of provider).
        --
        -- IGNORE_PATTERNS is now UNIVERSAL: any Syncthing daemon
        -- accepts POST /rest/db/ignores with a JSON body — that's
        -- what `set_folder_ignore` below uses, via the rest_client.
        -- Provider-supplied capabilities (events, conflict details,
        -- periodic sync) layer on top.
        if capability == Interface.CAPABILITIES.IGNORE_PATTERNS then
            return t.is_available()
        end

        local provider = current_provider()
        if provider and type(provider.supports) == "function" then
            local ok, result = pcall(provider.supports, capability)
            if ok and result then return true end
        end
        return false
    end


    -- ------------------------------------------------------------------
    -- Universal capability: folder-ignore patterns.
    --
    -- Works through whichever rest_client the factory built — the
    -- transport doesn't care whether it's an HttpClient or a
    -- KOSyncthingPlusApiClient.  Both expose the same get / post_json surface.
    --
    -- These methods are NOT part of the core Transport interface.
    -- They're advertised via supports(IGNORE_PATTERNS); the UI checks
    -- support before calling.  The contract spec doesn't enforce them
    -- because not every transport will have them (Cloud
    -- won't).
    -- ------------------------------------------------------------------

    --- Get the current ignore patterns for a folder.  Calls back with
    --- (true, nil, patterns_table) on success or (false, err_class, nil).
    --- patterns_table is the parsed response.ignore array, or empty.
    function t.get_folder_ignore(folder_id, callback)
        if not t.is_available() then
            callback(false, Interface.ERRORS.NOT_AVAILABLE, nil); return
        end
        if type(folder_id) ~= "string" or folder_id == "" then
            callback(false, Interface.ERRORS.REJECTED, nil); return
        end

        local provider = current_provider()
        local config   = provider and provider.get_config()
        if not config then
            callback(false, Interface.ERRORS.NOT_CONFIGURED, nil); return
        end

        local path = "/rest/db/ignores?folder=" .. HttpClient.url_encode(folder_id)
        local ok_call, call_err = pcall(function()
            local client = http_factory(config)
            client:get(path, function(ok, err, body)
                if not ok then callback(false, err, nil); return end
                -- Parse the JSON response.  Syncthing returns
                -- {"ignore":[...], "expanded":[...]} — we want ignore.
                local ok_j, cjson = pcall(require, "cjson")
                if not ok_j then
                    local ok_rj, rj = pcall(require, "rapidjson")
                    if ok_rj then cjson = rj end
                end
                if not cjson then
                    callback(false, Interface.ERRORS.INTERNAL, nil); return
                end
                local ok_dec, parsed = pcall(cjson.decode, body or "")
                if not ok_dec or type(parsed) ~= "table" then
                    callback(false, Interface.ERRORS.INTERNAL, nil); return
                end
                callback(true, nil, parsed.ignore or {})
            end)
        end)
        if not ok_call then
            log.warn("get_folder_ignore raised: %s", tostring(call_err))
            callback(false, Interface.ERRORS.INTERNAL, nil)
        end
    end

    --- Set the ignore patterns for a folder.  `patterns` is a list of
    --- string patterns (Syncthing's own .stignore syntax).  Callback
    --- shape: (true, nil, nil) on success, (false, err_class, nil) on
    --- failure.
    function t.set_folder_ignore(folder_id, patterns, callback)
        if not t.is_available() then
            callback(false, Interface.ERRORS.NOT_AVAILABLE, nil); return
        end
        if type(folder_id) ~= "string" or folder_id == "" then
            callback(false, Interface.ERRORS.REJECTED, nil); return
        end
        if type(patterns) ~= "table" then
            callback(false, Interface.ERRORS.REJECTED, nil); return
        end
        -- Defensive copy + type-check each entry.  A non-string slipping
        -- through would encode as garbage and Syncthing would 400 us;
        -- we'd rather fail loudly here.
        local clean = {}
        for _, pat in ipairs(patterns) do
            if type(pat) ~= "string" then
                callback(false, Interface.ERRORS.REJECTED, nil); return
            end
            table.insert(clean, pat)
        end

        local provider = current_provider()
        local config   = provider and provider.get_config()
        if not config then
            callback(false, Interface.ERRORS.NOT_CONFIGURED, nil); return
        end

        local path = "/rest/db/ignores?folder=" .. HttpClient.url_encode(folder_id)
        local ok_call, call_err = pcall(function()
            local client = http_factory(config)
            client:post_json(path, { ignore = clean }, function(ok, err)
                callback(ok, err, nil)
            end)
        end)
        if not ok_call then
            log.warn("set_folder_ignore raised: %s", tostring(call_err))
            callback(false, Interface.ERRORS.INTERNAL, nil)
        end
    end


    -- ------------------------------------------------------------------
    -- KOSyncthing+-only capability: periodic sync.
    --
    -- These delegate to the plugin's status / control surface directly
    -- (not via REST — KOSyncthing+ manages the timer itself; the daemon
    -- doesn't even know).  They short-circuit with NOT_AVAILABLE if
    -- the active provider isn't reporting support.
    --
    -- Synchronous return values, not callbacks, because the plugin's API
    -- is itself synchronous and these calls touch in-process state, not
    -- a network.
    -- ------------------------------------------------------------------

    --- Return periodic-sync state as a table, or nil if unavailable.
    --- Shape: { enabled = bool, interval_minutes = number, next_at = number|nil }
    function t.get_periodic_sync_state()
        if not t.supports(Interface.CAPABILITIES.PERIODIC_SYNC) then return nil end
        local provider = current_provider()
        local config   = provider and provider.get_config()
        local api      = config and config.kosyncthing_plus_api
        if not api then return nil end

        local ok_e, enabled         = pcall(api.status.isPeriodicSyncEnabled)
        local ok_i, interval        = pcall(api.status.getPeriodicSyncInterval)
        local ok_n, next_at         = pcall(api.status.getNextPeriodicSyncAt)
        if not (ok_e and ok_i) then return nil end
        return {
            enabled          = enabled and true or false,
            interval_minutes = tonumber(interval) or 0,
            next_at          = ok_n and tonumber(next_at) or nil,
        }
    end

    --- Enable/disable periodic sync.  Returns true on success, nil+err
    --- string on failure (matching the plugin's own contract).
    function t.set_periodic_sync_enabled(enabled)
        if not t.supports(Interface.CAPABILITIES.PERIODIC_SYNC) then
            return nil, "periodic_sync not supported by current provider"
        end
        local config = current_provider() and current_provider().get_config()
        local api    = config and config.kosyncthing_plus_api
        if not api then return nil, "KOSyncthing+ API not available" end

        local ok, result, err = pcall(api.control.setPeriodicSyncEnabled, enabled)
        if not ok then return nil, tostring(result) end
        if result == nil then return nil, err or "unknown" end
        return result
    end

    --- Set the periodic-sync interval, in minutes (1–1440 per the plugin's
    --- own range check).  Same return shape as set_periodic_sync_enabled.
    function t.set_periodic_sync_interval(minutes)
        if not t.supports(Interface.CAPABILITIES.PERIODIC_SYNC) then
            return nil, "periodic_sync not supported by current provider"
        end
        local config = current_provider() and current_provider().get_config()
        local api    = config and config.kosyncthing_plus_api
        if not api then return nil, "KOSyncthing+ API not available" end

        local ok, result, err = pcall(api.control.setPeriodicSyncInterval, minutes)
        if not ok then return nil, tostring(result) end
        if result == nil then return nil, err or "unknown" end
        return result
    end

    --- Trigger a periodic sync NOW.  Equivalent to the timer firing
    --- right this moment; does NOT shift the schedule.  Returns true /
    --- nil+err per the plugin's contract.
    function t.run_periodic_sync_now()
        if not t.supports(Interface.CAPABILITIES.PERIODIC_SYNC) then
            return nil, "periodic_sync not supported by current provider"
        end
        local config = current_provider() and current_provider().get_config()
        local api    = config and config.kosyncthing_plus_api
        if not api then return nil, "KOSyncthing+ API not available" end

        local ok, result, err = pcall(api.control.runPeriodicSyncNow)
        if not ok then return nil, tostring(result) end
        if result == nil then return nil, err or "unknown" end
        return result
    end


    -- ------------------------------------------------------------------
    -- KOSyncthing+-only capability: one-shot Quick Sync.
    --
    -- KOSyncthing+'s `control.quickSync(on_complete)` runs a full
    -- scan-then-replicate cycle immediately, without touching any
    -- timer schedule.  We expose it as `quick_sync_all` (the suffix
    -- distinguishes it from per-folder push_book pushes the
    -- orchestrator already drives).
    --
    -- For the manual-config provider this no-ops with a debug log:
    -- the closest REST equivalent is per-folder scan, which the
    -- orchestrator's own push pathway already covers.  Better to
    -- return "not supported" than to silently do something different
    -- from what KOSyncthing+ does.
    --
    -- Returns true on success, or nil + a short error string.  Synchronous
    -- — the plugin's quickSync returns immediately; replication itself
    -- happens asynchronously inside the daemon.
    -- ------------------------------------------------------------------

    function t.quick_sync_all()
        if not t.supports(Interface.CAPABILITIES.QUICK_SYNC) then
            log.dbg("quick_sync_all: not supported by current provider; no-op")
            return nil, "quick_sync not supported by current provider"
        end
        local config = current_provider() and current_provider().get_config()
        local api    = config and config.kosyncthing_plus_api
        if not api or not api.control or type(api.control.quickSync) ~= "function" then
            return nil, "KOSyncthing+ API not available"
        end

        -- Pass nil for on_complete — fire and forget.  The KOSyncthing+
        -- published API documents this parameter as an optional
        -- completion callback; we don't consume it (replication is
        -- asynchronous inside the daemon either way).
        local ok, result = pcall(api.control.quickSync, nil)
        if not ok then return nil, tostring(result) end
        -- The plugin's quickSync doesn't return a sentinel — it either
        -- runs or raises.  No raise ⇒ success.
        return true
    end


    -- ------------------------------------------------------------------
    -- KOSyncthing+-only capability: conflict-scanner ignore registry.
    --
    -- KOSyncthing+ v1.1.5+ exposes `IgnoreRegistry:register(plugin_id,
    -- pattern)` so a companion plugin can exclude its OWN files from the
    -- conflict scanner — keeping the Conflicts badge/menu accurate.  This
    -- is the SCANNER side; set_folder_ignore (above) is the DAEMON side
    -- (`.stignore`, stops replication).  A Syncery conflict file still
    -- exists locally even with `.stignore` in place, so without this the
    -- scanner would still count/list it.
    --
    -- Pattern-agnostic on purpose (like set_folder_ignore): the caller —
    -- the bridge — owns the Syncery pattern source (Stignore.CONFLICT_PATTERN)
    -- and the plugin id, and passes both in.
    -- ------------------------------------------------------------------

    function t.register_conflict_scanner_ignore(plugin_id, pattern)
        if not t.supports(Interface.CAPABILITIES.CONFLICT_IGNORE_REGISTRY) then
            log.dbg("register_conflict_scanner_ignore: not supported by current provider; no-op")
            return nil, "conflict_ignore_registry not supported by current provider"
        end
        if type(plugin_id) ~= "string" or plugin_id == ""
           or type(pattern) ~= "string" or pattern == "" then
            return nil, "plugin_id and pattern required"
        end
        local config = current_provider() and current_provider().get_config()
        local api    = config and config.kosyncthing_plus_api
        if not api or type(api.IgnoreRegistry) ~= "table"
           or type(api.IgnoreRegistry.register) ~= "function" then
            return nil, "KOSyncthing+ API not available"
        end

        -- Colon call: IgnoreRegistry:register(plugin_id, pattern) — `self`
        -- is the registry table.  The v1.1.6 API accepts a single glob OR a
        -- list and REPLACES that plugin's set; we pass a single string, so
        -- re-registering the same id with the same pattern is idempotent
        -- (replaces with the same value).  Registration is an in-process table
        -- write (no REST round-trip), so unlike set_folder_ignore it never blocks.
        local ok, err = pcall(function()
            api.IgnoreRegistry:register(plugin_id, pattern)
        end)
        if not ok then return nil, tostring(err) end
        return true
    end


    -- ------------------------------------------------------------------
    -- KOSyncthing+-only capability: daemon process control.
    --
    -- KOSyncthing+ exposes `control.start(cb)` / `control.stop(cb)` —
    -- fire-and-forget with a NO-ARG completion callback — plus
    -- `status.isRunning()`.  This lets a power-user start or stop the
    -- Syncthing daemon process itself; the status panel surfaces it as
    -- a gated button.
    --
    -- Unlike quick_sync_all (synchronous) and the periodic-sync
    -- controls (synchronous), start/stop are CALLBACK-shaped because
    -- the plugin's own start/stop are.  We honour the transport layer's
    -- "callback fires exactly once" contract by wrapping the caller's
    -- callback in SafeCallback.once: the plugin's no-arg callback maps to
    -- `(true)`; every short-circuit (unsupported / missing API method /
    -- a raised error) maps to `(false, err)` so a daemon that will not
    -- start/stop surfaces a clear result rather than a silent no-op.
    --
    -- The manual-config provider does not advertise DAEMON_CONTROL —
    -- there is no REST endpoint to launch a process that is not
    -- running — so these all short-circuit there.
    -- ------------------------------------------------------------------

    --- Is the Syncthing daemon process currently running?
    --- Returns true/false from the plugin's `status.isRunning()`, or nil
    --- when DAEMON_CONTROL is unsupported or the KOSyncthing+ API is
    --- unreachable (a best-effort read; the UI degrades to a neutral
    --- label on nil).
    function t.is_daemon_running()
        if not t.supports(Interface.CAPABILITIES.DAEMON_CONTROL) then
            return nil
        end
        local config = current_provider() and current_provider().get_config()
        local api    = config and config.kosyncthing_plus_api
        if not (api and api.status and type(api.status.isRunning) == "function") then
            return nil
        end
        local ok, running = pcall(api.status.isRunning)
        if not ok then return nil end
        return running and true or false
    end

    --- Shared implementation for start_daemon / stop_daemon.  `which`
    --- is "start" or "stop"; `fn_name` the matching KOSyncthing+ control
    --- method.  `callback` fires exactly once: (true) when the plugin's
    --- completion callback fires, (false, err) on any short-circuit.
    local function daemon_control(which, fn_name, callback)
        local once = SafeCallback.once(
            type(callback) == "function" and callback or function() end,
            "syncthing.daemon_" .. which)

        if not t.supports(Interface.CAPABILITIES.DAEMON_CONTROL) then
            once(false, "daemon_control not supported by current provider")
            return
        end
        local config = current_provider() and current_provider().get_config()
        local api    = config and config.kosyncthing_plus_api
        if not (api and api.control and type(api.control[fn_name]) == "function") then
            once(false, "KOSyncthing+ API not available")
            return
        end

        -- The plugin's start/stop take a no-arg completion callback.
        -- Map "callback fired" to our (true) success signal — that is
        -- the only outcome the plugin's API surface lets us observe.
        local ok_call, call_err = pcall(api.control[fn_name], function()
            once(true)
        end)
        if not ok_call then
            log.warn("daemon %s raised: %s", which, tostring(call_err))
            once(false, "internal")
        end
    end

    --- Start the Syncthing daemon process.  `callback(ok, err)` fires
    --- exactly once — see daemon_control above.
    function t.start_daemon(callback)
        daemon_control("start", "start", callback)
    end

    --- Stop the Syncthing daemon process.  `callback(ok, err)` fires
    --- exactly once — see daemon_control above.
    function t.stop_daemon(callback)
        daemon_control("stop", "stop", callback)
    end

    -- Validate eagerly: if I've broken the interface, fail at construction
    -- with a readable error instead of two screens later inside a callback.
    -- (The orchestrator also validates, belt-and-braces.)
    local ok, problems = Interface.validate_implementation(t)
    if not ok then
        error("Syncthing Transport construction is broken: "
              .. table.concat(problems, "; "))
    end

    return t
end


return Transport
