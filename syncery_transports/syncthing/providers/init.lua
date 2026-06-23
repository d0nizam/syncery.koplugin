-- =============================================================================
-- syncery_transports/syncthing/providers/init.lua
-- =============================================================================
--
-- The provider chain.  Discovery tries providers in priority order
-- and returns the first that can supply config.
--
-- Chunk 3 has exactly one provider — the manual one.  Chunk 4 will
-- prepend `kosyncthing_plus_provider` to the chain, so when kosyncthing_plus is
-- installed the user doesn't need to enter URL + API key manually.
--
-- The chain pattern (even with a single entry today) is the seam
-- that keeps `syncthing/transport.lua` from needing edits.
-- That file consumes whatever provider this module returns; adding a
-- new candidate to the priority list is a one-line change in this
-- file plus the new provider's own implementation file.
--
-- USAGE
--
--     local Providers = require("syncery_transports/syncthing/providers/init")
--     local provider = Providers.discover({
--         settings_reader = function(k)
--             return G_reader_settings and G_reader_settings:readSetting(k)
--         end,
--     })
--     if provider then
--         local config = provider.get_config()
--         -- ... build HttpClient from config ...
--     else
--         -- No usable provider; transport reports is_available = false.
--     end
--
-- =============================================================================


local ManualProvider = require("syncery_transports/syncthing/providers/manual_provider")
local KOSyncthingPlusProvider   = require("syncery_transports/syncthing/providers/kosyncthing_plus_provider")
local ConfigXmlProvider = require("syncery_transports/syncthing/providers/config_xml_provider")
local Log            = require("syncery_transports/log")
local log            = Log.tag("syncthing.providers")


local Providers = {}


--- The ordered list of provider constructors.  Each entry is a function
--- that takes `opts` and returns a provider instance (or nil).
---
--- Priority order (the FIRST provider whose get_config returns non-nil wins):
---   1. KOSyncthing+ — its in-process apiCall proxy is strictly better than
---      manual REST (the API key never enters our process; bonus capabilities
---      the bare REST API can't offer).
---   2. config.xml — a DIFFERENT local-daemon Syncthing plugin's config.xml,
---      read straight off disk so its api_key/port/scheme auto-populate (no
---      hand entry).  Declines (→ falls through) when no readable config.xml
---      exists, e.g. on Android talking to an EXTERNAL app whose config lives
---      in the app's own sandbox.
---   3. manual — the fallback: a hand-entered API key, used only when neither
---      auto source is detectable.
---
--- The chain is UNCONDITIONAL: auto always precedes manual.  There is no
--- "prefer manual" switch — on a loopback-only design there is exactly one
--- local daemon, and a readable config.xml / the in-process API IS that
--- daemon's authoritative config, so a manual entry could only supply WRONG
--- values for the same daemon, never point at a different one.
local function build_candidates(opts)
    return {
        function() return KOSyncthingPlusProvider.new({
            api_resolver    = opts.api_resolver,    -- nil → default global lookup
            settings_reader = opts.settings_reader,
        }) end,
        function() return ConfigXmlProvider.new({
            settings_reader = opts.settings_reader,
            config_paths    = opts.config_paths,    -- nil → default DataStorage paths
            file_reader     = opts.file_reader,     -- nil → default io.open reader
        }) end,
        function() return ManualProvider.new(opts.settings_reader) end,
    }
end


--- Try each provider in priority order; return the first one whose
--- `get_config()` returns non-nil.  If none can supply config, return
--- nil — the transport then reports is_available=false to the
--- orchestrator, which skips it.
---
---@param opts table  { settings_reader = function }
---@return table|nil provider
function Providers.discover(opts)
    opts = opts or {}
    assert(type(opts.settings_reader) == "function",
        "Providers.discover: opts.settings_reader function required")

    for _, ctor in ipairs(build_candidates(opts)) do
        local ok, provider = pcall(ctor)
        if not ok then
            log.warn("provider constructor raised: %s", tostring(provider))
        elseif provider then
            local ok_cfg, cfg = pcall(provider.get_config)
            if ok_cfg and cfg then
                log.dbg("selected provider: %s", provider.id())
                return provider
            end
            -- get_config returned nil or raised: skip silently — that's
            -- the documented "I can't help" signal.
        end
    end
    log.dbg("no usable Syncthing provider")
    return nil
end


--- True iff a local-daemon config.xml yields a usable API key.
---
--- This is the cheap (one file read) probe the first-run wizard uses to
--- decide whether it can SKIP the manual API-key step: KOSyncthing+ is
--- detected separately (a cost-free global check, no API call), and this
--- covers the other auto source.  It constructs the SAME ConfigXmlProvider
--- the discovery chain uses, so the wizard's "can we auto-detect a key?"
--- answer can never drift from what discover() will actually do.
---
---@param opts table  { settings_reader?, config_paths?, file_reader? }  (all
---                     optional; nil paths/reader fall back to the production
---                     DataStorage + io.open defaults)
---@return boolean
function Providers.config_xml_key_available(opts)
    opts = opts or {}
    local provider = ConfigXmlProvider.new({
        settings_reader = opts.settings_reader or function() return nil end,
        config_paths    = opts.config_paths,
        file_reader     = opts.file_reader,
    })
    local ok, cfg = pcall(provider.get_config)
    return ok and cfg ~= nil
end


return Providers
