-- =============================================================================
-- syncery_transports/safe_callback.lua
-- =============================================================================
--
-- Wraps a callback so:
--
--   1. It can fire AT MOST ONCE.  Every additional invocation is
--      silently swallowed (and logged at warn level so we notice).
--      This is the load-bearing invariant of the entire transport
--      layer — the orchestrator relies on every push() and pull()
--      firing its callback exactly once.
--
--   2. The wrapped fn is pcalled.  A broken handler that raises a Lua
--      error cannot propagate up into transport internals and corrupt
--      orchestrator state.  The error is logged with the debug tag.
--
--   3. If the callback never fires within a deadline, the wrapper can
--      synthesize a `callback(false, "internal", nil)` so callers
--      don't hang forever.  (Opt-in; default is no deadline.)
--
-- WHY THIS EXISTS
--
-- The legacy transport code has subtle double-fire bugs.  Example
-- from syncery_syncthing.lua's `do_http_request`:
--
--     if not ok then
--         if callback then callback(false, nil, "unreachable") end
--         return true
--     end
--     if res == nil then
--         if callback then callback(false, nil, "unreachable") end
--         return true
--     end
--     if code == 200 ... then
--         if callback then callback(true, ...) end
--     else
--         if callback then callback(false, ...) end
--     end
--
-- The structure is correct today, but it's the kind of code that
-- grows a third error branch one day and someone forgets the early
-- `return`.  Wrapping the callback at the top of the function turns
-- "double-fire" from a silent bug ("why did Cloud upload twice?") into
-- a logged warning that points at exactly the wrong call site.
--
-- USAGE
--
--     local once = SafeCallback.once(callback, "syncthing.ping")
--     -- ... can call once() any number of times; only the first lands.
--
--     local once_with_deadline = SafeCallback.once(callback, "tag", {
--         deadline_seconds = 30,
--         scheduler = function(delay, fn) UIManager:scheduleIn(delay, fn) end,
--     })
--
-- =============================================================================


local Log = require("syncery_transports/log")
local log = Log.tag("safe_callback")


local SafeCallback = {}


-- ----------------------------------------------------------------------------
-- Helper: a no-op so callers don't have to special-case `nil` callbacks.
-- ----------------------------------------------------------------------------


local function noop() end


-- ----------------------------------------------------------------------------
-- The wrapper itself.
-- ----------------------------------------------------------------------------


--- Wrap `callback` so it fires at most once, pcalled, and (optionally)
--- with a deadline that synthesizes an `internal` failure.
---
--- Returns a function with the same calling shape as the wrapped one.
--- A nil callback returns a no-op — saves every caller from having to
--- write `if callback then callback(...) end`.
---
--- The returned function additionally has two methods:
---   .fired() → bool      — true once it's been called (even pre-deadline)
---   .cancel()           — prevents future invocations, including any
---                          pending deadline timeout.  After cancel(),
---                          the wrapper behaves as already-fired.
---
---@param callback function|nil
---@param debug_tag string
---@param opts table|nil  { deadline_seconds, scheduler, on_late }
---@return function
function SafeCallback.once(callback, debug_tag, opts)
    if callback == nil then return noop end
    assert(type(callback) == "function",
        "SafeCallback.once: callback must be function or nil, got "
        .. type(callback))
    assert(type(debug_tag) == "string" and debug_tag ~= "",
        "SafeCallback.once: debug_tag must be a non-empty string")
    opts = opts or {}

    local fired      = false
    local cancelled  = false
    local deadline_fired = false

    local function invoke(...)
        if fired or cancelled then
            if not cancelled then
                -- Already fired but called again — that's the bug we're
                -- here to catch.  Log once per redundant call so the
                -- log shows the order of double-fires.
                log.warn("double-fire suppressed at %s; args[1]=%s",
                    debug_tag, tostring((select(1, ...))))
            end
            return
        end
        fired = true
        local ok, err = pcall(callback, ...)
        if not ok then
            log.warn("callback at %s raised: %s", debug_tag, tostring(err))
        end
    end

    -- Optional deadline.  If the wrapped callback hasn't fired within
    -- `deadline_seconds`, synthesize a failure so the caller's chain
    -- can complete instead of hanging.  This is opt-in because most
    -- callers don't want timer-driven semantics; e.g. an in-memory
    -- fake transport callback fires synchronously and never needs a
    -- deadline.  Real network transports usually do.
    if opts.deadline_seconds and opts.scheduler then
        local schedule = opts.scheduler
        schedule(opts.deadline_seconds, function()
            if fired or cancelled then return end
            deadline_fired = true
            log.warn("deadline (%ss) expired at %s; synthesizing failure",
                opts.deadline_seconds, debug_tag)
            invoke(false, "internal", nil)
            if opts.on_late then pcall(opts.on_late) end
        end)
    end

    -- Bolt on .fired() / .cancel() / .deadline_fired() via a wrapper
    -- table.  We can't put fields on a function value in pure Lua, but
    -- a table with __call works the same way at call sites.
    local wrapper = setmetatable({}, { __call = function(_, ...) invoke(...) end })
    wrapper.fired          = function() return fired end
    wrapper.cancel         = function() cancelled = true end
    wrapper.deadline_fired = function() return deadline_fired end
    return wrapper
end


return SafeCallback
