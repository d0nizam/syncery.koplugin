-- =============================================================================
-- spec/transport_policy_spec.lua
-- =============================================================================
--
-- Tests for syncery_transports/policy.lua.  Policy is pure functions
-- so these tests are pure inputs → outputs — no setup beyond requiring
-- the module.
--
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_policy_spec_" .. tostring(os.time()))

local Policy    = require("syncery_transports/policy")
local Interface = require("syncery_transports/interface")


-- ----------------------------------------------------------------------------
-- classify_error: every documented ERROR maps to a class.
-- ----------------------------------------------------------------------------


do
    h.assert_equal(Policy.classify_error(Interface.ERRORS.UNREACHABLE),
        Policy.CLASS_TRANSIENT,        "UNREACHABLE → transient")
    h.assert_equal(Policy.classify_error(Interface.ERRORS.INTERNAL),
        Policy.CLASS_TRANSIENT,        "INTERNAL → transient")
    h.assert_equal(Policy.classify_error(Interface.ERRORS.REJECTED),
        Policy.CLASS_PERMANENT,        "REJECTED → permanent")
    h.assert_equal(Policy.classify_error(Interface.ERRORS.NOT_AVAILABLE),
        Policy.CLASS_CONFIG_NEEDED,    "NOT_AVAILABLE → config_needed")
    h.assert_equal(Policy.classify_error(Interface.ERRORS.NOT_CONFIGURED),
        Policy.CLASS_CONFIG_NEEDED,    "NOT_CONFIGURED → config_needed")
    h.assert_equal(Policy.classify_error(Interface.ERRORS.AUTH_FAILED),
        Policy.CLASS_CONFIG_NEEDED,    "AUTH_FAILED → config_needed")
end


-- ----------------------------------------------------------------------------
-- An undocumented error falls into CLASS_UNKNOWN — loud-but-functional.
-- ----------------------------------------------------------------------------


do
    h.assert_equal(Policy.classify_error("something_new"), Policy.CLASS_UNKNOWN,
        "unfamiliar errors → unknown")
    h.assert_equal(Policy.classify_error(""), Policy.CLASS_UNKNOWN,
        "empty string → unknown")
end


-- ----------------------------------------------------------------------------
-- classify_error(nil): we treat nil as transient so a buggy transport
-- that calls back(false, nil) doesn't crash policy logic.  It's still
-- a bug (the transport should provide an error) but we don't want
-- policy to throw.
-- ----------------------------------------------------------------------------


do
    h.assert_equal(Policy.classify_error(nil), Policy.CLASS_TRANSIENT,
        "nil error treated as transient (defensive)")
end


-- ----------------------------------------------------------------------------
-- is_retriable: transient yes, permanent no, config no, unknown once.
-- ----------------------------------------------------------------------------


do
    h.assert_true(Policy.is_retriable(Interface.ERRORS.UNREACHABLE, 1),
        "transient errors retriable on attempt 1")
    h.assert_true(Policy.is_retriable(Interface.ERRORS.UNREACHABLE, 5),
        "transient errors still retriable on attempt 5 (schedule decides cutoff)")

    h.assert_false(Policy.is_retriable(Interface.ERRORS.REJECTED, 1),
        "permanent errors never retriable")
    h.assert_false(Policy.is_retriable(Interface.ERRORS.AUTH_FAILED, 1),
        "config errors never retriable")
    h.assert_false(Policy.is_retriable(Interface.ERRORS.NOT_CONFIGURED, 1),
        "not_configured never retriable")

    h.assert_true(Policy.is_retriable("invented", 1),
        "unknown error: retry once")
    h.assert_false(Policy.is_retriable("invented", 2),
        "unknown error: don't loop")
end


-- ----------------------------------------------------------------------------
-- needs_user_attention: only config errors qualify.
-- ----------------------------------------------------------------------------


do
    h.assert_true(Policy.needs_user_attention(Interface.ERRORS.AUTH_FAILED),
        "auth_failed needs user attention")
    h.assert_true(Policy.needs_user_attention(Interface.ERRORS.NOT_CONFIGURED),
        "not_configured needs user attention")
    h.assert_false(Policy.needs_user_attention(Interface.ERRORS.UNREACHABLE),
        "unreachable does NOT (it's transient — quiet retry)")
    h.assert_false(Policy.needs_user_attention(Interface.ERRORS.REJECTED),
        "rejected does NOT (it's permanent but not user-fixable)")
    h.assert_false(Policy.needs_user_attention(nil),
        "no error = no attention needed")
end


-- ----------------------------------------------------------------------------
-- DEFAULT_CONFIG has entries for every transport id we use today.
-- ----------------------------------------------------------------------------


do
    h.assert_true(Policy.DEFAULT_CONFIG.syncthing ~= nil, "syncthing default present")
    h.assert_true(Policy.DEFAULT_CONFIG.cloud     ~= nil, "cloud default present")

    -- Sanity-check shape, not values: values are tuned and tests
    -- shouldn't pin them or we'll churn the spec.
    for id, cfg in pairs(Policy.DEFAULT_CONFIG) do
        h.assert_equal(type(cfg.debounce_seconds), "number",
            id .. ": debounce_seconds is a number")
        h.assert_equal(type(cfg.retry_schedule), "table",
            id .. ": retry_schedule is a table")
        h.assert_true(#cfg.retry_schedule >= 1,
            id .. ": retry_schedule has at least one entry")
    end
end


-- ----------------------------------------------------------------------------
-- config_for: returns user_config[id] if present, else default, else
-- a generic fallback.
-- ----------------------------------------------------------------------------


do
    local cfg = Policy.config_for("syncthing")
    h.assert_equal(cfg, Policy.DEFAULT_CONFIG.syncthing,
        "default lookup for known transport")
end


do
    local user_cfg = {
        cloud = { debounce_seconds = 999, retry_schedule = { 1 } },
    }
    local cfg = Policy.config_for("cloud", user_cfg)
    h.assert_equal(cfg.debounce_seconds, 999,        "user-config wins for known id")
end


do
    -- User_cfg supplied but doesn't contain `syncthing` — falls back
    -- to DEFAULT_CONFIG.syncthing, NOT to the generic fallback.  This
    -- matches the principle "user config is overlay, not replacement".
    local user_cfg = {
        cloud = { debounce_seconds = 1, retry_schedule = { 1 } },
    }
    local cfg = Policy.config_for("syncthing", user_cfg)
    h.assert_equal(cfg, Policy.DEFAULT_CONFIG.syncthing,
        "partial user_cfg overlays; missing keys fall through to defaults")
end


do
    -- An entirely unknown transport id gets a conservative fallback.
    local cfg = Policy.config_for("brand_new_transport")
    h.assert_equal(type(cfg.debounce_seconds), "number",
        "fallback debounce_seconds is a number")
    h.assert_equal(type(cfg.retry_schedule), "table",
        "fallback retry_schedule is a table")
    h.assert_true(#cfg.retry_schedule >= 1, "fallback schedule non-empty")
end


-- ----------------------------------------------------------------------------
-- is_debounced: returns true when last_attempt was recent.
-- ----------------------------------------------------------------------------


do
    h.assert_false(Policy.is_debounced(nil, 1000, 30),
        "no last attempt = not debounced")
    h.assert_true(Policy.is_debounced(995, 1000, 30),
        "5s ago, 30s debounce = debounced")
    h.assert_false(Policy.is_debounced(970, 1000, 30),
        "30s ago, 30s debounce = boundary (not debounced)")
    h.assert_false(Policy.is_debounced(900, 1000, 30),
        "100s ago, 30s debounce = clearly past")
end


-- ----------------------------------------------------------------------------
-- next_retry_delay: indexes into the schedule; nil after exhaustion.
-- ----------------------------------------------------------------------------


do
    local schedule = { 10, 30, 60 }
    h.assert_equal(Policy.next_retry_delay(schedule, 1), 10,  "attempt 1 → 10s")
    h.assert_equal(Policy.next_retry_delay(schedule, 2), 30,  "attempt 2 → 30s")
    h.assert_equal(Policy.next_retry_delay(schedule, 3), 60,  "attempt 3 → 60s")
    h.assert_nil(Policy.next_retry_delay(schedule, 4),
        "past the end → nil (signals 'give up')")
    h.assert_nil(Policy.next_retry_delay(schedule, 0),
        "0/negative attempt → nil")
end


do
    h.assert_nil(Policy.next_retry_delay(nil, 1),     "nil schedule → nil")
    h.assert_nil(Policy.next_retry_delay({}, 1),      "empty schedule → nil")
end


-- ----------------------------------------------------------------------------
-- should_attempt: the integrating decision function.
-- ----------------------------------------------------------------------------


do
    -- Fresh state, nothing in flight → proceed.
    local config = { debounce_seconds = 30, retry_schedule = { 10, 30 } }
    local ok, reason = Policy.should_attempt({}, 1000, config)
    h.assert_true(ok,   "fresh state proceeds")
    h.assert_nil(reason, "no reason needed")
end


do
    -- Recent successful attempt → debounced.
    local config = { debounce_seconds = 30, retry_schedule = { 10, 30 } }
    local state  = { last_attempt_at = 990, consecutive_failures = 0 }
    local ok, reason = Policy.should_attempt(state, 1000, config)
    h.assert_false(ok,                "blocked")
    h.assert_equal(reason, "debounced", "reason is debounced")
end


do
    -- Pending retry in the future → in_backoff.
    local config = { debounce_seconds = 30, retry_schedule = { 10, 30 } }
    local state  = {
        last_attempt_at      = 800,    -- well past debounce window
        consecutive_failures = 1,
        pending_retry_at     = 1010,   -- 10s in the future
    }
    local ok, reason = Policy.should_attempt(state, 1000, config)
    h.assert_false(ok,                  "blocked by pending retry")
    h.assert_equal(reason, "in_backoff",  "reason is in_backoff")
end


do
    -- Pending retry's deadline has passed → proceed.
    local config = { debounce_seconds = 30, retry_schedule = { 10, 30 } }
    local state  = {
        last_attempt_at      = 800,
        consecutive_failures = 1,
        pending_retry_at     = 990,    -- 10s in the past
    }
    local ok = Policy.should_attempt(state, 1000, config)
    h.assert_true(ok, "past-deadline backoff doesn't block")
end


do
    -- Retries exhausted → max_retries.
    local config = { debounce_seconds = 30, retry_schedule = { 10, 30 } }
    local state  = {
        last_attempt_at      = 500,   -- way past debounce
        consecutive_failures = 2,     -- = schedule length
    }
    local ok, reason = Policy.should_attempt(state, 1000, config)
    h.assert_false(ok,                    "blocked")
    h.assert_equal(reason, "max_retries",  "reason is max_retries")
end


do
    -- max_retries with no last_attempt_at: not blocked (means a fresh
    -- trigger arrived after a previous retry-exhausted state — let it
    -- through).
    local config = { debounce_seconds = 30, retry_schedule = { 10, 30 } }
    local state  = {
        last_attempt_at      = nil,
        consecutive_failures = 5,
    }
    local ok = Policy.should_attempt(state, 1000, config)
    h.assert_true(ok, "fresh trigger after exhaustion is allowed")
end
