-- =============================================================================
-- syncery_ui/annotation_viewer/book_enum.lua
-- =============================================================================
--
-- Enumerate every synced book for the all-books annotation viewer, reusing the
-- SAME scan primitives the booklist management view uses
-- (`Scan.getScanRoots` + `Scan.deriveRootsFromHistory` / `scanHash` /
-- `make_cancellable_walk` + `HashLocationFinder`), composed here WITHOUT the
-- interactive Trapper UI.
--
-- The underlying primitives are shared; only the ~30-line composition glue is
-- repeated from `booklist/init.lua`.  A production refinement (flagged in the
-- adversarial pass / design doc) is to extract ONE shared enumeration that both
-- the booklist and this viewer call.  Kept separate for the dry-run so the
-- booklist is not touched.
--
-- Returns { title, path, filename } per book, de-duped by path
-- (identity from JSON content, carried on the scan entry's `file`).  Pathless
-- entries are SKIPPED here (unlike the booklist, which keeps them for display):
-- the viewer needs a real path to `load_shared` the annotations.
-- =============================================================================

local Scan = require("syncery_ui/booklist/scan")

local BookEnum = {}

--- @param is_cancelled function|nil  () -> boolean, consulted during the walk
--- @param on_progress  function|nil  (count) -> boolean, false aborts the walk
--- @return table  list of { title, path, filename }
function BookEnum.enumerate(is_cancelled, on_progress)
    is_cancelled = is_cancelled or function() return false end
    local raw = {}

    -- (1) synceryhash STORAGE (synceryhash/)
    Scan.scanHash(raw)

    -- (2) KOReader hashdocsettings/ + docsettings/ trees (shared hash_seen so a
    --     book in more than one tree is listed once)
    local ok_hf, HashLocationFinder =
        pcall(require, "syncery_ann/hash_location_finder")
    if ok_hf and HashLocationFinder then
        local hash_seen = {}
        for _, b in ipairs(raw) do
            if b.file then hash_seen[b.file] = true end
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

    -- (3) <book>.sdr beside the books, over the scan roots.  Roots = the
    --     configured Syncthing folder(s) PLUS the folders KOReader's history
    --     knows (where the user keeps books) -- the SAME pair the booklist
    --     walks (booklist/init.lua).  The history roots are LOAD-BEARING: in
    --     KOReader's default "book folder" metadata location the .sdr files sit
    --     beside the books, reachable only via history, NOT via the configured
    --     Syncthing folder -- without them this view silently misses every
    --     book-folder-mode book the booklist shows.
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

    -- De-dup by a stable key.  File-bearing rows key on the resolved book path
    -- (unchanged).  Annotations-only rows from a synceryhash book have NO book
    -- path -- content-hash storage records none -- so they key on their
    -- annotations file instead (the scan always carries it).  Keeping them lets
    -- the browser show their notes (read via annotations_path below); without a
    -- path there is simply no "Go to" button (book_exists is false).
    local seen, books = {}, {}
    for _, b in ipairs(raw) do
        local key = b.file or b.annotations_path
        if key and not seen[key] then
            seen[key] = true
            books[#books + 1] = {
                title    = b.display_name,
                path     = b.file,
                filename = (b.file and (b.file:match("([^/\\]+)$") or b.file))
                           or b.display_name,
                -- The REAL shared file the scan found by walking the local
                -- filesystem.  Carry it so the viewer reads THIS file directly
                -- instead of re-deriving a sidecar path from `path`.
                annotations_path = b.annotations_path,
            }
        end
    end
    return books
end

return BookEnum
