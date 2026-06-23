-- =============================================================================
-- spec/orphan_adapters_present_spec.lua
-- =============================================================================
--
-- Tests for OrphanAdapters.present_book_hashes (syncery_migration/orphan_adapters.lua).
--
-- Exercises the REAL adapter over a REAL temporary filesystem, with injected
-- deps (lfs, home_dir, configured_roots, book_content_id). The content hash is
-- modelled as a content-derived value so "same content => same hash" holds, the
-- only property the present-set relies on.
--
-- Focus: home_dir is the BASE (always walked); configured roots are an
-- OPPORTUNISTIC additive (absence must NOT block); .sdr dirs are skipped;
-- books are de-duplicated; the walk is depth-bounded; a root nested under
-- another is not re-walked.
--
-- =============================================================================

local h = require("spec.test_helpers")
local lfs = require("lfs")
local OrphanAdapters = require("syncery_migration/orphan_adapters")

h.setup("/tmp/syncery_test_orphanpresent_" .. tostring(os.time()))
local ROOT = h.test_root

-- ---- fs helpers ----
local function mkdirp(path)
    os.execute("mkdir -p '" .. path .. "' 2>/dev/null")
end
local function wf(path, content)
    local dir = path:match("^(.*)/[^/]+$")
    if dir then mkdirp(dir) end
    local f = assert(io.open(path, "wb")); f:write(content); f:close()
end
-- content-derived hash (models partialMD5's content-keyed property)
local function content_hash(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local data = f:read("*a") or ""; f:close()
    local hsh = 5381
    for i = 1, #data do hsh = (hsh * 33 + data:byte(i)) % 4294967296 end
    return string.format("%08x", hsh)
end

-- deps factory: home_dir + optional roots; book_content_id reads file content
local function make_deps(home, roots)
    return {
        lfs = lfs,
        home_dir = function() return home end,
        configured_roots = function() return roots end,
        book_content_id = function(p) return content_hash(p) end,
    }
end

local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
local function has_hash_of(set, path) local hsh = content_hash(path); return hsh ~= nil and set[hsh] == true end

-- ==========================================================================
-- contract
-- ==========================================================================
do
    h.assert_false(pcall(function() OrphanAdapters.present_book_hashes(nil) end), "rejects nil deps")
    h.assert_false(pcall(function() OrphanAdapters.present_book_hashes({ lfs = lfs }) end), "rejects missing home_dir")
end

-- ==========================================================================
-- A — home_dir is the BASE: books under it are all hashed
-- ==========================================================================
do
    local home = ROOT .. "/A_home"
    wf(home .. "/Alice.epub", "ALICE-CONTENT")
    wf(home .. "/sub/Bob.pdf", "BOB-CONTENT")
    wf(home .. "/sub/deep/Carol.mobi", "CAROL-CONTENT")
    local set = OrphanAdapters.present_book_hashes(make_deps(home, nil))
    h.assert_equal(count(set), 3, "A: three books hashed from home_dir")
    h.assert_true(has_hash_of(set, home .. "/Alice.epub"), "A: Alice present")
    h.assert_true(has_hash_of(set, home .. "/sub/Bob.pdf"), "A: Bob present")
    h.assert_true(has_hash_of(set, home .. "/sub/deep/Carol.mobi"), "A: Carol present")
end

-- ==========================================================================
-- B — NO configured roots must NOT block (nil and empty table both work)
-- ==========================================================================
do
    local home = ROOT .. "/B_home"
    wf(home .. "/Solo.epub", "SOLO-CONTENT")
    local set_nil = OrphanAdapters.present_book_hashes(make_deps(home, nil))
    h.assert_equal(count(set_nil), 1, "B: nil roots → still scans home_dir")
    local set_empty = OrphanAdapters.present_book_hashes(make_deps(home, {}))
    h.assert_equal(count(set_empty), 1, "B: empty roots → still scans home_dir")
end

-- ==========================================================================
-- C — configured roots are OPPORTUNISTIC ADDITIVE: a book outside home_dir is
--     caught only when a covering root is supplied
-- ==========================================================================
do
    local home = ROOT .. "/C_home"
    local elsewhere = ROOT .. "/C_elsewhere"
    wf(home .. "/InHome.epub", "INHOME-CONTENT")
    wf(elsewhere .. "/Outside.epub", "OUTSIDE-CONTENT")

    -- without the root: outside book is NOT in the set
    local set_without = OrphanAdapters.present_book_hashes(make_deps(home, nil))
    h.assert_true(has_hash_of(set_without, home .. "/InHome.epub"), "C: in-home present without root")
    h.assert_false(has_hash_of(set_without, elsewhere .. "/Outside.epub"), "C: outside ABSENT without root")

    -- with the root: outside book IS caught
    local set_with = OrphanAdapters.present_book_hashes(make_deps(home, { elsewhere }))
    h.assert_true(has_hash_of(set_with, elsewhere .. "/Outside.epub"), "C: outside caught WITH root")
    h.assert_equal(count(set_with), 2, "C: both books present with root")
end

-- ==========================================================================
-- D — .sdr directories are SKIPPED (their contents are sidecars, not books)
-- ==========================================================================
do
    local home = ROOT .. "/D_home"
    wf(home .. "/Real.epub", "REAL-CONTENT")
    -- a sidecar dir containing a file with a book-like extension
    wf(home .. "/Real.sdr/metadata.epub.lua", "return {}")
    wf(home .. "/Real.sdr/Real.epub.syncery-progress.json", "{}")
    local set = OrphanAdapters.present_book_hashes(make_deps(home, nil))
    h.assert_equal(count(set), 1, "D: only the real book hashed; .sdr contents skipped")
    h.assert_true(has_hash_of(set, home .. "/Real.epub"), "D: real book present")
end

-- ==========================================================================
-- E — DEDUP: the same book under home_dir AND a configured root → one hash
-- ==========================================================================
do
    local home = ROOT .. "/E_home"
    local root2 = ROOT .. "/E_root2"
    wf(home .. "/Dup.epub", "DUP-SAME-CONTENT")
    wf(root2 .. "/DupCopy.epub", "DUP-SAME-CONTENT")  -- identical content, different path
    local set = OrphanAdapters.present_book_hashes(make_deps(home, { root2 }))
    -- identical content → identical hash → set has ONE entry
    h.assert_equal(count(set), 1, "E: identical-content books collapse to one hash")
end

-- ==========================================================================
-- F — nested configured root under home_dir is NOT re-walked (no double work,
--     result still correct)
-- ==========================================================================
do
    local home = ROOT .. "/F_home"
    local nested = home .. "/library"   -- nested UNDER home_dir
    wf(home .. "/Top.epub", "TOP-CONTENT")
    wf(nested .. "/Nested.epub", "NESTED-CONTENT")
    -- supplying the nested dir as a configured root should not change the result
    local set = OrphanAdapters.present_book_hashes(make_deps(home, { nested }))
    h.assert_equal(count(set), 2, "F: both books present, nested root not double-counted")
    h.assert_true(has_hash_of(set, home .. "/Top.epub"), "F: top present")
    h.assert_true(has_hash_of(set, nested .. "/Nested.epub"), "F: nested present")
end

-- ==========================================================================
-- G — empty / nonexistent home_dir → empty set (no crash)
-- ==========================================================================
do
    local set_missing = OrphanAdapters.present_book_hashes(make_deps(ROOT .. "/does_not_exist", nil))
    h.assert_equal(count(set_missing), 0, "G: nonexistent home_dir → empty set")

    local empty_home = ROOT .. "/G_empty"
    mkdirp(empty_home)
    local set_empty = OrphanAdapters.present_book_hashes(make_deps(empty_home, nil))
    h.assert_equal(count(set_empty), 0, "G: empty home_dir → empty set")
end

-- ==========================================================================
-- H — non-book files ignored (default extension predicate)
-- ==========================================================================
do
    local home = ROOT .. "/H_home"
    wf(home .. "/Book.epub", "BOOK-CONTENT")
    wf(home .. "/notes.xyz", "NOT-A-BOOK")
    wf(home .. "/cover.jpg", "IMAGE-DATA")
    local set = OrphanAdapters.present_book_hashes(make_deps(home, nil))
    h.assert_equal(count(set), 1, "H: only the book counted; .xyz/.jpg ignored")
end

-- ==========================================================================
-- I — injected is_book_file predicate overrides the default
-- ==========================================================================
do
    local home = ROOT .. "/I_home"
    wf(home .. "/custom.xyz", "CUSTOM-CONTENT")
    local deps = make_deps(home, nil)
    deps.is_book_file = function(_name, ext) return ext == "xyz" end
    local set = OrphanAdapters.present_book_hashes(deps)
    h.assert_equal(count(set), 1, "I: injected predicate recognises .xyz")
    h.assert_true(has_hash_of(set, home .. "/custom.xyz"), "I: custom book present")
end

h.teardown()
print("orphan_adapters_present_spec: all assertions passed")
