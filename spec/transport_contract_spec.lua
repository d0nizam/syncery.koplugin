-- =============================================================================
-- spec/transport_contract_spec.lua
-- =============================================================================
--
-- The contract every Syncery transport satisfies.  Exercises a fake
-- transport (h.make_fake_transport) — the same scenarios will later be
-- run against the real Syncthing and Cloud transports built
-- in subsequent Phase 5 chunks.
--
-- Why dogfood with a fake first?  Because if the interface is too
-- awkward to satisfy in a fake (which has no I/O, no network, no
-- daemon, no auth), it'll be much more awkward to satisfy in three
-- real transports.  Writing the fake is the cheapest way to discover
-- "wait, my interface doesn't actually let the caller observe X" or
-- "this method needs to be split into two".
--
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_transport_contract_spec_" .. tostring(os.time()))

local Interface = require("syncery_transports/interface")


-- ----------------------------------------------------------------------------
-- The fake transport itself conforms to the interface.
-- ----------------------------------------------------------------------------


do
    local transport = h.make_fake_transport()
    local ok, problems = Interface.validate_implementation(transport)
    h.assert_true(ok,                  "fake transport passes validate_implementation")
    h.assert_equal(#problems, 0,       "no problems reported for fake")
end


-- ----------------------------------------------------------------------------
-- id() and display_name() return strings; they roundtrip the opts.
-- ----------------------------------------------------------------------------


do
    local transport = h.make_fake_transport({
        id = "fake_x",
        display_name = "Fake Transport X",
    })
    h.assert_equal(transport.id(),           "fake_x",            "id roundtrip")
    h.assert_equal(transport.display_name(), "Fake Transport X",  "display_name roundtrip")
    h.assert_equal(type(transport.id()),           "string",      "id is a string")
    h.assert_equal(type(transport.display_name()), "string",      "display_name is a string")
end


-- ----------------------------------------------------------------------------
-- is_available() reflects the initial flag and the toggle.
-- ----------------------------------------------------------------------------


do
    local transport = h.make_fake_transport({ initial_available = true })
    h.assert_true(transport.is_available(),  "available when initial=true")

    transport.set_available(false)
    h.assert_false(transport.is_available(), "unavailable after toggle false")

    transport.set_available(true)
    h.assert_true(transport.is_available(),  "available again after toggle true")
end


do
    local transport = h.make_fake_transport({ initial_available = false })
    h.assert_false(transport.is_available(), "unavailable when initial=false")
end


-- ----------------------------------------------------------------------------
-- is_eventually_consistent() reflects the flag and is stable.
-- ----------------------------------------------------------------------------


do
    local sync_transport = h.make_fake_transport({ eventually_consistent = false })
    h.assert_false(sync_transport.is_eventually_consistent(),
        "synchronous fake is not eventually-consistent")

    local async_transport = h.make_fake_transport({ eventually_consistent = true })
    h.assert_true(async_transport.is_eventually_consistent(),
        "eventually-consistent fake reports true")
end


-- ----------------------------------------------------------------------------
-- push fires its callback exactly once with documented error shape.
-- ----------------------------------------------------------------------------


do
    local transport = h.make_fake_transport()
    local call_count = 0
    local cb_ok, cb_err
    transport.push("/books/x.epub", { payload = "hello" }, function(ok, err)
        call_count = call_count + 1
        cb_ok, cb_err = ok, err
    end)
    h.assert_equal(call_count, 1,  "push callback fires exactly once")
    h.assert_true(cb_ok,           "push succeeded")
    h.assert_nil(cb_err,           "no error on success")
end


-- ----------------------------------------------------------------------------
-- push when is_available is false returns NOT_AVAILABLE.
-- ----------------------------------------------------------------------------


do
    local transport = h.make_fake_transport({ initial_available = false })
    local cb_ok, cb_err
    transport.push("/books/x.epub", { payload = "x" }, function(ok, err)
        cb_ok, cb_err = ok, err
    end)
    h.assert_false(cb_ok,                                            "push fails when unavailable")
    h.assert_equal(cb_err, Interface.ERRORS.NOT_AVAILABLE,            "error is NOT_AVAILABLE")
    h.assert_true(Interface.is_documented_error(cb_err),              "error is documented")
end


-- ----------------------------------------------------------------------------
-- pull when is_available is false returns NOT_AVAILABLE.
-- ----------------------------------------------------------------------------


do
    local transport = h.make_fake_transport({ initial_available = false })
    local cb_ok, cb_err
    transport.pull("/books/x.epub", {}, function(ok, err) cb_ok, cb_err = ok, err end)
    h.assert_false(cb_ok,                                  "pull fails when unavailable")
    h.assert_equal(cb_err, Interface.ERRORS.NOT_AVAILABLE,  "error is NOT_AVAILABLE")
end


-- ----------------------------------------------------------------------------
-- For synchronous transports: push then pull observes the pushed payload.
-- This is the core round-trip property the contract guarantees.
-- ----------------------------------------------------------------------------


do
    local transport = h.make_fake_transport({ eventually_consistent = false })

    local push_ok
    transport.push("/books/x.epub", { payload = "hello" }, function(ok) push_ok = ok end)
    h.assert_true(push_ok, "push to synchronous transport succeeded")

    local pull_ok, pull_err, pulled_payload
    transport.pull("/books/x.epub", {}, function(ok, err, extra)
        pull_ok, pull_err, pulled_payload = ok, err, extra
    end)
    h.assert_true(pull_ok,                "pull succeeded")
    h.assert_nil(pull_err,                "no error")
    h.assert_equal(pulled_payload, "hello", "pull returns what was pushed")
end


-- ----------------------------------------------------------------------------
-- For eventually-consistent transports: push is fire-and-forget, pull
-- is allowed to return nil even after a successful push.  This pins
-- the looser contract for Syncthing-style transports.
-- ----------------------------------------------------------------------------


do
    local transport = h.make_fake_transport({ eventually_consistent = true })

    local push_ok
    transport.push("/books/x.epub", { payload = "hello" }, function(ok) push_ok = ok end)
    h.assert_true(push_ok, "push to eventually-consistent transport succeeded")

    local pull_ok, _pull_err, pulled_payload
    transport.pull("/books/x.epub", {}, function(ok, err, extra)
        pull_ok, _pull_err, pulled_payload = ok, err, extra
    end)
    h.assert_true(pull_ok,    "pull succeeded (the call itself is allowed)")
    h.assert_nil(pulled_payload,
        "eventually-consistent pull may legitimately observe nothing yet")
end


-- ----------------------------------------------------------------------------
-- Pull when nothing has ever been pushed returns ok=true, payload=nil.
-- "Nothing remote yet" is not an error.
-- ----------------------------------------------------------------------------


do
    local transport = h.make_fake_transport()
    local pull_ok, pull_err, pulled_payload
    transport.pull("/books/unseen.epub", {}, function(ok, err, extra)
        pull_ok, pull_err, pulled_payload = ok, err, extra
    end)
    h.assert_true(pull_ok,    "empty pull returns ok=true")
    h.assert_nil(pull_err,    "with no error")
    h.assert_nil(pulled_payload, "and a nil payload")
end


-- ----------------------------------------------------------------------------
-- push is idempotent: same payload twice => still one logical state remote-side.
-- This is the property that lets the router safely retry a push.
-- ----------------------------------------------------------------------------


do
    local transport = h.make_fake_transport()
    local push_oks = 0
    local function record_ok(ok) if ok then push_oks = push_oks + 1 end end

    transport.push("/books/x.epub", { payload = "a" }, record_ok)
    transport.push("/books/x.epub", { payload = "a" }, record_ok)

    h.assert_equal(push_oks, 2,                            "both pushes returned ok")
    h.assert_equal(transport.peek_remote("/books/x.epub"), "a",
        "remote has one logical state (the pushed value)")
    h.assert_equal(transport.push_call_count("/books/x.epub"), 2,
        "push was invoked twice")
end


-- ----------------------------------------------------------------------------
-- Errors injected at push time propagate through the callback with a
-- documented error string.  Real transports report e.g. UNREACHABLE or
-- AUTH_FAILED — the fake lets us choose which to simulate.
-- ----------------------------------------------------------------------------


do
    local transport = h.make_fake_transport()
    transport.set_error_on_push(Interface.ERRORS.UNREACHABLE)

    local cb_ok, cb_err
    transport.push("/books/x.epub", { payload = "a" }, function(ok, err)
        cb_ok, cb_err = ok, err
    end)
    h.assert_false(cb_ok,                                  "push reports failure")
    h.assert_equal(cb_err, Interface.ERRORS.UNREACHABLE,    "with the injected error")
    h.assert_true(Interface.is_documented_error(cb_err),    "documented error")
end


do
    local transport = h.make_fake_transport()
    transport.set_error_on_pull(Interface.ERRORS.AUTH_FAILED)

    local cb_ok, cb_err
    transport.pull("/books/x.epub", {}, function(ok, err) cb_ok, cb_err = ok, err end)
    h.assert_false(cb_ok,                                  "pull reports failure")
    h.assert_equal(cb_err, Interface.ERRORS.AUTH_FAILED,    "with the injected error")
end


-- ----------------------------------------------------------------------------
-- status() returns a table with the three required keys.
-- Transport-specific extras are allowed; the panel just ignores them
-- unless it knows about them.
-- ----------------------------------------------------------------------------


do
    local transport = h.make_fake_transport({ display_name = "Fake T" })
    local status = transport.status()

    h.assert_equal(type(status),             "table",    "status returns table")
    h.assert_equal(status.display_name,      "Fake T",   "display_name in status")
    h.assert_equal(type(status.available),   "boolean",  "available is boolean")
    h.assert_equal(type(status.summary),     "string",   "summary is string")
end


do
    -- After toggling availability, status reflects it.
    local transport = h.make_fake_transport()
    transport.set_available(false)
    local status = transport.status()
    h.assert_false(status.available, "status.available reflects current state")
end


-- ----------------------------------------------------------------------------
-- validate_implementation rejects non-tables and tables missing methods.
-- These are the cheap-class-of-bug checks the router runs at registration.
-- ----------------------------------------------------------------------------


do
    -- Wrong type entirely.
    local ok, problems = Interface.validate_implementation("not a table")
    h.assert_false(ok,                           "non-table rejected")
    h.assert_true(#problems >= 1,                "at least one problem reported")

    local ok2, problems2 = Interface.validate_implementation(nil)
    h.assert_false(ok2,                          "nil rejected")
    h.assert_true(#problems2 >= 1,               "nil reported as problem")
end


do
    -- Right type but missing every method.
    local empty = {}
    local ok, problems = Interface.validate_implementation(empty)
    h.assert_false(ok,                                  "empty table rejected")
    h.assert_equal(#problems, #Interface.REQUIRED_METHODS,
        "one problem per missing method")
end


do
    -- Some methods present, some missing.  Validator reports only what's
    -- missing — we'd want this in a real plugin-load log so the operator
    -- can see exactly which functions need writing.
    local partial = {
        id           = function() return "x" end,
        display_name = function() return "X" end,
        is_available = function() return true end,
        -- missing: is_eventually_consistent, push, pull, status
    }
    local ok, problems = Interface.validate_implementation(partial)
    h.assert_false(ok,                                "partial table rejected")
    h.assert_equal(#problems, 4,                      "exactly 4 missing methods")
end


do
    -- A method is present but is the wrong type (string instead of function).
    -- This catches `Transport.push = "TODO"` and similar dev typos.
    local mistyped = {
        id           = function() return "x" end,
        display_name = function() return "X" end,
        is_available = function() return true end,
        is_eventually_consistent = function() return false end,
        push         = "TODO write this",
        pull         = function() end,
        status       = function() return {} end,
    }
    local ok, problems = Interface.validate_implementation(mistyped)
    h.assert_false(ok,                                "non-function method rejected")
    h.assert_equal(#problems, 1,                      "one problem reported")
    h.assert_true(problems[1]:match("push") ~= nil,    "the problem names 'push'")
end


-- ----------------------------------------------------------------------------
-- is_documented_error: nil is always fine; known errors pass; unknown fail.
-- ----------------------------------------------------------------------------


do
    h.assert_true(Interface.is_documented_error(nil),
        "nil is always documented (means 'no error')")
    h.assert_true(Interface.is_documented_error(Interface.ERRORS.NOT_AVAILABLE),
        "NOT_AVAILABLE is documented")
    h.assert_true(Interface.is_documented_error(Interface.ERRORS.UNREACHABLE),
        "UNREACHABLE is documented")
    h.assert_true(Interface.is_documented_error(Interface.ERRORS.AUTH_FAILED),
        "AUTH_FAILED is documented")
    h.assert_true(Interface.is_documented_error(Interface.ERRORS.NOT_CONFIGURED),
        "NOT_CONFIGURED is documented")
    h.assert_true(Interface.is_documented_error(Interface.ERRORS.REJECTED),
        "REJECTED is documented")
    h.assert_true(Interface.is_documented_error(Interface.ERRORS.INTERNAL),
        "INTERNAL is documented")

    h.assert_false(Interface.is_documented_error("invented_string"),
        "free-form strings are not documented")
    h.assert_false(Interface.is_documented_error("NOT_AVAILABLE"),
        "wrong case is not documented (we lowercase by convention)")
end


-- ----------------------------------------------------------------------------
-- CAPABILITIES constants are stable strings (don't accidentally rename
-- — registered transports use them as keys).
-- ----------------------------------------------------------------------------


do
    h.assert_equal(Interface.CAPABILITIES.IGNORE_PATTERNS,
        "ignore_patterns",    "IGNORE_PATTERNS string is stable")
    h.assert_equal(Interface.CAPABILITIES.EVENT_SUBSCRIPTION,
        "event_subscription", "EVENT_SUBSCRIPTION string is stable")
    h.assert_equal(Interface.CAPABILITIES.CONFLICTS_DETAILED,
        "conflicts_detailed", "CONFLICTS_DETAILED string is stable")
    h.assert_equal(Interface.CAPABILITIES.PERIODIC_SYNC,
        "periodic_sync",      "PERIODIC_SYNC string is stable")
    h.assert_equal(Interface.CAPABILITIES.QUICK_SYNC,
        "quick_sync",         "QUICK_SYNC string is stable")
    -- Phase 11: daemon process control.  The bridge gates on the
    -- literal "daemon_control", so this string is load-bearing.
    h.assert_equal(Interface.CAPABILITIES.DAEMON_CONTROL,
        "daemon_control",     "DAEMON_CONTROL string is stable")
    -- daemon_control is OPTIONAL — it must not have leaked into the
    -- required-method contract; a transport with no daemon (Cloud,
    -- Cloud) must still validate.
    local minimal = h.make_fake_transport()
    local ok = Interface.validate_implementation(minimal)
    h.assert_true(ok,
        "a transport without daemon_control still passes validation")
end
