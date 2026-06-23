-- =============================================================================
-- spec/book_enum_spec.lua
-- =============================================================================
--
-- Tests for syncery_ui/annotation_viewer/book_enum.lua -- the all-books
-- enumeration for the Annotation Browser.
--
-- The enumeration is filesystem-integration glue (scanHash + HashLocationFinder
-- + a root-walk); the headless-testable invariant is its ROOT SET.  The browser
-- must walk the SAME roots the booklist does: the configured Syncthing folder(s)
-- (`getScanRoots`) PLUS the folders KOReader's history knows
-- (`deriveRootsFromHistory`).  The history roots are LOAD-BEARING -- in
-- KOReader's default "book folder" metadata location the .sdr files sit beside
-- the books, reachable only via history, so without them the browser silently
-- misses every book-folder-mode book the booklist shows.
--
-- Strategy: stub the scan module so the two root sources return sentinels and
-- the walk records which roots it is handed; assert BOTH sources are walked,
-- and that a root present in both is walked once (de-dup).
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_book_enum_spec_" .. tostring(os.time()))

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

-- Bind the stubs: force a fresh require (annotation_viewer/* is NOT in the
-- runner's between-spec clear list, so a load from a prior spec could persist).
package.loaded["syncery_ui/annotation_viewer/book_enum"] = nil
local BookEnum = require("syncery_ui/annotation_viewer/book_enum")


-- ---------------------------------------------------------------------------
-- enumerate walks getScanRoots AND deriveRootsFromHistory, de-duped
-- ---------------------------------------------------------------------------
do
    BookEnum.enumerate()

    h.assert_equal(walked["/ROOT_SYNCTHING"], 1,
        "walks the configured Syncthing folder (getScanRoots)")
    h.assert_equal(walked["/ROOT_HISTORY"], 1,
        "walks the history-derived roots (deriveRootsFromHistory) -- the book-folder-mode fix")
    h.assert_equal(walked["/ROOT_BOTH"], 1,
        "a root present in BOTH sources is walked once (de-dup)")
end


-- ---------------------------------------------------------------------------
-- Layer 0: enumerate KEEPS pathless rows that carry annotations_path (a
-- synceryhash annotations-only book has no book path, but its notes load via
-- annotations_path), de-duped by annotations_path; file-bearing rows are
-- unchanged (still keyed by path); a row with neither is dropped.
-- ---------------------------------------------------------------------------
do
    local Scan = package.loaded["syncery_ui/booklist/scan"]
    local saved_scanHash = Scan.scanHash
    Scan.scanHash = function(raw)
        raw[#raw + 1] = {     -- file-bearing book (resolving path)
            file = "/books/HasPath.epub",
            annotations_path = "/books/HasPath.epub.sdr/HasPath.epub.syncery-annotations.json",
            display_name = "Has Path",
        }
        raw[#raw + 1] = {     -- pathless synceryhash book (only annotations_path)
            file = nil,
            annotations_path = "/state/synceryhash/ab/abc123/syncery-annotations.json",
            display_name = "Pathless Book",
        }
        raw[#raw + 1] = {     -- duplicate of the pathless one (same annotations_path)
            file = nil,
            annotations_path = "/state/synceryhash/ab/abc123/syncery-annotations.json",
            display_name = "Pathless Book",
        }
        raw[#raw + 1] = {     -- neither path nor annotations_path -> unusable
            file = nil, annotations_path = nil, display_name = "Ghost",
        }
    end

    local books = BookEnum.enumerate()
    local byann, bypath = {}, {}
    for _, b in ipairs(books) do
        if b.annotations_path then
            byann[b.annotations_path] = (byann[b.annotations_path] or 0) + 1
        end
        if b.path then bypath[b.path] = b end
    end

    h.assert_true(bypath["/books/HasPath.epub"] ~= nil,
        "Layer 0: file-bearing row kept (path preserved)")
    h.assert_equal(byann["/state/synceryhash/ab/abc123/syncery-annotations.json"], 1,
        "Layer 0: pathless row carrying annotations_path KEPT, de-duped to one")
    local ghost = false
    for _, b in ipairs(books) do if b.title == "Ghost" then ghost = true end end
    h.assert_false(ghost,
        "Layer 0: a row with neither path nor annotations_path is dropped")

    Scan.scanHash = saved_scanHash
end

h.teardown()
