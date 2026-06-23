-- =============================================================================
-- syncery_transports/syncthing/providers/manual_provider.lua
-- =============================================================================
--
-- The "manual" Syncthing provider: reads the daemon's API key out of the
-- user's settings and builds its base URL from the loopback host plus the
-- stored scheme/port (no full URL is entered or stored any more).
--
-- This provider is what works WITHOUT the kosyncthing_plus plugin installed —
-- the user has a Syncthing daemon running ON THIS DEVICE (Termux, the desktop
-- app, etc.) and Syncery talks to it over REST on 127.0.0.1.  The host is the
-- loopback by construction: Syncery's progress files live on the local
-- filesystem, so the daemon that replicates them is necessarily local (a
-- remote daemon could not see those files to sync them).
--
-- A provider's job is narrow: produce a config table or signal
-- "I can't".  No HTTP calls, no caching, no policy.  The transport
-- layer decides what to do with the result.
--
-- INTERFACE
--
-- Every provider returned from this module has:
---   id()              → string         — stable internal id
---   get_config()      → table|nil      — config table, or nil if not ready
---   supports(cap)     → bool           — optional-capability check
---
--- The config table shape is what http_client expects to build on top of:
---   { url       = string,    -- computed "<scheme>://127.0.0.1:<port>"
---     api_key   = string,    -- the X-API-Key header value
---     folder_id = string,    -- default Syncthing folder id for this device
---     folders   = table|nil, -- list of {folder_id, path} for all folders,
---                              -- or nil if the provider can't enumerate
---   }
---
--- Settings keys (matched to legacy `syncery_syncthing_*` prefix so
--- we can drop syncery_syncthing.lua without burning user settings —
--- the values written by the legacy menu are still readable here):
---   syncery_syncthing_api_key    — API key (the one required field)
---   syncery_syncthing_port       — GUI port on 127.0.0.1 (optional; 8384 if absent)
---   syncery_syncthing_scheme     — "http" (default) or "https" (optional)
---   syncery_syncthing_folder_id  — default folder id (optional; "default" if absent)
---
--- DEPENDENCY INJECTION
---
--- The settings_reader is injected, not pulled from G_reader_settings
--- directly.  Tests pass a fake reader (`function(key) return data[key] end`);
--- production passes a thin wrapper around G_reader_settings.  Same
--- pattern as the orchestrator's clock and scheduler — the boundary
--- to "real globals" is exactly one line in the consumer.
-- =============================================================================


local LocalUrl = require("syncery_transports/syncthing/local_url")


local ManualProvider = {}


--- Build a new manual provider.
--- @param settings_reader function(key: string) → any   — required
function ManualProvider.new(settings_reader)
    assert(type(settings_reader) == "function",
        "ManualProvider.new: settings_reader function required")

    local p = {}

    function p.id() return "manual" end

    function p.get_config()
        local api_key   = settings_reader("syncery_syncthing_api_key")
        local folder_id = settings_reader("syncery_syncthing_folder_id")

        -- Readiness hinges on the API key alone: the daemon is always on the
        -- loopback, so its URL is COMPUTED (host 127.0.0.1 + the stored
        -- scheme/port), never user-entered.
        if type(api_key) ~= "string" or api_key == "" then return nil end

        local url = LocalUrl.build(
            settings_reader("syncery_syncthing_scheme"),
            settings_reader("syncery_syncthing_port"))

        return {
            url       = url,
            api_key   = api_key,
            -- nil when nothing is picked yet: the folder picker is the only
            -- way to set a real folder, and the scan guard treats a nil/empty
            -- id as "not configured" (so push is skipped).  No "default" seed --
            -- modern Syncthing/Android has no folder with that id.
            folder_id = (type(folder_id) == "string" and folder_id ~= "")
                         and folder_id or nil,
            -- No `folders` here: list_folders re-enumerates live over REST for
            -- the manual provider (only the KOSyncthing+ branch reads config.folders),
            -- so the stored folder isn't mirrored into the provider config.
        }
    end

    function p.supports(_capability)
        -- The manual provider exposes ZERO bonus capabilities — it's
        -- just a config-source.  No event subscription (no daemon-side
        -- API for that), no IgnoreRegistry (that's a KOSyncthing+ UI concept,
        -- not part of Syncthing itself), no detailed conflict records
        -- (we'd have to compute them via filesystem scan, which is the
        -- conflict_scanner module's job, not the provider's).
        return false
    end

    return p
end


return ManualProvider
