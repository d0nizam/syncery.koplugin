-- =============================================================================
-- syncery_ui/booklist/scan.lua
-- =============================================================================
--
-- The disk-scan half of the "Manage all books" feature: a clean,
-- side-effect-light unit (it reads the filesystem and builds a `books`
-- list; it shows no menus of its own).
--
-- PUBLIC SURFACE
--
--   Scan.getScanRoots()              — Syncthing folder paths to scan
--   Scan.promptForScanRoot(callback) — ask WHERE to scan (visual picker)
--   Scan.scanHash(books)             — hash-mode scan (appends to `books`)
--   Scan.scanSDR(roots, books)       — SDR-mode synchronous scan
--
-- These match the `BookList.*` signatures the orchestrator
-- (`booklist/init.lua`) and the migration tool expect, so callers
-- need no changes.
--
-- The two module-local helpers `load_json` / `book_path_from_sdr_
-- progress` moved here with the scan because nothing else uses them.
--
-- =============================================================================


local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox  = require("ui/widget/confirmbox")
local PathChooser = require("ui/widget/pathchooser")
local Device      = require("device")
local ffiUtil     = require("ffi/util")
local joinPath    = ffiUtil.joinPath
local Trapper     = require("ui/trapper")

local lfs      = require("libs/libkoreader-lfs")
local json     = require("rapidjson")
local Util     = require("syncery_util")
local util     = require("util")
local AnnPaths = require("syncery_ann/paths")
local HashLocationFinder = require("syncery_ann/hash_location_finder")
local Settings = require("syncery_settings")
local I18n     = require("syncery_i18n")
local _        = I18n.translate


local Scan = {}


-- ============================================================================
-- Helpers
-- ============================================================================


-- Load JSON from path, returning table or nil
local function load_json(path)
    if not path then return nil end
    local f = io.open(path, "r")
    if not f then return nil end
    local raw = f:read("*a"); f:close()
    if not raw or raw == "" then return nil end
    local ok, data = pcall(json.decode, raw)
    return (ok and type(data) == "table") and data or nil
end


local function book_path_from_sdr_progress(progress_path)
    -- Accepts either Syncery sync file (progress OR annotations).  An
    -- annotations-only book (progress sync off) has only the annotations file,
    -- whose basename carries the same book name, so the same derivation works.
    -- KOReader has no single util.splitFilePath; the author's intended
    -- (dir, name-without-ext, ext) is the composition of splitFilePathName
    -- (path -> dir, filename-with-ext) then splitFileNameSuffix
    -- (filename -> name, ext). After this, name is e.g.
    -- "My Book.syncery-progress" and file_ext is "json" — matching the
    -- original comment.
    local dir, filename = util.splitFilePathName(progress_path)
    local name, file_ext = util.splitFileNameSuffix(filename)
    local book_name = name:gsub("%.syncery%-progress$", ""):gsub("%.syncery%-annotations$", "")
    if book_name == name then return nil end       -- not a Syncery sync file

    -- If inside a .sdr folder, go up one level to get the book's parent directory.
    local sdr_match = dir:match("([^/\\]+)%.sdr[/\\]?$")
    if sdr_match then
        local parent_dir = dir:gsub("[^/\\]+%.sdr[/\\]?$", "")
        return parent_dir .. book_name              -- no extension (matches original)
    end
    return dir .. book_name                          -- no extension
end


-- Exposed for specs (these are the trickier pure functions).
Scan._load_json                  = load_json
Scan._book_path_from_sdr_progress = book_path_from_sdr_progress


-- Read the REAL book path (with its extension) from a Syncery progress file's
-- entries.  Syncery wrote the absolute book path inside; the `.sdr`-name
-- reconstruction above deliberately drops the extension ("matches original"),
-- which is fine for a display label but WRONG for anything that re-derives a
-- path-keyed identity — most importantly migration's synceryhash destination,
-- whose partial-MD5 hash is computed from the book path.  An extension-less
-- "MyBook" hashes differently from the real "MyBook.epub", so the migrated
-- files would land under a bogus hash dir while the rest of Syncery (using the
-- real path) looks elsewhere — files appear to vanish.  So prefer the path
-- from inside the JSON; the caller falls back to the reconstruction only when
-- the JSON carries no usable file entry (corrupt/empty).
local function book_file_from_progress_json(progress_path)
    local data = load_json(progress_path)
    if type(data) ~= "table" then return nil end
    local entries = data.entries
    if type(entries) ~= "table" then return nil end
    for _, entry in pairs(entries) do
        if type(entry) == "table" and type(entry.file) == "string"
                and entry.file ~= "" then
            return entry.file
        end
    end
    return nil
end

Scan._book_file_from_progress_json = book_file_from_progress_json


-- Display label for a book row: the filename WITHOUT its extension.  This
-- matches scanHash and HashLocationFinder.make_sdr_processor, so the same
-- book shows with an identical label no matter which scan path surfaced it
-- (the root-walk here, the hash/dir finders, or scanHash).  `fallback` is
-- used when there is no resolvable book file.
local function display_label(book_file, fallback)
    if not book_file then return fallback end
    local name = book_file:match("([^/\\]+)$") or book_file
    name = name:gsub("%.[^%.\\/]+$", "")
    if name ~= "" then return name end
    return fallback
end

Scan._display_label = display_label


-- ============================================================================
-- getScanRoots — Syncthing folder paths
-- ============================================================================


function Scan.getScanRoots()
    local folder = Settings.get_syncthing_folder()
    local roots = {}
    if folder and type(folder.path) == "string" and folder.path ~= "" then
        table.insert(roots, folder.path)
    end
    return roots
end


-- ============================================================================
-- deriveRootsFromHistory — candidate scan roots from KOReader's history
-- ============================================================================
--
-- For the "doc" metadata case, Syncery's *.syncery-progress.json sit BESIDE
-- the books, scattered across the filesystem — there is no fixed tree to
-- enumerate.  KOReader's history records recently-opened book PATHS, and the
-- FOLDER of each is a place a user keeps books.  We don't need the (capped)
-- book list itself — we need the folders: a root-walk over them finds EVERY
-- Syncery file there, including books beyond the history cap or synced from
-- another device but living in the same folder.
--
-- We read `history.lua` DIRECTLY (a flat `{ {time, file}, ... }` written by
-- ReadHistory:_flush), NOT via the ReadHistory singleton — we want the raw
-- paths, not its in-memory state/dim-flags.  Returns a de-duplicated list of
-- existing directory paths, the same shape as getScanRoots.
function Scan.deriveRootsFromHistory()
    local roots, seen = {}, {}

    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds or not DataStorage
            or type(DataStorage.getDataDir) ~= "function" then
        return roots
    end
    local ok_dir, data_dir = pcall(function() return DataStorage:getDataDir() end)
    if not ok_dir or type(data_dir) ~= "string" or data_dir == "" then
        return roots
    end

    local history_path = data_dir .. "/history.lua"
    if lfs.attributes(history_path, "mode") ~= "file" then return roots end

    local ok_load, hist = pcall(dofile, history_path)
    if not ok_load or type(hist) ~= "table" then return roots end

    for _, entry in ipairs(hist) do
        local file = type(entry) == "table" and entry.file
        if type(file) == "string" and file ~= "" then
            local folder = file:match("^(.*)/[^/]*$")
            if folder and folder ~= "" and not seen[folder]
                    and lfs.attributes(folder, "mode") == "directory" then
                seen[folder] = true
                roots[#roots + 1] = folder
            end
        end
    end

    return roots
end


-- ============================================================================
-- promptForScanRoot — choose WHERE to scan when no Syncthing folders are set
--
-- The old flow dropped the user into a raw text field prefilled with a
-- Kindle-only path ("/mnt/us/books") and made them type a directory by hand.
-- That is the wrong tool: hard to type on e-ink, and the prefill is wrong on
-- Kobo / PocketBook / Android. Instead, offer concrete choices:
--
--   1. Browse for a folder   — a visual PathChooser (no typing).
--   2. KOReader metadata folder — the central DocSettings dir, which always
--      exists and is where "dir" metadata-location sidecars live; no typing.
--   3. Cancel.
--
-- `callback(roots)` receives a one-element list of absolute paths (the
-- scan-roots contract: the booklist orchestrator feeds the result straight
-- into the root-walk).
-- ============================================================================


--- Resolve KOReader's central doc-settings directory, or nil if unavailable.
local function koreader_metadata_dir()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds or not DataStorage
            or type(DataStorage.getDocSettingsDir) ~= "function" then
        return nil
    end
    local ok_dir, dir = pcall(function() return DataStorage:getDocSettingsDir() end)
    if ok_dir and dir and dir ~= "" then return dir end
    return nil
end


function Scan.promptForScanRoot(callback)
    local function browse()
        local start_path = (Device and Device.home_dir)
            or (lfs.attributes("/mnt/us", "mode") == "directory" and "/mnt/us")
            or "/"
        UIManager:show(PathChooser:new{
            select_directory = true,
            select_file      = false,
            path             = start_path,
            onConfirm        = function(dir_path)
                if dir_path and lfs.attributes(dir_path, "mode") == "directory" then
                    callback({ dir_path })
                else
                    UIManager:show(InfoMessage:new{
                        text = _("Invalid directory."), timeout = 3 })
                end
            end,
        })
    end

    local meta_dir = koreader_metadata_dir()

    UIManager:show(ConfirmBox:new{
        text = _(
            "Syncery couldn't find your synced books automatically.\n\n"
            .. "Where should it look for synced book data?"),
        -- OK = browse (visual picker, works everywhere).
        ok_text     = _("Browse for folder"),
        ok_callback = browse,
        -- A second button for the always-present KOReader metadata folder,
        -- shown only when that directory is resolvable.
        other_buttons = meta_dir and {{
            {
                text     = _("KOReader metadata folder"),
                callback = function() callback({ meta_dir }) end,
            },
        }} or nil,
        cancel_text = _("Cancel"),
    })
end


-- ============================================================================
-- scanHash — hash-mode scan
-- ============================================================================


function Scan.scanHash(books)
    -- Shared per-book files (progress.json / annotations.json) live
    -- under <hash_root>/synceryhash/<shard>/<book_id>/, where <shard> is
    -- the first 2 hex chars of the id (see Paths._shared_book_state_dir
    -- for why we shard).  (The `synceryhash/` subdirectory uses a unique
    -- name — not a generic `shared/` — so it is unmistakable in a
    -- Syncthing folder list when a user syncs it.)  Scan there, not the
    -- hash-root top level (which also holds device-local dirs like
    -- last_sync/ and cloud_staging/).
    --
    -- Use the SAME hash-root source as the writers
    -- (AnnPaths._syncery_state_dir == StorageMode.get_hash_root).
    local hash_dir = joinPath(AnnPaths._syncery_state_dir(), "synceryhash")
    local ok_dir, iter, obj = pcall(lfs.dir, hash_dir)
    -- NOTE: synceryhash/ exists only in Syncery hash STORAGE mode.  An
    -- SDR-storage user has no synceryhash/ — but may still have Syncery
    -- files under KOReader's hashdocsettings/ (handled below).  So a
    -- missing synceryhash/ must NOT abort the function; it only skips the
    -- synceryhash walk.  (This early-return was the bug behind SDR +
    -- KOReader-hash users seeing "No synced books found".)
    local count = 0

    -- Process one per-book directory (the leaf `<book_id>/`).  Returns
    -- true if it was a Syncery book dir (had a progress file).
    local function process_book_dir(full, entry)
        if lfs.attributes(full, "mode") ~= "directory" then return false end
        local progress_path = joinPath(full, "syncery-progress.json")
        local ann_path      = joinPath(full, "syncery-annotations.json")
        local has_progress  = lfs.attributes(progress_path, "mode") == "file"

        -- read title.txt if exists
        local title_path = joinPath(full, "title.txt")
        local real_name = nil
        local f = io.open(title_path, "r")
        if f then
            real_name = f:read("*a"):match("^%s*(.-)%s*$")
            f:close()
            if real_name then
                real_name = Util.strip_book_extension(real_name)
            end
        end

        if not has_progress then
            -- Annotations-only book: progress sync is OFF, so there is no
            -- syncery-progress.json -- only the annotations file.  Not a Syncery
            -- dir if that is absent too.
            if lfs.attributes(ann_path, "mode") ~= "file" then return false end
            -- Recover the book path from KOReader's native metadata.<ext>.lua at
            -- the SAME-md5 hashdocsettings .sdr (the synceryhash book_id IS
            -- KOReader's partialMD5), for the KOReader-hash + opened-locally
            -- case; existence-gated, so a stale/foreign doc_path is dropped.
            -- Pathless otherwise -- the booklist still names the book from
            -- title.txt, and the browser still reads its notes via the
            -- annotations path (so a synced-but-not-yet-opened book still shows).
            local book_file = HashLocationFinder.doc_path_for_hash(entry, lfs)
            if book_file and lfs.attributes(book_file, "mode") ~= "file" then
                book_file = nil
            end
            if not real_name and book_file then
                local name = book_file:match("([^/\\]+)$") or book_file
                name = name:gsub("%.[^%.\\/]+$", "")
                if name ~= "" then real_name = name end
            end
            table.insert(books, {
                progress_path    = nil,
                annotations_path = ann_path,
                display_name     = real_name or (_("Book ") .. entry:sub(1, 8)),
                file             = book_file,
                mode             = "hash",
            })
            count = count + 1
            return true
        end

        -- Always try to read the original book file path from progress.json
        -- Normalize the shape first so we read `.entries` from the canonical
        -- wrapper regardless of the on-disk body.
        local book_file = nil
        local prog_raw  = load_json(progress_path)
        local prog_data = require("syncery_progress/state_store").normalize(prog_raw)
        local entries   = prog_data.entries or {}
        -- Pick the book path from the per-device entries. A book read on
        -- several devices carries ONE entry per device, EACH stamped with
        -- that device's OWN path. The migration caller needs book.file to
        -- be a path that exists on THIS device: the safety net skips a book
        -- whose path does not resolve, and the destination is derived from
        -- it. So prefer the entry whose file is actually on disk here
        -- (naturally the local device's). The old pick used `pairs()`,
        -- whose order is unspecified, so on a multi-device setup it could
        -- return ANOTHER device's path and make a present book look absent
        -- (skipped + mislabelled "already in new location").
        -- 1. The local device's own entry, if its recorded path is on disk.
        local this_dev    = Util.get_device_id and Util.get_device_id()
        local local_entry = this_dev and entries[this_dev]
        if type(local_entry) == "table" and local_entry.file
           and lfs.attributes(local_entry.file, "mode") == "file" then
            book_file = local_entry.file
        end
        -- 2. Else the first entry whose recorded path resolves on disk here
        --    (covers a changed/regenerated local device_id, or a renamed
        --    book whose new path was recorded under a different device).
        if not book_file then
            for _, entry_data in pairs(entries) do
                if type(entry_data) == "table" and entry_data.file
                   and lfs.attributes(entry_data.file, "mode") == "file" then
                    book_file = entry_data.file
                    break
                end
            end
        end
        -- 3. Else any recorded path. The book is not on THIS device; the
        --    display/management caller must still name it, and migration's
        --    safety net correctly skips it (the path does not resolve).
        if not book_file then
            for _, entry_data in pairs(entries) do
                if type(entry_data) == "table" and entry_data.file then
                    book_file = entry_data.file
                    break
                end
            end
        end

        -- If we still don't have a display name, use the file path
        if not real_name and book_file then
            local name = book_file:match("([^/\\]+)$") or book_file
            name = name:gsub("%.[^%.\\/]+$", "")
            if name ~= "" then
                real_name = name
            end
        end

        table.insert(books, {
            progress_path    = progress_path,
            annotations_path = ann_path,
            display_name     = real_name or (_("Book ") .. entry:sub(1, 8)),
            file             = book_file,
            mode             = "hash",
        })
        count = count + 1
        if count % 50 == 0 then
            -- Only yield (or call Trapper:info, which yields
            -- internally) when actually running inside a
            -- coroutine. The migration tool calls scanHash
            -- synchronously from the main thread, where yield
            -- would raise "attempt to yield from outside a
            -- coroutine".
            if coroutine.isyieldable() then
                if Trapper and Trapper.info then
                    Trapper:info(string.format(
                        _("Scanning books… (%d found)"), count))
                else
                    coroutine.yield()
                end
            end
        end
        return true
    end

    -- Two-level walk: synceryhash/<shard>/<book_id>/.  We also tolerate a
    -- stray book dir directly under synceryhash/ (defensive — e.g. data
    -- written by an older flat layout, or a hand-placed dir): if a
    -- top-level entry is itself a book dir it is processed in place,
    -- otherwise it is treated as a shard bucket and descended into.
    if ok_dir then
        for shard_entry in iter, obj do
            -- Skip Syncthing-internal folders.  synceryhash/ is itself synced,
            -- so `.stversions` (archived old per-book state) and `.stfolder`
            -- (marker) appear at the shard level; descending `.stversions` is
            -- wasted work and the flat-layout tolerance below could mis-read an
            -- archived copy as a stray book dir.  Neither holds a live book.
            if shard_entry ~= "." and shard_entry ~= ".."
                    and shard_entry ~= ".stversions" and shard_entry ~= ".stfolder" then
                local shard_full = joinPath(hash_dir, shard_entry)
                if lfs.attributes(shard_full, "mode") == "directory" then
                    -- Try as a book dir directly (flat-layout tolerance).
                    if not process_book_dir(shard_full, shard_entry) then
                        -- Otherwise descend: it's a shard bucket.
                        local ok_sub, sub_iter, sub_obj = pcall(lfs.dir, shard_full)
                        if ok_sub then
                            for book_entry in sub_iter, sub_obj do
                                if book_entry ~= "." and book_entry ~= ".." then
                                    process_book_dir(
                                        joinPath(shard_full, book_entry), book_entry)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end


-- ============================================================================
-- scanSDR — SDR-mode synchronous scan (used by the migration tool)
-- ============================================================================


function Scan.scanSDR(roots, books)
    local seen = {}
    for __, root in ipairs(roots) do
        local function walk(dir, depth)
            depth = depth or 0
            if depth > 20 then return end
            local ok, iter, obj = pcall(lfs.dir, dir)
            if not ok then return end
            for entry in iter, obj do
                if entry ~= "." and entry ~= ".." then
                    local full = joinPath(dir, entry)
                    local mode = lfs.attributes(full, "mode")
                    if mode == "directory" then
                        -- Skip Syncthing-internal folders (see make_cancellable_walk).
                        if entry ~= ".stversions" and entry ~= ".stfolder" then
                            walk(full, depth + 1)
                        end
                    elseif mode == "file" and full:match("%.syncery%-progress%.json$") and not seen[full] then
                        seen[full] = true
                        -- Prefer the real path (with extension) recorded inside
                        -- the JSON; fall back to the .sdr-name reconstruction
                        -- (extension-less) only if the JSON has no file entry.
                        local book_file = book_file_from_progress_json(full)
                            or book_path_from_sdr_progress(full)
                        local ann_path = full:gsub("%.syncery%-progress%.json$", ".syncery-annotations.json")
                        table.insert(books, {
                            progress_path = full,
                            annotations_path = ann_path,
                            display_name = display_label(book_file, full),
                            file = book_file,
                            mode = "sdr",
                        })
                    end
                end
            end
        end
        walk(root)
    end
end


-- ============================================================================
-- walk_dir_cancellable — the cancellable SDR walk used by the
-- interactive showBookList path.  Returned as a factory because it
-- needs a per-scan `cancelled` flag + `books` accumulator that the
-- orchestrator owns.
--
-- Exposed as a factory so `booklist/init.lua` can keep its cancellation
-- flag local while still reusing the walk.
-- ============================================================================


--- Build a cancellable directory walker.
---@param books table   accumulator the walker appends discovered books to
---@param is_cancelled function () -> boolean; consulted on entry + per file
---@param on_progress function|nil  (count) -> boolean; false aborts the scan
---@return function walk(dir, pattern, seen, depth)
function Scan.make_cancellable_walk(books, is_cancelled, on_progress)
    -- Resolve a book's path the SAME way the dir/hash finders do, so a `.sdr`
    -- reached by BOTH this walk and a finder (e.g. when the Syncthing folder
    -- sits inside the docsettings tree) yields ONE de-dup key, not two.  Build
    -- the docsettings reconstructor + this device's id ONCE (per walk), not per
    -- file.  `reconstruct` is nil when KOReader is not in "dir" mode (or the
    -- root is unavailable); resolve_book_file simply skips step 3 then.
    local reconstruct = HashLocationFinder.make_dir_reconstructor(lfs)
    local local_id = (Util.get_device_id and Util.get_device_id()) or nil

    local function walk(dir, pattern, seen, depth)
        if is_cancelled() then return end
        depth = depth or 0
        if depth > 20 then return end
        local ok, iter, obj = pcall(lfs.dir, dir)
        if not ok then return end

        local file_count = 0
        for entry in iter, obj do
            if is_cancelled() then return end
            if entry ~= "." and entry ~= ".." then
                local full = joinPath(dir, entry)
                local mode = lfs.attributes(full, "mode")
                if mode == "directory" then
                    -- Never descend into Syncthing's internal folders.
                    -- `.stversions` ARCHIVES old copies of changed/deleted files
                    -- (under Trash-Can versioning a full `<book>.sdr/` with its
                    -- `*.syncery-progress.json` is kept verbatim); `.stfolder` is
                    -- the folder marker.  Walking `.stversions` re-emits a stale
                    -- copy whose recorded book path may differ from the live one
                    -- (e.g. a pre-rename path), which the de-dup cannot collapse
                    -- -> the book shows twice.  Neither ever holds a live book.
                    if entry ~= ".stversions" and entry ~= ".stfolder" then
                        walk(full, pattern, seen, depth + 1)
                    end
                elseif mode == "file" and full:match(pattern) and not seen[full] then
                    seen[full] = true
                    -- Resolve the book path with the SHARED resolver (the SAME
                    -- one find_synced_books_in_dir uses): prefer THIS device's
                    -- entry, then the first that resolves on disk, then the
                    -- .sdr-location reconstruction, then any -- sorted tiebreak,
                    -- so this scan and the dir finder always compute the SAME
                    -- `file`.  Without this, the old first-`pairs()`-hit pick
                    -- could return another device's (absent) path while the
                    -- finder returned the present local one -> two different
                    -- `file` keys the de-dup cannot collapse -> the book showed
                    -- twice (and intermittently, since `pairs()` order shifts
                    -- across restarts).  Falls back to the .sdr-name
                    -- reconstruction only when the JSON carries no entry at all.
                    local sdr_full = full:match("^(.*)[/\\][^/\\]+$")
                    local book_file = HashLocationFinder.resolve_book_file(full, {
                        lfs              = lfs,
                        load_json        = load_json,
                        device_id        = local_id,
                        reconstruct_path = reconstruct,
                        sdr_full         = sdr_full,
                    }) or book_path_from_sdr_progress(full)
                    local ann_path = full:gsub("%.syncery%-progress%.json$", ".syncery-annotations.json")
                    table.insert(books, {
                        progress_path = full,
                        annotations_path = ann_path,
                        display_name = display_label(book_file, full),
                        file = book_file,
                        mode = "sdr",
                    })
                    file_count = file_count + 1
                    if file_count % 50 == 0 and on_progress then
                        if on_progress(#books) == false then return end
                    end
                elseif mode == "file" and full:match("%.syncery%-annotations%.json$")
                        and not seen[full] then
                    seen[full] = true
                    -- Annotations-only book: progress sync is OFF, so there is no
                    -- *.syncery-progress.json (the branch above), only the
                    -- annotations file.  (`pattern` is always the progress
                    -- pattern, so progress files never reach here; this is its
                    -- fixed complement.)  Emit ONLY when there is no sibling
                    -- progress file -- progress takes priority and is handled
                    -- above -- AND the .sdr-location reconstruction resolves to a
                    -- real local file here.  This resolves paths only; the
                    -- pathless case (book absent, or hash storage) is handled
                    -- elsewhere.
                    -- Existence-gated, so an absent book is never fabricated.
                    local sibling = full:gsub("%.syncery%-annotations%.json$",
                        ".syncery-progress.json")
                    if lfs.attributes(sibling, "mode") ~= "file" then
                        local book_file = book_path_from_sdr_progress(full)
                        if book_file and lfs.attributes(book_file, "mode") == "file" then
                            table.insert(books, {
                                progress_path = nil,
                                annotations_path = full,
                                display_name = display_label(book_file, full),
                                file = book_file,
                                mode = "sdr",
                            })
                            file_count = file_count + 1
                            if file_count % 50 == 0 and on_progress then
                                if on_progress(#books) == false then return end
                            end
                        end
                    end
                end
            end
        end
    end
    return walk
end


return Scan
