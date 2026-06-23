-- =============================================================================
-- spec/progress_paths_spec.lua
-- =============================================================================
--
-- Tests for syncery_progress/paths.lua — storage-mode toggling, the
-- two path-builder functions, and the recursive-mkdir property
-- (which we get for free by reaching into syncery_ann/paths.lua's
-- helper, but we verify end-to-end anyway since the integration is
-- where bugs hide).
--
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_progress_paths_spec_" .. tostring(os.time()))

local Paths      = require("syncery_progress/paths")
local AnnPaths   = require("syncery_ann/paths")
local JsonStore  = require("syncery_ann/json_store")
local lfs        = require("lfs")


-- ----------------------------------------------------------------------------
-- Storage-mode switching is independent of the ann subsystem's
-- ----------------------------------------------------------------------------


do
    Paths.set_storage_mode("sdr")
    h.assert_equal(Paths.get_storage_mode(), "sdr",
        "sdr mode roundtrips through set/get")

    Paths.set_storage_mode("hash")
    h.assert_equal(Paths.get_storage_mode(), "hash",
        "hash mode roundtrips")

    Paths.set_storage_mode("garbage")
    h.assert_equal(Paths.get_storage_mode(), "sdr",
        "invalid mode falls back to sdr")

    -- Unified storage mode (post-Phase-5 chunk 3 refactor): setting
    -- one subsystem's mode sets both, because both read from
    -- syncery_storage_mode.lua.  Previously these were independent
    -- module-level values that main.lua had to keep in sync by hand.
    Paths.set_storage_mode("hash")
    AnnPaths.set_storage_mode("sdr")
    h.assert_equal(Paths.get_storage_mode(), "sdr",
        "setting ann mode flows through to progress (unified source)")
    h.assert_equal(AnnPaths.get_storage_mode(), "sdr",
        "and ann itself reflects the shared value")
    AnnPaths.set_storage_mode("hash")    -- restore for next blocks
end


-- ----------------------------------------------------------------------------
-- shared_progress_path: SDR mode → sidecar
-- ----------------------------------------------------------------------------


do
    Paths.set_storage_mode("sdr")
    local p = Paths.shared_progress_path("/tmp/foo/book.epub")
    h.assert_true(p ~= nil,                                "non-nil path")
    h.assert_true(p:match("%.sdr/") ~= nil,                "lives in sidecar dir")
    h.assert_true(p:match("%.syncery%-progress%.json$") ~= nil,
        "uses legacy progress extension (no v2 suffix)")
    h.assert_true(p:match("book%.epub%.syncery") ~= nil,
        "filename embedded so multiple books don't collide in same dir")
end


-- ----------------------------------------------------------------------------
-- shared_progress_path: hash mode → state dir keyed by hash
-- ----------------------------------------------------------------------------


do
    Paths.set_storage_mode("hash")
    local p = Paths.shared_progress_path("/tmp/foo/book.epub")
    h.assert_true(p ~= nil, "non-nil path in hash mode")
    h.assert_true(p:match("/syncery/synceryhash/[0-9a-f][0-9a-f]/[0-9a-f]+/syncery%-progress%.json$") ~= nil,
        "hash-keyed path under sharded synceryhash/<2hex>/ with filename syncery-progress.json")
end


-- ----------------------------------------------------------------------------
-- Empty / nil book paths return nil
-- ----------------------------------------------------------------------------


do
    h.assert_nil(Paths.shared_progress_path(nil),    "nil book -> nil shared")
    h.assert_nil(Paths.shared_progress_path(""),     "empty book -> nil shared")
    h.assert_nil(Paths.last_sync_progress_path(nil), "nil book -> nil last_sync")
    h.assert_nil(Paths.last_sync_progress_path(""),  "empty book -> nil last_sync")
end


-- ----------------------------------------------------------------------------
-- last_sync_progress_path: end-to-end works on fresh install in SDR mode
--
-- This is the same regression-guard B1 had for ann/last-sync, applied
-- to progress's last-sync chain.  We reuse the same helper from
-- syncery_ann/paths.lua, but we verify the end-to-end through the
-- progress entry point.
-- ----------------------------------------------------------------------------


do
    -- Wipe the state dir to genuinely simulate a fresh install.
    os.execute("rm -rf '" .. h.test_root .. "/syncery'")
    Paths.set_storage_mode("sdr")

    local p = Paths.last_sync_progress_path("/tmp/some_progress_book.epub")
    h.assert_true(p ~= nil,
        "fresh-install last_sync path resolves to non-nil")

    h.assert_equal(lfs.attributes(h.test_root .. "/syncery", "mode"),
        "directory", "level 1 (syncery/) created on fresh install")
    h.assert_equal(lfs.attributes(h.test_root .. "/syncery/last_sync", "mode"),
        "directory", "level 2 (syncery/last_sync/) created on fresh install")

    local book_dir = p:match("^(.*)/[^/]+$")
    h.assert_equal(lfs.attributes(book_dir, "mode"),
        "directory", "level 3 (syncery/last_sync/<hash>/) created")

    -- Round-trip the write so we know save_last_sync would have worked.
    local ok, _ = JsonStore.write(p, { schema_version = 1, entries = {} })
    h.assert_true(ok, "writing to last_sync file succeeds end-to-end")
end


-- ----------------------------------------------------------------------------
-- last_sync path is distinct from ann/last_sync path for the same book
-- (different files in the same directory)
-- ----------------------------------------------------------------------------


do
    local progress_p = Paths.last_sync_progress_path("/tmp/test_distinct_book.epub")
    local ann_p      = AnnPaths.last_sync_annotations_path("/tmp/test_distinct_book.epub")

    h.assert_true(progress_p ~= ann_p,
        "ann and progress last-sync files are distinct")
    h.assert_true(progress_p:match("/last_sync/") ~= nil
              and ann_p:match("/last_sync/") ~= nil,
        "both live under last_sync/")

    -- Same book directory.
    local progress_dir = progress_p:match("^(.*)/[^/]+$")
    local ann_dir      = ann_p:match("^(.*)/[^/]+$")
    h.assert_equal(progress_dir, ann_dir,
        "both files live in the same per-book directory")
end


-- ----------------------------------------------------------------------------
-- shared_progress_path is different from shared_annotations_path
-- (different filenames in same sidecar / same hash dir)
-- ----------------------------------------------------------------------------


do
    Paths.set_storage_mode("sdr")
    AnnPaths.set_storage_mode("sdr")

    local progress_p = Paths.shared_progress_path("/tmp/qux/some_book.epub")
    local ann_p      = AnnPaths.shared_annotations_path("/tmp/qux/some_book.epub")
    h.assert_true(progress_p ~= ann_p,
        "ann and progress shared files are distinct in SDR mode")

    Paths.set_storage_mode("hash")
    AnnPaths.set_storage_mode("hash")
    local progress_h = Paths.shared_progress_path("/tmp/qux/some_book.epub")
    local ann_h      = AnnPaths.shared_annotations_path("/tmp/qux/some_book.epub")
    h.assert_true(progress_h ~= ann_h,
        "ann and progress shared files are distinct in hash mode")
end
