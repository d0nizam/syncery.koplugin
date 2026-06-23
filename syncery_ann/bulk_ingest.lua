-- =============================================================================
-- syncery_ann/bulk_ingest.lua
-- =============================================================================
--
-- Bulk annotation-ingest scanner.
--
-- WHY THIS IS NEW (and not Scan.scanSDR): native KOReader annotations are not
-- "converted" — doc_settings_bridge reads them straight from doc_settings on
-- every sync. But sync only happens per-book at book-open. A user with many
-- books full of pre-existing highlights has nothing synced until they open
-- each one. This scanner ingests them in bulk, WITHOUT opening the reader:
-- for every book whose KOReader sidecar holds a native metadata.<ext>.lua, it
-- opens DocSettings, reads the annotations through the bridge, and writes the
-- initial Syncery annotations JSON. It is IDEMPOTENT (skips books that already
-- have a Syncery file) and ON-DEMAND only (never auto at startup).
--
-- Scan.scanSDR is NOT reusable here: it looks for *.syncery-progress.json
-- (books ALREADY synced) — the wrong set.
--
-- This file holds the disk walk + a dependency-injected `run` so the whole
-- thing is unit-testable (the walk against a real temp tree; `run` with fake
-- deps). The real deps (DocSettings:open, the bridge, state_store, a Trapper
-- progress dialog) are wired by the caller — see BulkIngest.make_real_deps /
-- main.lua. No KOReader-widget requires live here.
-- =============================================================================


local BulkIngest = {}

-- Don't recurse forever on pathological trees / symlink loops.
local MAX_DEPTH = 20


-- ---------------------------------------------------------------------------
-- Pure: reconstruct a book path from its sidecar dir + a metadata filename.
--   "/books/Moby Dick.sdr" + "metadata.epub.lua" -> "/books/Moby Dick.epub"
-- Returns nil if the inputs don't look like a KOReader sidecar pair.
-- ---------------------------------------------------------------------------
function BulkIngest.book_path_from_sdr(sdr_dir, metadata_filename)
    if type(sdr_dir) ~= "string" or type(metadata_filename) ~= "string" then
        return nil
    end
    local ext = metadata_filename:match("^metadata%.(.+)%.lua$")
    if not ext or ext == "" then return nil end
    local base = sdr_dir:gsub("%.sdr$", "")
    if base == sdr_dir then return nil end   -- not a .sdr directory
    return base .. "." .. ext
end


-- Look inside one .sdr directory for a native metadata.<ext>.lua and, if
-- found, return the reconstructed book path.
function BulkIngest._book_from_sdr_dir(sdr_full, lfs)
    local ok, iter, obj = pcall(lfs.dir, sdr_full)
    if not ok then return nil end
    for f in iter, obj do
        if type(f) == "string" and f:match("^metadata%..+%.lua$") then
            return BulkIngest.book_path_from_sdr(sdr_full, f)
        end
    end
    return nil
end


-- ---------------------------------------------------------------------------
-- Walk the configured roots for .sdr sidecars holding native annotations.
-- Returns a de-duplicated list of book paths (NOT Syncery files). `lfs` is
-- injectable for tests; defaults to KOReader's libkoreader-lfs.
--
-- Only books that EXIST on disk are returned (shared with
-- find_books_in_metadata_dir): the .sdr->book reconstruction is a guess that
-- is wrong inside KOReader's hash-metadata tree (hash-named .sdr dirs) and
-- stale when the book was deleted/moved. Ingesting a non-existent path would
-- write a duplicate/orphan sidecar, so it is skipped.
-- ---------------------------------------------------------------------------
function BulkIngest.find_sdr_books(roots, lfs, seen)
    lfs = lfs or require("libs/libkoreader-lfs")
    local out = {}
    seen = seen or {}

    local function walk(dir, depth)
        if depth > MAX_DEPTH then return end
        local ok, iter, obj = pcall(lfs.dir, dir)
        if not ok then return end
        for entry in iter, obj do
            if entry ~= "." and entry ~= ".." then
                local full = dir .. "/" .. entry
                if lfs.attributes(full, "mode") == "directory" then
                    if entry:match("%.sdr$") then
                        -- A sidecar dir: inspect it, but never descend into it.
                        local book = BulkIngest._book_from_sdr_dir(full, lfs)
                        -- Mirrors find_books_in_metadata_dir: only
                        -- ingest a book that actually EXISTS on disk. The .sdr ->
                        -- book reconstruction is a guess; it is WRONG when the
                        -- scanned root reaches KOReader's hash-metadata tree,
                        -- where each .sdr is named by content hash, not by book
                        -- path -- so "<hash>.sdr" reconstructs a "<hash>.<ext>"
                        -- that does not exist. Ingesting it opens DocSettings on
                        -- a synthetic path and writes a duplicate/orphan sidecar
                        -- there. The same guard also drops genuinely stale
                        -- sidecars (book deleted or moved). Both finders now
                        -- share the invariant: reconstruct, but ingest only what
                        -- is real on disk.
                        if book and not seen[book]
                                and lfs.attributes(book, "mode") == "file" then
                            seen[book] = true
                            out[#out + 1] = book
                        end
                    else
                        walk(full, depth + 1)
                    end
                end
            end
        end
    end

    for _, root in ipairs(roots or {}) do
        if type(root) == "string" and root ~= "" then walk(root, 0) end
    end
    return out
end


-- ---------------------------------------------------------------------------
-- Walk KOReader's "dir" metadata location for native annotations.
--
-- When the user's "Book metadata location" is set to "dir", KOReader keeps
-- sidecars NOT next to the book but mirrored under a fixed central tree
-- (`DataStorage:getDocSettingsDir()`), preserving the book's full path:
--     <DOCSETTINGS_DIR>/mnt/us/books/MyBook.sdr/metadata.epub.lua
-- The `.sdr` walk over the user's roots never sees these (they live under
-- the central tree, not beside the books), so those users get nothing from
-- the SDR scan.  This finds them.
--
-- Two things differ from find_sdr_books:
--   1. The root is FIXED (DOCSETTINGS_DIR), not the user's configured
--      Syncthing folders — so this works even with no roots configured.
--   2. The reconstructed path is DOCSETTINGS_DIR-rooted; we strip that
--      prefix to recover the REAL book path on disk.
--
-- We verify the real book still exists before returning it.
-- A stale sidecar (book deleted/moved) must NOT be ingested — opening a
-- non-existent path would at best yield nothing and at worst let
-- DocSettings create a junk sidecar.  Skipping keeps disk clean.
--
-- Returns real book paths (de-duplicated via `seen`, shared key space with
-- find_sdr_books so a book found by both walks appears once).
-- ---------------------------------------------------------------------------
function BulkIngest.find_books_in_metadata_dir(lfs, seen)
    lfs = lfs or require("libs/libkoreader-lfs")
    seen = seen or {}
    local out = {}

    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds or not DataStorage
            or type(DataStorage.getDocSettingsDir) ~= "function" then
        return out
    end
    local ok_dir, docsettings_dir = pcall(function()
        return DataStorage:getDocSettingsDir()
    end)
    if not ok_dir or type(docsettings_dir) ~= "string" or docsettings_dir == "" then
        return out
    end
    -- Normalise: ensure a single trailing slash for clean prefix stripping.
    local prefix = docsettings_dir:gsub("/+$", "") .. "/"

    local function walk(dir, depth)
        if depth > MAX_DEPTH then return end
        local ok, iter, obj = pcall(lfs.dir, dir)
        if not ok then return end
        for entry in iter, obj do
            if entry ~= "." and entry ~= ".." then
                local full = dir .. "/" .. entry
                if lfs.attributes(full, "mode") == "directory" then
                    if entry:match("%.sdr$") then
                        -- A sidecar dir under the central tree.  Reconstruct
                        -- the DOCSETTINGS_DIR-rooted book path, then strip the
                        -- prefix to get the real on-disk path.
                        local rooted = BulkIngest._book_from_sdr_dir(full, lfs)
                        if rooted and rooted:sub(1, #prefix) == prefix then
                            local real = "/" .. rooted:sub(#prefix + 1)
                            -- 2a: only ingest if the real book still exists.
                            if not seen[real]
                                    and lfs.attributes(real, "mode") == "file" then
                                seen[real] = true
                                out[#out + 1] = real
                            end
                        end
                    else
                        walk(full, depth + 1)
                    end
                end
            end
        end
    end

    walk(prefix:gsub("/+$", ""), 0)
    return out
end


-- ---------------------------------------------------------------------------
-- Dependency-injected runner. Iterates the books and ingests each one.
--
-- `deps`:
--   find_books()              -> { book_path, ... }
--   already_ingested(path)    -> bool     (Syncery JSON already on disk)
--   open_ui(path)             -> ui|nil   ({doc_settings=ds}); nil = error
--   read_map(ui)              -> map      (keyed annotation map; {} = none)
--   stamp(map)                -> map      (optional; device stamping)
--   write_initial(path, map, ui) -> bool    (write Syncery JSON envelope;
--                                            ui is the opened DocSettings so
--                                            the writer can also capture native
--                                            metadata + render, not just annotations)
--   on_progress(i,total,outcome,path)     (optional)
--
-- Per-book outcome: "skipped_existing" | "skipped_empty" | "ingested" | "error".
-- Returns a summary { total, ingested, skipped_existing, skipped_empty, errors }.
-- ---------------------------------------------------------------------------
function BulkIngest.run(deps)
    local books = deps.find_books() or {}
    local summary = {
        total            = #books,
        ingested         = 0,
        skipped_existing = 0,
        skipped_empty    = 0,
        errors           = 0,
    }

    for i, book in ipairs(books) do
        local outcome

        if deps.already_ingested(book) then
            outcome = "skipped_existing"
            summary.skipped_existing = summary.skipped_existing + 1
        else
            local ui = deps.open_ui(book)
            if not ui then
                outcome = "error"
                summary.errors = summary.errors + 1
            else
                local map = deps.read_map(ui)
                if not map or next(map) == nil then
                    outcome = "skipped_empty"
                    summary.skipped_empty = summary.skipped_empty + 1
                else
                    if deps.stamp then map = deps.stamp(map) end
                    local ok = deps.write_initial(book, map, ui)
                    if ok then
                        outcome = "ingested"
                        summary.ingested = summary.ingested + 1
                    else
                        outcome = "error"
                        summary.errors = summary.errors + 1
                    end
                end
            end
        end

        if deps.on_progress then
            pcall(deps.on_progress, i, summary.total, outcome, book)
        end
    end

    return summary
end


return BulkIngest
