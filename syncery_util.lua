-- syncery_util.lua – Shared helpers used across the plugin

local logger = require("logger")
local Util = {}

function Util.get_lfs()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    return ok and lfs or nil
end

function Util.ensure_dir(path)
    if not path or path == "" then return end
    local lfs = Util.get_lfs()
    if lfs then
        local parts   = {}
        local partial = path:match("^/") and "/" or ""
        for part in path:gmatch("[^/\\]+") do parts[#parts + 1] = part end
        for __, part in ipairs(parts) do
            partial = partial .. part .. "/"
            if not lfs.attributes(partial, "mode") then pcall(lfs.mkdir, partial) end
        end
    else
        os.execute("mkdir -p '" .. path:gsub("'", "'\\''") .. "' 2>/dev/null")
    end
end

function Util.file_mtime(path)
    local lfs = Util.get_lfs()
    if not lfs then return 0 end
    local attr = lfs.attributes(path)
    return (attr and attr.modification) or 0
end

-- Move a file from src to dst, robust against Android FUSE/SAF.
--
-- WHY THIS EXISTS
--
-- The storage-mode migration helpers in main.lua (_migrateBookFiles,
-- migrateSingleBook) move real annotation/progress
-- files across directories.  They used a bare os.rename(src, dst).
-- On Android, when the two paths straddle a FUSE/SAF boundary, a
-- cross-directory rename can fail outright -- os.rename returns nil.
-- This is NOT the atomic-write bug class (a failed move is safe:
-- the source is left intact and the migration simply skips that
-- book -- no data loss, no corruption).  But it IS an Android
-- robustness gap: the migration silently does nothing on the
-- affected files.
--
-- THE FIX: try os.rename first (fast, atomic, the common case on
-- every non-Android platform and within a single Android volume).
-- Only if it fails, fall back to copy-then-delete: stream the bytes
-- to the destination, then remove the source.  The copy is a plain
-- io.open write -- it introduces NO new unconditional os.rename, so
-- it does not reopen the atomic-write hazard the rest of the
-- codebase guards against.
--
-- FAILURE SEMANTICS preserved from the old bare os.rename: a move
-- that cannot complete leaves the SOURCE intact and returns false.
-- The destination is never left half-written that the caller would
-- mistake for success: if the copy aborts mid-stream the partial
-- destination is removed before returning false.
--
-- @param src string source path.
-- @param dst string destination path.
-- @return boolean true if the file now lives at dst.
function Util.move_file(src, dst)
    if not src or not dst or src == "" or dst == "" then return false end

    -- Fast path: a plain rename.  Works everywhere except a
    -- cross-volume move on Android FUSE/SAF.
    if os.rename(src, dst) then
        return true
    end

    -- Fallback: copy-then-delete.  Reached only when os.rename failed.
    local in_f = io.open(src, "rb")
    if not in_f then
        -- No readable source -- nothing we can do; report failure.
        logger.warn("Syncery Util.move_file: cannot open source " ..
            tostring(src))
        return false
    end

    local out_f = io.open(dst, "wb")
    if not out_f then
        in_f:close()
        logger.warn("Syncery Util.move_file: cannot open destination " ..
            tostring(dst))
        return false
    end

    -- Stream in chunks so a large file does not balloon memory.
    local copy_ok = true
    while true do
        local chunk = in_f:read(64 * 1024)
        if not chunk then break end
        local wrote = out_f:write(chunk)
        if not wrote then copy_ok = false; break end
    end
    in_f:close()
    out_f:close()

    if not copy_ok then
        -- Copy aborted mid-stream.  Remove the partial destination so
        -- the caller cannot mistake it for a completed move, and leave
        -- the source intact (same safe failure as a failed rename).
        os.remove(dst)
        logger.warn("Syncery Util.move_file: copy failed for " ..
            tostring(src) .. " -> " .. tostring(dst))
        return false
    end

    -- Copy reported success, but on an unreliable cross-volume FS (Android
    -- SAF, USBMS) a write can return success yet leave dst TRUNCATED.  We
    -- must not delete src on a truncated dst: doing so loses data, and a
    -- truncated dst that survives would later fool move_one's
    -- "destination exists -> drop the stale source" path (migration_matrix
    -- Section E/H) into deleting the intact source on the next pass.  So
    -- verify the copy landed at full size first.  This is a raw byte copy
    -- (no transform), so a genuinely complete copy ALWAYS yields equal
    -- sizes; a mismatch can only mean truncation.  Cheap: two stats, no
    -- re-read.  On mismatch, behave exactly like a mid-stream copy abort
    -- (drop the bad dst, keep src, report failure) -- which lets the next
    -- migration pass re-attempt the copy from the intact source.
    local lfs = Util.get_lfs()
    if lfs then
        local src_size = lfs.attributes(src, "size")
        local dst_size = lfs.attributes(dst, "size")
        if src_size and dst_size and src_size ~= dst_size then
            os.remove(dst)
            logger.warn("Syncery Util.move_file: size mismatch after copy " ..
                tostring(src) .. " (" .. tostring(src_size) .. ") -> " ..
                tostring(dst) .. " (" .. tostring(dst_size) ..
                "); keeping source")
            return false
        end
    end

    -- Copy succeeded; drop the source to complete the move.  If the
    -- remove fails the data is still safe at dst -- worst case the
    -- source lingers and the next migration pass skips it (the
    -- destination-exists check guards re-copying).
    os.remove(src)
    return true
end

-- Returns the current Unix timestamp in integer seconds (POSIX epoch),
-- scale-compatible with `os.time()`. Internally prefers KOReader's
-- `ffi/util.gettime()`, which returns (sec, usec) — we keep only `sec`
-- because every timestamp we persist in JSON / doc_settings is in whole
-- seconds. Discarding `usec` explicitly avoids accidentally leaking the
-- second return value into multi-arg call sites or table tail positions.
function Util.now()
    local ok_ffi, ffi_util = pcall(require, "ffi/util")
    if ok_ffi and ffi_util and type(ffi_util.gettime) == "function" then
        local sec = ffi_util.gettime()
        return sec
    end
    return os.time()
end

local _seeded = false
function Util.seed_once()
    if _seeded then return end
    _seeded = true
    local seed = os.time()
    local ok_sock, sock = pcall(require, "socket")
    if ok_sock and sock and sock.gettime then seed = seed + math.floor(sock.gettime() * 1000) end
    local f = io.open("/dev/urandom", "rb")
    if f then
        local bytes = f:read(8); f:close()
        if bytes and #bytes == 8 then
            for i = 1, 8 do seed = seed * 256 + bytes:byte(i) end
        end
    end
    seed = (seed + math.floor(collectgarbage("count") * 1024)) % 2 ^ 31
    math.randomseed(seed)
    for _ = 1, 5 do math.random() end
end

local _counters = {}
function Util.generate_id(prefix)
    Util.seed_once()
    prefix = prefix or "id"
    _counters[prefix] = ((_counters[prefix] or 0) + 1) % 1000000
    local t = {}
    for _ = 1, 8 do t[#t + 1] = string.format("%04x", math.random(0, 0xffff)) end
    return string.format("%s_%d_%06d_%s", prefix, os.time(), _counters[prefix], table.concat(t, ""))
end

-- UTF-8 safe trimming
function Util.trim(s)
    if type(s) ~= "string" then return s end
    local ok, kutil = pcall(require, "util")
    if ok and kutil and type(kutil.trim) == "function" then
        return kutil.trim(s) -- KOReader's native C/Lua string util is UTF-8 safe
    end
    return s:match("^%s*(.-)%s*$") -- Fallback
end

function Util.escape_pattern(s) return (s:gsub("([^%w])", "%%%1")) end

function Util.file_extension(path)
    if type(path) ~= "string" then return "" end
    local ext = path:match("%.([^.\\/]+)$")
    return ext and ext:lower() or ""
end

-- Recognized book/document file extensions (KOReader's readable formats).
Util.BOOK_EXTENSIONS = {
    epub = true, mobi = true, azw = true, azw3 = true, azw4 = true, kfx = true,
    fb2 = true, fb3 = true, pdf = true, djvu = true, djv = true, cbz = true,
    cbr = true, cbt = true, txt = true, html = true, htm = true, xhtml = true,
    doc = true, docx = true, rtf = true, chm = true, prc = true, pdb = true,
    tcr = true, md = true, opf = true,
}

-- Strip a trailing book-file extension from a display TITLE, but ONLY if it is a
-- recognized one.  A synceryhash `title.txt` caches getBookTitle() -- a metadata
-- title (which may legitimately contain a dot, e.g. "Dr. No", "Vol. 1") or a
-- basename fallback -- and so normally has NO extension.  This strip exists only
-- to clean the rare value that IS a filename (junk metadata whose title is
-- literally "mybook.epub", or a legacy cache that stored a filename); it must
-- NOT touch ordinary titles that merely contain a dot.  (Real FILENAMES, where
-- the last dot always IS the extension, use an unconditional basename strip
-- instead -- this helper is for titles only.)
function Util.strip_book_extension(name)
    if type(name) ~= "string" then return name end
    local stem, ext = name:match("^(.-)%.([^.\\/]+)$")
    if stem and stem ~= "" and ext and Util.BOOK_EXTENSIONS[ext:lower()] then
        return stem
    end
    return name
end

-- Recursively convert cdata geometry objects to plain Lua tables
-- so doc_settings can persist them safely and dofile() won't crash.
function Util.sanitize_for_lua(val)
    if type(val) == "cdata" then
        local mt = getmetatable(val)
        if mt and mt.__index then
            local ok_x, x = pcall(function() return tonumber(val.x) end)
            local ok_y, y = pcall(function() return tonumber(val.y) end)
            local ok_w, w = pcall(function() return tonumber(val.w) end)
            local ok_h, h = pcall(function() return tonumber(val.h) end)
            if ok_x and ok_y and ok_w and ok_h and x and y and w and h then
                return { x = x, y = y, w = w, h = h }
            end
        end
        -- If the cdata doesn't look like a geometry object, drop it
        return nil
    elseif type(val) == "table" then
        local res = {}
        for k, v in pairs(val) do
            local clean_v = Util.sanitize_for_lua(v)
            if clean_v ~= nil then
                res[k] = clean_v
            end
        end
        return res
    end
    return val
end


-- ── Device identity (G_reader_settings) ──────────────────────────────────────
function Util.get_device_id()
    -- Syncery's device identity IS KOReader's own device_id: a stable random
    -- UUID generated once at first startup (reader.lua) and already used to
    -- stamp native annotations (readerannotation.lua). Reusing it keeps the
    -- sync identity aligned with KOReader's native annotation provenance and
    -- avoids maintaining a second identifier.
    if G_reader_settings then
        local id = G_reader_settings:readSetting("device_id")
        if id and id ~= "" then return id end
    end
    -- Defensive fallback: KOReader always sets device_id at startup, but a
    -- bare test harness (no reader.lua run) does not. Generate and persist
    -- our own id so identity stays stable in that environment.
    local own = G_reader_settings and G_reader_settings:readSetting("syncery_device_id")
    if not own or own == "" then
        own = Util.generate_id("dev")
        if G_reader_settings then
            G_reader_settings:saveSetting("syncery_device_id", own)
        end
    end
    return own
end

function Util.get_device_label()
    local function getSetting(key, default)
        if not G_reader_settings then return default end
        return G_reader_settings:readSetting("syncery_" .. key) or default
    end
    local label = getSetting("device_label")
    if not label or label == "" then
        local ok, dev = pcall(require, "device")
        label = (ok and dev and dev.model) or "KOReader"
        if G_reader_settings then
            G_reader_settings:saveSetting("syncery_device_label", label)
        end
    end
    return label
end

-- Persist a new device label. Trims, rejects empty/whitespace, and clips to
-- 50 codepoints. Returns the CANONICAL value actually saved (so callers can
-- mirror exactly what persisted — finding F3: mirroring the raw input left
-- the session and the settings divergent), or false when nothing was saved.
function Util.set_device_label(new_label)
    new_label = Util.trim(new_label)
    if not new_label or #new_label == 0 then return false end

    -- Enforce 50‑character codepoint limit using KOReader's native UTF‑8 helpers.
    local ok_util, kutil = pcall(require, "util")
    if ok_util and kutil and type(kutil.utf8charcount) == "function"
       and type(kutil.utf8sub) == "function" then
        if kutil.utf8charcount(new_label) > 50 then
            new_label = kutil.utf8sub(new_label, 1, 50)
        end
    end

    if G_reader_settings then
        G_reader_settings:saveSetting("syncery_device_label", new_label)
        return new_label
    end
    return false
end

-- ── State directory ──────────────────────────────────────────────────────────
local _state_dir_cache
function Util.state_dir()
    if not _state_dir_cache then
        local DataStorage = require("datastorage")
        local ok, sdir = pcall(function() return DataStorage:getSettingsDir() end)
        local base = (ok and sdir) and (sdir .. "/syncery") or "./syncery"
        local lfs = Util.get_lfs()
        if lfs and not lfs.attributes(base, "mode") then pcall(lfs.mkdir, base) end
        if base:sub(-1) ~= "/" and base:sub(-1) ~= "\\" then base = base .. "/" end
        _state_dir_cache = base
    end
    return _state_dir_cache
end

-- ── Transport-context label ──────────────────────────────────────────────────
--- The label naming which transport(s) carried a sync, for the journal's
--- `transport` field.  Syncthing and cloud are INDEPENDENT -- cloud runs
--- ALONGSIDE Syncthing (a fallback for users without it), not instead -- so
--- either, both, or neither may be on.  The label names whichever are active:
--- "syncthing+cloud" / "cloud" / "syncthing", or "local" when no transport
--- carries the merge.
function Util.transport_label(use_syncthing, use_cloud)
    local parts = {}
    if use_syncthing then parts[#parts + 1] = "syncthing" end
    if use_cloud      then parts[#parts + 1] = "cloud" end
    if #parts == 0 then return "local" end
    return table.concat(parts, "+")
end

return Util