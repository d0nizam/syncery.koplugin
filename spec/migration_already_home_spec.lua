-- =============================================================================
-- spec/migration_already_home_spec.lua
-- =============================================================================
--
-- Tests for StorageMode.data_already_at_destination (syncery_migration/storage_mode.lua)
-- — the guard that detects "nothing to migrate because the data is already in
-- the current (destination) mode", which fixes the misleading "No synced books
-- found" dead-end after a toggle-back-and-forth.
--
-- The helper enumerates Syncery JSONs via OrphanAdapters.build_deps internally.
-- We can't inject into it directly, so we drive it through a REAL filesystem:
-- lay out synceryhash and/or SDR JSON trees, point build_deps at them by
-- overriding the resolvers through the plugin/env the helper reads. Since
-- build_deps reads real settings we cannot easily stub here, we instead test
-- the helper's PURE DECISION by calling it with a fake `deps`-like seam: the
-- helper is split so the counting logic is reachable. To keep this robust and
-- not depend on global settings, we exercise the four cases by monkey-patching
-- OrphanAdapters.build_deps for the duration of the test to return a deps table
-- whose syncery_jsons yields a controlled entry list.
--
-- =============================================================================

local h = require("spec.test_helpers")
local lfs = require("lfs")
local StorageMode = require("syncery_migration/storage_mode")
local OrphanAdapters = require("syncery_migration/orphan_adapters")

h.setup("/tmp/syncery_test_alreadyhome_" .. tostring(os.time()))

-- Monkey-patch build_deps to return a deps whose syncery_jsons yields `entries`.
local real_build_deps = OrphanAdapters.build_deps
local function with_entries(entries, fn)
    OrphanAdapters.build_deps = function(_opts)
        return { syncery_jsons = function() return entries end }
    end
    local ok, err = pcall(fn)
    OrphanAdapters.build_deps = real_build_deps
    if not ok then error(err) end
end

local function fake_plugin(mode) return { storage_mode = mode } end

-- ==========================================================================
-- Case 1 — NORMAL: data in opposite, none in current → false (migrate needed)
-- ==========================================================================
do
    -- current = sdr; data lives in synceryhash (opposite). Should NOT fire.
    with_entries({
        { path = "/s/synceryhash/ab/hash1/syncery-progress.json", klass = "synceryhash" },
        { path = "/s/synceryhash/cd/hash2/syncery-progress.json", klass = "synceryhash" },
    }, function()
        local home, n = StorageMode.data_already_at_destination(fake_plugin("sdr"), lfs)
        h.assert_false(home, "Case1: data in opposite (hash) → not already home")
    end)
end

-- ==========================================================================
-- Case 2 — ALREADY DONE: data in current only, opposite empty → TRUE
-- ==========================================================================
do
    -- current = sdr; data lives in SDR trees (doc/dir), none in synceryhash.
    with_entries({
        { path = "/home/Book.epub.sdr/Book.epub.syncery-progress.json", klass = "doc" },
        { path = "/k/docsettings/x/B2.epub.sdr/B2.epub.syncery-progress.json", klass = "dir" },
    }, function()
        local home, n = StorageMode.data_already_at_destination(fake_plugin("sdr"), lfs)
        h.assert_true(home, "Case2: data in current (sdr) only → already home")
        h.assert_equal(n, 2, "Case2: counts the two current-mode JSONs")
    end)

    -- symmetric: current = hash, data in synceryhash only
    with_entries({
        { path = "/s/synceryhash/ab/h1/syncery-progress.json", klass = "synceryhash" },
    }, function()
        local home, n = StorageMode.data_already_at_destination(fake_plugin("hash"), lfs)
        h.assert_true(home, "Case2b: current=hash, data in synceryhash only → already home")
        h.assert_equal(n, 1, "Case2b: one current-mode JSON")
    end)
end

-- ==========================================================================
-- Case 3 — MIXED: data in BOTH → false (opposite leftovers to migrate)
-- ==========================================================================
do
    -- current = sdr; data in BOTH sdr and synceryhash. Must NOT fire — the
    -- synceryhash leftovers still need migrating into sdr.
    with_entries({
        { path = "/home/Book.epub.sdr/Book.epub.syncery-progress.json", klass = "doc" },
        { path = "/s/synceryhash/ab/h1/syncery-progress.json", klass = "synceryhash" },
    }, function()
        local home = StorageMode.data_already_at_destination(fake_plugin("sdr"), lfs)
        h.assert_false(home, "Case3: data in both → not already home (migrate leftovers)")
    end)
end

-- ==========================================================================
-- Case 4 — EMPTY: no JSONs anywhere → false (let normal empty path run)
-- ==========================================================================
do
    with_entries({}, function()
        local home, n = StorageMode.data_already_at_destination(fake_plugin("sdr"), lfs)
        h.assert_false(home, "Case4: no JSONs → not already home")
        h.assert_equal(n, 0, "Case4: zero current-mode JSONs")
    end)
end

-- ==========================================================================
-- Guard: unknown/absent current mode → false
-- ==========================================================================
do
    with_entries({ { path = "/s/synceryhash/ab/h/syncery-progress.json", klass = "synceryhash" } }, function()
        local home = StorageMode.data_already_at_destination(fake_plugin(nil), lfs)
        h.assert_false(home, "Guard: nil current mode → false")
    end)
end

-- ==========================================================================
-- Robustness: build_deps failure → false (graceful, no crash)
-- ==========================================================================
do
    OrphanAdapters.build_deps = function() error("boom") end
    local ok, home = pcall(StorageMode.data_already_at_destination, fake_plugin("sdr"), lfs)
    OrphanAdapters.build_deps = real_build_deps
    h.assert_true(ok, "Robustness: helper does not propagate build_deps error")
    h.assert_false(home, "Robustness: build_deps failure → false")
end

h.teardown()
print("migration_already_home_spec: all assertions passed")
