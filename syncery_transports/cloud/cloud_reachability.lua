-- =============================================================================
-- syncery_transports/cloud/cloud_reachability.lua
-- =============================================================================
--
-- A CACHED, NON-BLOCKING reachability verdict for the cloud server, so the
-- cloud-upload path and the DB-sync timer can gate on "reachable now?" WITHOUT
-- a synchronous DNS probe on every operation.
--
-- WHY THIS EXISTS (the stutter `reachability.lua` could not avoid)
--
-- `reachability.lua` answers "reachable now?" correctly but SYNCHRONOUSLY:
-- `is_online()` is `NetworkMgr:canResolveHostnames` == `socket.dns.toip(...)`,
-- a blocking DNS lookup with NO per-call timeout (the OS resolver decides, up
-- to ~30 s on a dead network).  Calling it before every cloud upload -- which
-- the autosave path does roughly once a minute while reading -- blocks the
-- single-threaded UI for the lookup each time: a perceptible reading stutter.
-- And `settimeout` bounds a TCP *connect* but NOT the DNS inside it, so there
-- is no way to make a single check both correct and cheap.
--
-- THE STRATEGY: probe rarely, trust recent evidence, react to events.
--
--   * `is_reachable()` reads a CACHED verdict -- instant, never blocks.  During
--     healthy reading (transfers succeeding) the verdict stays fresh from each
--     success, so the gate never probes -> no stutter.
--   * A SUCCESSFUL transfer is proof: `note_success()` marks reachable (TTL)
--     and, at that network-up moment (DNS is fast and safe), resolves+caches
--     the server IP ONCE for later non-blocking connects.
--   * A FAILED transfer / a `NetworkDisconnected` event marks unreachable
--     instantly (no I/O).
--   * When the verdict is stale/unknown, a NON-BLOCKING probe firms it up:
--     a `settimeout(0)` connect to the CACHED IP (no DNS), polled across UI
--     ticks with an instant `select(0)` until writable / refused / timeout.
--     No single call blocks -> the probe never stutters.
--
-- DNS IS KEPT OFF THE HOT PATH.  The only synchronous resolve is in
-- `note_success()` (post-transfer, network proven up -> fast), and only when
-- the IP is missing/stale.  The probe NEVER resolves; it connects to the
-- cached IP.  Production seeds the cached IP from a persisted value (so a
-- returning session probes non-blocking from the start) and re-persists on each
-- resolve.  RESIDUAL (documented): the very first sync before any IP is cached
-- fails OPEN (one attempt, so a success can seed the IP); production resolves
-- at cloud-config time -- network up -- to avoid even that.
--
-- VERDICT serves both consumers.  The probe targets the configured (Syncery)
-- cloud server; `do_cloud_upload` needs exactly that, and for the DB-sync timer
-- it is a sound proxy (a live TCP path to a cloud server == internet is up, so
-- the plugins' own sync to their server will not hang on the catastrophic
-- no-internet case; a specific-server-down stays a bounded socketutil hang).
--
-- PURE + INJECTED.  All I/O and the clock are injected so the state machine is
-- unit-testable with no sockets, no NetworkMgr, no real scheduler:
--   deps.now           function() -> number (seconds)            (os.time)
--   deps.get_server    function() -> server|nil                  (cloud server)
--   deps.resolve       function(host) -> ip|nil                  (socket.dns.toip)
--   deps.connect_start function(ip, port) -> handle|nil          (settimeout(0)+connect)
--   deps.connect_poll  function(handle) -> "ok"|"wait"|"fail"    (select(0))
--   deps.connect_close function(handle)
--   deps.connect_blocking function(ip, port, timeout) -> bool    (settimeout(t)+connect; warm_blocking only)
--   deps.schedule      function(delay, fn)                       (UIManager:scheduleIn)
--   deps.persist_ip    function(host, ip)            optional    (save across sessions)
--   deps.initial_ip    string                        optional    (seed from persistence)
--   deps.initial_host  string                        optional
--   deps.ttl           number  default 300   verdict freshness window (s)
--   deps.probe_timeout number  default 2     bounded connect (s)
--   deps.poll_interval number  default 0.25  gap between non-blocking polls (s)
--   deps.ip_ttl        number  default 1800  re-resolve the cached IP after (s)
--
-- FAIL-OPEN where we genuinely cannot tell -- exactly like `reachability.lua`:
-- a wrong "unreachable" would strand a sync the user wants, and KOReader's own
-- link gate plus socketutil are still in front.
--
-- =============================================================================


local CloudReachability = {}
CloudReachability.__index = CloudReachability

local Reachability = require("syncery_transports/cloud/reachability")

local DEFAULT_TTL           = 300     -- a reachable/unreachable verdict is trusted this long
local DEFAULT_PROBE_TIMEOUT = 2       -- the non-blocking connect gives up after this
local DEFAULT_POLL_INTERVAL = 0.25    -- gap between instant select(0) polls
local DEFAULT_IP_TTL        = 1800    -- re-resolve the cached IP after this (catches a moved server)


--- @param deps table  see the module header
--- @return table  a CloudReachability instance
function CloudReachability.new(deps)
    deps = deps or {}
    local self = setmetatable({}, CloudReachability)
    self.now           = deps.now           or os.time
    self.get_server    = deps.get_server
    self.resolve       = deps.resolve
    self.connect_start = deps.connect_start
    self.connect_poll  = deps.connect_poll
    self.connect_close = deps.connect_close
    self.connect_blocking = deps.connect_blocking
    self.schedule      = deps.schedule
    self.persist_ip    = deps.persist_ip
    self.ttl           = deps.ttl           or DEFAULT_TTL
    self.probe_timeout = deps.probe_timeout or DEFAULT_PROBE_TIMEOUT
    self.poll_interval = deps.poll_interval or DEFAULT_POLL_INTERVAL
    self.ip_ttl        = deps.ip_ttl        or DEFAULT_IP_TTL

    -- Verdict state.  verdict is "reachable" | "unreachable" | "unknown".
    self.verdict    = "unknown"
    self.verdict_at = nil               -- when the verdict was last set

    -- Cached IP for non-blocking connects (seeded from persistence).
    self.cached_ip   = deps.initial_ip
    self.cached_host = deps.initial_host
    self.cached_port = nil
    self.cached_ip_at = (deps.initial_ip and self.now()) or nil

    -- In-flight probe state.
    self.probing        = false
    self.probe_handle   = nil
    self.probe_deadline = nil

    return self
end


-- ----------------------------------------------------------------------------
-- Verdict read (instant, never blocks) -- THE GATE the callers use.
-- ----------------------------------------------------------------------------

--- Is the cloud server reachable right now?  Reads the cached verdict; on a
--- stale/unknown verdict it kicks off a background non-blocking probe (so a
--- later retry gets a firm answer) and meanwhile DEFERS -- except when no IP is
--- cached yet, where it fails OPEN to let a first transfer seed the IP.
--- @return boolean
function CloudReachability:is_reachable()
    local fresh = self.verdict_at ~= nil
        and self.now() < self.verdict_at + self.ttl

    if self.verdict == "reachable"   and fresh then return true  end
    if self.verdict == "unreachable" and fresh then return false end

    -- Unknown, or the verdict has expired: refresh in the background.
    if self.cached_ip then
        self:_start_probe()
        return false                    -- defer; the probe (or a retry) firms it up
    end

    -- No IP cached yet -> we cannot probe without a blocking resolve, and
    -- blocking is the whole thing we avoid.  Fail OPEN so one transfer can run;
    -- its success will seed the IP via note_success(), and every probe after
    -- that is non-blocking.
    return true
end


--- Force a FIRM verdict synchronously, for a TERMINAL caller (teardown's
--- close-time push) where there is no future UI tick for the non-blocking probe
--- to resolve on.  `is_reachable()` would start that probe and DEFER -- but at
--- teardown the deferred retry fires after the transport has shut down and the
--- push is dropped, so the close-time upload is lost.  This does ONE bounded,
--- BLOCKING connect to the CACHED IP (no DNS -> cannot hang on a dead resolver,
--- and bounded by probe_timeout) and sets the verdict, so the very next
--- `is_reachable()` returns true/false WITHOUT deferring and the push proceeds
--- (or is correctly skipped) inline, before shutdown.
---
--- Deliberately narrow, so the hot path is untouched and no DNS is ever added:
---   * no blocking connector injected (headless) -> no-op;
---   * no cached IP yet                          -> no-op (the caller's
---     `is_reachable()` then fails open exactly as before -- unchanged).
--- A stale cached IP (server moved since last session) connects-fails here ->
--- verdict unreachable -> this one close-push is skipped; note_success on the
--- next session's first successful sync re-resolves and self-heals it.
function CloudReachability:warm_blocking()
    if type(self.connect_blocking) ~= "function" then return end
    if not self.cached_ip then return end

    local port = self.cached_port
    if not port and type(self.get_server) == "function" then
        local _, p = Reachability.host_port_for(self.get_server())
        port = p
    end
    if not port then return end

    local ok = self.connect_blocking(self.cached_ip, port, self.probe_timeout)
    self.verdict    = ok and "reachable" or "unreachable"
    self.verdict_at = self.now()
end


-- ----------------------------------------------------------------------------
-- Outcome + event hooks that move the verdict WITHOUT a probe.
-- ----------------------------------------------------------------------------

--- A cloud transfer just SUCCEEDED -> reachable (proof), and -- at this
--- network-up moment, where DNS is fast and safe -- cache the server IP if it
--- is missing or stale, so future probes connect without resolving.
function CloudReachability:note_success()
    self.verdict    = "reachable"
    self.verdict_at = self.now()
    self:_maybe_refresh_ip()
end

--- A cloud transfer just FAILED -> unreachable (no I/O; the caller's wifi
--- backoff schedules the retry, by which time a probe / event has firmed up
--- the verdict).
function CloudReachability:note_failure()
    self.verdict    = "unreachable"
    self.verdict_at = self.now()
end

--- The network just went down (NetworkDisconnected) -> unreachable instantly,
--- no probe, no DNS.
function CloudReachability:on_network_disconnected()
    self.verdict    = "unreachable"
    self.verdict_at = self.now()
end

--- The network just came up (NetworkConnected).  "Connected" is not "internet
--- reachable" (captive portal), and it may be a DIFFERENT network, so drop to
--- unknown and -- if an IP is cached -- re-verify in the background.
function CloudReachability:on_network_connected()
    self.verdict    = "unknown"
    self.verdict_at = nil
    if self.cached_ip then
        self:_start_probe()
    end
end


-- ----------------------------------------------------------------------------
-- IP caching (the ONLY synchronous resolve; post-success, network-up).
-- ----------------------------------------------------------------------------

function CloudReachability:_maybe_refresh_ip()
    if type(self.resolve) ~= "function" or type(self.get_server) ~= "function" then
        return
    end
    local host, port = Reachability.host_port_for(self.get_server())
    if not host then return end         -- unprobeable server type -> nothing to cache

    local stale = self.cached_ip == nil
        or self.cached_host ~= host
        or (self.cached_ip_at ~= nil and self.now() >= self.cached_ip_at + self.ip_ttl)
    if not stale then return end

    local ip = self.resolve(host)       -- network is up (we just succeeded) -> fast
    if not ip then return end
    self.cached_ip    = ip
    self.cached_host  = host
    self.cached_port  = port
    self.cached_ip_at = self.now()
    if type(self.persist_ip) == "function" then
        self.persist_ip(host, ip)
    end
end


-- ----------------------------------------------------------------------------
-- Non-blocking probe: settimeout(0) connect to the CACHED IP, polled across UI
-- ticks with an instant select(0).  No single call blocks.
-- ----------------------------------------------------------------------------

function CloudReachability:_start_probe()
    if self.probing then return end
    if not self.cached_ip then return end
    if type(self.connect_start) ~= "function"
            or type(self.connect_poll) ~= "function"
            or type(self.schedule) ~= "function" then
        return                          -- no probe I/O (headless) -> verdict stays as is
    end

    -- The probe targets the cached host's port; fall back to the freshly
    -- derived port if the cache predates a port (seeded IP without one).
    local port = self.cached_port
    if not port and type(self.get_server) == "function" then
        local _, p = Reachability.host_port_for(self.get_server())
        port = p
    end
    if not port then return end

    local handle = self.connect_start(self.cached_ip, port)
    if not handle then
        -- Could not even begin the connect -> treat as unreachable.
        self.verdict    = "unreachable"
        self.verdict_at = self.now()
        return
    end

    self.probing        = true
    self.probe_handle   = handle
    self.probe_deadline = self.now() + self.probe_timeout
    self.schedule(self.poll_interval, function() self:_poll_probe() end)
end

function CloudReachability:_poll_probe()
    if not self.probing then return end

    local r = self.connect_poll(self.probe_handle)
    if r == "ok" then
        self:_finish_probe("reachable")
    elseif r == "fail" then
        self:_finish_probe("unreachable")
    else -- "wait"
        if self.now() >= self.probe_deadline then
            self:_finish_probe("unreachable")     -- bounded: gave up after probe_timeout
        else
            self.schedule(self.poll_interval, function() self:_poll_probe() end)
        end
    end
end

function CloudReachability:_finish_probe(verdict)
    self.verdict    = verdict
    self.verdict_at = self.now()
    if type(self.connect_close) == "function" and self.probe_handle then
        self.connect_close(self.probe_handle)
    end
    self.probing      = false
    self.probe_handle = nil
end


CloudReachability.DEFAULT_TTL           = DEFAULT_TTL
CloudReachability.DEFAULT_PROBE_TIMEOUT = DEFAULT_PROBE_TIMEOUT
CloudReachability.DEFAULT_POLL_INTERVAL = DEFAULT_POLL_INTERVAL
CloudReachability.DEFAULT_IP_TTL        = DEFAULT_IP_TTL


return CloudReachability
