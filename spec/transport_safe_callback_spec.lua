-- =============================================================================
-- spec/transport_safe_callback_spec.lua
-- =============================================================================
--
-- Tests for syncery_transports/safe_callback.lua — the fires-once,
-- pcall-wrapped, optionally-deadlined wrapper that every transport
-- callback flows through.
--
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_safe_callback_spec_" .. tostring(os.time()))

local SafeCallback = require("syncery_transports/safe_callback")


-- ----------------------------------------------------------------------------
-- A nil callback yields a no-op that can be called freely.
-- ----------------------------------------------------------------------------


do
    local once = SafeCallback.once(nil, "test")
    once(true, nil, nil)
    once(false, "err", nil)
    once()
    -- Reaching here without error is the assertion.
    h.assert_true(true, "nil callback yields a callable no-op")
end


-- ----------------------------------------------------------------------------
-- A normal callback fires exactly once with the given args.
-- ----------------------------------------------------------------------------


do
    local got_ok, got_err, got_extra
    local call_count = 0
    local once = SafeCallback.once(function(ok, err, extra)
        call_count = call_count + 1
        got_ok, got_err, got_extra = ok, err, extra
    end, "test")

    once(true, nil, { kind = "payload" })
    h.assert_equal(call_count, 1,              "fired exactly once")
    h.assert_true(got_ok,                       "ok arg passed through")
    h.assert_nil(got_err,                       "err arg passed through")
    h.assert_equal(type(got_extra), "table",    "extra arg passed through")
end


-- ----------------------------------------------------------------------------
-- A second invocation is silently swallowed.  The wrapped callback
-- does NOT see the second call.
-- ----------------------------------------------------------------------------


do
    local call_count = 0
    local once = SafeCallback.once(function() call_count = call_count + 1 end, "test")

    once(true)
    once(false)
    once("anything")

    h.assert_equal(call_count, 1, "subsequent invocations swallowed")
end


-- ----------------------------------------------------------------------------
-- .fired() reflects whether the callback has been invoked.
-- ----------------------------------------------------------------------------


do
    local once = SafeCallback.once(function() end, "test")
    h.assert_false(once.fired(), "not fired initially")
    once(true)
    h.assert_true(once.fired(),  "fired after first call")
    once(false)
    h.assert_true(once.fired(),  "still 'fired' after suppressed second call")
end


-- ----------------------------------------------------------------------------
-- A handler that raises does NOT propagate the error to the caller.
-- The wrapper pcalls it.
-- ----------------------------------------------------------------------------


do
    local once = SafeCallback.once(function() error("boom") end, "test")
    -- Calling it should not throw.
    local ok = pcall(once, true)
    h.assert_true(ok,           "wrapper swallows handler errors")
    h.assert_true(once.fired(), "and counts as fired (so retries don't re-call)")
end


-- ----------------------------------------------------------------------------
-- .cancel() prevents future invocations.
-- ----------------------------------------------------------------------------


do
    local call_count = 0
    local once = SafeCallback.once(function() call_count = call_count + 1 end, "test")

    once.cancel()
    once(true)
    h.assert_equal(call_count, 0, "cancelled before fire => never fires")
end


do
    -- cancel() after firing is a no-op (we don't un-fire).
    local call_count = 0
    local once = SafeCallback.once(function() call_count = call_count + 1 end, "test")

    once(true)
    h.assert_equal(call_count, 1, "fired before cancel")
    once.cancel()
    once(true)
    h.assert_equal(call_count, 1, "cancel after fire doesn't allow refire")
end


-- ----------------------------------------------------------------------------
-- Deadlines: if the wrapped callback hasn't fired by the deadline, the
-- wrapper synthesizes a callback(false, "internal", nil).
-- ----------------------------------------------------------------------------


do
    local clock = h.make_fake_clock(1000)
    local sched = h.make_fake_scheduler(clock)

    local cb_ok, cb_err
    local once = SafeCallback.once(function(ok, err)
        cb_ok, cb_err = ok, err
    end, "test", {
        deadline_seconds = 30,
        scheduler        = sched.schedule,
    })

    -- Time passes, the deadline fires, the callback receives a synthesized failure.
    clock.advance(30)
    sched.run_due()

    h.assert_true(once.fired(),      "deadline expired counts as fired")
    h.assert_true(once.deadline_fired(), "deadline_fired() reports true")
    h.assert_false(cb_ok,            "synthesized failure ok=false")
    h.assert_equal(cb_err, "internal", "synthesized failure err=internal")
end


do
    -- A callback that fires before the deadline cancels the deadline path.
    local clock = h.make_fake_clock(1000)
    local sched = h.make_fake_scheduler(clock)

    local cb_ok
    local once = SafeCallback.once(function(ok) cb_ok = ok end, "test", {
        deadline_seconds = 30,
        scheduler        = sched.schedule,
    })

    once(true)
    h.assert_true(cb_ok, "fired ok before deadline")

    -- Now advance past the deadline.  run_due should fire the deadline
    -- task, but the wrapper sees `fired` already true and bails — the
    -- user's callback is NOT called a second time.
    clock.advance(30)
    sched.run_due()
    h.assert_false(once.deadline_fired(), "deadline did not fire (cb already done)")
end


-- ----------------------------------------------------------------------------
-- The deadline is opt-in: without `deadline_seconds`, nothing is scheduled.
-- ----------------------------------------------------------------------------


do
    local sched_count = 0
    local sched_fn = function(_d, _f) sched_count = sched_count + 1 end
    local _once = SafeCallback.once(function() end, "test", {
        scheduler = sched_fn,
        -- no deadline_seconds
    })
    h.assert_equal(sched_count, 0, "no deadline_seconds => no scheduling")
end


-- ----------------------------------------------------------------------------
-- A wrong type for `callback` is loud (assert).  We want this loud so
-- a typo at the call site doesn't compile-time-equivalent silently.
-- ----------------------------------------------------------------------------


do
    local ok, err = pcall(SafeCallback.once, "not a function", "test")
    h.assert_false(ok,                                "assert fires on bad type")
    h.assert_true(tostring(err):match("function") ~= nil,
        "error message mentions 'function'")
end


do
    -- Empty / nil debug_tag is also rejected.
    local ok = pcall(SafeCallback.once, function() end, "")
    h.assert_false(ok, "empty debug_tag rejected")

    local ok2 = pcall(SafeCallback.once, function() end, nil)
    h.assert_false(ok2, "nil debug_tag rejected")
end
