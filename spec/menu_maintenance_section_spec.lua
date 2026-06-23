-- =============================================================================
-- spec/menu_maintenance_section_spec.lua
-- =============================================================================
--
-- Tests for syncery_ui/menu/maintenance_section.lua.  Focus on
-- Pattern 4 (conditional sections): rows specific to a transport
-- only appear when that transport is enabled.
-- =============================================================================


local h            = require("spec.test_helpers")
local menu_support = require("spec.menu_test_support")
h.setup("/tmp/syncery_menu_maint_spec_" .. tostring(os.time()))
local stubs = menu_support.install_stubs()

local M = require("syncery_ui/menu/maintenance_section")


-- ---------------------------------------------------------------------------
-- Pattern 4: Syncthing-conditional cluster
-- ---------------------------------------------------------------------------


-- All transports off: no Syncthing/Cloud headers or rows.
do
    local plugin = menu_support.make_fake_plugin{}
    local items = M.build(plugin)
    h.assert_nil(menu_support.find_row(items, "Syncthing"),
        "no transports: no Syncthing submenu (Pattern 4)")
    h.assert_nil(menu_support.find_row(items, "Rescan all Syncthing folders"),
        "no transports: no rescan row (Pattern 4)")
    h.assert_nil(menu_support.find_row(items, "Cloud"),
        "no transports: no Cloud submenu (Pattern 4)")
    h.assert_nil(menu_support.find_row(items, "Clean cloud upload staging"),
        "no transports: no clean staging row (Pattern 4)")

    -- §23.2 = C: the data ops live under the "── Your Syncery data ──" group,
    -- transport-agnostic, so they are present even with every transport off.
    h.assert_true(menu_support.find_row(items, "── Your Syncery data ──") ~= nil,
        "data group: 'Your Syncery data' header present regardless of transports")
    h.assert_true(menu_support.find_row(items, "Sync pre-Syncery data…") ~= nil,
        "bulk ingest: 'Sync pre-Syncery data…' row present (item 10 rename)")
    local row = menu_support.find_row(items, "Sync pre-Syncery data…")
    h.assert_true(type(row.callback) == "function", "bulk ingest: row has a callback")

    -- §23.13 replacement: orphan cleanup is now a STANDALONE Housekeeping row,
    -- NOT gated on Syncthing. It bases the book set on home_dir, so it must be
    -- reachable even with every transport off.
    h.assert_true(menu_support.find_row(items, "Remove orphaned sync files…") ~= nil,
        "orphan cleanup: standalone row present even with all transports off")
    local orphan_row = menu_support.find_row(items, "Remove orphaned sync files…")
    h.assert_true(type(orphan_row.callback) == "function", "orphan cleanup: row has a callback")
end


-- Syncthing on: header + rescan + KOSyncthing+ rows. (Orphan cleanup is NO LONGER
-- here — it is a standalone Housekeeping row, asserted above.)
do
    local plugin = menu_support.make_fake_plugin{ use_syncthing = true }
    local items = M.build(plugin)
    -- (d) nested submenu: the Syncthing row carries a sub_item_table_func;
    -- the transport rows live INSIDE it, not at the top level.
    local syncthing_row = menu_support.find_row(items, "Syncthing")
    h.assert_true(syncthing_row ~= nil, "syncthing on: Syncthing submenu row present")
    h.assert_true(type(syncthing_row.sub_item_table_func) == "function",
        "syncthing on: Syncthing row is a submenu (sub_item_table_func)")
    local sub = syncthing_row.sub_item_table_func()
    h.assert_true(menu_support.find_row(sub, "Rescan all Syncthing folders") ~= nil,
        "syncthing submenu: rescan row present")
    h.assert_true(menu_support.find_row(sub, "KOSyncthing+ integration status…") ~= nil,
        "syncthing submenu: KOSyncthing+ row present")
    -- orphan cleanup is in the DATA group (top level), NOT the Syncthing submenu —
    -- it is storage-mode-coupled, not transport-coupled.
    h.assert_true(menu_support.find_row(items, "Remove orphaned sync files…") ~= nil,
        "syncthing on: orphan row is top-level (data group), not in the submenu")
    h.assert_nil(menu_support.find_row(sub, "Remove orphaned sync files…"),
        "syncthing submenu: orphan row is NOT inside the transport submenu")
end


-- Cloud on: cloud header + clean staging row.
do
    local plugin = menu_support.make_fake_plugin{ use_cloud = true }
    local items = M.build(plugin)
    local cloud_row = menu_support.find_row(items, "Cloud")
    h.assert_true(cloud_row ~= nil, "cloud on: Cloud submenu row present")
    h.assert_true(type(cloud_row.sub_item_table_func) == "function",
        "cloud on: Cloud row is a submenu (sub_item_table_func)")
    local sub = cloud_row.sub_item_table_func()
    h.assert_true(menu_support.find_row(sub, "Clean cloud upload staging") ~= nil,
        "cloud submenu: clean staging row present")
end


-- Both on: both clusters present, in order (Syncthing first).
do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true, use_cloud = true,
    }
    local items = M.build(plugin)
    local syncthing_idx, cloud_idx
    for i, row in ipairs(items) do
        local label = menu_support.label_of(row)
        if label == "Syncthing" then syncthing_idx = i end
        if label == "Cloud"     then cloud_idx     = i end
    end
    h.assert_true(syncthing_idx ~= nil, "syncthing submenu found")
    h.assert_true(cloud_idx     ~= nil, "cloud submenu found")
    h.assert_true(syncthing_idx < cloud_idx,
        "syncthing submenu appears before cloud")
end


-- ---------------------------------------------------------------------------
-- KOSyncthing+ integration row gated on plugin being installed
-- ---------------------------------------------------------------------------


-- KOSyncthing+ not installed: row enabled_func is false.
do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        kosyncthing_installed = false,
    }
    local items = M.build(plugin)
    local sub = menu_support.find_row(items, "Syncthing").sub_item_table_func()
    local kosyncthing_row = menu_support.find_row(sub, "KOSyncthing+ integration status…")
    h.assert_true(kosyncthing_row ~= nil, "KOSyncthing+ row present (in submenu)")
    h.assert_equal(kosyncthing_row.enabled_func(), false,
        "KOSyncthing+ not installed: row disabled")
end


-- KOSyncthing+ installed: row enabled.
do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        kosyncthing_installed = true,
    }
    local items = M.build(plugin)
    local sub = menu_support.find_row(items, "Syncthing").sub_item_table_func()
    local kosyncthing_row = menu_support.find_row(sub, "KOSyncthing+ integration status…")
    h.assert_equal(kosyncthing_row.enabled_func(), true,
        "KOSyncthing+ installed: row enabled")

    kosyncthing_row.callback()
    h.assert_equal(plugin._calls._configureKOSyncthingPlusConflicts, 1,
        "tap fires plugin:_configureKOSyncthingPlusConflicts()")
end


-- ---------------------------------------------------------------------------
-- Always-present rows
-- ---------------------------------------------------------------------------


do
    local plugin = menu_support.make_fake_plugin{}
    local items = M.build(plugin)
    -- These rows are present regardless of transport toggles.
    h.assert_true(menu_support.find_row(items, "Recent sync activity") ~= nil,
        "activity log always present")
    h.assert_true(menu_support.find_row(items, "Manage all synced books…") ~= nil,
        "manage all books always present")
    -- Trash Bin lives in What's synced → Annotations (its domain home),
    -- not in maintenance.
    h.assert_true(menu_support.find_row(items, "Trash Bin (deleted annotations)…") == nil,
        "Trash Bin is NOT in maintenance (lives with annotations)")
    -- Reset all moved to Advanced → Delete and reset (Phase 13).
    h.assert_true(menu_support.find_row(items, "Reset all Syncery settings…") == nil,
        "reset all is NO LONGER in maintenance (moved to Advanced)")
end


-- Activity log tap fires the plugin method.
do
    local plugin = menu_support.make_fake_plugin{}
    local items = M.build(plugin)
    local row = menu_support.find_row(items, "Recent sync activity")
    row.callback()
    h.assert_equal(plugin._calls._showActivityLog, 1,
        "activity log tap fires plugin:_showActivityLog()")
end


-- (Reset-all moved to Advanced → Delete and reset; its tap behaviour is
-- now covered by menu_advanced_section_spec.)



-- ---------------------------------------------------------------------------
-- Storage mode submenu (radio selection)
-- ---------------------------------------------------------------------------


do
    local plugin = menu_support.make_fake_plugin{ storage_mode = "sdr" }
    local rows = M.menuStorageMode(plugin)
    -- SDR, hash, migrate. (The hash-folder row was removed: the hash root
    -- is now fixed, so there is nothing to configure.)
    h.assert_equal(#rows, 3, "menuStorageMode: 3 rows (SDR, hash, migrate)")
    h.assert_equal(rows[1].checked_func(), true,
        "SDR row checked when storage_mode = sdr")
    h.assert_equal(rows[2].checked_func(), false,
        "hash row unchecked when storage_mode = sdr")

    -- Tap hash row → setStorageMode called with "hash"
    rows[2].callback(nil)
    h.assert_equal(plugin._calls.setStorageMode, 1,
        "tap hash row: setStorageMode called")
    h.assert_equal(plugin.storage_mode, "hash",
        "storage_mode flipped to hash")
end


-- Migration row triggers confirm dialog.
do
    while #stubs.confirm._shown > 0 do table.remove(stubs.confirm._shown) end
    local plugin = menu_support.make_fake_plugin{ storage_mode = "sdr" }
    local rows = M.menuStorageMode(plugin)
    rows[3].callback()
    h.assert_equal(#stubs.confirm._shown, 1,
        "migration row tap shows confirm dialog")
end


-- ---------------------------------------------------------------------------
-- This-device submenu
-- ---------------------------------------------------------------------------


do
    local plugin = menu_support.make_fake_plugin{ device_label = "Kindle PW" }
    local rows = M.menuThisDevice(plugin)
    h.assert_equal(#rows, 2, "menuThisDevice: 2 rows (name + ID)")

    local name_label = rows[1].text_func()
    h.assert_true(name_label:find("Kindle PW") ~= nil,
        "name row inlines current device label (Pattern 3)")

    -- Device ID row: tapping offers a ConfirmBox whose OK shows a QR code,
    -- so the long ID can be scanned from another device when pairing.
    local id_row = rows[2]
    h.assert_true(type(id_row.callback) == "function",
        "device-ID row has a callback")
    id_row.callback()
    local shown = stubs.confirm._shown[#stubs.confirm._shown]
    h.assert_true(shown ~= nil, "device-ID tap shows a ConfirmBox")
    h.assert_true(type(shown.ok_callback) == "function",
        "device-ID ConfirmBox has an OK (Show QR code) callback")
    -- Invoking OK should push a QRMessage carrying the full ID.
    shown.ok_callback()
    local qr = stubs.qrmessage._shown[#stubs.qrmessage._shown]
    h.assert_true(qr ~= nil, "Show QR code → a QRMessage is shown")
    h.assert_true(qr.text:find("abcdef") ~= nil,
        "QR carries the device ID text")
end


-- ---------------------------------------------------------------------------
-- Storage mode moved to Advanced (Phase 13) — not in maintenance build.
-- ---------------------------------------------------------------------------


-- build() no longer carries Storage mode / This device (they live in
-- Advanced now). menuStorageMode itself still works (Advanced calls it).
do
    local plugin = menu_support.make_fake_plugin{ storage_mode = "hash" }
    local items = M.build(plugin)
    local found
    for _, row in ipairs(items) do
        local label = menu_support.label_of(row)
        if label and label:find("Storage mode") then found = row; break end
    end
    h.assert_true(found == nil,
        "Storage mode is NOT in maintenance build() (moved to Advanced)")

    -- The submenu still builds correctly when reached from Advanced.
    local rows = M.menuStorageMode(plugin)
    h.assert_true(#rows >= 2, "menuStorageMode still builds its rows")
end


-- ---------------------------------------------------------------------------
-- Phase-4 cleanup: the "Diagnostic windows" submenu was replaced by two direct
-- rows in Advanced.  copyDiagnosticInfoItem is the diagnostic action; the three
-- set-once numeric knobs (freshness / journal size / activity size) were removed
-- and now keep their defaults.  bookDataSaveIntervalItem is the one behavioural
-- knob kept, relocated out of the removed group.
-- ---------------------------------------------------------------------------


do
    local plugin = menu_support.make_fake_plugin{}
    -- Spy: the row's callback must invoke the plugin's gatherer.
    plugin._copyDiagnosticInfo = function(self)
        self._calls._copyDiagnosticInfo = (self._calls._copyDiagnosticInfo or 0) + 1
    end

    local item = M.copyDiagnosticInfoItem(plugin)
    h.assert_true(item.text:find("Copy diagnostic info") ~= nil,
        "copyDiagnosticInfoItem: row text is 'Copy diagnostic info'")
    h.assert_true(item.help_text ~= nil and #item.help_text > 0,
        "copyDiagnosticInfoItem: has help text")
    h.assert_true(type(item.hold_callback) == "function",
        "copyDiagnosticInfoItem: hold shows help")
    h.assert_true(type(item.callback) == "function",
        "copyDiagnosticInfoItem: has a callback")

    item.callback()
    h.assert_equal(plugin._calls._copyDiagnosticInfo, 1,
        "copyDiagnosticInfoItem: tapping fires _copyDiagnosticInfo")
end


do
    -- Unset -> the get() fallback yields the 5 s default.
    local plugin = menu_support.make_fake_plugin{}
    local item = M.bookDataSaveIntervalItem(plugin)
    local label = item.text_func()
    h.assert_true(label:find("Book data save interval") ~= nil,
        "bookDataSaveIntervalItem: label names the setting")
    h.assert_true(label:find("5") ~= nil,
        "bookDataSaveIntervalItem: default is 5 s when unset")
    h.assert_true(item.help_text ~= nil and #item.help_text > 0,
        "bookDataSaveIntervalItem: has help text")
    h.assert_true(type(item.callback) == "function",
        "bookDataSaveIntervalItem: tapping opens the editor")

    -- A saved value is reflected in the label.
    plugin.min_save_interval = 42
    local item2 = M.bookDataSaveIntervalItem(plugin)
    h.assert_true(item2.text_func():find("42") ~= nil,
        "bookDataSaveIntervalItem: label reflects the saved value")
end
