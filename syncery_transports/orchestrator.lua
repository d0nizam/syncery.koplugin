-- =============================================================================
-- syncery_transports/orchestrator.lua
-- =============================================================================
--
-- The centralized-policy engine for the transport layer.
--
-- The orchestrator is the only thing that:
--   • holds the registered transports
--   • holds the per-book per-transport push state
--   • decides (via Policy) when each transport should be attempted
--   • schedules retries
--   • aggregates status for the UI
--
-- It does NOT do any I/O itself.  Every byte that moves between this
-- device and a peer is moved by a Transport implementation.  The
-- orchestrator just orchestrates.
--
-- The split — orchestrator holds state, Policy is pure functions,
-- Transports are dumb executors — means each piece is independently
-- testable:
--
--   • Policy is tested by passing inputs and reading outputs.
--   • Transports are tested by exercising push/pull against fakes.
--   • The orchestrator is tested with a fake Policy, a fake clock, a
--     fake scheduler, and a fake transport — every dependency is
--     injectable so the tests don't touch UIManager, the network,
--     or the filesystem.
--
-- The same separation is what lets us change retry timings without
-- editing the orchestrator, swap transports without rewriting policy,
-- or fake any of the three for tests.
--
--
-- USAGE
--
--     local Orchestrator = require("syncery_transports/orchestrator")
--
--     local orch, err = Orchestrator.new({
--         transports = { syncthing_transport, cloud_transport },
--         clock      = function() return os.time() end,
--         scheduler  = function(delay, fn) UIManager:scheduleIn(delay, fn) end,
--     })
--     if not orch then error("orchestrator init failed: " .. tostring(err)) end
--
--     orch:push_book("/books/x.epub", { payload = "..." })
--     -- ... orchestrator decides per-transport whether to attempt,
--     -- ... debounces, retries on transient errors, etc.
--
--     local statuses = orch:get_status()
--     -- → { syncthing = { ... }, cloud = { ... } }
--
--     orch:shutdown()
--
--
-- DESIGN NOTE: NO MODULE-LEVEL STATE
--
-- Every piece of state lives on the instance (`self`).  `new()` is the
-- only entry point for creating an orchestrator; calling new() twice
-- gives you two independent instances that don't share state.  This
-- matters for tests (they create a fresh orch per test), and for the
-- plugin lifecycle (a teardown followed by re-init should NOT see
-- ghost state from before).
--
-- =============================================================================


local Interface     = require("syncery_transports/interface")
local Policy        = require("syncery_transports/policy")
local SafeCallback  = require("syncery_transports/safe_callback")
local Log           = require("syncery_transports/log")
local log           = Log.tag("orchestrator")


local Orchestrator = {}
Orchestrator.__index = Orchestrator


-- ----------------------------------------------------------------------------
-- Constructor.
-- ----------------------------------------------------------------------------


--- Build a new orchestrator instance.
---
--- Required opts:
---   transports — list of Transport implementations.  Each MUST satisfy
---                Interface.validate_implementation.  new() returns
---                nil + error string on failure (loud-but-non-fatal,
---                so the plugin can degrade gracefully if one transport
---                fails to load).
---
--- Optional opts:
---   clock         — function() → unix seconds.  Default os.time.
---                    Tests inject a controllable fake.
---   scheduler     — function(delay_seconds, fn).  Default uses
---                    UIManager:scheduleIn if available, else a degenerate
---                    "immediate" scheduler that runs fn synchronously
---                    (only used when KOReader isn't loaded, i.e. in tests
---                    that don't bother providing one).
---   policy_config — table, same shape as Policy.DEFAULT_CONFIG.  Overrides
---                    the defaults per-transport.
---   on_status_change — function() — called after any state change that
---                    might be reflected in the status panel.  The plugin
---                    wires this to a redraw.
---
---@param opts table
---@return table|nil orchestrator
---@return string|nil error
function Orchestrator.new(opts)
    opts = opts or {}

    -- ----- Validate transports up front (cheap-class-of-bug check) -----
    if type(opts.transports) ~= "table" then
        return nil, "transports must be a list of Transport tables"
    end
    if #opts.transports == 0 then
        log.warn("constructed with zero transports; push_book will be a no-op")
    end

    local seen_ids = {}
    for i, t in ipairs(opts.transports) do
        local ok, problems = Interface.validate_implementation(t)
        if not ok then
            return nil, string.format(
                "transports[%d] is not a valid Transport: %s",
                i, table.concat(problems, "; "))
        end
        local id = t.id()
        if seen_ids[id] then
            return nil, string.format(
                "transports[%d] has duplicate id '%s'", i, id)
        end
        seen_ids[id] = true
    end

    -- ----- Resolve injectable dependencies -----
    local clock = opts.clock or function() return os.time() end
    local scheduler = opts.scheduler
    if not scheduler then
        -- Best-effort default; tests should pass an injected one.  We
        -- check for UIManager defensively so this module can be loaded
        -- (and tested) without KOReader.
        local ok_ui, UIManager = pcall(require, "ui/uimanager")
        if ok_ui and UIManager and UIManager.scheduleIn then
            scheduler = function(delay, fn) UIManager:scheduleIn(delay, fn) end
        else
            -- Fallback: run immediately.  Surprising for production but
            -- harmless for tests that don't exercise scheduling.
            scheduler = function(_delay, fn) fn() end
        end
    end

    local self = setmetatable({}, Orchestrator)
    self._transports        = opts.transports
    self._clock             = clock
    self._scheduler         = scheduler
    self._policy_config     = opts.policy_config or Policy.DEFAULT_CONFIG
    self._on_status_change  = opts.on_status_change or function() end
    self._shutdown          = false

    -- Per-transport per-book state.  Keyed [transport_id][book_file]:
    --   { last_attempt_at, last_success_at, consecutive_failures,
    --     pending_retry_at, last_error_class }
    self._state = {}
    for _, t in ipairs(opts.transports) do
        self._state[t.id()] = {}
    end

    -- Pending retry handles, so shutdown() can cancel them.  Each entry:
    --   { cancelled = bool }
    -- We can't actually cancel a UIManager:scheduleIn callback, but the
    -- fired callback checks this flag and bails if cancelled.
    self._pending_retries = {}

    log.info("initialized with %d transport(s): %s",
        #opts.transports, self:_transport_ids_csv())
    return self
end


-- ----------------------------------------------------------------------------
-- Internal helpers.
-- ----------------------------------------------------------------------------


function Orchestrator:_transport_ids_csv()
    local ids = {}
    for _, t in ipairs(self._transports) do ids[#ids + 1] = t.id() end
    return table.concat(ids, ",")
end


--- Lazy-init and return the state entry for (transport_id, book_file).
function Orchestrator:_state_for(transport_id, book_file)
    local by_book = self._state[transport_id]
    if not by_book then
        -- shouldn't happen — _state was initialized in new()
        by_book = {}
        self._state[transport_id] = by_book
    end
    local entry = by_book[book_file]
    if not entry then
        entry = {
            last_attempt_at      = nil,
            last_success_at      = nil,
            consecutive_failures = 0,
            pending_retry_at     = nil,
            last_error_class     = nil,
        }
        by_book[book_file] = entry
    end
    return entry
end


-- ----------------------------------------------------------------------------
-- The main API: push_book.
--
-- For each registered transport: ask Policy if we should attempt, and
-- if so, call push.  On the callback, ask Policy what to do with the
-- result (retry / give up / reset failure counter) and schedule
-- accordingly.
--
-- Returns immediately — push_book is fire-and-forget for callers.
-- (Tests can observe completion by reading state after the scheduler
-- has run any pending tasks.)
-- ----------------------------------------------------------------------------


--- Push the given book through every available transport.
---
--- @param book_file string         absolute path to the book
--- @param opts table|nil           passed verbatim to each transport's push
--- @param caller_opts table|nil    options the orchestrator itself reads:
---                                   force = bool | table  — bypass debounce/
---                                     backoff.  `true` forces ALL transports
---                                     (the "Sync Now" hatch); a set {[tid]=true}
---                                     forces ONLY those — so a terminal Syncthing
---                                     scan can bypass policy for Syncthing without
---                                     also forcing its nil payload onto Cloud
---                                     (which would REJECT and clobber a just-sent
---                                     cloud upload's status).
function Orchestrator:push_book(book_file, opts, caller_opts)
    if self._shutdown then
        log.warn("push_book after shutdown; ignoring")
        return
    end
    caller_opts = caller_opts or {}
    local now = self._clock()

    local force = caller_opts.force
    local function _forced(tid)
        if force == true then return true end
        return type(force) == "table" and force[tid] == true
    end

    for _, transport in ipairs(self._transports) do
        local tid = transport.id()

        -- ----- Transport-level gate -----
        if not transport.is_available() then
            log.dbg("skipping %s: not available", tid)
        else
            -- ----- Policy-level gate -----
            local state  = self:_state_for(tid, book_file)
            local config = Policy.config_for(tid, self._policy_config)

            local proceed, reason = true, nil
            if not _forced(tid) then
                proceed, reason = Policy.should_attempt(state, now, config)
            end

            if not proceed then
                log.dbg("skipping %s for %s: %s", tid, book_file, reason)
            else
                self:_attempt_push(transport, book_file, opts, 1)
            end
        end
    end
end


--- The per-attempt push.  Recursive via the retry scheduler (`attempt_n`
--- increments per retry).  Lives below push_book so push_book stays
--- readable as the top-level decision flow.
function Orchestrator:_attempt_push(transport, book_file, opts, attempt_n)
    if self._shutdown then return end

    local tid   = transport.id()
    local state = self:_state_for(tid, book_file)
    local now   = self._clock()

    state.last_attempt_at = now
    state.pending_retry_at = nil

    local cb = SafeCallback.once(function(ok, err, _extra)
        self:_on_push_result(transport, book_file, opts, attempt_n, ok, err)
    end, "orchestrator.push:" .. tid)

    -- pcall the transport call itself: a bug in a transport that
    -- raises a Lua error should NOT take down the orchestrator.
    -- We funnel it through the same callback path as a normal error.
    local ok_call, call_err = pcall(transport.push, book_file, opts, cb)
    if not ok_call then
        log.warn("transport %s.push raised: %s", tid, tostring(call_err))
        cb(false, Interface.ERRORS.INTERNAL, nil)
    end
end


--- React to a push result: update state, decide whether to retry.
function Orchestrator:_on_push_result(transport, book_file, opts, attempt_n, ok, err)
    if self._shutdown then return end

    local tid    = transport.id()
    local state  = self:_state_for(tid, book_file)
    local config = Policy.config_for(tid, self._policy_config)

    if ok then
        state.last_success_at      = self._clock()
        state.consecutive_failures = 0
        state.last_error_class     = nil
        log.dbg("%s push ok for %s", tid, book_file)
        self._on_status_change()
        return
    end

    -- Failure path.
    state.consecutive_failures = (state.consecutive_failures or 0) + 1
    state.last_error_class     = Policy.classify_error(err)
    log.info("%s push failed for %s: %s (class=%s, attempt=%d)",
        tid, book_file, tostring(err), state.last_error_class, attempt_n)

    if not Policy.is_retriable(err, attempt_n) then
        log.dbg("not retrying %s: error class %s",
            tid, state.last_error_class)
        self._on_status_change()
        return
    end

    local delay = Policy.next_retry_delay(config.retry_schedule, attempt_n)
    if not delay then
        log.info("retry schedule exhausted for %s on %s", tid, book_file)
        self._on_status_change()
        return
    end

    -- Schedule the next attempt.  Capture a per-retry handle so
    -- shutdown() can defuse it.
    state.pending_retry_at = self._clock() + delay
    local handle = { cancelled = false }
    self._pending_retries[#self._pending_retries + 1] = handle

    log.dbg("scheduling retry %d for %s on %s in %ds",
        attempt_n + 1, tid, book_file, delay)

    self._scheduler(delay, function()
        if handle.cancelled or self._shutdown then return end
        -- The transport may have been disabled (toggle off) since this retry
        -- was scheduled.  push_book gates fresh pushes on is_available();
        -- scheduled retries bypass that gate, so without this re-check a
        -- transport the user turned off keeps probing forever.  When it has
        -- gone unavailable, drop the retry and do NOT reschedule (the chain
        -- dies).  Touch no state -> the backoff fields Policy.should_attempt
        -- reads (pending_retry_at / consecutive_failures) stay intact.
        if not transport.is_available() then
            log.dbg("retry for %s dropped: transport no longer available", tid)
            return
        end
        self:_attempt_push(transport, book_file, opts, attempt_n + 1)
    end)

    self._on_status_change()
end


-- ----------------------------------------------------------------------------
-- pull_book — analogous to push_book but inbound.
--
-- Unlike push, pull is request-response: callers want the pulled
-- payload back.  We aggregate per-transport results into a single
-- callback fired once after all transports have reported.
-- ----------------------------------------------------------------------------


--- Pull state for the given book from every available transport.
---
--- The callback receives a table keyed by transport_id:
---   { syncthing = { ok = true,  err = nil, payload = ... },
---     cloud     = { ok = false, err = "auth_failed", payload = nil } }
---
--- Transports that report `is_available() == false` are not represented
--- in the result table (the caller can tell them apart from "available
--- but errored" if they care).
---
---@param book_file string
---@param opts table|nil
---@param callback function(results: table)
function Orchestrator:pull_book(book_file, opts, callback)
    if self._shutdown then
        if callback then callback({}) end
        return
    end

    -- Filter to available transports up front so the "did everyone
    -- finish" check is bounded by the available set, not the registered
    -- set.  Otherwise an unavailable transport never reports and the
    -- callback never fires.
    local active = {}
    for _, t in ipairs(self._transports) do
        if t.is_available() then active[#active + 1] = t end
    end

    if #active == 0 then
        if callback then callback({}) end
        return
    end

    local results = {}
    local pending = #active
    local aggregate_cb = SafeCallback.once(function() callback(results) end,
        "orchestrator.pull:aggregate")

    for _, transport in ipairs(active) do
        local tid = transport.id()
        local per_cb = SafeCallback.once(function(ok, err, payload)
            results[tid] = { ok = ok, err = err, payload = payload }
            pending = pending - 1
            if pending == 0 then aggregate_cb() end
        end, "orchestrator.pull:" .. tid)

        local ok_call, call_err = pcall(transport.pull, book_file, opts, per_cb)
        if not ok_call then
            log.warn("transport %s.pull raised: %s", tid, tostring(call_err))
            per_cb(false, Interface.ERRORS.INTERNAL, nil)
        end
    end
end


-- ----------------------------------------------------------------------------
-- Status — for the status panel UI.
-- ----------------------------------------------------------------------------


--- Aggregate status for every registered transport.  Returns a table
--- keyed by transport_id.  Each value is the transport's own
--- `status()` table, plus orchestrator-supplied fields:
---   last_error_class — from the most recent failed push (any book)
---   any_pending_retry — true if any book has a pending retry
---@return table
function Orchestrator:get_status()
    local out = {}
    for _, transport in ipairs(self._transports) do
        local tid = transport.id()
        local ok_call, status = pcall(transport.status)
        if not ok_call or type(status) ~= "table" then
            log.warn("transport %s.status raised or returned non-table; using stub", tid)
            status = {
                display_name = transport.display_name(),
                available    = false,
                summary      = "status unavailable (internal error)",
            }
        end

        -- Decorate with the orchestrator's view of recent failures.
        -- Pick the most recent error class across all this transport's
        -- books.  Useful for the status panel's "you need to configure
        -- transport" banner.
        local most_recent_error_class = nil
        local any_pending_retry       = false
        local most_recent_at          = 0
        for _, entry in pairs(self._state[tid] or {}) do
            if entry.pending_retry_at then any_pending_retry = true end
            if entry.last_attempt_at and entry.last_attempt_at > most_recent_at
               and entry.last_error_class then
                most_recent_at          = entry.last_attempt_at
                most_recent_error_class = entry.last_error_class
            end
        end
        status.orch_last_error_class  = most_recent_error_class
        status.orch_any_pending_retry = any_pending_retry

        out[tid] = status
    end
    return out
end


-- ----------------------------------------------------------------------------
-- Inspection (for tests and the status panel "debug" view).
-- ----------------------------------------------------------------------------


--- Read-only snapshot of state for (transport_id, book_file), or nil.
function Orchestrator:peek_state(transport_id, book_file)
    local by_book = self._state[transport_id]
    if not by_book then return nil end
    local entry = by_book[book_file]
    if not entry then return nil end
    return {
        last_attempt_at      = entry.last_attempt_at,
        last_success_at      = entry.last_success_at,
        consecutive_failures = entry.consecutive_failures,
        pending_retry_at     = entry.pending_retry_at,
        last_error_class     = entry.last_error_class,
    }
end


--- Per-book state for every book this transport has touched.
---
--- `peek_state` answers "what's the state of THIS book on THIS
--- transport"; the status panel needs the other axis — "show me every
--- book with interesting state on this transport" — so it can list
--- per-book pending retries.  Rather than make the panel iterate book
--- files it doesn't know, this returns the whole per-transport map.
---
--- Returns a list (not a map) of `{ book_file = <string>, state =
--- <peek_state table> }`, so the caller gets a stable, sortable shape.
--- Empty list when the transport is unknown or has touched no books.
---@param transport_id string
---@return table list of { book_file, state }
function Orchestrator:peek_transport_books(transport_id)
    local out = {}
    local by_book = self._state[transport_id]
    if not by_book then return out end
    for book_file, entry in pairs(by_book) do
        out[#out + 1] = {
            book_file = book_file,
            state = {
                last_attempt_at      = entry.last_attempt_at,
                last_success_at      = entry.last_success_at,
                consecutive_failures = entry.consecutive_failures,
                pending_retry_at     = entry.pending_retry_at,
                last_error_class     = entry.last_error_class,
            },
        }
    end
    return out
end


--- Look up a transport by its id.  Returns the transport table, or nil
--- if no transport with that id is registered.  Used by the bridge for
--- transport-specific surfaces that aren't part of the uniform push/pull
--- interface (ignore-pattern registration, KOSyncthing+-only quick-sync trigger).
---@param transport_id string
---@return table|nil
function Orchestrator:find_transport(transport_id)
    if type(transport_id) ~= "string" then return nil end
    for _, t in ipairs(self._transports) do
        if t.id() == transport_id then return t end
    end
    return nil
end


-- ----------------------------------------------------------------------------
-- Lifecycle.
-- ----------------------------------------------------------------------------


--- Cancel pending retries and refuse new pushes.  Safe to call
--- multiple times; subsequent calls are no-ops.  Idempotent by design
--- so the plugin's teardown path can call this without checking state.
function Orchestrator:shutdown()
    if self._shutdown then return end
    self._shutdown = true
    for _, handle in ipairs(self._pending_retries) do
        handle.cancelled = true
    end
    self._pending_retries = {}
    log.info("shutdown complete")
end


return Orchestrator
