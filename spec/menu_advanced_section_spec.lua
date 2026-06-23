-- =============================================================================
-- spec/menu_advanced_section_spec.lua
-- =============================================================================
--
-- Tests for syncery_ui/menu/advanced_section.lua.
--
-- Two clusters live here:
--   1. Deep clean \xe2\x80\x94 gated on doc + extra confirm-dialog friction.
--   2. Annotation engine options \xe2\x80\x94 two opt-in sub-toggles.  Phase 9
--      retired the `use_new_sync_engine` master switch, so these are
--      now plain unconditional rows.
-- =============================================================================


local h            = require("spec.test_helpers")
local menu_support = require("spec.menu_test_support")
h.setup("/tmp/syncery_menu_adv_spec_" .. tostring(os.time()))
local stubs = menu_support.install_stubs()

local Adv = require("syncery_ui/menu/advanced_section")


-- ---------------------------------------------------------------------------
-- Deep clean \xe2\x80\x94 gated on doc, tap-shows-confirm
-- ---------------------------------------------------------------------------


-- No doc: disabled.
do
    local plugin = menu_support.make_fake_plugin{ ui = nil }
    local row = Adv.deep_clean(plugin)
    h.assert_equal(row.enabled_func(), false,
        "no doc: deep clean disabled")
end


-- Doc open: enabled, tap shows ConfirmBox.
do
    while #stubs.confirm._shown > 0 do table.remove(stubs.confirm._shown) end
    local plugin = menu_support.make_fake_plugin{
        ui = menu_support.make_fake_ui{ settings = {} },
        current_state = { file = "/tmp/book.epub" },
    }
    local row = Adv.deep_clean(plugin)
    h.assert_equal(row.enabled_func(), true, "doc open: enabled")

    row.callback()
    h.assert_equal(#stubs.confirm._shown, 1,
        "deep clean tap shows confirm dialog (extra friction)")

    -- The confirm message should mention "permanently" / "lost forever"
    -- \xe2\x80\x94 that's part of the bookends lesson 4 friction.
    local confirm = stubs.confirm._shown[1]
    h.assert_true(confirm.text:find("permanently") ~= nil
                  or confirm.text:find("lost forever") ~= nil,
        "deep clean confirm uses dangerous-action language")
end


-- ---------------------------------------------------------------------------
-- Deep clean ALSO removes the cloud-staging artifacts — the staged payloads
-- AND KOReader SyncService's `.sync` cached-ancestor + `.temp`.  (Reported
-- bug: the cloud_staging folder, including the two `.sync` files, survived
-- deep clean, so "all book data permanently deleted" was a lie.)
-- ---------------------------------------------------------------------------
do
    while #stubs.confirm._shown > 0 do table.remove(stubs.confirm._shown) end
    local book_file = "/tmp/staging_book.epub"

    -- Deterministic content id via the doc_settings cache-hit path.
    package.loaded["docsettings"] = { open = function(_, _)
        return { readSetting = function(_, k)
            if k == "partial_md5_checksum" then return "deadbeef99" end
        end }
    end }
    -- clear_all touches the live annotation list; not under test here.
    package.loaded["syncery_ann/doc_settings_bridge"] = { clear_all = function() end }
    package.loaded["syncery_ui/menu/advanced_section"] = nil
    local Adv2 = require("syncery_ui/menu/advanced_section")

    local paths = Adv2._cloud_staging_paths(book_file)
    h.assert_equal(#paths, 6,
        "cloud-staging removal covers 6 paths (payload + .sync + .temp, x2 kinds)")

    local StorageMode = require("syncery_storage_mode")
    local staging_dir = StorageMode.get_hash_root() .. "/cloud_staging"
    local set = {}
    for __, p in ipairs(paths) do set[p] = true end
    for __, kind in ipairs({ "progress", "annotations" }) do
        local base = staging_dir .. "/syncery-" .. kind .. "-deadbeef99.json"
        h.assert_true(set[base .. ".sync"] == true,
            kind .. " .sync cached-ancestor is in the removal set")
    end

    -- End-to-end: real files at those paths, run deep clean, assert gone.
    os.execute("mkdir -p '" .. staging_dir .. "' 2>/dev/null")
    for __, p in ipairs(paths) do
        local f = io.open(p, "w"); if f then f:write("x"); f:close() end
    end

    local plugin = menu_support.make_fake_plugin{
        ui = menu_support.make_fake_ui{ settings = {} },
        current_state = { file = book_file },
    }
    plugin.storage_mode = "sdr"   -- skip the hash-only synceryhash block
    local row = Adv2.deep_clean(plugin)
    row.callback()
    local confirm = stubs.confirm._shown[#stubs.confirm._shown]
    h.assert_true(type(confirm.ok_callback) == "function",
        "deep clean confirm has an ok_callback")
    confirm.ok_callback()

    for __, p in ipairs(paths) do
        h.assert_true(io.open(p, "r") == nil,
            "deep clean removed cloud-staging file: " .. p)
    end

    package.loaded["syncery_ui/menu/advanced_section"] = nil
    package.loaded["docsettings"] = nil
    package.loaded["syncery_ann/doc_settings_bridge"] = nil
end


-- ---------------------------------------------------------------------------
-- reset_all — destructive row moved here from Maintenance (Phase 13)
-- ---------------------------------------------------------------------------


do
    local plugin = menu_support.make_fake_plugin{}
    local row = Adv.reset_all(plugin)
    h.assert_true(type(row.callback) == "function",
        "reset_all is an actionable row")
    h.assert_true(row.text:find("Reset all") ~= nil,
        "reset_all row is labelled 'Reset all'")
    -- tapping it routes to the plugin's _resetAll
    plugin._resetAll = function(self) self._reset_called = true end
    row.callback(nil)
    h.assert_true(plugin._reset_called == true,
        "reset_all callback invokes plugin:_resetAll()")
end


-- ---------------------------------------------------------------------------
-- build() composition — Delete and reset: destructive only
-- ---------------------------------------------------------------------------


do
    local plugin = menu_support.make_fake_plugin{}
    local rows = Adv.build(plugin)
    h.assert_equal(#rows, 2,
        "build(): 2 entries (deep clean + reset all)")
    h.assert_true(type(rows[1].callback) == "function",
        "build row 1 (deep clean) is actionable")
    h.assert_true(type(rows[2].callback) == "function",
        "build row 2 (reset all) is actionable")
    -- summary/render are NO LONGER here (moved to What's synced → Other types)
    h.assert_true(Adv.menuEngineOptions == nil,
        "menuEngineOptions removed — summary/render moved out of Advanced")
end
