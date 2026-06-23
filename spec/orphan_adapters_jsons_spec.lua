-- =============================================================================
-- spec/orphan_adapters_jsons_spec.lua
-- =============================================================================
--
-- Tests for OrphanAdapters.syncery_jsons (syncery_migration/orphan_adapters.lua).
--
-- Walks the REAL adapter over a REAL temporary filesystem laid out as the four
-- location trees, with injected root getters. Each tree's files must be tagged
-- with the correct location class; both progress and annotations JSONs must be
-- found; lookalikes ignored; a nil/absent tree skipped without error.
--
-- =============================================================================

local h = require("spec.test_helpers")
local lfs = require("lfs")
local OrphanAdapters = require("syncery_migration/orphan_adapters")

h.setup("/tmp/syncery_test_orphanjsons_" .. tostring(os.time()))
local ROOT = h.test_root

local function mkdirp(path) os.execute("mkdir -p '" .. path .. "' 2>/dev/null") end
local function wf(path, content)
    local dir = path:match("^(.*)/[^/]+$"); if dir then mkdirp(dir) end
    local f = assert(io.open(path, "wb")); f:write(content); f:close()
end

-- find an entry by path; return its klass or nil
local function klass_of(list, path)
    for _, e in ipairs(list) do if e.path == path then return e.klass end end
    return nil
end
local function count(list) return #list end

-- ==========================================================================
-- contract
-- ==========================================================================
do
    h.assert_false(pcall(function() OrphanAdapters.syncery_jsons(nil) end), "rejects nil deps")
    h.assert_false(pcall(function() OrphanAdapters.syncery_jsons({}) end), "rejects missing lfs")
end

-- ==========================================================================
-- A — each tree's JSONs tagged with the correct klass; progress+annotations both
-- ==========================================================================
do
    local sh   = ROOT .. "/A_sh/synceryhash"
    local home = ROOT .. "/A_home"
    local dir  = ROOT .. "/A_dir/docsettings"
    local hash = ROOT .. "/A_hash/hashdocsettings"

    -- synceryhash: no book prefix
    wf(sh .. "/ab/abcd1234/syncery-progress.json", "{}")
    wf(sh .. "/ab/abcd1234/syncery-annotations.json", "{}")
    -- doc: <book>.sdr beside book in home
    wf(home .. "/Book.epub.sdr/Book.epub.syncery-progress.json", "{}")
    wf(home .. "/Book.epub.sdr/Book.epub.syncery-annotations.json", "{}")
    -- dir: docsettings tree
    wf(dir .. "/some/path/Doc.epub.sdr/Doc.epub.syncery-progress.json", "{}")
    -- hash: hashdocsettings tree, <hash>.sdr
    wf(hash .. "/cd/cdef5678.sdr/Some.epub.syncery-progress.json", "{}")

    local deps = {
        lfs = lfs,
        synceryhash_root = function() return sh end,
        doc_roots = function() return { home } end,
        dir_tree_root = function() return dir end,
        hash_tree_root = function() return hash end,
    }
    local list = OrphanAdapters.syncery_jsons(deps)
    h.assert_equal(count(list), 6, "A: all six JSONs enumerated across four trees")

    h.assert_equal(klass_of(list, sh .. "/ab/abcd1234/syncery-progress.json"), "synceryhash", "A: synceryhash progress klass")
    h.assert_equal(klass_of(list, sh .. "/ab/abcd1234/syncery-annotations.json"), "synceryhash", "A: synceryhash annotations klass")
    h.assert_equal(klass_of(list, home .. "/Book.epub.sdr/Book.epub.syncery-progress.json"), "doc", "A: doc progress klass")
    h.assert_equal(klass_of(list, home .. "/Book.epub.sdr/Book.epub.syncery-annotations.json"), "doc", "A: doc annotations klass")
    h.assert_equal(klass_of(list, dir .. "/some/path/Doc.epub.sdr/Doc.epub.syncery-progress.json"), "dir", "A: dir klass")
    h.assert_equal(klass_of(list, hash .. "/cd/cdef5678.sdr/Some.epub.syncery-progress.json"), "hashdocsettings", "A: hash klass")
end

-- ==========================================================================
-- B — lookalike files ignored (.bak, .txt, wrong name)
-- ==========================================================================
do
    local sh = ROOT .. "/B_sh/synceryhash"
    wf(sh .. "/ab/abcd1234/syncery-progress.json", "{}")          -- real
    wf(sh .. "/ab/abcd1234/syncery-progress.json.bak", "{}")      -- .bak → ignore
    wf(sh .. "/ab/abcd1234/syncery-progress.txt", "{}")           -- wrong ext → ignore
    wf(sh .. "/ab/abcd1234/notes.json", "{}")                     -- not syncery → ignore
    local deps = { lfs = lfs, synceryhash_root = function() return sh end }
    local list = OrphanAdapters.syncery_jsons(deps)
    h.assert_equal(count(list), 1, "B: only the real syncery-progress.json enumerated")
    h.assert_equal(list[1].klass, "synceryhash", "B: tagged synceryhash")
end

-- ==========================================================================
-- C — absent / nil tree getters are skipped without error
-- ==========================================================================
do
    local home = ROOT .. "/C_home"
    wf(home .. "/B.epub.sdr/B.epub.syncery-progress.json", "{}")
    -- only doc_roots provided; the other three getters absent
    local deps = { lfs = lfs, doc_roots = function() return { home } end }
    local list = OrphanAdapters.syncery_jsons(deps)
    h.assert_equal(count(list), 1, "C: missing tree getters skipped; doc tree still walked")
    h.assert_equal(list[1].klass, "doc", "C: doc klass")

    -- a getter returning nil (tree configured but absent) also skipped
    local deps2 = {
        lfs = lfs,
        synceryhash_root = function() return nil end,
        doc_roots = function() return { home } end,
        dir_tree_root = function() return ROOT .. "/C_no_such_dir" end,
        hash_tree_root = function() return nil end,
    }
    local list2 = OrphanAdapters.syncery_jsons(deps2)
    h.assert_equal(count(list2), 1, "C: nil/nonexistent trees skipped, doc still found")
end

-- ==========================================================================
-- D — multiple doc roots (home_dir ∪ a configured root) both walked
-- ==========================================================================
do
    local home  = ROOT .. "/D_home"
    local extra = ROOT .. "/D_extra"
    wf(home  .. "/H.epub.sdr/H.epub.syncery-progress.json", "{}")
    wf(extra .. "/E.epub.sdr/E.epub.syncery-annotations.json", "{}")
    local deps = { lfs = lfs, doc_roots = function() return { home, extra } end }
    local list = OrphanAdapters.syncery_jsons(deps)
    h.assert_equal(count(list), 2, "D: both doc roots walked")
    h.assert_equal(klass_of(list, home  .. "/H.epub.sdr/H.epub.syncery-progress.json"), "doc", "D: home doc")
    h.assert_equal(klass_of(list, extra .. "/E.epub.sdr/E.epub.syncery-annotations.json"), "doc", "D: extra doc")
end

-- ==========================================================================
-- E — empty world (all trees empty) → empty list, no crash
-- ==========================================================================
do
    local deps = {
        lfs = lfs,
        synceryhash_root = function() return ROOT .. "/E_none1" end,
        doc_roots = function() return { ROOT .. "/E_none2" } end,
        dir_tree_root = function() return nil end,
        hash_tree_root = function() return nil end,
    }
    local list = OrphanAdapters.syncery_jsons(deps)
    h.assert_equal(count(list), 0, "E: empty world → no JSONs")
end

-- ==========================================================================
-- F — nested JSONs deep in the synceryhash tree are reached (shard structure)
-- ==========================================================================
do
    local sh = ROOT .. "/F_sh/synceryhash"
    wf(sh .. "/00/0000aaaa/syncery-progress.json", "{}")
    wf(sh .. "/ff/ffff9999/syncery-annotations.json", "{}")
    local deps = { lfs = lfs, synceryhash_root = function() return sh end }
    local list = OrphanAdapters.syncery_jsons(deps)
    h.assert_equal(count(list), 2, "F: both sharded synceryhash JSONs reached")
end

h.teardown()
print("orphan_adapters_jsons_spec: all assertions passed")
