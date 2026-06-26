-- =============================================================================
-- spec/menu_db_sync_section_spec.lua
-- =============================================================================
--
-- Tests for syncery_ui/menu/db_sync_section.lua -- the "Statistics &
-- Vocabulary" submenu (master toggle + two sub-toggles gated by the master +
-- an info row).  The gating LOGIC is tested in syncery_db_sync_spec; this spec
-- covers the MENU's shape: that the rows are wired to the right plugin fields
-- and that the sub-toggles are disabled while the master is OFF.
-- =============================================================================


local h            = require("spec.test_helpers")
local menu_support = require("spec.menu_test_support")
h.setup("/tmp/syncery_menu_db_sync_spec_" .. tostring(os.time()))
local stubs = menu_support.install_stubs()

local DbSyncSec = require("syncery_ui/menu/db_sync_section")


-- Master OFF: the two sub-toggles are present but DISABLED (master_field), and
-- the info row is a plain callback, not a toggle.
do
    local plugin = menu_support.make_fake_plugin{ db_sync_enabled = false }
    local rows = DbSyncSec.menuDbSync(plugin)
    h.assert_equal(#rows, 6, "menuDbSync: 6 rows (master + 3 subs + interval + info)")

    h.assert_true(type(rows[1].checked_func) == "function", "row 1 is the master toggle")
    h.assert_false(rows[1].checked_func(), "master reads db_sync_enabled (false)")

    h.assert_true(type(rows[2].enabled_func) == "function", "stats sub has enabled_func")
    h.assert_false(rows[2].enabled_func(), "stats sub disabled while master OFF")
    h.assert_false(rows[3].enabled_func(), "vocab sub disabled while master OFF")

    -- Row 4 is the Tier 2 unify sub-toggle: a toggle gated by the master.
    h.assert_true(type(rows[4].checked_func) == "function", "row 4 is the unify toggle")
    h.assert_true(type(rows[4].enabled_func) == "function", "unify sub has enabled_func")
    h.assert_false(rows[4].enabled_func(), "unify sub disabled while master OFF")

    -- Row 5 is the interval (numeric) row: a dynamic text_func label, gated by
    -- the master, not a toggle.
    h.assert_true(type(rows[5].text_func) == "function", "row 5 is the interval row (text_func)")
    h.assert_true(type(rows[5].enabled_func) == "function", "interval row has enabled_func")
    h.assert_false(rows[5].enabled_func(), "interval row disabled while master OFF")
    h.assert_true(rows[5].checked_func == nil, "interval row is not a toggle")

    h.assert_true(type(rows[6].callback) == "function", "row 6 is the info row")
    h.assert_true(rows[6].checked_func == nil, "info row is not a toggle")
end


-- Master ON: the sub-toggles become enabled; their checked_func reads the
-- per-DB fields (default ON).
do
    local plugin = menu_support.make_fake_plugin{ db_sync_enabled = true }
    local rows = DbSyncSec.menuDbSync(plugin)
    h.assert_true(rows[1].checked_func(), "master reads db_sync_enabled (true)")
    h.assert_true(rows[2].enabled_func(), "stats sub enabled while master ON")
    h.assert_true(rows[3].enabled_func(), "vocab sub enabled while master ON")
    h.assert_true(rows[2].checked_func(),  "stats sub default ON")
    h.assert_true(rows[3].checked_func(),  "vocab sub default ON")
    h.assert_true(rows[4].enabled_func(),  "unify sub enabled while master ON")
    h.assert_false(rows[4].checked_func(), "unify sub default OFF (Tier 2 opt-in)")
    h.assert_true(rows[5].enabled_func(),  "interval row enabled while master ON")
end


-- The master toggle flips its live field (which syncery_db_sync reads via the
-- persisted key).
do
    local rearm_calls = 0
    local plugin = menu_support.make_fake_plugin{ db_sync_enabled = true }
    plugin._rearmDbSyncTimer = function() rearm_calls = rearm_calls + 1 end
    local rows = DbSyncSec.menuDbSync(plugin)
    rows[1].callback(nil)
    h.assert_false(plugin.db_sync_enabled, "master toggle flips db_sync_enabled true->false")
    h.assert_equal(rearm_calls, 1, "master toggle re-arms the DB-sync timer (after_set)")
    rows[1].callback(nil)
    h.assert_true(plugin.db_sync_enabled, "master toggle flips back false->true")
    h.assert_equal(rearm_calls, 2, "master toggle re-arms again on flip back")
end


-- A sub-toggle flips only its own field, independently.
do
    local plugin = menu_support.make_fake_plugin{ db_sync_enabled = true,
                                                  db_sync_stats = true, db_sync_vocab = true }
    local rows = DbSyncSec.menuDbSync(plugin)
    rows[2].callback(nil)
    h.assert_false(plugin.db_sync_stats, "stats sub flips db_sync_stats")
    h.assert_true(plugin.db_sync_vocab,  "vocab field untouched by the stats toggle")
end


-- The Tier 2 unify toggle flips its own field AND asserts the unified config
-- (after_set -> _unifyDbSyncConfig) so the change takes effect immediately.
do
    local unify_calls = 0
    local plugin = menu_support.make_fake_plugin{ db_sync_enabled = true, db_sync_unify = false }
    plugin._unifyDbSyncConfig = function() unify_calls = unify_calls + 1 end
    local rows = DbSyncSec.menuDbSync(plugin)
    rows[4].callback(nil)
    h.assert_true(plugin.db_sync_unify, "unify toggle flips db_sync_unify OFF->ON")
    h.assert_equal(unify_calls, 1, "unify toggle asserts the unified config (after_set)")
    rows[4].callback(nil)
    h.assert_false(plugin.db_sync_unify, "unify toggle flips back ON->OFF")
    h.assert_equal(unify_calls, 2, "unify after_set fires again on flip back (no-op when OFF)")
end


print("menu_db_sync_section_spec: all assertions passed")
