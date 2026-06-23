-- =============================================================================
-- syncery_ui/progress_browser/progress_enum.lua
-- =============================================================================
--
-- Enumerate every synced book that has reading-PROGRESS state, for the
-- all-books Progress Browser.  Reuses the SAME scan primitives the booklist
-- and the annotation viewer's book_enum use (Scan.scanHash /
-- Scan.getScanRoots + Scan.deriveRootsFromHistory / make_cancellable_walk +
-- HashLocationFinder), composed here WITHOUT the interactive Trapper UI.
--
-- This is the progress-domain twin of annotation_viewer/book_enum.lua.  Two
-- substantive differences:
--
--   * It KEEPS each book's real `progress_path` -- the syncery-progress.json
--     the scan found by walking the filesystem.  The browser reads each file
--     directly via ProgressStateStore.load_shared_from_path(progress_path),
--     because a content-hash (synceryhash) book has NO book_path to derive
--     from, and a book stored in a different KOReader metadata mode than the
--     active one derives the wrong sidecar path.
--
--   * It emits ONLY books that HAVE a progress file.  A book with annotations
--     but no syncery-progress.json (progress sync is off for it) belongs in
--     the Annotation Browser, not here.
--
-- Returns { title, book_path, progress_path, filename } per book, de-duped by
-- `book_path or progress_path` (identity from JSON content, not
-- .sdr location).
--
-- TRANSPORT-AGNOSTIC: every book and field here comes from the shared
-- progress files, which BOTH Syncthing and cloud transports sync.  Nothing in
-- this module depends on Syncthing folder state, peer connectivity, or any
-- transport-specific signal.
-- =============================================================================

local Scan = require("syncery_ui/booklist/scan")

local ProgressEnum = {}

--- @param is_cancelled function|nil  () -> boolean, consulted during the walk
--- @param on_progress  function|nil  (count) -> boolean, false aborts the walk
--- @return table  list of { title, book_path, progress_path, filename }
function ProgressEnum.enumerate(is_cancelled, on_progress)
    is_cancelled = is_cancelled or function() return false end
    local raw = {}

    -- (1) synceryhash STORAGE (synceryhash/).
    Scan.scanHash(raw)

    -- (2) KOReader hashdocsettings/ + docsettings/ trees.  Seed the finders'
    --     skip-set with books synceryhash ALREADY contributed a PROGRESS row
    --     for, so the same book in two stores is listed once.  Gate on
    --     progress_path (NOT just file): an annotations-only synceryhash row
    --     carries no progress, so it must not suppress a tree's progress row
    --     for the same book.
    local ok_hf, HashLocationFinder =
        pcall(require, "syncery_ann/hash_location_finder")
    if ok_hf and HashLocationFinder then
        local hash_seen = {}
        for _, b in ipairs(raw) do
            if b.progress_path and b.file then hash_seen[b.file] = true end
        end
        local ok_ss, ProgressStateStore =
            pcall(require, "syncery_progress/state_store")
        local normalize = ok_ss and ProgressStateStore
            and ProgressStateStore.normalize or nil

        for _, b in ipairs(HashLocationFinder.find_synced_books(
                hash_seen, { normalize = normalize })) do
            raw[#raw + 1] = b
        end
        for _, b in ipairs(HashLocationFinder.find_synced_books_in_dir(
                hash_seen, { normalize = normalize })) do
            raw[#raw + 1] = b
        end
    end

    -- (3) <book>.sdr beside the books, over the scan roots PLUS the folders
    --     KOReader's history knows -- the SAME pair the booklist and book_enum
    --     walk.  The history roots are LOAD-BEARING for KOReader's default
    --     "book folder" metadata location: the .sdr sits beside the book,
    --     reachable only via history, NOT via the configured Syncthing folder.
    local roots, root_seen = {}, {}
    for _, r in ipairs(Scan.getScanRoots() or {}) do
        if not root_seen[r] then root_seen[r] = true; roots[#roots + 1] = r end
    end
    for _, r in ipairs(Scan.deriveRootsFromHistory() or {}) do
        if not root_seen[r] then root_seen[r] = true; roots[#roots + 1] = r end
    end
    local walk = Scan.make_cancellable_walk(raw, is_cancelled, on_progress)
    local walk_seen = {}
    for _, root in ipairs(roots) do
        if is_cancelled() then break end
        walk(root, "%.syncery%-progress%.json$", walk_seen)
    end

    -- De-dup, keeping ONLY books that have a progress file.  Key on the
    -- resolved book path when known (collapses the same book found in more
    -- than one store), else the progress file path (content-hash books carry
    -- no book path).  Rows without a progress_path are annotations-only --
    -- dropped here; they surface in the Annotation Browser instead.
    local seen, books = {}, {}
    for _, b in ipairs(raw) do
        if b.progress_path then
            local key = b.file or b.progress_path
            if key and not seen[key] then
                seen[key] = true
                books[#books + 1] = {
                    title         = b.display_name,
                    book_path     = b.file,
                    progress_path = b.progress_path,
                    filename      = (b.file and (b.file:match("([^/\\]+)$") or b.file))
                                    or b.display_name,
                }
            end
        end
    end
    return books
end

return ProgressEnum
