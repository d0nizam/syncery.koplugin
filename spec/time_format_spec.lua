-- =============================================================================
-- spec/time_format_spec.lua
-- =============================================================================
--
-- Tests for syncery_ann/time_format.lua — the canonical-format helper
-- plus the UTC string parser.
--
-- The most important assertion here is the roundtrip:
--   format(epoch) → string ; parse(string) → epoch  must be identity
-- regardless of the host's TZ.  An earlier version of the parser
-- (which lived inside tombstones.lua) used `os.time({...})` and
-- treated the table as LOCAL time, so the roundtrip was off by the
-- local timezone offset.  See tombstones.lua header for context.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup()

local TimeFormat = require("syncery_ann/time_format")


-- ── now() shape ─────────────────────────────────────────────────────


do
    local s = TimeFormat.now()
    h.assert_true(s:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$") ~= nil,
        "now() matches YYYY-MM-DD HH:MM:SS")
end


-- ── now() tracks LOCAL wall-clock, NOT UTC ─────────────────────────
-- REGRESSION GUARD (device bug, 2026-06): now() must use the same zone
-- KOReader writes its annotation `datetime` in -- LOCAL, via os.date()
-- WITHOUT the "!" UTC flag.  When now() emitted UTC, a deletion's
-- `datetime_updated` sorted BEFORE the creation `datetime` on any
-- device east of UTC ("16:40" < "19:38" at UTC+3), so the stale alive
-- copy won newer-wins and the deleted annotation was RESURRECTED.
--
-- This assertion only DISTINGUISHES local from UTC under a non-UTC TZ
-- (in UTC the two coincide), so the suite is also run under
-- TZ=Europe/Sofia -- that run is what actually exercises this guard.


do
    -- Two reads guard against a 1-second tick landing between the
    -- comparisons; a real UTC/local mismatch is hours, not one second.
    local matches_local =
        TimeFormat.now() == os.date("%Y-%m-%d %H:%M:%S")
        or TimeFormat.now() == os.date("%Y-%m-%d %H:%M:%S")
    h.assert_true(matches_local,
        "now() tracks LOCAL time (matches KOReader datetime), not UTC")
end


-- ── last_modified_of: datetime_updated wins over datetime ──────────


do
    h.assert_equal(
        TimeFormat.last_modified_of({
            datetime         = "2024-01-01 00:00:00",
            datetime_updated = "2024-12-01 00:00:00",
        }),
        "2024-12-01 00:00:00",
        "datetime_updated preferred over datetime")
end


-- ── last_modified_of: falls back to datetime ───────────────────────


do
    h.assert_equal(
        TimeFormat.last_modified_of({ datetime = "2024-01-01 00:00:00" }),
        "2024-01-01 00:00:00",
        "falls back to datetime when datetime_updated missing")
end


-- ── last_modified_of: tolerates missing / non-table inputs ─────────


do
    h.assert_equal(TimeFormat.last_modified_of({}),  "", "no fields -> empty")
    h.assert_equal(TimeFormat.last_modified_of(nil), "", "nil -> empty")
    h.assert_equal(TimeFormat.last_modified_of("not a table"), "",
        "non-table -> empty")
end


-- ── parse_utc_to_unix: roundtrip with format() ─────────────────────
--
-- The whole point of the parser: regardless of the local timezone,
-- formatting a Unix epoch as UTC then parsing it back must yield
-- the same epoch.  This single test would have caught the bug that
-- used to live in tombstones.lua.

do
    local moments = {
        1700000000,   -- 2023-11-14 22:13:20 UTC
        1577836800,   -- 2020-01-01 00:00:00 UTC (year boundary)
        1719792000,   -- 2024-07-01 00:00:00 UTC (DST season in N. hemisphere)
        1672531199,   -- 2022-12-31 23:59:59 UTC (just before midnight)
    }
    for _, epoch in ipairs(moments) do
        local utc_string = os.date("!%Y-%m-%d %H:%M:%S", epoch)
        local parsed     = TimeFormat.parse_utc_to_unix(utc_string)
        h.assert_equal(parsed, epoch,
            "UTC string roundtrips to original epoch (" .. utc_string .. ")")
    end
end


-- ── parse_utc_to_unix: garbage input → 0 ───────────────────────────


do
    h.assert_equal(TimeFormat.parse_utc_to_unix("not a date"), 0,
        "garbage string -> 0")
    h.assert_equal(TimeFormat.parse_utc_to_unix(""), 0,
        "empty string -> 0")
    h.assert_equal(TimeFormat.parse_utc_to_unix(nil), 0,
        "nil -> 0")
    h.assert_equal(TimeFormat.parse_utc_to_unix(12345), 0,
        "non-string (number) -> 0")
    h.assert_equal(TimeFormat.parse_utc_to_unix("2024-01-01"), 0,
        "missing time part -> 0 (rejected by regex)")
    h.assert_equal(TimeFormat.parse_utc_to_unix("2024-01-01T12:00:00Z"), 0,
        "ISO-8601 with T/Z separators -> 0 (our format uses space)")
end


-- ── parse_utc_to_unix: DST-boundary edge cases ─────────────────────
--
-- These are the moments most likely to trip up a naïve "parse UTC by
-- pretending the components are local" implementation.  All assertions
-- must hold regardless of the host's TZ (the test runner ought to be
-- exercising this under several TZ values; see Makefile / CI).

do
    local boundary_epochs = {
        -- EU DST start: 2024-03-31 01:00:00 UTC (clocks jump 02→03 local in EEST)
        1711846800,
        -- EU DST end: 2024-10-27 01:00:00 UTC (clocks fall back 03→02 local)
        1729998000,
        -- US DST start: 2024-03-10 07:00:00 UTC
        1710054000,
        -- US DST end: 2024-11-03 06:00:00 UTC
        1730613600,
        -- Year boundary at midnight UTC
        1704067200,
        -- Second before year boundary
        1704067199,
    }
    for _, epoch in ipairs(boundary_epochs) do
        local s = os.date("!%Y-%m-%d %H:%M:%S", epoch)
        h.assert_equal(TimeFormat.parse_utc_to_unix(s), epoch,
            "DST/boundary roundtrip for " .. s)
    end
end


-- ── parse_utc_to_unix: roundtrip a current UTC instant ─────────────


do
    -- parse_utc_to_unix does UTC calendar-math, so its roundtrip is
    -- exercised with a UTC-formatted current instant (os.date("!...")).
    -- NOTE: deliberately NOT TimeFormat.now() -- that is LOCAL now (it
    -- matches KOReader's `datetime`), so feeding it here would be off by
    -- the device's UTC offset.  now()'s zone is covered by the
    -- "tracks LOCAL" guard above.
    local before = os.time()
    local s      = os.date("!%Y-%m-%d %H:%M:%S")
    local parsed = TimeFormat.parse_utc_to_unix(s)
    local after  = os.time()

    h.assert_true(parsed >= before - 1 and parsed <= after + 1,
        "current UTC string roundtrips to current epoch (±1s)")
end
