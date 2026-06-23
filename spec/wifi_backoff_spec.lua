-- =============================================================================
-- spec/wifi_backoff_spec.lua
-- =============================================================================
--
-- Tests for syncery_lifecycle/wifi_backoff.lua (Phase 7.2).
--
-- The whole point of the module's injected-dependency design is that
-- the backoff curve and the absolute-timeout race are testable WITHOUT
-- wall-clock waiting.  These tests drive it with make_fake_clock +
-- make_fake_scheduler from spec/test_helpers: advance the fake clock,
-- run due tasks, assert exactly which delays were scheduled and when
-- the action ran.
--
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_wifi_backoff_spec_" .. tostring(os.time()))

local WifiBackoff = require("syncery_lifecycle/wifi_backoff")


-- ----------------------------------------------------------------------------
-- Helper: a controllable online-state stub.
-- ----------------------------------------------------------------------------


local function make_online_stub(initial)
    local online = initial and true or false
    return {
        probe   = function() return online end,
        set     = function(v) online = v and true or false end,
    }
end


-- ----------------------------------------------------------------------------
-- Helper: a scheduler that ALSO records each delay it was handed, so a
-- test can assert the backoff curve directly.  Wraps make_fake_scheduler.
-- ----------------------------------------------------------------------------


local function make_recording_scheduler(clock)
    local inner  = h.make_fake_scheduler(clock)
    local delays = {}
    return {
        schedule      = function(delay, fn)
            table.insert(delays, delay)
            inner.schedule(delay, fn)
        end,
        run_due       = inner.run_due,
        run_all       = inner.run_all,
        pending_count = inner.pending_count,
        delays        = delays,
    }
end


-- ----------------------------------------------------------------------------
-- Online: the action runs immediately, nothing is scheduled
-- ----------------------------------------------------------------------------


do
    local clock = h.make_fake_clock(1000)
    local sched = make_recording_scheduler(clock)
    local net   = make_online_stub(true)

    local backoff = WifiBackoff.new{
        scheduler = sched.schedule,
        clock     = clock.now,
        is_online = net.probe,
    }

    local ran = 0
    local outcome = backoff:attempt{ run = function() ran = ran + 1 end }

    h.assert_equal(outcome, "ran",          "online attempt reports 'ran'")
    h.assert_equal(ran, 1,                  "action ran immediately")
    h.assert_equal(sched.pending_count(), 0, "nothing scheduled when online")
    h.assert_false(backoff:is_in_flight(),  "no retry effort in flight")
end


-- ----------------------------------------------------------------------------
-- Offline then online: action deferred, runs on the first retry tick
-- ----------------------------------------------------------------------------


do
    local clock = h.make_fake_clock(1000)
    local sched = make_recording_scheduler(clock)
    local net   = make_online_stub(false)

    local backoff = WifiBackoff.new{
        scheduler = sched.schedule,
        clock     = clock.now,
        is_online = net.probe,
    }

    local ran = 0
    local outcome = backoff:attempt{ run = function() ran = ran + 1 end }

    h.assert_equal(outcome, "scheduled",    "offline attempt reports 'scheduled'")
    h.assert_equal(ran, 0,                  "action does NOT run while offline")
    h.assert_true(backoff:is_in_flight(),   "a retry effort is in flight")
    h.assert_equal(sched.delays[1], WifiBackoff.DEFAULT_INITIAL_DELAY,
        "first retry uses the initial delay (3s)")

    -- WiFi comes back; advance to the first retry's deadline.
    net.set(true)
    clock.advance(WifiBackoff.DEFAULT_INITIAL_DELAY)
    sched.run_due()

    h.assert_equal(ran, 1,                  "action ran once WiFi was back")
    h.assert_false(backoff:is_in_flight(),  "retry effort finished after success")
end


-- ----------------------------------------------------------------------------
-- The backoff CURVE: delays double, capped at max_delay
-- ----------------------------------------------------------------------------


do
    local clock = h.make_fake_clock(0)
    local sched = make_recording_scheduler(clock)
    local net   = make_online_stub(false)   -- stays offline the whole time

    local backoff = WifiBackoff.new{
        scheduler = sched.schedule,
        clock     = clock.now,
        is_online = net.probe,
    }

    -- A long absolute timeout so the curve, not the timeout, is what
    -- this test observes.  initial 3, mult 2, cap 60.
    backoff:attempt{
        run              = function() end,
        initial_delay    = 3,
        multiplier       = 2,
        max_delay        = 60,
        absolute_timeout = 100000,
    }

    -- Drive seven ticks: step the clock forward by each scheduled
    -- delay in turn and run the due task.  Each tick stays offline,
    -- so each reschedules with the next (doubled, then capped) delay.
    for i = 1, 7 do
        clock.advance(sched.delays[i])
        sched.run_due()
    end

    -- delays[1] is the initial arm; delays[2..7] are the reschedules.
    h.assert_equal(sched.delays[1], 3,   "delay 1 = 3s (initial)")
    h.assert_equal(sched.delays[2], 6,   "delay 2 = 6s (doubled)")
    h.assert_equal(sched.delays[3], 12,  "delay 3 = 12s")
    h.assert_equal(sched.delays[4], 24,  "delay 4 = 24s")
    h.assert_equal(sched.delays[5], 48,  "delay 5 = 48s")
    h.assert_equal(sched.delays[6], 60,  "delay 6 = 60s (capped, not 96)")
    h.assert_equal(sched.delays[7], 60,  "delay 7 = 60s (stays at cap)")
end


-- ----------------------------------------------------------------------------
-- The ABSOLUTE TIMEOUT: the effort gives up; the action never runs
-- ----------------------------------------------------------------------------


do
    local clock = h.make_fake_clock(5000)
    local sched = make_recording_scheduler(clock)
    local net   = make_online_stub(false)   -- never comes back

    local backoff = WifiBackoff.new{
        scheduler = sched.schedule,
        clock     = clock.now,
        is_online = net.probe,
    }

    local ran = 0
    backoff:attempt{
        run              = function() ran = ran + 1 end,
        initial_delay    = 3,
        multiplier       = 2,
        max_delay        = 60,
        absolute_timeout = 30,   -- short window
    }

    -- Drive ticks until the scheduler drains.  Each tick is still
    -- offline; once a tick fires past the 30s deadline it finishes the
    -- effort instead of rescheduling.  Step the clock by the most
    -- recently scheduled delay each time.
    local guard = 0
    while sched.pending_count() > 0 and guard < 50 do
        guard = guard + 1
        local next_delay = sched.delays[#sched.delays]
        clock.advance(next_delay)
        sched.run_due()
    end

    h.assert_equal(ran, 0,                 "action never ran — offline past the timeout")
    h.assert_false(backoff:is_in_flight(), "effort finished (gave up) after the timeout")
    h.assert_equal(sched.pending_count(), 0, "no retry left armed after giving up")
end


-- ----------------------------------------------------------------------------
-- Re-entrancy: a second attempt while one is in flight is dropped
-- ----------------------------------------------------------------------------


do
    local clock = h.make_fake_clock(0)
    local sched = make_recording_scheduler(clock)
    local net   = make_online_stub(false)

    local backoff = WifiBackoff.new{
        scheduler = sched.schedule,
        clock     = clock.now,
        is_online = net.probe,
    }

    local first  = backoff:attempt{ run = function() end }
    local second = backoff:attempt{ run = function() end }

    h.assert_equal(first,  "scheduled", "first offline attempt schedules")
    h.assert_equal(second, "busy",      "second attempt while in flight is dropped")
    h.assert_equal(sched.pending_count(), 1,
        "only one retry loop armed despite two attempts")
end


-- ----------------------------------------------------------------------------
-- After an effort finishes, a fresh attempt is accepted again
-- ----------------------------------------------------------------------------


do
    local clock = h.make_fake_clock(0)
    local sched = make_recording_scheduler(clock)
    local net   = make_online_stub(false)

    local backoff = WifiBackoff.new{
        scheduler = sched.schedule,
        clock     = clock.now,
        is_online = net.probe,
    }

    backoff:attempt{ run = function() end, initial_delay = 3 }
    -- WiFi returns; first tick runs + finishes the effort.
    net.set(true)
    clock.advance(3)
    sched.run_due()
    h.assert_false(backoff:is_in_flight(), "first effort finished")

    -- A new attempt — now online — runs immediately.
    local ran = 0
    local outcome = backoff:attempt{ run = function() ran = ran + 1 end }
    h.assert_equal(outcome, "ran", "fresh attempt accepted after prior effort ended")
    h.assert_equal(ran, 1,         "and it ran")
end


-- ----------------------------------------------------------------------------
-- wake_network: called on a still-offline retry, best-effort
-- ----------------------------------------------------------------------------


do
    local clock = h.make_fake_clock(0)
    local sched = make_recording_scheduler(clock)
    local net   = make_online_stub(false)

    local network_wakes = 0
    local backoff = WifiBackoff.new{
        scheduler    = sched.schedule,
        clock        = clock.now,
        is_online    = net.probe,
        wake_network = function() network_wakes = network_wakes + 1 end,
    }

    backoff:attempt{
        run              = function() end,
        initial_delay    = 3,
        absolute_timeout = 100,
    }

    -- One still-offline retry tick.
    clock.advance(3)
    sched.run_due()
    h.assert_true(network_wakes >= 1,
        "wake_network nudged on a still-offline retry tick")

    -- A raising wake_network must not break the loop (it's pcall'd).
    local clock2 = h.make_fake_clock(0)
    local sched2 = make_recording_scheduler(clock2)
    local net2   = make_online_stub(false)
    local backoff2 = WifiBackoff.new{
        scheduler    = sched2.schedule,
        clock        = clock2.now,
        is_online    = net2.probe,
        wake_network = function() error("platform refused") end,
    }
    backoff2:attempt{ run = function() end, initial_delay = 3, absolute_timeout = 100 }
    clock2.advance(3)
    local ok = pcall(sched2.run_due)
    h.assert_true(ok, "a raising wake_network does not crash the retry loop")
    h.assert_true(backoff2:is_in_flight(), "loop still alive after wake_network raised")
end


-- ----------------------------------------------------------------------------
-- A raising action does not crash the scheduler (pcall isolation)
-- ----------------------------------------------------------------------------


do
    local clock = h.make_fake_clock(0)
    local sched = make_recording_scheduler(clock)
    local net   = make_online_stub(true)   -- online: action runs inline

    local backoff = WifiBackoff.new{
        scheduler = sched.schedule,
        clock     = clock.now,
        is_online = net.probe,
    }

    local ok = pcall(function()
        backoff:attempt{ run = function() error("action blew up") end }
    end)
    h.assert_true(ok, "a raising action is pcall-isolated, attempt() does not throw")
end


-- ----------------------------------------------------------------------------
-- Constructor validation
-- ----------------------------------------------------------------------------


do
    local clock = h.make_fake_clock(0)
    local ok_no_sched = pcall(WifiBackoff.new, {
        is_online = function() return true end,
    })
    h.assert_false(ok_no_sched, "constructor requires a scheduler")

    local ok_no_online = pcall(WifiBackoff.new, {
        scheduler = function() end,
    })
    h.assert_false(ok_no_online, "constructor requires is_online")
end


-- ----------------------------------------------------------------------------
-- Report
-- ----------------------------------------------------------------------------

h.report("wifi_backoff_spec")
