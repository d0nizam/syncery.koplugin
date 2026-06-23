-- =============================================================================
-- spec/json_store_skip_unchanged_spec.lua
-- =============================================================================
--
-- Regression spec for the skip-if-unchanged optimization in
-- syncery_ann/json_store.lua's JsonStore.write.
--
-- When the canonical (sort_keys) serialization of a state is BYTE-IDENTICAL to
-- what the target file already holds, JsonStore.write skips the write entirely
-- (no temp+rename on POSIX, no direct overwrite on Android) and returns true
-- with the "unchanged" diagnostic.  This removes redundant flash erase/program
-- cycles on every page-turn save where only the progress file actually moved:
-- the annotation envelope and last-sync files serialize unchanged and are
-- skipped, while the progress file (whose position changed) is rewritten.
--
-- The optimization is a READ-COMPARE against the CURRENT on-disk bytes, NOT an
-- in-memory hash of the last write.  That distinction is the whole point: the
-- Syncthing daemon rewrites these files out-of-band as it delivers a peer's
-- update, so only a comparison against what is on disk right now is correct.
-- T3 pins exactly that property -- the case an in-memory hash gets wrong.
--
-- Tests:
--   T1  identical content twice  -> the second call skips (diag "unchanged",
--       zero write-opens -- no write syscall at all).
--   T2  changed content          -> the write runs, the file holds new bytes.
--   T3  CORRECTNESS: the file is changed out-of-band between two writes of the
--       same state -> JsonStore.write compares against the new on-disk bytes
--       (not a cache), detects the difference, and writes, restoring intent.
-- =============================================================================


local h = require("spec.test_helpers")
local test_root = "/tmp/syncery_json_store_skip_unchanged_spec_" .. tostring(os.time())
h.setup(test_root)


-- Force the POSIX path (temp + atomic rename).  The skip sits ABOVE the
-- platform branch, so POSIX is the representative case; the Android branch is
-- covered by json_store_android_spec.
package.loaded["device"] = {
    isAndroid = function(_) return false end,
}

local JsonStore = require("syncery_ann/json_store")
JsonStore._reset_platform_cache()


-- Run `fn` while counting how many times io.open is asked for a WRITE-mode
-- handle (mode containing "w").  The skip's existence-read uses "rb", so a
-- skipped write performs ZERO write-opens; a real POSIX write opens the temp
-- file with "wb" exactly once.  Counting write-opens is therefore an exact
-- detector of "did a write syscall actually happen".
local function count_write_opens(fn)
    local real_open = io.open
    local writes = 0
    io.open = function(path, mode)
        if mode and mode:find("w") then
            writes = writes + 1
        end
        return real_open(path, mode)
    end
    local ok, err = pcall(fn)
    io.open = real_open  -- restore before any assertion/teardown
    assert(ok, err)
    return writes
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local c = f:read("*a")
    f:close()
    return c
end


-- ---------------------------------------------------------------------------
-- T1: identical content twice -> the second write is skipped entirely.
-- ---------------------------------------------------------------------------
do
    local path = test_root .. "/t1_unchanged.json"
    os.remove(path)

    local state = { a = 1, b = "two", nested = { x = true } }

    -- First write: the file does not exist -> a real write, "ok".
    local ok1, diag1 = JsonStore.write(path, state)
    h.assert_true(ok1, "T1: first write succeeds")
    h.assert_equal(diag1, "ok", "T1: first write reports 'ok' (a real write happened)")

    -- Second write of the SAME state: must skip, with no write syscall.
    local diag2
    local writes = count_write_opens(function()
        local ok2
        ok2, diag2 = JsonStore.write(path, state)
        h.assert_true(ok2, "T1: second write returns success")
    end)
    h.assert_equal(diag2, "unchanged",
        "T1: second identical write reports 'unchanged'")
    h.assert_equal(writes, 0,
        "T1: second identical write performs NO write-open (the write is skipped)")

    -- And the file still holds the content (skipping did not erase it).
    local on_disk = read_file(path)
    h.assert_true(on_disk ~= nil and on_disk:find("two") ~= nil,
        "T1: the file still holds its content after the skipped write")
end


-- ---------------------------------------------------------------------------
-- T2: changed content -> the write runs and the new bytes land.
-- ---------------------------------------------------------------------------
do
    local path = test_root .. "/t2_changed.json"
    os.remove(path)

    JsonStore.write(path, { v = "first" })

    local diag
    local writes = count_write_opens(function()
        local ok
        ok, diag = JsonStore.write(path, { v = "second" })
        h.assert_true(ok, "T2: changed write succeeds")
    end)
    h.assert_equal(diag, "ok",
        "T2: changed content reports 'ok' (not skipped)")
    h.assert_true(writes >= 1,
        "T2: changed content performs a real write-open")

    local on_disk = read_file(path)
    h.assert_true(on_disk ~= nil and on_disk:find("second") ~= nil,
        "T2: the file holds the new content after a changed write")
    h.assert_true(on_disk:find("first") == nil,
        "T2: the old content is gone")
end


-- ---------------------------------------------------------------------------
-- T3: CORRECTNESS -- compares against the CURRENT disk bytes, not a cache.
--
-- This is the case an in-memory "last bytes I wrote" hash gets wrong: after
-- writing X, an out-of-band writer (the Syncthing daemon) replaces the file
-- with Z.  Writing X again must NOT be skipped (X != the on-disk Z); the
-- read-compare sees the difference and restores X.
-- ---------------------------------------------------------------------------
do
    local path = test_root .. "/t3_out_of_band.json"
    os.remove(path)

    local state_x = { who = "X", n = 1 }

    -- Write X.
    JsonStore.write(path, state_x)

    -- Out-of-band: a different writer clobbers the file with unrelated bytes.
    do
        local f = assert(io.open(path, "wb"))
        f:write('{"who":"Z","n":999}')
        f:close()
    end

    -- Write X again.  A cache keyed on "I last wrote X" would skip and leave Z
    -- on disk (the bug).  Read-compare instead sees on-disk Z != encoded X and
    -- writes, restoring X.
    local diag
    local writes = count_write_opens(function()
        local ok
        ok, diag = JsonStore.write(path, state_x)
        h.assert_true(ok, "T3: write after out-of-band change succeeds")
    end)
    h.assert_equal(diag, "ok",
        "T3: the out-of-band change is detected -> a real write happens (NOT skipped)")
    h.assert_true(writes >= 1,
        "T3: a real write-open happens after the out-of-band change")

    local on_disk = read_file(path)
    h.assert_true(on_disk ~= nil and on_disk:find("X") ~= nil,
        "T3: the file is restored to the intended content X")
    h.assert_true(on_disk:find("999") == nil,
        "T3: the out-of-band Z bytes are gone (X overwrote them)")
end
