-- =============================================================================
-- syncery_progress/paths.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- It computes the on-disk paths for all of Syncery's progress-related
-- files (the "reading position" subsystem).  Two files per book:
--
--   1. SHARED (sync'd by Syncthing/cloud — visible to other devices)
--        SDR mode  : <book>.sdr/<book>.syncery-progress.json
--        Hash mode : <state_dir>/<book_md5>/syncery-progress.json
--
--   2. LOCAL ONLY (NEVER sync'd, the 3-way merge ancestor)
--        <state_dir>/last_sync/<book_md5>/progress.last-sync.json
--
-- Plus one device-local, non-per-book file:
--
--   3. SYNC JOURNAL (device-local, NEVER sync'd, append-only)
--        <state_dir>/sync-journal.ndjson
--      The diagnostic merge-event record — see sync_journal.lua.
--
-- Same shape as `syncery_ann/paths.lua`, just for the progress file
-- instead of the annotations file.
--
--
-- WHY THE SHARED FILE KEEPS ITS LEGACY NAME (NO `.v2` SUFFIX)
--
-- The annotation engine chose `.v2.json` to coexist with the legacy
-- engine's data on disk — annotations had a real schema change.
-- Progress has no schema change: the file is still
-- `{ [device_id] = { revision, percent, timestamp, ... } }` exactly
-- as the legacy code wrote it.  Reusing the same path means the new
-- engine reads the legacy file directly, no migration step needed.
--
--
-- WHY WE REACH INTO syncery_ann/paths.lua FOR DIRECTORY HELPERS
--
-- The helpers for "find Syncery's state dir", "compute the book's
-- content hash", and "mkdir -p" already live in `syncery_ann/paths.lua`
-- (since annotations got built first).  Duplicating them here would
-- double the maintenance burden.  Re-exporting them through a shared
-- `syncery_core/` module is the right long-term move, a future
-- cleanup.  Until then, we deliberately call across
-- module boundaries; the helpers are exposed on the `Paths` table
-- by name (underscore-prefix means "internal" by convention, not by
-- enforcement).
--
-- =============================================================================

local AnnPaths = require("syncery_ann/paths")
local lfs      = require("libs/libkoreader-lfs")
local logger   = require("logger")

local Paths = {}


-- ----------------------------------------------------------------------------
-- Public constants
--
-- `SHARED_FILE_EXTENSION` is the suffix used by the shared progress file
-- in SDR mode (`<book>.syncery-progress.json`).  Exposed as a public
-- constant so callers like the orphan-sweep maintenance tool can pattern-
-- match progress files on disk without hard-coding the string in multiple
-- places.  Hash mode does NOT use this extension — it writes a fixed
-- filename (`progress.json`) inside the per-book hash directory.
-- ----------------------------------------------------------------------------

Paths.SHARED_FILE_EXTENSION = ".syncery-progress.json"


-- ----------------------------------------------------------------------------
-- Storage mode.  Shared with syncery_ann/paths.lua via
-- syncery_storage_mode.lua — see that module's header for the full
-- rationale.  These two functions are thin delegators that exist so
-- existing call sites (main.lua, tests) keep working without changes.
-- ----------------------------------------------------------------------------

local StorageMode = require("syncery_storage_mode")


--- Tell the plugin which storage mode is currently active.
---
--- @param mode string Either "sdr" or "hash".  Anything else falls back to "sdr".
function Paths.set_storage_mode(mode)
    StorageMode.set(mode)
end


--- Read the current storage mode.
---
--- @return string Either "sdr" or "hash".
function Paths.get_storage_mode()
    return StorageMode.get()
end


-- ----------------------------------------------------------------------------
-- File path computation
-- ----------------------------------------------------------------------------


--- Compute the path to a book's "shared" progress JSON file.
---
--- This is the file that gets synchronized between devices.  Layout:
---   * SDR mode  : sidecar directory, filename includes the book name
---     so multiple books in the same folder don't collide.
---   * Hash mode : per-book subdirectory under Syncery's state dir,
---     with the name "syncery-progress.json" (the `syncery-` infix keeps
---     it distinguishable in name-based ignore patterns; the dir gives
---     book-to-book uniqueness).
---
--- @param book_path string Absolute path to the book file.
--- @return string|nil The path, or nil on error.
function Paths.shared_progress_path(book_path)
    if not book_path or book_path == "" then
        return nil
    end

    if StorageMode.get() == "hash" then
        local book_dir = AnnPaths._shared_book_state_dir(book_path)
        if not book_dir then return nil end
        return book_dir .. "/syncery-progress.json"
    end

    -- SDR mode.
    local sidecar_dir = AnnPaths._sidecar_dir_for_book(book_path)
    if not sidecar_dir then return nil end
    local book_filename = book_path:match("([^/\\]+)$") or "book"
    return sidecar_dir .. "/" .. book_filename .. ".syncery-progress.json"
end


--- The progress path to READ from.  See the rationale on
--- `AnnPaths.shared_annotations_path_for_read`: writes stay on the
--- canonical location, but if the user changes "Book metadata location"
--- the old file would otherwise become invisible.  In SDR mode this
--- checks all sidecar locations and returns the first that exists; in
--- hash mode it equals `shared_progress_path`.  Read-only — moves
--- nothing.
---
--- @param book_path string Absolute path to the book file.
--- @return string|nil The path to read from (canonical if none exist yet).
function Paths.shared_progress_path_for_read(book_path)
    local canonical = Paths.shared_progress_path(book_path)
    if StorageMode.get() == "hash" then return canonical end
    return AnnPaths._first_existing_sidecar_file(
        book_path, ".syncery-progress.json", canonical)
end


--- Compute the path to a book's "last-sync" progress file.
---
--- Always lives in Syncery's private state directory, keyed by the
--- book's content hash.  Never shared with other devices.
---
--- @param book_path string Absolute path to the book file.
--- @return string|nil The path, or nil on error.
function Paths.last_sync_progress_path(book_path)
    if not book_path or book_path == "" then
        return nil
    end

    local book_id = AnnPaths._book_content_id(book_path)
    if not book_id then return nil end

    local last_sync_dir = AnnPaths._syncery_state_dir()
                       .. "/last_sync/"
                       .. book_id

    -- mkdir -p the whole chain.  See the comment in AnnPaths for why
    -- this matters specifically in SDR mode (the default).
    AnnPaths._ensure_directory_exists(last_sync_dir)
    return last_sync_dir .. "/progress.last-sync.json"
end


--- Compute the path to the device-local sync journal file.
---
--- The journal (see syncery_progress/sync_journal.lua) is a
--- device-local, append-only diagnostic record of merge events.  It
--- is DELIBERATELY NOT a per-book file and DELIBERATELY NOT synced:
---
---   * NOT synced — it lives directly under Syncery's private state
---     directory, the same place the last-sync ancestors live.  That
---     directory is never replicated by Syncthing.  A synced journal
---     would itself become a sync-conflict surface, defeating its
---     purpose as a diagnostic tool.  This is the same device-local
---     guarantee `last_sync_progress_path` relies on, just at the
---     state-dir root rather than under `last_sync/<hash>/`.
---
---   * NOT per-book — it is a single append-only file recording merge
---     events across all books, each entry carrying its own `book_id`.
---     One file keeps the writer a pure append (no per-book path
---     resolution on the hot path) and matches how the eventual UI
---     wants to read it ("recent sync history", filterable by book).
---
--- Unlike the path builders above this takes no book argument and is
--- storage-mode-independent: the journal is about the DEVICE, not any
--- one book.
---
--- @return string|nil The journal file path, or nil if the state dir
---                     could not be resolved.
function Paths.sync_journal_path()
    local state_dir = AnnPaths._syncery_state_dir()
    if not state_dir or state_dir == "" then return nil end

    -- Ensure the state dir exists.  On a fresh SDR-mode install
    -- nothing else has created `<settings>/syncery` yet — the same
    -- fresh-install gap `last_sync_progress_path` guards against.
    AnnPaths._ensure_directory_exists(state_dir)
    return state_dir .. "/sync-journal.ndjson"
end


return Paths
