-- =============================================================================
-- spec/tombstones_spec.lua
-- =============================================================================
--
-- Unit tests for syncery_ann/tombstones.lua — the garbage collector
-- that drops deletion markers older than the configured TTL.
--
-- We test this by stuffing the input map with annotations whose
-- datetime_updated strings represent specific moments in time, then
-- temporarily overriding `os.time` to fix "now" at a known value.
-- That way we can assert "this should drop / this should stay"
-- without any flakiness from real wall-clock time.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup()

local Tombstones = require("syncery_ann/tombstones")


-- ----------------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------------


--- Convert a Unix timestamp to our standard "YYYY-MM-DD HH:MM:SS" UTC
--- format.  Used to build test fixtures: we pick a Unix time, format
--- it as a string, drop it into an annotation's `datetime_updated`,
--- and then test that the parser inside tombstones.lua recovers the
--- right moment.
local function utc_string_for(unix_time)
    return os.date("!%Y-%m-%d %H:%M:%S", unix_time)
end


--- Run a function with `os.time()` (no arg) returning a fixed value.
--- The TABLE form (`os.time{year=...,...}`) still works normally —
--- the parser inside Tombstones uses that to convert datetime strings
--- back to Unix times, and we want it to compute real values.
--- The previous os.time is restored on completion.
local function with_clock(fixed_unix, body)
    local original_time = os.time
    os.time = function(t)
        if t == nil then return fixed_unix end
        return original_time(t)
    end
    local ok, err = pcall(body)
    os.time = original_time
    if not ok then error(err) end
end


--- Make a fake tombstone for testing — the only fields collect_garbage
--- inspects are `deleted` and `datetime_updated`.
local function tomb(at_unix)
    return {
        deleted          = true,
        datetime_updated = utc_string_for(at_unix),
        text             = "tomb @ " .. tostring(at_unix),
    }
end


--- Make a fake alive annotation.
local function alive(at_unix)
    return {
        deleted          = false,
        datetime_updated = utc_string_for(at_unix),
        text             = "alive @ " .. tostring(at_unix),
    }
end


-- ----------------------------------------------------------------------------
-- Tests
-- ----------------------------------------------------------------------------


-- ── Test 1: empty input ─────────────────────────────────────────────

do
    local cleaned, dropped = Tombstones.collect_garbage({}, 30)
    h.assert_equal(dropped, 0,                "empty in, zero dropped")
    h.assert_deep_equal(cleaned, {},          "empty in, empty out")
end


-- ── Test 2: tombstones older than TTL get COMPACTED (not dropped) ───
--
-- Behavior change from earlier revisions: old tombstones are now
-- compacted to their minimal form instead of being removed.  The
-- map still has an entry at every key that had a tombstone — the
-- deletion marker just gets smaller on disk.

do
    local now_unix = 1700000000   -- 2023-11-14 22:13:20 UTC
    local day      = 86400
    local map = {
        ["young_tomb"] = tomb(now_unix - 5  * day),   -- 5 days old   → stay verbatim
        ["mid_tomb"]   = tomb(now_unix - 29 * day),   -- 29 days old  → stay verbatim
        ["old_tomb"]   = tomb(now_unix - 31 * day),   -- 31 days old  → compact
        ["ancient"]    = tomb(now_unix - 365 * day),  -- 1 year old   → compact
    }

    with_clock(now_unix, function()
        local cleaned, compacted = Tombstones.collect_garbage(map, 30)
        h.assert_equal(compacted, 2, "two tombstones over TTL compacted")
        h.assert_true(cleaned["young_tomb"]      ~= nil, "young tomb still present")
        h.assert_true(cleaned["young_tomb"].text ~= nil, "young tomb kept verbatim (has text field)")
        h.assert_true(cleaned["mid_tomb"]        ~= nil, "29-day tomb still present")
        h.assert_true(cleaned["mid_tomb"].text   ~= nil, "29-day tomb kept verbatim")
        h.assert_true(cleaned["old_tomb"]        ~= nil, "31-day tomb still in map (compacted)")
        h.assert_nil(cleaned["old_tomb"].text,           "31-day tomb stripped of text")
        h.assert_true(cleaned["old_tomb"].deleted,       "31-day tomb still marked deleted")
        h.assert_true(cleaned["ancient"]         ~= nil, "ancient tomb still in map (compacted)")
        h.assert_nil(cleaned["ancient"].text,            "ancient tomb stripped of text")
    end)
end


-- ── Test 3: alive entries always survive verbatim, regardless of age ─

do
    local now_unix = 1700000000
    local day      = 86400
    local map = {
        ["old_alive"]    = alive(now_unix - 365 * day),   -- 1y old, alive
        ["recent_alive"] = alive(now_unix - 1 * day),     -- 1d old, alive
        ["old_tomb"]     = tomb(now_unix - 100 * day),    -- 100d old, tomb → compact
    }

    with_clock(now_unix, function()
        local cleaned, compacted = Tombstones.collect_garbage(map, 30)
        h.assert_equal(compacted, 1,                              "only the tomb was compacted")
        h.assert_true(cleaned["old_alive"]         ~= nil,        "old alive kept")
        h.assert_true(cleaned["old_alive"].text    ~= nil,        "old alive kept verbatim (text field intact)")
        h.assert_true(cleaned["recent_alive"]      ~= nil,        "recent alive kept")
        h.assert_true(cleaned["old_tomb"]          ~= nil,        "old tomb still present (compacted, not dropped)")
        h.assert_nil(cleaned["old_tomb"].text,                    "old tomb stripped of text")
    end)
end


-- ── Test 4: malformed datetime is treated as "compact" ──────────────
--
-- An unparseable datetime is bad data, but we still need the
-- deletion marker to propagate.  Treat unparseable as "very old"
-- (compact it down to minimal form), don't drop it entirely.

do
    local now_unix = 1700000000

    local bad_tomb = {
        deleted          = true,
        datetime_updated = "not-a-date-at-all",
        text             = "stuff that should be stripped",
    }

    local map = { ["bad"] = bad_tomb }

    with_clock(now_unix, function()
        local cleaned, compacted = Tombstones.collect_garbage(map, 30)
        h.assert_equal(compacted, 1,                          "unparseable tomb compacted")
        h.assert_true(cleaned["bad"] ~= nil,                  "unparseable tomb still in map")
        h.assert_true(cleaned["bad"].deleted,                 "deletion marker preserved")
        h.assert_nil(cleaned["bad"].text,                     "text field stripped")
    end)
end


-- ── Test 5: input is never mutated ──────────────────────────────────
--
-- Our merge code relies on this: collect_garbage returns a NEW map,
-- so callers can safely keep referencing the original.

do
    local now_unix = 1700000000
    local original_tomb = tomb(now_unix - 100 * 86400)  -- 100 days old → compact
    local original_alive = alive(now_unix - 1 * 86400)

    local input = { ["t"] = original_tomb, ["a"] = original_alive }

    with_clock(now_unix, function()
        local _ = Tombstones.collect_garbage(input, 30)
        h.assert_true(input["t"] ~= nil,
            "original tomb still in input map after GC")
        h.assert_true(input["t"].text ~= nil,
            "original tomb's text field NOT stripped (input is unmodified)")
        h.assert_true(input["a"] ~= nil,
            "original alive still in input map after GC")
    end)
end


-- ── Test 6: default TTL of 30 days is used when omitted ─────────────

do
    local now_unix = 1700000000
    local day = 86400
    local map = {
        ["just_over"]  = tomb(now_unix - 31 * day),
        ["just_under"] = tomb(now_unix - 29 * day),
    }

    with_clock(now_unix, function()
        local cleaned, compacted = Tombstones.collect_garbage(map)  -- no TTL arg
        h.assert_equal(compacted, 1,                           "default TTL = 30 days")
        h.assert_true(cleaned["just_under"]      ~= nil,       "29-day survives default TTL verbatim")
        h.assert_true(cleaned["just_under"].text ~= nil,       "29-day kept verbatim")
        h.assert_true(cleaned["just_over"]       ~= nil,       "31-day still in map (compacted)")
        h.assert_nil(cleaned["just_over"].text,                "31-day stripped")
    end)
end


-- ── Test 7: Tombstones.count counts only tombstones ─────────────────

do
    local now_unix = 1700000000
    local map = {
        ["a1"] = alive(now_unix),
        ["a2"] = alive(now_unix),
        ["t1"] = tomb(now_unix),
        ["t2"] = tomb(now_unix - 365 * 86400),  -- old, but count still counts
    }

    h.assert_equal(Tombstones.count(map),  2,    "count() returns tombstone count")
    h.assert_equal(Tombstones.count({}),   0,    "empty -> zero")
    h.assert_equal(Tombstones.count(nil),  0,    "nil tolerated, returns zero")
end


-- ── Test 8: custom long TTL keeps very old tombstones verbatim ──────

do
    local now_unix = 1700000000
    local day = 86400
    local map = {
        ["six_months"] = tomb(now_unix - 180 * day),
    }

    with_clock(now_unix, function()
        local cleaned_30,  compacted_30  = Tombstones.collect_garbage(map, 30)
        local cleaned_365, compacted_365 = Tombstones.collect_garbage(map, 365)

        h.assert_equal(compacted_30,  1,                       "TTL 30 compacts the 180-day tomb")
        h.assert_equal(compacted_365, 0,                       "TTL 365 leaves the 180-day tomb verbatim")
        h.assert_true(cleaned_30["six_months"]       ~= nil,   "still present at TTL 30")
        h.assert_nil(cleaned_30["six_months"].text,            "compacted at TTL 30")
        h.assert_true(cleaned_365["six_months"]      ~= nil,   "present at TTL 365")
        h.assert_true(cleaned_365["six_months"].text ~= nil,   "kept verbatim at TTL 365")
    end)
end


-- ── Test 9: compaction is idempotent ────────────────────────────────
--
-- Running GC twice on a map where some tombstones were already
-- compacted should NOT report them again.  The second pass returns
-- compacted=0 because there's nothing left to do.

do
    local now_unix = 1700000000
    local day = 86400

    local map = {
        ["old"] = tomb(now_unix - 100 * day),
    }

    with_clock(now_unix, function()
        local pass1, count1 = Tombstones.collect_garbage(map, 30)
        local pass2, count2 = Tombstones.collect_garbage(pass1, 30)
        h.assert_equal(count1, 1,                       "first pass compacts 1 tombstone")
        h.assert_equal(count2, 0,                       "second pass has nothing to compact")
        h.assert_true(pass2["old"]       ~= nil,        "tombstone still present after both passes")
        h.assert_true(pass2["old"].deleted,             "still marked deleted")
        h.assert_nil(pass2["old"].text,                 "still stripped")
    end)
end


-- ── Test 10: device_id and device_label survive compaction ──────────
--
-- These are the only "metadata" fields kept on a compacted tombstone
-- because they're tiny and useful for "X was deleted on <device>" UIs.

do
    local now_unix = 1700000000

    local rich_tomb = {
        deleted          = true,
        datetime_updated = utc_string_for(now_unix - 100 * 86400),
        device_id        = "kindle-1",
        device_label     = "Kindle PW",
        text             = "should be stripped",
        drawer           = "underscore",
        color            = "red",
        pos0             = "/p[1].0",
        pos1             = "/p[1].50",
    }

    local map = { ["rich"] = rich_tomb }

    with_clock(now_unix, function()
        local cleaned, _ = Tombstones.collect_garbage(map, 30)
        h.assert_equal(cleaned["rich"].device_id,    "kindle-1",   "device_id preserved")
        h.assert_equal(cleaned["rich"].device_label, "Kindle PW",  "device_label preserved")
        h.assert_nil(cleaned["rich"].text,                         "text stripped")
        h.assert_nil(cleaned["rich"].drawer,                       "drawer stripped")
        h.assert_nil(cleaned["rich"].color,                        "color stripped")
        h.assert_nil(cleaned["rich"].pos0,                         "pos0 stripped")
        h.assert_nil(cleaned["rich"].pos1,                         "pos1 stripped")
    end)
end
