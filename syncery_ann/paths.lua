-- =============================================================================
-- syncery_ann/paths.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- It computes the on-disk paths for all of Syncery's annotation-related
-- files.  Centralized here so the rest of the annotation subsystem
-- doesn't need to know about storage modes, sidecar directories, or
-- the difference between "files that sync" and "files that stay local".
--
--
-- THREE FILE LOCATIONS PER BOOK
--
-- For each book, Syncery uses two storage areas:
--
--   1. SHARED (sync'd by Syncthing/cloud — visible to other devices)
--        SDR mode  : <book>.sdr/<book>.syncery-annotations.json
--        Hash mode : <state_dir>/<book_md5>/syncery-annotations.json
--
--   2. LOCAL ONLY (NEVER sync'd, lives in Syncery's own state folder)
--        <state_dir>/last_sync/<book_md5>/annotations.last-sync.json
--
-- The "shared" file is what other devices see.  The "last-sync" file
-- is the 3-way merge ancestor, kept private to each device.
--
--
-- WHY LAST-SYNC IS NEVER SHARED
--
-- The last-sync file represents "what THIS device knew about at its
-- last sync".  Each device has its own answer — device B's last-sync
-- is not relevant to device A.  Sharing them would be both pointless
-- and harmful (devices would overwrite each other's last-sync state).
--
-- By placing last-sync OUTSIDE the Syncthing folder, we ensure
-- Syncthing simply never sees these files.  No .stignore needed, no
-- chance of user misconfiguration, no special handling.
--
-- =============================================================================

local DataStorage = require("datastorage")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")

local Paths = {}


-- ----------------------------------------------------------------------------
-- The storage mode is "sdr" or "hash".  Both subsystems (annotations
-- and progress) share a single source of truth in `syncery_storage_mode`;
-- this module's set_storage_mode / get_storage_mode are thin delegators
-- preserved so existing call sites (main.lua, tests) keep working.
--
-- Why centralize: see syncery_storage_mode.lua header.  Short version:
-- annotations and progress must always agree on the mode.  Centralizing
-- it means there is no second copy to fall out of sync -- separate copies
-- updated in adjacent calls would silently corrupt data on a missed update.
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


--- Compute the path to a book's "shared" annotations JSON file.
---
--- This is the file that gets synchronized between devices.  Its
--- location depends on the current storage mode:
---   * SDR mode: lives in the book's sidecar directory, with a name
---     that includes the book's filename (so multiple books in the
---     same directory don't conflict).
---   * Hash mode: lives in a per-book subdirectory of Syncery's
---     state directory, with a name ("syncery-annotations.json") whose `syncery-` infix
---     keeps it distinguishable in name-based ignore patterns; the directory
---     the directory already provides uniqueness.
---
--- FILENAME
---
--- The file is `<book>.syncery-annotations.json` (SDR) /
--- `syncery-annotations.json` (hash) — the canonical name.
---
--- @param book_path string Absolute path to the book file (e.g. "/sdcard/foo.epub").
--- @return string|nil The path to the shared annotations file, or nil on error.
function Paths.shared_annotations_path(book_path)
    if not book_path or book_path == "" then
        return nil
    end

    if StorageMode.get() == "hash" then
        local book_dir = Paths._shared_book_state_dir(book_path)
        if not book_dir then return nil end
        return book_dir .. "/syncery-annotations.json"
    end

    -- SDR mode.
    local sidecar_dir = Paths._sidecar_dir_for_book(book_path)
    if not sidecar_dir then return nil end
    local book_filename = book_path:match("([^/\\]+)$") or "book"
    return sidecar_dir .. "/" .. book_filename .. ".syncery-annotations.json"
end


--- The annotations path to READ from.
---
--- Writes always go to the canonical `shared_annotations_path` (the
--- user's current "Book metadata location").  But if the user CHANGES
--- that setting, files written under the old location become invisible
--- — KOReader's getSidecarDir now points elsewhere, and the book looks
--- like it has no Syncery data even though it does.
---
--- This resolver mirrors KOReader's own "ordered location candidates"
--- idea: in SDR mode it checks the canonical location first, then the
--- other sidecar locations (doc / dir / hash), and returns the first
--- file that actually exists.  It is READ-ONLY — it never moves or
--- writes anything, so there is no risk of duplicating or losing data;
--- a later save still lands in the canonical location, which naturally
--- re-homes the book over time.
---
--- In hash mode there is only one location (synceryhash/), so this is
--- identical to `shared_annotations_path`.
---
--- @param book_path string Absolute path to the book file.
--- @return string|nil The path to read from (canonical if none exist yet).
function Paths.shared_annotations_path_for_read(book_path)
    local canonical = Paths.shared_annotations_path(book_path)
    if StorageMode.get() == "hash" then return canonical end
    return Paths._first_existing_sidecar_file(
        book_path, ".syncery-annotations.json", canonical)
end


--- SDR-mode helper: among the doc/dir/hash sidecar locations, return the
--- first that contains `<book>.<suffix>`.  Falls back to `canonical`
--- when none exist yet (a fresh book).  Pure lookup; touches nothing.
---
--- Order matters: the CANONICAL (write) location is checked FIRST.  This
--- prevents a staleness trap — once a save has re-homed the data to the
--- canonical location, a leftover copy in the old location must never be
--- read again.  Checking canonical first guarantees the freshest copy
--- wins; the stale leftover is simply ignored forever (a harmless
--- orphan the user can clean up).  We only fall through to the other
--- locations when canonical does NOT yet exist (i.e. right after the
--- user changed the setting, before the next save).
---
--- @param book_path string Absolute path to the book file.
--- @param suffix string e.g. ".syncery-annotations.json".
--- @param canonical string The default path to return if no file exists.
--- @return string The path to read from.
function Paths._first_existing_sidecar_file(book_path, suffix, canonical)
    -- Canonical first: if the freshest (last-written) copy is there, use
    -- it and never look at stale leftovers in other locations.
    if lfs.attributes(canonical, "mode") == "file" then
        return canonical
    end

    local docsettings = require("docsettings")
    if not docsettings or not docsettings.getSidecarDir then
        return canonical
    end
    local book_filename = book_path:match("([^/\\]+)$") or "book"
    -- Canonical didn't exist; check the other sidecar locations (deduped,
    -- and skipping any that resolve back to canonical).
    local seen, candidates = { [canonical] = true }, {}
    local function add(dir)
        if dir and dir ~= "" then
            local path = dir .. "/" .. book_filename .. suffix
            if not seen[path] then
                seen[path] = true
                candidates[#candidates + 1] = path
            end
        end
    end
    for _, loc in ipairs({ "doc", "dir", "hash" }) do
        local ok, dir = pcall(function()
            return docsettings:getSidecarDir(book_path, loc)
        end)
        if ok then add(dir) end
    end
    for _, path in ipairs(candidates) do
        if lfs.attributes(path, "mode") == "file" then
            return path
        end
    end
    return canonical
end



--- Compute the path to a book's "last-sync" annotations file.
---
--- This file is NEVER shared with other devices.  It always lives in
--- Syncery's private state directory, keyed by the book's content
--- hash (so it survives the user renaming or moving the book).
---
--- @param book_path string Absolute path to the book file.
--- @return string|nil The path to the last-sync file, or nil on error.
function Paths.last_sync_annotations_path(book_path)
    if not book_path or book_path == "" then
        return nil
    end

    local book_id = Paths._book_content_id(book_path)
    if not book_id then return nil end

    local last_sync_dir = Paths._syncery_state_dir()
                       .. "/last_sync/"
                       .. book_id

    Paths._ensure_directory_exists(last_sync_dir)
    return last_sync_dir .. "/annotations.last-sync.json"
end


-- ----------------------------------------------------------------------------
-- Internal helpers
-- ----------------------------------------------------------------------------


--- Get Syncery's state directory (where private files live, AND
--- where hash-mode storage roots its per-book directories).
---
--- Delegates to syncery_storage_mode so the value can be user-chosen.
--- See that module's `get_hash_root` for the rationale and defaults.
---
--- @return string The state directory path (no trailing slash).
function Paths._syncery_state_dir()
    return StorageMode.get_hash_root()
end


--- Get the per-book directory for SHARED, replicate-everywhere files
--- (annotations.json / progress.json) in hash mode.
---
--- These files live under a dedicated `synceryhash/` subdirectory so that
--- replicating the whole hash root (a reasonable thing for a user to
--- do with Syncthing) carries ONLY the cross-device data and not the
--- device-local diagnostics that sit at the hash-root top level
--- (`last_sync/`, `sync-journal.ndjson`, `syncery_activity.json`,
--- `cloud_staging/`).
---
--- @param book_path string Absolute path to the book.
--- @return string|nil The per-book shared directory path.
function Paths._shared_book_state_dir(book_path)
    local book_id = Paths._book_content_id(book_path)
    if not book_id then return nil end
    -- Shard by the first 2 hex chars of the id, the same way KOReader
    -- shards its own hashdocsettings/ tree: a flat synceryhash/ with one
    -- subdir per book becomes thousands of entries in a single directory
    -- for a large library, which slows directory operations (lookup and
    -- enumeration) on some filesystems (FAT/SD, older e-readers).  Two
    -- hex chars spread books across up to 256 buckets, keeping each
    -- directory listing short.  `_ensure_directory_exists` is recursive
    -- (mkdir -p), so the extra parent level needs no special handling.
    local shard = book_id:sub(1, 2)
    local dir = Paths._syncery_state_dir() .. "/synceryhash/" .. shard .. "/" .. book_id
    Paths._ensure_directory_exists(dir)
    return dir
end


--- Compute the content-based ID for a book.
---
--- KOReader caches the partial MD5 of each book's content in
--- doc_settings under "partial_md5_checksum".  This ID is stable
--- across devices (same file = same hash) and across file renames
--- (a moved book keeps its ID).
---
--- Falls back to KOReader's util.partialMD5 if the cached value is
--- not available.  As a last resort, hashes the basename — this
--- will not match across devices but is at least deterministic
--- locally.
---
--- @param book_path string Absolute path to the book.
--- @return string|nil The book's content ID (40-char hex), or nil.
function Paths._book_content_id(book_path)
    -- Try the cached value via the active document's doc_settings.
    -- This is the cheapest path and produces an identical answer to
    -- partialMD5 once KOReader has opened the book.
    local doc_settings_module = package.loaded.docsettings
                              or require("docsettings")
    if doc_settings_module and doc_settings_module.open then
        local ok, doc_settings = pcall(doc_settings_module.open, doc_settings_module, book_path)
        if ok and doc_settings then
            local cached = doc_settings:readSetting("partial_md5_checksum")
            if cached and cached ~= "" then
                return cached
            end
        end
    end

    -- Fall through: compute the partial MD5 ourselves.
    local ok_util, util_module = pcall(require, "util")
    if ok_util and util_module and type(util_module.partialMD5) == "function" then
        local checksum = util_module.partialMD5(book_path)
        if checksum and checksum ~= "" then
            return checksum
        end
    end

    -- Last resort.  Won't match across devices.
    --
    -- This is a SILENT correctness trap: a basename-derived id differs
    -- from device to device (filenames differ), so this book will sync
    -- to nobody — yet nothing visibly fails.  paths.lua has no UI (it is
    -- pure string logic), so instead of showing anything here we RECORD
    -- the book and expose `had_basename_fallback()`; the UI layer
    -- (onReaderReady) surfaces it once per book.  Recording is keyed by
    -- book_path so repeated path-builder calls for the same book don't
    -- pile up.
    Paths._basename_fallback_books = Paths._basename_fallback_books or {}
    Paths._basename_fallback_books[book_path] = true
    local md5_module = require("ffi/sha2")
    local basename = book_path:match("([^/\\]+)$") or book_path
    logger.warn("Syncery paths: falling back to basename-based book id for "
        .. tostring(book_path) .. " — sync across devices will not work")
    return md5_module.md5(basename)
end


--- Remove a directory ONLY if Syncery owns it.
---
--- "Owns" means the directory lives under Syncery's own state dir (the
--- `synceryhash/` tree in hash mode).  It is explicitly NOT a KOReader
--- `.sdr` sidecar: in SDR mode Syncery's JSON lives INSIDE the book's
--- `.sdr`, alongside KOReader's own metadata.lua and cover image, so
--- deleting that directory would destroy data Syncery does not own.
--- KOReader removes a `.sdr` only because IT owns the whole folder; we
--- must not.  In SDR mode we delete only our individual files and leave
--- the `.sdr` for KOReader to clean up.
---
--- This is a guard rail: callers that have removed Syncery's files and
--- want to tidy the now-empty directory should route through here so the
--- "is it mine?" check can never be accidentally skipped by future code.
---
--- @param dir string The directory to remove.
--- @return boolean True if the directory was owned and removal attempted.
function Paths.remove_owned_directory(dir)
    if not dir or dir == "" then return false end
    local state_dir = Paths._syncery_state_dir()
    if not state_dir or state_dir == "" then return false end
    -- Must be strictly under our state dir, and specifically inside the
    -- synceryhash/ subtree (never the state dir root itself, which holds
    -- last_sync/ and cloud_staging/ siblings).  Sharded per-book dirs
    -- (synceryhash/<shard>/<id>/) still carry this prefix, so the check
    -- covers them; we deliberately leave the now-empty <shard>/ bucket in
    -- place (a harmless empty dir — removing it would add races for no
    -- real benefit).
    local owned_root = state_dir .. "/synceryhash/"
    if dir:sub(1, #owned_root) ~= owned_root then
        logger.warn("Syncery: refusing to remove non-owned directory "
            .. tostring(dir) .. " (not under " .. owned_root .. ")")
        return false
    end
    os.remove(dir)
    return true
end
--- basename-derived id for this book during this session (i.e. neither
--- the cached partial_md5_checksum nor a live partialMD5 was available).
--- The UI uses this to warn the user that the book cannot sync across
--- devices.  Read-only; never clears itself.
function Paths.had_basename_fallback(book_path)
    return Paths._basename_fallback_books ~= nil
        and Paths._basename_fallback_books[book_path] == true
end


--- Get the sidecar directory for a book (the .sdr folder KOReader uses).
---
--- This delegates to KOReader's docsettings module, which respects
--- the user's "Book metadata location" preference (doc / dir / hash).
---
--- @param book_path string Absolute path to the book.
--- @return string|nil The sidecar directory.
function Paths._sidecar_dir_for_book(book_path)
    local docsettings = require("docsettings")
    if not docsettings or not docsettings.getSidecarDir then
        return nil
    end
    return docsettings:getSidecarDir(book_path)
end


--- Make sure a directory exists, creating it (and ALL missing parents)
--- if needed.  Semantics: `mkdir -p`.
---
--- We need full recursion (not just one level up) because in SDR mode
--- — which is Syncery's default — `<settings>/syncery` is never the
--- target of any other mkdir; `save_shared` puts the JSON in the .sdr
--- sidecar instead.  Without recursion, `last_sync_annotations_path`
--- (whose target is `<settings>/syncery/last_sync/<hash>`, three levels
--- deep) would silently fail on a fresh install, breaking 3-way merge.
---
--- Best-effort: errors are logged but not raised, since path creation
--- failures are usually filesystem-level issues we can't recover from
--- anyway.
---
--- @param directory_path string The directory to ensure.
function Paths._ensure_directory_exists(directory_path)
    if not directory_path or directory_path == "" then return end

    local mode = lfs.attributes(directory_path, "mode")
    if mode == "directory" then return end

    -- Make the parent first.  Recursing here (rather than a single
    -- mkdir) means we handle arbitrarily deep paths correctly: each
    -- frame strips the trailing component, so the chain terminates
    -- at the first existing directory or at the path root.
    local parent = directory_path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then
        Paths._ensure_directory_exists(parent)
    end

    local ok, err = lfs.mkdir(directory_path)
    if not ok and lfs.attributes(directory_path, "mode") ~= "directory" then
        logger.warn("Syncery paths: failed to create " .. tostring(directory_path)
            .. ": " .. tostring(err))
    end
end


return Paths
