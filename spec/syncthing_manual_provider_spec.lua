-- =============================================================================
-- spec/syncthing_manual_provider_spec.lua
-- =============================================================================
--
-- Tests for syncery_transports/syncthing/providers/manual_provider.lua.
--
-- The provider takes a settings_reader function — we pass a fake that
-- reads from an in-memory table.  No G_reader_settings, no real I/O.
--
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_manual_provider_spec_" .. tostring(os.time()))

local ManualProvider = require("syncery_transports/syncthing/providers/manual_provider")


-- Helper: build a settings_reader backed by a table.
local function reader(t)
    return function(key) return t[key] end
end


-- ----------------------------------------------------------------------------
-- id() returns the stable string.
-- ----------------------------------------------------------------------------


do
    local p = ManualProvider.new(reader({}))
    h.assert_equal(p.id(), "manual", "id is 'manual'")
end


-- ----------------------------------------------------------------------------
-- get_config: no settings → nil.
-- ----------------------------------------------------------------------------


do
    local p = ManualProvider.new(reader({}))
    h.assert_nil(p.get_config(), "empty settings → no config")
end


-- ----------------------------------------------------------------------------
-- get_config: the API key is the one required field.  A stored URL (if any)
-- is ignored; without an API key there is no config.
-- ----------------------------------------------------------------------------


do
    local p = ManualProvider.new(reader({
        syncery_syncthing_url = "http://127.0.0.1:8384",   -- stale legacy key, ignored
    }))
    h.assert_nil(p.get_config(), "a stored URL without an API key is not enough")
end


do
    local p = ManualProvider.new(reader({
        syncery_syncthing_api_key = "",
    }))
    h.assert_nil(p.get_config(), "empty API key → no config")
end


-- ----------------------------------------------------------------------------
-- get_config: API key present → config, with the URL COMPUTED on the loopback
-- (no stored URL needed any more).
-- ----------------------------------------------------------------------------


do
    local p = ManualProvider.new(reader({
        syncery_syncthing_api_key = "secret",
    }))
    local cfg = p.get_config()
    h.assert_equal(type(cfg), "table",               "API key alone → config table")
    h.assert_equal(cfg.url, "http://127.0.0.1:8384", "URL computed: http loopback, default port")
    h.assert_equal(cfg.api_key, "secret",            "API key passed through")
    h.assert_nil(cfg.folder_id,                       "no folder picked yet -> folder_id nil")
    h.assert_nil(cfg.folders,                         "manual provider exposes no folders field")
end


-- ----------------------------------------------------------------------------
-- get_config: the computed URL reflects the stored port + scheme.
-- ----------------------------------------------------------------------------


do
    local p = ManualProvider.new(reader({
        syncery_syncthing_api_key = "k",
        syncery_syncthing_port    = 9000,
        syncery_syncthing_scheme  = "https",
    }))
    local cfg = p.get_config()
    h.assert_equal(cfg.url, "https://127.0.0.1:9000", "URL built from stored scheme + port")
end


-- ----------------------------------------------------------------------------
-- get_config: explicit folder_id is preserved.
-- ----------------------------------------------------------------------------


do
    local p = ManualProvider.new(reader({
        syncery_syncthing_url       = "http://x",
        syncery_syncthing_api_key   = "k",
        syncery_syncthing_folder_id = "books-7y3xz",
    }))
    local cfg = p.get_config()
    h.assert_equal(cfg.folder_id, "books-7y3xz", "explicit folder_id wins")
end


-- ----------------------------------------------------------------------------
-- supports(): always false for the manual provider.
-- ----------------------------------------------------------------------------


do
    local p = ManualProvider.new(reader({}))
    h.assert_false(p.supports("ignore_patterns"),
        "manual does not expose ignore_patterns (no provider-level path)")
    h.assert_false(p.supports("event_subscription"),
        "no events without a KOSyncthing+-style API")
    h.assert_false(p.supports("conflicts_detailed"),
        "no detailed conflict records (scanner is a different module)")
    h.assert_false(p.supports("anything"), "unknown capability → false")
end


-- ----------------------------------------------------------------------------
-- Constructor rejects a non-function settings_reader loudly.
-- ----------------------------------------------------------------------------


do
    local ok = pcall(ManualProvider.new, nil)
    h.assert_false(ok, "nil settings_reader rejected")

    local ok2 = pcall(ManualProvider.new, {})
    h.assert_false(ok2, "non-function settings_reader rejected")
end


-- ----------------------------------------------------------------------------
-- A garbage/legacy syncery_syncthing_url value is ignored entirely — the URL
-- is computed, so it never reaches the config.
-- ----------------------------------------------------------------------------


do
    local p = ManualProvider.new(reader({
        syncery_syncthing_url     = 12345,           -- legacy junk, ignored
        syncery_syncthing_api_key = "k",
    }))
    local cfg = p.get_config()
    h.assert_equal(type(cfg), "table",               "junk URL key doesn't block config")
    h.assert_equal(cfg.url, "http://127.0.0.1:8384", "URL computed, ignoring the junk key")
end
