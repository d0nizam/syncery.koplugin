-- =============================================================================
-- spec/menu_helpers_parity_spec.lua
-- =============================================================================
--
-- Phase 13.B step 1 — the "scaffolding parity gate".
--
-- The Phase-13 menu rewrite KEEPS the mechanisms in _helpers.lua (safe,
-- gatedHold, makeBoolToggle, makeNumericSetting, status_snapshot,
-- transport_state, the cfg/test functions) and only rewrites the four
-- user-facing help_* texts to match the new design.  This spec locks
-- both halves before any section is rebuilt:
--
--   1. CONTRACT: every helper the new menu relies on still exists with
--      the right shape.  If a later step accidentally drops or renames
--      one, this fails loudly instead of surfacing as a runtime nil.
--
--   2. TEXT AUDIT: the help_* strings no longer carry the stale model
--      (manual URL-as-a-step setup, "Settings → Storage mode",
--      "Settings → Annotations → Trash Bin", mutually-exclusive
--      transports) AND still carry the accurate mechanics that must NOT
--      be thrown out with the old names (filters are outbound-only,
--      tombstones, the 30-day window, the API key, the JSON-file model).
--
-- This is the same discipline as the parity sweep: assert the NEW state
-- positively, and assert the stale state is GONE.
-- =============================================================================


local h            = require("spec.test_helpers")
local menu_support = require("spec.menu_test_support")
h.setup("/tmp/syncery_menu_helpers_parity_spec_" .. tostring(os.time()))
menu_support.install_stubs()

local H = require("syncery_ui/menu/_helpers")


-- A tiny case-insensitive "contains" so the audit is robust to spacing.
local function contains(haystack, needle)
    return haystack:lower():find(needle:lower(), 1, true) ~= nil
end


-- ---------------------------------------------------------------------------
-- 1. CONTRACT — the mechanisms the new menu requires must all be present.
-- ---------------------------------------------------------------------------
do
    local required = {
        "safe", "helpHold", "gatedHold", "statusPanelHold",
        "makeBoolToggle", "makeNumericSetting",
        "load_syncthing_cfg", "save_syncthing_cfg",
        "test_syncthing_connection",
        "test_cloud_connection",
        "status_snapshot", "clear_status_snapshot", "transport_state",
    }
    for _, name in ipairs(required) do
        h.assert_true(type(H[name]) == "function",
            "contract: H." .. name .. " exists and is callable")
    end
    -- The translation shims the sections rely on.
    h.assert_true(type(H._) == "function", "contract: H._ translation shim present")
    h.assert_true(type(H._n) == "function", "contract: H._n plural shim present")
end
