-- =============================================================================
-- spec/menu_status_parity_spec.lua
-- =============================================================================
--
-- Phase 13.B step 2 — status cluster parity gate.
--
-- The Phase-13 review verified that status_section.lua ALREADY implements
-- the step-2 design: the smart header reads cached state and opens the
-- status panel, and "Sync this book" is decoupled from the global
-- sync_progress field (it reads/writes the per-book `syncery_disabled`
-- flag in doc_settings).  Rather than rewrite working, well-tested code,
-- this gate LOCKS the two invariants the mockup made explicit, so a later
-- step can't silently regress them:
--
--   1. The smart header is tappable ONLY when a transport needs action,
--      and in that case tapping opens that transport's SETUP (resolve),
--      via plugin:resolveStatusProblem() — not the read-only status panel.
--      When there is no problem the header is informational and NOT
--      tappable; everyday access to the device-positions panel is the
--      dedicated "Show device status" row (Devices menu, door #2).
--      (Supersedes the original "header always opens the panel" decision:
--      a header that always opened the panel made "— tap to resolve"
--      meaningless, since it never took you anywhere you could fix things.)
--
--   2. "Sync this book" is per-book and DECOUPLED: toggling it must change
--      only doc_settings.syncery_disabled and must NOT touch the global
--      plugin.sync_progress field. (Coupling them would mean "exclude one
--      book" == "stop progress for ALL books" — the D-finding the mockup
--      fixed.)
-- =============================================================================


local h            = require("spec.test_helpers")
local menu_support = require("spec.menu_test_support")
h.setup("/tmp/syncery_menu_status_parity_spec_" .. tostring(os.time()))
menu_support.install_stubs()

local S = require("syncery_ui/menu/status_section")


-- ---------------------------------------------------------------------------
-- 1. Header is tappable ONLY on a problem; no-problem header does nothing.
-- ---------------------------------------------------------------------------
do
    -- No problem → informational, NOT tappable, does NOT open the panel.
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        _transport = menu_support.make_fake_transport({
            syncthing = { available = true, summary = "ready", display_name = "Syncthing" },
        }),
        status_badge = "synced just now",
    }
    local row = S.smart_header(plugin)
    h.assert_true(row.text_func():find("tap to resolve") == nil,
        "parity: precondition — no-problem header has no 'tap to resolve'")
    -- The guarantee is at the UI layer: enabled_func() == false means the
    -- menu never fires the callback for an informational header.  (The
    -- callback isn't independently guarded — enabled_func is the gate, and
    -- resolveStatusProblem has a harmless status-panel fallback if ever
    -- force-invoked.)  Everyday status access is the "Show device status"
    -- row, not this header.
    h.assert_equal(row.enabled_func(), false,
        "parity: no-problem header is NOT tappable")

    -- Problem present → tappable, and tapping resolves (opens setup).
    local plugin2 = menu_support.make_fake_plugin{
        use_syncthing = true,
        _transport = menu_support.make_fake_transport({
            syncthing = { available = false, summary = "x", display_name = "Syncthing" },
        }),
    }
    local row2 = S.smart_header(plugin2)
    h.assert_true(row2.text_func():find("tap to resolve") ~= nil,
        "parity: problem header shows '— tap to resolve'")
    h.assert_equal(row2.enabled_func(), true,
        "parity: problem header IS tappable")
    row2.callback()
    h.assert_equal(plugin2._calls.resolveStatusProblem, 1,
        "parity: tapping a problem header opens the transport setup (resolve)")
end


-- ---------------------------------------------------------------------------
-- 2. "Sync this book" is decoupled from the global sync_progress field.
-- ---------------------------------------------------------------------------
do
    local plugin = menu_support.make_fake_plugin{
        sync_progress = true,                          -- global stays true throughout
        ui = menu_support.make_fake_ui{ settings = {} },
    }
    local row = S.sync_this_book_toggle(plugin)

    -- toggling OFF must flip only the per-book flag…
    row.callback(nil)
    h.assert_equal(plugin.ui._settings.syncery_disabled, true,
        "parity: toggle writes per-book syncery_disabled")
    -- …and must NOT touch the global progress field.
    h.assert_equal(plugin.sync_progress, true,
        "parity: global sync_progress is untouched by per-book toggle (decoupled)")

    -- checked_func reflects the per-book flag, not the global field.
    h.assert_equal(row.checked_func(), false,
        "parity: checked_func reads the per-book flag")
    row.callback(nil)
    h.assert_equal(plugin.sync_progress, true,
        "parity: global sync_progress still untouched after second toggle")
    h.assert_equal(row.checked_func(), true,
        "parity: checked_func flips back with the per-book flag")
end


-- ---------------------------------------------------------------------------
-- 3. The cluster build() still yields exactly the three top rows in order.
-- ---------------------------------------------------------------------------
do
    local plugin = menu_support.make_fake_plugin{
        ui = menu_support.make_fake_ui{ settings = {} },
    }
    local rows = S.build(plugin)
    h.assert_equal(#rows, 3, "parity: status cluster has 3 rows")
    h.assert_true(type(rows[1].text_func) == "function",
        "parity: row 1 is the dynamic smart header")
    h.assert_equal(rows[2].text, "Sync this book",
        "parity: row 2 is Sync this book")
    h.assert_true(type(rows[3].text_func) == "function",
        "parity: row 3 is the dynamic Sync now")
end
