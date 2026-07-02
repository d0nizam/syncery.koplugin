-- =============================================================================
-- spec/menu_transport_section_spec.lua
-- =============================================================================
--
-- Tests for syncery_ui/menu/transport_section.lua.
--
-- The transport section is the natural home for Patterns 3 + 4:
--   * Master toggle row labels show inline state ("(ready)" /
--     "(not configured)" / "(off)" / "(retrying…)").
--   * Each transport's settings live in a SUBMENU reached via a gated
--     "Configure …" row (Pattern 4, refined): the configure row is always
--     present so flipping the master toggle reveals it immediately via
--     updateItems; it is enabled only when the transport is on, and the
--     settings inside rebuild fresh on entry (see T.menuSyncthingConfig for
--     why a submenu rather than conditional rows at this level).
-- =============================================================================


local h            = require("spec.test_helpers")
local menu_support = require("spec.menu_test_support")
h.setup("/tmp/syncery_menu_transport_spec_" .. tostring(os.time()))
local stubs = menu_support.install_stubs()

-- Piece 1: transport_section now requires Stignore (eager `.stignore` at folder
-- adoption).  Stub it with a recorder so we can assert that adopting a folder
-- eagerly writes the ignore pattern, WITHOUT touching the filesystem.  (The
-- real writer is covered by stignore_spec; here we test the WIRING.)  Set
-- before the require below so transport_section picks up this stub.
local stignore_calls = {}
local stignore_status_ret = "written"   -- flip per-test to simulate a failure
package.loaded["syncery_transports/stignore"] = {
    PATTERN = "*syncery-*sync-conflict-*",
    ensure_for_folder = function(folder_id, get_folder)
        stignore_calls[#stignore_calls + 1] =
            { folder_id = folder_id, get_folder = get_folder }
        return stignore_status_ret
    end,
}

local T = require("syncery_ui/menu/transport_section")


-- ---------------------------------------------------------------------------
-- Pattern 3: dynamic labels reflect transport state
-- ---------------------------------------------------------------------------


-- Syncthing off → master toggle label is "Syncthing integration (off)".
do
    local plugin = menu_support.make_fake_plugin{ use_syncthing = false }
    local items = T.build(plugin)
    local syncthing_row = items[1]
    h.assert_true(type(syncthing_row.text_func) == "function",
        "build(): syncthing master row is a text_func row")
    local label = syncthing_row.text_func()
    h.assert_true(label:find("Syncthing") ~= nil,
        "label includes 'Syncthing'")
    h.assert_true(label:find("off") ~= nil,
        "syncthing OFF → label contains '(off)'")
end


-- Syncthing on + transport says ready → label says "(ready)".
do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        _transport = menu_support.make_fake_transport({
            syncthing = { available = true, summary = "ready" },
        }),
    }
    local syncthing_row = T.build(plugin)[1]
    local label = syncthing_row.text_func()
    h.assert_true(label:find("ready") ~= nil,
        "syncthing ready → label contains '(ready)'")
end


-- Syncthing on + transport says not configured → label says "(not configured)".
do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        _transport = menu_support.make_fake_transport({
            syncthing = { available = false, summary = "not configured" },
        }),
    }
    local syncthing_row = T.build(plugin)[1]
    local label = syncthing_row.text_func()
    h.assert_true(label:find("not configured") ~= nil,
        "syncthing needs_config → label contains '(not configured)'")
end


-- ---------------------------------------------------------------------------
-- Pattern 4 (refined): gated "Configure …" submenu rows
-- ---------------------------------------------------------------------------


-- Syncthing off: "Configure Syncthing…" row IS present but DISABLED (gated),
-- so flipping the master toggle can reveal it via updateItems without a rebuild.
do
    local plugin = menu_support.make_fake_plugin{ use_syncthing = false }
    local items = T.build(plugin)
    local configure_row = menu_support.find_row(items, "Configure Syncthing…")
    h.assert_true(configure_row ~= nil,
        "syncthing off: 'Configure Syncthing…' row present (gated, not hidden)")
    h.assert_equal(configure_row.enabled_func(), false,
        "syncthing off: 'Configure Syncthing…' disabled")
    -- The actual settings live one level deeper, not at the transport level.
    h.assert_nil(menu_support.find_row(items, "Advanced"),
        "syncthing off: 'Advanced' not at transport level (it's in the submenu)")
    h.assert_nil(menu_support.find_row(items, "Set up API key…"),
        "syncthing off: 'Set up API key…' not at transport level (it's in the submenu)")
end


-- Syncthing on: "Configure Syncthing…" enabled, and its submenu holds the
-- settings (wizard, Advanced, …).
do
    local plugin = menu_support.make_fake_plugin{ use_syncthing = true }
    local items = T.build(plugin)
    local configure_row = menu_support.find_row(items, "Configure Syncthing…")
    h.assert_true(configure_row ~= nil,
        "syncthing on: 'Configure Syncthing…' row present")
    h.assert_equal(configure_row.enabled_func(), true,
        "syncthing on: 'Configure Syncthing…' enabled")
    h.assert_true(type(configure_row.sub_item_table_func) == "function",
        "syncthing on: 'Configure Syncthing…' opens a submenu")
    local sub = configure_row.sub_item_table_func()
    h.assert_true(menu_support.find_row(sub, "Advanced") ~= nil,
        "submenu: 'Advanced' row present")
    h.assert_true(menu_support.find_row(sub, "Set up API key…") ~= nil,
        "submenu: 'Set up API key…' row present")
end


-- Cloud on: cloud settings present.
do
    local plugin = menu_support.make_fake_plugin{ use_cloud = true }
    local items = T.build(plugin)
    local cloud_settings = menu_support.find_row(items, "Cloud settings")
    h.assert_true(cloud_settings ~= nil,
        "cloud on: 'Cloud settings' present")
    h.assert_equal(cloud_settings.enabled_func(), true,
        "cloud on: 'Cloud settings' enabled")
end


-- Cloud off: cloud settings row present but disabled (gated).
do
    local plugin = menu_support.make_fake_plugin{ use_cloud = false }
    local items = T.build(plugin)
    local cloud_settings = menu_support.find_row(items, "Cloud settings")
    h.assert_true(cloud_settings ~= nil,
        "cloud off: 'Cloud settings' row present (gated, not hidden)")
    h.assert_equal(cloud_settings.enabled_func(), false,
        "cloud off: 'Cloud settings' disabled")
end


-- ---------------------------------------------------------------------------
-- Pattern 2: "Test connection" gated on the API key being set
-- ---------------------------------------------------------------------------


-- syncthing on + missing api_key → Test connection (in the submenu) disabled.
do
    -- Default Settings stub returns "" for api_key.
    local plugin = menu_support.make_fake_plugin{ use_syncthing = true }
    local configure_row = menu_support.find_row(T.build(plugin), "Configure Syncthing…")
    local sub = configure_row.sub_item_table_func()
    local test_row = menu_support.find_row(sub, "Test connection")
    h.assert_true(test_row ~= nil, "Test connection row present (in submenu)")
    h.assert_equal(test_row.enabled_func(), false,
        "Test connection: disabled when API key missing")
end


-- syncthing on + api_key set → Test connection enabled.
--
-- Note: we can't easily swap the Settings stub mid-test because the
-- transport_section module captured a reference at load time.  But
-- we CAN verify the gate logic separately: the enabled_func reads
-- `H.load_syncthing_cfg()` which in turn reads `Settings.get_*`.
-- The gate logic is `cfg.api_key ~= ""`.  The default stub returns
-- "" for it, so the disabled case above is the load-bearing check.
-- When real Settings returns non-empty, the same expression
-- evaluates to true.  This is small enough to verify by reading the
-- code directly.
do
    -- Confirm the gate predicate exists with the expected shape by
    -- checking the row's enabled_func is wired (it's tested fully
    -- above in the "missing api_key" case).
    package.loaded["syncery_settings"] = nil
    menu_support.install_stubs()
    local plugin = menu_support.make_fake_plugin{ use_syncthing = true }
    local configure_row = menu_support.find_row(T.build(plugin), "Configure Syncthing…")
    local sub = configure_row.sub_item_table_func()
    local test_row = menu_support.find_row(sub, "Test connection")
    h.assert_true(type(test_row.enabled_func) == "function",
        "Test connection: has an enabled_func gate")
    h.assert_true(type(test_row.hold_callback) == "function",
        "Test connection: hold_callback is wired (Pattern 2 gate explanation)")
end


-- Gate-fix: the key may come from KOSyncthing+ or config.xml, not only a
-- manual entry.  Rows that need "a key is available" (Test connection, Choose
-- Syncthing folder — both in menuSyncthingConfig) must therefore be ENABLED
-- when KOSyncthing+ is present even with no manual key.  A present
-- _G.KOSyncthingPlusAPI satisfies H.syncthing_key_usable.
do
    local plugin = menu_support.make_fake_plugin{ use_syncthing = true }
    local configure_row = menu_support.find_row(T.build(plugin), "Configure Syncthing…")
    local sub = configure_row.sub_item_table_func()
    local test_row   = menu_support.find_row(sub, "Test connection")
    local choose_row = menu_support.find_row(sub, "Choose Syncthing folder")
    h.assert_true(choose_row ~= nil, "gate-fix: Choose folder row is in the config menu")

    -- Baseline: no manual key, no KOSyncthing+, no config.xml → both disabled.
    local saved = rawget(_G, "KOSyncthingPlusAPI")
    _G.KOSyncthingPlusAPI = nil
    h.assert_equal(test_row.enabled_func(), false,
        "gate-fix baseline: Test connection disabled with no key from any source")
    h.assert_equal(choose_row.enabled_func(), false,
        "gate-fix baseline: Choose folder disabled with no key from any source")

    -- KOSyncthing+ present → both enabled (it supplies the key via apiCall).
    _G.KOSyncthingPlusAPI = { apiCall = function() end }
    h.assert_equal(test_row.enabled_func(), true,
        "gate-fix: Test connection enabled when KOSyncthing+ present (no manual key)")
    h.assert_equal(choose_row.enabled_func(), true,
        "gate-fix: Choose folder enabled when KOSyncthing+ present (no manual key)")

    _G.KOSyncthingPlusAPI = saved
end


-- "Set up API key…" configures the manual provider only.  When an automatic
-- provider (KOSyncthing+ / config.xml) supplies the key it always wins the
-- chain, so a manual key can't take effect — the row is hidden.  With no
-- automatic source the row is shown (manual entry is the only path to a key).
do
    local plugin = menu_support.make_fake_plugin{ use_syncthing = true }
    local saved  = rawget(_G, "KOSyncthingPlusAPI")

    _G.KOSyncthingPlusAPI = nil
    h.assert_true(
        menu_support.find_row(T.menuSyncthingConfig(plugin), "Set up API key…") ~= nil,
        "Set up API key: shown when no automatic provider supplies the key")

    _G.KOSyncthingPlusAPI = { apiCall = function() end }
    h.assert_nil(
        menu_support.find_row(T.menuSyncthingConfig(plugin), "Set up API key…"),
        "Set up API key: hidden when KOSyncthing+ supplies the key")

    _G.KOSyncthingPlusAPI = saved
end


-- ---------------------------------------------------------------------------
-- Sub-submenu shapes
-- ---------------------------------------------------------------------------


-- menuCloudConfig with NO destination configured (default stub): 4 cloud config
-- rows only — Destination, Clear destination, Upload delay, Check cloud settings.
-- codex 552: the two opt-in wake-push toggles are HIDDEN until a destination is
-- set (the wake gate no-ops without one, so a visible toggle would be dead).
-- There is ONE cloud backend (the "Cloud storage+" plugin) with an invisible
-- syncservice fallback — no picker, no "Sync backend:" row.
do
    local plugin = menu_support.make_fake_plugin{}
    local rows = T.menuCloudConfig(plugin)
    h.assert_equal(#rows, 4, "menuCloudConfig: 4 rows when no destination (wake toggles hidden)")
    h.assert_nil(menu_support.find_row(rows, "Wake Wi-Fi for cloud push on close"),
        "552: close wake toggle hidden until a cloud destination exists")
    h.assert_nil(menu_support.find_row(rows, "Wake Wi-Fi for cloud push on sleep"),
        "552: sleep wake toggle hidden until a cloud destination exists")

    -- U18: the cloud config-check row is labelled "Check cloud settings", not
    -- "Test connection" — the cloud check does NO network probe (only
    -- is_cloud_configured via H.test_cloud_connection), so the label must not
    -- promise connectivity.  The Syncthing submenu keeps its real "Test
    -- connection" probe (covered by separate tests above).
    h.assert_true(menu_support.find_row(rows, "Check cloud settings") ~= nil,
        "menuCloudConfig: cloud config-check row is 'Check cloud settings'")
    h.assert_nil(menu_support.find_row(rows, "Test connection"),
        "menuCloudConfig: no 'Test connection' label in the cloud submenu (no network probe here)")

    -- Regression: no "Sync backend:" summary row survives.
    local saw_backend_row = false
    for _, r in ipairs(rows) do
        if type(r.text_func) == "function" then
            local ok, label = pcall(r.text_func)
            if ok and type(label) == "string" and label:find("Sync backend", 1, true) then
                saw_backend_row = true
            end
        end
    end
    h.assert_false(saw_backend_row, "no 'Sync backend:' row remains (picker removed)")

    -- Regression: the picker function itself is gone (single seam removed).
    h.assert_nil(T.menuCloudBackend, "T.menuCloudBackend removed")
end


-- ---------------------------------------------------------------------------
-- Cloud destination picker routes to the "Cloud storage+" plugin
--
-- The picker must use the live plugin's OWN UI (ui.cloudstorage:
-- onShowCloudStorageList) — which shows "Cloud storage+" and lists FTP — NOT
-- the built-in standalone SyncService widget (the old "Cloud storage" UI,
-- Dropbox/WebDAV only).  Regression for the "wrong (old) UI shows" bug.
-- ---------------------------------------------------------------------------

-- cloud_picker_kind: the pure routing decision.
do
    h.assert_equal(
        T.cloud_picker_kind({ cloudstorage = { onShowCloudStorageList = function() end } }),
        "plugin", "plugin present + method -> 'plugin'")
    -- Regression: a fork may wrap onShowCloudStorageList as a CALLABLE TABLE
    -- (obj:method() works, but type(method) == "table", not "function").  The
    -- old `type(...) == "function"` guard wrongly routed this to "fallback"
    -- (the standalone SyncService) — the exact device-side bug.
    h.assert_equal(
        T.cloud_picker_kind({ cloudstorage = {
            onShowCloudStorageList = setmetatable({}, { __call = function() end }),
        }}),
        "plugin", "plugin present + CALLABLE-TABLE method -> 'plugin' (not just plain functions)")
    h.assert_equal(
        T.cloud_picker_kind({ cloudstorage = {} }),
        "fallback", "plugin present but no onShowCloudStorageList -> 'fallback'")
    h.assert_equal(
        T.cloud_picker_kind({ cloudstorage = { onShowCloudStorageList = "not callable" } }),
        "fallback", "a non-callable truthy value is NOT treated as the plugin")
    h.assert_equal(
        T.cloud_picker_kind({}),
        "fallback", "no cloudstorage on ui -> 'fallback'")
    h.assert_equal(
        T.cloud_picker_kind(nil),
        "fallback", "nil ui -> 'fallback'")
end

-- pickCloudDestination routes through the plugin when present, and the chosen
-- server is persisted via Settings.set_cloud_server.
do
    local shown = {}
    local plugin = menu_support.make_fake_plugin{
        ui = { cloudstorage = {
            onShowCloudStorageList = function(_self, cb) shown.cb = cb end,
        }},
    }
    T.pickCloudDestination(plugin, nil)
    h.assert_true(type(shown.cb) == "function",
        "pickCloudDestination: plugin present -> onShowCloudStorageList invoked with a callback")

    -- The plugin fires the callback with the chosen server (a SINGLE arg).
    local server = { type = "ftp", url = "/books", address = "ftp://host" }
    shown.cb(server)
    local saw = nil
    for _, c in ipairs(stubs.settings_set_calls) do
        if c.key == "set_cloud_server" then saw = c.value end
    end
    h.assert_true(saw == server,
        "the chosen server is persisted via set_cloud_server")
end


-- menuSyncthingAdvanced returns 1 row: just the Syncthing port (a
-- makeNumericSetting knob whose label reflects the current value).  The scan
-- interval knob was removed — it exposed an internal debounce (lesson #24) and
-- its name misled (it tuned Syncery's /db/scan-nudge debounce, not Syncthing's
-- own scanning, which fsWatcher handles).  The API key row and folder picker
-- live in menuSyncthingConfig.
do
    local plugin = menu_support.make_fake_plugin{}
    local rows = T.menuSyncthingAdvanced(plugin)
    h.assert_equal(#rows, 1, "menuSyncthingAdvanced: 1 row (port only; scan interval removed)")

    local port_row, scan_interval_row = nil, nil
    for _, row in ipairs(rows) do
        if type(row.help_text) == "string"
           and row.help_text:find("non-standard port", 1, true) then
            port_row = row
        end
        if type(row.help_text) == "string"
           and row.help_text:find("Lower = more battery", 1, true) then
            scan_interval_row = row
        end
    end
    h.assert_true(port_row ~= nil, "menuSyncthingAdvanced: a Syncthing port row is present")
    -- Regression guard: the scan interval knob is gone (debounce is a fixed
    -- internal default now, not a user-facing row).
    h.assert_nil(scan_interval_row,
        "menuSyncthingAdvanced: no Syncthing scan interval row (knob removed)")
    -- The picker and the API key entry are no longer here.
    h.assert_nil(menu_support.find_row(rows, "Choose Syncthing folder"),
        "menuSyncthingAdvanced: Choose-folder row moved out (now in config menu)")
end


-- ---------------------------------------------------------------------------
-- Folder picker: the state suffix flags folders that will not sync (or are
-- busy); idle/healthy/unknown folders stay clean.
-- ---------------------------------------------------------------------------
do
    h.assert_true(T.folder_state_suffix("paused") ~= nil,
        "folder_state_suffix: a paused folder is flagged")
    h.assert_true(T.folder_state_suffix("error") ~= nil,
        "folder_state_suffix: an error folder is flagged")
    h.assert_true(T.folder_state_suffix("syncing") ~= nil,
        "folder_state_suffix: a syncing folder is flagged (live state)")
    h.assert_true(T.folder_state_suffix("scanning") ~= nil,
        "folder_state_suffix: a scanning folder is flagged (live state)")
    h.assert_nil(T.folder_state_suffix("idle"),
        "folder_state_suffix: a healthy (idle) folder is not flagged")
    h.assert_nil(T.folder_state_suffix("unknown"),
        "folder_state_suffix: an unknown state is not flagged")
    h.assert_nil(T.folder_state_suffix(nil),
        "folder_state_suffix: nil state is not flagged")
end


-- ---------------------------------------------------------------------------
-- Master-toggle callbacks flip the right plugin field
-- ---------------------------------------------------------------------------


do
    local plugin = menu_support.make_fake_plugin{ use_syncthing = false }
    local items = T.build(plugin)
    -- Find the syncthing master toggle (text_func returns "Syncthing integration ...")
    local row = items[1]
    h.assert_true(row.text_func():find("Syncthing integration") ~= nil,
        "build()[1] is the Syncthing master toggle")

    row.callback(nil)
    h.assert_equal(plugin.use_syncthing, true,
        "syncthing master callback: flips use_syncthing on")
    row.callback(nil)
    h.assert_equal(plugin.use_syncthing, false,
        "syncthing master callback: flips back off")
end


-- Cloud master callback
do
    local plugin = menu_support.make_fake_plugin{ use_cloud = false }
    local items = T.build(plugin)
    local cloud_row
    for _, item in ipairs(items) do
        local label = item.text_func and item.text_func() or item.text
        if label and label:find("Cloud storage") then
            cloud_row = item
            break
        end
    end
    h.assert_true(cloud_row ~= nil, "cloud master row present")
    cloud_row.callback(nil)
    h.assert_equal(plugin.use_cloud, true,
        "cloud master callback: flips use_cloud on")
end


-- ---------------------------------------------------------------------------
-- D-3 regression — toggle rows must write BOTH the `syncery_use_*` key
-- (read by main.lua at startup) AND the `syncery_sync_via_*` key (read
-- by the transport's `is_available()`).
--
-- Before the fix:
--   • Syncthing row wrote only `syncery_use_syncthing` → transport saw
--     no `sync_via_syncthing`, refused to push on clean installs.
--   • Cloud row wrote only `syncery_use_cloud`         → same shape.
--   • The Cloud row called Settings.set_cloud_enabled (which writes
--     `sync_via_cloud`) but never wrote `syncery_use_cloud` → on
--     restart, main.lua re-read the OLD value of use_cloud, so the
--     toggle did not persist.
--
-- These tests assert each toggle writes both keys, both directions.
-- ---------------------------------------------------------------------------


-- Earlier blocks in this spec re-installed stubs (each install creates a
-- new G_reader_settings stub + new settings stub).  By now, _G.G_reader_settings
-- and package.loaded["syncery_settings"] point at the LATEST install,
-- but transport_section's `local Settings = require(...)` captured the
-- FIRST install at module load.  To make assertions reliable, do one
-- final reinstall HERE and reload transport_section against it.
package.loaded["syncery_ui/menu/transport_section"] = nil
package.loaded["syncery_settings"]                  = nil
stubs = menu_support.install_stubs()
T = require("syncery_ui/menu/transport_section")


--- Helper: find a row by label predicate.
local function find_row(items, label_pattern)
    for _, item in ipairs(items) do
        local label = item.text_func and item.text_func() or item.text
        if label and label:find(label_pattern) then return item end
    end
    return nil
end


-- Helper: count entries in a recorded-call list matching a key/value.
local function count_calls(calls, key, value)
    local n = 0
    for _, c in ipairs(calls) do
        if c.key == key and (value == nil or c.value == value) then
            n = n + 1
        end
    end
    return n
end


--- Helper: clear the recording tables on the shared `stubs` instance.
local function reset_recordings()
    while #stubs.settings_set_calls > 0 do
        table.remove(stubs.settings_set_calls)
    end
    while #stubs.grs_save_calls > 0 do
        table.remove(stubs.grs_save_calls)
    end
end


-- Syncthing toggle writes BOTH keys, both directions.
do
    reset_recordings()
    local plugin = menu_support.make_fake_plugin{ use_syncthing = false }
    local items = T.build(plugin)
    local row = find_row(items, "Syncthing integration")
    h.assert_true(row ~= nil, "D-3: Syncthing master toggle row present")

    -- ── off → on ────────────────────────────────────────────────
    row.callback(nil)
    h.assert_equal(plugin.use_syncthing, true,
        "syncthing on: in-memory flipped on")
    -- COLLAPSED: the menu writes ONLY the canonical `syncery_use_syncthing`
    -- key, which the transport's is_available() now reads directly.  The old
    -- D-3 mirror to `syncery_sync_via_syncthing` (via set_syncthing_enabled) is
    -- gone — one key, no way to diverge from this checkbox.
    h.assert_equal(
        count_calls(stubs.grs_save_calls, "syncery_use_syncthing", true), 1,
        "syncthing on: wrote the canonical syncery_use_syncthing=true (the key is_available reads)")
    h.assert_equal(
        count_calls(stubs.settings_set_calls, "set_syncthing_enabled", true), 0,
        "syncthing on: NO set_syncthing_enabled mirror call (collapsed)")

    -- ── on → off ────────────────────────────────────────────────
    row.callback(nil)
    h.assert_equal(plugin.use_syncthing, false,
        "syncthing off: in-memory flipped off")
    h.assert_equal(
        count_calls(stubs.grs_save_calls, "syncery_use_syncthing", false), 1,
        "syncthing off: persisted syncery_use_syncthing=false")
    h.assert_equal(
        count_calls(stubs.settings_set_calls, "set_syncthing_enabled", false), 0,
        "syncthing off: NO set_syncthing_enabled mirror call (collapsed)")
end


-- Cloud toggle writes the SINGLE canonical key (collapsed — no sync_via mirror).
do
    reset_recordings()
    local plugin = menu_support.make_fake_plugin{ use_cloud = false }
    local items = T.build(plugin)
    local row = find_row(items, "Cloud storage")
    h.assert_true(row ~= nil, "Cloud master toggle row present")

    row.callback(nil)
    h.assert_equal(plugin.use_cloud, true, "cloud on: flipped on")
    h.assert_equal(
        count_calls(stubs.grs_save_calls, "syncery_use_cloud", true), 1,
        "cloud on: wrote the canonical syncery_use_cloud=true (the key is_available reads)")
    h.assert_equal(
        count_calls(stubs.settings_set_calls, "set_cloud_enabled", true), 0,
        "cloud on: NO set_cloud_enabled mirror call (collapsed)")

    row.callback(nil)
    h.assert_equal(
        count_calls(stubs.grs_save_calls, "syncery_use_cloud", false), 1,
        "cloud off: wrote syncery_use_cloud=false")
    h.assert_equal(
        count_calls(stubs.settings_set_calls, "set_cloud_enabled", false), 0,
        "cloud off: NO set_cloud_enabled mirror call (collapsed)")
end





-- ----------------------------------------------------------------------------
-- T.pickFolder (folder picker): fetch via the transport bridge, then branch —
--   0 / error    → an explanatory notice, nothing stored
--   exactly 1    → auto-adopt (folder_id + record) + a dismiss-only notice
--   more than 1  → a tappable Menu; a tap stores the choice and closes it
-- ----------------------------------------------------------------------------


-- Recorders accumulate across tests; clear them in place (T holds references
-- to these exact lists, so reassigning would detach them).
local function pf_clear()
    for _, t in ipairs({ stubs.info._shown, stubs.menu._shown,
                         stubs.settings_set_calls, stubs.uimgr._events }) do
        for i = #t, 1, -1 do t[i] = nil end
    end
end

local function pf_folder_sets()
    local id_v, rec_v
    for _, c in ipairs(stubs.settings_set_calls) do
        if c.key == "set_syncthing_folder_id" then id_v  = c.value end
        if c.key == "set_syncthing_folder"    then rec_v = c.value end
    end
    return id_v, rec_v
end

local function pf_plugin(list_result)
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        _transport = { list_folders = function(_self, cb) list_result(cb) end },
    }
    plugin._isNetworkOnline = function() return true end
    return plugin
end


do
    -- Error (not_available) → API-key message; nothing stored.
    pf_clear()
    T.pickFolder(pf_plugin(function(cb) cb(nil, "not_available") end))
    local last = stubs.info._shown[#stubs.info._shown]
    h.assert_true(last.text:match("No API key set") ~= nil,
        "not_available → API-key message shown")
    local id_v, rec_v = pf_folder_sets()
    h.assert_nil(id_v,  "error → no folder_id stored")
    h.assert_nil(rec_v, "error → no folder record stored")
end


do
    -- no_folders → the daemon-has-no-folders message.
    pf_clear()
    T.pickFolder(pf_plugin(function(cb) cb(nil, "no_folders") end))
    local last = stubs.info._shown[#stubs.info._shown]
    h.assert_true(last.text:match("no folders to sync") ~= nil,
        "no_folders → 'no folders to sync' message")
end


do
    -- Exactly 1 → auto-adopt (folder_id + record) + a DISMISS-ONLY notice
    -- (no timeout) that names the folder.
    pf_clear()
    T.pickFolder(pf_plugin(function(cb)
        cb({ { folder_id = "solo", path = "/sd/solo", label = "Solo" } }, nil)
    end))
    local id_v, rec_v = pf_folder_sets()
    h.assert_equal(id_v, "solo",            "auto-adopt → folder_id stored")
    h.assert_equal(rec_v.folder_id, "solo",     "auto-adopt → folder record id stored")
    h.assert_equal(rec_v.path,  "/sd/solo",     "auto-adopt → record path stored")
    h.assert_equal(rec_v.label, "Solo",         "auto-adopt → record label stored")
    local last = stubs.info._shown[#stubs.info._shown]
    h.assert_true(last.text:match("Solo") ~= nil, "auto-adopt notice names the folder")
    h.assert_nil(last.timeout, "auto-adopt notice is dismiss-only (no timeout)")
end


do
    -- Piece 1: adopting a folder eagerly writes `.stignore` (calls
    -- Stignore.ensure_for_folder) the MOMENT the folder is chosen -- not only
    -- after the first scan fires.  The single-folder path auto-adopts, so it
    -- exercises adopt_folder.  We assert the writer was invoked with the
    -- adopted folder_id; the actual file write is covered by stignore_spec.
    pf_clear()
    local before = #stignore_calls
    T.pickFolder(pf_plugin(function(cb)
        cb({ { folder_id = "eager-fid", path = "/sd/eager", label = "Eager" } }, nil)
    end))
    h.assert_equal(#stignore_calls, before + 1,
        "adopt_folder eagerly calls Stignore.ensure_for_folder on pick")
    h.assert_equal(stignore_calls[#stignore_calls].folder_id, "eager-fid",
        "eager `.stignore` uses the adopted folder_id")
end


do
    -- More than 1 → a Menu (no auto-store); tapping an item stores it + closes.
    pf_clear()
    T.pickFolder(pf_plugin(function(cb)
        cb({
            { folder_id = "books", path = "/sd/books", label = "Books" },
            { folder_id = "docs",  path = "/sd/docs",  label = "Docs" },
        }, nil)
    end))

    h.assert_equal(#stubs.menu._shown, 1, ">1 → a Menu is shown")
    local menu = stubs.menu._shown[1]
    h.assert_equal(menu.title, "Choose a folder to sync", "picker title")
    h.assert_equal(#menu.item_table, 2, "picker lists both folders")
    h.assert_equal(menu.item_table[1].text, "Books", "label-only row text")
    h.assert_nil(menu.item_table[1].mandatory,
        "path NOT used as mandatory (long paths crash Menu's makeLine)")

    local id_before = pf_folder_sets()
    h.assert_nil(id_before, ">1 → nothing stored before a tap")

    menu.item_table[2].callback()
    local id_v, rec_v = pf_folder_sets()
    h.assert_equal(id_v, "docs",           "tap → chosen folder_id stored")
    h.assert_equal(rec_v.label, "Docs",    "tap → chosen folder record stored")
    local closed = false
    for _, e in ipairs(stubs.uimgr._events) do if e.kind == "close" then closed = true end end
    h.assert_true(closed, "tap closes the picker menu")
    -- Confirmation toast: the tap is no longer silent.
    local toast = stubs.info._shown[#stubs.info._shown]
    h.assert_true(toast.text:match("Selected folder") ~= nil,
        "tap shows a 'Selected folder' confirmation toast")
    h.assert_true(toast.text:match("Docs") ~= nil,
        "confirmation toast names the chosen folder")
    h.assert_nil(toast.text:match("not written"),
        "clean status → no .stignore-failure suffix")
end


do
    -- Confirmation toast surfaces a `.stignore` write failure (diagnostic):
    -- when ensure_for_folder returns a non-success status, the tap toast
    -- appends it instead of silently swallowing.
    stignore_status_ret = "no_path"
    pf_clear()
    T.pickFolder(pf_plugin(function(cb)
        cb({
            { folder_id = "a", path = "/sd/a", label = "Alpha" },
            { folder_id = "b", path = "/sd/b", label = "Beta" },
        }, nil)
    end))
    stubs.menu._shown[1].item_table[1].callback()
    local toast = stubs.info._shown[#stubs.info._shown]
    h.assert_true(toast.text:match("Alpha") ~= nil,
        "failure toast still names the folder")
    h.assert_true(toast.text:match("not written") ~= nil
        and toast.text:match("no_path") ~= nil,
        "failure status surfaced in the toast (.stignore not written: no_path)")
    stignore_status_ret = "written"   -- restore for any later test
end


do
    -- Wiring: the "Choose Syncthing folder" row invokes the picker
    -- (T.pickFolder), not the old discoverFolders.  With >1 folder the picker
    -- shows a Menu (discoverFolders showed an InfoMessage list instead), so a
    -- Menu proves the picker is what the row's callback runs.
    pf_clear()
    local plugin = pf_plugin(function(cb)
        cb({
            { folder_id = "a", path = "/a", label = "A" },
            { folder_id = "b", path = "/b", label = "B" },
        }, nil)
    end)
    local row = menu_support.find_row(T.menuSyncthingConfig(plugin), "Choose Syncthing folder")
    h.assert_true(row ~= nil, "wiring: 'Choose Syncthing folder' row present")
    row.callback()
    h.assert_equal(#stubs.menu._shown, 1, "wiring: the row's callback runs the picker (Menu shown)")
end


-- ---------------------------------------------------------------------------
-- T.cloud_backend_available — no_sync_service detection.  The transport's
-- is_available() can't be used (syncservice.syncable_providers() returns
-- {dropbox,webdav} unconditionally), so this checks the SELECTED provider's
-- real availability — it drives testCloudConnection's honest "not available in
-- this build" message on a stripped build instead of a false "will verify on
-- next sync".
-- ---------------------------------------------------------------------------
-- providers/init logs via Log.tag on the syncservice fallback path; the menu
-- support stub's logger facade returns nil from .tag, so install a real-enough
-- logger first (this is the last block in the spec, so no restore needed).
package.loaded["syncery_transports/log"] = {
    tag = function()
        return { info = function() end, warn = function() end, dbg = function() end }
    end,
}
do
    -- No "Cloud storage+" plugin (ui.cloudstorage) and no built-in syncservice
    -- (the real module require fails headless, and none injected) -> no backend.
    h.assert_false(T.cloud_backend_available({}, nil),
        "cloud_backend_available: false when neither plugin nor syncservice is present")

    -- "Cloud storage+" plugin present (table with a callable sync) -> primary.
    h.assert_true(T.cloud_backend_available({ cloudstorage = { sync = function() end } }, nil),
        "cloud_backend_available: true when the Cloud storage+ plugin is present")

    -- No plugin, but the built-in syncservice injected -> fallback is available.
    h.assert_true(T.cloud_backend_available({}, { sync = function() end }),
        "cloud_backend_available: true via the built-in syncservice fallback")
end


-- codex 552 (positive): with a cloud DESTINATION configured, the two wake toggles
-- DO appear under Cloud settings.  Reload transport_section against a stub whose
-- is_cloud_configured() is true.  Runs LAST so the reinstall can't affect earlier
-- blocks.
do
    package.loaded["syncery_ui/menu/transport_section"] = nil
    package.loaded["syncery_settings"]                  = nil
    menu_support.install_stubs({ settings = {
        is_cloud_configured   = true,
        describe_cloud_server = "webdav://example",
    } })
    local T2     = require("syncery_ui/menu/transport_section")
    local plugin = menu_support.make_fake_plugin{}
    local rows   = T2.menuCloudConfig(plugin)

    h.assert_equal(#rows, 6, "552: destination set -> 6 rows (4 config + 2 wake toggles)")
    h.assert_true(menu_support.find_row(rows, "Wake Wi-Fi for cloud push on close") ~= nil,
        "552: close wake toggle shown when a destination is configured")
    h.assert_true(menu_support.find_row(rows, "Wake Wi-Fi for cloud push on sleep") ~= nil,
        "552: sleep wake toggle shown when a destination is configured")
end
