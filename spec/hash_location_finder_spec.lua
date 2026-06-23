-- spec/hash_location_finder_spec.lua
--
-- The consolidated KOReader-hash-location finder (Phase 23.5 / P2).  Two
-- finders over the same `hashdocsettings/` tree:
--   * find_native_books  — native metadata.lua → doc_path → existence-guard,
--     returns book-path strings (for bulk_ingest);
--   * find_synced_books  — Syncery *.syncery-progress.json → book file,
--     returns scanHash-shaped rows (for the booklist).
--
-- Real luafilesystem over temp dirs; DocSettings / DataStorage stubbed.

local h = require("spec.test_helpers")
local lfs = require("lfs")

local Finder = require("syncery_ann/hash_location_finder")


-- ---------------------------------------------------------------------------
-- find_native_books — doc_path read from inside metadata, existence-guarded
-- ---------------------------------------------------------------------------
do
    local base = "/tmp/syncery_hashfind_native_" .. tostring(os.time())
        .. "_" .. tostring(math.random(1e6))
    local books = base .. "/library"
    os.execute("rm -rf '" .. base .. "'")
    os.execute("mkdir -p '" .. books .. "' 2>/dev/null")
    -- Two real books; a third doc_path will be stale (no file on disk).
    os.execute("touch '" .. books .. "/Alpha.epub'")
    os.execute("touch '" .. books .. "/Beta.pdf'")

    -- Stub the enumerator: it returns {metadata_file, custom?} pairs.  The
    -- paths themselves don't need to exist (we inject load_metadata), but we
    -- make them plausible.
    local fake_pairs = {
        { "/hash/al/aaaa.sdr/metadata.epub.lua" },
        { "/hash/be/bbbb.sdr/metadata.pdf.lua" },
        { "/hash/ga/cccc.sdr/metadata.epub.lua" },   -- stale doc_path
        { "/hash/xx/dddd.sdr/metadata.epub.lua" },   -- no doc_path at all
    }
    local doc_paths = {
        ["/hash/al/aaaa.sdr/metadata.epub.lua"] = books .. "/Alpha.epub",
        ["/hash/be/bbbb.sdr/metadata.pdf.lua"]  = books .. "/Beta.pdf",
        ["/hash/ga/cccc.sdr/metadata.epub.lua"] = books .. "/Gamma.epub", -- missing
        -- dddd: no entry → load_metadata returns a table without doc_path
    }

    local deps = {
        docsettings = {
            findSidecarFilesInHashLocation = function() return fake_pairs end,
        },
        load_metadata = function(path)
            local dp = doc_paths[path]
            if dp then return { doc_path = dp } end
            return {}   -- a metadata file with no doc_path
        end,
    }

    local found = Finder.find_native_books(lfs, nil, deps)
    local set = {}
    for _, b in ipairs(found) do set[b] = true end

    h.assert_equal(#found, 2,
        "native: only the two books whose file exists (stale + no-doc_path skipped)")
    h.assert_true(set[books .. "/Alpha.epub"] ~= nil,
        "native: Alpha recovered from its metadata doc_path")
    h.assert_true(set[books .. "/Beta.pdf"] ~= nil,
        "native: Beta recovered from its metadata doc_path")
    h.assert_nil(set[books .. "/Gamma.epub"],
        "native: stale doc_path (book missing) skipped — 2a / lesson #12")

    -- Shared seen: a book already counted elsewhere is not returned again.
    local seen = { [books .. "/Alpha.epub"] = true }
    local found2 = Finder.find_native_books(lfs, seen, deps)
    local set2 = {}
    for _, b in ipairs(found2) do set2[b] = true end
    h.assert_nil(set2[books .. "/Alpha.epub"],
        "native: respects shared seen (Alpha already counted → skipped)")
    h.assert_true(set2[books .. "/Beta.pdf"] ~= nil,
        "native: still returns not-yet-seen Beta")

    -- Missing DocSettings → empty, no crash.
    local none = Finder.find_native_books(lfs, nil, {
        docsettings = {},   -- no findSidecarFilesInHashLocation
    })
    h.assert_equal(#none, 0, "native: missing enumerator yields nothing, no crash")

    os.execute("rm -rf '" .. base .. "'")
end


-- ---------------------------------------------------------------------------
-- find_synced_books — Syncery progress files inside hashdocsettings .sdr dirs
-- ---------------------------------------------------------------------------
do
    local base = "/tmp/syncery_hashfind_synced_" .. tostring(os.time())
        .. "_" .. tostring(math.random(1e6))
    local hashroot = base .. "/hashdocsettings"
    os.execute("rm -rf '" .. base .. "'")

    -- Two sharded .sdr dirs, each with a Syncery progress file carrying the
    -- real book path in its entries.
    local sdr1 = hashroot .. "/59/599fcb.sdr"
    local sdr2 = hashroot .. "/e7/e7ea86.sdr"
    os.execute("mkdir -p '" .. sdr1 .. "' 2>/dev/null")
    os.execute("mkdir -p '" .. sdr2 .. "' 2>/dev/null")
    local f1 = io.open(sdr1 .. "/Nietzsche.syncery-progress.json", "w")
    f1:write('{"schema_version":1,"entries":{"dev1":{"file":"/mnt/us/Books/Nietzsche.pdf","percent":0.3}}}')
    f1:close()
    local f2 = io.open(sdr2 .. "/WarPeace.syncery-progress.json", "w")
    f2:write('{"schema_version":1,"entries":{"dev1":{"file":"/mnt/us/Books/War and Peace.epub","percent":0.1}}}')
    f2:close()

    -- Stub DataStorage so the finder's hash_root() points at our tree.
    local saved_ds = package.loaded["datastorage"]
    package.loaded["datastorage"] = {
        getDocSettingsHashDir = function() return hashroot end,
    }

    local rows = Finder.find_synced_books(nil, {
        lfs       = lfs,
        load_json = function(path)
            local fh = io.open(path, "r"); if not fh then return nil end
            local s = fh:read("*a"); fh:close()
            return require("rapidjson").decode(s)
        end,
        normalize = require("syncery_progress/state_store").normalize,
    })

    local byfile = {}
    for _, r in ipairs(rows) do byfile[r.file or ""] = r end

    h.assert_equal(#rows, 2,
        "synced: both Syncery progress files in hashdocsettings are found")
    h.assert_true(byfile["/mnt/us/Books/Nietzsche.pdf"] ~= nil,
        "synced: Nietzsche book file read from progress entries")
    h.assert_equal(byfile["/mnt/us/Books/Nietzsche.pdf"].mode, "sdr",
        "synced: row is tagged mode=sdr (hashdocsettings = SDR storage in KOReader-hash)")
    h.assert_equal(byfile["/mnt/us/Books/War and Peace.epub"].display_name,
        "War and Peace",
        "synced: display name derived from book basename (ext stripped)")
    h.assert_true(byfile["/mnt/us/Books/Nietzsche.pdf"].progress_path:find("syncery%-progress") ~= nil,
        "synced: progress_path points at the Syncery file")

    -- De-dup: a book already in `seen` is not emitted again.
    local rows2 = Finder.find_synced_books(
        { ["/mnt/us/Books/Nietzsche.pdf"] = true }, {
            lfs       = lfs,
            load_json = function(path)
                local fh = io.open(path, "r"); if not fh then return nil end
                local s = fh:read("*a"); fh:close()
                return require("rapidjson").decode(s)
            end,
            normalize = require("syncery_progress/state_store").normalize,
        })
    local seen_nietzsche = false
    for _, r in ipairs(rows2) do
        if r.file == "/mnt/us/Books/Nietzsche.pdf" then seen_nietzsche = true end
    end
    h.assert_false(seen_nietzsche,
        "synced: respects shared seen (Nietzsche already listed → skipped)")

    package.loaded["datastorage"] = saved_ds
    os.execute("rm -rf '" .. base .. "'")
end


-- Missing hash root → empty, no crash.
do
    local saved_ds = package.loaded["datastorage"]
    package.loaded["datastorage"] = { getDocSettingsHashDir = function() return nil end }
    local rows = Finder.find_synced_books(nil, { lfs = lfs })
    h.assert_equal(#rows, 0, "synced: no hash root → empty, no crash")
    package.loaded["datastorage"] = saved_ds
end


-- ---------------------------------------------------------------------------
-- find_synced_books — annotations-only books in hashdocsettings (progress OFF).
--
-- A content-hash .sdr encodes no path, so the book path comes from the KOReader
-- native metadata.<ext>.lua's `doc_path` that sits in the SAME .sdr (Phase 2a).
-- Existence-gated; progress takes priority when both files are present; a .sdr
-- with no native metadata has no path source and is not surfaced.
-- ---------------------------------------------------------------------------
do
    local base = "/tmp/syncery_hashfind_annonly_" .. tostring(os.time())
        .. "_" .. tostring(math.random(1e6))
    local hashroot = base .. "/hashdocsettings"
    local books    = base .. "/books"
    os.execute("rm -rf '" .. base .. "'")
    os.execute("mkdir -p '" .. books .. "' 2>/dev/null")

    -- Book A — ANNOTATIONS-ONLY, present: native metadata carries doc_path, real
    -- book on disk, Syncery annotations file, NO progress file → surfaced.
    local a_file = books .. "/Idiot.epub"
    do local fh = io.open(a_file, "w"); fh:write("epub"); fh:close() end
    local sdr_a = hashroot .. "/aa/aaaaaa.sdr"
    os.execute("mkdir -p '" .. sdr_a .. "' 2>/dev/null")
    do local fh = io.open(sdr_a .. "/metadata.epub.lua", "w")
       fh:write('return { ["doc_path"] = "' .. a_file .. '" }'); fh:close() end
    do local fh = io.open(sdr_a .. "/Idiot.epub.syncery-annotations.json", "w")
       fh:write('{"schema_version":1,"annotations":{}}'); fh:close() end

    -- Book B — BOTH files: progress takes priority → emitted via progress.
    local b_file = books .. "/Both.epub"
    do local fh = io.open(b_file, "w"); fh:write("epub"); fh:close() end
    local sdr_b = hashroot .. "/bb/bbbbbb.sdr"
    os.execute("mkdir -p '" .. sdr_b .. "' 2>/dev/null")
    do local fh = io.open(sdr_b .. "/metadata.epub.lua", "w")
       fh:write('return { ["doc_path"] = "' .. b_file .. '" }'); fh:close() end
    do local fh = io.open(sdr_b .. "/Both.epub.syncery-progress.json", "w")
       fh:write('{"schema_version":1,"entries":{"dev1":{"file":"' .. b_file .. '","percent":0.2}}}'); fh:close() end
    do local fh = io.open(sdr_b .. "/Both.epub.syncery-annotations.json", "w")
       fh:write('{"schema_version":1,"annotations":{}}'); fh:close() end

    -- Book C — OPENED-THEN-MOVED: native metadata EXISTS (the book was opened
    -- here) but its doc_path no longer resolves on disk (the book file was since
    -- moved/deleted).  Now surfaced PATHLESS (notes still readable) instead of
    -- dropped.
    local sdr_c = hashroot .. "/cc/cccccc.sdr"
    os.execute("mkdir -p '" .. sdr_c .. "' 2>/dev/null")
    do local fh = io.open(sdr_c .. "/metadata.epub.lua", "w")
       fh:write('return { ["doc_path"] = "' .. books .. '/Gone.epub" }'); fh:close() end
    do local fh = io.open(sdr_c .. "/Gone.epub.syncery-annotations.json", "w")
       fh:write('{"schema_version":1,"annotations":{}}'); fh:close() end

    -- Book D — ANNOTATIONS-ONLY, NO native metadata (book not opened on this
    -- device): no doc_path source → surfaced PATHLESS (notes readable via
    -- annotations_path; path self-heals on first open via Phase 2a).
    local sdr_d = hashroot .. "/dd/dddddd.sdr"
    os.execute("mkdir -p '" .. sdr_d .. "' 2>/dev/null")
    do local fh = io.open(sdr_d .. "/Nometa.epub.syncery-annotations.json", "w")
       fh:write('{"schema_version":1,"annotations":{}}'); fh:close() end

    -- Book E — ANNOTATIONS-ONLY, NO native metadata, EXTENSIONLESS DOTTED name:
    -- the prefixed filename "Dr. No.syncery-annotations.json" (book file has no
    -- recognized extension) must strip ONLY a recognized extension -> the name
    -- stays "Dr. No".  A naive `gsub("%.[^.]+$","")` would over-strip to "Dr"
    -- (it removes the last dot-segment unconditionally); strip_book_extension
    -- removes it only when it is a known book extension.  (A book WITH an
    -- extension, e.g. "Dr. No.epub", does not distinguish the two -- both strip
    -- only ".epub" -- so the binding fixture must be extensionless.)
    local sdr_e = hashroot .. "/ee/eeeeee.sdr"
    os.execute("mkdir -p '" .. sdr_e .. "' 2>/dev/null")
    do local fh = io.open(sdr_e .. "/Dr. No.syncery-annotations.json", "w")
       fh:write('{"schema_version":1,"annotations":{}}'); fh:close() end

    local saved_ds = package.loaded["datastorage"]
    package.loaded["datastorage"] = {
        getDocSettingsHashDir = function() return hashroot end,
    }
    local function loader(path)
        local fh = io.open(path, "r"); if not fh then return nil end
        local s = fh:read("*a"); fh:close()
        return require("rapidjson").decode(s)
    end

    local rows = Finder.find_synced_books(nil, {
        lfs = lfs, load_json = loader,
        normalize = require("syncery_progress/state_store").normalize,
    })
    local byfile = {}
    for _, r in ipairs(rows) do byfile[r.file or ""] = r end

    h.assert_true(byfile[a_file] ~= nil,
        "hash annonly: an annotations-only book is surfaced via native metadata doc_path")
    h.assert_equal((byfile[a_file] or {}).progress_path, nil,
        "hash annonly: its row has no progress_path")
    h.assert_true((byfile[a_file] or {}).annotations_path ~= nil,
        "hash annonly: its row carries the annotations path")
    h.assert_true(byfile[b_file] ~= nil,
        "hash annonly: a both-files book is surfaced once via progress priority")
    h.assert_true((byfile[b_file] or {}).progress_path ~= nil,
        "hash annonly: the both-files row is the PROGRESS row, not annotations-only")
    local gone_row = nil
    for _, r in ipairs(rows) do
        if (r.annotations_path or ""):find("Gone") then gone_row = r end
    end
    h.assert_true(gone_row ~= nil,
        "hash annonly: an opened-then-moved book (stale absent doc_path) is surfaced PATHLESS, not dropped")
    h.assert_equal(gone_row and gone_row.file, nil,
        "hash annonly: the stale-absent row is pathless (file=nil)")
    h.assert_equal(gone_row and gone_row.display_name, "Gone",
        "hash annonly: stale-absent pathless row names the book from the prefixed annotations filename")
    -- Book D is now surfaced PATHLESS: with no native metadata there is no
    -- doc_path, but the notes are still readable via annotations_path, so the
    -- hash finder emits it with file=nil and a name recovered from the prefixed
    -- annotations filename.  (The path self-heals on first open -- Phase 2a then
    -- reads the freshly written doc_path.)
    local d_row = nil
    for _, r in ipairs(rows) do
        if (r.annotations_path or ""):find("Nometa") then d_row = r end
    end
    h.assert_true(d_row ~= nil,
        "hash annonly: an annotations-only .sdr with NO native metadata is surfaced PATHLESS")
    h.assert_equal(d_row and d_row.file, nil,
        "hash annonly: the not-opened (no native metadata) row is pathless (file=nil)")
    h.assert_equal(d_row and d_row.display_name, "Nometa",
        "hash annonly: pathless row names the book from the prefixed annotations filename")

    local e_row = nil
    for _, r in ipairs(rows) do
        if (r.annotations_path or ""):find("Dr%. No") then e_row = r end
    end
    h.assert_true(e_row ~= nil,
        "hash annonly: an extensionless dotted-name pathless book is surfaced")
    h.assert_equal(e_row and e_row.display_name, "Dr. No",
        "hash annonly: extensionless dotted name keeps \"Dr. No\" (recognized-extension strip, not naive last-dot-segment removal which gives \"Dr\")")

    package.loaded["datastorage"] = saved_ds
    os.execute("rm -rf '" .. base .. "'")
end


-- ---------------------------------------------------------------------------
-- find_synced_books_in_dir — Syncery progress files inside the DEEP
-- docsettings/<full/book/path>.sdr/ tree (KOReader metadata location "dir")
-- ---------------------------------------------------------------------------
do
    local base = "/tmp/syncery_dirfind_synced_" .. tostring(os.time())
        .. "_" .. tostring(math.random(1e6))
    local dirroot = base .. "/docsettings"
    os.execute("rm -rf '" .. base .. "'")

    -- The dir tree mirrors the book's full path under docsettings/, so the
    -- .sdr is DEEPLY nested — the finder must recurse, not assume two levels.
    local sdr1 = dirroot .. "/mnt/us/Books/Nietzsche.sdr"
    local sdr2 = dirroot .. "/mnt/us/More/Deep/Nested/WarPeace.sdr"
    os.execute("mkdir -p '" .. sdr1 .. "' 2>/dev/null")
    os.execute("mkdir -p '" .. sdr2 .. "' 2>/dev/null")
    local f1 = io.open(sdr1 .. "/Nietzsche.syncery-progress.json", "w")
    f1:write('{"schema_version":1,"entries":{"dev1":{"file":"/mnt/us/Books/Nietzsche.pdf","percent":0.3}}}')
    f1:close()
    local f2 = io.open(sdr2 .. "/WarPeace.syncery-progress.json", "w")
    f2:write('{"schema_version":1,"entries":{"dev1":{"file":"/mnt/us/More/War and Peace.epub","percent":0.1}}}')
    f2:close()

    local saved_ds = package.loaded["datastorage"]
    package.loaded["datastorage"] = {
        getDocSettingsDir = function() return dirroot end,
    }

    local function loader(path)
        local fh = io.open(path, "r"); if not fh then return nil end
        local s = fh:read("*a"); fh:close()
        return require("rapidjson").decode(s)
    end

    local rows = Finder.find_synced_books_in_dir(nil, {
        lfs = lfs, load_json = loader,
        normalize = require("syncery_progress/state_store").normalize,
    })
    local byfile = {}
    for _, r in ipairs(rows) do byfile[r.file or ""] = r end

    h.assert_equal(#rows, 2,
        "dir: both Syncery progress files in the deep docsettings tree are found")
    h.assert_true(byfile["/mnt/us/Books/Nietzsche.pdf"] ~= nil,
        "dir: Nietzsche book file read from a deeply-nested .sdr")
    h.assert_true(byfile["/mnt/us/More/War and Peace.epub"] ~= nil,
        "dir: deeply-nested WarPeace found (recursion works, not just 2 levels)")
    h.assert_equal(byfile["/mnt/us/Books/Nietzsche.pdf"].mode, "sdr",
        "dir: row tagged mode=sdr (docsettings = SDR storage in KOReader-dir)")
    h.assert_equal(byfile["/mnt/us/More/War and Peace.epub"].display_name,
        "War and Peace", "dir: display name from basename, ext stripped")

    -- De-dup via shared seen (cross-tree: a book already found in hash is not
    -- re-emitted from dir).
    local rows2 = Finder.find_synced_books_in_dir(
        { ["/mnt/us/Books/Nietzsche.pdf"] = true },
        { lfs = lfs, load_json = loader,
          normalize = require("syncery_progress/state_store").normalize })
    local saw_n = false
    for _, r in ipairs(rows2) do
        if r.file == "/mnt/us/Books/Nietzsche.pdf" then saw_n = true end
    end
    h.assert_false(saw_n,
        "dir: respects shared seen (Nietzsche already listed → skipped)")

    package.loaded["datastorage"] = saved_ds
    os.execute("rm -rf '" .. base .. "'")
end


-- Missing dir root → empty, no crash.
do
    local saved_ds = package.loaded["datastorage"]
    package.loaded["datastorage"] = { getDocSettingsDir = function() return nil end }
    local rows = Finder.find_synced_books_in_dir(nil, { lfs = lfs })
    h.assert_equal(#rows, 0, "dir: no docsettings root → empty, no crash")
    package.loaded["datastorage"] = saved_ds
end


-- ---------------------------------------------------------------------------
-- find_synced_books_in_dir — .sdr-LOCATION reconstruction fallback.
--
-- A book read only on ANOTHER device records that device's paths in its
-- progress entries; none resolve here.  But the docsettings .sdr LOCATION
-- encodes the book's real local path, and the book may be present locally.
-- The dir finder recovers that path (docsettings-root-stripped) -- but ONLY
-- when the reconstructed file actually exists, so a genuinely-absent book
-- still shows the foreign path (migration's safety net then skips it).
-- ---------------------------------------------------------------------------
do
    local base = "/tmp/syncery_dirfind_recon_" .. tostring(os.time())
        .. "_" .. tostring(math.random(1e6))
    local dirroot   = base .. "/docsettings"
    local realbooks = base .. "/realbooks"
    os.execute("rm -rf '" .. base .. "'")
    os.execute("mkdir -p '" .. realbooks .. "' 2>/dev/null")

    -- Book PRESENT locally: create the real file, and put its .sdr at the
    -- docsettings mirror of that absolute path.  Progress records ONLY a
    -- foreign path (this device never opened it, so it has no own entry).
    local present_file = realbooks .. "/Present.epub"
    local fp = io.open(present_file, "w"); fp:write("epub"); fp:close()
    local sdr_present = dirroot .. realbooks .. "/Present.sdr"
    os.execute("mkdir -p '" .. sdr_present .. "' 2>/dev/null")
    local f1 = io.open(sdr_present .. "/Present.epub.syncery-progress.json", "w")
    f1:write('{"schema_version":1,"entries":{"kindle":{"file":"/mnt/us/Foreign/Present.epub","percent":0.4}}}')
    f1:close()

    -- Book ABSENT locally: no real file.  Same shape; the reconstructed path
    -- points at a non-existent local file and must NOT be used.
    local sdr_missing = dirroot .. realbooks .. "/Missing.sdr"
    os.execute("mkdir -p '" .. sdr_missing .. "' 2>/dev/null")
    local f2 = io.open(sdr_missing .. "/Missing.epub.syncery-progress.json", "w")
    f2:write('{"schema_version":1,"entries":{"kindle":{"file":"/mnt/us/Foreign/Missing.epub","percent":0.2}}}')
    f2:close()

    local saved_ds = package.loaded["datastorage"]
    package.loaded["datastorage"] = {
        getDocSettingsDir = function() return dirroot end,
    }
    local function loader(path)
        local fh = io.open(path, "r"); if not fh then return nil end
        local s = fh:read("*a"); fh:close()
        return require("rapidjson").decode(s)
    end

    local rows = Finder.find_synced_books_in_dir(nil, {
        lfs = lfs, load_json = loader,
        normalize = require("syncery_progress/state_store").normalize,
    })
    local byfile = {}
    for _, r in ipairs(rows) do byfile[r.file or ""] = r end

    h.assert_equal(#rows, 2, "recon: both books found")
    h.assert_true(byfile[present_file] ~= nil,
        "recon: present book resolves to its REAL local path via the .sdr location")
    h.assert_true(byfile["/mnt/us/Foreign/Present.epub"] == nil,
        "recon: the foreign path is NOT used when the local file exists")
    h.assert_true(byfile["/mnt/us/Foreign/Missing.epub"] ~= nil,
        "recon: absent book falls through to the foreign path (existence-gated)")
    h.assert_true(byfile[realbooks .. "/Missing.epub"] == nil,
        "recon: a non-existent reconstructed path is never fabricated")

    package.loaded["datastorage"] = saved_ds
    os.execute("rm -rf '" .. base .. "'")
end


-- ---------------------------------------------------------------------------
-- find_synced_books_in_dir — annotations-only books (progress sync OFF).
--
-- A book with progress sync off has only *.syncery-annotations.json (no
-- progress file).  The dir finder must still surface it, sourcing the path
-- from the .sdr LOCATION.  Progress takes priority when both exist.  Phase 1
-- emits only when the reconstructed path resolves on disk.
-- ---------------------------------------------------------------------------
do
    local base = "/tmp/syncery_dirfind_annonly_" .. tostring(os.time())
        .. "_" .. tostring(math.random(1e6))
    local dirroot   = base .. "/docsettings"
    local realbooks = base .. "/realbooks"
    os.execute("rm -rf '" .. base .. "'")
    os.execute("mkdir -p '" .. realbooks .. "' 2>/dev/null")

    -- Book A — ANNOTATIONS-ONLY, present locally: only the annotations file,
    -- real book file on disk.  Must be surfaced (path reconstructed).
    local a_file = realbooks .. "/AnnOnly.epub"
    local fa = io.open(a_file, "w"); fa:write("epub"); fa:close()
    local sdr_a = dirroot .. realbooks .. "/AnnOnly.sdr"
    os.execute("mkdir -p '" .. sdr_a .. "' 2>/dev/null")
    local f1 = io.open(sdr_a .. "/AnnOnly.epub.syncery-annotations.json", "w")
    f1:write('{"schema_version":1,"annotations":{}}'); f1:close()

    -- Book B — BOTH files, present: progress takes priority -> one row, sourced
    -- from progress (its foreign entry falls back to the .sdr reconstruction).
    local b_file = realbooks .. "/Both.epub"
    local fb = io.open(b_file, "w"); fb:write("epub"); fb:close()
    local sdr_b = dirroot .. realbooks .. "/Both.sdr"
    os.execute("mkdir -p '" .. sdr_b .. "' 2>/dev/null")
    local f2 = io.open(sdr_b .. "/Both.epub.syncery-progress.json", "w")
    f2:write('{"schema_version":1,"entries":{"kindle":{"file":"/mnt/us/Foreign/Both.epub"}}}'); f2:close()
    local f2a = io.open(sdr_b .. "/Both.epub.syncery-annotations.json", "w")
    f2a:write('{"schema_version":1,"annotations":{}}'); f2a:close()

    -- Book C — ANNOTATIONS-ONLY, ABSENT: only the annotations file, no real
    -- book file.  Reconstruction does not resolve -> must NOT be surfaced.
    local sdr_c = dirroot .. realbooks .. "/Absent.sdr"
    os.execute("mkdir -p '" .. sdr_c .. "' 2>/dev/null")
    local f3 = io.open(sdr_c .. "/Absent.epub.syncery-annotations.json", "w")
    f3:write('{"schema_version":1,"annotations":{}}'); f3:close()

    local saved_ds = package.loaded["datastorage"]
    package.loaded["datastorage"] = {
        getDocSettingsDir = function() return dirroot end,
    }
    local function loader(path)
        local fh = io.open(path, "r"); if not fh then return nil end
        local s = fh:read("*a"); fh:close()
        return require("rapidjson").decode(s)
    end

    local rows = Finder.find_synced_books_in_dir(nil, {
        lfs = lfs, load_json = loader,
        normalize = require("syncery_progress/state_store").normalize,
    })
    local byfile = {}
    for _, r in ipairs(rows) do byfile[r.file or ""] = r end

    h.assert_true(byfile[a_file] ~= nil,
        "annonly: an annotations-only book (no progress file) is surfaced")
    h.assert_equal((byfile[a_file] or {}).progress_path, nil,
        "annonly: its row has no progress_path (annotations-only)")
    h.assert_true((byfile[a_file] or {}).annotations_path ~= nil,
        "annonly: its row carries the annotations path")
    h.assert_true(byfile[b_file] ~= nil,
        "annonly: a both-files book is surfaced once via progress priority")
    h.assert_true((byfile[b_file] or {}).progress_path ~= nil,
        "annonly: the both-files row is the PROGRESS row, not annotations-only")
    h.assert_true(byfile[realbooks .. "/Absent.epub"] == nil,
        "annonly: an annotations-only book with NO local file is NOT surfaced (existence-gated)")
    -- Gate: unlike the HASH finder (which surfaces a not-opened book PATHLESS),
    -- the DIR finder must NOT emit a pathless row for an absent book -- its
    -- reconstruct_path is location-based and resolves for present books, so an
    -- absent one is simply dropped, never surfaced with file=nil.
    local absent_pathless = false
    for _, r in ipairs(rows) do
        if (r.annotations_path or ""):find("Absent") then absent_pathless = true end
    end
    h.assert_false(absent_pathless,
        "annonly: the DIR finder never emits a PATHLESS row (no read_doc_path branch) -- absent dir-mode book stays dropped")

    package.loaded["datastorage"] = saved_ds
    os.execute("rm -rf '" .. base .. "'")
end


-- ---------------------------------------------------------------------------
-- DISTINGUISHING TEST — the two finder groups match DIFFERENT files.
--
-- A single .sdr directory can hold BOTH a native KOReader sidecar
-- (`metadata.<ext>.lua`) AND Syncery's own files (`*.syncery-progress.json`).
-- The three library-wide tools must not confuse them:
--   * find_synced_books / find_synced_books_in_dir (migration + "Manage all")
--     → match ONLY `*.syncery-progress.json` (Syncery's files, which migration
--       MOVES), NEVER the native metadata.lua (KOReader's, never touched).
--   * find_sdr_books / find_books_in_metadata_dir / find_native_books
--     (bulk_ingest "Scan for annotations") → match ONLY native
--       `metadata.<ext>.lua` (to READ annotations), NEVER the Syncery JSON.
-- ---------------------------------------------------------------------------
do
    local BulkIngest = require("syncery_ann/bulk_ingest")

    local base = "/tmp/syncery_distinguish_" .. tostring(os.time())
        .. "_" .. tostring(math.random(1e6))
    os.execute("rm -rf '" .. base .. "'")
    -- A real book + a .sdr beside it holding BOTH file types.
    local lib = base .. "/lib"
    local sdr = lib .. "/Nietzsche.sdr"
    os.execute("mkdir -p '" .. sdr .. "' 2>/dev/null")
    os.execute("touch '" .. lib .. "/Nietzsche.epub'")  -- the book must exist (2a guard)
    -- Native KOReader sidecar:
    local nf = io.open(sdr .. "/metadata.epub.lua", "w")
    nf:write('return { doc_path = "' .. lib .. '/Nietzsche.epub", annotations = {} }')
    nf:close()
    -- Syncery's own progress JSON, in the SAME .sdr:
    local sf = io.open(sdr .. "/Nietzsche.syncery-progress.json", "w")
    sf:write('{"schema_version":1,"entries":{"dev1":{"file":"' .. lib .. '/Nietzsche.epub","percent":0.3}}}')
    sf:close()

    local function loader(path)
        local fh = io.open(path, "r"); if not fh then return nil end
        local s = fh:read("*a"); fh:close()
        -- Fail-soft like the real default loader (non-JSON → nil, not a throw).
        local ok, d = pcall(function() return require("rapidjson").decode(s) end)
        return ok and d or nil
    end

    -- GROUP A — find_synced_books_in_dir (dir tree): matches the JSON only.
    local saved_ds = package.loaded["datastorage"]
    package.loaded["datastorage"] = {
        getDocSettingsDir = function() return lib end,  -- treat lib as the dir tree root
    }
    local synced = Finder.find_synced_books_in_dir(nil, {
        lfs = lfs, load_json = loader,
        normalize = require("syncery_progress/state_store").normalize,
    })
    package.loaded["datastorage"] = saved_ds

    h.assert_equal(#synced, 1,
        "distinguish: the synced-books finder returns the ONE book (from its .syncery-progress.json)")
    h.assert_true(synced[1] and synced[1].progress_path
        and synced[1].progress_path:find("syncery%-progress%.json") ~= nil,
        "distinguish: synced finder's progress_path is the Syncery JSON, not metadata.lua")
    h.assert_true(synced[1] and synced[1].progress_path
        and synced[1].progress_path:find("metadata%.epub%.lua") == nil,
        "distinguish: synced finder NEVER returns the native metadata.lua path")

    -- GROUP B — find_sdr_books (doc walk): matches the native metadata.lua only.
    local native = BulkIngest.find_sdr_books({ lib }, lfs)
    h.assert_equal(#native, 1,
        "distinguish: the native finder returns the ONE book (from its metadata.epub.lua)")
    h.assert_equal(native[1], lib .. "/Nietzsche.epub",
        "distinguish: native finder returns the book path reconstructed from the .sdr name (not the JSON)")
    -- find_sdr_books returns book-path strings, so it cannot have matched the
    -- JSON (which carries no .sdr/metadata pairing); the single clean result
    -- with no error IS the proof it ignored the Syncery JSON sitting beside it.

    os.execute("rm -rf '" .. base .. "'")
end


-- A .sdr holding ONLY a native metadata.lua (NO Syncery JSON) — the synced
-- finder must return NOTHING from it.  This is order-independent proof: if the
-- synced finder's pattern were broadened to also match metadata.<ext>.lua, it
-- would wrongly emit a book here (where the correct count is zero), regardless
-- of which file lfs.dir happens to list first.
do
    local base = "/tmp/syncery_distinguish_nativeonly_" .. tostring(os.time())
        .. "_" .. tostring(math.random(1e6))
    os.execute("rm -rf '" .. base .. "'")
    local lib = base .. "/lib"
    local sdr = lib .. "/OnlyNative.sdr"
    os.execute("mkdir -p '" .. sdr .. "' 2>/dev/null")
    os.execute("touch '" .. lib .. "/OnlyNative.epub'")
    local nf = io.open(sdr .. "/metadata.epub.lua", "w")
    nf:write('return { doc_path = "' .. lib .. '/OnlyNative.epub", annotations = {} }')
    nf:close()
    -- Deliberately NO *.syncery-progress.json here.

    local saved_ds = package.loaded["datastorage"]
    package.loaded["datastorage"] = { getDocSettingsDir = function() return lib end }
    local synced = Finder.find_synced_books_in_dir(nil, {
        lfs = lfs,
        load_json = function(path)
            local fh = io.open(path, "r"); if not fh then return nil end
            local s = fh:read("*a"); fh:close()
            -- Fail-soft like the real default loader: a non-JSON file (e.g. a
            -- native metadata.lua wrongly matched) decodes to nil, not a throw,
            -- so the assertion below reflects the finder's RESULT.
            local ok, d = pcall(function() return require("rapidjson").decode(s) end)
            return ok and d or nil
        end,
        normalize = require("syncery_progress/state_store").normalize,
    })
    package.loaded["datastorage"] = saved_ds

    h.assert_equal(#synced, 0,
        "distinguish: synced finder returns ZERO from a .sdr that has ONLY native metadata.lua (no Syncery JSON) — order-independent proof it ignores metadata.lua")

    os.execute("rm -rf '" .. base .. "'")
end


-- The mirror image: a .sdr holding ONLY Syncery's JSON (NO native
-- metadata.lua) — the NATIVE finder (bulk_ingest) must return NOTHING from it.
-- Order-independent proof that find_sdr_books ignores the Syncery JSON.
do
    local BulkIngest = require("syncery_ann/bulk_ingest")
    local base = "/tmp/syncery_distinguish_jsononly_" .. tostring(os.time())
        .. "_" .. tostring(math.random(1e6))
    os.execute("rm -rf '" .. base .. "'")
    local lib = base .. "/lib"
    local sdr = lib .. "/OnlyJson.sdr"
    os.execute("mkdir -p '" .. sdr .. "' 2>/dev/null")
    os.execute("touch '" .. lib .. "/OnlyJson.epub'")
    -- ONLY a Syncery progress JSON; deliberately NO metadata.<ext>.lua.
    local sf = io.open(sdr .. "/OnlyJson.syncery-progress.json", "w")
    sf:write('{"schema_version":1,"entries":{"dev1":{"file":"' .. lib .. '/OnlyJson.epub","percent":0.5}}}')
    sf:close()

    local native = BulkIngest.find_sdr_books({ lib }, lfs)
    h.assert_equal(#native, 0,
        "distinguish: native finder returns ZERO from a .sdr that has ONLY a Syncery JSON (no metadata.lua) — order-independent proof it ignores the Syncery JSON")

    os.execute("rm -rf '" .. base .. "'")
end


-- ---------------------------------------------------------------------------
-- REGRESSION (multi-device, this finder's twin of the 23.13e scanHash bug):
-- the shared SDR processor must read book.file from the entry that exists on
-- THIS device, not an arbitrary pairs() first hit.  The test PROBES which key
-- this build's parse+normalize yields first (the old first-hit pick) and makes
-- THAT the foreign/absent device, so reverting to the first-hit pick strands
-- the present book and the assertion fails -- on any build.
-- ---------------------------------------------------------------------------
do
    local StateStore = require("syncery_progress/state_store")
    local rapidjson  = require("rapidjson")
    local function first_key(json_str)
        local norm = StateStore.normalize(rapidjson.decode(json_str))
        for k in pairs(norm.entries) do return k end
    end

    local base = "/tmp/syncery_hashfind_devsel_" .. tostring(os.time())
        .. "_" .. tostring(math.random(1e6))
    local hashroot = base .. "/hashdocsettings"
    local sdr = hashroot .. "/ab/abc123.sdr"
    os.execute("rm -rf '" .. base .. "'")
    os.execute("mkdir -p '" .. sdr .. "' 2>/dev/null")

    local DEV_A = "dev_aaaaaaaa"
    local DEV_B = "dev_bbbbbbbb"
    local path_a = base .. "/A.epub"
    local path_b = base .. "/B.epub"
    local json = '{"schema_version":1,"entries":{'
        .. '"' .. DEV_A .. '":{"device_id":"' .. DEV_A .. '","file":"' .. path_a .. '","percent":0.3},'
        .. '"' .. DEV_B .. '":{"device_id":"' .. DEV_B .. '","file":"' .. path_b .. '","percent":0.4}}}'
    local pf = io.open(sdr .. "/Multi.syncery-progress.json", "w")
    pf:write(json); pf:close()

    -- Roles from the probe: pairs()-first key is the foreign (absent) device.
    local DEV_FOREIGN = first_key(json)
    local DEV_LOCAL   = (DEV_FOREIGN == DEV_A) and DEV_B or DEV_A
    local local_path  = (DEV_LOCAL == DEV_A) and path_a or path_b
    -- Only the local device's book exists on disk.
    os.execute("touch '" .. local_path .. "'")

    local saved_ds = package.loaded["datastorage"]
    package.loaded["datastorage"] = { getDocSettingsHashDir = function() return hashroot end }

    local rows = Finder.find_synced_books(nil, {
        device_id = DEV_LOCAL,
        lfs       = lfs,
        load_json = function(path)
            local fh = io.open(path, "r"); if not fh then return nil end
            local s = fh:read("*a"); fh:close()
            return rapidjson.decode(s)
        end,
        normalize = StateStore.normalize,
    })

    package.loaded["datastorage"] = saved_ds

    local hit
    for _, r in ipairs(rows) do
        if (r.progress_path or ""):find("Multi%.syncery%-progress") then hit = r end
    end
    h.assert_true(hit ~= nil, "multi-device: the book row is found")
    h.assert_equal(hit.file, local_path,
        "multi-device: book.file is THIS device's path, not the pairs()-first foreign one")
    h.assert_true(lfs.attributes(hit.file, "mode") == "file",
        "multi-device: the chosen book.file resolves on disk (migration will NOT skip it)")

    os.execute("rm -rf '" .. base .. "'")
end


-- ---------------------------------------------------------------------------
-- find_synced_books_in_dir — must NOT recurse into Syncthing's `.stversions`.
-- The dir walk is RECURSIVE, so a realistic mirrored archive
-- (`docsettings/.stversions/<path>/<book>.sdr/<book>.syncery-progress.json`)
-- is reachable; if its recorded book path differs from the live one (renamed
-- since), the book-path de-dup cannot collapse the two and the book appears
-- twice.  The skip must stop the recursion at `.stversions`.
-- ---------------------------------------------------------------------------
do
    local base = "/tmp/syncery_dirfind_stv_" .. tostring(os.time())
        .. "_" .. tostring(math.random(1e6))
    local dirroot = base .. "/docsettings"
    os.execute("rm -rf '" .. base .. "'")
    -- LIVE deeply-nested .sdr.
    local sdr = dirroot .. "/mnt/us/Books/Book.sdr"
    os.execute("mkdir -p '" .. sdr .. "' 2>/dev/null")
    do local f = io.open(sdr .. "/Book.syncery-progress.json", "w")
       f:write('{"schema_version":1,"entries":{"dev1":{"file":"/mnt/us/Books/Live.epub","percent":0.3}}}'); f:close() end
    -- STALE copy under `.stversions`, mirroring the path, recording a DIFFERENT
    -- (pre-rename) book path so a path-keyed de-dup could NOT collapse it.
    local stv = dirroot .. "/.stversions/mnt/us/Books/Book.sdr"
    os.execute("mkdir -p '" .. stv .. "' 2>/dev/null")
    do local f = io.open(stv .. "/Book.syncery-progress.json", "w")
       f:write('{"schema_version":1,"entries":{"dev1":{"file":"/mnt/us/Books/Old.epub","percent":0.3}}}'); f:close() end

    local saved_ds = package.loaded["datastorage"]
    package.loaded["datastorage"] = { getDocSettingsDir = function() return dirroot end }
    local function loader(path)
        local fh = io.open(path, "r"); if not fh then return nil end
        local s = fh:read("*a"); fh:close()
        return require("rapidjson").decode(s)
    end
    local rows = Finder.find_synced_books_in_dir(nil, {
        lfs = lfs, load_json = loader,
        normalize = require("syncery_progress/state_store").normalize })

    h.assert_equal(#rows, 1,
        "dir: skips .stversions recursion -> only the live book is found")
    h.assert_equal((rows[1] or {}).file, "/mnt/us/Books/Live.epub",
        "dir: the row is the LIVE path, not the .stversions stale path")

    package.loaded["datastorage"] = saved_ds
    os.execute("rm -rf '" .. base .. "'")
end


-- ---------------------------------------------------------------------------
-- find_synced_books — the two-level shard walk must skip `.stversions` at the
-- shard level.  (The realistic mirrored archive sits one level deeper than
-- process_sdr's single-level look, so it already misses; this fixture places a
-- `.sdr` DIRECTLY under `.stversions` to exercise the shard-level skip itself —
-- defense-in-depth, so the protection holds regardless of archive depth.)
-- ---------------------------------------------------------------------------
do
    local base = "/tmp/syncery_hashfind_stv_" .. tostring(os.time())
        .. "_" .. tostring(math.random(1e6))
    local hashroot = base .. "/hashdocsettings"
    os.execute("rm -rf '" .. base .. "'")
    -- LIVE sharded .sdr.
    local sdr = hashroot .. "/59/599fcb.sdr"
    os.execute("mkdir -p '" .. sdr .. "' 2>/dev/null")
    do local f = io.open(sdr .. "/Book.syncery-progress.json", "w")
       f:write('{"schema_version":1,"entries":{"dev1":{"file":"/mnt/us/Books/Live.epub","percent":0.3}}}'); f:close() end
    -- A `.sdr` placed directly under `.stversions` (shard-level), recording a
    -- different path; without the shard-skip the descent reads it as a book.
    local stv = hashroot .. "/.stversions/599fcb.sdr"
    os.execute("mkdir -p '" .. stv .. "' 2>/dev/null")
    do local f = io.open(stv .. "/Book.syncery-progress.json", "w")
       f:write('{"schema_version":1,"entries":{"dev1":{"file":"/mnt/us/Books/Old.epub","percent":0.3}}}'); f:close() end

    local saved_ds = package.loaded["datastorage"]
    package.loaded["datastorage"] = { getDocSettingsHashDir = function() return hashroot end }
    local function loader(path)
        local fh = io.open(path, "r"); if not fh then return nil end
        local s = fh:read("*a"); fh:close()
        return require("rapidjson").decode(s)
    end
    local rows = Finder.find_synced_books(nil, {
        lfs = lfs, load_json = loader,
        normalize = require("syncery_progress/state_store").normalize })

    h.assert_equal(#rows, 1,
        "synced: skips .stversions shard -> only the live book is found")
    h.assert_equal((rows[1] or {}).file, "/mnt/us/Books/Live.epub",
        "synced: the row is the LIVE path, not the .stversions stale path")

    package.loaded["datastorage"] = saved_ds
    os.execute("rm -rf '" .. base .. "'")
end


-- ---------------------------------------------------------------------------
-- doc_path_for_hash — recover a synceryhash book's path from KOReader's native
-- metadata at the same-md5 hashdocsettings .sdr (book_id == partialMD5).
-- Shards by the first 2 hex chars, reads doc_path; nil when the .sdr/native
-- metadata is absent or the id is too short to shard.
-- ---------------------------------------------------------------------------
do
    local base = "/tmp/syncery_docpath_for_hash_" .. tostring(os.time())
        .. "_" .. tostring(math.random(1e6))
    local hashroot = base .. "/hashdocsettings"
    os.execute("rm -rf '" .. base .. "'")
    -- Native metadata for book_id "abc123def0" lives at <root>/ab/abc123def0.sdr/.
    local sdr = hashroot .. "/ab/abc123def0.sdr"
    os.execute("mkdir -p '" .. sdr .. "' 2>/dev/null")
    do local mf = io.open(sdr .. "/metadata.epub.lua", "w")
       mf:write('return { ["doc_path"] = "/mnt/us/Books/Recovered.epub" }'); mf:close() end

    local saved_ds = package.loaded["datastorage"]
    package.loaded["datastorage"] = { getDocSettingsHashDir = function() return hashroot end }

    h.assert_equal(Finder.doc_path_for_hash("abc123def0", lfs),
        "/mnt/us/Books/Recovered.epub",
        "doc_path_for_hash: reads doc_path from the sharded same-md5 hashdocsettings .sdr")
    h.assert_equal(Finder.doc_path_for_hash("ffffffffff", lfs), nil,
        "doc_path_for_hash: nil when no .sdr exists for the id")
    h.assert_equal(Finder.doc_path_for_hash("a", lfs), nil,
        "doc_path_for_hash: nil for an id too short to shard")

    package.loaded["datastorage"] = saved_ds
    os.execute("rm -rf '" .. base .. "'")
end


-- ---------------------------------------------------------------------------
-- _reconstruct_dir_book_path — mirrored book path from a docsettings .sdr,
-- including the mount-alias fallback (Fix A): the SAME tree reached via a
-- prefix that differs from getDocSettingsDir() must still resolve, or a root
-- walk (Syncthing folder pointed into the tree) lists the book a SECOND time
-- because it falls through to another device's recorded path while the dir
-- finder resolved the local one (the cross-scan duplicate).
-- ---------------------------------------------------------------------------
do
    local R = Finder._reconstruct_dir_book_path

    -- Canonical: the .sdr is under dir_root as DataStorage reports it (the dir
    -- finder, which scans FROM dir_root, always lands here).
    local sdr = "./docsettings/mnt/us/Books/MyBook.epub.sdr"
    h.assert_equal(
        R(sdr, sdr .. "/MyBook.epub.syncery-progress.json", "./docsettings"),
        "/mnt/us/Books/MyBook.epub",
        "reconstruct: canonical prefix strip")

    -- Mount-alias (Fix A): dir_root is a relative "./docsettings" but the walk
    -- reaches the identical tree absolutely.  The strict strip fails; the
    -- tree-name-segment fallback must recover the SAME mirrored path.
    local sdr_walk = "/mnt/base-us/koreader/docsettings/mnt/us/Books/MyBook.epub.sdr"
    h.assert_equal(
        R(sdr_walk, sdr_walk .. "/MyBook.epub.syncery-progress.json", "./docsettings"),
        "/mnt/us/Books/MyBook.epub",
        "reconstruct: mount-alias fallback recovers the mirrored path (Fix A)")

    -- The aliased and canonical scans resolve IDENTICALLY -- this agreement is
    -- exactly what lets the content de-dup collapse the re-walk.
    h.assert_equal(
        R(sdr_walk, sdr_walk .. "/MyBook.epub.syncery-progress.json", "./docsettings"),
        R(sdr, sdr .. "/MyBook.epub.syncery-progress.json", "./docsettings"),
        "reconstruct: aliased scan resolves identically to the canonical scan")

    -- A hashdocsettings .sdr reached by the walk must NOT be mistaken for a
    -- docsettings one: the leading-slash "/docsettings/" anchor never matches
    -- "/hashdocsettings/", so this returns nil and the walk falls to the
    -- recorded-entry path -- exactly what the hash finder does, so they agree.
    local sdr_hash = "/mnt/base-us/koreader/hashdocsettings/ab/abcd1234.sdr"
    h.assert_nil(
        R(sdr_hash, sdr_hash .. "/MyBook.epub.syncery-progress.json", "./docsettings"),
        "reconstruct: hashdocsettings path is not mistaken for docsettings")

    -- Annotations-only sync files resolve the same way (same basename rule).
    h.assert_equal(
        R(sdr_walk, sdr_walk .. "/MyBook.epub.syncery-annotations.json", "./docsettings"),
        "/mnt/us/Books/MyBook.epub",
        "reconstruct: annotations-only sync file resolves via the fallback too")

    -- A non-Syncery file in the .sdr yields nil (no suffix stripped).
    h.assert_nil(
        R(sdr, sdr .. "/metadata.epub.lua", "./docsettings"),
        "reconstruct: a non-Syncery file is not treated as a book")
end


h.teardown()
