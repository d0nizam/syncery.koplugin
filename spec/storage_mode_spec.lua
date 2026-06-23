-- =============================================================================
-- spec/storage_mode_spec.lua
-- =============================================================================
--
-- Tests for syncery_storage_mode.lua — the unified storage-mode value
-- shared between the annotations and progress subsystems.
--
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_storage_mode_spec_" .. tostring(os.time()))

local StorageMode = require("syncery_storage_mode")


-- ----------------------------------------------------------------------------
-- Default mode is "sdr" — KOReader-native sidecar layout.
-- ----------------------------------------------------------------------------


do
    -- The module starts at "sdr" on fresh require.  run_tests clears
    -- syncery_storage_mode from package.loaded between specs, so this
    -- is the truth before any other spec touches it.
    h.assert_equal(StorageMode.get(), "sdr", "default mode is sdr")
end


-- ----------------------------------------------------------------------------
-- set / get roundtrip.
-- ----------------------------------------------------------------------------


do
    StorageMode.set("hash")
    h.assert_equal(StorageMode.get(), "hash", "hash roundtrips")

    StorageMode.set("sdr")
    h.assert_equal(StorageMode.get(), "sdr", "sdr roundtrips back")
end


-- ----------------------------------------------------------------------------
-- Invalid input falls back to "sdr" — matches the legacy behaviour
-- in paths.lua's set_storage_mode that callers may rely on.
-- ----------------------------------------------------------------------------


do
    StorageMode.set("garbage")
    h.assert_equal(StorageMode.get(), "sdr",
        "unknown mode falls back to sdr")

    StorageMode.set(nil)
    h.assert_equal(StorageMode.get(), "sdr", "nil falls back")

    StorageMode.set(42)
    h.assert_equal(StorageMode.get(), "sdr", "non-string falls back")
end


-- ----------------------------------------------------------------------------
-- on_change fires when the mode actually changes.
-- ----------------------------------------------------------------------------


do
    StorageMode._reset_for_tests()
    StorageMode.set("sdr")  -- ensure baseline

    local notified = nil
    StorageMode.on_change(function(new_mode) notified = new_mode end)

    StorageMode.set("hash")
    h.assert_equal(notified, "hash", "listener received new mode")
end


-- ----------------------------------------------------------------------------
-- on_change does NOT fire on a same-value set — subscribers can trust
-- that being called means the world changed.
-- ----------------------------------------------------------------------------


do
    StorageMode._reset_for_tests()
    StorageMode.set("sdr")

    local call_count = 0
    StorageMode.on_change(function() call_count = call_count + 1 end)

    StorageMode.set("sdr")
    h.assert_equal(call_count, 0, "no-op set does not fire listeners")

    StorageMode.set("hash")
    h.assert_equal(call_count, 1, "real change fires once")

    StorageMode.set("hash")
    h.assert_equal(call_count, 1, "repeated same-value set is no-op")
end


-- ----------------------------------------------------------------------------
-- Multiple listeners all fire; order is registration order.
-- ----------------------------------------------------------------------------


do
    StorageMode._reset_for_tests()
    StorageMode.set("sdr")

    local fired = {}
    StorageMode.on_change(function() table.insert(fired, "first") end)
    StorageMode.on_change(function() table.insert(fired, "second") end)
    StorageMode.on_change(function() table.insert(fired, "third") end)

    StorageMode.set("hash")
    h.assert_deep_equal(fired, { "first", "second", "third" },
        "all listeners fire in registration order")
end


-- ----------------------------------------------------------------------------
-- A listener that raises doesn't break other listeners or the setter.
-- ----------------------------------------------------------------------------


do
    StorageMode._reset_for_tests()
    StorageMode.set("sdr")

    local fired_after = false
    StorageMode.on_change(function() error("boom") end)
    StorageMode.on_change(function() fired_after = true end)

    StorageMode.set("hash")
    h.assert_true(fired_after,
        "later listener fires despite earlier listener raising")
    h.assert_equal(StorageMode.get(), "hash",
        "set completed (the throw didn't unwind it)")
end


-- ----------------------------------------------------------------------------
-- The unsubscribe function returned by on_change actually unsubscribes.
-- ----------------------------------------------------------------------------


do
    StorageMode._reset_for_tests()
    StorageMode.set("sdr")

    local call_count = 0
    local unsub = StorageMode.on_change(function() call_count = call_count + 1 end)

    StorageMode.set("hash")
    h.assert_equal(call_count, 1, "fired once")

    unsub()
    StorageMode.set("sdr")
    h.assert_equal(call_count, 1, "no fire after unsubscribe")
end


-- ----------------------------------------------------------------------------
-- on_change rejects non-function arguments loudly.
-- ----------------------------------------------------------------------------


do
    local ok = pcall(StorageMode.on_change, "not a function")
    h.assert_false(ok, "non-function listener rejected")

    local ok2 = pcall(StorageMode.on_change, nil)
    h.assert_false(ok2, "nil listener rejected")
end


-- ----------------------------------------------------------------------------
-- Integration: both paths modules see the same value because they
-- both delegate here.  This is the regression-prevention test for
-- the "coordination bug pretending to be a feature" we eliminated.
-- ----------------------------------------------------------------------------


do
    local AnnPaths      = require("syncery_ann/paths")
    local ProgressPaths = require("syncery_progress/paths")

    StorageMode.set("sdr")
    h.assert_equal(AnnPaths.get_storage_mode(), "sdr",
        "ann paths sees the central value")
    h.assert_equal(ProgressPaths.get_storage_mode(), "sdr",
        "progress paths sees the central value")

    -- Set via ann's setter; progress sees it.
    AnnPaths.set_storage_mode("hash")
    h.assert_equal(ProgressPaths.get_storage_mode(), "hash",
        "set via ann → seen by progress (no drift possible)")

    -- And the inverse.
    ProgressPaths.set_storage_mode("sdr")
    h.assert_equal(AnnPaths.get_storage_mode(), "sdr",
        "set via progress → seen by ann")
end


-- ----------------------------------------------------------------------------
-- hash_root: default returns a string ending with "/syncery".
-- ----------------------------------------------------------------------------


do
    StorageMode._reset_for_tests()
    local root = StorageMode.get_hash_root()
    h.assert_equal(type(root), "string",       "default root is a string")
    h.assert_true(#root > 0,                    "default root is non-empty")
    h.assert_true(root:match("/syncery$") ~= nil or root:match("syncery$") ~= nil,
        "default root ends with 'syncery' (got: " .. root .. ")")
end


-- ----------------------------------------------------------------------------
-- hash_root is FIXED (relocation removed).  set_hash_root no longer exists;
-- get_hash_root always returns the default; paths.lua resolves under it.
-- Relocating the root was the source of a path-drift bug class — the
-- cross-device-sync use case it served is now met by syncing the `shared/`
-- subdirectory of the fixed root instead.
-- ----------------------------------------------------------------------------


do
    StorageMode._reset_for_tests()
    h.assert_true(type(StorageMode.set_hash_root) ~= "function",
        "set_hash_root is removed")
end


do
    StorageMode._reset_for_tests()
    local AnnPaths = require("syncery_ann/paths")
    -- paths.lua's _syncery_state_dir resolves to the fixed default root.
    local root = StorageMode.get_hash_root()
    h.assert_equal(AnnPaths._syncery_state_dir(), root,
        "paths.lua _syncery_state_dir equals the fixed hash root")
    h.assert_true(root:match("syncery$") ~= nil,
        "fixed hash root ends with 'syncery'")
end
