-- =============================================================================
-- spec/progress_merge_spec.lua
-- =============================================================================
--
-- Tests for syncery_progress/merge.lua — the pure 3-way merge core.
--
-- These tests don't touch disk and don't need the stub framework, but
-- we still call `h.setup` because the merge module's parent package
-- requires a non-nil `logger` etc. on first load (defensive).
--
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_progress_merge_spec_" .. tostring(os.time()))

local Merge = require("syncery_progress/merge")


-- ----------------------------------------------------------------------------
-- three_way: empty inputs everywhere
-- ----------------------------------------------------------------------------


do
    local merged = Merge.three_way(nil, nil, nil)
    h.assert_deep_equal(merged, {}, "all-nil inputs return empty map")

    merged = Merge.three_way({}, {}, {})
    h.assert_deep_equal(merged, {}, "all-empty inputs return empty map")
end


-- ----------------------------------------------------------------------------
-- three_way: one side only — entries copy through
-- ----------------------------------------------------------------------------


do
    local entry_a = { revision = 1, percent = 0.3, timestamp = 100 }
    local merged  = Merge.three_way({ DA = entry_a }, nil, nil)
    h.assert_equal(merged.DA, entry_a, "local-only entry is preserved")

    merged = Merge.three_way(nil, nil, { DB = entry_a })
    h.assert_equal(merged.DB, entry_a, "remote-only entry is preserved")

    merged = Merge.three_way(nil, { DC = entry_a }, nil)
    h.assert_equal(merged.DC, entry_a,
        "last-sync-only entry is preserved (no GC in this phase)")
end


-- ----------------------------------------------------------------------------
-- three_way: higher revision wins
-- ----------------------------------------------------------------------------


do
    local older   = { revision = 1, percent = 0.30, timestamp = 100 }
    local newer   = { revision = 5, percent = 0.55, timestamp = 200 }
    local merged  = Merge.three_way({ DA = older }, nil, { DA = newer })
    h.assert_equal(merged.DA, newer, "remote with higher revision wins")

    merged = Merge.three_way({ DA = newer }, nil, { DA = older })
    h.assert_equal(merged.DA, newer, "local with higher revision wins")
end


-- ----------------------------------------------------------------------------
-- three_way: equal revision, timestamp tie-break
-- ----------------------------------------------------------------------------


do
    local a = { revision = 3, percent = 0.40, timestamp = 100 }
    local b = { revision = 3, percent = 0.45, timestamp = 200 }
    local merged = Merge.three_way({ DA = a }, nil, { DA = b })
    h.assert_equal(merged.DA, b,
        "remote wins on timestamp tie-break at equal revision")
end


-- ----------------------------------------------------------------------------
-- three_way: identical entries → either-or, but deterministic
-- ----------------------------------------------------------------------------


do
    local same   = { revision = 7, percent = 0.5, timestamp = 333 }
    local merged = Merge.three_way({ DA = same }, nil, { DA = same })
    h.assert_equal(merged.DA.revision, 7,    "true tie keeps revision")
    h.assert_equal(merged.DA.percent,  0.5,  "true tie keeps percent")
    h.assert_equal(merged.DA.timestamp, 333, "true tie keeps timestamp")
end


-- ----------------------------------------------------------------------------
-- three_way: multi-device merge (each device picked independently)
-- ----------------------------------------------------------------------------


do
    local local_map = {
        PHONE  = { revision = 5, percent = 0.50, timestamp = 100 },  -- our entry, newest locally
        TABLET = { revision = 1, percent = 0.10, timestamp = 50  },  -- stale cached view
    }
    local last_sync_map = {
        PHONE  = { revision = 4, percent = 0.40, timestamp = 90 },
        TABLET = { revision = 1, percent = 0.10, timestamp = 50 },
    }
    local remote_map = {
        PHONE  = { revision = 4, percent = 0.40, timestamp = 90 },   -- old version of us
        TABLET = { revision = 3, percent = 0.30, timestamp = 200 },  -- TABLET advanced!
        EREADER = { revision = 1, percent = 0.05, timestamp = 60 },  -- brand new device
    }

    local merged = Merge.three_way(local_map, last_sync_map, remote_map)

    h.assert_equal(merged.PHONE.revision,  5,
        "our entry: local newer than remote, wins")
    h.assert_equal(merged.TABLET.revision, 3,
        "TABLET: remote newer than local-cached, wins")
    h.assert_equal(merged.EREADER.revision, 1,
        "EREADER: remote-only, adopted")

    local key_count = 0
    for _ in pairs(merged) do key_count = key_count + 1 end
    h.assert_equal(key_count, 3, "three device_ids in merged map")
end


-- ----------------------------------------------------------------------------
-- three_way: input maps are not mutated
-- ----------------------------------------------------------------------------


do
    local local_map  = { DA = { revision = 2, percent = 0.2, timestamp = 100 } }
    local remote_map = { DA = { revision = 5, percent = 0.5, timestamp = 200 } }
    Merge.three_way(local_map, nil, remote_map)

    h.assert_equal(local_map.DA.revision,  2, "local map untouched")
    h.assert_equal(remote_map.DA.revision, 5, "remote map untouched")
end


-- ----------------------------------------------------------------------------
-- upsert_local_entry: bumps revision, stamps device_id and timestamp
-- ----------------------------------------------------------------------------


do
    local state = {
        DA = { revision = 3, percent = 0.30, timestamp = 100 },
    }

    local new_state = Merge.upsert_local_entry(state, "DA", {
        percent = 0.55, page = 142, total_pages = 271,
    }, 500)

    h.assert_equal(new_state.DA.revision,    4,    "revision bumped")
    h.assert_equal(new_state.DA.percent,     0.55, "new percent applied")
    h.assert_equal(new_state.DA.page,        142,  "page applied")
    h.assert_equal(new_state.DA.total_pages, 271,  "total_pages applied")
    h.assert_equal(new_state.DA.device_id,   "DA", "device_id stamped")
    h.assert_equal(new_state.DA.timestamp,   500,  "timestamp from clock arg")

    -- Input state map is untouched.
    h.assert_equal(state.DA.revision, 3, "input state not mutated")
    h.assert_equal(state.DA.percent,  0.30, "input state.DA not mutated")
end


-- ----------------------------------------------------------------------------
-- upsert_local_entry: brand-new device starts at revision 1
-- ----------------------------------------------------------------------------


do
    local new_state = Merge.upsert_local_entry({}, "DA", {
        percent = 0.10
    }, 999)
    h.assert_equal(new_state.DA.revision, 1, "fresh device starts at revision 1")
end


-- ----------------------------------------------------------------------------
-- upsert_local_entry: rejects missing device_id
-- ----------------------------------------------------------------------------


do
    local state = { DA = { revision = 3, percent = 0.3, timestamp = 100 } }
    local result = Merge.upsert_local_entry(state, nil, { percent = 0.5 })
    h.assert_equal(result.DA.revision, 3, "nil device_id is a no-op")

    result = Merge.upsert_local_entry(state, "", { percent = 0.5 })
    h.assert_equal(result.DA.revision, 3, "empty device_id is a no-op")
end


-- ----------------------------------------------------------------------------
-- upsert_local_entry: only THIS device's prior revision matters
-- (don't accidentally walk other devices to compute the next revision)
-- ----------------------------------------------------------------------------


do
    local state = {
        DA = { revision = 3, page = 30, percent = 0.30, timestamp = 100 },
        DB = { revision = 99, page = 99, percent = 0.99, timestamp = 999 },  -- huge, but irrelevant
    }
    -- A real move (page 30 -> 40) so the upsert actually stamps a new entry;
    -- an identical position would now be an idempotent no-op (revision unchanged).
    local new_state = Merge.upsert_local_entry(state, "DA", { page = 40, percent = 0.4 })
    h.assert_equal(new_state.DA.revision, 4,
        "next revision is OUR previous + 1, not max-across-all-devices")
end


-- ----------------------------------------------------------------------------
-- upsert_local_entry: IDEMPOTENT — re-asserting the SAME position is a no-op
-- (no revision bump, no timestamp refresh). Only an actual move stamps a new
-- entry. This keeps "the position changed" and "we wrote something" separate:
-- an annotation-triggered save (same position, no page turn) must NOT look
-- like a fresh reading event — that false freshness is what made the
-- annotating device a spurious recency jump target and bumped the ack
-- revision on its peers.
-- ----------------------------------------------------------------------------


do
    -- Same position (page + xpath identical) → no-op: the map is returned
    -- untouched (same reference), revision and timestamp unchanged.
    local state = {
        DA = { revision = 5, page = 42, xpath = "/body/p[3]",
               percent = 0.42, timestamp = 100, device_id = "DA" },
    }
    local result = Merge.upsert_local_entry(state, "DA",
        { page = 42, xpath = "/body/p[3]", percent = 0.42 }, 999)
    h.assert_true(result == state, "same position returns the input map untouched (no-op)")
    h.assert_equal(result.DA.revision, 5, "same position does NOT bump the revision")
    h.assert_equal(result.DA.timestamp, 100, "same position does NOT refresh the timestamp")
end


do
    -- Changed page (paged book) → a real move → bump + fresh timestamp.
    local state = {
        DA = { revision = 5, page = 42, percent = 0.42, timestamp = 100, device_id = "DA" },
    }
    local result = Merge.upsert_local_entry(state, "DA", { page = 43, percent = 0.43 }, 999)
    h.assert_equal(result.DA.revision, 6, "changed page bumps the revision")
    h.assert_equal(result.DA.timestamp, 999, "changed page refreshes the timestamp")
end


do
    -- Changed xpath (rolling book) → a real move → bump, even if the page
    -- NUMBER is unchanged (xpath is the authoritative position there).
    local state = {
        DA = { revision = 5, page = 1, xpath = "/body/p[3]",
               percent = 0.30, timestamp = 100, device_id = "DA" },
    }
    local result = Merge.upsert_local_entry(state, "DA",
        { page = 1, xpath = "/body/p[9]", percent = 0.35 }, 999)
    h.assert_equal(result.DA.revision, 6, "changed xpath bumps even when the page number is unchanged")
end


do
    -- No existing entry → first write inserts (revision 1, stamped timestamp).
    local result = Merge.upsert_local_entry({}, "DA", { page = 10, percent = 0.1 }, 999)
    h.assert_equal(result.DA.revision, 1, "first write inserts with revision 1")
    h.assert_equal(result.DA.timestamp, 999, "first write stamps the timestamp")
end


do
    -- _same_position direct: page + xpath define the position, nil-safe.
    h.assert_true(Merge._same_position({ page = 5, xpath = "/a" }, { page = 5, xpath = "/a" }),
        "_same_position: identical page+xpath → true")
    h.assert_true(Merge._same_position({ page = 5 }, { page = 5 }),
        "_same_position: paged (xpath nil on both) → true")
    h.assert_false(Merge._same_position({ page = 5, xpath = "/a" }, { page = 6, xpath = "/a" }),
        "_same_position: differing page → false")
    h.assert_false(Merge._same_position({ page = 5, xpath = "/a" }, { page = 5, xpath = "/b" }),
        "_same_position: differing xpath → false")
    h.assert_false(Merge._same_position({ page = 5, xpath = "/a" }, { page = 5 }),
        "_same_position: xpath present vs nil → false (err toward a move)")
end


-- ----------------------------------------------------------------------------
-- pick_best: highest (revision, timestamp) wins
-- ----------------------------------------------------------------------------


do
    local entries = {
        DA = { revision = 5, percent = 0.5, timestamp = 100 },
        DB = { revision = 5, percent = 0.5, timestamp = 200 },  -- equal rev, newer ts
        DC = { revision = 3, percent = 0.3, timestamp = 500 },  -- newer ts, lower rev
    }

    local best, who = Merge.pick_best(entries)
    h.assert_equal(who, "DB", "DB wins on timestamp tie-break at top revision")
    h.assert_equal(best.revision, 5, "best entry has rev 5")

    -- Exclude DB; DA should win (also at rev 5).
    best, who = Merge.pick_best(entries, "DB")
    h.assert_equal(who, "DA", "excluding DB, DA at rev 5 wins")

    -- Exclude both top entries; DC wins by default.
    local two_excluded = {
        DA = entries.DA,
        DC = entries.DC,
    }
    best, who = Merge.pick_best(two_excluded, "DA")
    h.assert_equal(who, "DC", "only DC left, picks DC")
end


-- ----------------------------------------------------------------------------
-- pick_best: empty / nil inputs return nil
-- ----------------------------------------------------------------------------


do
    local best, who = Merge.pick_best(nil)
    h.assert_nil(best, "nil input -> nil best")
    h.assert_nil(who,  "nil input -> nil device_id")

    best, who = Merge.pick_best({})
    h.assert_nil(best, "empty input -> nil best")
    h.assert_nil(who,  "empty input -> nil device_id")
end


-- ----------------------------------------------------------------------------
-- three_way: missing revision/timestamp fields don't crash, default to 0
-- ----------------------------------------------------------------------------


do
    local entry_no_rev = { percent = 0.5 }  -- malformed but should not crash
    local entry_real   = { revision = 1, percent = 0.1, timestamp = 50 }

    local merged = Merge.three_way(
        { DA = entry_no_rev },
        nil,
        { DA = entry_real })

    h.assert_equal(merged.DA.revision, 1,
        "real entry beats malformed (revision=0) one")
end
