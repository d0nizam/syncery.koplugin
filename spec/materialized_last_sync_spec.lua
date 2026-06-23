-- =============================================================================
-- spec/materialized_last_sync_spec.lua
-- =============================================================================
--
-- Tests SyncOrchestrator._materialized_last_sync_annotations (S3): the filter
-- that keeps un-materialized remote pulls OUT of the last-sync ancestor, so
-- the next 3-way merge cannot synthesize a phantom deletion for an annotation
-- that has not yet reached this device's live list.
--
-- REGRESSION-PROOF assertions:
--   * a live pull NOT in the local read is EXCLUDED (the phantom guard);
--   * a live entry that IS in the local read is KEPT (real deletion still
--     detectable later);
--   * a KEPT entry carries the MATERIALIZED (live) value, NOT the merged
--     value: when a remote EDIT won the pick, merged != live, and recording
--     merged would desync the ancestor from the live list, making the next
--     merge re-assert the stale value -> ping-pong / regression;
--   * tombstones are ALWAYS kept (never resurrect).
-- If the filter were removed (ancestor = full merged map, the old behavior),
-- the "excluded" assertions fail.  If a kept entry recorded the merged value
-- instead of the live value, the "edit" assertion fails.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup()

local SyncOrchestrator = require("syncery_ann/sync_orchestrator")

local function ann(text, deleted)
    return { text = text, datetime = "2026-01-01 00:00:00", deleted = deleted }
end

local F = SyncOrchestrator._materialized_last_sync_annotations


-- ── live pull NOT in local read -> EXCLUDED (phantom guard) ───────────────

do
    local merged = { ["K_pull"] = ann("PULL") }   -- adopted from remote
    local local_read = {}                          -- never materialized locally
    local out = F(merged, local_read)
    h.assert_nil(out["K_pull"],
        "un-materialized live pull must be EXCLUDED from the ancestor")
end


-- ── live entry IN local read -> KEPT (real deletion stays detectable) ─────

do
    local merged = { ["K_own"] = ann("OWN") }
    local local_read = { ["K_own"] = ann("OWN") }  -- materialized locally
    local out = F(merged, local_read)
    h.assert_true(out["K_own"] ~= nil,
        "materialized live entry must be KEPT in the ancestor")
    h.assert_equal(out["K_own"].text, "OWN",
        "kept entry carries the materialized value (live == merged here)")
end


-- ── KEPT entry records the LIVE value, NOT the merged value (edit case) ───
--
-- THE PING-PONG REGRESSION.  A remote note edit (v2) won the merge pick, so
-- merged.note == "v2", but S1 leaves the live list at "v1" until close (G).
-- The ancestor must record the LIVE value ("v1") -- what the device actually
-- has -- not the merged value ("v2").  Recording "v2" would make the next
-- merge's _preserve_local_note_edits read the stale live "v1" as a fresh
-- local edit (ancestor.note "v2" != local.note "v1") and re-assert it with a
-- bumped timestamp, regressing the remote edit -> bidirectional ping-pong.
-- Here merged != live, so this distinguishes the live value from the merged
-- value (the materialized-case test above cannot, its values are equal).

do
    local merged     = { ["K"] = { text = "hl", note = "v2", datetime = "t" } }  -- remote edit won
    local local_read = { ["K"] = { text = "hl", note = "v1", datetime = "t" } }  -- live still v1 (S1)
    local out = F(merged, local_read)
    h.assert_true(out["K"] ~= nil, "edit: materialized entry kept in ancestor")
    h.assert_equal(out["K"].note, "v1",
        "edit: ancestor records the LIVE note (v1), NOT the merged note (v2)")
end


-- ── tombstones ALWAYS kept (never resurrect) ─────────────────────────────

do
    local merged = { ["K_del"] = ann("GONE", true) }  -- tombstone
    -- tombstone kept even when NOT in the local read:
    local out = F(merged, {})
    h.assert_true(out["K_del"] ~= nil, "tombstone kept even when not in local read")
    h.assert_true(out["K_del"].deleted == true, "kept tombstone stays deleted")
end


-- ── mixed: own (kept) + pull (excluded) + tombstone (kept) ───────────────

do
    local merged = {
        ["K_own"]  = ann("OWN"),
        ["K_pull"] = ann("PULL"),
        ["K_del"]  = ann("GONE", true),
    }
    local local_read = { ["K_own"] = ann("OWN") }   -- only own is materialized
    local out = F(merged, local_read)

    h.assert_true(out["K_own"]  ~= nil, "own (materialized) kept")
    h.assert_nil(out["K_pull"],         "pull (un-materialized) excluded")
    h.assert_true(out["K_del"]  ~= nil, "tombstone kept")

    -- count: 2 entries (own + tombstone), pull dropped
    local n = 0
    for _ in pairs(out) do n = n + 1 end
    h.assert_equal(n, 2, "ancestor has exactly own + tombstone (pull dropped)")
end


-- ── nil-safety ───────────────────────────────────────────────────────────

do
    h.assert_deep_equal(F(nil, nil), {}, "nil merged -> empty ancestor")
    h.assert_deep_equal(F({}, nil), {},  "empty merged -> empty ancestor")
    -- merged with entries, nil local read -> only tombstones survive
    local out = F({ ["K_pull"] = ann("PULL"), ["K_del"] = ann("X", true) }, nil)
    h.assert_nil(out["K_pull"],         "nil local read excludes live pulls")
    h.assert_true(out["K_del"] ~= nil,  "nil local read still keeps tombstones")
end
