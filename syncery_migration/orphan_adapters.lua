-- =============================================================================
-- syncery_migration/orphan_adapters.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- The adapter layer for the orphan-cleanup feature. The
-- decision core (`orphan_cleanup.lua`) is pure logic driven by four injected
-- deps; THIS file builds those deps from the real world — the filesystem, the
-- home_dir setting, KOReader's content hashing.
--
-- Built incrementally. This sub-step provides `present_book_hashes` — the set
-- of content hashes of books that currently exist. The remaining adapters
-- (Syncery-JSON enumeration, per-JSON hash/name resolution) follow in later
-- sub-steps.
--
--
-- present_book_hashes — home_dir is the BASE, roots are OPPORTUNISTIC
--
-- The present-book set is built from
-- `home_dir` ALWAYS (the canonical, always-present books folder), unioned with
-- any configured roots when they exist. Configured roots are an OPPORTUNISTIC
-- additive to catch books living outside home_dir; their ABSENCE must NEVER
-- block the scan. There is no "no roots -> stop" — home_dir always gives us a
-- base to stand on. (This is the explicit fix versus the old `_cleanupOrphans`,
-- which REQUIRED a Syncthing folder mapping and refused without one.)
--
-- Each book's content hash comes from the injected `book_content_id` resolver
-- (in production: `Paths._book_content_id`, which reads the cached
-- partial_md5_checksum first and computes `util.partialMD5` only when absent).
-- Every book that HAS a Syncery JSON was necessarily opened, so its hash is
-- cached and cheap to read; the partialMD5 cost only arises for cold books
-- that have no JSON and thus cannot be an orphan source anyway.
--
-- PERFORMANCE CAVEAT: a large library with many cold books
-- still pays partialMD5 for each cold book here, because we enumerate all book
-- files, not only those with sidecars. This is acceptable for an on-demand,
-- user-initiated action (never automatic). It is the same cost KOReader warns
-- about for the hash metadata location.
--
--
-- THE INJECTED DEPENDENCIES
--
--   deps.lfs                 KOReader's lfs (Util.get_lfs() in production).
--   deps.home_dir()          -> string|nil   The canonical books folder.
--   deps.configured_roots()  -> { <path>, ... } | nil   Optional extra roots.
--   deps.book_content_id(p)  -> hash<string>|nil   Content hash of a book.
--   deps.is_book_file(name)  -> boolean   (optional) Whether a filename is a
--                              book. Defaults to a conservative extension list.
--
-- =============================================================================

local OrphanAdapters = {}

-- Conservative default set of book extensions, used only when the caller does
-- not inject `is_book_file`. KOReader supports more, but for orphan detection a
-- book that is neither here nor recognised by an injected predicate simply does
-- not contribute its hash — a missed book risks a false orphan elsewhere, never
-- a wrong deletion of its own JSON (its JSON, if any, is judged on its own
-- identity). Kept deliberately broad to minimise that risk.
local DEFAULT_BOOK_EXTS = {
    epub = true, pdf = true, mobi = true, azw = true, azw3 = true, fb2 = true,
    djvu = true, cbz = true, cbr = true, txt = true, html = true, htm = true,
    doc = true, docx = true, rtf = true, chm = true, fb2z = true, zip = true,
    ["zip"] = true, prc = true, pdb = true, ["xps"] = true, ["oxps"] = true,
    md = true, opf = true, kepub = true, ["epub3"] = true,
}

--- Bound, pcall-guarded directory walk. Recurses into subdirectories but skips
--- `.sdr` directories (their contents are sidecars, not books) and never
--- descends past `max_depth` (cycle/symlink safety).
local function walk_books(lfs, dir, max_depth, is_book_file, on_book, _depth, _seen_dirs)
    _depth = _depth or 0
    if _depth > max_depth then return end
    if type(dir) ~= "string" or dir == "" then return end

    local ok, iter, obj = pcall(lfs.dir, dir)
    if not ok then return end

    for entry in iter, obj do
        if entry ~= "." and entry ~= ".." then
            local full = dir .. "/" .. entry
            local mode = lfs.attributes(full, "mode")
            if mode == "directory" then
                -- Skip Syncery's own hash tree and KOReader's .sdr dirs: those
                -- hold sidecars, not book files.
                if not entry:match("%.sdr$") then
                    walk_books(lfs, full, max_depth, is_book_file, on_book, _depth + 1, _seen_dirs)
                end
            elseif mode == "file" then
                local ext = entry:match("%.([%a%d]+)$")
                if ext and is_book_file(entry, ext:lower()) then
                    on_book(full)
                end
            end
        end
    end
end

--- Build the present-book content-hash set: home_dir (BASE) ∪ configured roots
--- (OPPORTUNISTIC). Absence of roots never blocks; absence of home_dir yields an
--- empty set (the caller / UI decides what to do with that).
---
--- @param deps table Injected dependencies (see header).
--- @return table { [hash]=true, ... }
function OrphanAdapters.present_book_hashes(deps)
    assert(type(deps) == "table", "orphan_adapters: deps table required")
    assert(deps.lfs, "orphan_adapters: lfs required")
    assert(type(deps.home_dir) == "function", "orphan_adapters: home_dir() required")
    assert(type(deps.book_content_id) == "function", "orphan_adapters: book_content_id() required")

    local max_depth = deps.max_depth or 30
    local is_book_file = deps.is_book_file or function(_name, ext)
        return DEFAULT_BOOK_EXTS[ext] == true
    end

    -- Collect the roots to scan: home_dir FIRST (the base), then any configured
    -- roots not already covered by an already-listed root.
    local roots = {}
    local seen_root = {}
    local function add_root(path)
        if type(path) == "string" and path ~= "" and not seen_root[path] then
            seen_root[path] = true
            roots[#roots + 1] = path
        end
    end

    add_root(deps.home_dir())                       -- BASE — always

    local configured = deps.configured_roots and deps.configured_roots() or nil
    if type(configured) == "table" then             -- OPPORTUNISTIC — additive
        for _, r in ipairs(configured) do
            -- Skip a configured root that is nested under an already-added root
            -- (home_dir or an earlier one) to avoid re-walking the same files.
            local nested = false
            for existing in pairs(seen_root) do
                if r == existing or (type(r) == "string"
                        and r:sub(1, #existing + 1) == existing .. "/") then
                    nested = true
                    break
                end
            end
            if not nested then add_root(r) end
        end
    end

    -- Walk each root, hashing every book file into the present-set. A book seen
    -- under multiple roots resolves to the same hash, so de-dup is implicit.
    local present = {}
    local seen_book = {}
    for _, root in ipairs(roots) do
        walk_books(deps.lfs, root, max_depth, is_book_file, function(book_path)
            if not seen_book[book_path] then
                seen_book[book_path] = true
                local hash = deps.book_content_id(book_path)
                if hash and hash ~= "" then
                    present[hash] = true
                end
            end
        end)
    end

    return present
end

-- ---------------------------------------------------------------------------
-- syncery_jsons — enumerate every Syncery JSON sidecar, tagged by location class
-- ---------------------------------------------------------------------------
--
-- Syncery JSONs live in one of four trees, and the tree a file is found under
-- DECIDES its location class (cleaner and safer than guessing klass from a path
-- substring):
--
--   * synceryhash : <hash_root>/synceryhash/<shard>/<book_md5>/syncery-*.json
--                   (filename has NO book prefix). klass = "synceryhash".
--   * doc         : <book>.sdr beside each book, inside home_dir ∪ roots.
--                   filename = "<book>.syncery-*.json". klass = "doc".
--   * dir         : DataStorage:getDocSettingsDir()/.../<book>.sdr/<book>.syncery-*.json
--                   klass = "dir".
--   * hash        : DataStorage:getDocSettingsHashDir()/XX/<hash>.sdr/<book>.syncery-*.json
--                   klass = "hashdocsettings".
--
-- Both shared files (progress AND annotations) are enumerated; each is judged
-- independently by the decision core. The same physical file can only sit in
-- one tree, so no cross-tree de-dup is needed; a per-path guard prevents listing
-- the same file twice within a tree.
--
-- All roots arrive through injected getters so tests can point them at a fake
-- filesystem and so a getter returning nil (tree absent / older KOReader) is
-- simply skipped — never an error, never blocking.
--
--   deps.lfs                       lfs.
--   deps.synceryhash_root()        -> string|nil   <hash_root>/synceryhash root.
--   deps.doc_roots()               -> { <path>, ... } | nil   home_dir ∪ roots.
--   deps.dir_tree_root()           -> string|nil   KOReader docsettings/ root.
--   deps.hash_tree_root()          -> string|nil   KOReader hashdocsettings/ root.
--
-- Returns: { { path=<string>, klass=<string> }, ... }

-- Matches both "<book>.syncery-progress.json" and ".../syncery-annotations.json"
-- (with or without a book-name prefix). Does NOT match e.g. a ".bak" suffix.
local function is_syncery_json(name)
    return name:match("syncery%-progress%.json$") ~= nil
        or name:match("syncery%-annotations%.json$") ~= nil
end

-- Walk a tree, collecting Syncery JSONs, tagging each with `klass`.
local function collect_jsons(lfs, root, klass, max_depth, out, seen, _depth)
    _depth = _depth or 0
    if _depth > max_depth then return end
    if type(root) ~= "string" or root == "" then return end

    local ok, iter, obj = pcall(lfs.dir, root)
    if not ok then return end

    for entry in iter, obj do
        if entry ~= "." and entry ~= ".." then
            local full = root .. "/" .. entry
            local mode = lfs.attributes(full, "mode")
            if mode == "directory" then
                collect_jsons(lfs, full, klass, max_depth, out, seen, _depth + 1)
            elseif mode == "file" and is_syncery_json(entry) then
                if not seen[full] then
                    seen[full] = true
                    out[#out + 1] = { path = full, klass = klass }
                end
            end
        end
    end
end

--- Enumerate every Syncery JSON sidecar across the four location trees.
--- @param deps table Injected dependencies (see above).
--- @return table { { path=, klass= }, ... }
function OrphanAdapters.syncery_jsons(deps)
    assert(type(deps) == "table", "orphan_adapters: deps table required")
    assert(deps.lfs, "orphan_adapters: lfs required")

    local max_depth = deps.max_depth or 30
    local out = {}
    local seen = {}

    -- 1. synceryhash tree (content-keyed; filenames have no book prefix).
    if type(deps.synceryhash_root) == "function" then
        collect_jsons(deps.lfs, deps.synceryhash_root(), "synceryhash", max_depth, out, seen)
    end

    -- 2. doc location: book-folder .sdr dirs live inside home_dir ∪ roots.
    if type(deps.doc_roots) == "function" then
        local doc_roots = deps.doc_roots()
        if type(doc_roots) == "table" then
            for _, r in ipairs(doc_roots) do
                collect_jsons(deps.lfs, r, "doc", max_depth, out, seen)
            end
        end
    end

    -- 3. dir location: KOReader's central docsettings/ tree.
    if type(deps.dir_tree_root) == "function" then
        collect_jsons(deps.lfs, deps.dir_tree_root(), "dir", max_depth, out, seen)
    end

    -- 4. hash location: KOReader's hashdocsettings/ tree.
    if type(deps.hash_tree_root) == "function" then
        collect_jsons(deps.lfs, deps.hash_tree_root(), "hashdocsettings", max_depth, out, seen)
    end

    return out
end

-- ---------------------------------------------------------------------------
-- json_book_hash / json_book_name_present — per-JSON identity resolution
-- ---------------------------------------------------------------------------
--
-- These two resolvers supply the decision core's `json_book_hash` and
-- `json_book_name_present` deps. Where the identity comes from depends on the
-- location class (the symmetric-structural-identity finding):
--
--   * synceryhash    : the book hash is the directory NAME containing the JSON
--                      (.../synceryhash/<shard>/<book_md5>/syncery-*.json) —
--                      structural, always present.
--   * hashdocsettings: the book hash is the ".sdr" directory NAME containing the
--                      JSON (.../hashdocsettings/XX/<hash>.sdr/<book>.syncery-*.json),
--                      with ".sdr" stripped — structural, always present.
--   * doc / dir      : the hash is NOT structural. It comes from the sibling
--                      metadata.<ext>.lua (`partial_md5_checksum`), which may be
--                      absent (the partial_md5 caveat). The NAME (doc_path) also
--                      comes from that metadata file, falling back to
--                      reconstructing the book path beside the .sdr (doc only).
--
-- The metadata file is read FORMAT-SPECIFICALLY: a shared ".sdr" can hold
-- metadata for several formats (Book.pdf + Book.mobi → metadata.pdf.lua +
-- metadata.mobi.lua); we read the one matching the JSON's "<book>.<ext>." prefix
-- so we never pick up another format's doc_path/hash (the PoC shared-.sdr case).
--
--   deps.lfs                 lfs (for the name-presence existence check).
--   deps.load_metadata(p)    -> table|nil   Loads a metadata.lua (dofile in
--                            production; injected in tests). Defaults to dofile.
--
-- (The same `deps` table is shared with the other adapters; only the keys each
-- function needs are required.)

-- Find the sibling metadata.<ext>.lua for a JSON, format-specifically.
local function sibling_metadata_path(json_path, lfs)
    local dir = json_path:match("^(.*)/[^/]+$")
    if not dir then return nil end
    -- "<book>.<ext>.syncery-{progress,annotations}.json" → ext
    local ext = json_path:match("/[^/]+%.([%a%d]+)%.syncery%-[%a]+%.json$")
    if ext then
        local cand = dir .. "/metadata." .. ext .. ".lua"
        if (not lfs) or lfs.attributes(cand, "mode") == "file" then
            -- When lfs is available, only return it if it exists; otherwise
            -- optimistically return the format-specific path.
            if lfs and lfs.attributes(cand, "mode") == "file" then return cand end
            if not lfs then return cand end
        end
    end
    -- Fallback: any metadata.<ext>.lua in the dir (single-format .sdr).
    if lfs then
        local ok, iter, obj = pcall(lfs.dir, dir)
        if ok then
            for entry in iter, obj do
                if entry:match("^metadata%.[%a%d]+%.lua$") then
                    return dir .. "/" .. entry
                end
            end
        end
    end
    return nil
end

local function default_load_metadata(path)
    local ok, stored = pcall(dofile, path)
    if ok and type(stored) == "table" then return stored end
    return nil
end

--- Resolve the content hash recorded for a JSON's book, or nil.
--- @param deps table { lfs?, load_metadata? }
--- @param entry table { path=, klass= }
--- @return string|nil
function OrphanAdapters.json_book_hash(deps, entry)
    assert(type(deps) == "table", "orphan_adapters: deps table required")
    assert(type(entry) == "table", "orphan_adapters: entry required")

    if entry.klass == "synceryhash" then
        -- hash = the directory NAME containing the JSON.
        return entry.path:match("/synceryhash/[^/]+/([^/]+)/[^/]+$")
    elseif entry.klass == "hashdocsettings" then
        -- hash = the ".sdr" dir NAME containing the JSON, ".sdr" stripped.
        return entry.path:match("/hashdocsettings/[^/]+/([^/]+)%.sdr/[^/]+$")
    else
        -- doc / dir: read partial_md5_checksum from the sibling metadata.lua.
        local md = sibling_metadata_path(entry.path, deps.lfs)
        if not md then return nil end
        local load_metadata = deps.load_metadata or default_load_metadata
        local stored = load_metadata(md)
        if type(stored) ~= "table" then return nil end
        local hash = stored.partial_md5_checksum
        if type(hash) == "string" and hash ~= "" then return hash end
        return nil
    end
end

--- For PATH-keyed (doc/dir) JSONs: does the book exist at its recorded path?
--- @return true | false | nil   (nil = path undeterminable → fail-closed upstream)
function OrphanAdapters.json_book_name_present(deps, entry)
    assert(type(deps) == "table", "orphan_adapters: deps table required")
    assert(deps.lfs, "orphan_adapters: lfs required")
    assert(type(entry) == "table", "orphan_adapters: entry required")

    -- Only meaningful for path-keyed modes. (The decision core never calls this
    -- for content-keyed entries, but guard anyway.)
    if entry.klass ~= "doc" and entry.klass ~= "dir" then return nil end

    -- Prefer the recorded doc_path from the sibling metadata.lua.
    local md = sibling_metadata_path(entry.path, deps.lfs)
    if md then
        local load_metadata = deps.load_metadata or default_load_metadata
        local stored = load_metadata(md)
        if type(stored) == "table" then
            local doc_path = stored.doc_path
            if type(doc_path) == "string" and doc_path ~= "" then
                return deps.lfs.attributes(doc_path, "mode") == "file"
            end
        end
    end

    -- Fallback for doc mode: the book sits beside its ".sdr" (the SDR
    -- convention). Reconstruct "<parent>/<book-filename>" from the JSON path.
    if entry.klass == "doc" then
        local sdr_dir = entry.path:match("^(.*)/[^/]+$")          -- the .sdr dir
        local parent = sdr_dir and sdr_dir:match("^(.*)/[^/]+%.sdr$")
        local fname  = entry.path:match("/([^/]+)%.syncery%-[%a]+%.json$")
        if parent and fname then
            return deps.lfs.attributes(parent .. "/" .. fname, "mode") == "file"
        end
    end

    -- Undeterminable → fail-closed upstream.
    return nil
end

-- ---------------------------------------------------------------------------
-- build_deps — assemble the real-world getters into one deps table
-- ---------------------------------------------------------------------------
--
-- This is the production wiring: it resolves the four trees and home_dir from
-- KOReader / Syncery settings and returns a deps table whose four functions are
-- exactly what `OrphanCleanup.scan` expects. Every external access is GUARDED
-- (pcall + type checks); a missing piece (older KOReader, absent setting,
-- unavailable tree) degrades to "not contributing", never an error.
--
-- The shape:
--   * present_book_hashes    — home_dir (BASE) ∪ Syncthing folders (OPPORTUNISTIC)
--   * syncery_jsons          — synceryhash tree + doc roots (home ∪ folders)
--                              + DataStorage dir tree + DataStorage hash tree
--   * json_book_hash / json_book_name_present — the resolvers above
--
-- `opts` lets callers / tests override any piece without monkey-patching:
--   opts.lfs, opts.home_dir(), opts.configured_roots(), opts.book_content_id(p),
--   opts.synceryhash_root(), opts.dir_tree_root(), opts.hash_tree_root().
--
-- @param opts table|nil  Optional overrides (see above).
-- @return table  A deps table for OrphanCleanup.scan.

-- Resolve KOReader's home_dir (the canonical books folder), or nil.
-- G_reader_settings "home_dir" first; fall back to filemanagerutil.getDefaultDir().
local function resolve_home_dir()
    local grs = rawget(_G, "G_reader_settings")
    if grs and type(grs.readSetting) == "function" then
        local ok, v = pcall(function() return grs:readSetting("home_dir") end)
        if ok and type(v) == "string" and v ~= "" then return v end
    end
    local ok_fmu, fmu = pcall(require, "apps/filemanager/filemanagerutil")
    if ok_fmu and fmu and type(fmu.getDefaultDir) == "function" then
        local ok, v = pcall(fmu.getDefaultDir)
        if ok and type(v) == "string" and v ~= "" then return v end
    end
    return nil
end

-- Syncery's synceryhash tree root, or nil.
local function resolve_synceryhash_root()
    local ok_sm, StorageMode = pcall(require, "syncery_storage_mode")
    if not ok_sm or not StorageMode or type(StorageMode.get_hash_root) ~= "function" then
        return nil
    end
    local ok, root = pcall(StorageMode.get_hash_root)
    if not ok or type(root) ~= "string" or root == "" then return nil end
    return root .. "/synceryhash"
end

-- A guarded DataStorage dir getter (getDocSettingsDir / getDocSettingsHashDir).
local function resolve_datastorage_dir(method, lfs)
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds or not DataStorage or type(DataStorage[method]) ~= "function" then
        return nil
    end
    local ok, dir = pcall(function() return DataStorage[method](DataStorage) end)
    if not ok or type(dir) ~= "string" or dir == "" then return nil end
    if lfs and lfs.attributes(dir, "mode") ~= "directory" then return nil end
    return dir
end

-- Configured roots = Syncery's Syncthing folder paths (OPPORTUNISTIC additive).
local function resolve_configured_roots()
    local ok_set, Settings = pcall(require, "syncery_settings")
    if not ok_set or not Settings or type(Settings.get_syncthing_folder) ~= "function" then
        return nil
    end
    local ok, folder = pcall(Settings.get_syncthing_folder)
    if not ok or type(folder) ~= "table" then return nil end
    local roots = {}
    if type(folder.path) == "string" and folder.path ~= "" then
        roots[#roots + 1] = folder.path
    end
    return roots
end

function OrphanAdapters.build_deps(opts)
    opts = opts or {}

    local lfs = opts.lfs
    if not lfs then
        local ok_util, Util = pcall(require, "syncery_util")
        if ok_util and Util and type(Util.get_lfs) == "function" then
            lfs = Util.get_lfs()
        end
        if not lfs then
            local ok_lfs, real = pcall(require, "libs/libkoreader-lfs")
            if ok_lfs then lfs = real end
        end
    end

    local home_dir       = opts.home_dir       or resolve_home_dir
    local configured     = opts.configured_roots or resolve_configured_roots
    local synceryhash    = opts.synceryhash_root or resolve_synceryhash_root
    local dir_tree       = opts.dir_tree_root  or function() return resolve_datastorage_dir("getDocSettingsDir", lfs) end
    local hash_tree      = opts.hash_tree_root or function() return resolve_datastorage_dir("getDocSettingsHashDir", lfs) end

    -- book content id: production uses Paths._book_content_id (cache-first).
    local book_content_id = opts.book_content_id
    if not book_content_id then
        local ok_paths, Paths = pcall(require, "syncery_ann/paths")
        if ok_paths and Paths and type(Paths._book_content_id) == "function" then
            book_content_id = function(p) return Paths._book_content_id(p) end
        else
            book_content_id = function(_) return nil end
        end
    end

    -- doc roots for JSON enumeration = home_dir ∪ configured roots (the same
    -- union present_book_hashes uses, so the two stay consistent).
    local function doc_roots()
        local roots, seen = {}, {}
        local function add(p)
            if type(p) == "string" and p ~= "" and not seen[p] then
                seen[p] = true; roots[#roots + 1] = p
            end
        end
        add(home_dir())
        local cfg = configured()
        if type(cfg) == "table" then for _, r in ipairs(cfg) do add(r) end end
        return roots
    end

    -- The metadata loader (dofile by default; overridable for tests).
    local load_metadata = opts.load_metadata

    return {
        present_book_hashes = function()
            return OrphanAdapters.present_book_hashes({
                lfs = lfs,
                home_dir = home_dir,
                configured_roots = configured,
                book_content_id = book_content_id,
                is_book_file = opts.is_book_file,
                max_depth = opts.max_depth,
            })
        end,
        syncery_jsons = function()
            return OrphanAdapters.syncery_jsons({
                lfs = lfs,
                synceryhash_root = synceryhash,
                doc_roots = doc_roots,
                dir_tree_root = dir_tree,
                hash_tree_root = hash_tree,
                max_depth = opts.max_depth,
            })
        end,
        json_book_hash = function(entry)
            return OrphanAdapters.json_book_hash({ lfs = lfs, load_metadata = load_metadata }, entry)
        end,
        json_book_name_present = function(entry)
            return OrphanAdapters.json_book_name_present({ lfs = lfs, load_metadata = load_metadata }, entry)
        end,
    }
end

-- ---------------------------------------------------------------------------
-- display_name — a human-readable label for an orphan entry (confirm-with-names)
-- ---------------------------------------------------------------------------
--
-- The confirm dialog shows the BOOK each orphaned JSON belonged to, so the user
-- can veto a deletion for a book they know still exists (the home_dir-
-- completeness backstop). The name source depends on the location:
--
--   * doc / dir / hashdocsettings : the JSON filename is "<book>.syncery-*.json",
--     so the book filename ("<book>") is recoverable directly from the path.
--   * synceryhash : the JSON is "<hash>/syncery-*.json" — keyed by content hash
--     with NO readable name. We fall back to "Book <short-hash>" (the hash from
--     the containing dir), so the row is at least identifiable/stable.
--
-- Pure string logic; no filesystem access.
--
-- @param entry table { path=, klass= }
-- @return string A label suitable for a confirm list.
function OrphanAdapters.display_name(entry)
    if type(entry) ~= "table" or type(entry.path) ~= "string" then
        return "?"
    end

    if entry.klass == "synceryhash" then
        -- Only the content hash is available (dir name containing the JSON).
        local hash = entry.path:match("/synceryhash/[^/]+/([^/]+)/[^/]+$")
        if hash and hash ~= "" then
            return "Book " .. hash:sub(1, 10)
        end
        return "Book (unknown)"
    end

    -- doc / dir / hashdocsettings: "<book>.syncery-{progress,annotations}.json".
    local book = entry.path:match("/([^/]+)%.syncery%-[%a]+%.json$")
    if book and book ~= "" then
        return book
    end

    -- Fallback: the bare filename.
    return entry.path:match("/([^/]+)$") or entry.path
end

return OrphanAdapters
