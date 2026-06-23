-- =============================================================================
-- spec/paths_spec.lua
-- =============================================================================
--
-- Tests for syncery_ann/paths.lua — storage-mode switching, the two
-- main path-builder functions, and the directory-creation helper.
--
-- The most important test here is the REGRESSION for the recursive-
-- mkdir bug: on a fresh install in SDR mode (the default), the
-- last-sync file's directory chain (`<settings>/syncery/last_sync/<h>`)
-- is three levels deep below the settings root.  An earlier version
-- of `_ensure_directory_exists` only created one parent level, so
-- the chain failed silently and last-sync never persisted — breaking
-- the 3-way merge from sync #2 onward.
--
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_paths_spec_" .. tostring(os.time()))

local Paths     = require("syncery_ann/paths")
local JsonStore = require("syncery_ann/json_store")
local lfs       = require("lfs")


-- ----------------------------------------------------------------------------
-- Storage-mode switching
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
end


-- ----------------------------------------------------------------------------
-- shared_annotations_path: SDR mode → sidecar
-- ----------------------------------------------------------------------------


do
    Paths.set_storage_mode("sdr")
    local p = Paths.shared_annotations_path("/tmp/foo/book.epub")
    h.assert_true(p ~= nil,                                  "non-nil path")
    h.assert_true(p:match("%.sdr/") ~= nil,                  "sidecar path")
    -- Phase 9.4: canonical name, NO `.v2` suffix.
    h.assert_true(p:match("%.syncery%-annotations%.json$") ~= nil,
                                                             "canonical suffix")
    h.assert_true(p:match("%.v2%.json$") == nil,
                                                             "no .v2 suffix post-9.4")
    h.assert_true(p:match("book%.epub%.syncery") ~= nil,
        "filename embedded so multiple books don't collide in same dir")
end


-- shared_annotations_path: hash mode → state dir, under synceryhash/, keyed by hash
do
    Paths.set_storage_mode("hash")
    local p = Paths.shared_annotations_path("/tmp/foo/book.epub")
    h.assert_true(p ~= nil,
        "non-nil path in hash mode")
    h.assert_true(p:match("/syncery/synceryhash/[0-9a-f][0-9a-f]/[0-9a-f]+/syncery%-annotations%.json$") ~= nil,
        "hash-keyed canonical path under sharded synceryhash/<2hex>/ state dir")
end


-- ----------------------------------------------------------------------------
-- Empty / nil book paths return nil
-- ----------------------------------------------------------------------------


do
    h.assert_nil(Paths.shared_annotations_path(nil),    "nil book -> nil")
    h.assert_nil(Paths.shared_annotations_path(""),     "empty book -> nil")
    h.assert_nil(Paths.last_sync_annotations_path(nil), "nil book -> nil last_sync")
    h.assert_nil(Paths.last_sync_annotations_path(""),  "empty book -> nil last_sync")
end


-- ----------------------------------------------------------------------------
-- REGRESSION: last_sync path & dir survive in SDR mode on FRESH install
-- ----------------------------------------------------------------------------
--
-- The bug: in SDR mode, `<settings>/syncery` is never the target of any
-- prior mkdir (save_shared puts the JSON in the .sdr sidecar).  When
-- last_sync's three-level path (`<settings>/syncery/last_sync/<h>`)
-- gets ensured, the old single-level mkdir failed silently and the
-- file write later failed too.


do
    -- Wipe the state dir so we genuinely simulate a fresh install.
    os.execute("rm -rf '" .. h.test_root .. "/syncery'")
    Paths.set_storage_mode("sdr")

    local p = Paths.last_sync_annotations_path("/tmp/some_book.epub")
    h.assert_true(p ~= nil, "fresh-install last_sync path resolves to non-nil")

    -- Every directory on the path must exist after the call.
    h.assert_equal(lfs.attributes(h.test_root .. "/syncery", "mode"),
        "directory", "level 1 (syncery/) created")
    h.assert_equal(lfs.attributes(h.test_root .. "/syncery/last_sync", "mode"),
        "directory", "level 2 (syncery/last_sync/) created")

    local book_dir = p:match("^(.*)/[^/]+$")
    h.assert_equal(lfs.attributes(book_dir, "mode"),
        "directory", "level 3 (syncery/last_sync/<hash>/) created")

    -- Round-trip the write so we know save_last_sync would have worked.
    local ok, _ = JsonStore.write(p, { schema_version = 1 })
    h.assert_true(ok, "writing to last_sync file succeeds end-to-end")
end


-- ----------------------------------------------------------------------------
-- _ensure_directory_exists is recursive (handles arbitrary depth)
-- ----------------------------------------------------------------------------


do
    -- Five new levels under test_root; none of them exist yet.
    local deep = h.test_root .. "/d1/d2/d3/d4/d5"
    os.execute("rm -rf '" .. h.test_root .. "/d1'")

    Paths._ensure_directory_exists(deep)
    h.assert_equal(lfs.attributes(deep, "mode"), "directory",
        "5-level nested directory created")
    h.assert_equal(lfs.attributes(h.test_root .. "/d1/d2/d3", "mode"),
        "directory", "intermediate level also created")
end


-- ----------------------------------------------------------------------------
-- _ensure_directory_exists is idempotent
-- ----------------------------------------------------------------------------


do
    local p = h.test_root .. "/already_there"
    os.execute("mkdir -p '" .. p .. "' 2>/dev/null")

    -- Calling on an existing dir should be a no-op (no crash, dir still
    -- there afterwards).
    Paths._ensure_directory_exists(p)
    h.assert_equal(lfs.attributes(p, "mode"), "directory",
        "existing dir still exists after re-ensure")
end


-- ----------------------------------------------------------------------------
-- _ensure_directory_exists tolerates nil / empty / non-path inputs
-- ----------------------------------------------------------------------------


do
    -- These must not throw, but their effect is undefined.  The goal
    -- is just "no crash".
    Paths._ensure_directory_exists(nil)
    Paths._ensure_directory_exists("")
    h.assert_true(true, "nil and empty path inputs do not crash")
end


-- ----------------------------------------------------------------------------
-- REGRESSION (18.12.24/25): the title.txt cache must live in the SAME
-- per-book directory as the canonical files, under synceryhash/.  The hash-mode
-- title writer/reader/eraser were on a stale path (<hash_root>/<md5>/, the
-- pre-12.2 layout, via a bespoke partialMD5 + Util.state_dir()), so the
-- title was written where the booklist scan never looked.  All three now
-- route through _shared_book_state_dir.  This invariant locks that: the
-- directory of the annotation file IS _shared_book_state_dir, so anything
-- written there with a fixed name (title.txt) is found by a scan of the
-- same directory.
-- ----------------------------------------------------------------------------


do
    Paths.set_storage_mode("hash")
    local book = "/tmp/foo/book.epub"

    local ann_path  = Paths.shared_annotations_path(book)
    local state_dir = Paths._shared_book_state_dir(book)

    h.assert_true(ann_path ~= nil and state_dir ~= nil,
        "hash mode yields both an annotation path and a shared book dir")

    -- The annotation file's directory must equal the shared book dir,
    -- so title.txt (written into the shared book dir) is a sibling of
    -- annotations.json — i.e. discoverable by a scan of that directory.
    local ann_dir = ann_path:match("^(.*)/[^/]+$")
    h.assert_equal(ann_dir, state_dir,
        "annotation file sits directly in _shared_book_state_dir (title.txt sibling)")

    -- And that directory is under a `synceryhash/` segment (Phase 12.2).
    h.assert_true(state_dir:find("/synceryhash/", 1, true) ~= nil,
        "shared book dir is under the synceryhash/ subdirectory")
end


-- ----------------------------------------------------------------------------
-- INVARIANT: the hash root is FIXED at the default (set_hash_root removed).
-- Relocating the root was the source of an entire path-drift bug class; the
-- cross-device-sync use case it served is now met by pointing Syncthing at
-- the `synceryhash/` subdirectory of the fixed root instead.  This locks that the
-- root is no longer relocatable and that `get_hash_root` and the shared-dir
-- builder both resolve under that one fixed root.
-- ----------------------------------------------------------------------------


-- ----------------------------------------------------------------------------
-- Basename-fallback visibility (the silent cross-device trap)
-- ----------------------------------------------------------------------------

do
    -- Normal case: the stub provides partial_md5_checksum, so the id comes
    -- from the cache and NO fallback is recorded.
    local normal_book = "/tmp/normalbook.epub"
    Paths._book_content_id(normal_book)
    h.assert_true(Paths.had_basename_fallback(normal_book) == false,
        "no basename fallback when a content hash is available")

    -- Degraded case: force BOTH sources to fail (no cached checksum, no
    -- live partialMD5).  The chokepoint must fall back to a basename hash
    -- AND record it so the UI can warn.
    local saved_docsettings = package.loaded["docsettings"]
    local saved_util        = package.loaded["util"]

    package.loaded["docsettings"] = {
        open = function() return nil end,  -- no doc_settings -> no cached hash
    }
    package.loaded["util"] = {
        partialMD5 = function() return nil end,  -- live hash unavailable
    }

    local broken_book = "/tmp/brokenbook.epub"
    local id = Paths._book_content_id(broken_book)

    h.assert_true(type(id) == "string" and id ~= "",
        "basename fallback still returns a usable (local) id")
    h.assert_true(Paths.had_basename_fallback(broken_book) == true,
        "basename fallback is recorded so the UI can surface it")
    h.assert_true(Paths.had_basename_fallback(normal_book) == false,
        "recording is per-book — the healthy book is not flagged")

    package.loaded["docsettings"] = saved_docsettings
    package.loaded["util"]        = saved_util
end


-- ----------------------------------------------------------------------------
-- Multi-location read resolver (find Syncery files after the user changes
-- KOReader's "Book metadata location")
-- ----------------------------------------------------------------------------

do
    Paths.set_storage_mode("sdr")

    local book = "/tmp/relocated.epub"
    local suffix = ".syncery-annotations.json"

    -- Three distinct sidecar dirs, one per KOReader location.  This
    -- overrides the harness stub (whose getSidecarDir ignores location).
    local root = "/tmp/syncery_multiloc_" .. tostring(os.time())
    local dirs = {
        doc  = root .. "/doc",
        dir  = root .. "/dir",
        hash = root .. "/hash",
    }
    for _, d in pairs(dirs) do os.execute("mkdir -p '" .. d .. "' 2>/dev/null") end

    local saved_docsettings = package.loaded["docsettings"]
    package.loaded["docsettings"] = {
        open = saved_docsettings.open,  -- keep cached-hash behaviour
        getSidecarDir = function(_self, _book_path, force_location)
            -- Canonical (no force_location) = "doc"; otherwise per-arg.
            return dirs[force_location or "doc"]
        end,
    }

    local book_filename = "relocated.epub"

    -- Nothing written yet → resolver returns the canonical (doc) path.
    local p0 = Paths.shared_annotations_path_for_read(book)
    h.assert_equal(p0, dirs.doc .. "/" .. book_filename .. suffix,
        "read resolver returns canonical path when no file exists yet")

    -- Simulate the user having changed location: the real file sits in the
    -- "dir" location, not the canonical "doc" one.
    local stray = dirs.dir .. "/" .. book_filename .. suffix
    local fh = io.open(stray, "w"); fh:write("{}"); fh:close()

    local p1 = Paths.shared_annotations_path_for_read(book)
    h.assert_equal(p1, stray,
        "read resolver finds the file at a non-canonical sidecar location")

    -- P4 regression guard: an idempotency check (like already_ingested in
    -- main.lua) must use shared_annotations_path_for_read, NOT the write-
    -- path shared_annotations_path.  When the file sits at a fallback
    -- location the write path misses it — any caller that treats a
    -- missing/false result as "not done yet" would repeat work that already
    -- happened.
    h.assert_true(
        Paths.shared_annotations_path(book) ~= Paths.shared_annotations_path_for_read(book),
        "P4 guard: write-path and read-path diverge when file is at fallback")
    h.assert_nil(
        lfs.attributes(Paths.shared_annotations_path(book), "mode"),
        "P4 guard: write-path does NOT see the file (wrong for idempotency)")
    h.assert_equal(
        lfs.attributes(Paths.shared_annotations_path_for_read(book), "mode"),
        "file",
        "P4 guard: read-path DOES find the file at the fallback sidecar location")

    -- Staleness guard: once a save writes the CANONICAL copy, the resolver
    -- must prefer it and ignore the stale leftover in the old location —
    -- otherwise each sync would read old data while writing new.
    local canonical_file = dirs.doc .. "/" .. book_filename .. suffix
    local cf = io.open(canonical_file, "w"); cf:write("{}"); cf:close()
    local p2 = Paths.shared_annotations_path_for_read(book)
    h.assert_equal(p2, canonical_file,
        "read resolver prefers canonical once it exists (no stale-copy trap)")

    -- The WRITE path is unchanged — still canonical (so saves re-home the
    -- book over time rather than scattering further).
    local w = Paths.shared_annotations_path(book)
    h.assert_equal(w, dirs.doc .. "/" .. book_filename .. suffix,
        "write path stays canonical (read-only resolver does not move writes)")

    package.loaded["docsettings"] = saved_docsettings
    os.execute("rm -rf '" .. root .. "'")
end


-- ----------------------------------------------------------------------------
-- Ownership-checked directory removal (never delete KOReader's .sdr)
-- ----------------------------------------------------------------------------

do
    Paths.set_storage_mode("hash")
    local state_dir = Paths._syncery_state_dir()

    -- Owned: a directory inside synceryhash/ (sharded) — removal allowed.
    local owned = state_dir .. "/synceryhash/de/deadbeefdeadbeef"
    os.execute("mkdir -p '" .. owned .. "' 2>/dev/null")
    h.assert_true(lfs.attributes(owned, "mode") == "directory",
        "precondition: owned dir exists")
    local ok_owned = Paths.remove_owned_directory(owned)
    h.assert_true(ok_owned == true,
        "remove_owned_directory: returns true for a synceryhash/ dir")
    h.assert_true(lfs.attributes(owned, "mode") == nil,
        "remove_owned_directory: actually removed the owned dir")

    -- NOT owned: a fake KOReader .sdr elsewhere — must be refused untouched.
    local foreign = "/tmp/syncery_ownership_" .. tostring(os.time()) .. "/book.sdr"
    os.execute("mkdir -p '" .. foreign .. "' 2>/dev/null")
    local ok_foreign = Paths.remove_owned_directory(foreign)
    h.assert_true(ok_foreign == false,
        "remove_owned_directory: refuses a non-owned (.sdr) dir")
    h.assert_true(lfs.attributes(foreign, "mode") == "directory",
        "remove_owned_directory: left the non-owned dir intact")
    os.execute("rm -rf '" .. foreign:match("^(.*)/[^/]+$") .. "'")

    -- The state-dir ROOT itself is not "owned" for removal (it holds
    -- last_sync/ and cloud_staging/ siblings).
    h.assert_true(Paths.remove_owned_directory(state_dir) == false,
        "remove_owned_directory: refuses the state-dir root")
end


do
    local StorageMode = require("syncery_storage_mode")

    -- The relocation API must be gone.
    h.assert_true(type(StorageMode.set_hash_root) ~= "function",
        "set_hash_root is removed (hash root is fixed)")

    -- get_hash_root resolves to the default root, and the per-book shared dir
    -- sits under it, under synceryhash/.
    Paths.set_storage_mode("hash")
    local root      = StorageMode.get_hash_root()
    local state_dir = Paths._shared_book_state_dir("/tmp/foo/book.epub")

    h.assert_true(type(root) == "string" and root ~= "",
        "get_hash_root returns the fixed default root")
    h.assert_true(state_dir ~= nil and state_dir:find(root, 1, true) == 1,
        "shared book dir is rooted at the fixed hash root")
    h.assert_true(state_dir:find("/synceryhash/", 1, true) ~= nil,
        "shared book dir is under the synceryhash/ subdirectory")

    -- The scan's root source agrees with the builder's root.
    h.assert_true(Paths._syncery_state_dir():find(root, 1, true) == 1,
        "_syncery_state_dir (scan root source) resolves under the same fixed root")
end
