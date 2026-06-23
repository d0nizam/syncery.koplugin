-- =============================================================================
-- spec/json_store_android_spec.lua
-- =============================================================================
--
-- Regression spec for the Android branch in syncery_ann/json_store.lua.
--
-- Legacy syncery_data.lua learned the hard way that `os.rename`
-- across Android's FUSE/SAF storage is unreliable: it silently
-- succeeds without replacing the file, or fails outright, depending
-- on Android version and which kind of storage the user mounted.
-- The legacy code branched on `Device:isAndroid()` and on Android
-- did a direct overwrite + fsync.  Phase 1's json_store.lua dropped
-- that branch and re-introduced the bug — every save on Android
-- went through the rename path and failed.
--
-- This spec ensures the Android branch is back: on Android we MUST
-- write directly to the target path with NO temp file involved, and
-- we MUST NOT crash if rename was about to fail.
--
-- The spec works by stubbing `device` to report
-- `isAndroid() == true`, then writing a file and checking:
--   * The target file contains the new content.
--   * No `.tmp` file is left behind.
--   * The diagnostic is "ok".
--
-- The POSIX path (when isAndroid is false) is the existing behaviour
-- and is exercised by every other json_store call in the suite — we
-- don't re-test it here.
-- =============================================================================


local h = require("spec.test_helpers")
local test_root = "/tmp/syncery_json_store_android_spec_" .. tostring(os.time())
h.setup(test_root)


-- ---------------------------------------------------------------------------
-- Stub Device to report Android, then load JsonStore.
-- ---------------------------------------------------------------------------

package.loaded["device"] = {
    isAndroid = function(_) return true end,
}

local JsonStore = require("syncery_ann/json_store")
JsonStore._reset_platform_cache()  -- make sure isAndroid is re-read


-- ---------------------------------------------------------------------------
-- Direct write succeeds on Android and produces the right content
-- ---------------------------------------------------------------------------

do
    local path = test_root .. "/android_write.json"
    -- Make sure no leftover from prior runs.
    os.remove(path)
    os.remove(path .. ".tmp")

    local ok, diag = JsonStore.write(path, { hello = "world", n = 42 })
    h.assert_true(ok, "android write returns true")
    h.assert_equal(diag, "ok", "android write returns 'ok' diagnostic")

    -- The target exists.
    local f = io.open(path, "rb")
    h.assert_true(f ~= nil, "target file exists after android write")
    local content = f:read("*a")
    f:close()
    h.assert_true(content:find("hello") ~= nil,
        "target file contains the written key")
    h.assert_true(content:find("42") ~= nil,
        "target file contains the written value")

    -- No leftover .tmp file (we didn't go through the rename path).
    local tmp = io.open(path .. ".tmp", "rb")
    h.assert_nil(tmp,
        "android write leaves no .tmp file behind (no rename was attempted)")
end


-- ---------------------------------------------------------------------------
-- Overwrite an existing file works
-- ---------------------------------------------------------------------------

do
    local path = test_root .. "/android_overwrite.json"
    -- Pre-create with old content.
    local pre = io.open(path, "wb")
    pre:write('{"old":"data"}')
    pre:close()

    local ok = JsonStore.write(path, { new = "data" })
    h.assert_true(ok, "android overwrite returns true")

    -- New content is in place.
    local f = io.open(path, "rb")
    local content = f:read("*a")
    f:close()
    h.assert_true(content:find('"new"') ~= nil,
        "android overwrite: new content present")
    h.assert_true(content:find('"old"') == nil,
        "android overwrite: old content gone")
end


-- ---------------------------------------------------------------------------
-- write_error diagnostic when path is unwritable
-- ---------------------------------------------------------------------------

do
    -- Force a write failure with a path whose parent component is a FILE,
    -- not a directory: makePath cannot create it, so io.open fails.  (A
    -- merely-missing dir no longer triggers failure — JsonStore.write now
    -- makePath's it.  This still exercises the write_error path.)
    os.execute("rm -rf '" .. test_root .. "/blocker'")
    os.execute("touch '" .. test_root .. "/blocker'")
    local path = test_root .. "/blocker/file.json"  -- 'blocker' is a file
    local ok, diag = JsonStore.write(path, { x = 1 })
    h.assert_false(ok, "android write through a file-as-dir returns false")
    h.assert_equal(diag, "write_error",
        "android write through a file-as-dir returns 'write_error' diagnostic")
end


-- ---------------------------------------------------------------------------
-- Now flip the stub to NOT-Android and confirm the POSIX path engages
-- (rename happens, .tmp does NOT exist after success).
-- ---------------------------------------------------------------------------

package.loaded["device"] = {
    isAndroid = function(_) return false end,
}
JsonStore._reset_platform_cache()

do
    local path = test_root .. "/posix_write.json"
    os.remove(path)
    os.remove(path .. ".tmp")

    local ok, diag = JsonStore.write(path, { posix = true })
    h.assert_true(ok, "posix write returns true")
    h.assert_equal(diag, "ok", "posix write returns 'ok'")

    -- Target is in place.
    local f = io.open(path, "rb")
    h.assert_true(f ~= nil, "target file exists after posix write")
    f:close()

    -- And NO .tmp left behind (rename consumed it).
    local tmp = io.open(path .. ".tmp", "rb")
    h.assert_nil(tmp, "posix write: .tmp consumed by rename")
end


-- ---------------------------------------------------------------------------
-- P1 regression: write into a NOT-yet-existing sidecar dir must succeed.
--
-- In SDR storage mode the shared sidecar path follows KOReader's metadata
-- location and is not pre-created by the path builders (unlike hash/last-sync
-- paths).  Before the fix, JsonStore.write did not create the parent dir, so a
-- write into a `.sdr` folder that KOReader had not flushed yet failed with
-- write_error -> save_shared_failed.  JsonStore.write now makePath's the parent
-- first.  This exercises BOTH the POSIX and the Android branch, and a second
-- write proves the mkdir -p is idempotent (no error when the dir exists).
-- ---------------------------------------------------------------------------

do
    -- POSIX branch.
    package.loaded["device"] = { isAndroid = function(_) return false end }
    JsonStore._reset_platform_cache()

    -- A two-level path that does NOT exist yet (shard dir + .sdr dir),
    -- mirroring KOReader's hash metadata layout `XX/<hash>.sdr/`.
    local missing_dir = test_root .. "/59/deadbeef.sdr"
    os.execute("rm -rf '" .. test_root .. "/59'")
    local path = missing_dir .. "/My Book.syncery-progress.json"

    local ok, diag = JsonStore.write(path, { schema_version = 1, entries = {} })
    h.assert_true(ok, "posix write into missing .sdr dir succeeds (P1 fix)")
    h.assert_equal(diag, "ok", "posix write into missing dir returns 'ok'")

    local f = io.open(path, "rb")
    h.assert_true(f ~= nil, "file exists after write into previously-missing dir")
    if f then f:close() end

    -- Second write: the dir now exists; makePath must be a no-op (no error).
    -- The content MUST differ from the first write, otherwise JsonStore.write's
    -- skip-if-unchanged short-circuits before makePath and this would no longer
    -- exercise the idempotent-mkdir path it exists to prove.
    local ok2, diag2 = JsonStore.write(path, { schema_version = 1, entries = { ["dummy"] = { page = 2 } } })
    h.assert_true(ok2, "second write (dir already exists) still succeeds — idempotent")
    h.assert_equal(diag2, "ok", "second write (changed content) returns 'ok' (reaches makePath)")
end

do
    -- Android branch (direct write) — same missing-dir scenario.
    package.loaded["device"] = { isAndroid = function(_) return true end }
    JsonStore._reset_platform_cache()

    local missing_dir = test_root .. "/7a/cafebabe.sdr"
    os.execute("rm -rf '" .. test_root .. "/7a'")
    local path = missing_dir .. "/My Book.syncery-annotations.json"

    local ok, diag = JsonStore.write(path, { schema_version = 1, annotations = {} })
    h.assert_true(ok, "android write into missing .sdr dir succeeds (P1 fix)")
    h.assert_equal(diag, "ok", "android write into missing dir returns 'ok'")

    local f = io.open(path, "rb")
    h.assert_true(f ~= nil, "android: file exists after write into missing dir")
    if f then f:close() end

    -- Restore POSIX for any later specs sharing this process.
    package.loaded["device"] = { isAndroid = function(_) return false end }
    JsonStore._reset_platform_cache()
end


-- ---------------------------------------------------------------------------
-- _reset_platform_cache is a callable surface
-- ---------------------------------------------------------------------------

do
    h.assert_true(type(JsonStore._reset_platform_cache) == "function",
        "_reset_platform_cache is a public test surface")
    -- Calling it again is a no-op (idempotent).
    JsonStore._reset_platform_cache()
    JsonStore._reset_platform_cache()
end
