-- =============================================================================
-- spec/sdr_doc_json_creation_spec.lua
-- =============================================================================
--
-- QUESTION (user): in KOReader's DEFAULT metadata location — "book folder",
-- i.e. a real human-named `<Book>.sdr` directory sitting NEXT TO the book file
-- (KOReader document_metadata_folder = "doc") — does Syncery, in its SDR
-- storage mode, actually CREATE its JSON sidecar files on disk?
--
-- This is a REAL end-to-end test of the production chain, traced to code:
--
--   StateStore.save_shared(book)                       [state_store.lua L133]
--     -> Paths.shared_annotations_path(book)           [paths.lua L103]
--          -> _sidecar_dir_for_book                    [-> docsettings:getSidecarDir]
--          -> "<book>.sdr/<name>.syncery-annotations.json"   [L118]
--          -> (does NOT mkdir — unlike hash/last_sync)        [the P1 gap]
--     -> JsonStore.write(file_path, state_table)        [state_store.lua L138]
--          -> util.makePath(parent)   <-- the P1 fix: mkdir -p the .sdr        [json_store.lua L208]
--          -> io.open(tmp,"wb") -> write -> rename       [POSIX atomic]
--
-- Everything runs against a REAL lfs on a REAL temp dir and asserts a REAL
-- file appears on disk. We do NOT mock save_shared.
--
-- THE TRAP we deliberately avoid: the global test_helpers `docsettings`
-- stub's getSidecarDir does `mkdir -p` on the .sdr itself, so with it the
-- .sdr ALWAYS exists and the P1-mkdir path is NEVER exercised — a green run
-- there would prove nothing about "is the dir created when it's missing".
-- So this spec installs its OWN docsettings stub that returns the .sdr path
-- WITHOUT creating it, letting us control whether the dir pre-exists. That
-- mirrors real doc-mode: KOReader owns when the .sdr appears, not Syncery.
--
-- Cases:
--   1. doc-mode, .sdr ALREADY exists  -> JSON created inside, correct name,
--      content round-trips. (baseline path)
--   2. doc-mode, .sdr MISSING (fresh book, before KOReader's first metadata
--      flush — the exact P1 scenario) -> P1 makePath creates it, JSON still
--      created. (the case the user is really asking about)
--   3. REGRESSION GUARD: break P1 (makePath -> no-op) and prove case 2 now
--      FAILS (no file), then restore. Proves this test actually catches P1.
--
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_sdr_doc_json_spec_" .. tostring(os.time()))

local lfs = require("lfs")

-- ---------------------------------------------------------------------------
-- Install OUR docsettings stub BEFORE requiring the modules under test, so
-- Paths._sidecar_dir_for_book (which require()s "docsettings" each call) picks
-- it up. Unlike the global helper stub, getSidecarDir here returns the .sdr
-- path but does NOT create it — the test decides when the dir exists.
--
-- doc-mode semantics: the .sdr sits NEXT TO the book. We honour that exactly:
-- for "<root>/Some Book.epub" we return "<root>/Some Book.sdr".
-- ---------------------------------------------------------------------------
local function book_sdr_path(book_path)
    -- strip the extension, append ".sdr" — KOReader's doc-mode layout
    local stem = book_path:gsub("%.%w+$", "")
    return stem .. ".sdr"
end

package.loaded["docsettings"] = {
    getSidecarDir = function(_self, book_path)
        return book_sdr_path(book_path)   -- NB: no mkdir here, on purpose
    end,
    open = function(_self, _book_path)
        -- save_shared's path builder doesn't need partial_md5 in SDR mode
        -- (the sidecar name comes from the book filename, not a hash), but
        -- provide a benign reader so any incidental open() is harmless.
        return { readSetting = function() return nil end }
    end,
}

-- util.makePath is the P1 fix's mkdir. The global helper stub already mirrors
-- KOReader's makePath (mkdir -p). We keep that, and in case 3 we monkeypatch
-- it to a no-op to prove the regression, then restore the original.
local util = require("util")
local real_makePath = util.makePath

local Paths      = require("syncery_ann/paths")
local StateStore = require("syncery_ann/state_store")

-- Force SDR storage mode (the case under test). hash mode is a different path.
Paths.set_storage_mode("sdr")
h.assert_equal(Paths.get_storage_mode(), "sdr", "storage mode is sdr for this spec")

-- A real temp library root for "books on disk".
local LIB = (os.getenv("TMPDIR") or "/tmp") .. "/syncery_sdr_doc_lib_" .. tostring(os.time())
os.execute("mkdir -p '" .. LIB .. "' 2>/dev/null")

-- Helper: does a file exist as a regular file?
local function is_file(p)
    return lfs.attributes(p, "mode") == "file"
end
local function is_dir(p)
    return lfs.attributes(p, "mode") == "directory"
end

-- Helper: read a whole file (real disk read-back).
local function read_all(p)
    local fh = io.open(p, "rb")
    if not fh then return nil end
    local data = fh:read("*a")
    fh:close()
    return data
end

-- A minimal but realistic shared-annotations state table.
local function sample_state()
    return {
        annotations = {
            ["pos0|chapter1"] = {
                pos0 = "pos0", pos1 = "pos1",
                text = "a highlight", datetime = "2026-01-01 10:00:00",
            },
        },
    }
end

-- ===========================================================================
-- CASE 1 — doc-mode, .sdr ALREADY exists -> JSON created inside it.
-- ===========================================================================
do
    local book = LIB .. "/Alice in Wonderland.epub"
    os.execute("touch '" .. book .. "'")                 -- the book file exists
    local sdr = book_sdr_path(book)                       -- "<...>/Alice in Wonderland.sdr"
    os.execute("mkdir -p '" .. sdr .. "' 2>/dev/null")                -- KOReader already made it

    h.assert_true(is_dir(sdr), "case1: .sdr pre-exists")

    -- Sanity: the path builder points INSIDE the book-named .sdr, with the
    -- ".syncery-annotations.json" suffix and the book's filename.
    -- NB: the JSON keeps the book's FULL filename incl. extension (paths.lua
    -- L117 takes the last path segment), while the .sdr DIR drops it. So it's
    -- "Alice in Wonderland.sdr/Alice in Wonderland.epub.syncery-annotations.json".
    local want_path = sdr .. "/Alice in Wonderland.epub.syncery-annotations.json"
    local got_path  = Paths.shared_annotations_path(book)
    h.assert_equal(got_path, want_path, "case1: JSON path is inside book .sdr, correct name")

    local ok = StateStore.save_shared(book, sample_state(), "deviceA", "Device A")
    h.assert_true(ok, "case1: save_shared returns true")
    h.assert_true(is_file(want_path), "case1: JSON FILE actually created on disk")

    -- Real read-back: the file is non-empty and contains our highlight text.
    local body = read_all(want_path)
    h.assert_true(body ~= nil and #body > 0, "case1: JSON file is non-empty")
    h.assert_true(body:find("a highlight", 1, true) ~= nil,
        "case1: JSON content round-trips (contains the highlight text)")
end

-- ===========================================================================
-- CASE 2 — doc-mode, .sdr MISSING (fresh book, before KOReader's first
-- metadata flush). This is the exact P1 scenario. The chain must create the
-- .sdr via JsonStore's makePath and still write the JSON.
-- ===========================================================================
do
    local book = LIB .. "/Brand New Book.epub"
    os.execute("touch '" .. book .. "'")                 -- book exists...
    local sdr = book_sdr_path(book)
    -- ...but the .sdr does NOT (we never mkdir it; our stub doesn't either)
    h.assert_false(is_dir(sdr), "case2: .sdr is MISSING before save (fresh book)")

    local want_path = sdr .. "/Brand New Book.epub.syncery-annotations.json"

    local ok = StateStore.save_shared(book, sample_state(), "deviceA", "Device A")
    h.assert_true(ok, "case2: save_shared returns true even though .sdr was missing")
    h.assert_true(is_dir(sdr), "case2: .sdr was CREATED by the write chain (P1 makePath)")
    h.assert_true(is_file(want_path), "case2: JSON FILE created on disk in the new .sdr")

    local body = read_all(want_path)
    h.assert_true(body ~= nil and #body > 0, "case2: JSON file is non-empty")
end

-- ===========================================================================
-- CASE 3 — REGRESSION GUARD. With P1 removed (makePath -> no-op), case 2 must
-- FAIL: the .sdr stays missing and no JSON file appears. This proves the test
-- genuinely exercises P1 rather than passing for unrelated reasons.
-- (On POSIX, io.open(tmp,"wb") into a non-existent directory returns nil, so
-- the atomic write can't even create its temp file.)
-- ===========================================================================
do
    -- Break P1.
    util.makePath = function() return true end   -- pretends success, makes nothing

    local book = LIB .. "/Guarded Book.epub"
    os.execute("touch '" .. book .. "'")
    local sdr = book_sdr_path(book)
    h.assert_false(is_dir(sdr), "case3: .sdr missing at start (P1 broken)")

    local want_path = sdr .. "/Guarded Book.epub.syncery-annotations.json"

    local ok = StateStore.save_shared(book, sample_state(), "deviceA", "Device A")

    -- The guard's core assertions: without the mkdir, nothing lands on disk.
    h.assert_false(is_dir(sdr), "case3: .sdr STILL missing (proves makePath was the creator)")
    h.assert_false(is_file(want_path), "case3: NO JSON file created when P1 is broken")
    h.assert_false(ok, "case3: save_shared reports failure when the dir can't be made")

    -- Restore P1 so we leave the world as we found it, and prove restoration
    -- actually re-enables creation (same book, now succeeds).
    util.makePath = real_makePath
    local ok2 = StateStore.save_shared(book, sample_state(), "deviceA", "Device A")
    h.assert_true(ok2, "case3: after restoring P1, save_shared succeeds again")
    h.assert_true(is_file(want_path), "case3: after restoring P1, JSON file is created")
end

-- Cleanup our temp library (helpers.teardown handles the spec test_root).
os.execute("rm -rf '" .. LIB .. "'")
h.teardown()

print("sdr_doc_json_creation_spec: all assertions passed")
