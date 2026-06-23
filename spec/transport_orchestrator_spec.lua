-- =============================================================================
-- spec/transport_orchestrator_spec.lua
-- =============================================================================
--
-- End-to-end tests for syncery_transports/orchestrator.lua.
--
-- The orchestrator's job is to wire Policy decisions to Transport
-- executions, owning the state that bridges them.  These tests
-- exercise that wiring: a fake clock, a fake scheduler, and fake
-- transports — every dependency injected.  No KOReader code is
-- loaded by these tests.
--
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_orchestrator_spec_" .. tostring(os.time()))

local Orchestrator = require("syncery_transports/orchestrator")
local Interface    = require("syncery_transports/interface")
local Policy       = require("syncery_transports/policy")


-- ----------------------------------------------------------------------------
-- Small helper: build a fresh orchestrator with N fake transports and
-- a controllable clock + scheduler.  Returns { orch, clock, sched,
-- transports }.
-- ----------------------------------------------------------------------------


local function make_orch(opts)
    opts = opts or {}
    local clock = h.make_fake_clock(opts.start_time or 1000)
    local sched = h.make_fake_scheduler(clock)

    local transports = {}
    for _, spec in ipairs(opts.transports or { { id = "fake" } }) do
        transports[#transports + 1] = h.make_fake_transport(spec)
    end

    local orch, err = Orchestrator.new({
        transports     = transports,
        clock          = clock.now,
        scheduler      = sched.schedule,
        policy_config  = opts.policy_config,
        on_status_change = opts.on_status_change,
    })
    assert(orch, "make_orch: orchestrator construction failed: " .. tostring(err))
    return { orch = orch, clock = clock, sched = sched, transports = transports }
end


-- ----------------------------------------------------------------------------
-- Construction: validation rejects garbage transports loudly.
-- ----------------------------------------------------------------------------


do
    local orch, err = Orchestrator.new({
        transports = { "this is not a transport" },
    })
    h.assert_nil(orch,              "non-table transport => nil")
    h.assert_true(err ~= nil,       "error string returned")
    h.assert_true(tostring(err):match("not a valid Transport") ~= nil,
        "error mentions invalid transport")
end


do
    -- A table missing required methods is also rejected.
    local broken = { id = function() return "x" end }
    local orch, err = Orchestrator.new({ transports = { broken } })
    h.assert_nil(orch, "incomplete transport => nil")
    h.assert_true(err ~= nil, "error string returned")
end


do
    -- Duplicate ids are rejected — orchestrator keys state by id, so
    -- duplicates would silently corrupt each other's state.
    local a = h.make_fake_transport({ id = "dup" })
    local b = h.make_fake_transport({ id = "dup" })
    local orch, err = Orchestrator.new({ transports = { a, b } })
    h.assert_nil(orch, "duplicate ids rejected")
    h.assert_true(tostring(err):match("duplicate") ~= nil,
        "error mentions duplicate")
end


do
    -- Zero transports is allowed (warned but not an error).  This is
    -- the degenerate case for fresh installs that haven't configured
    -- anything yet.
    local orch = Orchestrator.new({ transports = {} })
    h.assert_true(orch ~= nil, "zero transports is allowed")
end


-- ----------------------------------------------------------------------------
-- push_book on a fresh state: every available transport is called.
-- ----------------------------------------------------------------------------


do
    local ctx = make_orch({
        transports = {
            { id = "a", initial_available = true  },
            { id = "b", initial_available = true  },
            { id = "c", initial_available = false },   -- skipped
        },
    })

    ctx.orch:push_book("/books/x.epub", { payload = "hello" })

    h.assert_equal(ctx.transports[1].push_call_count("/books/x.epub"), 1,
        "available transport 'a' was pushed")
    h.assert_equal(ctx.transports[2].push_call_count("/books/x.epub"), 1,
        "available transport 'b' was pushed")
    h.assert_equal(ctx.transports[3].push_call_count("/books/x.epub"), 0,
        "unavailable transport 'c' was skipped")
end


-- ----------------------------------------------------------------------------
-- Debounce: a second push within debounce window is suppressed.
-- ----------------------------------------------------------------------------


do
    local ctx = make_orch({
        transports = { { id = "fake" } },
        policy_config = { fake = { debounce_seconds = 30, retry_schedule = { 5 } } },
    })

    ctx.orch:push_book("/books/x.epub", { payload = "1" })
    h.assert_equal(ctx.transports[1].push_call_count("/books/x.epub"), 1,
        "first push goes through")

    -- 10s later — still within the 30s window.
    ctx.clock.advance(10)
    ctx.orch:push_book("/books/x.epub", { payload = "2" })
    h.assert_equal(ctx.transports[1].push_call_count("/books/x.epub"), 1,
        "second push within debounce window suppressed")

    -- Past the window.
    ctx.clock.advance(25)
    ctx.orch:push_book("/books/x.epub", { payload = "3" })
    h.assert_equal(ctx.transports[1].push_call_count("/books/x.epub"), 2,
        "push past debounce window proceeds")
end


-- ----------------------------------------------------------------------------
-- The force flag bypasses debounce.  Used for the "Sync Now" button.
-- ----------------------------------------------------------------------------


do
    local ctx = make_orch({
        transports = { { id = "fake" } },
        policy_config = { fake = { debounce_seconds = 60, retry_schedule = { 5 } } },
    })

    ctx.orch:push_book("/books/x.epub", { payload = "1" })
    h.assert_equal(ctx.transports[1].push_call_count("/books/x.epub"), 1,
        "first push goes through")

    ctx.orch:push_book("/books/x.epub", { payload = "2" }, { force = true })
    h.assert_equal(ctx.transports[1].push_call_count("/books/x.epub"), 2,
        "forced push bypasses debounce")
end


-- ----------------------------------------------------------------------------
-- Transient error → retry per the schedule.
-- ----------------------------------------------------------------------------


do
    local ctx = make_orch({
        transports = { { id = "fake" } },
        policy_config = { fake = {
            debounce_seconds = 0,                    -- no debounce in test
            retry_schedule   = { 5, 15, 30 },
        }},
    })
    -- First attempt: transient failure.
    ctx.transports[1].set_error_on_push(Interface.ERRORS.UNREACHABLE)
    ctx.orch:push_book("/books/x.epub", { payload = "x" })
    h.assert_equal(ctx.transports[1].push_call_count("/books/x.epub"), 1,
        "first attempt called")

    local state1 = ctx.orch:peek_state("fake", "/books/x.epub")
    h.assert_equal(state1.consecutive_failures, 1, "failure counter at 1")
    h.assert_true(state1.pending_retry_at ~= nil, "retry scheduled")
    h.assert_equal(state1.last_error_class, Policy.CLASS_TRANSIENT,
        "error classified as transient")

    -- Advance just past the first retry slot.
    ctx.clock.advance(5)
    ctx.sched.run_due()
    h.assert_equal(ctx.transports[1].push_call_count("/books/x.epub"), 2,
        "second attempt fired after schedule[1]=5s")

    -- Still failing — second retry at +15s.
    ctx.clock.advance(15)
    ctx.sched.run_due()
    h.assert_equal(ctx.transports[1].push_call_count("/books/x.epub"), 3,
        "third attempt fired after schedule[2]=15s")

    -- Now succeed — counter resets.
    ctx.transports[1].set_error_on_push(nil)
    ctx.clock.advance(30)
    ctx.sched.run_due()
    h.assert_equal(ctx.transports[1].push_call_count("/books/x.epub"), 4,
        "fourth attempt fired")
    local state_final = ctx.orch:peek_state("fake", "/books/x.epub")
    h.assert_equal(state_final.consecutive_failures, 0,
        "success resets failure counter")
    h.assert_nil(state_final.last_error_class,
        "success clears last error class")
end


-- ----------------------------------------------------------------------------
-- A retry scheduled while the transport was available must NOT fire once the
-- transport has gone unavailable (toggle off) before its slot.  push_book
-- gates fresh pushes on is_available(); without the same gate on the
-- scheduled retry a disabled transport keeps probing forever.  The dropped
-- retry must also leave the backoff state untouched (no clearing), so the
-- counters Policy.should_attempt reads survive a disable.
-- ----------------------------------------------------------------------------


do
    local ctx = make_orch({
        transports = { { id = "fake" } },
        policy_config = { fake = {
            debounce_seconds = 0,
            retry_schedule   = { 5, 15, 30 },
        }},
    })
    -- First attempt fails transiently → a retry is queued at +5s.
    ctx.transports[1].set_error_on_push(Interface.ERRORS.UNREACHABLE)
    ctx.orch:push_book("/books/x.epub", { payload = "x" })
    h.assert_equal(ctx.transports[1].push_call_count("/books/x.epub"), 1,
        "first attempt called")

    local state_before = ctx.orch:peek_state("fake", "/books/x.epub")
    local cf_before    = state_before.consecutive_failures
    local pra_before   = state_before.pending_retry_at
    h.assert_equal(cf_before, 1, "failure counter at 1 before disable")
    h.assert_true(pra_before ~= nil, "retry scheduled before disable")

    -- User disables the transport (toggle off) before the retry slot.
    ctx.transports[1].set_available(false)

    -- Fire the due retry: it must observe is_available()=false and drop.
    ctx.clock.advance(5)
    ctx.sched.run_due()
    h.assert_equal(ctx.transports[1].push_call_count("/books/x.epub"), 1,
        "disabled-transport retry did NOT re-attempt the push")
    h.assert_equal(ctx.sched.pending_count(), 0,
        "dropped retry did NOT reschedule (chain dies)")

    -- The drop touched no backoff state: the same counters survive, so a
    -- later re-enable carries the backoff rather than resetting it.
    local state_after = ctx.orch:peek_state("fake", "/books/x.epub")
    h.assert_equal(state_after.consecutive_failures, cf_before,
        "drop left consecutive_failures intact (backoff preserved)")
    h.assert_equal(state_after.pending_retry_at, pra_before,
        "drop left pending_retry_at intact (backoff preserved)")
end


-- ----------------------------------------------------------------------------
-- Permanent error → no retry.
-- ----------------------------------------------------------------------------


do
    local ctx = make_orch({
        transports = { { id = "fake" } },
        policy_config = { fake = { debounce_seconds = 0, retry_schedule = { 5 } } },
    })
    ctx.transports[1].set_error_on_push(Interface.ERRORS.REJECTED)

    ctx.orch:push_book("/books/x.epub", {})
    h.assert_equal(ctx.transports[1].push_call_count("/books/x.epub"), 1,
        "first attempt fired")

    -- No retry should be scheduled.  Advancing time and running due
    -- tasks should NOT trigger another attempt.
    ctx.clock.advance(60)
    ctx.sched.run_due()
    h.assert_equal(ctx.transports[1].push_call_count("/books/x.epub"), 1,
        "no retry for permanent error")

    local state = ctx.orch:peek_state("fake", "/books/x.epub")
    h.assert_equal(state.last_error_class, Policy.CLASS_PERMANENT,
        "error classified as permanent")
end


-- ----------------------------------------------------------------------------
-- Config error → no retry, status reports needs-attention class.
-- ----------------------------------------------------------------------------


do
    local ctx = make_orch({
        transports = { { id = "fake" } },
        policy_config = { fake = { debounce_seconds = 0, retry_schedule = { 5 } } },
    })
    ctx.transports[1].set_error_on_push(Interface.ERRORS.AUTH_FAILED)

    ctx.orch:push_book("/books/x.epub", {})
    h.assert_equal(ctx.transports[1].push_call_count("/books/x.epub"), 1,
        "attempt fired")

    ctx.clock.advance(60)
    ctx.sched.run_due()
    h.assert_equal(ctx.transports[1].push_call_count("/books/x.epub"), 1,
        "no retry for config error")

    local status = ctx.orch:get_status()
    h.assert_equal(status.fake.orch_last_error_class, Policy.CLASS_CONFIG_NEEDED,
        "status surfaces config_needed class for the UI")
end


-- ----------------------------------------------------------------------------
-- Schedule exhaustion → give up.
-- ----------------------------------------------------------------------------


do
    local ctx = make_orch({
        transports = { { id = "fake" } },
        policy_config = { fake = { debounce_seconds = 0, retry_schedule = { 5 } } },
    })
    ctx.transports[1].set_error_on_push(Interface.ERRORS.UNREACHABLE)

    ctx.orch:push_book("/books/x.epub", {})
    h.assert_equal(ctx.transports[1].push_call_count("/books/x.epub"), 1, "1st")

    ctx.clock.advance(5)
    ctx.sched.run_due()
    h.assert_equal(ctx.transports[1].push_call_count("/books/x.epub"), 2,
        "2nd attempt after the only schedule slot")

    -- Schedule has only one entry — no more retries should be scheduled.
    ctx.clock.advance(60)
    ctx.sched.run_due()
    h.assert_equal(ctx.transports[1].push_call_count("/books/x.epub"), 2,
        "no further attempts after exhaustion")
end


-- ----------------------------------------------------------------------------
-- A transport that throws (raises a Lua error) is contained.  The
-- orchestrator doesn't crash; the throw becomes an INTERNAL error.
-- ----------------------------------------------------------------------------


do
    local thrower = {
        id                       = function() return "thrower" end,
        display_name             = function() return "Thrower" end,
        is_available             = function() return true end,
        is_eventually_consistent = function() return false end,
        push                     = function() error("kaboom") end,
        pull                     = function(_, _, cb) cb(true, nil, nil) end,
        status                   = function() return {
            display_name = "Thrower", available = true, summary = "ok"
        } end,
    }

    local clock = h.make_fake_clock(1000)
    local sched = h.make_fake_scheduler(clock)
    local orch  = Orchestrator.new({
        transports = { thrower },
        clock      = clock.now,
        scheduler  = sched.schedule,
        policy_config = { thrower = { debounce_seconds = 0, retry_schedule = { 5 } } },
    })

    -- Calling push_book should not raise; the thrown error becomes
    -- an INTERNAL failure that goes through the normal retry path.
    local ok = pcall(orch.push_book, orch, "/books/x.epub", {})
    h.assert_true(ok, "orchestrator contained the throw")

    local state = orch:peek_state("thrower", "/books/x.epub")
    h.assert_equal(state.consecutive_failures, 1, "thrown error counts as failure")
    h.assert_equal(state.last_error_class, Policy.CLASS_TRANSIENT,
        "INTERNAL classified as transient (caller can retry)")
end


-- ----------------------------------------------------------------------------
-- pull_book aggregates per-transport results into a single callback.
-- ----------------------------------------------------------------------------


do
    local ctx = make_orch({
        transports = {
            { id = "a" },
            { id = "b" },
        },
    })
    -- "Pre-push" so the in-memory fake has something to return.
    ctx.transports[1].push("/books/x.epub", { payload = "from-a" }, function() end)
    ctx.transports[2].push("/books/x.epub", { payload = "from-b" }, function() end)

    local got
    ctx.orch:pull_book("/books/x.epub", {}, function(results) got = results end)

    h.assert_true(got ~= nil,                  "callback fired")
    h.assert_true(got.a ~= nil,                "a present")
    h.assert_true(got.a.ok,                    "a ok")
    h.assert_equal(got.a.payload, "from-a",     "a payload")
    h.assert_true(got.b ~= nil,                "b present")
    h.assert_equal(got.b.payload, "from-b",     "b payload")
end


-- ----------------------------------------------------------------------------
-- pull_book with no available transports fires callback with empty table.
-- ----------------------------------------------------------------------------


do
    local ctx = make_orch({
        transports = { { id = "x", initial_available = false } },
    })
    local got
    ctx.orch:pull_book("/books/x.epub", {}, function(r) got = r end)
    h.assert_equal(type(got), "table",  "callback fired with a table")
    h.assert_nil(got.x,                  "no entry for unavailable transport")
end


-- ----------------------------------------------------------------------------
-- pull_book with an unavailable transport excludes it from results.
-- ----------------------------------------------------------------------------


do
    local ctx = make_orch({
        transports = {
            { id = "a", initial_available = true  },
            { id = "b", initial_available = false },
        },
    })
    local got
    ctx.orch:pull_book("/books/x.epub", {}, function(r) got = r end)
    h.assert_true(got.a ~= nil, "available transport in results")
    h.assert_nil(got.b,          "unavailable transport not in results")
end


-- ----------------------------------------------------------------------------
-- on_status_change is fired after a push completes (success or fail).
-- The UI hook works.
-- ----------------------------------------------------------------------------


do
    local change_count = 0
    local ctx = make_orch({
        transports       = { { id = "fake" } },
        policy_config    = { fake = { debounce_seconds = 0, retry_schedule = { 5 } } },
        on_status_change = function() change_count = change_count + 1 end,
    })

    ctx.orch:push_book("/books/x.epub", {})
    h.assert_equal(change_count, 1, "status_change fired on success")

    ctx.clock.advance(1)
    ctx.transports[1].set_error_on_push(Interface.ERRORS.UNREACHABLE)
    ctx.orch:push_book("/books/x.epub", {})
    h.assert_equal(change_count, 2, "status_change fired on failure")
end


-- ----------------------------------------------------------------------------
-- get_status reports a row per registered transport, decorated with
-- the orchestrator's view.
-- ----------------------------------------------------------------------------


do
    local ctx = make_orch({
        transports = {
            { id = "a", display_name = "Transport A" },
            { id = "b", display_name = "Transport B" },
        },
    })
    local status = ctx.orch:get_status()
    h.assert_true(status.a ~= nil,                "a present")
    h.assert_equal(status.a.display_name, "Transport A",  "a display_name")
    h.assert_true(status.b ~= nil,                "b present")

    -- Decoration: keys added by the orchestrator are present even
    -- before any push has happened.
    h.assert_nil(status.a.orch_last_error_class,
        "no error before any push")
    h.assert_false(status.a.orch_any_pending_retry,
        "no pending retry before any push")
end


-- ----------------------------------------------------------------------------
-- A transport whose status() raises gets a stub row, not a crash.
-- ----------------------------------------------------------------------------


do
    local bad = {
        id                       = function() return "bad" end,
        display_name             = function() return "Bad" end,
        is_available             = function() return true end,
        is_eventually_consistent = function() return false end,
        push                     = function(_, _, cb) cb(true, nil, nil) end,
        pull                     = function(_, _, cb) cb(true, nil, nil) end,
        status                   = function() error("nope") end,
    }
    local orch = Orchestrator.new({ transports = { bad } })
    local status = orch:get_status()
    h.assert_true(status.bad ~= nil,            "stub row inserted for crashing status()")
    h.assert_false(status.bad.available,        "stub marks unavailable")
    h.assert_equal(type(status.bad.summary), "string",
        "stub has a summary string")
end


-- ----------------------------------------------------------------------------
-- shutdown() cancels pending retries and refuses new pushes.
-- ----------------------------------------------------------------------------


do
    local ctx = make_orch({
        transports = { { id = "fake" } },
        policy_config = { fake = { debounce_seconds = 0, retry_schedule = { 5 } } },
    })
    ctx.transports[1].set_error_on_push(Interface.ERRORS.UNREACHABLE)

    ctx.orch:push_book("/books/x.epub", {})
    h.assert_equal(ctx.transports[1].push_call_count("/books/x.epub"), 1,
        "first attempt fired")
    h.assert_equal(ctx.sched.pending_count(), 1, "one retry pending")

    ctx.orch:shutdown()

    -- The scheduled retry should NOT execute after shutdown.
    ctx.clock.advance(5)
    ctx.sched.run_due()
    h.assert_equal(ctx.transports[1].push_call_count("/books/x.epub"), 1,
        "retry suppressed by shutdown")

    -- New pushes are ignored too.
    ctx.orch:push_book("/books/y.epub", {})
    h.assert_equal(ctx.transports[1].push_call_count("/books/y.epub"), 0,
        "new pushes refused after shutdown")
end


do
    -- Calling shutdown twice is fine.
    local ctx = make_orch({ transports = { { id = "fake" } } })
    ctx.orch:shutdown()
    local ok = pcall(function() ctx.orch:shutdown() end)
    h.assert_true(ok, "double shutdown is a no-op")
end


-- ----------------------------------------------------------------------------
-- Two transports failing differently: per-transport state is isolated.
-- ----------------------------------------------------------------------------


do
    local ctx = make_orch({
        transports = { { id = "a" }, { id = "b" } },
        policy_config = {
            a = { debounce_seconds = 0, retry_schedule = { 5 } },
            b = { debounce_seconds = 0, retry_schedule = { 5 } },
        },
    })
    ctx.transports[1].set_error_on_push(Interface.ERRORS.UNREACHABLE)   -- a: transient
    ctx.transports[2].set_error_on_push(Interface.ERRORS.AUTH_FAILED)   -- b: config

    ctx.orch:push_book("/books/x.epub", {})

    local sa = ctx.orch:peek_state("a", "/books/x.epub")
    local sb = ctx.orch:peek_state("b", "/books/x.epub")
    h.assert_equal(sa.last_error_class, Policy.CLASS_TRANSIENT, "a state: transient")
    h.assert_equal(sb.last_error_class, Policy.CLASS_CONFIG_NEEDED, "b state: config")
    h.assert_true(sa.pending_retry_at ~= nil, "a has a retry scheduled")
    h.assert_nil(sb.pending_retry_at,          "b does NOT (config errors don't retry)")
end


-- ----------------------------------------------------------------------------
-- Per-book state isolation: two books on the same transport don't
-- share counters.
-- ----------------------------------------------------------------------------


do
    local ctx = make_orch({
        transports = { { id = "fake" } },
        policy_config = { fake = { debounce_seconds = 0, retry_schedule = { 5 } } },
    })
    ctx.transports[1].set_error_on_push(Interface.ERRORS.UNREACHABLE)

    ctx.orch:push_book("/books/x.epub", {})
    ctx.orch:push_book("/books/y.epub", {})

    local sx = ctx.orch:peek_state("fake", "/books/x.epub")
    local sy = ctx.orch:peek_state("fake", "/books/y.epub")
    h.assert_equal(sx.consecutive_failures, 1, "x has 1 failure")
    h.assert_equal(sy.consecutive_failures, 1, "y has 1 failure (independent)")
end
