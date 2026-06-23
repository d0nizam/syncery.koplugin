-- =============================================================================
-- spec/scan_target_spec.lua
-- =============================================================================
--
-- Locks the behaviour of ScanTarget.compute — the folder-match + per-mode
-- sub-directory math extracted VERBATIM from main.lua's _getScanTarget.  The
-- single-folder collapse (B2) is now in place: the folder source is the one
-- chosen `cfg.folder` record (no more folders list / longest-prefix search);
-- the per-mode sub-dir computation is byte-identical to the pre-collapse code.
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_scan_target_spec_" .. tostring(os.time()))

local ScanTarget = require("syncery_progress/scan_target")


-- ---------------------------------------------------------------------------
-- nil sync_path → the default folder id, no sub.
-- ---------------------------------------------------------------------------
do
    local cfg = { folder_id = "books",
                  folder = { folder_id = "books", path = "/storage/Books" } }
    local fid, sub = ScanTarget.compute(nil, cfg, "sdr")
    h.assert_equal(fid, "books", "nil sync_path → cfg.folder_id")
    h.assert_nil(sub, "nil sync_path → no sub_dir")
end


-- ---------------------------------------------------------------------------
-- SDR mode, book under the folder → folder_id + the sub-dir between the
-- folder root and the file.
-- ---------------------------------------------------------------------------
do
    local cfg = { folder_id = "books",
                  folder = { folder_id = "books", path = "/storage/Books" } }
    local fid, sub = ScanTarget.compute(
        "/storage/Books/Fiction/novel.sdr/syncery-progress.json", cfg, "sdr")
    h.assert_equal(fid, "books", "sdr → matched folder id")
    h.assert_equal(sub, "Fiction/novel.sdr", "sdr → sub_dir is the path between root and file")
end


-- ---------------------------------------------------------------------------
-- HASH mode, book under the folder → sub_dir is the file's directory minus
-- the root.
-- ---------------------------------------------------------------------------
do
    local cfg = { folder_id = "books",
                  folder = { folder_id = "books", path = "/storage/Books" } }
    local fid, sub = ScanTarget.compute(
        "/storage/Books/.sync_meta/ab/cdef.json", cfg, "hash")
    h.assert_equal(fid, "books", "hash → matched folder id")
    h.assert_equal(sub, ".sync_meta/ab", "hash → sub_dir is the file's dir minus root")
end


-- ---------------------------------------------------------------------------
-- Book NOT under the configured folder → fall back to cfg.folder_id, no sub.
-- ---------------------------------------------------------------------------
do
    local cfg = { folder_id = "books",
                  folder = { folder_id = "books", path = "/storage/Books" } }
    local fid, sub = ScanTarget.compute("/elsewhere/file.json", cfg, "sdr")
    h.assert_equal(fid, "books", "no match → cfg.folder_id")
    h.assert_nil(sub, "no match → no sub_dir")
end


-- ---------------------------------------------------------------------------
-- The folder path is normalised with a trailing slash before matching, so a
-- stored path without one still matches and the sub-dir is computed correctly.
-- ---------------------------------------------------------------------------
do
    local cfg = { folder_id = "default",
                  folder = { folder_id = "inner", path = "/storage/Books" } }
    local fid, sub = ScanTarget.compute(
        "/storage/Books/Sci/book.sdr/syncery-progress.json", cfg, "sdr")
    h.assert_equal(fid, "inner", "book under the folder → the folder's id")
    h.assert_equal(sub, "Sci/book.sdr", "sub_dir relative to the folder root")
end


-- ---------------------------------------------------------------------------
-- `folder.id` is accepted as the id key (not only `folder.folder_id`).
-- ---------------------------------------------------------------------------
do
    local cfg = { folder_id = "default",
                  folder = { id = "byid", path = "/data" } }
    local fid, sub = ScanTarget.compute("/data/x/file.json", cfg, "sdr")
    h.assert_equal(fid, "byid", "folder.id used when folder.folder_id absent")
    h.assert_equal(sub, "x", "sub_dir computed from the .id folder root")
end


-- ---------------------------------------------------------------------------
-- No folder at all → cfg.folder_id, no sub (whole-folder scan).
-- ---------------------------------------------------------------------------
do
    local cfg = { folder_id = "solo", folder = nil }
    local fid, sub = ScanTarget.compute("/anything/file.json", cfg, "sdr")
    h.assert_equal(fid, "solo", "no folder → cfg.folder_id")
    h.assert_nil(sub, "no folder → no sub_dir")
end


-- ---------------------------------------------------------------------------
-- is_folder_configured: the guard predicate for "may push a Syncthing scan".
-- ---------------------------------------------------------------------------
do
    local C = ScanTarget.is_folder_configured
    -- KOSyncthing+ self-discovers → always configured, even with nothing in Settings.
    h.assert_equal(C(true, "", nil), true, "KOSyncthing+ → configured regardless of Settings")
    h.assert_equal(C(true, "default", nil), true, "KOSyncthing+ → configured even with default id + no folder")
    -- a folder record with a path → configured (whatever the id).
    h.assert_equal(C(false, "default", { folder_id = "x", path = "/p" }), true,
                   "folder record with a path → configured")
    -- real folder_id, no folder → configured (must not regress manual id-only).
    h.assert_equal(C(false, "books", nil), true, "real folder_id without a folder → configured")
    -- nothing chosen yet → NOT configured (pre-pick).
    h.assert_equal(C(false, "default", nil), false, "default id + no folder → not configured")
    h.assert_equal(C(false, "", nil), false, "empty id + no folder → not configured")
    h.assert_equal(C(false, "default", { folder_id = "x", path = "" }), false,
                   "default id + folder with empty path → not configured")
    h.assert_equal(C(false, nil, { path = "" }), false, "nil id + folder with empty path → not configured")
end
