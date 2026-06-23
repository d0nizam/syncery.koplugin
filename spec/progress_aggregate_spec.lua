-- =============================================================================
-- spec/progress_aggregate_spec.lua
-- =============================================================================
--
-- Tests for syncery_ui/progress_browser/aggregate.lua -- the pure per-book
-- reduction the Progress Browser's all-books view renders, organised around the
-- MOST RECENT position (KOReader kosync's "latest record" model), NOT Kindle's
-- furthest.  Covers the recency state token (behind / even / neutral), the
-- recent-device marker, this-device fallback, freshness filtering, that recent
-- is by TIMESTAMP not max percent, and that the epsilon is honoured.  All
-- inputs are plain tables -> fully headless.
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_progress_aggregate_spec_" .. tostring(os.time()))

local Aggregate = require("syncery_ui/progress_browser/aggregate")

local NOW   = 1700000000
local T_OLD = NOW - 3 * 86400         -- 3 days ago (fresh)
local T_MID = NOW - 2 * 86400         -- 2 days ago (fresh)
local T_NEW = NOW - 1 * 86400         -- 1 day ago  (fresh, newest)
local STALE = NOW - 100 * 86400       -- 100 days ago (outside a 90-day window)

local function opts() return { now_epoch = NOW, freshness_days = 90 } end


-- ---------------------------------------------------------------------------
-- 1. Only this device -> neutral, this device holds the most recent position.
-- ---------------------------------------------------------------------------
do
    local entries = {
        ["me"] = { percent = 0.42, timestamp = T_NEW, label = "Phone" },
    }
    local r = Aggregate.aggregate_book(entries, "me", opts())
    h.assert_equal(r.state, "neutral", "only this device -> neutral")
    h.assert_equal(r.my_percent, 0.42, "my_percent reflects this device")
    h.assert_equal(r.other_count, 0, "no other devices")
    h.assert_true(r.is_recent_me, "this device holds the most recent position when alone")
    h.assert_equal(r.recent_percent, 0.42, "recent is this device's position")
end


-- ---------------------------------------------------------------------------
-- 2. A MORE RECENT position is ahead -> behind; recent = that device.
-- ---------------------------------------------------------------------------
do
    local entries = {
        ["me"]    = { percent = 0.38, timestamp = T_OLD, label = "Kindle" },
        ["phone"] = { percent = 0.61, timestamp = T_NEW, label = "Phone" },  -- newest AND ahead
    }
    local r = Aggregate.aggregate_book(entries, "me", opts())
    h.assert_equal(r.state, "behind", "a newer position ahead -> behind")
    h.assert_equal(r.my_percent, 0.38, "my_percent unchanged")
    h.assert_equal(r.recent_percent, 0.61, "recent is the latest device")
    h.assert_equal(r.recent_label, "Phone", "recent label is the latest device's")
    h.assert_equal(r.recent_device_id, "phone", "recent id is the latest device's")
    h.assert_false(r.is_recent_me, "this device is not the most recent")
    h.assert_equal(r.other_count, 1, "one other device")
end


-- ---------------------------------------------------------------------------
-- 3. The most recent (another device) is at this device's spot -> even.
-- ---------------------------------------------------------------------------
do
    local entries = {
        ["me"]    = { percent = 0.500, timestamp = T_OLD, label = "Phone" },
        ["b"]     = { percent = 0.503, timestamp = T_NEW, label = "Kindle" },  -- newest, ~same spot
        ["c"]     = { percent = 0.499, timestamp = T_MID, label = "Desktop" },
    }
    local r = Aggregate.aggregate_book(entries, "me", opts())
    h.assert_equal(r.state, "even",
        "the most recent device is within epsilon of this device -> even")
    h.assert_equal(r.recent_device_id, "b", "recent is the newest device")
    h.assert_equal(r.other_count, 2, "two other devices")
end


-- ---------------------------------------------------------------------------
-- 4. This device is AHEAD of the most recent activity -> neutral (the latest
--    record is behind me; nothing to catch up to, KOReader would offer only a
--    backward sync).
-- ---------------------------------------------------------------------------
do
    local entries = {
        ["me"]    = { percent = 0.80, timestamp = T_OLD, label = "Phone" },
        ["b"]     = { percent = 0.20, timestamp = T_NEW, label = "Kindle" },  -- newest but behind
    }
    local r = Aggregate.aggregate_book(entries, "me", opts())
    h.assert_equal(r.state, "neutral", "this device is ahead of the latest activity -> neutral")
    h.assert_false(r.is_recent_me, "the newer (lower-progress) device holds the latest record")
    h.assert_equal(r.recent_percent, 0.20, "recent is the latest record (behind me), not the furthest")
end


-- ---------------------------------------------------------------------------
-- 5. recent is by TIMESTAMP, not max percent: the NEWER but LOWER-% device is
--    the recent one (the exact distinction vs Kindle's furthest).
-- ---------------------------------------------------------------------------
do
    local entries = {
        ["phone"] = { percent = 0.55, timestamp = T_NEW, label = "Phone" },   -- newest
        ["kndl"]  = { percent = 0.61, timestamp = T_OLD, label = "Kindle" },  -- furthest, older
    }
    local r = Aggregate.aggregate_book(entries, "me", opts())
    h.assert_equal(r.state, "behind", "no local position, a newer position exists -> behind")
    h.assert_true(r.my_percent == nil, "my_percent is nil when this device has no entry")
    h.assert_equal(r.recent_percent, 0.55,
        "recent = the NEWEST device (0.55), NOT the furthest (0.61)")
    h.assert_equal(r.recent_device_id, "phone", "recent id is the newest device")
    h.assert_equal(r.other_count, 2, "both others counted")
end


-- ---------------------------------------------------------------------------
-- 6. Empty entries -> neutral, recent 0, my_percent nil (defensive).
-- ---------------------------------------------------------------------------
do
    local r = Aggregate.aggregate_book({}, "me", opts())
    h.assert_equal(r.state, "neutral", "no entries at all -> neutral")
    h.assert_equal(r.recent_percent, 0, "recent is 0 with no entries")
    h.assert_true(r.my_percent == nil, "my_percent nil with no entries")
    h.assert_equal(r.other_count, 0, "no others with no entries")
end


-- ---------------------------------------------------------------------------
-- 7. A STALE other device is excluded -> it neither counts nor anchors recency.
-- ---------------------------------------------------------------------------
do
    local entries = {
        ["me"]    = { percent = 0.50, timestamp = T_MID, label = "Phone" },
        ["old"]   = { percent = 0.99, timestamp = STALE, label = "OldTablet" },
    }
    local r = Aggregate.aggregate_book(entries, "me", opts())
    h.assert_equal(r.other_count, 0, "the stale other is filtered out")
    h.assert_equal(r.recent_percent, 0.50,
        "the stale 99% does NOT anchor recency (freshness hides it)")
    h.assert_true(r.is_recent_me, "only this device remains fresh -> it holds recency")
    h.assert_equal(r.state, "neutral", "only this device remains fresh -> neutral")
end


-- ---------------------------------------------------------------------------
-- 8. A STALE local entry still counts (fallback to the unfiltered map).
-- ---------------------------------------------------------------------------
do
    local entries = {
        ["me"] = { percent = 0.33, timestamp = STALE, label = "Phone" },
    }
    local r = Aggregate.aggregate_book(entries, "me", opts())
    h.assert_equal(r.my_percent, 0.33,
        "this device's own position is shown even when stale (status-panel parity)")
    h.assert_equal(r.state, "neutral", "still the only device -> neutral")
end


-- ---------------------------------------------------------------------------
-- 9. The epsilon is honoured: a small gap to the most-recent device that is
--    "behind" by default becomes "even" under a wider epsilon.
-- ---------------------------------------------------------------------------
do
    local entries = {
        ["me"] = { percent = 0.40, timestamp = T_OLD, label = "Phone" },
        ["b"]  = { percent = 0.43, timestamp = T_NEW, label = "Kindle" },  -- newest, slightly ahead
    }
    local default_r = Aggregate.aggregate_book(entries, "me", opts())
    h.assert_equal(default_r.state, "behind",
        "a 3% gap to the most-recent device exceeds the default 0.5% epsilon -> behind")

    local wide = { now_epoch = NOW, freshness_days = 90, epsilon = 0.05 }
    local wide_r = Aggregate.aggregate_book(entries, "me", wide)
    h.assert_equal(wide_r.state, "even",
        "the same 3% gap is within a 5% epsilon -> even (epsilon honoured)")
end


h.teardown()
print("progress_aggregate_spec: assertions complete")
