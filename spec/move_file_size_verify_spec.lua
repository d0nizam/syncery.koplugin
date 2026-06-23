-- =============================================================================
-- spec/move_file_size_verify_spec.lua
-- =============================================================================
--
-- Tests the size-verify guard in Util.move_file's copy-fallback.
--
-- The fallback runs only when os.rename fails (cross-volume on Android
-- SAF/USBMS). On such filesystems a write can report success yet leave the
-- destination TRUNCATED. Before this guard, move_file deleted the source on
-- copy-success without checking dst size, losing data; worse, a truncated dst
-- that survived would later fool move_one's "destination exists -> drop the
-- stale source" path into deleting the intact source on the next pass.
--
-- We can't make a real same-volume rename fail, and we can't make a real write
-- silently truncate, so we inject both:
--   * os.rename -> nil  (forces the copy-fallback)
--   * io.open(dst,"wb")  returns a handle whose :write SILENTLY drops bytes
--     (returns success but writes a prefix), producing a short dst.
--
-- Assertions: move_file returns false, the SOURCE survives, the truncated dst
-- is REMOVED (so the next migration pass re-attempts from the intact source).
-- A control case (faithful copy via the fallback) still succeeds + removes src.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_move_verify_spec_" .. tostring(os.time()))

local Util = require("syncery_util")

local function unique_path(tag)
    return h.test_root .. "/" .. tag .. "_" .. tostring(os.time()) .. "_"
         .. tostring(math.random(1, 1e6))
end
local function write_file(path, content)
    local f = assert(io.open(path, "wb")); f:write(content); f:close()
end
local function read_file(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local c = f:read("*a"); f:close(); return c
end
local function exists(path)
    local f = io.open(path, "rb"); if f then f:close(); return true end
    return false
end

local real_rename = os.rename
local real_open = io.open

-- ---------------------------------------------------------------------------
-- CASE 1 — truncated copy: size-verify must catch it, keep src, drop dst.
-- ---------------------------------------------------------------------------
do
    local src = unique_path("trunc_src")
    local dst = unique_path("trunc_dst")
    write_file(src, string.rep("X", 5000))   -- 5000 bytes

    -- Force the copy-fallback.
    os.rename = function() return nil end

    -- Wrap io.open so the DESTINATION handle truncates: its :write reports
    -- success but only ever commits the first chunk, leaving dst short. The
    -- SOURCE handle (and everything else) is the real thing.
    io.open = function(path, mode)
        if path == dst and mode == "wb" then
            local real_handle = real_open(path, mode)
            local committed = false
            return {
                write = function(_self, chunk)
                    if not committed then
                        -- Commit only the first 100 bytes of the first chunk,
                        -- then claim success for everything (silent truncation).
                        real_handle:write(chunk:sub(1, 100))
                        committed = true
                    end
                    return true  -- report success regardless (the FS "lie")
                end,
                close = function(_self) return real_handle:close() end,
                read = function(_self, ...) return real_handle:read(...) end,
            }
        end
        return real_open(path, mode)
    end

    local ok = Util.move_file(src, dst)

    -- Restore immediately so assertions/teardown use the real funcs.
    os.rename = real_rename
    io.open = real_open

    h.assert_false(ok, "case1: truncated copy -> move_file returns false")
    h.assert_true(exists(src), "case1: SOURCE kept after a truncated copy")
    h.assert_equal(#(read_file(src) or ""), 5000, "case1: source is intact (full size)")
    h.assert_false(exists(dst), "case1: truncated dst REMOVED (next pass can retry)")
end

-- ---------------------------------------------------------------------------
-- CASE 2 — control: a FAITHFUL copy via the fallback still succeeds.
-- Forces the fallback (rename fails) but lets io.open behave normally, so the
-- copy is complete and sizes match. move_file must succeed and remove src.
-- ---------------------------------------------------------------------------
do
    local src = unique_path("ok_src")
    local dst = unique_path("ok_dst")
    write_file(src, string.rep("Y", 5000))

    os.rename = function() return nil end   -- force fallback, real io.open

    local ok = Util.move_file(src, dst)

    os.rename = real_rename

    h.assert_true(ok, "case2: faithful fallback copy succeeds")
    h.assert_true(exists(dst), "case2: destination created")
    h.assert_equal(#(read_file(dst) or ""), 5000, "case2: destination full size")
    h.assert_false(exists(src), "case2: source removed after a verified copy")
end

h.teardown()
print("move_file_size_verify_spec: all assertions passed")
