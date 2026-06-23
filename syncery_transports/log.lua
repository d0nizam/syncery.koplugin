-- =============================================================================
-- syncery_transports/log.lua
-- =============================================================================
--
-- A tiny tagged-logger facade.  Wraps KOReader's `logger` module so that
-- every log line emitted from this subsystem has a consistent prefix:
--
--     Syncery[orchestrator]: scheduling retry for cloud in 30s
--     Syncery[transport:syncthing]: scan triggered
--     Syncery[policy]: classified 'unreachable' as transient
--
-- WHY THIS EXISTS
--
-- Three reasons.  First, the legacy code logs as plain
-- `logger.info("Syncery: ...")` with hand-written prefixes, which means
-- the prefix drifts (`"Syncery:"`, `"Syncery: cloud:"`, `"syncery"`)
-- and grepping the logs is annoying.  Second, by routing every log
-- line through this module, tests can swap out the logger trivially
-- (the test helper already does — `null_logger` discards everything).
-- Third, when we later want to add per-tag log levels ("show me only
-- orchestrator and transport:syncthing lines") this is the one
-- bottleneck where that gets implemented.
--
-- USAGE
--
--     local Log = require("syncery_transports/log")
--     local log = Log.tag("orchestrator")
--     log.info("starting push for %s", book_file)
--     log.warn("transport %s reported %s", t.id(), err)
--     log.dbg("state: %s", inspect(state))      -- shown only with verbose
--
-- The string-format style is convenient (no `..` chains) and forgiving
-- (any extra args after the format string are stringified by tostring()
-- if the format doesn't consume them).
--
-- =============================================================================


local Log = {}


-- ----------------------------------------------------------------------------
-- Underlying logger module.  We re-require on each call so the test
-- harness's stub (installed into package.loaded by spec/test_helpers)
-- wins over any cached reference.
-- ----------------------------------------------------------------------------


local function backend()
    return require("logger")
end


-- ----------------------------------------------------------------------------
-- Format a log message safely.  string.format crashes on
-- argument-type/format mismatch, so wrap in pcall — a broken log call
-- shouldn't take down the caller.
-- ----------------------------------------------------------------------------


local function safe_format(fmt, ...)
    if select("#", ...) == 0 then return fmt end
    local ok, formatted = pcall(string.format, fmt, ...)
    if ok then return formatted end
    -- Fall back to space-joining; never crash a logging call.
    local parts = { tostring(fmt) }
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    return table.concat(parts, " ")
end


-- ----------------------------------------------------------------------------
-- Build a tagged logger.  Returned table has `info`, `warn`, `dbg`.
-- ----------------------------------------------------------------------------


--- Make a logger that prefixes every line with "Syncery[<tag>]: ".
---@param tag string
---@return table { info = fn, warn = fn, dbg = fn }
function Log.tag(tag)
    assert(type(tag) == "string" and tag ~= "",
        "Log.tag: tag must be a non-empty string")
    local prefix = "Syncery[" .. tag .. "]: "

    return {
        info = function(fmt, ...)
            backend().info(prefix .. safe_format(fmt, ...))
        end,
        warn = function(fmt, ...)
            backend().warn(prefix .. safe_format(fmt, ...))
        end,
        dbg = function(fmt, ...)
            backend().dbg(prefix .. safe_format(fmt, ...))
        end,
    }
end


return Log
