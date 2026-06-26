-- =============================================================================
-- spec/lifecycle_timers_spec.lua
-- =============================================================================
--
-- Tests for syncery_lifecycle/timers.lua.
--
-- A real UIManager is a complex piece of KOReader.  For these tests we
-- only care about three operations: scheduleIn(delay, fn), unschedule(fn),
-- and what's been called.  The fake below records every call and lets
-- us fire scheduled callbacks on demand, so the test reads as
-- "arm a timer, advance, assert".
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_lifecycle_timers_spec_" .. tostring(os.time()))

local Timers = require("syncery_lifecycle/timers")


-- ----------------------------------------------------------------------------
-- Fake UIManager.  Captures every scheduleIn / unschedule call.
-- `fire(action)` runs a captured action as if its deadline had passed;
-- `fire_all()` runs every captured action.  `is_scheduled(action)`
-- returns whether the action is still in the pending list (false after
-- the action has fired or been unscheduled).
-- ----------------------------------------------------------------------------


local function make_fake_uimgr()
    local pending = {}  -- list of {delay, action}
    return {
        -- Calls received, in order, for assertions on what got scheduled.
        scheduleIn = function(self, delay, action)
            table.insert(pending, { delay = delay, action = action })
        end,
        unschedule = function(self, action)
            for i = #pending, 1, -1 do
                if pending[i].action == action then
                    table.remove(pending, i)
                end
            end
        end,
        -- Test helpers.
        is_scheduled = function(action)
            for _, e in ipairs(pending) do
                if e.action == action then return true end
            end
            return false
        end,
        delay_for = function(action)
            for _, e in ipairs(pending) do
                if e.action == action then return e.delay end
            end
            return nil
        end,
        fire = function(action)
            -- Mimic UIManager's contract: action removed before it runs.
            for i = #pending, 1, -1 do
                if pending[i].action == action then
                    table.remove(pending, i)
                end
            end
            action()
        end,
        pending_count = function() return #pending end,
    }
end


-- ----------------------------------------------------------------------------
-- A fresh Timers stores the action token under the slot field on the
-- plugin object — that's the contract legacy call sites read.
-- ----------------------------------------------------------------------------


do
    local ui     = make_fake_uimgr()
    local plugin = { destroyed = false }
    local t      = Timers.new{ ui_manager = ui, plugin = plugin }

    local fired = false
    t:schedule("_autosave_action", 5, function() fired = true end)

    h.assert_equal(ui.pending_count(),               1,
        "schedule registers one timer with UIManager")
    h.assert_equal(type(plugin._autosave_action),    "function",
        "slot field on plugin holds the action token")
    h.assert_true(t:is_armed("_autosave_action"),
        "is_armed reports true after schedule")
    h.assert_false(fired,
        "body does not fire until UIManager runs it")
end


-- ----------------------------------------------------------------------------
-- Firing the action runs the body and clears the slot.
-- ----------------------------------------------------------------------------


do
    local ui     = make_fake_uimgr()
    local plugin = { destroyed = false }
    local t      = Timers.new{ ui_manager = ui, plugin = plugin }

    local fired = false
    t:schedule("_autosave_action", 1, function() fired = true end)
    local action = plugin._autosave_action

    ui.fire(action)

    h.assert_true(fired,                              "body fired")
    h.assert_nil(plugin._autosave_action,             "plugin slot cleared after fire")
    h.assert_false(t:is_armed("_autosave_action"),    "is_armed false after fire")
end


-- ----------------------------------------------------------------------------
-- Re-arming the same slot cancels the prior arm.  The first action
-- token must be unscheduled before the second goes in, otherwise
-- cancel_all would have two tokens for the same slot to clean up.
-- ----------------------------------------------------------------------------


do
    local ui     = make_fake_uimgr()
    local plugin = { destroyed = false }
    local t      = Timers.new{ ui_manager = ui, plugin = plugin }

    t:schedule("_autosave_action", 5, function() end)
    local first_action = plugin._autosave_action
    t:schedule("_autosave_action", 2, function() end)
    local second_action = plugin._autosave_action

    h.assert_false(first_action == second_action,
        "second schedule allocates a new action token")
    h.assert_false(ui.is_scheduled(first_action),
        "prior arm was unscheduled")
    h.assert_true(ui.is_scheduled(second_action),
        "new arm is scheduled")
    h.assert_equal(ui.delay_for(second_action), 2,
        "new arm uses the new delay")
    h.assert_equal(ui.pending_count(), 1,
        "exactly one pending action after re-arm")
end


-- ----------------------------------------------------------------------------
-- The body of the action may re-schedule the same slot.  The slot
-- must be cleared BEFORE the body runs so the re-schedule sees an
-- empty slot rather than tripping its own cancel-prior-arm path with
-- a token whose action is currently mid-call.
-- ----------------------------------------------------------------------------


do
    local ui     = make_fake_uimgr()
    local plugin = { destroyed = false }
    local t      = Timers.new{ ui_manager = ui, plugin = plugin }

    local call_count = 0
    local function body()
        call_count = call_count + 1
        -- During the body, the slot should already be cleared.
        h.assert_nil(plugin._autosave_action,
            "slot cleared before body runs (call " .. call_count .. ")")
        if call_count < 2 then
            t:schedule("_autosave_action", 1, body)
        end
    end

    t:schedule("_autosave_action", 1, body)
    ui.fire(plugin._autosave_action)  -- body re-arms
    ui.fire(plugin._autosave_action)  -- body does not re-arm

    h.assert_equal(call_count, 2,        "body fired twice (initial + re-arm)")
    h.assert_nil(plugin._autosave_action, "slot finally cleared")
end


-- ----------------------------------------------------------------------------
-- Destroyed plugin: scheduled bodies do NOT fire.  Same guarantee as
-- the legacy inline _schedule.
-- ----------------------------------------------------------------------------


do
    local ui     = make_fake_uimgr()
    local plugin = { destroyed = false }
    local t      = Timers.new{ ui_manager = ui, plugin = plugin }

    local fired = false
    t:schedule("_autosave_action", 1, function() fired = true end)
    local action = plugin._autosave_action

    plugin.destroyed = true
    ui.fire(action)

    h.assert_false(fired,
        "body skipped when plugin.destroyed is true")
    h.assert_nil(plugin._autosave_action,
        "slot is still cleared (so cancel_all stays a no-op)")
end


-- ----------------------------------------------------------------------------
-- A body that raises an exception does NOT bring down UIManager's
-- scheduler — the error is caught by pcall and logged via the
-- injected logger.
-- ----------------------------------------------------------------------------


do
    local ui     = make_fake_uimgr()
    local plugin = { destroyed = false }
    local warn_messages = {}
    local logger = {
        warn = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
            table.insert(warn_messages, table.concat(parts, " "))
        end,
    }
    local t = Timers.new{ ui_manager = ui, plugin = plugin, logger = logger }

    t:schedule("_gc_action", 1, function() error("boom") end)
    local action = plugin._gc_action

    -- pcall in Timers means ui.fire must not propagate the error.
    local ok = pcall(ui.fire, action)
    h.assert_true(ok,
        "exception in body is swallowed by Timers' internal pcall")

    h.assert_equal(#warn_messages, 1, "logger.warn called once")
    h.assert_true(warn_messages[1]:find("_gc_action") ~= nil,
        "warn message includes the slot name")
    h.assert_true(warn_messages[1]:find("boom") ~= nil,
        "warn message includes the error text")
end


-- ----------------------------------------------------------------------------
-- cancel(slot) drops one slot without touching others.
-- ----------------------------------------------------------------------------


do
    local ui     = make_fake_uimgr()
    local plugin = { destroyed = false }
    local t      = Timers.new{ ui_manager = ui, plugin = plugin }

    t:schedule("_autosave_action", 1, function() end)
    t:schedule("_gc_action",       2, function() end)
    h.assert_equal(ui.pending_count(), 2, "both armed")

    local autosave_action = plugin._autosave_action
    t:cancel("_autosave_action")

    h.assert_false(ui.is_scheduled(autosave_action),
        "cancel unschedules the action with UIManager")
    h.assert_nil(plugin._autosave_action,
        "cancel clears the plugin slot field")
    h.assert_true(t:is_armed("_gc_action"),
        "other slots untouched by cancel")
end


-- ----------------------------------------------------------------------------
-- cancel(slot) on an empty slot is a no-op (no crash, no UIManager call).
-- ----------------------------------------------------------------------------


do
    local ui     = make_fake_uimgr()
    local plugin = { destroyed = false }
    local t      = Timers.new{ ui_manager = ui, plugin = plugin }

    t:cancel("_autosave_action")  -- nothing to cancel
    h.assert_equal(ui.pending_count(), 0, "no UIManager interaction")
    h.assert_nil(plugin._autosave_action, "slot remains nil")
end


-- ----------------------------------------------------------------------------
-- cancel_all drops every armed slot and clears every plugin field.
-- ----------------------------------------------------------------------------


do
    local ui     = make_fake_uimgr()
    local plugin = { destroyed = false }
    local t      = Timers.new{ ui_manager = ui, plugin = plugin }

    t:schedule("_autosave_action",     1, function() end)
    t:schedule("_gc_action",           1, function() end)
    t:schedule("_debounce_scan_action",1, function() end)
    h.assert_equal(ui.pending_count(), 3, "three timers armed")

    t:cancel_all()

    h.assert_equal(ui.pending_count(), 0,
        "every armed timer is unscheduled")
    h.assert_nil(plugin._autosave_action,      "autosave slot cleared")
    h.assert_nil(plugin._gc_action,            "gc slot cleared")
    h.assert_nil(plugin._debounce_scan_action, "debounce slot cleared")
end


-- ----------------------------------------------------------------------------
-- cancel_all is idempotent: calling it on a fresh Timers does nothing
-- and doesn't crash.  Important because lifecycle events can fire in
-- arbitrary orders (e.g. onCloseDocument → onQuit → cancel_all twice).
-- ----------------------------------------------------------------------------


do
    local ui     = make_fake_uimgr()
    local plugin = { destroyed = false }
    local t      = Timers.new{ ui_manager = ui, plugin = plugin }

    t:cancel_all()
    t:cancel_all()
    h.assert_equal(ui.pending_count(), 0, "no spurious UIManager calls")
end


-- ----------------------------------------------------------------------------
-- The static SLOTS list contains exactly the slot names production code
-- schedules — so cancel_all (which iterates SLOTS) reaches every armed
-- timer, and a typo / off-slot name is caught.
-- ----------------------------------------------------------------------------


do
    local expected = {
        ["_autosave_action"]         = true,
        ["_check_remote_action"]     = true,
        ["_cloud_upload_action"]     = true,
        ["_debounce_scan_action"]    = true,
        ["_firstrun_action"]         = true,
        ["_gc_action"]               = true,
        ["_open_cloud_pull"]         = true,
        ["_post_pull_check"]         = true,
        ["_resume_recheck_action"]   = true,
        ["_sync_annotations_action"] = true,
        ["_sync_bookmarks_action"]   = true,
        ["_sync_now_action"]         = true,
        ["_sync_unlock_action"]      = true,
    }
    local found = {}
    for _, slot in ipairs(Timers.SLOTS) do found[slot] = true end

    for slot in pairs(expected) do
        h.assert_true(found[slot] == true,
            "SLOTS contains legacy slot " .. slot)
    end
    for slot in pairs(found) do
        h.assert_true(expected[slot] == true,
            "SLOTS contains no surprise slot (" .. slot .. ")")
    end
end


-- ----------------------------------------------------------------------------
-- BUG-2 regression: `_sync_annotations_action` and `_resume_recheck_action`
-- are scheduled by production code (main.lua onAnnotationsModified / lifecycle
-- init resume re-probe) but were MISSING from SLOTS, so cancel_all — and thus
-- cancelPendingSync, which guards destructive resets — silently skipped them.
-- A forced annotation save could then survive a reset.  They must now be
-- cancelled by cancel_all like every other slot.
-- ----------------------------------------------------------------------------


do
    local ui     = make_fake_uimgr()
    local plugin = { destroyed = false }
    local t      = Timers.new{ ui_manager = ui, plugin = plugin }

    t:schedule("_sync_annotations_action", 1, function() end)
    t:schedule("_resume_recheck_action",   1, function() end)
    h.assert_true(t:is_armed("_sync_annotations_action"),
        "BUG-2: _sync_annotations_action armed before cancel_all")
    h.assert_true(t:is_armed("_resume_recheck_action"),
        "BUG-2: _resume_recheck_action armed before cancel_all")

    t:cancel_all()

    h.assert_false(t:is_armed("_sync_annotations_action"),
        "BUG-2: cancel_all cancels _sync_annotations_action (was off-slot)")
    h.assert_false(t:is_armed("_resume_recheck_action"),
        "BUG-2: cancel_all cancels _resume_recheck_action (was off-slot)")
end


-- ----------------------------------------------------------------------------
-- BUG-2 hardening: scheduling an unknown slot fails loudly, so a future
-- off-slot name cannot silently escape cancel_all again.
-- ----------------------------------------------------------------------------


do
    local ui     = make_fake_uimgr()
    local plugin = { destroyed = false }
    local t      = Timers.new{ ui_manager = ui, plugin = plugin }

    local ok = pcall(function()
        t:schedule("_bogus_unknown_action", 1, function() end)
    end)
    h.assert_false(ok,
        "BUG-2 hardening: schedule rejects an unknown (off-SLOTS) slot")
end


-- ----------------------------------------------------------------------------
-- Constructor validates required deps.
-- ----------------------------------------------------------------------------


do
    local ok = pcall(Timers.new, {})
    h.assert_false(ok, "missing ui_manager raises")

    local ok2 = pcall(Timers.new, { ui_manager = {} })
    h.assert_false(ok2, "missing plugin raises")

    local ok3 = pcall(Timers.new, { ui_manager = {}, plugin = {} })
    h.assert_true(ok3, "both deps present → construction succeeds")
end
