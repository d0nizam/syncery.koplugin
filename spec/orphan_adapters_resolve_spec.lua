-- =============================================================================
-- spec/orphan_adapters_resolve_spec.lua
-- =============================================================================
--
-- Tests for OrphanAdapters.json_book_hash and .json_book_name_present
-- (syncery_migration/orphan_adapters.lua) — the per-JSON identity resolvers.
--
-- Real temporary filesystem with real metadata.<ext>.lua files; the loader is
-- the production default (dofile) so we also exercise the actual file read.
-- Covers: structural hash for synceryhash (path) and hashdocsettings (.sdr
-- name); metadata-derived hash for doc/dir; FORMAT-SPECIFIC resolution in a
-- shared .sdr; nil when the hash is absent; name-presence via doc_path
-- (true/false), the doc reconstruction fallback, and fail-closed (nil).
--
-- =============================================================================

local h = require("spec.test_helpers")
local lfs = require("lfs")
local OrphanAdapters = require("syncery_migration/orphan_adapters")

h.setup("/tmp/syncery_test_orphanresolve_" .. tostring(os.time()))
local ROOT = h.test_root

local function mkdirp(path) os.execute("mkdir -p '" .. path .. "' 2>/dev/null") end
local function wf(path, content)
    local dir = path:match("^(.*)/[^/]+$"); if dir then mkdirp(dir) end
    local f = assert(io.open(path, "wb")); f:write(content); f:close()
end
-- write a metadata.<ext>.lua with optional fields
local function wmeta(path, fields)
    local parts = {}
    for k, v in pairs(fields) do parts[#parts+1] = k .. " = '" .. v .. "'" end
    wf(path, "return {\n  " .. table.concat(parts, ",\n  ") .. ",\n}\n")
end

local deps = { lfs = lfs }   -- production dofile loader

-- ==========================================================================
-- json_book_hash — synceryhash: hash is the dir name containing the JSON
-- ==========================================================================
do
    local p = ROOT .. "/sh/synceryhash/ab/abcd1234ef/syncery-progress.json"
    wf(p, "{}")
    local hash = OrphanAdapters.json_book_hash(deps, { path = p, klass = "synceryhash" })
    h.assert_equal(hash, "abcd1234ef", "synceryhash: hash extracted from path dir name")
end

-- ==========================================================================
-- json_book_hash — hashdocsettings: hash is the .sdr dir name (stripped)
-- ==========================================================================
do
    local p = ROOT .. "/hd/hashdocsettings/cd/cdef5678.sdr/Book.epub.syncery-progress.json"
    wf(p, "{}")
    local hash = OrphanAdapters.json_book_hash(deps, { path = p, klass = "hashdocsettings" })
    h.assert_equal(hash, "cdef5678", "hashdocsettings: hash from .sdr dir name")
end

-- ==========================================================================
-- json_book_hash — doc/dir: hash from sibling metadata.<ext>.lua
-- ==========================================================================
do
    local sdr = ROOT .. "/doc_home/Book.epub.sdr"
    local p = sdr .. "/Book.epub.syncery-progress.json"
    wf(p, "{}")
    wmeta(sdr .. "/metadata.epub.lua", { partial_md5_checksum = "deadbeef00", doc_path = ROOT .. "/doc_home/Book.epub" })
    local hash = OrphanAdapters.json_book_hash(deps, { path = p, klass = "doc" })
    h.assert_equal(hash, "deadbeef00", "doc: hash read from sibling metadata.lua")
end

-- ==========================================================================
-- json_book_hash — doc: nil when metadata has NO partial_md5
-- ==========================================================================
do
    local sdr = ROOT .. "/doc_nohash/Book.epub.sdr"
    local p = sdr .. "/Book.epub.syncery-progress.json"
    wf(p, "{}")
    wmeta(sdr .. "/metadata.epub.lua", { doc_path = ROOT .. "/doc_nohash/Book.epub" })  -- no hash
    local hash = OrphanAdapters.json_book_hash(deps, { path = p, klass = "doc" })
    h.assert_nil(hash, "doc: nil hash when partial_md5 absent")
end

-- ==========================================================================
-- json_book_hash — doc: nil when NO metadata.lua at all
-- ==========================================================================
do
    local sdr = ROOT .. "/doc_nometa/Book.epub.sdr"
    local p = sdr .. "/Book.epub.syncery-progress.json"
    wf(p, "{}")   -- no metadata.lua
    local hash = OrphanAdapters.json_book_hash(deps, { path = p, klass = "doc" })
    h.assert_nil(hash, "doc: nil hash when no metadata.lua")
end

-- ==========================================================================
-- json_book_hash — FORMAT-SPECIFIC: shared .sdr, read the matching format only
-- ==========================================================================
do
    local sdr = ROOT .. "/shared/Book.sdr"
    -- two formats share one .sdr; each has its own metadata + Syncery JSON
    wf(sdr .. "/Book.pdf.syncery-progress.json", "{}")
    wf(sdr .. "/Book.mobi.syncery-progress.json", "{}")
    wmeta(sdr .. "/metadata.pdf.lua",  { partial_md5_checksum = "pdfhash111", doc_path = ROOT .. "/shared/Book.pdf" })
    wmeta(sdr .. "/metadata.mobi.lua", { partial_md5_checksum = "mobihash222", doc_path = ROOT .. "/shared/Book.mobi" })
    local hp = OrphanAdapters.json_book_hash(deps, { path = sdr .. "/Book.pdf.syncery-progress.json",  klass = "doc" })
    local hm = OrphanAdapters.json_book_hash(deps, { path = sdr .. "/Book.mobi.syncery-progress.json", klass = "doc" })
    h.assert_equal(hp, "pdfhash111",  "shared .sdr: PDF JSON resolves PDF metadata hash")
    h.assert_equal(hm, "mobihash222", "shared .sdr: MOBI JSON resolves MOBI metadata hash")
end

-- ==========================================================================
-- json_book_name_present — doc_path present, book EXISTS → true
-- ==========================================================================
do
    local home = ROOT .. "/np_exists"
    local book = home .. "/Live.epub"
    wf(book, "LIVE")
    local sdr = home .. "/Live.epub.sdr"
    local p = sdr .. "/Live.epub.syncery-progress.json"
    wf(p, "{}")
    wmeta(sdr .. "/metadata.epub.lua", { doc_path = book })
    local np = OrphanAdapters.json_book_name_present(deps, { path = p, klass = "doc" })
    h.assert_true(np, "name-present: doc_path points to existing book → true")
end

-- ==========================================================================
-- json_book_name_present — doc_path present, book GONE → false
-- ==========================================================================
do
    local home = ROOT .. "/np_gone"
    local book = home .. "/Gone.epub"   -- never created
    local sdr = home .. "/Gone.epub.sdr"
    local p = sdr .. "/Gone.epub.syncery-progress.json"
    wf(p, "{}")
    wmeta(sdr .. "/metadata.epub.lua", { doc_path = book })
    local np = OrphanAdapters.json_book_name_present(deps, { path = p, klass = "doc" })
    h.assert_false(np, "name-present: doc_path points to missing book → false")
end

-- ==========================================================================
-- json_book_name_present — doc reconstruction fallback (no doc_path), book exists
-- ==========================================================================
do
    local home = ROOT .. "/np_recon"
    local book = home .. "/Recon.epub"
    wf(book, "RECON")
    local sdr = home .. "/Recon.epub.sdr"
    local p = sdr .. "/Recon.epub.syncery-progress.json"
    wf(p, "{}")
    wmeta(sdr .. "/metadata.epub.lua", {})   -- no doc_path → reconstruct beside .sdr
    local np = OrphanAdapters.json_book_name_present(deps, { path = p, klass = "doc" })
    h.assert_true(np, "name-present: doc reconstruction finds sibling book → true")
end

-- ==========================================================================
-- json_book_name_present — dir mode, no doc_path → undeterminable → nil (fail-closed)
-- ==========================================================================
do
    local dir = ROOT .. "/np_dir/docsettings/some/Book.epub.sdr"
    local p = dir .. "/Book.epub.syncery-progress.json"
    wf(p, "{}")
    wmeta(dir .. "/metadata.epub.lua", {})   -- no doc_path; dir has no reconstruction
    local np = OrphanAdapters.json_book_name_present(deps, { path = p, klass = "dir" })
    h.assert_nil(np, "name-present: dir with no doc_path → nil (fail-closed)")
end

-- ==========================================================================
-- json_book_name_present — content-keyed klass → nil (never consulted, guarded)
-- ==========================================================================
do
    local np = OrphanAdapters.json_book_name_present(deps, { path = "/x", klass = "synceryhash" })
    h.assert_nil(np, "name-present: synceryhash → nil (guard)")
end

-- ==========================================================================
-- end-to-end through the DECISION CORE: real adapters + real fs, doc content-mod
-- kept; synceryhash content-mod orphaned (the §23.13a split, via real resolvers)
-- ==========================================================================
do
    local OrphanCleanup = require("syncery_migration/orphan_cleanup")
    local home = ROOT .. "/e2e_home"

    -- doc book, content-modified: metadata holds OLD hash, book still at path
    local doc_book = home .. "/Doc.epub"
    wf(doc_book, "DOC-MODIFIED")
    local doc_sdr = home .. "/Doc.epub.sdr"
    local doc_json = doc_sdr .. "/Doc.epub.syncery-progress.json"
    wf(doc_json, "{}")
    wmeta(doc_sdr .. "/metadata.epub.lua", { partial_md5_checksum = "OLDHASH_doc", doc_path = doc_book })

    -- synceryhash book, content-modified: path hash is OLD, no present match
    local sh_json = ROOT .. "/e2e_sh/synceryhash/ol/OLDHASH_sh/syncery-progress.json"
    wf(sh_json, "{}")

    -- present-set: only the doc book's CURRENT hash (sh book's new hash differs;
    -- we just don't include OLDHASH_sh). Build via the real present adapter over home.
    local present = OrphanAdapters.present_book_hashes({
        lfs = lfs,
        home_dir = function() return home end,
        book_content_id = function(_) return "CURRENT_doc" end,  -- the doc book's current (new) hash
    })

    local entries = {
        { path = doc_json, klass = "doc" },
        { path = sh_json,  klass = "synceryhash" },
    }
    local result = OrphanCleanup.scan({
        present_book_hashes = function() return present end,
        syncery_jsons = function() return entries end,
        json_book_hash = function(e) return OrphanAdapters.json_book_hash(deps, e) end,
        json_book_name_present = function(e) return OrphanAdapters.json_book_name_present(deps, e) end,
    })

    -- doc: hash OLDHASH_doc not in present (present has CURRENT_doc), but doc_path
    -- exists → kept via name. synceryhash: OLDHASH_sh not in present, no fallback → orphan.
    local kept_doc, orphan_sh = false, false
    for _, p in ipairs(result.kept) do if p == doc_json then kept_doc = true end end
    for _, p in ipairs(result.orphans) do if p == sh_json then orphan_sh = true end end
    h.assert_true(kept_doc, "e2e: doc content-mod KEPT via real name resolver")
    h.assert_true(orphan_sh, "e2e: synceryhash content-mod ORPHANED via real path resolver")
end

-- ==========================================================================
-- display_name — book label per klass (for confirm-with-names)
-- ==========================================================================
do
    h.assert_equal(
        OrphanAdapters.display_name({ path = "/x/Book One.epub.sdr/Book One.epub.syncery-progress.json", klass = "doc" }),
        "Book One.epub", "display: doc → book filename")
    h.assert_equal(
        OrphanAdapters.display_name({ path = "/d/docsettings/p/Novel.pdf.sdr/Novel.pdf.syncery-annotations.json", klass = "dir" }),
        "Novel.pdf", "display: dir → book filename")
    h.assert_equal(
        OrphanAdapters.display_name({ path = "/h/hashdocsettings/ab/abcd.sdr/Tome.epub.syncery-progress.json", klass = "hashdocsettings" }),
        "Tome.epub", "display: hashdocsettings → book filename (has prefix)")
    h.assert_equal(
        OrphanAdapters.display_name({ path = "/s/synceryhash/ab/abcdef1234567890/syncery-progress.json", klass = "synceryhash" }),
        "Book abcdef1234", "display: synceryhash → 'Book <short-hash>' (no name available)")
    h.assert_equal(OrphanAdapters.display_name(nil), "?", "display: nil entry → '?'")
end

h.teardown()
print("orphan_adapters_resolve_spec: all assertions passed")
