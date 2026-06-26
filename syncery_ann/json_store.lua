-- =============================================================================
-- syncery_ann/json_store.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- It provides the lowest layer of persistence: reading and writing
-- JSON files to disk in a way that doesn't corrupt them when bad
-- things happen (power loss, app crash, full disk).
--
-- Everyone else in the annotation subsystem who touches disk does
-- it through this module, so the safety properties live in one
-- place.
--
--
-- ATOMIC WRITES (the "tmp-then-rename" trick) — POSIX ONLY
--
-- When we save a JSON file on a POSIX filesystem we don't write
-- directly to the final path.  Instead:
--
--   1. Write the new content to a temporary file (path + ".tmp").
--   2. If the write succeeds completely, rename the temp file over
--      the real file.  On POSIX filesystems (Linux, Kindle, Kobo,
--      PocketBook all run native ext2/ext3/ext4 with proper rename
--      semantics) rename is ATOMIC — either the old file is there,
--      or the new one is, never a half-written mix.
--   3. If anything goes wrong during step 1, delete the temp file
--      and leave the original untouched.
--
-- ANDROID IS DIFFERENT
--
-- Android's storage is FUSE-mounted user space (or SAF in recent
-- versions) — `os.rename` across that mount silently fails or
-- partially fails in ways that look like "rename ok but the file
-- never appeared".  Legacy syncery_data.lua learned this the hard
-- way: on Android we MUST overwrite the target directly with a
-- single open() + write() + fsync() + close(), accepting the
-- non-atomic write as the lesser evil.
--
-- The branch lives at the top of `write()`.  Same diagnostic
-- shape from both paths so callers don't need to know which
-- platform they're on.
--
--
-- READ FAILURES ARE NEVER FATAL
--
-- Reading a missing or corrupt file returns "no data, here's the
-- diagnosis" rather than throwing an error.  Callers can then
-- decide whether that's normal (fresh book, file doesn't exist
-- yet) or alarming (file got corrupted, alert the user).
--
-- =============================================================================

local logger = require("logger")
local rapidjson = require("rapidjson")
local util = require("util")

local JsonStore = {}


-- ----------------------------------------------------------------------------
-- Platform detection
-- ----------------------------------------------------------------------------
--
-- Cached because Device:isAndroid() is cheap but called on every
-- write and there's no scenario where it changes mid-session.
-- The cache is invalidated under tests by clearing package.loaded
-- for this module (which happens between specs via
-- spec/run_tests.lua's clear_syncery_modules).

local _is_android_cached = nil
local function _is_android()
    if _is_android_cached == nil then
        local ok, Device = pcall(require, "device")
        _is_android_cached = (ok and Device and type(Device.isAndroid) == "function"
                              and Device:isAndroid()) and true or false
    end
    return _is_android_cached
end


--- Direct write — no atomic rename.  Opens the target for binary
--- write, dumps the encoded text, fsyncs, closes.  Used on Android
--- where rename across FUSE/SAF is unreliable.
---
--- Same caveat as the legacy code: a power loss mid-write on Android
--- CAN leave a partial file.  There's no portable way around that
--- without rename, so the trade-off is "lose this one save but stay
--- functional" vs "every save fails because rename doesn't work".
local function _write_direct(file_path, encoded_text)
    local handle, open_err = io.open(file_path, "wb")
    if not handle then
        logger.warn("Syncery JSON store: open failed for "
            .. tostring(file_path) .. ": " .. tostring(open_err))
        return false, "write_error"
    end
    local write_ok, write_err = handle:write(encoded_text)
    if write_ok then
        handle:flush()
        -- Hint to the kernel to push the page cache to the medium.
        -- Important for e-ink suspend / power loss; on Android the
        -- backing store may be slow flash and the writeback delay
        -- can be seconds.
        local ok_futil, futil = pcall(require, "ffi/util")
        if ok_futil and futil.fsyncOpenedFile then
            futil.fsyncOpenedFile(handle, true)
        end
    end
    handle:close()
    if not write_ok then
        logger.warn("Syncery JSON store: direct write failed: " .. tostring(write_err))
        return false, "write_error"
    end
    return true, "ok"
end


-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------


--- Read a JSON file and decode it into a Lua table.
---
--- Returns two values:
---   * The parsed data (or nil if the read failed).
---   * A diagnostic string explaining what happened.  Possible values:
---       "ok"            — file read and decoded successfully
---       "no_path"       — caller passed nil/empty as file_path
---       "not_found"     — file doesn't exist (probably normal)
---       "empty"         — file exists but has zero bytes
---       "invalid_json"  — file exists but couldn't be parsed
---       "read_error"    — couldn't open the file for reading
---
--- @param file_path string|nil Path to the JSON file.
--- @return table|nil The decoded JSON object, or nil.
--- @return string A diagnostic code.
function JsonStore.read(file_path)
    if not file_path or file_path == "" then
        return nil, "no_path"
    end

    local file_handle = io.open(file_path, "rb")
    if not file_handle then
        return nil, "not_found"
    end

    local file_contents = file_handle:read("*a")
    file_handle:close()

    if not file_contents then
        return nil, "read_error"
    end
    if file_contents == "" then
        return nil, "empty"
    end

    local decode_ok, decoded_data = pcall(rapidjson.decode, file_contents)
    if not decode_ok or type(decoded_data) ~= "table" then
        logger.warn("Syncery JSON store: invalid JSON in " .. tostring(file_path))
        return nil, "invalid_json"
    end

    return decoded_data, "ok"
end


--- Encode a Lua table as JSON and write it to disk.
---
--- On POSIX filesystems (Linux, Kindle, Kobo, PocketBook) this uses
--- the tmp-file-then-rename pattern, so either the new content is
--- fully written or the existing file is left untouched.
---
--- On Android, where rename across FUSE/SAF is unreliable, this
--- falls back to a direct overwrite + fsync.  A power loss mid-write
--- can leave a partial file on that platform — the alternative
--- (attempting rename and seeing every save fail silently) is much
--- worse.  A leftover `.tmp` from an interrupted POSIX write is harmless:
--- `read` only ever opens the main file (the atomic rename guarantees the
--- main file is always a complete prior version), so a stray `.tmp` is
--- ignored garbage, and cross-platform Syncery deployments degrade
--- gracefully.
---
--- @param file_path string Path where the JSON should be written.
--- @param data_table table The Lua table to encode.
--- @return boolean True on success, false on any failure.  "Success" includes
---         the skip-if-unchanged case (the file already holds these exact
---         bytes), reported with the "unchanged" diagnostic below.
--- @return string A diagnostic code: "ok" / "unchanged" / "no_path" /
---         "encode_error" / "write_error" / "rename_error".
function JsonStore.write(file_path, data_table)
    if not file_path or file_path == "" then
        return false, "no_path"
    end

    -- sort_keys: emit object keys in a stable (sorted) order, so the SAME
    -- merged content always serializes to the SAME bytes -- on any device,
    -- regardless of the order keys were inserted into the Lua map.  Annotations
    -- are stored as a position-keyed object, and the merge is a commutative
    -- per-key LWW: two devices that ingest the same changes converge to an
    -- identical state.  Without a stable key order rapidjson follows Lua table
    -- iteration order, which can differ between devices for that identical
    -- state, producing byte-different files; Syncthing (or any folder-sync)
    -- then sees a change to shuttle and can raise a spurious sync-conflict.
    -- Sorting closes that gap: identical state -> identical bytes -> no churn.
    local encode_ok, encoded_text = pcall(rapidjson.encode, data_table,
        { sort_keys = true })
    if not encode_ok or type(encoded_text) ~= "string" then
        logger.warn("Syncery JSON store: encode failed for "
            .. tostring(file_path) .. ": " .. tostring(encoded_text))
        return false, "encode_error"
    end

    -- Skip-if-unchanged.  The encode above is canonical (sort_keys), so an
    -- UNCHANGED state serializes to bytes IDENTICAL to what is already on
    -- disk.  Re-read the existing file and byte-compare: on a match the
    -- desired bytes are already there, so we skip the write entirely (the
    -- POSIX temp+fsync+rename, or the Android direct overwrite).  That avoids
    -- a redundant erase/program cycle -- pure flash wear with NO observable
    -- effect, since the file already holds exactly this content.  A page-turn
    -- save re-runs the merge but, when only progress changed, the annotation
    -- envelope and last-sync files serialize unchanged and are skipped here;
    -- only the progress file (whose position genuinely moved) is rewritten.
    --
    -- Correctness is BY CONSTRUCTION: we compare against the CURRENT on-disk
    -- bytes (not a cached hash), so this stays right even when an out-of-band
    -- writer (the Syncthing daemon delivering a peer's file) has touched the
    -- file -- we skip ONLY when the bytes truly match right now.  A genuine
    -- change (a local edit or a pulled remote) makes the merged content
    -- differ from disk, so the write runs exactly as before.
    --
    -- The read is pcall-guarded because this is a PURE optimization: any I/O
    -- oddity (a handle that won't read, a transient FS error) must fall
    -- through to the normal write path -- it may only fail to optimize, never
    -- turn a save into a failure.
    --
    -- LOAD-BEARING for future readers: because this skips the write, the
    -- file's mtime is NOT bumped on a no-op save.  Intentional.  Any code that
    -- depends on a write side-effect (mtime bump, file touch) must not assume
    -- every save moves the mtime.  MtimeGate (syncery_ann/mtime_gate) stays
    -- correct because it RE-READS the actual mtime after the merge instead of
    -- assuming a bump; the booklist "synced N ago" row now reflects the last
    -- REAL content change rather than the last save cycle (intended).
    local ok_existing, existing = pcall(function()
        local handle = io.open(file_path, "rb")
        if not handle then return nil end
        local contents = handle:read("*a")
        handle:close()
        return contents
    end)
    if ok_existing and existing == encoded_text then
        return true, "unchanged"
    end

    -- Ensure the parent directory exists before writing.  In SDR storage
    -- mode the shared sidecar path follows KOReader's metadata location
    -- (doc / dir / hash) and is NOT pre-created by the path builders the
    -- way hash-mode and last-sync paths are -- so a write could land in a
    -- not-yet-existing `.sdr` dir (e.g. before KOReader's first metadata
    -- flush) and fail.  makePath is mkdir -p: a no-op when the dir already
    -- exists (so hash/last-sync writes are unaffected), and it creates the
    -- intermediate shard + `.sdr` dirs for the hash metadata location.
    local parent = file_path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then
        util.makePath(parent)
    end

    -- Android: skip the atomic-rename dance entirely.  See module
    -- header — rename across FUSE/SAF returns success but doesn't
    -- actually replace the file.
    if _is_android() then
        return _write_direct(file_path, encoded_text)
    end

    -- POSIX: atomic temp + rename.
    local temp_path = file_path .. ".tmp"

    local temp_handle = io.open(temp_path, "wb")
    if not temp_handle then
        return false, "write_error"
    end

    local write_ok, write_err = temp_handle:write(encoded_text)
    -- Flush + fsync the temp file too — otherwise the rename can land
    -- a metadata entry pointing at unflushed data, which on power loss
    -- looks like a 0-byte main file.
    if write_ok then
        temp_handle:flush()
        local ok_futil, futil = pcall(require, "ffi/util")
        if ok_futil and futil.fsyncOpenedFile then
            futil.fsyncOpenedFile(temp_handle, true)
        end
    end
    temp_handle:close()

    if not write_ok then
        os.remove(temp_path)
        logger.warn("Syncery JSON store: write to temp failed: " .. tostring(write_err))
        return false, "write_error"
    end

    local rename_ok = os.rename(temp_path, file_path)
    if not rename_ok then
        os.remove(temp_path)
        return false, "rename_error"
    end

    return true, "ok"
end


--- Test-only: reset the cached Android detection.  Specs that swap
--- the `device` stub mid-test call this to force a re-read.
function JsonStore._reset_platform_cache()
    _is_android_cached = nil
end


--- Encode a Lua table to a canonical JSON string (sorted keys) -- the SAME
--- serialization JsonStore.write uses on disk.  Returns nil on failure.  Lets
--- callers stage in-memory canonical content without a temp file.
function JsonStore.encode(data_table)
    local ok, encoded = pcall(rapidjson.encode, data_table, { sort_keys = true })
    if not ok or type(encoded) ~= "string" then return nil end
    return encoded
end


return JsonStore
