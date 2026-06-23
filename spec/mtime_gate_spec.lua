-- =============================================================================
-- spec/mtime_gate_spec.lua
-- =============================================================================
--
-- Tests for syncery_ann/mtime_gate.lua: the annotation back-sync debounce
-- gate that checkRemote uses to avoid re-running the merge when the shared
-- file has not changed.
--
-- The load-bearing, REGRESSION-PROOF assertion is that the cache returned
-- after a sync reflects the POST-write mtime (read AFTER do_sync ran), not
-- the pre-write mtime passed in.  The original inline code cached the
-- pre-write value, which made the very next tick re-run the merge for
-- nothing (and, before S3, helped open the phantom-tombstone window).
-- =============================================================================

local h = require("spec.test_helpers")
h.setup()

local MtimeGate = require("syncery_ann/mtime_gate")


-- ── should_sync: the gate decision ───────────────────────────────────────

do
    h.assert_true(MtimeGate.should_sync(12345, 0),
        "fresh session (cache 0) must sync")
    h.assert_true(MtimeGate.should_sync(0, 0),
        "cache 0 syncs even when the file is absent (mtime 0)")
    h.assert_false(MtimeGate.should_sync(500, 500),
        "unchanged mtime must skip")
    h.assert_true(MtimeGate.should_sync(600, 500),
        "changed mtime must sync")
end


-- ── run: REGRESSION — returns POST-write mtime as the cache ───────────────

do
    local pre_write  = 100
    local post_write = 137   -- our own merge bumped the file's mtime
    local synced = false
    local new_cache, did_sync = MtimeGate.run(
        pre_write, 0,
        function() synced = true end,
        function() return post_write end)

    h.assert_true(did_sync,  "fresh session must sync")
    h.assert_true(synced,    "do_sync must have been called")
    -- THE regression assertion: cache is the POST-write mtime.  If the code
    -- cached the pre-write value (the original bug), this is 100 and fails.
    h.assert_equal(new_cache, post_write,
        "cache must be the POST-write mtime (the fix)")
    h.assert_false(new_cache == pre_write,
        "cache must NOT be the pre-write mtime (the redundant-merge bug)")
end


-- ── run: next tick after a sync SKIPS (no redundant merge) ────────────────

do
    local post_write = 137
    local cache, did1 = MtimeGate.run(
        100, 0,
        function() end,
        function() return post_write end)
    h.assert_true(did1, "first tick syncs")
    h.assert_equal(cache, post_write, "first tick caches the post-write mtime")

    -- Second tick: file's current mtime is the post-write value (nothing else
    -- moved it).  With the fix, current == cache -> SKIP.
    local sync2 = false
    local cache2, did2 = MtimeGate.run(
        post_write, cache,
        function() sync2 = true end,
        function() return post_write end)
    h.assert_false(did2,  "second tick must SKIP (mtime unchanged since our write)")
    h.assert_false(sync2, "do_sync must NOT run on the second tick")
    h.assert_equal(cache2, post_write, "cache stays at the post-write mtime")
end


-- ── run: a genuine later remote change is NOT missed ─────────────────────

do
    local cache = 137
    local remote_mtime = 200   -- a remote device wrote at a later second
    local synced = false
    local new_cache, did = MtimeGate.run(
        remote_mtime, cache,
        function() synced = true end,
        function() return remote_mtime end)
    h.assert_true(did,    "a changed mtime must trigger a merge")
    h.assert_true(synced, "do_sync must run for a real remote change")
    h.assert_equal(new_cache, remote_mtime, "cache updates to the new mtime")
end


-- ── run: when it skips, cache is unchanged and do_sync never runs ────────

do
    local sync = false
    local new_cache, did = MtimeGate.run(
        500, 500,
        function() sync = true end,
        function() error("read_mtime must not be called when skipping") end)
    h.assert_false(did,  "unchanged mtime skips")
    h.assert_false(sync, "do_sync must not run")
    h.assert_equal(new_cache, 500, "cache unchanged on skip")
end
