-- =============================================================================
-- spec/syncthing_config_xml_provider_spec.lua
-- =============================================================================
--
-- Tests for syncery_transports/syncthing/providers/config_xml_provider.lua.
--
-- The provider takes injected config_paths + file_reader (+ settings_reader),
-- so we feed it fake config.xml content from an in-memory map — no real
-- DataStorage, no real file I/O.
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_config_xml_provider_spec_" .. tostring(os.time()))

local ConfigXmlProvider =
    require("syncery_transports/syncthing/providers/config_xml_provider")


-- Standard + legacy candidate paths (the provider tries standard first).
local STD = "/dd/settings/syncthing/config.xml"
local LEG = "/dd/settings/syncthing-legacy/config.xml"


-- A realistic Syncthing config.xml (http, default port).
local FULL = [[
<configuration version="37">
  <gui enabled="true" tls="false" debugging="false">
    <address>127.0.0.1:8384</address>
    <apikey>ABC123KEY</apikey>
    <theme>default</theme>
  </gui>
  <folder id="books-7y3xz" path="/mnt/onboard/books"></folder>
</configuration>
]]

-- TLS on, non-default port.
local TLS = [[
<configuration version="37">
  <gui enabled="true" tls="true">
    <address>127.0.0.1:8443</address>
    <apikey>TLSKEY</apikey>
  </gui>
</configuration>
]]

-- Only an apikey — no <gui>/<address>/tls.  URL must fall back to defaults.
local SPARSE = "<apikey>SPARSEKEY</apikey>"

-- Empty apikey element — treated as ABSENT (would 401 every call).
local EMPTYKEY = [[
<configuration version="37">
  <gui tls="false"><address>127.0.0.1:8384</address><apikey></apikey></gui>
</configuration>
]]

-- GUI bound to 0.0.0.0 on a custom port: the host is ignored (loopback wins),
-- only the port is taken.
local BIND_ALL = [[
<gui tls="false"><address>0.0.0.0:9001</address><apikey>BINDKEY</apikey></gui>
]]


-- Build a provider whose config_paths returns `paths` in order and whose
-- file_reader returns files[path] (nil when absent).
local function provider(paths, files, settings)
    return ConfigXmlProvider.new({
        config_paths    = function() return paths end,
        file_reader     = function(p) return files[p] end,
        settings_reader = function(k) return (settings or {})[k] end,
    })
end


-- ----------------------------------------------------------------------------
-- id() is the stable string.
-- ----------------------------------------------------------------------------


do
    local p = provider({}, {})
    h.assert_equal(p.id(), "config_xml", "id is 'config_xml'")
end


-- ----------------------------------------------------------------------------
-- No readable config.xml → nil (the chain falls through to manual).
-- ----------------------------------------------------------------------------


do
    local p = provider({ STD, LEG }, {})   -- reader returns nil for every path
    h.assert_nil(p.get_config(), "no config.xml anywhere → no config")
end


-- ----------------------------------------------------------------------------
-- Standard config.xml: api_key + computed http URL on the loopback.
-- ----------------------------------------------------------------------------


do
    local p = provider({ STD, LEG }, { [STD] = FULL })
    local cfg = p.get_config()
    h.assert_equal(type(cfg), "table",               "config.xml present → config table")
    h.assert_equal(cfg.api_key, "ABC123KEY",         "api_key read from <apikey>")
    h.assert_equal(cfg.url, "http://127.0.0.1:8384", "http URL, port from <address>")
    h.assert_nil(cfg.folder_id,                       "no folder picked yet → folder_id nil")
    h.assert_nil(cfg.folders,                         "no folders field (REST re-enumerates)")
end


-- ----------------------------------------------------------------------------
-- tls="true" → https; port from <address>.
-- ----------------------------------------------------------------------------


do
    local p = provider({ STD }, { [STD] = TLS })
    local cfg = p.get_config()
    h.assert_equal(cfg.api_key, "TLSKEY",              "api_key read")
    h.assert_equal(cfg.url, "https://127.0.0.1:8443",  "tls=true → https, custom port")
end


-- ----------------------------------------------------------------------------
-- Sparse config (apikey only): URL falls back to http + default 8384.
-- ----------------------------------------------------------------------------


do
    local p = provider({ STD }, { [STD] = SPARSE })
    local cfg = p.get_config()
    h.assert_equal(cfg.api_key, "SPARSEKEY",          "api_key read from a minimal file")
    h.assert_equal(cfg.url, "http://127.0.0.1:8384",  "missing gui/address → http + default port")
end


-- ----------------------------------------------------------------------------
-- Empty <apikey></apikey> is treated as absent → provider declines.
-- ----------------------------------------------------------------------------


do
    local p = provider({ STD }, { [STD] = EMPTYKEY })
    h.assert_nil(p.get_config(), "empty <apikey> → no config (would 401)")
end


-- ----------------------------------------------------------------------------
-- The GUI binding host is ignored; only the port is taken (loopback wins).
-- ----------------------------------------------------------------------------


do
    local p = provider({ STD }, { [STD] = BIND_ALL })
    local cfg = p.get_config()
    h.assert_equal(cfg.api_key, "BINDKEY",            "api_key read")
    h.assert_equal(cfg.url, "http://127.0.0.1:9001",  "0.0.0.0:9001 → loopback host, port 9001")
end


-- ----------------------------------------------------------------------------
-- Legacy fallback: standard path absent, legacy path has the config.
-- ----------------------------------------------------------------------------


do
    local p = provider({ STD, LEG }, { [LEG] = FULL })   -- only the legacy file exists
    local cfg = p.get_config()
    h.assert_equal(type(cfg), "table",        "legacy config.xml is used when standard is absent")
    h.assert_equal(cfg.api_key, "ABC123KEY",  "api_key read from the legacy path")
end


-- ----------------------------------------------------------------------------
-- First match wins: standard is tried before legacy.
-- ----------------------------------------------------------------------------


do
    local p = provider({ STD, LEG }, { [STD] = FULL, [LEG] = TLS })
    local cfg = p.get_config()
    h.assert_equal(cfg.api_key, "ABC123KEY", "standard path wins over legacy (tried first)")
end


-- ----------------------------------------------------------------------------
-- An explicitly picked folder_id is carried through.
-- ----------------------------------------------------------------------------


do
    local p = provider({ STD }, { [STD] = FULL },
        { syncery_syncthing_folder_id = "books-7y3xz" })
    local cfg = p.get_config()
    h.assert_equal(cfg.folder_id, "books-7y3xz", "picked folder_id from settings is carried")
end


-- ----------------------------------------------------------------------------
-- supports(): always false (pure config-source, like manual).
-- ----------------------------------------------------------------------------


do
    local p = provider({ STD }, { [STD] = FULL })
    h.assert_false(p.supports("ignore_patterns"),    "no provider-level ignore_patterns")
    h.assert_false(p.supports("event_subscription"), "no events (not an in-process API)")
    h.assert_false(p.supports("anything"),           "unknown capability → false")
end


-- ----------------------------------------------------------------------------
-- Constructor rejects non-function injected deps loudly.
-- ----------------------------------------------------------------------------


do
    local ok1 = pcall(ConfigXmlProvider.new, { settings_reader = 5 })
    h.assert_false(ok1, "non-function settings_reader rejected")

    local ok2 = pcall(ConfigXmlProvider.new, { config_paths = 5 })
    h.assert_false(ok2, "non-function config_paths rejected")

    local ok3 = pcall(ConfigXmlProvider.new, { file_reader = 5 })
    h.assert_false(ok3, "non-function file_reader rejected")
end
