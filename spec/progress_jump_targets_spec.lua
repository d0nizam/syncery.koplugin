-- =============================================================================
-- spec/progress_jump_targets_spec.lua
-- =============================================================================
--
-- Tests for syncery_ui/progress_browser/jump_targets.lua -- the pure selection
-- of which devices get a per-device jump button and whether [Jump to latest]
-- shows.  The init.lua that consumes it requires UI widgets (loadfile-only),
-- so this isolated module is where the branching is regression-checked.
-- =============================================================================

local h = require("spec.test_helpers")
local JumpTargets = require("syncery_ui/progress_browser/jump_targets")


local function set(list)
    local s = {}
    for _, v in ipairs(list) do s[v] = true end
    return s
end


-- 1. Latest is another device; a third device is behind.
do
    local entries = {
        me     = { percent = 0.30 },
        phone  = { percent = 0.70 },  -- latest
        tablet = { percent = 0.50 },
    }
    local per, show = JumpTargets.compute(entries, "me", "phone")
    h.assert_true(show, "show [Jump to latest] when latest is another device")
    h.assert_equal(#per, 1, "one per-device button (the third device)")
    local s = set(per)
    h.assert_true(s["tablet"] == true, "the third (non-latest) device gets a button")
    h.assert_true(s["phone"] == nil, "the latest gets NO per-device button")
    h.assert_true(s["me"] == nil, "this device gets NO per-device button")
end


-- 2. THIS device is the latest -> hide [Jump to latest]; others still listed.
do
    local entries = {
        me     = { percent = 0.90 },  -- latest = me
        phone  = { percent = 0.40 },
        tablet = { percent = 0.50 },
    }
    local per, show = JumpTargets.compute(entries, "me", "me")
    h.assert_true(not show, "hide [Jump to latest] when THIS device is the latest")
    h.assert_equal(#per, 2, "the other (behind) devices still get buttons")
    local s = set(per)
    h.assert_true(s["phone"] and s["tablet"], "both behind devices listed")
    h.assert_true(s["me"] == nil, "this device never gets a button")
end


-- 3. Only this device.
do
    local entries = { me = { percent = 0.20 } }
    local per, show = JumpTargets.compute(entries, "me", "me")
    h.assert_equal(#per, 0, "no per-device buttons when alone")
    h.assert_true(not show, "no [Jump to latest] when alone")
end


-- 4. nil latest -> no [Jump to latest]; entries without percent excluded.
do
    local entries = {
        me    = { percent = 0.30 },
        phone = { percent = 0.60 },
        ghost = { label = "no percent" },  -- excluded (no percent)
    }
    local per, show = JumpTargets.compute(entries, "me", nil)
    h.assert_true(not show, "nil latest -> no [Jump to latest]")
    h.assert_equal(#per, 1, "only the percent-bearing non-this device")
    local s = set(per)
    h.assert_true(s["phone"] == true, "phone listed")
    h.assert_true(s["ghost"] == nil, "entry without percent excluded")
end


-- 5. nil entries -> empty.
do
    local per, show = JumpTargets.compute(nil, "me", "me")
    h.assert_equal(#per, 0, "nil entries -> no buttons")
    h.assert_true(not show, "nil entries + latest==this -> no latest")
end


print("progress_jump_targets_spec: assertions complete")
