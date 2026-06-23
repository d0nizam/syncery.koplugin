-- =============================================================================
-- syncery_transports/policy.lua
-- =============================================================================
--
-- ALL pure functions.  This module decides:
--
--   • Whether an error is worth retrying        ← classify_error
--   • How long to wait before the next retry    ← next_retry_delay
--   • Whether enough time has passed since the
--     last push to warrant another              ← is_debounced
--   • Whether to surface an error to the user   ← needs_user_attention
--
-- It does NOT:
--
--   • Schedule timers                — that's the orchestrator's job
--   • Track time / state             — likewise
--   • Call into transports           — likewise
--   • Read globals or KOReader APIs  — no I/O of any kind
--
-- Why so strict about purity?  Because policy is the thing we change
-- most often — "retry cloud more aggressively", "let cloud back off
-- harder", "treat 429 as retriable" — and the change-most-often code
-- should be the easiest to test.  A pure function is the easiest
-- possible thing to test: no setup, no teardown, no mocking.
--
-- ARCHITECTURAL NOTE
--
-- This file is part of the "centralized policy, decentralized
-- execution" design.  The plain-English version:
--
--   • Policy   (this file) decides WHAT to do.
--   • Transports decide HOW to do it.
--   • Orchestrator wires them together: it asks Policy for decisions,
--     calls Transports to act on them, and owns all the state
--     (timers, counters, last-push timestamps) that policy decisions
--     read.
--
-- The previous structure had policy splattered across each transport
-- and across main.lua.  Want to know when Cloud retries?  Read three
-- files and reverse-engineer.  Now: read this one.
--
-- =============================================================================


local Interface = require("syncery_transports/interface")


local Policy = {}


-- ----------------------------------------------------------------------------
-- Error classes.
--
-- We classify each error returned by a transport into one of four
-- buckets.  Every downstream branch (retry? log? show in UI? user
-- attention?) reads the class, not the original string.  This lets
-- us add a new error string in one place (interface.lua + the
-- classification table here) without auditing every consumer.
-- ----------------------------------------------------------------------------


--- Transient: a different attempt later might succeed.  Worth retrying
--- per the per-transport schedule.
Policy.CLASS_TRANSIENT     = "transient"
--- Permanent: the operation itself is wrong.  Retrying will not help.
--- Don't retry; log; don't badger the user.
Policy.CLASS_PERMANENT     = "permanent"
--- Configuration: the transport is set up wrong (missing key, wrong
--- credentials).  Don't retry; surface to the user as "please configure".
Policy.CLASS_CONFIG_NEEDED = "config_needed"
--- Unknown: we don't have a classification for this error string.
--- Retry once, then log a warning so we can add a rule next release.
Policy.CLASS_UNKNOWN       = "unknown"


-- The mapping from documented ERRORS to classes.  Keys MUST be values
-- of Interface.ERRORS (any drift here means an undocumented error
-- gets dropped into CLASS_UNKNOWN, which is loud).
local CLASS_BY_ERROR = {
    [Interface.ERRORS.UNREACHABLE]    = Policy.CLASS_TRANSIENT,
    [Interface.ERRORS.INTERNAL]       = Policy.CLASS_TRANSIENT,
    [Interface.ERRORS.REJECTED]       = Policy.CLASS_PERMANENT,
    [Interface.ERRORS.NOT_AVAILABLE]  = Policy.CLASS_CONFIG_NEEDED,
    [Interface.ERRORS.NOT_CONFIGURED] = Policy.CLASS_CONFIG_NEEDED,
    [Interface.ERRORS.AUTH_FAILED]    = Policy.CLASS_CONFIG_NEEDED,
}


--- Classify an error returned by a transport's push/pull callback.
---@param err string|nil
---@return string  one of Policy.CLASS_*
function Policy.classify_error(err)
    if err == nil then return Policy.CLASS_TRANSIENT end  -- shouldn't happen
    return CLASS_BY_ERROR[err] or Policy.CLASS_UNKNOWN
end


--- Convenience: should the orchestrator retry on this error?
---@param err string|nil
---@param attempt_count integer   1 = first attempt just failed
---@return boolean
function Policy.is_retriable(err, attempt_count)
    local class = Policy.classify_error(err)
    if class == Policy.CLASS_PERMANENT
       or class == Policy.CLASS_CONFIG_NEEDED then
        return false
    end
    if class == Policy.CLASS_UNKNOWN then
        -- Retry once and only once for unknown errors — don't loop
        -- forever on something we don't understand.
        return (attempt_count or 1) < 2
    end
    return true  -- transient
end


--- Convenience: should this error trigger a user-visible badge or
--- toast?  Used by the orchestrator → UI status path.
---@param err string|nil
---@return boolean
function Policy.needs_user_attention(err)
    return Policy.classify_error(err) == Policy.CLASS_CONFIG_NEEDED
end


-- ----------------------------------------------------------------------------
-- Default per-transport configuration.
--
-- These numbers are the result of a year-plus of production tuning.
-- They're not arbitrary; if you change them, change
-- them after thinking about the trade-off.
--
-- debounce_seconds:
--   minimum gap between two successful pushes of the same book on
--   the same transport.  Syncthing scans are cheap; Cloud
--   uploads are expensive in bandwidth and rate-limited by providers.
--
-- retry_schedule:
--   array of seconds; the Nth retry waits schedule[N] seconds.  After
--   the schedule is exhausted, the orchestrator gives up and waits
--   for the next natural push event.  Note: the schedule is NOT cumulative
--   — schedule[2]=15 means "wait 15s after the second attempt's failure",
--   NOT "wait 15s total after the first failure".
-- ----------------------------------------------------------------------------


Policy.DEFAULT_CONFIG = {
    syncthing = {
        -- The /db/scan nudge is only a backstop: Syncthing's own fsWatcher
        -- already picks up folder changes in real time, so we nudge rarely —
        -- one local HTTP call at most every 90s.  Not user-tunable: a debounce
        -- window is a mechanism detail, not a knob.
        debounce_seconds = 90,
        retry_schedule   = { 5, 15, 30, 60 },
    },
    cloud = {
        -- Commercial backends (Dropbox, WebDAV) — rate limits matter.
        --
        -- NOTE: debounce_seconds is currently INERT for cloud DATA pushes.
        -- Bridge:push_cloud_files forces every cloud entry (the documented
        -- "Sync Now" hatch), bypassing Policy.should_attempt — so this
        -- debounce never gates a real cloud upload.  Upload throttling is
        -- handled upstream: schedule_cloud_upload (cloud_upload_delay,
        -- default 60s) for the autosave path, save_now_cooldown for manual,
        -- and close fires once.  The value is KEPT (not deleted) because:
        --   1. the content-less push_syncthing_scan path still calls
        --      should_attempt for EVERY transport (cloud rejects the empty
        --      payload as permanent), so is_debounced would compare a number
        --      against nil and error if this field were removed; and
        --   2. it is the correct fallback if cloud is ever un-forced.
        debounce_seconds = 60,
        retry_schedule   = { 30, 60, 120, 300 },
    },
}


--- Return the effective config for a transport, falling back to a
--- conservative default if the id isn't in DEFAULT_CONFIG.  Pure: takes
--- the user-config table as input, doesn't read any globals.
---@param transport_id string
---@param user_config table|nil    same shape as DEFAULT_CONFIG
---@return table { debounce_seconds = number, retry_schedule = number[] }
function Policy.config_for(transport_id, user_config)
    local merged_root = user_config or Policy.DEFAULT_CONFIG
    local entry = merged_root[transport_id]
                  or Policy.DEFAULT_CONFIG[transport_id]
                  or {
                      -- Unknown transports get a conservative default,
                      -- not an error — the system stays useful even if
                      -- a future transport id slips through without a
                      -- DEFAULT_CONFIG entry.
                      debounce_seconds = 30,
                      retry_schedule   = { 30, 60, 120 },
                  }
    return entry
end


-- ----------------------------------------------------------------------------
-- Decisions.
-- ----------------------------------------------------------------------------


--- Has enough time passed since the last attempt to allow another one?
---@param last_attempt_at number|nil   unix time of the last attempt, or nil
---@param now             number       current unix time
---@param debounce_seconds number      from config
---@return boolean
function Policy.is_debounced(last_attempt_at, now, debounce_seconds)
    if not last_attempt_at then return false end
    return (now - last_attempt_at) < debounce_seconds
end


--- How long to wait before the Nth retry?  Returns the delay in
--- seconds, or nil if the schedule is exhausted.
---@param retry_schedule number[]
---@param attempt_count integer   1 = first attempt has failed, asking for the next
---@return number|nil
function Policy.next_retry_delay(retry_schedule, attempt_count)
    if not retry_schedule or #retry_schedule == 0 then return nil end
    if attempt_count < 1 then return nil end
    return retry_schedule[attempt_count]   -- nil for out-of-range, which IS the signal
end


--- Overall decision: given current state, should we attempt a push now?
--- Returns (true, nil) to proceed, (false, reason) to skip.
---
--- Reasons:
---   "debounced"          — last attempt was too recent
---   "in_backoff"         — we're between retry slots
---   "max_retries"        — exhausted the retry schedule, no natural trigger yet
---
---@param state table       { last_attempt_at, consecutive_failures, pending_retry_at }
---@param now number
---@param config table      result of Policy.config_for
---@return boolean ok
---@return string|nil reason
function Policy.should_attempt(state, now, config)
    state = state or {}
    if state.pending_retry_at and now < state.pending_retry_at then
        return false, "in_backoff"
    end
    if Policy.is_debounced(state.last_attempt_at, now, config.debounce_seconds) then
        return false, "debounced"
    end
    if state.consecutive_failures
       and state.consecutive_failures >= #config.retry_schedule
       and (state.last_attempt_at or 0) > 0 then
        -- We've exhausted retries and not yet been retriggered by a
        -- natural event (new book, save, ...).  The caller may want
        -- to allow this for a manual "Sync Now" press; should_attempt
        -- returns false here, the caller can override.
        return false, "max_retries"
    end
    return true, nil
end


return Policy
