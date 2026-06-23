-- =============================================================================
-- spec/syncthing_providers_spec.lua
-- =============================================================================
--
-- Tests for syncery_transports/syncthing/providers/init.lua — the
-- provider discovery chain.
--
-- Chunk 3 has only manual_provider in the chain, so most of these
-- tests are "does it return manual_provider when settings are set,
-- nil otherwise".  Chunk 4 will extend with kosyncthing_plus_provider scenarios.
--
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_providers_spec_" .. tostring(os.time()))

local Providers = require("syncery_transports/syncthing/providers/init")


local function reader(t)
    return function(key) return t[key] end
end


-- ----------------------------------------------------------------------------
-- discover() with no settings AND no KOSyncthing+ → nil.
-- ----------------------------------------------------------------------------


do
    local provider = Providers.discover({
        settings_reader = reader({}),
        api_resolver    = function() return nil end,
    })
    h.assert_nil(provider, "nothing configured → no provider")
end


-- ----------------------------------------------------------------------------
-- discover() with manual settings set AND no KOSyncthing+ → manual provider.
-- ----------------------------------------------------------------------------


do
    local provider = Providers.discover({
        settings_reader = reader({
            syncery_syncthing_url     = "http://127.0.0.1:8384",
            syncery_syncthing_api_key = "k",
        }),
        api_resolver = function() return nil end,
    })
    h.assert_true(provider ~= nil,        "got a provider")
    h.assert_equal(provider.id(), "manual", "no KOSyncthing+ → manual wins")
    local cfg = provider.get_config()
    h.assert_equal(cfg.url, "http://127.0.0.1:8384", "manual config wired through")
end


-- ----------------------------------------------------------------------------
-- discover() with BOTH KOSyncthing+ present AND manual settings → KOSyncthing+ wins
-- (it goes first in the chain — no API key in our process is strictly
-- better than holding one).
-- ----------------------------------------------------------------------------


do
    local kosyncthing_plus_api = { apiCall = function() return {} end }
    local provider = Providers.discover({
        settings_reader = reader({
            syncery_syncthing_url     = "http://127.0.0.1:8384",
            syncery_syncthing_api_key = "k",
        }),
        api_resolver = function() return kosyncthing_plus_api end,
    })
    h.assert_equal(provider.id(), "kosyncthing_plus", "KOSyncthing+ beats manual when both available")
end


-- ----------------------------------------------------------------------------
-- discover() with ONLY KOSyncthing+ present → KOSyncthing+ provider (no manual settings
-- needed; this is the "user installed KOSyncthing+ and Syncery just works" path).
-- ----------------------------------------------------------------------------


do
    local kosyncthing_plus_api = { apiCall = function() return {} end }
    local provider = Providers.discover({
        settings_reader = reader({}),    -- no manual config
        api_resolver    = function() return kosyncthing_plus_api end,
    })
    h.assert_true(provider ~= nil,             "got a provider")
    h.assert_equal(provider.id(), "kosyncthing_plus",       "KOSyncthing+-only setup works")
    h.assert_true(provider.get_config() ~= nil, "config returned")
end


-- ----------------------------------------------------------------------------
-- NO KOSyncthing+, but a local-daemon config.xml is readable → the config.xml
-- provider wins (api_key auto-read off disk).  This is the e-ink "other
-- Syncthing plugin with its own daemon" case.
-- ----------------------------------------------------------------------------


local CFGPATH = "/dd/settings/syncthing/config.xml"
local CFGXML  =
    [[<gui tls="false"><address>127.0.0.1:8384</address><apikey>FROMXML</apikey></gui>]]

do
    local provider = Providers.discover({
        settings_reader = reader({}),
        api_resolver    = function() return nil end,           -- no KOSyncthing+
        config_paths    = function() return { CFGPATH } end,
        file_reader     = function(p) return (p == CFGPATH) and CFGXML or nil end,
    })
    h.assert_true(provider ~= nil,                "config.xml present → got a provider")
    h.assert_equal(provider.id(), "config_xml",   "no KOSyncthing+ but config.xml → config_xml wins")
    h.assert_equal(provider.get_config().api_key, "FROMXML", "api_key auto-read from config.xml")
end


-- ----------------------------------------------------------------------------
-- config.xml (auto) takes precedence over a hand-entered manual key.
-- ----------------------------------------------------------------------------


do
    local provider = Providers.discover({
        settings_reader = reader({ syncery_syncthing_api_key = "manualkey" }),
        api_resolver    = function() return nil end,
        config_paths    = function() return { CFGPATH } end,
        file_reader     = function(p) return (p == CFGPATH) and CFGXML or nil end,
    })
    h.assert_equal(provider.id(), "config_xml", "config.xml (auto) beats a manual key")
end


-- ----------------------------------------------------------------------------
-- No KOSyncthing+, no readable config.xml, but a manual key → manual fallback
-- (e.g. Android talking to an external app whose config.xml isn't on disk).
-- ----------------------------------------------------------------------------


do
    local provider = Providers.discover({
        settings_reader = reader({ syncery_syncthing_api_key = "manualkey" }),
        api_resolver    = function() return nil end,
        config_paths    = function() return {} end,            -- no config.xml
        file_reader     = function() return nil end,
    })
    h.assert_equal(provider.id(), "manual", "no auto source → manual fallback")
end


-- ----------------------------------------------------------------------------
-- KOSyncthing+ is first in the chain: it wins over BOTH a readable config.xml
-- and a hand-entered manual key.
-- ----------------------------------------------------------------------------


do
    local kosyncthing_plus_api = { apiCall = function() return {} end }
    local provider = Providers.discover({
        settings_reader = reader({ syncery_syncthing_api_key = "manualkey" }),
        api_resolver    = function() return kosyncthing_plus_api end,
        config_paths    = function() return { CFGPATH } end,
        file_reader     = function(p) return (p == CFGPATH) and CFGXML or nil end,
    })
    h.assert_equal(provider.id(), "kosyncthing_plus",
        "KOSyncthing+ wins over config.xml and manual")
end


-- ----------------------------------------------------------------------------
-- config_xml_key_available: the wizard's cheap "is a key auto-readable?" probe
-- (reuses ConfigXmlProvider so it can't drift from discover()).
-- ----------------------------------------------------------------------------


do
    h.assert_true(Providers.config_xml_key_available({
        config_paths = function() return { CFGPATH } end,
        file_reader  = function(p) return (p == CFGPATH) and CFGXML or nil end,
    }), "config.xml with a key -> available")

    h.assert_false(Providers.config_xml_key_available({
        config_paths = function() return {} end,
        file_reader  = function() return nil end,
    }), "no config.xml -> not available")

    h.assert_false(Providers.config_xml_key_available({}),
        "no injected paths (headless, no DataStorage) -> not available")
end


-- ----------------------------------------------------------------------------
-- discover() called without opts → loud failure.
-- A silent default for settings_reader would mask configuration bugs;
-- requiring it explicitly forces the consumer to think about where
-- the settings come from.
-- ----------------------------------------------------------------------------


do
    local ok = pcall(Providers.discover)
    h.assert_false(ok, "no opts → assert fires")

    local ok2 = pcall(Providers.discover, {})
    h.assert_false(ok2, "no settings_reader → assert fires")
end


-- ----------------------------------------------------------------------------
-- A misbehaving settings reader doesn't propagate.  Discovery
-- swallows constructor / get_config crashes so one broken provider
-- doesn't kill the chain.
-- ----------------------------------------------------------------------------


do
    local provider = Providers.discover({
        settings_reader = function(_k) error("settings backend exploded") end,
        api_resolver    = function() return nil end,
    })
    h.assert_nil(provider, "errors swallowed; result is nil")
end
