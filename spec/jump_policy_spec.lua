-- =============================================================================
-- spec/jump_policy_spec.lua
-- =============================================================================
--
-- Tests for syncery_ui/jump_policy.lua — the pure jump-prompt
-- decision extracted from main.lua:checkRemote.
--
-- This spec exists to LOCK the B8 fix: the old gate compared a remote
-- device's per-device save-count against THIS device's save-count
-- (`r_rev <= self.own_revision`), silently suppressing the cross-device
-- jump prompt whenever our save-count was higher.  The new policy keys
-- suppression per remote device by revision, with no notion of our own
-- counter — so a device that is behind us in save-count but ahead in the
-- book is still offered.  The "B8 regression lock" block below pins that.
--
-- Pure logic, no disk — but we still call h.setup for parity with the
-- other progress specs (defensive parent-package requires).
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_jump_policy_spec_" .. tostring(os.time()))

local JumpPolicy = require("syncery_ui/jump_policy")


-- ----------------------------------------------------------------------------
-- B8 REGRESSION LOCK — the exact case the old `own_revision` gate broke.
-- ----------------------------------------------------------------------------
do
    -- Canonical scenario: we read heavily on this device (high save-count,
    -- which the OLD gate stored in own_revision); the phone read further
    -- ahead in fewer saves (low revision, high percent).  Fresh book open
    -- => nothing acknowledged yet.  Must OFFER.
    local phone = { revision = 3, percent = 0.80, page = 240 }
    h.assert_true(
        JumpPolicy.should_prompt(phone, "PHONE", {}, 0.10, nil),
        "B8: remote behind in save-count but ahead in book is OFFERED (empty acked)")

    -- The remote's low revision must NOT be compared against any local
    -- save-count: even an absurdly high revision for a DIFFERENT device
    -- in the acked map does not suppress this one.
    h.assert_true(
        JumpPolicy.should_prompt(phone, "PHONE", { TABLET = 9999 }, 0.10, nil),
        "B8: a high acked revision for ANOTHER device does not suppress this one")
end


-- ----------------------------------------------------------------------------
-- Re-prompt suppression — per device, revision-keyed.
-- ----------------------------------------------------------------------------
do
    local b5 = { revision = 5, percent = 0.80 }

    -- Already acknowledged B at revision 5 => same state suppressed.
    h.assert_false(
        JumpPolicy.should_prompt(b5, "B", { B = 5 }, 0.10, nil),
        "acked at same revision suppresses")

    -- Acked at a HIGHER revision (e.g. file rolled back) => suppressed.
    h.assert_false(
        JumpPolicy.should_prompt(b5, "B", { B = 6 }, 0.10, nil),
        "acked at higher revision suppresses (<=)")

    -- Remote advanced past what we acked => offered again.
    local b6 = { revision = 6, percent = 0.85 }
    h.assert_true(
        JumpPolicy.should_prompt(b6, "B", { B = 5 }, 0.10, nil),
        "remote advanced beyond acked revision is offered")

    -- Per-device independence: acking B does not suppress C.
    local c3 = { revision = 3, percent = 0.70 }
    h.assert_true(
        JumpPolicy.should_prompt(c3, "C", { B = 5 }, 0.10, nil),
        "acking device B does not suppress device C (per-device map)")
end


-- ----------------------------------------------------------------------------
-- Substantive delta gates (percent / xpath).
-- ----------------------------------------------------------------------------
do
    -- No meaningful movement (within PERCENT_EPSILON) => suppress.
    local same = { revision = 7, percent = 0.5000 }
    h.assert_false(
        JumpPolicy.should_prompt(same, "B", {}, 0.5004, nil),
        "delta <= PERCENT_EPSILON suppresses")

    -- Small-but-real percent move, no xpath change => suppress.
    local small = { revision = 7, percent = 0.503, xpath = nil }
    h.assert_false(
        JumpPolicy.should_prompt(small, "B", {}, 0.500, nil),
        "small percent delta with no xpath change suppresses")

    -- Same small percent move, but xpath genuinely changed => offer.
    local small_xp = { revision = 7, percent = 0.503, xpath = "/body/DocFragment[5]" }
    h.assert_true(
        JumpPolicy.should_prompt(small_xp, "B", {}, 0.500, "/body/DocFragment[4]"),
        "small percent delta but changed xpath is offered")

    -- Identical xpath, small delta => still suppressed (xpath unchanged).
    h.assert_false(
        JumpPolicy.should_prompt(small_xp, "B", {}, 0.500, "/body/DocFragment[5]"),
        "small percent delta with identical xpath suppresses")

    -- Large percent delta => offer regardless of xpath.
    local big = { revision = 7, percent = 0.90 }
    h.assert_true(
        JumpPolicy.should_prompt(big, "B", {}, 0.10, nil),
        "large percent delta is offered")

    -- Direction-agnostic: remote BEHIND us by a large margin still trips
    -- the delta (abs); suppression of that is the acked map's job, not
    -- this gate's.  (Documents current behaviour.)
    local behind = { revision = 7, percent = 0.10 }
    h.assert_true(
        JumpPolicy.should_prompt(behind, "B", {}, 0.90, nil),
        "delta is absolute — remote behind also trips it (acked map gates re-show)")
end


-- ----------------------------------------------------------------------------
-- Defensive — malformed / missing inputs never crash.
-- ----------------------------------------------------------------------------
do
    h.assert_false(JumpPolicy.should_prompt(nil, "B", {}, 0.1, nil),
        "nil best_entry => false")
    h.assert_false(JumpPolicy.should_prompt("not a table", "B", {}, 0.1, nil),
        "non-table best_entry => false")

    -- nil acked_map treated as empty => offered when delta is real.
    local b = { revision = 4, percent = 0.8 }
    h.assert_true(JumpPolicy.should_prompt(b, "B", nil, 0.1, nil),
        "nil acked_map treated as empty (offered)")

    -- nil best_device_id => acked floor is -1 => offered.
    h.assert_true(JumpPolicy.should_prompt(b, nil, {}, 0.1, nil),
        "nil best_device_id => offered (acked floor -1)")

    -- Malformed revision (string) does not crash; treated as 0.
    local bad_rev = { revision = "oops", percent = 0.8 }
    h.assert_true(JumpPolicy.should_prompt(bad_rev, "B", {}, 0.1, nil),
        "non-numeric revision tonumber->0, no crash, offered on delta")

    -- Malformed percents tonumber->0; delta 0 => suppressed (no crash).
    local bad_pct = { revision = 4, percent = "x" }
    h.assert_false(JumpPolicy.should_prompt(bad_pct, "B", {}, "y", nil),
        "non-numeric percents tonumber->0 => delta 0 => suppressed, no crash")
end


-- ============================================================================
-- pick_jump_target — recency ranking (B8-sub).  Ranks by timestamp, NOT by
-- per-device revision (save-count) and NOT by furthest-read.
-- ============================================================================

-- B8-sub REGRESSION LOCK — save-count must NOT win; recency must.
do
    -- Tablet: many autosaves (high revision) but read a while ago (older ts).
    -- Phone: few saves (low revision) but read most recently (newer ts).
    -- The OLD pick_best (revision-keyed) chose the Tablet; recency chooses Phone.
    local entries = {
        TABLET = { revision = 30, percent = 0.50, timestamp = 1000 },
        PHONE  = { revision = 3,  percent = 0.80, timestamp = 2000 },
    }
    local best, id = JumpPolicy.pick_jump_target(entries, "EREADER")
    h.assert_equal(id, "PHONE",
        "B8-sub: most-recently-read wins over most-saved (recency, not save-count)")
    h.assert_equal(best.timestamp, 2000, "B8-sub: returns the recent entry")
end

-- B9 forward-only: if WE are the most-recently-read, return nil — offering an
-- older device (PHONE@ts100) would be a backward jump (suppressed by default).
do
    local entries = {
        EREADER = { revision = 5, percent = 0.9, timestamp = 9999 }, -- us, newest
        PHONE   = { revision = 2, percent = 0.4, timestamp = 100 },
    }
    local best, id = JumpPolicy.pick_jump_target(entries, "EREADER")
    h.assert_nil(best, "B9: we are the most-recently-read -> no forward candidate (entry nil)")
    h.assert_nil(id,   "B9: we are the most-recently-read -> no forward candidate (id nil)")
end

-- Most recent among several others.
do
    local entries = {
        A = { revision = 1, percent = 0.1, timestamp = 100 },
        B = { revision = 1, percent = 0.2, timestamp = 300 },
        C = { revision = 1, percent = 0.3, timestamp = 200 },
    }
    local _, id = JumpPolicy.pick_jump_target(entries, "ME")
    h.assert_equal(id, "B", "picks max timestamp among multiple others")
end

-- Tie on timestamp -> furthest (percent) breaks it.
do
    local entries = {
        A = { revision = 1, percent = 0.40, timestamp = 500 },
        B = { revision = 1, percent = 0.70, timestamp = 500 },
    }
    local _, id = JumpPolicy.pick_jump_target(entries, "ME")
    h.assert_equal(id, "B", "equal timestamp -> furthest percent wins (tiebreak)")
end

-- Tie on timestamp AND percent -> deterministic device_id tiebreak,
-- independent of table/iteration order.
do
    local e1 = {
        ZED   = { revision = 1, percent = 0.5, timestamp = 500 },
        ALPHA = { revision = 9, percent = 0.5, timestamp = 500 },
    }
    local _, id1 = JumpPolicy.pick_jump_target(e1, "ME")
    h.assert_equal(id1, "ALPHA",
        "full tie -> smaller device_id wins (deterministic)")
    -- Build the same map the other way to confirm order-independence.
    local e2 = {
        ALPHA = { revision = 9, percent = 0.5, timestamp = 500 },
        ZED   = { revision = 1, percent = 0.5, timestamp = 500 },
    }
    local _, id2 = JumpPolicy.pick_jump_target(e2, "ME")
    h.assert_equal(id2, "ALPHA", "tiebreak is order-independent")
end

-- Single other device -> returned regardless of fields.
do
    local entries = { PHONE = { revision = 1, percent = 0.3, timestamp = 1 } }
    local best, id = JumpPolicy.pick_jump_target(entries, "ME")
    h.assert_equal(id, "PHONE", "single other device is returned")
    h.assert_true(best ~= nil, "single other device entry returned")
end

-- Defensive: empty / nil / only-self / non-table entries.
do
    local n1, i1 = JumpPolicy.pick_jump_target({}, "ME")
    h.assert_nil(n1, "empty map -> nil entry")
    h.assert_nil(i1, "empty map -> nil id")

    local n2 = JumpPolicy.pick_jump_target(nil, "ME")
    h.assert_nil(n2, "nil map -> nil")

    local only_self = { ME = { revision = 1, percent = 0.5, timestamp = 9 } }
    h.assert_nil(JumpPolicy.pick_jump_target(only_self, "ME"),
        "only this device present -> nil (nothing to offer)")

    local with_junk = {
        PHONE = { revision = 1, percent = 0.5, timestamp = 50 },
        BAD   = "not a table",
    }
    local _, id = JumpPolicy.pick_jump_target(with_junk, "ME")
    h.assert_equal(id, "PHONE", "non-table entries are skipped, no crash")

    -- Missing timestamps -> treated as 0, still deterministic (percent then id).
    local no_ts = {
        A = { revision = 1, percent = 0.2 },
        B = { revision = 1, percent = 0.6 },
    }
    local _, idnt = JumpPolicy.pick_jump_target(no_ts, "ME")
    h.assert_equal(idnt, "B", "missing timestamps -> ts 0 tie -> furthest wins, no crash")
end


-- ============================================================================
-- pick_jump_target — B9 forward-only direction.  Offer ONLY a device newer
-- than us; suppress backward.  "Forward" = newer by timestamp, NOT further
-- in %.  (Scenarios mirror the original-vs-current differential.)
-- ============================================================================

-- Other device is newer than us -> forward -> offered.
do
    local entries = {
        EREADER = { revision = 5, percent = 0.50, timestamp = 100 }, -- us
        PHONE   = { revision = 2, percent = 0.80, timestamp = 200 }, -- newer
    }
    local _, id = JumpPolicy.pick_jump_target(entries, "EREADER")
    h.assert_equal(id, "PHONE", "B9: other newer than us -> forward -> offered")
end

-- We are the newest among three -> nil (nothing forward to offer).
do
    local entries = {
        EREADER = { revision = 1, percent = 0.50, timestamp = 300 }, -- us, newest
        PHONE   = { revision = 1, percent = 0.80, timestamp = 200 },
        TABLET  = { revision = 1, percent = 0.30, timestamp = 100 },
    }
    h.assert_nil(JumpPolicy.pick_jump_target(entries, "EREADER"),
        "B9: we are newest among several -> nil (no backward offer)")
end

-- "Forward means newer, not ahead": a newer device BEHIND us in % is still a
-- forward jump (you re-read elsewhere) -> offered at its actual (lower) %.
do
    local entries = {
        EREADER = { revision = 5, percent = 0.90, timestamp = 100 }, -- us: ahead in %, older
        PHONE   = { revision = 2, percent = 0.40, timestamp = 200 }, -- behind in %, newer
    }
    local best, id = JumpPolicy.pick_jump_target(entries, "EREADER")
    h.assert_equal(id, "PHONE", "B9: newer-but-behind-in-% is forward (re-read) -> offered")
    h.assert_equal(best.percent, 0.40, "B9: offers the newer device's actual (lower) position")
end

-- Direction is by recency, NOT percent: a device FURTHER in % but OLDER than
-- us is backward -> suppressed (we are the newest).
do
    local entries = {
        EREADER = { revision = 1, percent = 0.50, timestamp = 300 }, -- us, newest
        PHONE   = { revision = 1, percent = 0.90, timestamp = 200 }, -- further in %, older
    }
    h.assert_nil(JumpPolicy.pick_jump_target(entries, "EREADER"),
        "B9: a further-in-% but OLDER device is backward -> suppressed")
end

-- 3 devices, we are oldest: among forward candidates the most-recent wins
-- (not the furthest).
do
    local entries = {
        EREADER = { revision = 2, percent = 0.30, timestamp = 50 },  -- us, oldest
        PHONE   = { revision = 4, percent = 0.90, timestamp = 100 }, -- furthest, older
        TABLET  = { revision = 3, percent = 0.50, timestamp = 300 }, -- most recent
    }
    local _, id = JumpPolicy.pick_jump_target(entries, "EREADER")
    h.assert_equal(id, "TABLET", "B9: among forward candidates, most-recent wins (not furthest)")
end

-- Exact-second tie WITH us resolves deterministically; landing on us -> nil.
do
    local entries = {
        EREADER = { revision = 1, percent = 0.60, timestamp = 500 }, -- us: ties ts, higher %
        PHONE   = { revision = 1, percent = 0.40, timestamp = 500 }, -- ties ts, lower %
    }
    -- equal ts -> percent tiebreak -> EREADER (0.60 > 0.40) is "most recent" -> nil
    h.assert_nil(JumpPolicy.pick_jump_target(entries, "EREADER"),
        "B9: exact-ts tie resolving to us (by percent tiebreak) -> nil")
end
