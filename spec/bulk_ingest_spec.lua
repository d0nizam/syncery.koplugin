-- =============================================================================
-- spec/bulk_ingest_spec.lua
-- =============================================================================
--
-- Phase 14.3a — the bulk annotation-ingest scanner core
-- (syncery_ann/bulk_ingest.lua):
--   * book_path_from_sdr  — pure sidecar -> book path reconstruction
--   * find_sdr_books      — the real disk walk, against a temp .sdr tree
--   * run                 — the dependency-injected ingest loop, with fakes
--
-- The walk uses the REAL luafilesystem over a temp directory; `run` is driven
-- with fake deps so every outcome (existing / empty / ingested / error) is
-- exercised without touching KOReader.
-- =============================================================================


local h   = require("spec.test_helpers")
local lfs = require("lfs")

package.loaded["syncery_ann/bulk_ingest"] = nil
local BulkIngest = require("syncery_ann/bulk_ingest")


-- --- book_path_from_sdr (pure) -----------------------------------------------
do
    h.assert_equal(BulkIngest.book_path_from_sdr("/b/Moby Dick.sdr", "metadata.epub.lua"),
        "/b/Moby Dick.epub", "reconstruct: epub sidecar -> book")
    h.assert_equal(BulkIngest.book_path_from_sdr("/b/Scan.sdr", "metadata.pdf.lua"),
        "/b/Scan.pdf", "reconstruct: pdf sidecar -> book")
    h.assert_nil(BulkIngest.book_path_from_sdr("/b/NotASidecar", "metadata.epub.lua"),
        "reconstruct: non-.sdr dir -> nil")
    h.assert_nil(BulkIngest.book_path_from_sdr("/b/Book.sdr", "history.lua"),
        "reconstruct: non-metadata file -> nil")
    h.assert_nil(BulkIngest.book_path_from_sdr("/b/Book.sdr", "metadata.lua"),
        "reconstruct: metadata.lua without an extension segment -> nil")
end


-- --- find_sdr_books (real disk walk) -----------------------------------------
do
    local root = "/tmp/syncery_bulk_ingest_spec_" .. tostring(os.time()) .. "_" .. tostring(math.random(1e6))
    os.execute("rm -rf '" .. root .. "'")
    os.execute("mkdir -p '" .. root .. "/Book1.sdr' 2>/dev/null")
    os.execute("touch '" .. root .. "/Book1.sdr/metadata.epub.lua'")
    os.execute("touch '" .. root .. "/Book1.epub'")            -- the real book exists
    os.execute("mkdir -p '" .. root .. "/sub/Book2.sdr' 2>/dev/null")
    os.execute("touch '" .. root .. "/sub/Book2.sdr/metadata.pdf.lua'")
    os.execute("touch '" .. root .. "/sub/Book2.pdf'")         -- the real book exists
    os.execute("mkdir -p '" .. root .. "/deep/a/b/Book3.sdr' 2>/dev/null")
    os.execute("touch '" .. root .. "/deep/a/b/Book3.sdr/metadata.fb2.lua'")
    os.execute("touch '" .. root .. "/deep/a/b/Book3.fb2'")    -- the real book exists
    os.execute("mkdir -p '" .. root .. "/Empty.sdr' 2>/dev/null")          -- no metadata -> skipped
    -- A sidecar whose real book is MISSING: mimics KOReader's hash-metadata
    -- tree (hash-named .sdr) or a stale sidecar. Decision 2a: must be SKIPPED,
    -- never ingested (otherwise we'd write a duplicate/orphan sidecar there).
    os.execute("mkdir -p '" .. root .. "/Ghost.sdr' 2>/dev/null")
    os.execute("touch '" .. root .. "/Ghost.sdr/metadata.epub.lua'")
    -- (no Ghost.epub created)
    os.execute("touch '" .. root .. "/loose.txt'")             -- not a sidecar

    local books = BulkIngest.find_sdr_books({ root }, lfs)

    local set = {}
    for _, b in ipairs(books) do set[b] = true end
    h.assert_equal(#books, 3, "find_sdr_books: exactly the three books that exist on disk")
    h.assert_true(set[root .. "/Book1.epub"] ~= nil, "find_sdr_books: top-level epub found")
    h.assert_true(set[root .. "/sub/Book2.pdf"] ~= nil, "find_sdr_books: nested pdf found")
    h.assert_true(set[root .. "/deep/a/b/Book3.fb2"] ~= nil, "find_sdr_books: deep fb2 found")
    h.assert_nil(set[root .. "/Empty.epub"], "find_sdr_books: .sdr without metadata is skipped")
    h.assert_nil(set[root .. "/Ghost.epub"], "find_sdr_books: .sdr whose book is missing is skipped (2a)")

    -- A non-existent root must not crash.
    local none = BulkIngest.find_sdr_books({ root .. "/does-not-exist" }, lfs)
    h.assert_equal(#none, 0, "find_sdr_books: missing root yields nothing, no crash")

    os.execute("rm -rf '" .. root .. "'")
end
-- --- find_books_in_metadata_dir (the "dir" metadata location) ----------------
do
    local base = "/tmp/syncery_bulk_dirloc_" .. tostring(os.time()) .. "_" .. tostring(math.random(1e6))
    local books_root = base .. "/library"          -- where the REAL books live
    local docsettings = base .. "/docsettings"      -- fake DOCSETTINGS_DIR (central tree)
    os.execute("rm -rf '" .. base .. "'")

    -- Two real books on disk.
    os.execute("mkdir -p '" .. books_root .. "' 2>/dev/null")
    os.execute("touch '" .. books_root .. "/Alpha.epub'")
    os.execute("touch '" .. books_root .. "/Beta.pdf'")
    -- A third sidecar whose real book is MISSING (stale) -> must be skipped (2a).
    -- (no Gamma.epub created)

    -- Mirror the books' absolute paths under the central docsettings tree,
    -- exactly as KOReader's "dir" mode does: <DOCSETTINGS_DIR><abs path>.sdr/
    local function mirror(book_abs, ext)
        local sdr = docsettings .. book_abs:gsub("%." .. ext .. "$", "") .. ".sdr"
        os.execute("mkdir -p '" .. sdr .. "' 2>/dev/null")
        os.execute("touch '" .. sdr .. "/metadata." .. ext .. ".lua'")
    end
    mirror(books_root .. "/Alpha.epub", "epub")
    mirror(books_root .. "/Beta.pdf", "pdf")
    mirror(books_root .. "/Gamma.epub", "epub")   -- stale: no real Gamma.epub

    -- Stub DataStorage so the scanner reads our fake central tree.
    local saved_ds = package.loaded["datastorage"]
    package.loaded["datastorage"] = {
        getDocSettingsDir = function() return docsettings end,
    }

    local found = BulkIngest.find_books_in_metadata_dir(lfs)
    local set = {}
    for _, b in ipairs(found) do set[b] = true end

    h.assert_equal(#found, 2,
        "dir-loc: exactly the two books whose real file exists (stale skipped)")
    h.assert_true(set[books_root .. "/Alpha.epub"] ~= nil,
        "dir-loc: Alpha recovered to its REAL path (prefix stripped)")
    h.assert_true(set[books_root .. "/Beta.pdf"] ~= nil,
        "dir-loc: Beta recovered to its real path")
    h.assert_nil(set[books_root .. "/Gamma.epub"],
        "dir-loc: stale sidecar (real book missing) is skipped — 2a")

    -- Shared `seen`: a book already seen is not returned again (cross-walk dedup).
    local seen = { [books_root .. "/Alpha.epub"] = true }
    local found2 = BulkIngest.find_books_in_metadata_dir(lfs, seen)
    local set2 = {}
    for _, b in ipairs(found2) do set2[b] = true end
    h.assert_nil(set2[books_root .. "/Alpha.epub"],
        "dir-loc: respects shared seen (Alpha already counted -> skipped)")
    h.assert_true(set2[books_root .. "/Beta.pdf"] ~= nil,
        "dir-loc: still returns the not-yet-seen Beta")

    -- No DataStorage / no getDocSettingsDir -> empty, no crash.
    package.loaded["datastorage"] = nil
    local none = BulkIngest.find_books_in_metadata_dir(lfs)
    h.assert_equal(#none, 0, "dir-loc: missing DataStorage yields nothing, no crash")

    package.loaded["datastorage"] = saved_ds
    os.execute("rm -rf '" .. base .. "'")
end


-- --- run (dependency-injected) -----------------------------------------------
do
    -- Books: b_exist (already ingested), b_empty (no annotations),
    -- b_full (has annotations), b_err (open fails).
    local writes = {}
    local got_ui = {}
    local stamped = {}
    local progress = {}
    local deps = {
        find_books = function() return { "b_exist", "b_empty", "b_full", "b_err" } end,
        already_ingested = function(p) return p == "b_exist" end,
        open_ui = function(p)
            if p == "b_err" then return nil end
            return { __book = p }
        end,
        read_map = function(ui)
            if ui.__book == "b_empty" then return {} end
            if ui.__book == "b_full" then return { ["K|1"] = { page = 1 } } end
            return {}
        end,
        stamp = function(map) stamped[#stamped + 1] = map; map.__stamped = true; return map end,
        write_initial = function(path, map, ui) writes[path] = map; got_ui[path] = ui; return true end,
        on_progress = function(i, total, outcome, path)
            progress[#progress + 1] = { i = i, total = total, outcome = outcome, path = path }
        end,
    }

    local summary = BulkIngest.run(deps)

    h.assert_equal(summary.total, 4, "run: total counts every book")
    h.assert_equal(summary.skipped_existing, 1, "run: one already-ingested book skipped")
    h.assert_equal(summary.skipped_empty, 1, "run: one annotation-free book skipped")
    h.assert_equal(summary.ingested, 1, "run: one book ingested")
    h.assert_equal(summary.errors, 1, "run: one open failure counted as error")

    h.assert_true(writes["b_full"] ~= nil, "run: the book with annotations was written")
    h.assert_true(writes["b_full"].__stamped == true, "run: written map was stamped first")
    h.assert_true(got_ui["b_full"] ~= nil and got_ui["b_full"].__book == "b_full",
        "run: write_initial receives the opened ui (so it can capture metadata + render)")
    h.assert_nil(writes["b_exist"], "run: existing book not rewritten")
    h.assert_nil(writes["b_empty"], "run: empty book not written")
    h.assert_equal(#stamped, 1, "run: stamping only happens for non-empty maps")

    h.assert_equal(#progress, 4, "run: progress reported once per book")
    h.assert_equal(progress[1].outcome, "skipped_existing", "run: outcome order — existing first")
    h.assert_equal(progress[3].outcome, "ingested", "run: outcome order — full ingested")
    h.assert_equal(progress[4].outcome, "error", "run: outcome order — error last")
    h.assert_equal(progress[4].total, 4, "run: progress carries the total")
end


-- write_initial failure is counted as an error, not ingested.
do
    local deps = {
        find_books = function() return { "b" } end,
        already_ingested = function() return false end,
        open_ui = function() return { __book = "b" } end,
        read_map = function() return { ["K|1"] = {} } end,
        write_initial = function() return false end,   -- write fails
    }
    local summary = BulkIngest.run(deps)
    h.assert_equal(summary.errors, 1, "run: a failed write counts as an error")
    h.assert_equal(summary.ingested, 0, "run: a failed write is not an ingest")
end


-- ---------------------------------------------------------------------------
-- REGRESSION GATE — the main.lua wiring for "Scan all books for annotations"
--
-- Reads main.lua and asserts the picker is a LAST RESORT, not a first-line
-- prompt: _bulkIngestAnnotations must merge history-derived roots and call
-- _runBulkIngest unconditionally (so the fixed dir/hash trees are always
-- scanned even with no roots), and _runBulkIngest must gate the picker on an
-- empty result.  Fails if anyone reverts to "no roots → picker first" (which
-- skipped the dir/hash trees a "dir"/"hash" user relies on).
-- ---------------------------------------------------------------------------
do
    local function read_main()
        for _, p in ipairs({ "main.lua", "./main.lua", "../main.lua" }) do
            local f = io.open(p, "r")
            if f then local c = f:read("*a"); f:close(); return c end
        end
        return nil
    end
    local function body_of(src, header)
        local s = src:find(header, 1, true)
        if not s then return nil end
        return src:sub(s):match("^(.-\n)end\n")
    end

    local src = read_main()
    h.assert_true(src ~= nil, "bulk gate: main.lua readable")

    if src then
        local ann_body = body_of(src, "function Syncery:_bulkIngestAnnotations()")
        h.assert_true(ann_body ~= nil, "bulk gate: found _bulkIngestAnnotations body")
        h.assert_true(ann_body and ann_body:find("deriveRootsFromHistory", 1, true) ~= nil,
            "bulk gate: _bulkIngestAnnotations merges history-derived roots")
        -- It must NOT early-prompt the picker before running the scan.
        h.assert_true(ann_body and ann_body:find("promptForScanRoot", 1, true) == nil,
            "bulk gate: _bulkIngestAnnotations does NOT prompt the picker first (no early-return picker)")
        h.assert_true(ann_body and ann_body:find("_runBulkIngest", 1, true) ~= nil,
            "bulk gate: _bulkIngestAnnotations calls _runBulkIngest")

        local run_body = body_of(src, "function Syncery:_runBulkIngest(roots, offer_picker_if_empty)")
        h.assert_true(run_body ~= nil,
            "bulk gate: _runBulkIngest takes offer_picker_if_empty")
        -- The picker now lives here, gated on an empty result.
        h.assert_true(run_body and run_body:find("summary.total == 0 and offer_picker_if_empty", 1, true) ~= nil,
            "bulk gate: _runBulkIngest offers the picker only as a last resort (empty result + no roots)")
    end
end
