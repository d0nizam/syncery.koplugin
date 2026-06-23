-- =============================================================================
-- spec/syncery_settings_spec.lua
-- =============================================================================
--
-- Tests for syncery_settings.lua — the transport-settings I/O module.
--
-- Covers:
--   • read/write roundtrips for every public key
--   • defaults when no value is persisted
--   • validation at the write boundary (URL trailing-slash normalization,
--     folder_id empty-string fallback, types coerced/rejected)
--   • legacy plaintext password migration
--   • on_change listener fires per-transport and per-write
--   • cloud server table persistence (table value, not JSON string)
--
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_settings_spec_" .. tostring(os.time()))

-- This spec exercises Settings against an absent _G.G_reader_settings —
-- specifically, the "no backend → defaults" assertion below requires it.
-- Earlier specs (e.g. the menu specs) may have installed a global
-- G_reader_settings stub via menu_test_support; null it out before the
-- Settings module captures the global on first use, so this spec
-- observes the documented "no backend" behaviour.
_G.G_reader_settings = nil

local Settings = require("syncery_settings")


-- ----------------------------------------------------------------------------
-- Test backend.  A tiny in-memory shim with the same shape as
-- G_reader_settings: readSetting / saveSetting / delSetting.
-- ----------------------------------------------------------------------------


local function make_backend(initial)
    local store = {}
    if initial then for k, v in pairs(initial) do store[k] = v end end
    return {
        _store = store,
        readSetting = function(self, key) return self._store[key] end,
        saveSetting = function(self, key, value) self._store[key] = value end,
        delSetting  = function(self, key) self._store[key] = nil end,
    }
end


local function with_backend(initial)
    Settings._reset_for_tests()
    local b = make_backend(initial)
    Settings._set_backend(b)
    return b
end


-- ----------------------------------------------------------------------------
-- Master toggles default to false; round-trip through booleans.
-- ----------------------------------------------------------------------------


do
    local b = with_backend()
    h.assert_false(Settings.get_syncthing_enabled(), "syncthing toggle default false")
    h.assert_false(Settings.get_cloud_enabled(),     "cloud toggle default false")

    -- COLLAPSED: get_*_enabled reads the canonical `syncery_use_<name>` key that
    -- the menu checkbox + wizard write directly.  There is no set_*_enabled —
    -- the old setter only wrote the now-removed `sync_via_*` mirror.
    b:saveSetting("syncery_use_syncthing", true)
    b:saveSetting("syncery_use_cloud", true)
    h.assert_true(Settings.get_syncthing_enabled(),  "syncthing enabled reads syncery_use_syncthing")
    h.assert_true(Settings.get_cloud_enabled(),      "cloud enabled reads syncery_use_cloud")

    b:saveSetting("syncery_use_syncthing", false)
    h.assert_false(Settings.get_syncthing_enabled(), "syncthing toggle off again")
end


-- ----------------------------------------------------------------------------
-- Syncthing URL is COMPUTED from scheme + port (host hardcoded), not stored.
-- ----------------------------------------------------------------------------


do
    with_backend()
    h.assert_equal(Settings.get_syncthing_url(), "http://127.0.0.1:8384",
        "default URL = http loopback on 8384")

    Settings.set_syncthing_port(9000)
    Settings.set_syncthing_scheme("https")
    h.assert_equal(Settings.get_syncthing_url(), "https://127.0.0.1:9000",
        "URL reflects the stored scheme + port")
end


-- ----------------------------------------------------------------------------
-- Syncthing port: default 8384; only 1024-65535 persists; corrupt → default.
-- ----------------------------------------------------------------------------


do
    with_backend()
    h.assert_equal(Settings.get_syncthing_port(), 8384, "default port 8384")

    Settings.set_syncthing_port(9000)
    h.assert_equal(Settings.get_syncthing_port(), 9000, "valid port roundtrips")

    Settings.set_syncthing_port(80)        -- below the 1024 floor → rejected
    h.assert_equal(Settings.get_syncthing_port(), 9000,
        "privileged port rejected (keeps previous)")

    Settings.set_syncthing_port(70000)     -- above 65535 → rejected
    h.assert_equal(Settings.get_syncthing_port(), 9000,
        "port >65535 rejected (keeps previous)")

    Settings.set_syncthing_port("8443")    -- numeric string accepted
    h.assert_equal(Settings.get_syncthing_port(), 8443, "numeric-string port coerced")
end


do
    -- A corrupt persisted value reads back as the default, not a crash.
    with_backend({ syncery_syncthing_port = "not-a-port" })
    h.assert_equal(Settings.get_syncthing_port(), 8384, "corrupt persisted port → default")
end


-- ----------------------------------------------------------------------------
-- Syncthing scheme: default http; only the exact string "https" upgrades.
-- ----------------------------------------------------------------------------


do
    with_backend()
    h.assert_equal(Settings.get_syncthing_scheme(), "http", "default scheme http")

    Settings.set_syncthing_scheme("https")
    h.assert_equal(Settings.get_syncthing_scheme(), "https", "https roundtrips")

    Settings.set_syncthing_scheme("ftp")
    h.assert_equal(Settings.get_syncthing_scheme(), "http",
        "unknown scheme normalises to http")
end


-- ----------------------------------------------------------------------------
-- Syncthing folder_id: empty / non-string is stored as "" (no folder chosen).
-- ----------------------------------------------------------------------------


do
    with_backend()
    h.assert_equal(Settings.get_syncthing_folder_id(), "",
        "default folder_id is empty (no folder chosen)")

    Settings.set_syncthing_folder_id("my-books")
    h.assert_equal(Settings.get_syncthing_folder_id(), "my-books",
        "real folder_id roundtrips")

    Settings.set_syncthing_folder_id("")
    h.assert_equal(Settings.get_syncthing_folder_id(), "",
        "empty string stays empty")

    Settings.set_syncthing_folder_id(nil)
    h.assert_equal(Settings.get_syncthing_folder_id(), "",
        "nil stays empty")
end


-- ----------------------------------------------------------------------------
-- Syncthing API key: any string roundtrips; non-strings become "".
-- ----------------------------------------------------------------------------


do
    with_backend()
    h.assert_equal(Settings.get_syncthing_api_key(), "", "default api_key is empty")

    Settings.set_syncthing_api_key("abc123XYZ")
    h.assert_equal(Settings.get_syncthing_api_key(), "abc123XYZ",
        "api_key roundtrips")

    Settings.set_syncthing_api_key(42)
    h.assert_equal(Settings.get_syncthing_api_key(), "",
        "non-string api_key coerces to empty")
end


-- ----------------------------------------------------------------------------
-- Syncthing folder: single record roundtrips; nil/non-table clears.
-- ----------------------------------------------------------------------------


do
    with_backend()
    h.assert_nil(Settings.get_syncthing_folder(), "default folder is nil")

    Settings.set_syncthing_folder({ folder_id = "f1", path = "/p1" })
    local f = Settings.get_syncthing_folder()
    h.assert_true(type(f) == "table", "folder record roundtrips")
    h.assert_equal(f.folder_id, "f1", "folder_id preserved")
    h.assert_equal(f.path, "/p1", "folder path preserved")

    Settings.set_syncthing_folder("not a table")
    h.assert_nil(Settings.get_syncthing_folder(),
        "non-table folder is cleared (set to nil)")
end
















-- ----------------------------------------------------------------------------
-- Cloud server: persists a table directly, not a JSON-encoded string.
-- ----------------------------------------------------------------------------


do
    with_backend()
    h.assert_nil(Settings.get_cloud_server(), "no server by default")
    h.assert_false(Settings.is_cloud_configured(), "not configured by default")

    local server = { type = "dropbox", url = "https://api.dropboxapi.com" }
    local ok = Settings.set_cloud_server(server)
    h.assert_true(ok, "set_cloud_server returned true")

    local got = Settings.get_cloud_server()
    h.assert_true(type(got) == "table", "round-trip returns a table")
    h.assert_equal(got.type, "dropbox", "server.type preserved")
    h.assert_equal(got.url,  "https://api.dropboxapi.com",
        "server.url preserved")

    h.assert_true(Settings.is_cloud_configured(),
        "configured once a valid server table is set")

    local desc = Settings.describe_cloud_server()
    h.assert_equal(desc, "dropbox — https://api.dropboxapi.com",
        "describe combines kind and where")
end


-- ----------------------------------------------------------------------------
-- Option A lock (PROJECT_PLAN.md 18.9.5 / 18.12.15): the captured server is a
-- FULL SNAPSHOT including credentials, not a stripped reference. The native
-- picker hands back a self-contained copy (upstream shape: dropbox is
-- {name,password,address,url,type}); set/get must preserve EVERY field so the
-- copy can sync without the shared cs_servers list (immune to the old app's
-- removal). This pins that we store the snapshot, not a subset.
-- ----------------------------------------------------------------------------


do
    with_backend()
    -- The real upstream Dropbox server shape (verified 18.10), credentials
    -- included. password is the refresh token; address is the app key.
    local full = {
        name     = "My Dropbox",
        type     = "dropbox",
        password = "refresh-token-xyz",
        address  = "app-key-123",
        url      = "/Apps/KOReader",
    }
    h.assert_true(Settings.set_cloud_server(full), "set full server ok")
    local got = Settings.get_cloud_server()
    h.assert_equal(got.name,     "My Dropbox",        "name preserved")
    h.assert_equal(got.type,     "dropbox",            "type preserved")
    h.assert_equal(got.password, "refresh-token-xyz",  "credential (refresh token) preserved — snapshot, not stripped")
    h.assert_equal(got.address,  "app-key-123",        "address (app key) preserved")
    h.assert_equal(got.url,      "/Apps/KOReader",     "url preserved")

    -- A WebDAV snapshot likewise keeps username + password.
    local wd = {
        name = "NAS", type = "webdav", username = "reader",
        password = "wd-pass", address = "https://nas.local", url = "/books",
    }
    h.assert_true(Settings.set_cloud_server(wd), "set webdav server ok")
    local gw = Settings.get_cloud_server()
    h.assert_equal(gw.username, "reader",  "webdav username preserved")
    h.assert_equal(gw.password, "wd-pass", "webdav password preserved (snapshot)")
end


-- ----------------------------------------------------------------------------
-- Cloud: non-table set is rejected; clear empties the value.
-- ----------------------------------------------------------------------------


do
    with_backend()
    local ok = Settings.set_cloud_server("not a table")
    h.assert_false(ok, "set_cloud_server rejects non-table")
    h.assert_nil(Settings.get_cloud_server(), "rejected write didn't persist")

    Settings.set_cloud_server({ type = "webdav", address = "https://wd.example" })
    h.assert_true(Settings.is_cloud_configured(), "configured after set")
    h.assert_equal(Settings.describe_cloud_server(),
        "webdav — https://wd.example",
        "describe with address (not url) still works")

    Settings.clear_cloud_server()
    h.assert_nil(Settings.get_cloud_server(), "cleared")
    h.assert_false(Settings.is_cloud_configured(), "not configured after clear")
end


-- ----------------------------------------------------------------------------
-- describe_cloud_server returns nil when no server is set.
-- ----------------------------------------------------------------------------


do
    with_backend()
    h.assert_nil(Settings.describe_cloud_server(),
        "describe returns nil with no server")

    -- Just the kind, no where: returns the kind alone.
    Settings.set_cloud_server({ type = "ftp" })
    h.assert_equal(Settings.describe_cloud_server(), "ftp",
        "describe with no where returns kind alone")
end


-- ----------------------------------------------------------------------------
-- is_cloud_configured needs a url OR address (not just a type).
-- ----------------------------------------------------------------------------


do
    with_backend()
    Settings.set_cloud_server({ type = "dropbox" })
    -- Only `type` is set; legacy `Cloud.isConfigured` required url or
    -- address.  Match that — a server descriptor without an endpoint
    -- isn't actually usable for upload.
    h.assert_false(Settings.is_cloud_configured(),
        "type alone is not configured")
end


-- ----------------------------------------------------------------------------
-- Listeners fire after writes, scoped by transport id.
-- ----------------------------------------------------------------------------


do
    with_backend()

    local syncthing_hits, cloud_hits, all_hits = 0, 0, 0
    local unsub_s = Settings.on_change("syncthing", function() syncthing_hits = syncthing_hits + 1 end)
    local unsub_c = Settings.on_change("cloud",     function() cloud_hits     = cloud_hits     + 1 end)
    local unsub_all = Settings.on_change("*",       function() all_hits       = all_hits       + 1 end)

    Settings.set_syncthing_api_key("k1")
    h.assert_equal(syncthing_hits, 1, "syncthing listener fired once")
    h.assert_equal(cloud_hits,     0, "cloud listener did NOT fire on syncthing write")
    h.assert_equal(all_hits,       1, "wildcard listener fired once")

    Settings.clear_cloud_server()
    h.assert_equal(syncthing_hits, 1, "syncthing listener still 1")
    h.assert_equal(cloud_hits,     1, "cloud listener fired")
    h.assert_equal(all_hits,       2, "wildcard listener fired again")

    unsub_s()
    Settings.set_syncthing_api_key("k2")
    h.assert_equal(syncthing_hits, 1,
        "unsubscribed syncthing listener does not fire")
    h.assert_equal(all_hits,       3,
        "but the wildcard listener still fires")

    unsub_c(); unsub_all()
end


-- ----------------------------------------------------------------------------
-- Listener errors do NOT prevent other listeners from firing, nor block
-- the write from completing.  Same "no listener can break the system"
-- stance as syncery_storage_mode.
-- ----------------------------------------------------------------------------


do
    with_backend()
    local quiet_fired = false
    Settings.on_change("*", function() error("boom") end)
    Settings.on_change("*", function() quiet_fired = true end)

    Settings.set_syncthing_api_key("k-after-crash")
    h.assert_true(quiet_fired,
        "second listener fires even when the first raised")
    h.assert_equal(Settings.get_syncthing_api_key(), "k-after-crash",
        "write completed despite the listener crash")
end


-- ----------------------------------------------------------------------------
-- _reset_for_tests clears listeners (so a re-run doesn't leak the
-- listeners registered above into the next case).
-- ----------------------------------------------------------------------------


do
    Settings._reset_for_tests()
    Settings._set_backend(make_backend())

    local fired = false
    Settings.set_syncthing_api_key("k-no-listener")
    h.assert_false(fired,
        "no listener attached after reset, so no spurious fire")
end


-- ----------------------------------------------------------------------------
-- After reset, backend reverts to _G.G_reader_settings (which is nil
-- in this spec environment) and writes/reads no-op gracefully.
-- ----------------------------------------------------------------------------


do
    Settings._reset_for_tests()
    -- _set_backend(nil) clears injection; without an injected backend
    -- _G.G_reader_settings is consulted, which is nil in our test env.
    h.assert_equal(Settings.get_syncthing_url(), "http://127.0.0.1:8384",
        "no backend → computed default URL returned")

    -- Writes don't raise when there's no backend.  They no-op silently
    -- — the legacy modules behaved the same way under the same
    -- conditions (every G_reader_settings call was guarded `if ... then`).
    local ok, err = pcall(Settings.set_syncthing_api_key, "anything")
    h.assert_true(ok, "write with no backend doesn't raise (" .. tostring(err) .. ")")
end
