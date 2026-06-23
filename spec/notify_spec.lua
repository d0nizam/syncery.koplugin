-- =============================================================================
-- spec/notify_spec.lua
-- =============================================================================
--
-- Phase 14.4a — the notification tier system + e-ink toast queue
-- (syncery_ui/notify.lua). No KOReader widgets are involved: a fake scheduler
-- lets us drive time by hand, and a recording present/dismiss pair lets us
-- assert ordering, the inter-toast gap, tap-vs-timeout outcomes, and that a
-- broken present() can't stall the queue.
-- =============================================================================


local h = require("spec.test_helpers")

package.loaded["syncery_ui/notify"] = nil
local Notify = require("syncery_ui/notify")


-- A controllable test environment.
local function make_env(opts)
    opts = opts or {}
    local rec = {
        sched   = {},     -- { {fn, secs, active}, ... }
        shown   = {},     -- { {item, on_tap, dismissed}, ... }
        logs    = {},
    }
    local deps = {
        scheduleIn = function(secs, fn)
            local task = { fn = fn, secs = secs, active = true }
            rec.sched[#rec.sched + 1] = task
            return task
        end,
        unschedule = function(task)
            if task then task.active = false end
        end,
        present = function(item, on_tap)
            if opts.break_present then error("boom") end
            local record = { item = item, on_tap = on_tap, dismissed = false }
            rec.shown[#rec.shown + 1] = record
            return record
        end,
        dismiss = function(handle)
            if handle then handle.dismissed = true end
        end,
        log = function(msg) rec.logs[#rec.logs + 1] = msg end,
    }
    -- Fire the most recently scheduled still-active task (drives the
    -- sequential timeout -> gap -> next-timeout flow).
    rec.fire_last = function()
        for i = #rec.sched, 1, -1 do
            local t = rec.sched[i]
            if t.active then t.active = false; t.fn(); return true end
        end
        return false
    end
    -- Fire a specific task regardless of active state (to test stale safety).
    rec.fire = function(task) task.fn() end
    return Notify.new(deps), rec
end


-- --- L1: silent, log only -----------------------------------------------------
do
    local n, rec = make_env()
    n:l1("did a routine thing")
    h.assert_equal(#rec.shown, 0, "L1: shows no toast")
    h.assert_equal(#rec.sched, 0, "L1: schedules nothing")
    h.assert_equal(rec.logs[1], "did a routine thing", "L1: writes a log line")
end


-- --- L2: a single toast, auto-dismiss ----------------------------------------
do
    local n, rec = make_env()
    local timed_out = 0
    n:l2("Rescan triggered", { on_timeout = function() timed_out = timed_out + 1 end })
    h.assert_equal(#rec.shown, 1, "L2: one toast shown immediately")
    h.assert_equal(rec.shown[1].item.text, "Rescan triggered", "L2: carries the text")
    h.assert_equal(rec.shown[1].item.seconds, Notify.DISPLAY_SECONDS,
        "L2: uses the default display time")
    h.assert_equal(n:pending(), 0, "L2: nothing else queued")

    rec.fire_last()  -- the display timeout
    h.assert_true(rec.shown[1].dismissed, "L2: toast dismissed after its spell")
    h.assert_equal(timed_out, 1, "L2: on_timeout ran")
end


-- --- L2 with a tappable action -----------------------------------------------
do
    local n, rec = make_env()
    local acted, timed = 0, 0
    n:l2("Jumped — undo?", {
        action     = { label = "Undo", fn = function() acted = acted + 1 end },
        on_timeout = function() timed = timed + 1 end,
    })
    rec.shown[1].on_tap()  -- user taps Undo
    h.assert_equal(acted, 1, "L2 action: tap runs the action fn")
    h.assert_equal(timed, 0, "L2 action: tap suppresses on_timeout")
    h.assert_true(rec.shown[1].dismissed, "L2 action: toast dismissed on tap")

    -- The now-stale timeout firing must do nothing.
    local timeout_task = rec.sched[1]
    rec.fire(timeout_task)
    h.assert_equal(timed, 0, "L2 action: stale timeout is inert")
    h.assert_equal(acted, 1, "L2 action: action not run twice")
end


-- --- queue: two toasts are serialised with a gap -----------------------------
do
    local n, rec = make_env()
    n:l2("first")
    n:l2("second")
    h.assert_equal(#rec.shown, 1, "queue: only the first toast is on screen")
    h.assert_equal(n:pending(), 1, "queue: the second is waiting")

    rec.fire_last()  -- first's display timeout -> dismiss + schedule gap
    h.assert_equal(#rec.shown, 1, "queue: second not shown during the gap")
    h.assert_true(rec.shown[1].dismissed, "queue: first dismissed")
    -- The just-scheduled task should be the GAP, not a display spell.
    local gap_task
    for i = #rec.sched, 1, -1 do if rec.sched[i].active then gap_task = rec.sched[i]; break end end
    h.assert_equal(gap_task.secs, Notify.GAP_SECONDS, "queue: a gap is scheduled before the next")

    rec.fire_last()  -- the gap -> show second
    h.assert_equal(#rec.shown, 2, "queue: second shown after the gap")
    h.assert_equal(rec.shown[2].item.text, "second", "queue: order preserved (FIFO)")
    h.assert_equal(n:pending(), 0, "queue: drained")

    rec.fire_last()  -- second's timeout -> dismiss, queue empty, stop
    h.assert_true(rec.shown[2].dismissed, "queue: second dismissed")
end


-- --- invite jumps to the FRONT of the queue ----------------------------------
do
    local n, rec = make_env()
    n:l2("status A")            -- shown now
    n:l2("status B")            -- queued behind A
    n:invite({ text = "Device moved — Jump?",
               action = { label = "Jump", fn = function() end } })
    h.assert_equal(n:pending(), 2, "invite: two items waiting behind the on-screen one")

    rec.fire_last()  -- A's timeout -> gap
    rec.fire_last()  -- gap -> show next: should be the INVITE, not B
    h.assert_equal(rec.shown[2].item.text, "Device moved — Jump?",
        "invite: shown before the older queued status toast")
    h.assert_equal(rec.shown[2].item.seconds, Notify.INTERACTIVE_SECONDS,
        "invite: lingers for the interactive duration")
    h.assert_true(rec.shown[2].item.interactive, "invite: flagged interactive")
end


-- --- a broken present() must not stall the queue -----------------------------
do
    local n, rec = make_env({ break_present = true })
    n:l2("will fail to render")
    n:l2("should still get its turn")
    -- present threw for the first item; the display timeout was still scheduled.
    h.assert_equal(#rec.shown, 0, "broken present: nothing recorded as shown")
    h.assert_true(#rec.sched >= 1, "broken present: a timeout was still scheduled")

    rec.fire_last()  -- first's timeout -> finish (dismiss no-op) + gap
    rec.fire_last()  -- gap -> attempt the second
    -- present still throws (env-wide), but the point is the queue advanced
    -- without raising out of fire().
    h.assert_equal(n:pending(), 0, "broken present: queue still drains, no stall")
end


-- --- module-level singleton API ----------------------------------------------
do
    local logged = {}
    Notify.configure({
        scheduleIn = function(_, _) return {} end,
        unschedule = function() end,
        present    = function() return {} end,
        dismiss    = function() end,
        log        = function(m) logged[#logged + 1] = m end,
    })
    Notify.notifyL1("singleton silent")
    h.assert_equal(logged[1], "singleton silent", "singleton: Notify.notifyL1 routes to the default instance")
    -- l2 / invite on the singleton should not error with a configured default.
    Notify.notifyL2("singleton toast")
    Notify.notifyInvite({ text = "singleton invite" })
    h.assert_true(true, "singleton: notifyL2/notifyInvite run without error")
end


-- --- stop(): teardown cancels the on-screen toast + its auto-dismiss ----------
do
    local n, rec = make_env()
    n:l2("on screen now")
    h.assert_equal(#rec.shown, 1, "stop: a toast is on screen")
    local timeout_task = rec.sched[#rec.sched]
    h.assert_true(timeout_task.active, "stop: its auto-dismiss is armed")

    n:stop()
    h.assert_true(not timeout_task.active, "stop: the auto-dismiss timeout is cancelled")
    h.assert_true(rec.shown[1].dismissed, "stop: the on-screen toast is dismissed")
    h.assert_equal(n:pending(), 0, "stop: the queue is emptied")

    -- A late enqueue after teardown must be a no-op (no new toast, no schedule).
    local shown_before, sched_before = #rec.shown, #rec.sched
    n:l2("arrives after teardown")
    h.assert_equal(#rec.shown, shown_before, "stop: a late toast is not shown")
    h.assert_equal(#rec.sched, sched_before, "stop: a late toast schedules nothing")

    -- The cancelled timeout firing (stale) must do nothing harmful.
    rec.fire(timeout_task)
    h.assert_equal(#rec.shown, shown_before, "stop: a stale timeout fire is inert")
end


-- --- stop(): teardown cancels a pending gap drain (the off-slot leak) ---------
do
    local n, rec = make_env()
    n:l2("first")
    n:l2("second")             -- queued behind first
    rec.fire_last()            -- first's timeout -> dismiss + schedule the gap
    local gap_task
    for i = #rec.sched, 1, -1 do if rec.sched[i].active then gap_task = rec.sched[i]; break end end
    h.assert_equal(gap_task.secs, Notify.GAP_SECONDS, "stop/gap: a gap drain is armed")

    n:stop()
    h.assert_true(not gap_task.active, "stop/gap: the pending gap drain is cancelled")

    -- Firing the cancelled gap (stale) must NOT surface the second toast.
    local shown_before = #rec.shown
    rec.fire(gap_task)
    h.assert_equal(#rec.shown, shown_before, "stop/gap: a stale gap fire shows nothing")
    h.assert_equal(n:pending(), 0, "stop/gap: the queue is emptied")
end


-- --- stopAll(): the module-level teardown hook drives the singleton -----------
do
    Notify.configure({
        scheduleIn = function(secs, fn) return { fn = fn, secs = secs, active = true } end,
        unschedule = function(t) if t then t.active = false end end,
        present    = function() return { dismissed = false } end,
        dismiss    = function(handle) if handle then handle.dismissed = true end end,
        log        = function() end,
    })
    Notify.notifyL2("a")
    Notify.notifyL2("b")       -- one on screen, one queued
    h.assert_true(Notify._default:pending() >= 1, "stopAll: something is queued before teardown")

    Notify.stopAll()
    h.assert_equal(Notify._default:pending(), 0, "stopAll: the singleton's queue is emptied")
    h.assert_true(Notify._default.stopped, "stopAll: the singleton is latched stopped")

    Notify.notifyL2("late")    -- a late module-level enqueue is a no-op
    h.assert_equal(Notify._default:pending(), 0, "stopAll: a late toast stays out of the queue")
end
