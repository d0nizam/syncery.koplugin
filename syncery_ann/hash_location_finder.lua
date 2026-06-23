--[[--
Consolidated location-aware finder for KOReader's hash metadata tree
(`hashdocsettings/`).

WHY THIS MODULE EXISTS
----------------------
KOReader stores a book's sidecar (`metadata.<ext>.lua`) in one of three
locations, chosen by the global `document_metadata_folder` setting:

  * doc  — `<book>.sdr` beside the book (scattered; needs a root/picker),
  * dir  — `docsettings/<path>.sdr` (fixed tree; bulk_ingest already walks
           it via `find_books_in_metadata_dir`),
  * hash — `hashdocsettings/XX/<hash>.sdr` (fixed tree, but the dir is
           named by content-hash, so the book path is NOT recoverable
           from the dir name).

The hash location was the one neither finder covered: the booklist scan
looks only at Syncery's own `synceryhash/` tree, and bulk_ingest's two
finders cover roots ("doc") and `docsettings/` ("dir") but deliberately
skipped hash because reconstructing the book from a hash-named `.sdr`
needs the `doc_path` stored INSIDE the metadata file.  This module is
that missing piece.

TWO CLIENTS, ONE WALK, DIFFERENT MATCHES
----------------------------------------
bulk_ingest and the booklist scan share the WALK (the `hashdocsettings/`
tree) but match DIFFERENT files, because they answer different questions:

  * `find_native_books`  — bulk_ingest seeds Syncery state from KOReader's
    NATIVE annotations, so it matches `metadata.<ext>.lua`, reads the
    `doc_path` inside, and only returns books
    that still EXIST on disk.  Returns a list of book-path strings (the
    same shape `find_books_in_metadata_dir` returns), so it drops straight
    into bulk_ingest's `find_books`.

  * `find_synced_books` — the booklist lists ALREADY-synced books, so it
    matches Syncery's own `*.syncery-progress.json`.  In SDR storage mode
    with KOReader on hash metadata, those files land in
    `hashdocsettings/XX/<hash>.sdr/` (Syncery's `_sidecar_dir_for_book`
    delegates to `getSidecarDir` with no force_location, so it follows
    KOReader's setting).  Returns table rows matching `scanHash`'s shape.

Enumeration reuses KOReader's own `DocSettings.findSidecarFilesInHashLocation`
(which is `util.findFiles(DOCSETTINGS_HASH_DIR, ...)` under the hood) so we
have a single source of truth for "what is the hash tree and how is it
walked", the same way the rest of Syncery reuses `util.makePath`.
]]

local HashLocationFinder = {}

-- Recognized-extension stripping for display names (dotted-title safe:
-- "Dr. No.epub" -> "Dr. No", "Vol.2" with no known extension stays intact).
local Util = require("syncery_util")


-- Resolve KOReader's hashdocsettings root, or nil if unavailable.  Used by
-- the Syncery-file finder, which walks the tree directly (the native finder
-- goes through DocSettings instead).
local function hash_root(lfs)
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds or not DataStorage
            or type(DataStorage.getDocSettingsHashDir) ~= "function" then
        return nil
    end
    local ok_dir, dir = pcall(function()
        return DataStorage:getDocSettingsHashDir()
    end)
    if not ok_dir or type(dir) ~= "string" or dir == "" then return nil end
    if lfs and lfs.attributes(dir, "mode") ~= "directory" then return nil end
    return dir
end


-- Resolve KOReader's central docsettings ("dir" location) root, or nil.
-- Mirrors hash_root, for the "dir" metadata location's tree.
local function dir_root(lfs)
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds or not DataStorage
            or type(DataStorage.getDocSettingsDir) ~= "function" then
        return nil
    end
    local ok_dir, dir = pcall(function()
        return DataStorage:getDocSettingsDir()
    end)
    if not ok_dir or type(dir) ~= "string" or dir == "" then return nil end
    if lfs and lfs.attributes(dir, "mode") ~= "directory" then return nil end
    return dir
end


-- Build the per-.sdr processor shared by find_synced_books (hash tree) and
-- find_synced_books_in_dir (dir tree).  Both trees hold the SAME thing in each
-- leaf `.sdr` — Syncery's own `*.syncery-progress.json` for an SDR-storage book
-- whose KOReader metadata location happens to be hash or dir — so the
-- "find the progress file, read the real book path from inside, de-dup by that
-- path, emit a scanHash-shaped row" logic is identical.  Only the WALK over the
-- tree differs (two-level hash shards vs deep docsettings nesting).
--
-- Returns a function `process_sdr(sdr_full)` that appends matching rows to
-- `out`.  `seen` de-dups by book path across BOTH trees (so a book found in
-- both appears once); `deps` injects lfs + load_json/normalize for tests.
-- Recover a docsettings book's REAL local path from its .sdr LOCATION.
--
-- In KOReader metadata location "dir", the sidecar lives at
--   <docsettings_root>/<the book's absolute path>/<stem>.sdr/
-- so the book's directory IS the .sdr's parent with the docsettings_root
-- prefix stripped, and the filename (WITH extension) is the Syncery sync
-- file's basename minus its `.syncery-progress.json` / `.syncery-annotations.json`
-- suffix -- the .sdr dir name itself has the extension stripped, so the
-- filename must come from the sync file, not the dir name.  Either file works
-- (an annotations-only book, progress sync off, has no progress file but its
-- annotations file carries the same basename).
--
-- Used only as a fallback when no per-device progress entry resolves on disk,
-- and as the sole path source for annotations-only books.  The hash finder
-- cannot use this -- its .sdr dirs are content-hash-named, so the location
-- encodes nothing about the book path.  Returns nil when an input is missing
-- or the docsettings-tree segment cannot be located in the .sdr path.
local function reconstruct_dir_book_path(sdr_full, sync_file_path, dir_root)
    if not (sdr_full and sync_file_path and dir_root and dir_root ~= "") then
        return nil
    end
    local root = dir_root:gsub("/+$", "")                  -- no trailing slash
    local sdr_parent = sdr_full:match("^(.*)/[^/]+$")      -- dir holding the .sdr
    if not sdr_parent then return nil end
    -- Recover the book's directory by stripping the docsettings-root prefix.
    local book_dir
    if sdr_parent == root or sdr_parent:sub(1, #root + 1) == root .. "/" then
        -- Canonical: the .sdr is under the docsettings root as DataStorage
        -- reports it.  The dir finder, which scans FROM dir_root, always lands
        -- here, so its resolution is unchanged.
        book_dir = sdr_parent:sub(#root + 1)              -- "" at FS root, else "/abs/dir"
    else
        -- Mount-alias fallback.  The SAME docsettings tree can be addressed via a
        -- DIFFERENT prefix than getDocSettingsDir() reports: the dir finder may
        -- see a relative "./docsettings" while a root walk (a Syncthing folder
        -- pointed into the tree) reaches the identical files absolutely as
        -- "/mnt/.../docsettings".  A strict prefix strip then fails for the walk,
        -- the book falls through to another device's recorded path, and -- since
        -- the dir finder DID resolve the local one -- it lists twice (the
        -- cross-scan duplicate).  The tree's own dir NAME is the basename of
        -- dir_root; locate that segment (leading-slash anchored, so it never
        -- matches "/hashdocsettings/") and strip up to it -- the remainder IS the
        -- book's mirrored absolute path.  resolve_book_file existence-gates the
        -- result, so a path absent locally is dropped, never fabricated.
        local seg = root:match("([^/]+)$")                -- e.g. "docsettings"
        if not seg or seg == "" then return nil end
        local esc = seg:gsub("(%W)", "%%%1")              -- escape pattern magic
        local after = sdr_parent:match("/" .. esc .. "/(.*)$")
        if after and after ~= "" then
            book_dir = "/" .. after
        elseif sdr_parent:match("/" .. esc .. "$") then
            book_dir = ""                                 -- .sdr directly under the tree root
        else
            return nil
        end
    end
    local sbase = sync_file_path:match("([^/]+)$")
    if not sbase then return nil end
    local fname = sbase
    fname = fname:gsub("%.syncery%-progress%.json$", "")
    fname = fname:gsub("%.syncery%-annotations%.json$", "")
    if fname == sbase or fname == "" then return nil end   -- not a Syncery sync file
    return book_dir .. "/" .. fname
end


-- Recover a hash-located book's REAL local path from the KOReader native
-- sidecar that lives in the SAME .sdr.  A hashdocsettings .sdr is
-- content-hash-named, so its location encodes no path (reconstruct_dir_book_path
-- cannot help) -- but KOReader writes the book's `doc_path` INSIDE its own
-- `metadata.<ext>.lua` (docsettings.lua `data.doc_path`), and for an
-- SDR-storage + KOReader-hash user that metadata file sits right next to
-- Syncery's annotations file in the same .sdr.  Find it, read its doc_path.
-- (The same `doc_path` source find_native_books reads, but scoped to one .sdr
-- rather than the global hashdocsettings enumeration.)  Returns nil when no
-- native metadata file is present or it carries no doc_path; the caller
-- existence-gates the result, so a stale doc_path is dropped, not fabricated.
local function read_native_doc_path(sdr_full, lfs, loader)
    if not (sdr_full and lfs) then return nil end
    loader = loader or function(path)
        local ok, stored = pcall(dofile, path)
        if ok and type(stored) == "table" then return stored end
        return nil
    end
    local ok, iter, obj = pcall(lfs.dir, sdr_full)
    if not ok then return nil end
    for f in iter, obj do
        -- KOReader's own metadata file (same pattern findSidecarFilesInHashLocation
        -- uses); custom_metadata.lua does NOT match this.
        if type(f) == "string" and f:match("metadata%..+%.lua$") then
            local stored = loader(sdr_full .. "/" .. f)
            local doc_path = stored and stored.doc_path
            if type(doc_path) == "string" and doc_path ~= "" then
                return doc_path
            end
        end
    end
    return nil
end


--- Recover a synceryhash book's local path from KOReader's native metadata.
---
--- A Syncery hash-STORAGE book lives in `synceryhash/<book_id>/` with NO path
--- recorded (only `title.txt`); `book_id` IS KOReader's `util.partialMD5`.  When
--- KOReader is ALSO in hash metadata mode, its native `metadata.<ext>.lua` for
--- the same book sits at `hashdocsettings/<book_id[1:2]>/<book_id>.sdr/`, and
--- that file records `doc_path` (the local open path, written only when the book
--- was opened on THIS device).  Compute that `.sdr` and read the doc_path,
--- reusing `read_native_doc_path` (the same source `find_native_books` reads).
---
--- Returns nil when the hash root is unavailable, the `.sdr`/native metadata is
--- absent (KOReader not in hash mode, or the book never opened locally), or no
--- doc_path is recorded.  The caller existence-gates the result -- a recorded
--- path that does not resolve on THIS device (e.g. one written by another
--- device) is dropped, not fabricated.
function HashLocationFinder.doc_path_for_hash(book_id, lfs)
    lfs = lfs or require("libs/libkoreader-lfs")
    if type(book_id) ~= "string" or #book_id < 2 then return nil end
    local root = hash_root(lfs)
    if not root then return nil end
    local sdr_full = root .. "/" .. book_id:sub(1, 2) .. "/" .. book_id .. ".sdr"
    return read_native_doc_path(sdr_full, lfs)
end


-- ---------------------------------------------------------------------------
-- resolve_book_file — the ONE place that turns a Syncery progress file's
-- per-device entries into THIS device's real book path.  Shared by BOTH the
-- dir/hash finders (make_sdr_processor) and the root walk
-- (booklist/scan.lua's make_cancellable_walk), so the two enumerators can
-- never disagree on a book's path -- a disagreement is exactly what split one
-- book into two un-collapsible de-dup keys (one scan picking the present local
-- path, the other an absent foreign one) and showed it twice.
--
-- A book read on several devices carries one entry per device, each with that
-- device's OWN path.  The selection order:
--   1. THIS device's own entry, if its path is on disk here.
--   2. Else the first entry whose path resolves on disk here.
--   3. Else the .sdr-LOCATION reconstruction, if it resolves on disk here
--      (provided only when the caller injects `reconstruct_path`; dir/doc only).
--   4. Else any recorded path (book not on THIS device; named for display,
--      migration's safety net skips it).
--
-- Steps 2 and 4 iterate device ids in SORTED order, not `pairs()` order: two
-- independent reads of the same file (one per enumerator) build two separate
-- Lua tables whose `pairs()` order can differ, so an unsorted "first hit"
-- could return different paths in the two scans -- a non-deterministic split
-- that appeared and vanished across restarts.  Sorting makes the choice a
-- pure function of the file's contents, identical in both callers.
--
-- `deps`: lfs, load_json, normalize, device_id, reconstruct_path (a
-- `function(sdr_full, progress_path) -> path|nil`), sdr_full.  load_json /
-- normalize fall back to the real implementations for bare callers.
local function resolve_book_file(progress_path, deps)
    deps = deps or {}
    local lfs = deps.lfs or require("libs/libkoreader-lfs")
    local load_json = deps.load_json or function(path)
        local f = io.open(path, "r"); if not f then return nil end
        local body = f:read("*a"); f:close()
        if not body or body == "" then return nil end
        local ok_j, cjson = pcall(require, "cjson")
        if not ok_j then
            local ok_rj, rj = pcall(require, "rapidjson"); if not ok_rj then return nil end
            cjson = rj
        end
        local ok_dec, parsed = pcall(cjson.decode, body)
        return ok_dec and parsed or nil
    end
    local normalize = deps.normalize or function(x) return x or { entries = {} } end
    local local_id = deps.device_id
    local reconstruct_path = deps.reconstruct_path
    local sdr_full = deps.sdr_full

    local prog = normalize(load_json(progress_path))
    local entries = (type(prog) == "table" and type(prog.entries) == "table")
        and prog.entries or {}

    -- Device ids in a stable, content-determined order (see header).
    local ids = {}
    for id in pairs(entries) do ids[#ids + 1] = id end
    table.sort(ids)

    -- 1. The local device's own entry, if its path is on disk here.
    local local_entry = local_id and entries[local_id]
    if type(local_entry) == "table" and local_entry.file
       and lfs.attributes(local_entry.file, "mode") == "file" then
        return local_entry.file
    end
    -- 2. Else the first entry (sorted) whose path resolves on disk here.
    for _, id in ipairs(ids) do
        local entry = entries[id]
        if type(entry) == "table" and entry.file
           and lfs.attributes(entry.file, "mode") == "file" then
            return entry.file
        end
    end
    -- 3. Else recover the local path from the .sdr LOCATION, existence-gated.
    if reconstruct_path and sdr_full then
        local recon = reconstruct_path(sdr_full, progress_path)
        if recon and lfs.attributes(recon, "mode") == "file" then
            return recon
        end
    end
    -- 4. Else any recorded path (sorted, so both enumerators agree).
    for _, id in ipairs(ids) do
        local entry = entries[id]
        if type(entry) == "table" and entry.file then
            return entry.file
        end
    end
    return nil
end
HashLocationFinder.resolve_book_file = resolve_book_file

-- Expose the dir-mode reconstruction so the root walk can pass the SAME
-- `reconstruct_path` callback the dir finder uses (full parity).
HashLocationFinder._reconstruct_dir_book_path = reconstruct_dir_book_path

-- Build a dir-mode reconstruct callback for resolve_book_file.  Computes the
-- docsettings root ONCE; returns a `function(sdr_full, progress_path)` that
-- root-strips a docsettings `.sdr` to the book's real local path (or nil when
-- the `.sdr` is not under the docsettings root, e.g. a book-folder "doc"-mode
-- sidecar -- there the per-device entries already carry the real path).
function HashLocationFinder.make_dir_reconstructor(lfs)
    lfs = lfs or require("libs/libkoreader-lfs")
    local root = dir_root(lfs)
    if not root then return nil end
    return function(sdr_full, progress_path)
        return reconstruct_dir_book_path(sdr_full, progress_path, root)
    end
end


local function make_sdr_processor(out, seen, deps)
    local lfs = deps.lfs or require("libs/libkoreader-lfs")

    local load_json = deps.load_json
    if not load_json then
        -- Default reader: slurp the file and JSON-decode it.  Display callers
        -- pass no loader, and we must still recover each book's path from its
        -- progress entries.
        load_json = function(path)
            local f = io.open(path, "r")
            if not f then return nil end
            local body = f:read("*a")
            f:close()
            if not body or body == "" then return nil end
            local ok_j, cjson = pcall(require, "cjson")
            if not ok_j then
                local ok_rj, rj = pcall(require, "rapidjson")
                if not ok_rj then return nil end
                cjson = rj
            end
            local ok_dec, parsed = pcall(cjson.decode, body)
            return ok_dec and parsed or nil
        end
    end

    local normalize = deps.normalize
    if not normalize then
        local ok_ss, StateStore = pcall(require, "syncery_progress/state_store")
        if ok_ss and StateStore and StateStore.normalize then
            normalize = StateStore.normalize
        else
            normalize = function(x) return x or { entries = {} } end
        end
    end

    -- THIS device's id, so the per-device selection below can prefer its own
    -- entry.  Injectable for tests; falls back to the real device id.
    local local_id = deps.device_id
    if local_id == nil then
        local ok_u, Util = pcall(require, "syncery_util")
        if ok_u and Util and Util.get_device_id then
            local_id = Util.get_device_id()
        end
    end

    -- Optional .sdr-location -> local book path reconstruction (provided only
    -- by the dir finder; the hash finder leaves it nil because content-hash
    -- dir names encode no path).  Used as a fallback below.
    local reconstruct_path = deps.reconstruct_path
    -- The hash finder injects this instead: a content-hash .sdr has no path in
    -- its location, so the book path comes from the native metadata's doc_path
    -- (see read_native_doc_path).  Mutually exclusive with reconstruct_path --
    -- each finder injects exactly one.
    local read_doc_path = deps.read_doc_path

    -- A .sdr directory may hold a `<basename>.syncery-progress.json`.  Find it,
    -- read the book path from inside, and emit a row.
    return function(sdr_full)
        if lfs.attributes(sdr_full, "mode") ~= "directory" then return end
        local progress_path, ann_path, ann_only_path
        local ok, iter, obj = pcall(lfs.dir, sdr_full)
        if not ok then return end
        for f in iter, obj do
            if type(f) == "string" then
                if f:match("%.syncery%-progress%.json$") then
                    progress_path = sdr_full .. "/" .. f
                    ann_path = sdr_full .. "/"
                        .. f:gsub("%.syncery%-progress%.json$", ".syncery-annotations.json")
                elseif f:match("%.syncery%-annotations%.json$") then
                    ann_only_path = sdr_full .. "/" .. f
                end
            end
        end
        if not progress_path then
            -- Annotations-only book: progress sync is OFF (no
            -- *.syncery-progress.json) but annotations sync wrote
            -- *.syncery-annotations.json.  Progress takes priority when both
            -- exist (the branch below), so we land here only with no progress
            -- file at all.  Recover the book path mode-appropriately:
            --   * dir/doc finder injects `reconstruct_path` (the .sdr LOCATION
            --     encodes the absolute book path);
            --   * the hash finder injects `read_doc_path` (a content-hash .sdr
            --     encodes no path, but KOReader's native metadata.<ext>.lua in
            --     the SAME .sdr carries `doc_path`).
            -- Each finder injects exactly one, so they are mutually exclusive.
            -- Existence-gated exactly like the foreign-path fallback below, so
            -- an absent (or moved/deleted) book is never fabricated.
            if ann_only_path then
                local book_file
                if reconstruct_path then
                    book_file = reconstruct_path(sdr_full, ann_only_path)
                elseif read_doc_path then
                    book_file = read_doc_path(sdr_full)
                end
                local resolves = book_file
                    and lfs.attributes(book_file, "mode") == "file"
                if resolves and not seen[book_file] then
                    seen[book_file] = true
                    local name = book_file:match("([^/\\]+)$") or book_file
                    name = name:gsub("%.[^%.\\/]+$", "")
                    out[#out + 1] = {
                        progress_path    = nil,
                        annotations_path = ann_only_path,
                        display_name     = (name ~= "" and name) or "Book",
                        file             = book_file,
                        mode             = "sdr",
                    }
                elseif read_doc_path and not resolves and not seen[ann_only_path] then
                    -- Hash finder, no RESOLVABLE book path on THIS device.  Two
                    -- shapes land here, both surfaced PATHLESS:
                    --   * NOT opened locally -- KOReader's native metadata.<ext>
                    --     .lua (which carries doc_path) is .stignore-suppressed
                    --     from sync, so read_doc_path returns nil (a content-hash
                    --     .sdr encodes no path of its own);
                    --   * opened earlier but the book FILE was since moved or
                    --     deleted -- read_doc_path returns a stale doc_path that
                    --     no longer resolves on disk.
                    -- Either way the notes stay readable via annotations_path, so
                    -- surface with file=nil; the name comes from the prefixed
                    -- annotations filename (<book>.<ext>.syncery-annotations.json),
                    -- extension stripped only if recognized (so "Dr. No.epub"
                    -- keeps "Dr. No").  The not-opened path self-heals on first
                    -- open (KOReader writes doc_path, which then resolves).
                    -- This is the SOLE pathless emitter for a hashdocsettings
                    -- book: the general walk REACHES the same file (its prefixed
                    -- name matches the pattern) but DROPS it (its .sdr-location
                    -- reconstruction yields a non-resolving path, existence-
                    -- gated), and the dir/doc finder takes the `reconstruct_path`
                    -- branch -- whose own absent books ALSO fall into `not
                    -- resolves`, but are gated OUT here by the `read_doc_path`
                    -- guard (nil for that finder), so the DIR finder never emits
                    -- a pathless row and a synced book is shown exactly once.
                    seen[ann_only_path] = true
                    local raw = ann_only_path:match("([^/\\]+)$") or ""
                    raw = raw:gsub("%.syncery%-annotations%.json$", "")
                    local name = Util.strip_book_extension(raw)
                    out[#out + 1] = {
                        progress_path    = nil,
                        annotations_path = ann_only_path,
                        display_name     = (name ~= "" and name) or "Book",
                        file             = nil,
                        mode             = "sdr",
                    }
                end
            end
            return
        end

        -- Read the real book file path from the per-device progress entries via
        -- the shared resolver (the SAME one the root walk uses, so the two
        -- enumerators never disagree on a book's path -- the duplicate-row bug).
        -- A book read on several devices has one entry per device, each with
        -- that device's OWN path; the resolver prefers THIS device's entry, then
        -- the first that resolves on disk, then the .sdr-location reconstruction,
        -- then any -- with a deterministic (sorted) tiebreak so it is a pure
        -- function of the file's contents (the 23.13e bug, this finder's twin).
        local book_file = resolve_book_file(progress_path, {
            lfs              = lfs,
            load_json        = load_json,
            normalize        = normalize,
            device_id        = local_id,
            reconstruct_path = reconstruct_path,
            sdr_full         = sdr_full,
        })

        -- De-dup by book path when known (a book also found beside itself, in
        -- the hash tree, or in the dir tree should appear once).
        if book_file then
            if seen[book_file] then return end
            seen[book_file] = true
        end

        local display_name
        if book_file then
            local name = book_file:match("([^/\\]+)$") or book_file
            name = name:gsub("%.[^%.\\/]+$", "")
            if name ~= "" then display_name = name end
        end

        out[#out + 1] = {
            progress_path    = progress_path,
            annotations_path = ann_path,
            display_name     = display_name or "Book",
            file             = book_file,
            -- SDR storage: these files are in KOReader's hashdocsettings/ or
            -- docsettings/ because the user's KOReader metadata location is
            -- "hash" or "dir", but Syncery itself is in SDR mode (synceryhash
            -- storage would put them under synceryhash/, not here).
            -- storage_mode is the axis the booklist counts; KOReader's
            -- metadata location is orthogonal.
            mode             = "sdr",
        }
    end
end


-- ---------------------------------------------------------------------------
-- Native-annotation finder (for bulk_ingest).
--
-- Enumerate `hashdocsettings/` via DocSettings.findSidecarFilesInHashLocation,
-- read each metadata file's `doc_path`, and return the book paths that still
-- exist on disk.  Mirrors `find_books_in_metadata_dir`'s contract: a
-- de-duplicated list of book-path strings, existence-guarded.
--
-- `seen` is the shared de-dup table from bulk_ingest's find_books (a book
-- whose sidecars sit in more than one location appears once).  `deps` allows
-- injecting `docsettings` and a `dofile`-style loader for tests; both default
-- to the real implementations.
-- ---------------------------------------------------------------------------
function HashLocationFinder.find_native_books(lfs, seen, deps)
    lfs  = lfs or require("libs/libkoreader-lfs")
    seen = seen or {}
    deps = deps or {}
    local out = {}

    local DocSettings = deps.docsettings
    if not DocSettings then
        local ok_ds, mod = pcall(require, "docsettings")
        if not ok_ds then return out end
        DocSettings = mod
    end
    if type(DocSettings.findSidecarFilesInHashLocation) ~= "function" then
        return out
    end

    local load_metadata = deps.load_metadata or function(path)
        local ok, stored = pcall(dofile, path)
        if ok and type(stored) == "table" then return stored end
        return nil
    end

    local ok_list, pairs_list = pcall(DocSettings.findSidecarFilesInHashLocation)
    if not ok_list or type(pairs_list) ~= "table" then return out end

    for _, pair in ipairs(pairs_list) do
        -- Each entry is { sidecar_file, custom_metadata_file? }; we only
        -- need the metadata file (the first element).
        local metadata_file = pair[1]
        if type(metadata_file) == "string" and metadata_file ~= "" then
            local stored = load_metadata(metadata_file)
            local doc_path = stored and stored.doc_path
            if type(doc_path) == "string" and doc_path ~= "" then
                -- Only ingest books that still exist.  The
                -- stored doc_path can be stale (book moved/deleted since it
                -- was last opened); skip those rather than seed an orphan.
                if not seen[doc_path]
                        and lfs.attributes(doc_path, "mode") == "file" then
                    seen[doc_path] = true
                    out[#out + 1] = doc_path
                end
            end
        end
    end

    return out
end


-- ---------------------------------------------------------------------------
-- Synced-file finder (for the booklist scan).
--
-- Walk the `hashdocsettings/XX/<hash>.sdr/` tree looking for Syncery's own
-- `*.syncery-progress.json` (present there for SDR-storage + KOReader-hash
-- users).  Returns table rows in the SAME shape `scanHash` appends, so the
-- booklist can consume them directly.  De-duplicated by book path through
-- the shared `seen` table.
--
-- `deps` injects `lfs` and a `load_json`/`normalize` pair for tests.
-- ---------------------------------------------------------------------------
function HashLocationFinder.find_synced_books(seen, deps)
    seen = seen or {}
    deps = deps or {}
    local lfs = deps.lfs or require("libs/libkoreader-lfs")
    local out = {}

    local root = hash_root(lfs)
    if not root then return out end

    -- Annotations-only books in this hash tree have a content-hash-named .sdr
    -- (no path in the location), so recover the book path from the KOReader
    -- native metadata.<ext>.lua's doc_path that sits in the SAME .sdr.  Injected
    -- the same way the dir finder injects reconstruct_path; the caller's deps
    -- fall through via the metatable, and a .sdr that holds a Syncery progress
    -- file takes the progress branch instead, so this only fires for
    -- annotations-only books.
    local processor_deps = setmetatable({
        read_doc_path = function(sdr_full)
            return read_native_doc_path(sdr_full, lfs, deps.load_metadata)
        end,
    }, { __index = deps })
    local process_sdr = make_sdr_processor(out, seen, processor_deps)

    -- Two-level walk: hashdocsettings/<shard>/<hash>.sdr/.
    local ok_top, top_iter, top_obj = pcall(lfs.dir, root)
    if not ok_top then return out end
    for shard in top_iter, top_obj do
        -- Skip Syncthing-internal folders at the shard level (`.stversions`
        -- archives, `.stfolder` marker) when the hashdocsettings/ tree is itself
        -- inside a synced folder; neither holds a live `.sdr`.
        if shard ~= "." and shard ~= ".."
                and shard ~= ".stversions" and shard ~= ".stfolder" then
            local shard_full = root .. "/" .. shard
            if lfs.attributes(shard_full, "mode") == "directory" then
                local ok_sub, sub_iter, sub_obj = pcall(lfs.dir, shard_full)
                if ok_sub then
                    for sdr in sub_iter, sub_obj do
                        if sdr ~= "." and sdr ~= ".." then
                            process_sdr(shard_full .. "/" .. sdr)
                        end
                    end
                end
            end
        end
    end

    return out
end


-- ---------------------------------------------------------------------------
-- find_synced_books_in_dir — the "dir" metadata location analog of
-- find_synced_books.  Walks KOReader's central docsettings/ tree looking for
-- Syncery's own `*.syncery-progress.json` (present there for SDR-storage users
-- whose KOReader metadata location is "dir").  Returns rows in the SAME shape
-- scanHash/find_synced_books append, de-duplicated by book path through the
-- shared `seen` table.
--
-- The dir tree is DEEP (`docsettings/<full/book/path>.sdr/`), unlike the
-- two-level hash shards, so this walks recursively and emits a row for any
-- `.sdr` directory holding a Syncery progress file.  `deps` injects
-- lfs + load_json/normalize for tests, identical to find_synced_books.
-- ---------------------------------------------------------------------------
local MAX_DIR_DEPTH = 20

function HashLocationFinder.find_synced_books_in_dir(seen, deps)
    seen = seen or {}
    deps = deps or {}
    local lfs = deps.lfs or require("libs/libkoreader-lfs")
    local out = {}

    local root = dir_root(lfs)
    if not root then return out end

    -- Give the shared processor a dir-mode reconstruction: when a book's
    -- progress entries all carry other-device paths that don't resolve here,
    -- recover its real local path from the .sdr location (root-stripped).  The
    -- caller's deps are not mutated -- the original fields fall through via the
    -- metatable, and the hash finder, which passes no such callback, is wholly
    -- unaffected.
    local processor_deps = setmetatable({
        reconstruct_path = function(sdr_full, progress_path)
            return reconstruct_dir_book_path(sdr_full, progress_path, root)
        end,
    }, { __index = deps })
    local process_sdr = make_sdr_processor(out, seen, processor_deps)

    -- Deep recursive walk: process any `.sdr` dir; recurse into the rest.
    -- (A `.sdr` directory is a leaf for our purposes — we don't descend into
    -- it beyond process_sdr's own single-level listing.)
    local function walk(dir, depth)
        if depth > MAX_DIR_DEPTH then return end
        local ok, iter, obj = pcall(lfs.dir, dir)
        if not ok then return end
        for entry in iter, obj do
            if entry ~= "." and entry ~= ".." then
                local full = dir .. "/" .. entry
                if lfs.attributes(full, "mode") == "directory"
                        and entry ~= ".stversions" and entry ~= ".stfolder" then
                    -- Skip Syncthing-internal folders: `.stversions` archives old
                    -- copies of changed/deleted sidecars and `.stfolder` is the
                    -- marker.  Recursing `.stversions` would re-emit a stale `.sdr`
                    -- copy; if its recorded book path differs from the live one
                    -- (e.g. a pre-rename path) the book-path de-dup cannot collapse
                    -- it and the book appears twice.  Neither holds a live book.
                    if entry:match("%.sdr$") then
                        process_sdr(full)
                    else
                        walk(full, depth + 1)
                    end
                end
            end
        end
    end

    walk(root:gsub("/+$", ""), 0)
    return out
end


return HashLocationFinder
