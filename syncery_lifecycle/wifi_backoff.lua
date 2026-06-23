-- =============================================================================
-- syncery_lifecycle/wifi_backoff.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- Exponential-backoff retry scheduling for sync actions that need a
-- network connection.
--
-- A NOTE ON THE NAME
--
-- The file is called `wifi_backoff` because Syncthing-on-an-e-reader is
-- overwhelmingly a WiFi scenario (KOSyncthing+'s equivalent uses the same
-- vocabulary).  But the logic here is DELIBERATELY connection-
-- agnostic: the connectivity probe is `is_online`, which in production
-- is `NetworkMgr:isConnected()` — true for ANY working connection
-- (WiFi, mobile data, Ethernet on a desktop, a USB tether).  Nothing
-- in this module gates on WiFi specifically.  A device on mobile data
-- is "online" and its action runs immediately; a genuinely offline
-- device gets the backoff regardless of which radio will eventually
-- carry the connection.  Read "WiFi" throughout this file as shorthand
-- for "the network transport".
--
-- THE GAP IT CLOSES
--
-- Syncery otherwise has no transient-connectivity-drop retry.
-- The pattern across the cloud upload path and
-- `_rescanAllFolders` was uniform: check `NetworkMgr:isConnected()`,
-- and if offline, `return` — the retry was never SCHEDULED, it just
-- waited for the next reader-ready event to happen to coincide with
-- the connection being back.  On a slow device waking from suspend
-- the user feels this as "sync didn't happen".
--
-- THE PATTERN, IMPORTED FROM KOSYNCTHING+
--
-- KOSyncthing+'s `st_orchestrator.lua` `runQuickSync` / `runPeriodicSync`
-- solve exactly this.  The shape, reproduced here:
--
--   * A `retry_delay` that starts small and doubles on each failed
--     attempt — 3s, 6s, 12s, 24s, … — capped (`math.min(delay*2, cap)`).
--   * An ABSOLUTE timeout: regardless of how many retries are still
--     pending, the whole effort gives up after a fixed wall-clock
--     window.  This is what bounds the worst case.
--   * A `finish`-wrapper guard for the documented race where the
--     network-enable callback is silently dropped: `finish` is
--     idempotent and is reached BOTH from a successful online check
--     AND from the absolute-timeout fallback, so a dropped callback
--     can't strand the retry loop forever.
--
-- WHY IT LIVES IN syncery_lifecycle/
--
-- This is a SCHEDULING concern, not a transport-contract one.  It does
-- not know or care which transport the deferred action drives; it just
-- answers "we're offline now — re-attempt with backoff until online or
-- timed out".  Putting it here (alongside `timers.lua`, which already
-- proves the injected-scheduler pattern) keeps the transport
-- contract closed: `wifi_backoff` adds NO transport method and touches
-- NO transport code.
--
-- INJECTED DEPENDENCIES (the testability seam)
--
-- Everything time- or environment-dependent is injected, exactly so
-- the backoff curve and the absolute-timeout race are unit-testable
-- with `make_fake_clock` / `make_fake_scheduler` (spec/test_helpers):
--
--   opts.scheduler  — function(delay_seconds, fn).  Defers `fn` by
--                     `delay_seconds`.  Production wires this to
--                     `UIManager:scheduleIn`; tests pass a fake.
--   opts.clock      — function() → epoch seconds.  Used only for the
--                     absolute-timeout deadline.  Defaults to os.time.
--   opts.is_online  — function() → boolean.  The connectivity probe.
--                     Production wires this to NetworkMgr:isConnected
--                     (true for ANY connection — see the name note
--                     above); tests pass a controllable stub.
--   opts.wake_network — function()|nil.  Optional: asks the platform
--                     to bring the network up (NetworkMgr:turnOnWifi-
--                     style).  Best-effort — many platforms auto-
--                     manage connectivity and this is a no-op, which
--                     is why the production wiring leaves it unset.
--                     The retry does NOT depend on it succeeding; the
--                     next scheduled probe is what actually re-checks.
--   opts.logger     — optional; .info / .warn.  No-op fallback.
--
-- The action to (re)attempt and the curve parameters are passed per
-- call to `attempt`, not at construction, so one Backoff instance can
-- drive several different sync actions.
--
-- =============================================================================

local WifiBackoff = {}
WifiBackoff.__index = WifiBackoff


-- ----------------------------------------------------------------------------
-- Defaults — the curve (same shape as KOSyncthing+'s runQuickSync).
-- ----------------------------------------------------------------------------


--- First retry delay, seconds.  (KOSyncthing+ itself now starts at 7 s.)
WifiBackoff.DEFAULT_INITIAL_DELAY = 3

--- Per-retry multiplier.  Doubling: 3 → 6 → 12 → 24 → 48 → …
WifiBackoff.DEFAULT_MULTIPLIER = 2

--- Delay cap, seconds.  Past this the delay stops growing — retries
--- continue at the cap until the absolute timeout fires.
WifiBackoff.DEFAULT_MAX_DELAY = 60

--- Absolute timeout, seconds.  The whole retry effort gives up this
--- long after it started, regardless of pending retries.  KOSyncthing+'s
--- quickSync uses a 2-minute window; we match it.
WifiBackoff.DEFAULT_ABSOLUTE_TIMEOUT = 120


-- ----------------------------------------------------------------------------
-- Construction
-- ----------------------------------------------------------------------------


--- Build a new WifiBackoff scheduler.
---
--- @param opts table  see the INJECTED DEPENDENCIES block in the header.
--- @return table
function WifiBackoff.new(opts)
    opts = opts or {}
    assert(type(opts.scheduler) == "function",
        "WifiBackoff.new: scheduler function is required")
    assert(type(opts.is_online) == "function",
        "WifiBackoff.new: is_online function is required")

    local self = setmetatable({}, WifiBackoff)
    self._scheduler    = opts.scheduler
    self._clock        = opts.clock or os.time
    self._is_online    = opts.is_online
    self._wake_network = opts.wake_network   -- may be nil
    self._logger       = opts.logger or { info = function() end,
                                          warn = function() end }
    -- At most one retry effort runs at a time per instance.  A second
    -- `attempt` while one is in flight is dropped (see `attempt`).
    self._in_flight    = false
    return self
end


-- ----------------------------------------------------------------------------
-- attempt — run an action now if online, else retry with backoff
-- ----------------------------------------------------------------------------


--- Run `action` immediately if online; otherwise schedule retries
--- with exponential backoff until online or the absolute timeout.
---
--- This is the single entry point the `main.lua` offline-sync paths
--- call instead of their old bare `return`.  When the device is
--- online the action runs synchronously, in this call, and `attempt`
--- returns — there is no scheduling overhead in the common case.
---
--- When offline, `attempt` returns immediately after arming the first
--- retry; the action runs later, from the scheduler, once a probe
--- finds the device online.  If the absolute timeout is reached first,
--- the action is NOT run — the effort is abandoned (logged).
---
--- Re-entrancy: while one retry effort is in flight, a further
--- `attempt` call is dropped (logged at info).  That matches the
--- intent — these actions are idempotent re-syncs; piling up parallel
--- backoff loops for the same work buys nothing and complicates the
--- absolute-timeout accounting.
---
--- @param action table {
---     run   = function   — REQUIRED. the work to perform when online.
---     label = string|nil — for log lines; defaults to "sync".
---     initial_delay     = number|nil
---     multiplier        = number|nil
---     max_delay         = number|nil
---     absolute_timeout  = number|nil
---   }
--- @return string  one of:
---     "ran"        — online; the action ran in this call.
---     "scheduled"  — offline; a retry was armed.
---     "busy"       — a retry effort was already in flight; dropped.
function WifiBackoff:attempt(action)
    assert(type(action) == "table" and type(action.run) == "function",
        "WifiBackoff:attempt: action.run function is required")

    local label = action.label or "sync"

    -- Common case: already online.  Run now, no scheduling.
    if self._is_online() then
        self:_run_action(action.run, label)
        return "ran"
    end

    -- Offline and a retry effort is already running — drop this one.
    if self._in_flight then
        self._logger.info("Syncery wifi_backoff: " .. label
            .. " attempt dropped (a retry effort is already in flight)")
        return "busy"
    end

    -- Offline: arm the backoff loop.
    local curve = {
        delay     = action.initial_delay    or WifiBackoff.DEFAULT_INITIAL_DELAY,
        mult      = action.multiplier       or WifiBackoff.DEFAULT_MULTIPLIER,
        cap       = action.max_delay        or WifiBackoff.DEFAULT_MAX_DELAY,
        timeout   = action.absolute_timeout or WifiBackoff.DEFAULT_ABSOLUTE_TIMEOUT,
    }
    local deadline = self._clock() + curve.timeout

    self._in_flight = true
    self._logger.info("Syncery wifi_backoff: " .. label
        .. " offline — scheduling retry in " .. tostring(curve.delay) .. "s")

    self:_schedule_retry(action, curve, deadline, label)
    return "scheduled"
end


-- ----------------------------------------------------------------------------
-- Internal: the retry loop
-- ----------------------------------------------------------------------------


--- Arm one retry tick.  Each tick:
---   1. clears in-flight if past the absolute deadline (give up), OR
---   2. runs the action and clears in-flight if now online, OR
---   3. doubles the delay (capped) and reschedules.
---
--- The `finish`-wrapper guard: `_finish` is idempotent and is the ONLY
--- place `_in_flight` is cleared.  It is reached from both the success
--- branch and the timeout branch, so even if the platform's WiFi-
--- enable callback is silently dropped (a known platform race), the
--- next scheduled tick still reaches `_finish` via the timeout check —
--- the loop can never strand `_in_flight` set forever.
function WifiBackoff:_schedule_retry(action, curve, deadline, label)
    self._scheduler(curve.delay, function()
        -- Absolute-timeout check FIRST.  This is the guard that bounds
        -- the worst case and that catches a dropped WiFi callback: a
        -- tick always eventually arrives, and once past the deadline
        -- it finishes the effort rather than rescheduling.
        if self._clock() >= deadline then
            self._logger.warn("Syncery wifi_backoff: " .. label
                .. " gave up — still offline after the absolute timeout")
            self:_finish()
            return
        end

        if self._is_online() then
            self._logger.info("Syncery wifi_backoff: " .. label
                .. " back online — running deferred action")
            self:_run_action(action.run, label)
            self:_finish()
            return
        end

        -- Still offline: best-effort nudge the network up, then double
        -- the delay (capped) and reschedule.
        if self._wake_network then
            pcall(self._wake_network)
        end

        curve.delay = math.min(curve.delay * curve.mult, curve.cap)
        self._logger.info("Syncery wifi_backoff: " .. label
            .. " still offline — next retry in " .. tostring(curve.delay) .. "s")
        self:_schedule_retry(action, curve, deadline, label)
    end)
end


--- Run the action under pcall so a faulty deferred callback can't
--- crash the scheduler.  Shared by the immediate path and the retry
--- path.
function WifiBackoff:_run_action(run, label)
    local ok, err = pcall(run)
    if not ok then
        self._logger.warn("Syncery wifi_backoff: " .. label
            .. " action raised: " .. tostring(err))
    end
end


--- Idempotent end-of-effort.  The ONLY place `_in_flight` clears.
--- Reached from both the success and the timeout branches — see the
--- `finish`-wrapper note on `_schedule_retry`.
function WifiBackoff:_finish()
    self._in_flight = false
end


-- ----------------------------------------------------------------------------
-- is_in_flight — testing hook + a sometimes-useful predicate.
-- ----------------------------------------------------------------------------


--- True iff a retry effort is currently armed / running.
--- @return boolean
function WifiBackoff:is_in_flight()
    return self._in_flight
end


return WifiBackoff
