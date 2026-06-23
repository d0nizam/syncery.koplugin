-- =============================================================================
-- spec/progress_enum_spec.lua
-- =============================================================================
--
-- Tests for syncery_ui/progress_browser/progress_enum.lua -- the all-books
-- enumeration for the Progress Browser.
--
-- The enumeration is filesystem-integration glue (scanHash + HashLocationFinder
-- + a root-walk); the headless-testable invariants are (1) its ROOT SET and
-- (2) its de-dup/filter contract.
--
--   1. It must walk the SAME roots the booklist does: the configured Syncthing
--      folder(s) (getScanRoots) PLUS the folders KOReader's history knows
--      (deriveRootsFromHistory).  The history roots are LOAD-BEARING -- in
--      KOReader's default "book folder" location the .sdr sits beside the book,
--      reachable only via history.
--
--   2. Unlike the Annotation Browser's book_enum, the Progress Browser emits
--      ONLY books that HAVE a progress file, and carries each book's real
--      `progress_path` for a direct load_shared_from_path read.  An
--      annotations-only row (no progress_path) is dropped here.
--
-- Strategy: stub the scan module so the two root sources return sentinels and
-- the walk records which roots it is handed; stub the hash finders to add
-- nothing; inject rows via the scanHash stub to exercise the de-dup/filter.
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_progress_enum_spec_" .. tostring(os.time()))

-- Count how many times the walk is handed each root.
local walked = {}

package.loaded["syncery_ui/booklist/scan"] = {
    scanHash               = function(_) end,        -- no synceryhash books
    getScanRoots           = function() return { "/ROOT_SYNCTHING", "/ROOT_BOTH" } end,
    deriveRootsFromHistory = function() return { "/ROOT_HISTORY", "/ROOT_BOTH" } end,
    make_cancellable_walk  = function(_raw, _is_cancelled, _on_progress)
        return function(root, _pattern, _seen)
            walked[root] = (walked[root] or 0) + 1
        end
    end,
}
package.loaded["syncery_ann/hash_location_finder"] = {
    find_synced_books        = function() return {} end,
    find_synced_books_in_dir = function() return {} end,
}
package.loaded["syncery_progress/state_store"] = { normalize = function(x) return x end }

-- Bind the stubs: force a fresh require (progress_browser/* is NOT in the
-- runner's between-spec clear list, so a load from a prior spec could persist).
package.loaded["syncery_ui/progress_browser/progress_enum"] = nil
local ProgressEnum = require("syncery_ui/progress_browser/progress_enum")


-- ---------------------------------------------------------------------------
-- 1. enumerate walks getScanRoots AND deriveRootsFromHistory, de-duped.
-- ---------------------------------------------------------------------------
do
    ProgressEnum.enumerate()

    h.assert_equal(walked["/ROOT_SYNCTHING"], 1,
        "walks the configured Syncthing folder (getScanRoots)")
    h.assert_equal(walked["/ROOT_HISTORY"], 1,
        "walks the history-derived roots (deriveRootsFromHistory) -- book-folder-mode")
    h.assert_equal(walked["/ROOT_BOTH"], 1,
        "a root present in BOTH sources is walked once (de-dup)")
end


-- ---------------------------------------------------------------------------
-- 2. enumerate keeps ONLY progress-bearing books, carrying progress_path;
--    file-bearing rows key on the book path; a pathless (synceryhash) progress
--    row keys on its progress_path; an annotations-only row (no progress_path)
--    is DROPPED; a duplicate progress row collapses to one.
-- ---------------------------------------------------------------------------
do
    local Scan = package.loaded["syncery_ui/booklist/scan"]
    local saved_scanHash = Scan.scanHash
    Scan.scanHash = function(raw)
        raw[#raw + 1] = {     -- file-bearing book WITH progress
            file = "/books/HasProgress.epub",
            progress_path = "/books/HasProgress.epub.sdr/HasProgress.epub.syncery-progress.json",
            annotations_path = "/books/HasProgress.epub.sdr/HasProgress.epub.syncery-annotations.json",
            display_name = "Has Progress",
        }
        raw[#raw + 1] = {     -- pathless synceryhash book WITH progress
            file = nil,
            progress_path = "/state/synceryhash/cd/cd456/syncery-progress.json",
            annotations_path = "/state/synceryhash/cd/cd456/syncery-annotations.json",
            display_name = "Pathless Progress",
        }
        raw[#raw + 1] = {     -- duplicate of the file-bearing one (same file)
            file = "/books/HasProgress.epub",
            progress_path = "/books/HasProgress.epub.sdr/HasProgress.epub.syncery-progress.json",
            display_name = "Has Progress",
        }
        raw[#raw + 1] = {     -- annotations-only book (NO progress_path)
            file = "/books/AnnOnly.epub",
            progress_path = nil,
            annotations_path = "/books/AnnOnly.epub.sdr/AnnOnly.epub.syncery-annotations.json",
            display_name = "Annotations Only",
        }
        raw[#raw + 1] = {     -- neither path nor progress -> unusable
            file = nil, progress_path = nil, display_name = "Ghost",
        }
    end

    local books = ProgressEnum.enumerate()

    local by_book_path, count_book_path = {}, {}
    local by_progress_path = {}
    local titles = {}
    for _, b in ipairs(books) do
        titles[b.title] = (titles[b.title] or 0) + 1
        if b.book_path then
            by_book_path[b.book_path] = b
            count_book_path[b.book_path] = (count_book_path[b.book_path] or 0) + 1
        end
        if b.progress_path then by_progress_path[b.progress_path] = b end
    end

    -- file-bearing progress row kept, with BOTH paths preserved
    local hp = by_book_path["/books/HasProgress.epub"]
    h.assert_true(hp ~= nil,
        "file-bearing progress book kept (book_path preserved)")
    if hp then
        h.assert_equal(hp.progress_path,
            "/books/HasProgress.epub.sdr/HasProgress.epub.syncery-progress.json",
            "progress_path carried for direct load_shared_from_path")
    end
    h.assert_equal(count_book_path["/books/HasProgress.epub"], 1,
        "a duplicate progress row for the same book collapses to one")

    -- pathless synceryhash progress row kept, keyed by progress_path
    h.assert_true(by_progress_path["/state/synceryhash/cd/cd456/syncery-progress.json"] ~= nil,
        "pathless (synceryhash) progress book kept, keyed by progress_path")

    -- annotations-only row dropped
    h.assert_true(titles["Annotations Only"] == nil,
        "annotations-only book (no progress_path) is dropped -- it belongs in the Annotation Browser")

    -- ghost dropped
    h.assert_true(titles["Ghost"] == nil,
        "a row with neither book_path nor progress_path is dropped")

    Scan.scanHash = saved_scanHash
end

h.teardown()
print("progress_enum_spec: assertions complete")
