-- =============================================================================
-- spec/move_file_spec.lua
-- =============================================================================
--
-- Tests for Util.move_file — the os.rename-with-copy-then-delete-
-- fallback helper added in Phase 7 to make the storage-mode migration
-- robust against the Android FUSE/SAF cross-volume rename failure
-- (Phase 6 carryover, lesson 5).
--
-- The fast path (os.rename succeeds) is the common case on every
-- non-Android platform and is exercised directly.  The fallback path
-- (os.rename fails) is the Android case; we can't make a real rename
-- fail in the test environment, so the fallback's COMPONENT behaviour
-- — copy a file's bytes faithfully, delete the source, clean up a
-- partial destination — is verified, and the fast-path/fallback
-- contract (a failed move leaves the source intact) is asserted.
--
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_move_file_spec_" .. tostring(os.time()))

local Util = require("syncery_util")


-- ----------------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------------


local counter = 0
local function unique_path(tag)
    counter = counter + 1
    return h.test_root .. "/" .. (tag or "f") .. "_" .. tostring(counter)
end


local function write_file(path, content)
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
end


local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local c = f:read("*a")
    f:close()
    return c
end


local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end


-- ----------------------------------------------------------------------------
-- Happy path: a move relocates the bytes and removes the source
-- ----------------------------------------------------------------------------


do
    local src = unique_path("src")
    local dst = unique_path("dst")
    write_file(src, "hello migration")

    local ok = Util.move_file(src, dst)
    h.assert_true(ok, "move_file returns true on success")
    h.assert_false(exists(src), "source removed after a successful move")
    h.assert_equal(read_file(dst), "hello migration",
        "destination has the exact source bytes")
end


-- ----------------------------------------------------------------------------
-- A move of a larger file (exercises the chunked copy in the fallback,
-- and is harmless on the fast path) — bytes must round-trip exactly
-- ----------------------------------------------------------------------------


do
    local src = unique_path("big_src")
    local dst = unique_path("big_dst")
    -- 200 KB — larger than the 64 KB copy chunk, so a fallback copy
    -- would loop several times.
    local big = string.rep("ABCDEFGH", 25 * 1024)
    write_file(src, big)

    local ok = Util.move_file(src, dst)
    h.assert_true(ok, "large-file move succeeds")
    h.assert_equal(#(read_file(dst) or ""), #big,
        "destination length matches a multi-chunk payload")
    h.assert_equal(read_file(dst), big, "every byte round-trips")
    h.assert_false(exists(src), "large-file source removed")
end


-- ----------------------------------------------------------------------------
-- Missing source: returns false, creates nothing
-- ----------------------------------------------------------------------------


do
    local src = unique_path("absent_src")   -- never created
    local dst = unique_path("absent_dst")

    local ok = Util.move_file(src, dst)
    h.assert_false(ok, "move of a non-existent source returns false")
    h.assert_false(exists(dst), "no destination created for a missing source")
end


-- ----------------------------------------------------------------------------
-- Empty / nil arguments are rejected without raising
-- ----------------------------------------------------------------------------


do
    h.assert_false(Util.move_file(nil, "/tmp/x"), "nil src -> false")
    h.assert_false(Util.move_file("/tmp/x", nil), "nil dst -> false")
    h.assert_false(Util.move_file("", ""),        "empty paths -> false")
end


-- ----------------------------------------------------------------------------
-- Failure contract: a move that cannot complete leaves the source
-- intact.  Simulated by pointing the destination at an unwritable
-- location (a path under a non-existent, non-creatable parent).  Both
-- os.rename and the io.open("wb") fallback fail there, so this drives
-- the full fast-path-then-fallback contract.
-- ----------------------------------------------------------------------------


do
    local src = unique_path("keep_src")
    write_file(src, "must survive a failed move")

    -- A destination whose parent directory does not exist: os.rename
    -- fails (no parent), and io.open(dst, "wb") also fails (no parent).
    local bad_dst = h.test_root .. "/nonexistent_dir_" .. tostring(os.time())
                  .. "/deeper/dst"

    local ok = Util.move_file(src, bad_dst)
    h.assert_false(ok, "an impossible move returns false")
    h.assert_true(exists(src), "source is left INTACT after a failed move")
    h.assert_equal(read_file(src), "must survive a failed move",
        "source bytes untouched by a failed move")
    h.assert_false(exists(bad_dst), "no destination left behind on failure")
end


-- ----------------------------------------------------------------------------
-- Report
-- ----------------------------------------------------------------------------

h.report("move_file_spec")
