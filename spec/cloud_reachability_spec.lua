-- =============================================================================
-- spec/cloud_reachability_spec.lua
-- =============================================================================
--
-- Tests for syncery_transports/cloud/cloud_reachability.lua.
--
-- The module's value is a CACHED, NON-BLOCKING reachability verdict: callers
-- read `is_reachable()` (instant) instead of a synchronous DNS probe, and the
-- verdict is moved by transfer outcomes, NetworkMgr events, and a non-blocking
-- connect probe polled across UI ticks.  These tests drive it with pure stubs
-- (a fake clock, a fake scheduler whose queued polls the test "ticks" by hand,
-- and a programmable fake connect) and assert:
--   * verdict freshness / TTL expiry;
--   * note_success -> reachable + a ONE-TIME IP resolve at that network-up
--     moment (and no re-resolve while fresh; re-resolve on host change / IP TTL);
--   * the non-blocking probe state machine: ok / fail / timeout / wait-then-ok
--     across simulated ticks, with connect_close always called;
--   * is_reachable bootstrap (no IP cached -> fail OPEN) vs defer (IP cached ->
--     probe + defer);
--   * the event hooks move the verdict with NO I/O (disconnect) / a probe
--     (connect);
--   * fail-open when there is no server / no probe I/O.
--
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_cloud_reachability_spec_" .. tostring(os.time()))

local CloudReachability = require("syncery_transports/cloud/cloud_reachability")

local WEBDAV = { type = "webdav", address = "https://example.com/dav" }   -- host example.com:443


-- Build an instance + a controllable test rig around it.
local function make(opts)
    opts = opts or {}
    local rig = {
        clock        = opts.t0 or 1000,
        sched        = {},               -- queued {delay, fn}
        resolve_calls = 0,
        persist_calls = {},
        close_calls  = 0,
        connect_started = {},
        poll_results = opts.poll_results or {},  -- sequence consumed by connect_poll
        poll_i       = 0,
        connect_blocking_calls = {},     -- recorded warm_blocking connects
        server       = opts.server,      -- mutable: tests can swap it
        resolve_ip   = (opts.resolve_ip ~= nil) and opts.resolve_ip or "1.2.3.4",
    }
    local deps = {
        now        = function() return rig.clock end,
        get_server = function() return rig.server end,
        resolve    = function(host)
            rig.resolve_calls = rig.resolve_calls + 1
            return rig.resolve_ip
        end,
        connect_start = function(ip, port)
            table.insert(rig.connect_started, { ip = ip, port = port })
            if opts.connect_start_nil then return nil end
            return { ip = ip, port = port }
        end,
        connect_poll = function(handle)
            rig.poll_i = rig.poll_i + 1
            return rig.poll_results[rig.poll_i] or "wait"
        end,
        connect_close = function(handle) rig.close_calls = rig.close_calls + 1 end,
        connect_blocking = function(ip, port, timeout)
            table.insert(rig.connect_blocking_calls, { ip = ip, port = port, timeout = timeout })
            return opts.connect_blocking_result and true or false
        end,
        schedule   = function(delay, fn)
            table.insert(rig.sched, { delay = delay, fn = fn })
        end,
        persist_ip = function(host, ip) table.insert(rig.persist_calls, { host, ip }) end,
        ttl           = opts.ttl,
        probe_timeout = opts.probe_timeout,
        poll_interval = opts.poll_interval,
        ip_ttl        = opts.ip_ttl,
        initial_ip    = opts.initial_ip,
        initial_host  = opts.initial_host,
    }
    -- Disable selected injections explicitly.  A `flag and nil or fn` idiom
    -- would ALWAYS yield fn (since `flag and nil` is nil/falsy -> `or fn`).
    if opts.no_server   then deps.get_server    = nil end
    if opts.no_resolve  then deps.resolve       = nil end
    if opts.no_connect  then deps.connect_start = nil; deps.connect_poll = nil end
    if opts.no_connect_blocking then deps.connect_blocking = nil end
    if opts.no_schedule then deps.schedule      = nil end
    rig.cr = CloudReachability.new(deps)
    -- run the next queued scheduled callback (FIFO; the probe self-schedules)
    rig.tick = function()
        local e = table.remove(rig.sched, 1)
        if e then e.fn() end
    end
    return rig
end


-- ----------------------------------------------------------------------------
-- 1. note_success -> reachable + a one-time IP resolve; then no probe.
-- ----------------------------------------------------------------------------
do
    local r = make({ server = WEBDAV })

    -- First call, no IP yet: bootstrap fails OPEN so a transfer can seed the IP.
    h.assert_true(r.cr:is_reachable(), "1 bootstrap: no IP -> fail open (true)")

    r.cr:note_success()
    h.assert_equal(r.cr.verdict, "reachable", "1 note_success -> reachable")
    h.assert_equal(r.resolve_calls, 1, "1 note_success resolved the IP once")
    h.assert_equal(r.cr.cached_ip, "1.2.3.4", "1 cached the resolved IP")
    h.assert_equal(r.cr.cached_host, "example.com", "1 cached the host")
    h.assert_equal(r.cr.cached_port, 443, "1 cached the port")
    h.assert_equal(#r.persist_calls, 1, "1 persisted the IP")

    -- Fresh reachable verdict -> instant true, NO probe scheduled.
    h.assert_true(r.cr:is_reachable(), "1 fresh reachable -> true")
    h.assert_equal(#r.sched, 0, "1 no probe while the verdict is fresh")
    h.assert_equal(r.resolve_calls, 1, "1 no extra resolve while fresh")
end


-- ----------------------------------------------------------------------------
-- 2. Verdict TTL expiry -> background probe + defer; probe 'ok' -> reachable.
-- ----------------------------------------------------------------------------
do
    local r = make({ server = WEBDAV, ttl = 300, poll_results = { "ok" } })
    r.cr:note_success()                       -- reachable, IP cached @ t=1000

    r.clock = 1000 + 301                       -- past the TTL
    h.assert_false(r.cr:is_reachable(), "2 expired verdict -> defer (false)")
    h.assert_true(r.cr.probing, "2 a probe is in flight")
    h.assert_equal(#r.sched, 1, "2 a poll was scheduled")
    h.assert_equal(#r.connect_started, 1, "2 connect targeted the cached IP")
    h.assert_equal(r.connect_started[1].ip, "1.2.3.4", "2 connected to cached IP (no DNS)")
    h.assert_equal(r.resolve_calls, 1, "2 the probe did NOT resolve")

    r.tick()                                   -- poll -> "ok"
    h.assert_equal(r.cr.verdict, "reachable", "2 probe ok -> reachable")
    h.assert_false(r.cr.probing, "2 probe finished")
    h.assert_equal(r.close_calls, 1, "2 the probe socket was closed")
    h.assert_true(r.cr:is_reachable(), "2 reachable again -> true")
end


-- ----------------------------------------------------------------------------
-- 3. Probe: wait, wait, ok across three ticks.
-- ----------------------------------------------------------------------------
do
    local r = make({ server = WEBDAV, ttl = 300, probe_timeout = 5,
                     poll_results = { "wait", "wait", "ok" } })
    r.cr:note_success()
    r.clock = 1000 + 301
    r.cr:is_reachable()                        -- starts the probe

    r.tick(); h.assert_true(r.cr.probing, "3 still probing after wait #1")
    r.tick(); h.assert_true(r.cr.probing, "3 still probing after wait #2")
    r.tick()
    h.assert_equal(r.cr.verdict, "reachable", "3 ok on the third poll -> reachable")
    h.assert_false(r.cr.probing, "3 probe done")
    h.assert_equal(r.close_calls, 1, "3 socket closed once")
end


-- ----------------------------------------------------------------------------
-- 4. Probe: connect refused -> unreachable.
-- ----------------------------------------------------------------------------
do
    local r = make({ server = WEBDAV, ttl = 300, poll_results = { "fail" } })
    r.cr:note_success()
    r.clock = 1000 + 301
    r.cr:is_reachable()
    r.tick()                                   -- poll -> "fail"
    h.assert_equal(r.cr.verdict, "unreachable", "4 probe fail -> unreachable")
    h.assert_false(r.cr.probing, "4 probe done")
    h.assert_equal(r.close_calls, 1, "4 socket closed")
    h.assert_false(r.cr:is_reachable(), "4 unreachable (fresh) -> false")
end


-- ----------------------------------------------------------------------------
-- 5. Probe: never writable, deadline passes -> bounded timeout -> unreachable.
-- ----------------------------------------------------------------------------
do
    local r = make({ server = WEBDAV, ttl = 300, probe_timeout = 2,
                     poll_results = { "wait", "wait", "wait" } })
    r.cr:note_success()
    r.clock = 1000 + 301
    r.cr:is_reachable()                        -- deadline = now + 2 = 1303

    r.tick(); h.assert_true(r.cr.probing, "5 still probing before the deadline")
    r.clock = 1303 + 1                          -- past the probe deadline
    r.tick()                                    -- poll "wait" but deadline passed
    h.assert_equal(r.cr.verdict, "unreachable", "5 deadline passed -> unreachable")
    h.assert_false(r.cr.probing, "5 probe gave up")
    h.assert_equal(r.close_calls, 1, "5 socket closed on timeout")
end


-- ----------------------------------------------------------------------------
-- 6. Fail-open when there is no probe I/O / no resolve (headless).
-- ----------------------------------------------------------------------------
do
    local r = make({ server = WEBDAV, no_resolve = true, no_connect = true,
                     no_schedule = true })
    h.assert_true(r.cr:is_reachable(), "6 no IP, headless -> fail open (true)")
    r.cr:note_success()                         -- must not crash without resolve
    h.assert_equal(r.cr.verdict, "reachable", "6 note_success still sets reachable")
    h.assert_nil(r.cr.cached_ip, "6 nothing cached without a resolver")
end


-- ----------------------------------------------------------------------------
-- 7. note_failure -> unreachable.
-- ----------------------------------------------------------------------------
do
    local r = make({ server = WEBDAV })
    r.cr:note_success()
    r.cr:note_failure()
    h.assert_equal(r.cr.verdict, "unreachable", "7 note_failure -> unreachable")
    h.assert_false(r.cr:is_reachable(), "7 unreachable (fresh) -> false")
end


-- ----------------------------------------------------------------------------
-- 8. Events: disconnect -> unreachable (no I/O); connect -> unknown + probe.
-- ----------------------------------------------------------------------------
do
    local r = make({ server = WEBDAV, poll_results = { "ok" } })
    r.cr:note_success()                         -- reachable, IP cached
    local resolves_before = r.resolve_calls

    r.cr:on_network_disconnected()
    h.assert_equal(r.cr.verdict, "unreachable", "8 disconnect -> unreachable")
    h.assert_equal(#r.sched, 0, "8 disconnect did NO I/O (no probe)")
    h.assert_equal(r.resolve_calls, resolves_before, "8 disconnect did not resolve")
    h.assert_false(r.cr:is_reachable(), "8 unreachable after disconnect -> false")

    r.cr:on_network_connected()
    h.assert_equal(r.cr.verdict, "unknown", "8 connect -> unknown (re-verify)")
    h.assert_true(r.cr.probing, "8 connect started a background re-probe (IP cached)")
    r.tick()                                    -- poll -> ok
    h.assert_equal(r.cr.verdict, "reachable", "8 re-probe ok -> reachable")
end


-- ----------------------------------------------------------------------------
-- 9. note_success re-resolves on host change, but NOT while fresh.
-- ----------------------------------------------------------------------------
do
    local r = make({ server = WEBDAV })
    r.cr:note_success()
    h.assert_equal(r.resolve_calls, 1, "9 first success resolved")

    r.cr:note_success()                         -- same host, fresh -> no re-resolve
    h.assert_equal(r.resolve_calls, 1, "9 same host while fresh -> no re-resolve")

    r.server = { type = "webdav", address = "https://other.example.net/dav" }
    r.cr:note_success()                         -- host changed -> re-resolve
    h.assert_equal(r.resolve_calls, 2, "9 host change -> re-resolve")
    h.assert_equal(r.cr.cached_host, "other.example.net", "9 cached the new host")
end


-- ----------------------------------------------------------------------------
-- 10. note_success re-resolves once the cached IP exceeds its own TTL.
-- ----------------------------------------------------------------------------
do
    local r = make({ server = WEBDAV, ip_ttl = 1800 })
    r.cr:note_success()                         -- cached @ t=1000
    h.assert_equal(r.resolve_calls, 1, "10 initial resolve")

    r.clock = 1000 + 1801                        -- past the IP TTL
    r.cr:note_success()
    h.assert_equal(r.resolve_calls, 2, "10 stale cached IP -> re-resolve")
end


-- ----------------------------------------------------------------------------
-- 11. connect_start returning nil -> unreachable (cannot even begin).
-- ----------------------------------------------------------------------------
do
    local r = make({ server = WEBDAV, ttl = 300, connect_start_nil = true })
    r.cr:note_success()
    r.clock = 1000 + 301
    h.assert_false(r.cr:is_reachable(), "11 expired -> tries to probe")
    h.assert_equal(r.cr.verdict, "unreachable", "11 connect_start nil -> unreachable")
    h.assert_false(r.cr.probing, "11 no probe in flight")
    h.assert_equal(#r.sched, 0, "11 nothing scheduled")
end


-- ----------------------------------------------------------------------------
-- 12. Seeded IP (persistence) -> probes non-blocking from cold start.
-- ----------------------------------------------------------------------------
do
    local r = make({ server = WEBDAV, ttl = 300, poll_results = { "ok" },
                     initial_ip = "9.9.9.9", initial_host = "example.com" })
    -- unknown verdict but a seeded IP -> is_reachable defers + probes (no bootstrap)
    h.assert_false(r.cr:is_reachable(), "12 seeded IP + unknown -> defer (false)")
    h.assert_true(r.cr.probing, "12 probes immediately using the seeded IP")
    h.assert_equal(r.connect_started[1].ip, "9.9.9.9", "12 connected to the seeded IP")
    h.assert_equal(r.resolve_calls, 0, "12 cold-start probe did NOT resolve")
    r.tick()
    h.assert_equal(r.cr.verdict, "reachable", "12 seeded-IP probe ok -> reachable")
end


-- ----------------------------------------------------------------------------
-- 13. warm_blocking: cached IP + connect OK -> firm reachable, and the very
--     next is_reachable() returns true WITHOUT deferring (the terminal-push
--     point: the gate proceeds INLINE, no probe scheduled).
-- ----------------------------------------------------------------------------
do
    local r = make({ server = WEBDAV, ttl = 300, connect_blocking_result = true,
                     initial_ip = "9.9.9.9", initial_host = "example.com" })
    r.cr:warm_blocking()
    h.assert_equal(r.cr.verdict, "reachable", "13 warm_blocking ok -> reachable")
    h.assert_equal(#r.connect_blocking_calls, 1, "13 one blocking connect")
    h.assert_equal(r.connect_blocking_calls[1].ip, "9.9.9.9", "13 connected to the cached IP (no DNS)")
    h.assert_equal(r.connect_blocking_calls[1].port, 443, "13 derived the server port")
    h.assert_equal(r.resolve_calls, 0, "13 warm_blocking did NOT resolve (no DNS)")
    -- The payoff: the gate now answers firm-true with no defer/probe.
    h.assert_true(r.cr:is_reachable(), "13 fresh reachable -> true (inline, no defer)")
    h.assert_equal(#r.sched, 0, "13 no probe scheduled")
end


-- ----------------------------------------------------------------------------
-- 14. warm_blocking: cached IP + connect FAILS -> firm unreachable (a stale
--     cached IP / down server is skipped, NOT frozen).
-- ----------------------------------------------------------------------------
do
    local r = make({ server = WEBDAV, ttl = 300, connect_blocking_result = false,
                     initial_ip = "9.9.9.9", initial_host = "example.com" })
    r.cr:warm_blocking()
    h.assert_equal(r.cr.verdict, "unreachable", "14 warm_blocking fail -> unreachable")
    h.assert_equal(#r.connect_blocking_calls, 1, "14 one blocking connect attempted")
    h.assert_false(r.cr:is_reachable(), "14 unreachable (fresh) -> false")
end


-- ----------------------------------------------------------------------------
-- 15. warm_blocking: NO cached IP -> no-op (verdict untouched, no connect, no
--     DNS).  The caller's is_reachable() then fails open exactly as before.
-- ----------------------------------------------------------------------------
do
    local r = make({ server = WEBDAV, ttl = 300, connect_blocking_result = true })
    h.assert_equal(r.cr.verdict, "unknown", "15 starts unknown")
    r.cr:warm_blocking()
    h.assert_equal(r.cr.verdict, "unknown", "15 no cached IP -> verdict untouched")
    h.assert_equal(#r.connect_blocking_calls, 0, "15 no blocking connect")
    h.assert_equal(r.resolve_calls, 0, "15 no DNS")
end


-- ----------------------------------------------------------------------------
-- 16. warm_blocking: no blocking connector injected (headless) -> no-op even
--     with a cached IP.
-- ----------------------------------------------------------------------------
do
    local r = make({ server = WEBDAV, ttl = 300, no_connect_blocking = true,
                     initial_ip = "9.9.9.9", initial_host = "example.com" })
    r.cr:warm_blocking()
    h.assert_equal(r.cr.verdict, "unknown", "16 no connector -> no-op (verdict untouched)")
end


print("cloud_reachability_spec: all assertions passed")
