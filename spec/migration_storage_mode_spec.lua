-- =============================================================================
-- spec/migration_storage_mode_spec.lua
-- =============================================================================
--
-- Tests for syncery_migration/storage_mode.lua — the SDR↔hash file
-- relocation, moved out of main.lua in Phase 9.3.
--
-- The real relocation risk is the file-moving core, so these tests
-- exercise it against real files in /tmp:
--
--   * migrate_book_files — moves progress + annotation files between
--     the SDR and hash path layouts.
--   * migrate_single_book — moves one scanned book, returns false when
--     the book is already in the new layout (idempotent resume).
--   * perform_migration — bulk loop: migrates new books, skips ones
--     already present, reports counts.
--
-- UI deps (Trapper, InputDialog, UIManager) are stubbed.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_migration_storage_" .. tostring(os.time()))


-- ----------------------------------------------------------------------------
-- Stubs — installed BEFORE requiring the module under test.
-- ----------------------------------------------------------------------------

local shown = {}
package.loaded["ui/uimanager"] = {
    show  = function(_, w) table.insert(shown, w) end,
    close = function() end,
}
package.loaded["ui/widget/infomessage"] = { new = function(_, a) return a or {} end }
package.loaded["ui/widget/inputdialog"] = { new = function(_, a) return a or {} end }
package.loaded["ui/widget/confirmbox"]  = { new = function(_, a) return a or {} end }
package.loaded["ui/widget/pathchooser"] = { new = function(_, a) return a or {} end }
package.loaded["device"]                = { home_dir = "/mnt/us",
    screen = { getWidth = function() return 600 end, getHeight = function() return 800 end } }

-- Trapper stub: `wrap` runs the function inline; `info` always returns
-- true (never "cancelled"); `reset` is a no-op.
package.loaded["ui/trapper"] = {
    wrap  = function(_, fn) fn() end,
    info  = function() return true end,
    reset = function() end,
}


local StorageMode   = require("syncery_migration/storage_mode")
local AnnPaths      = require("syncery_ann/paths")
local ProgressPaths = require("syncery_progress/paths")
local lfs           = require("libs/libkoreader-lfs")


-- ----------------------------------------------------------------------------
-- Fixtures
-- ----------------------------------------------------------------------------

local _book_counter = 0
local function unique_book_file()
    _book_counter = _book_counter + 1
    local path = string.format("%s/books/book_%03d.epub", h.test_root, _book_counter)
    -- Create the real (empty) book on disk: production always has the book
    -- present, and perform_migration's existence guard requires it (a missing
    -- book means a malformed path → don't move/delete).
    os.execute("mkdir -p '" .. h.test_root .. "/books' 2>/dev/null")
    local f = io.open(path, "w"); if f then f:write(""); f:close() end
    return path
end

local function write_file(path, content)
    if not path then return end
    local dir = path:match("^(.*)/[^/]+$")
    if dir then os.execute("mkdir -p '" .. dir .. "' 2>/dev/null") end
    local f = io.open(path, "wb")
    assert(f, "could not open " .. tostring(path))
    f:write(content or "x")
    f:close()
end

local function file_exists(path)
    return path ~= nil and lfs.attributes(path, "mode") == "file"
end

-- A minimal fake plugin: only `_logActivity` is touched by the module.
local function fake_plugin()
    local p = { _activity = {} }
    function p:_logActivity(kind, detail)
        table.insert(self._activity, { kind = kind, detail = detail })
    end
    return p
end


-- ===========================================================================
-- migrate_book_files — SDR → hash
-- ===========================================================================

do
    local plugin = fake_plugin()
    local book   = unique_book_file()

    -- Lay down SDR-layout files.
    ProgressPaths.set_storage_mode("sdr")
    AnnPaths.set_storage_mode("sdr")
    local sdr_prog = ProgressPaths.shared_progress_path(book)
    local sdr_ann  = AnnPaths.shared_annotations_path(book)
    write_file(sdr_prog, "progress-data")
    write_file(sdr_ann,  "annotation-data")

    -- The caller flips the mode to the target before calling (mirrors
    -- setStorageMode in main.lua).
    ProgressPaths.set_storage_mode("hash")
    AnnPaths.set_storage_mode("hash")
    local hash_prog = ProgressPaths.shared_progress_path(book)
    local hash_ann  = AnnPaths.shared_annotations_path(book)

    StorageMode.migrate_book_files(plugin, book, "sdr", "hash")

    h.assert_true(file_exists(hash_prog),  "SDR→hash: progress file moved to hash layout")
    h.assert_true(file_exists(hash_ann),   "SDR→hash: annotation file moved to hash layout")
    h.assert_false(file_exists(sdr_prog),  "SDR→hash: old SDR progress file gone")
    h.assert_false(file_exists(sdr_ann),   "SDR→hash: old SDR annotation file gone")

    -- Content preserved through the move.
    local f = io.open(hash_prog, "rb")
    h.assert_equal(f:read("*a"), "progress-data", "SDR→hash: progress content intact")
    f:close()

    -- Leave the mode where the rest of the spec expects it.
    ProgressPaths.set_storage_mode("sdr")
    AnnPaths.set_storage_mode("sdr")
end


-- migrate_book_files: a missing source file is a silent no-op (no crash).
do
    local plugin = fake_plugin()
    local book   = unique_book_file()   -- nothing written for this book
    ProgressPaths.set_storage_mode("sdr")
    AnnPaths.set_storage_mode("sdr")
    StorageMode.migrate_book_files(plugin, book, "sdr", "hash")
    h.assert_true(true, "migrate_book_files: missing source → safe no-op")
    ProgressPaths.set_storage_mode("sdr")
    AnnPaths.set_storage_mode("sdr")
end


-- ===========================================================================
-- migrate_single_book
-- ===========================================================================

-- A scanned book not yet in the new layout → moved, returns true.
do
    local plugin = fake_plugin()
    local book   = unique_book_file()

    ProgressPaths.set_storage_mode("hash")
    AnnPaths.set_storage_mode("hash")
    local dst_prog = ProgressPaths.shared_progress_path(book)
    local dst_ann  = AnnPaths.shared_annotations_path(book)

    -- The scanned-book record carries the OLD-layout source paths.
    local src_prog = h.test_root .. "/scan/" .. _book_counter .. ".progress.json"
    local src_ann  = h.test_root .. "/scan/" .. _book_counter .. ".ann.json"
    write_file(src_prog, "p")
    write_file(src_ann,  "a")

    local moved = StorageMode.migrate_single_book(plugin, {
        file             = book,
        progress_path    = src_prog,
        annotations_path = src_ann,
    })
    h.assert_true(moved,                  "migrate_single_book: new book → true")
    h.assert_true(file_exists(dst_prog),  "migrate_single_book: progress moved")
    h.assert_true(file_exists(dst_ann),   "migrate_single_book: annotations moved")

    ProgressPaths.set_storage_mode("sdr")
    AnnPaths.set_storage_mode("sdr")
end


-- A book already present in the new layout → skipped, returns false.
do
    local plugin = fake_plugin()
    local book   = unique_book_file()

    ProgressPaths.set_storage_mode("hash")
    AnnPaths.set_storage_mode("hash")
    write_file(ProgressPaths.shared_progress_path(book), "already-here")

    local moved = StorageMode.migrate_single_book(plugin, {
        file          = book,
        progress_path = h.test_root .. "/scan/none.json",
    })
    h.assert_false(moved,
        "migrate_single_book: book already in new layout → false (skip)")

    ProgressPaths.set_storage_mode("sdr")
    AnnPaths.set_storage_mode("sdr")
end


-- Guard: nil book / nil book.file → false, no crash.
do
    local plugin = fake_plugin()
    h.assert_false(StorageMode.migrate_single_book(plugin, {}),
        "migrate_single_book: book with no .file → false")
end


-- ===========================================================================
-- A4/A5 — per-file convergence (the partial-migration cases the
-- progress-only skip used to mishandle).
-- ===========================================================================

-- A4: progress already at destination, annotations NOT yet moved (a
-- prior run crashed between the two moves). A re-run must FINISH the
-- annotations rather than skip the book on the progress check — and
-- report it as migrated (a real step happened this pass).
do
    local plugin = fake_plugin()
    local book   = unique_book_file()

    ProgressPaths.set_storage_mode("hash")
    AnnPaths.set_storage_mode("hash")
    local dst_prog = ProgressPaths.shared_progress_path(book)
    local dst_ann  = AnnPaths.shared_annotations_path(book)

    -- Simulate the partial earlier run: progress is already at dst…
    write_file(dst_prog, "progress-already-moved")
    -- …but annotations still sit at the old-layout source.
    local src_ann = h.test_root .. "/scan/" .. _book_counter .. ".ann.json"
    write_file(src_ann, "annotation-pending")

    local moved = StorageMode.migrate_single_book(plugin, {
        file             = book,
        progress_path    = h.test_root .. "/scan/" .. _book_counter .. ".prog.json", -- absent
        annotations_path = src_ann,
    })

    h.assert_true(moved,
        "A4: partially-migrated book finishes on re-run → reported migrated")
    h.assert_true(file_exists(dst_ann),
        "A4: the pending annotations file was placed at the destination")
    h.assert_false(file_exists(src_ann),
        "A4: the old-layout annotations source was consumed")

    ProgressPaths.set_storage_mode("sdr")
    AnnPaths.set_storage_mode("sdr")
end


-- A book with NO annotations file (read but never highlighted). It must
-- migrate once (progress only), then be SKIPPED on re-run — never
-- re-counted forever because dst_ann legitimately never exists.
do
    local plugin = fake_plugin()
    local book   = unique_book_file()

    ProgressPaths.set_storage_mode("hash")
    AnnPaths.set_storage_mode("hash")
    local dst_prog = ProgressPaths.shared_progress_path(book)

    local src_prog = h.test_root .. "/scan/" .. _book_counter .. ".prog.json"
    write_file(src_prog, "p-only")          -- no annotations source at all

    -- First pass: progress placed → migrated.
    local first = StorageMode.migrate_single_book(plugin, {
        file             = book,
        progress_path    = src_prog,
        annotations_path = h.test_root .. "/scan/" .. _book_counter .. ".ann.json", -- never written
    })
    h.assert_true(first,  "ann-less: first pass migrates (progress placed)")
    h.assert_true(file_exists(dst_prog), "ann-less: progress now at destination")

    -- Second pass: nothing left to move → skipped (false), NOT re-counted.
    local second = StorageMode.migrate_single_book(plugin, {
        file             = book,
        progress_path    = src_prog,   -- already consumed; absent now
        annotations_path = h.test_root .. "/scan/" .. _book_counter .. ".ann.json",
    })
    h.assert_false(second,
        "ann-less: re-run skips the fully-migrated book (no phantom re-migrate)")

    ProgressPaths.set_storage_mode("sdr")
    AnnPaths.set_storage_mode("sdr")
end


-- Destination-exists must NEVER overwrite newer data, and must drop a
-- stale lingering source (the plan's "never overwrites newer shared
-- data, drops the stale source").
do
    local plugin = fake_plugin()
    local book   = unique_book_file()

    ProgressPaths.set_storage_mode("hash")
    AnnPaths.set_storage_mode("hash")
    local dst_prog = ProgressPaths.shared_progress_path(book)

    write_file(dst_prog, "NEWER-destination-data")   -- already there, newer
    local src_prog = h.test_root .. "/scan/" .. _book_counter .. ".prog.json"
    write_file(src_prog, "STALE-source-data")        -- old-layout leftover

    local moved = StorageMode.migrate_single_book(plugin, {
        file             = book,
        progress_path    = src_prog,
        annotations_path = h.test_root .. "/scan/" .. _book_counter .. ".ann.json",
    })

    h.assert_false(moved,
        "non-clobber: nothing placed this pass (dst already present) → skipped")
    local f = io.open(dst_prog, "rb")
    h.assert_equal(f:read("*a"), "NEWER-destination-data",
        "non-clobber: newer destination data was NOT overwritten")
    f:close()
    h.assert_false(file_exists(src_prog),
        "non-clobber: the stale old-layout source was dropped")

    ProgressPaths.set_storage_mode("sdr")
    AnnPaths.set_storage_mode("sdr")
end


-- ===========================================================================
-- perform_migration — bulk loop
-- ===========================================================================

-- Empty book list → "nothing to migrate" message, no crash.
do
    local plugin = fake_plugin()
    while #shown > 0 do table.remove(shown) end
    StorageMode.perform_migration(plugin, {})
    h.assert_equal(#shown, 1, "perform_migration: empty list → one message shown")
end


-- Mixed list: one new book migrated, one already-present book (already there).
do
    local plugin = fake_plugin()
    while #shown > 0 do table.remove(shown) end

    ProgressPaths.set_storage_mode("hash")
    AnnPaths.set_storage_mode("hash")

    -- book A: new — source files exist, destination does not.
    local book_a  = unique_book_file()
    local a_src_p = h.test_root .. "/scan/a_p.json"
    local a_src_a = h.test_root .. "/scan/a_a.json"
    write_file(a_src_p, "ap")
    write_file(a_src_a, "aa")

    -- book B: already migrated — destination progress file present.
    local book_b = unique_book_file()
    write_file(ProgressPaths.shared_progress_path(book_b), "bp")

    StorageMode.perform_migration(plugin, {
        { file = book_a, progress_path = a_src_p, annotations_path = a_src_a },
        { file = book_b, progress_path = h.test_root .. "/scan/none.json" },
    })

    h.assert_true(file_exists(ProgressPaths.shared_progress_path(book_a)),
        "perform_migration: new book A migrated to hash layout")
    h.assert_equal(#shown, 1, "perform_migration: one summary message shown")

    -- The activity log records the honest migrated / already-there / not-here counts.
    h.assert_true(#plugin._activity >= 1,
        "perform_migration: activity logged")
    h.assert_true(plugin._activity[1].detail:match("1 migrated") ~= nil,
        "perform_migration: log reports 1 migrated")
    h.assert_true(plugin._activity[1].detail:match("1 already there") ~= nil,
        "perform_migration: log reports 1 already there (book B was already at the destination)")

    ProgressPaths.set_storage_mode("sdr")
    AnnPaths.set_storage_mode("sdr")
end


-- perform_migration bulk loop: a partially-migrated book (progress at
-- destination, annotations pending) is FINISHED and counted migrated,
-- not skipped on the progress check (A4/A5 in the bulk path).
do
    local plugin = fake_plugin()
    while #shown > 0 do table.remove(shown) end

    ProgressPaths.set_storage_mode("hash")
    AnnPaths.set_storage_mode("hash")

    local book   = unique_book_file()
    local dst_prog = ProgressPaths.shared_progress_path(book)
    local dst_ann  = AnnPaths.shared_annotations_path(book)
    write_file(dst_prog, "prog-already")               -- progress already moved
    local src_ann = h.test_root .. "/scan/partial_a.json"
    write_file(src_ann, "ann-pending")                 -- annotations still at source

    StorageMode.perform_migration(plugin, {
        { file = book,
          progress_path    = h.test_root .. "/scan/partial_p.json",  -- absent
          annotations_path = src_ann },
    })

    h.assert_true(file_exists(dst_ann),
        "perform_migration: partial book's annotations finished on this pass")
    h.assert_true(plugin._activity[1].detail:match("1 migrated") ~= nil,
        "perform_migration: partial book counted as migrated, not skipped")

    ProgressPaths.set_storage_mode("sdr")
    AnnPaths.set_storage_mode("sdr")
end


-- ---------------------------------------------------------------------------
-- REGRESSION (data loss the user hit): a book whose progress_path IS its
-- destination (already at the SDR/hashdocsettings location) must SURVIVE
-- migration.  On-device, the booklist's hashdocsettings books wrongly reached
-- migrate_all_books via scanHash; move_one saw src==dst and os.remove'd the
-- live file.  The real fix is scanHash being synceryhash-only (so these never
-- reach migration), but perform_migration itself must also never delete a
-- file that is already where it belongs.
-- ---------------------------------------------------------------------------
do
    shown = {}
    local plugin = fake_plugin()
    ProgressPaths.set_storage_mode("sdr")
    AnnPaths.set_storage_mode("sdr")

    local book = unique_book_file()
    local dst = ProgressPaths.shared_progress_path(book)
    write_file(dst, "live-progress-data")
    h.assert_true(file_exists(dst), "precondition: progress file present at destination")

    StorageMode.perform_migration(plugin, {
        { file = book, progress_path = dst, annotations_path = h.test_root .. "/scan/missing_ann.json" },
    })

    h.assert_true(file_exists(dst),
        "DATA-LOSS GUARD: a book already at its destination is NOT deleted by migration")
    local f = io.open(dst, "r")
    local body = f and f:read("*a")
    if f then f:close() end
    h.assert_equal(body, "live-progress-data",
        "DATA-LOSS GUARD: the already-migrated file's contents are intact")

    ProgressPaths.set_storage_mode("sdr")
    AnnPaths.set_storage_mode("sdr")
end


-- ----------------------------------------------------------------------------
-- dedup_books_by_file — the all-locations migration's data-loss guard.
-- The same book can surface from more than one location scan; migrating it
-- twice could make move_one os.remove a legitimate second source.  De-dup by
-- book.file BEFORE migrating.
-- ----------------------------------------------------------------------------
do
    local books = {
        { file = "/b/Alpha.epub", progress_path = "/loc1/Alpha.syncery-progress.json" },
        { file = "/b/Beta.pdf",   progress_path = "/loc1/Beta.syncery-progress.json" },
        { file = "/b/Alpha.epub", progress_path = "/loc2/Alpha.syncery-progress.json" }, -- dup book, other src
        { file = nil,             progress_path = "/loc3/Mystery.syncery-progress.json" }, -- no file
    }
    StorageMode.dedup_books_by_file(books)

    local by_file, no_file = {}, 0
    for _, b in ipairs(books) do
        if b.file then by_file[b.file] = (by_file[b.file] or 0) + 1
        else no_file = no_file + 1 end
    end
    h.assert_equal(by_file["/b/Alpha.epub"], 1,
        "dedup: duplicate book.file collapses to a single entry")
    h.assert_equal(by_file["/b/Beta.pdf"], 1, "dedup: distinct book kept once")
    h.assert_equal(no_file, 1,
        "dedup: entry with no resolvable file is kept (cannot be de-duped)")
    -- The surviving Alpha is the FIRST occurrence (loc1), not the later dup.
    local alpha_src
    for _, b in ipairs(books) do
        if b.file == "/b/Alpha.epub" then alpha_src = b.progress_path end
    end
    h.assert_equal(alpha_src, "/loc1/Alpha.syncery-progress.json",
        "dedup: keeps the first occurrence's source path")
end


-- dedup_books_by_file's `seen` parameter EXCLUDES pre-known book paths.
-- NOTE: the migration caller must NOT pass the finders' OWN seen here — that
-- table already contains every finder-found book, so they'd all be treated as
-- duplicates and dropped (the 0-of-4 hashdocsettings data-loss bug).  The
-- caller dedups from a fresh slate; `seen` is only for a deliberate exclusion.
do
    local books = {
        { file = "/b/Gamma.epub", progress_path = "/rootwalk/Gamma.syncery-progress.json" },
        { file = "/b/Delta.epub", progress_path = "/rootwalk/Delta.syncery-progress.json" },
    }
    local seen = { ["/b/Gamma.epub"] = true }  -- caller deliberately excludes Gamma
    StorageMode.dedup_books_by_file(books, seen)
    local files = {}
    for _, b in ipairs(books) do files[b.file] = true end
    h.assert_nil(files["/b/Gamma.epub"],
        "dedup: a book pre-listed in `seen` is excluded from the result")
    h.assert_true(files["/b/Delta.epub"] ~= nil,
        "dedup: a not-yet-seen book is kept")
end


-- The data-loss shape, made explicit: if `seen` ALREADY contains every book
-- (as the finders' seen would), dedup drops them all.  This is exactly why the
-- migration caller passes NO seen — documented here so it is never reintroduced.
do
    local books = {
        { file = "/b/A.epub", progress_path = "/p/A.syncery-progress.json" },
        { file = "/b/B.epub", progress_path = "/p/B.syncery-progress.json" },
    }
    local already = { ["/b/A.epub"] = true, ["/b/B.epub"] = true }  -- finders' seen
    StorageMode.dedup_books_by_file(books, already)
    h.assert_equal(#books, 0,
        "dedup: passing a seen that already holds every book drops them ALL — the bug the caller avoids by passing no seen")

    -- Same books, dedup from a fresh slate (what the caller now does) → kept.
    local books2 = {
        { file = "/b/A.epub", progress_path = "/p/A.syncery-progress.json" },
        { file = "/b/B.epub", progress_path = "/p/B.syncery-progress.json" },
    }
    StorageMode.dedup_books_by_file(books2)
    h.assert_equal(#books2, 2,
        "dedup: from a fresh slate, distinct books are all kept (the fix)")
end


-- perform_migration EXISTENCE GUARD: a book.file that does NOT resolve to a
-- real book on disk must be skipped — its source must NOT be deleted.  This is
-- the data-loss safety net for a malformed book.file (the class of bug that
-- the extension-less reconstruction caused).
do
    local plugin = fake_plugin()
    while #shown > 0 do table.remove(shown) end
    ProgressPaths.set_storage_mode("hash")
    AnnPaths.set_storage_mode("hash")

    -- A source JSON exists, but book.file points at a book that is NOT on disk.
    local ghost_src = h.test_root .. "/scan/ghost_p.json"
    write_file(ghost_src, "ghost-progress-data")
    local ghost_book = h.test_root .. "/books/DoesNotExist.epub"   -- never created

    StorageMode.perform_migration(plugin, {
        { file = ghost_book, progress_path = ghost_src,
          annotations_path = h.test_root .. "/scan/ghost_a.json" },
    })

    h.assert_true(file_exists(ghost_src),
        "GUARD: source JSON is NOT deleted when book.file points to a missing book")
    h.assert_false(file_exists(ProgressPaths.shared_progress_path(ghost_book)),
        "GUARD: nothing is written to the destination for a missing book")
    h.assert_true(plugin._activity[1] and plugin._activity[1].detail:match("1 not here") ~= nil,
        "GUARD: the missing-book entry is counted as not-here (not on this device)")

    ProgressPaths.set_storage_mode("sdr")
    AnnPaths.set_storage_mode("sdr")
end


-- perform_migration CORRECT DESTINATION: a real book migrates to the
-- destination derived from its REAL path, and the source is removed.  With the
-- extension fix, book.file is the real ".epub" path, so the synceryhash hash is
-- the right one — the files are findable afterward, not stranded under a bogus
-- (extension-less) hash.
do
    local plugin = fake_plugin()
    while #shown > 0 do table.remove(shown) end
    ProgressPaths.set_storage_mode("hash")
    AnnPaths.set_storage_mode("hash")

    local book = unique_book_file()   -- creates the real .epub on disk
    local src_p = h.test_root .. "/scan/real_p.json"
    local src_a = h.test_root .. "/scan/real_a.json"
    write_file(src_p, "real-progress")
    write_file(src_a, "real-annotations")

    local dst_p = ProgressPaths.shared_progress_path(book)   -- hash from the REAL path
    h.assert_false(file_exists(dst_p), "precondition: destination absent before migration")

    StorageMode.perform_migration(plugin, {
        { file = book, progress_path = src_p, annotations_path = src_a },
    })

    h.assert_true(file_exists(dst_p),
        "CORRECT DST: progress lands at the destination derived from the REAL book path")
    h.assert_false(file_exists(src_p),
        "CORRECT DST: the SDR source progress file is removed after a successful move")
    h.assert_true(plugin._activity[1] and plugin._activity[1].detail:match("1 migrated") ~= nil,
        "CORRECT DST: counted as migrated")

    ProgressPaths.set_storage_mode("sdr")
    AnnPaths.set_storage_mode("sdr")
end


-- ----------------------------------------------------------------------------
-- Multi-device report: the completion message NAMES the user's OTHER devices
-- (so they know to repeat the migration there), in a stable sorted order, and
-- never names THIS device.  The names come from the per-device entries already
-- in each book's progress JSON -- no extra scan.  It also stays up until the
-- user dismisses it (timeout = nil), since it is actionable.
-- ----------------------------------------------------------------------------
do
    local plugin = fake_plugin()
    while #shown > 0 do table.remove(shown) end
    ProgressPaths.set_storage_mode("hash")
    AnnPaths.set_storage_mode("hash")

    -- THIS device.
    local LOCAL = "dev_local_thisone"
    local saved_grs = _G.G_reader_settings
    _G.G_reader_settings = { _t = { syncery_device_id = LOCAL },
        readSetting = function(self, k) return self._t[k] end,
        saveSetting = function(self, k, v) self._t[k] = v end }

    -- A real book on disk whose progress JSON lists THREE devices (this one +
    -- two others, each with a label).  The book migrates; the report should
    -- still surface the two OTHER devices.
    local book = unique_book_file()
    local prog = h.test_root .. "/scan/multi_p.json"
    write_file(prog,
        '{"schema_version":1,"entries":{'
        .. '"' .. LOCAL .. '":{"device_id":"' .. LOCAL .. '","label":"MyPhone","file":"' .. book .. '"},'
        .. '"dev_kkk":{"device_id":"dev_kkk","label":"KindlePaperWhite6","file":"/mnt/us/x.epub"},'
        .. '"dev_ooo":{"device_id":"dev_ooo","label":"Kobo Clara","file":"/kobo/x.epub"}}}')

    StorageMode.perform_migration(plugin, {
        { file = book, progress_path = prog, annotations_path = h.test_root .. "/scan/multi_a.json" },
    })

    h.assert_equal(#shown, 1, "multi-device: one summary message shown")
    local text = shown[1].text or ""
    h.assert_true(text:match("KindlePaperWhite6") ~= nil,
        "multi-device: report names the foreign Kindle")
    h.assert_true(text:match("Kobo Clara") ~= nil,
        "multi-device: report names the foreign Kobo")
    h.assert_true(text:match("MyPhone") == nil,
        "multi-device: report does NOT name THIS device")
    -- Stable, sorted order (pairs() order is unspecified): Kindle before Kobo.
    h.assert_true(text:match("KindlePaperWhite6, Kobo Clara") ~= nil,
        "multi-device: the other devices are listed in a stable sorted order")
    -- Actionable report stays until dismissed.
    h.assert_true(shown[1].timeout == nil,
        "multi-device: the report stays up (no auto-dismiss) until read")

    _G.G_reader_settings = saved_grs
    ProgressPaths.set_storage_mode("sdr")
    AnnPaths.set_storage_mode("sdr")
end


-- ----------------------------------------------------------------------------
-- Follow-up sequencing: when on_complete RETURNS a widget, the migration-result
-- message becomes sticky and carries that widget as its dismiss follow-up, shown
-- only AFTER the result is dismissed.  Isolated: a book that genuinely migrates
-- (no not-here, no foreign devices), so the stickiness comes ONLY from the
-- follow-up.
-- ----------------------------------------------------------------------------
do
    local plugin = fake_plugin()
    while #shown > 0 do table.remove(shown) end
    ProgressPaths.set_storage_mode("hash")
    AnnPaths.set_storage_mode("hash")

    local book = unique_book_file()                 -- real file on disk => migrates
    local prog = h.test_root .. "/scan/fu_p.json"
    write_file(prog, "p")                           -- present source => moved
    local follow = { text = "FOLLOWUP-WIDGET" }     -- stand-in advisory widget

    StorageMode.perform_migration(plugin, {
        { file = book, progress_path = prog, annotations_path = h.test_root .. "/scan/fu_a.json" },
    }, function() return follow end)

    -- Only the result message shows synchronously; the follow-up is deferred.
    h.assert_equal(#shown, 1, "followup: only the result message shows synchronously")
    h.assert_true(shown[1].text:match("Migrated 1 book") ~= nil,
        "followup: result message reports the migration")
    h.assert_true(shown[1].timeout == nil,
        "followup: result is sticky BECAUSE a follow-up waits (no foreign/not-here here)")
    h.assert_true(type(shown[1].dismiss_callback) == "function",
        "followup: result message carries the follow-up as a dismiss callback")
    h.assert_true(shown[1].text ~= "FOLLOWUP-WIDGET",
        "followup: the follow-up is not the synchronously-shown message")

    -- Dismissing the result reveals exactly the returned widget, next in sequence.
    shown[1].dismiss_callback()
    h.assert_equal(#shown, 2, "followup: dismissing the result shows the follow-up next")
    h.assert_equal(shown[2].text, "FOLLOWUP-WIDGET",
        "followup: the dismissed result reveals exactly the returned widget")

    ProgressPaths.set_storage_mode("sdr")
    AnnPaths.set_storage_mode("sdr")
end


h.teardown()
