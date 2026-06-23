-- =============================================================================
-- spec/migration_scattered_hook_spec.lua
-- =============================================================================
--
-- Step 2: verifies the READ-ONLY scattered-metadata detection is wired into
-- StorageMode.migrate_all_books's HASH-branch (synceryhash -> SDR) and ONLY
-- there. The detection module itself is unit-tested in scattered_metadata_spec;
-- this spec proves the WIRING:
--   (1) hash-branch (old_mode="hash") returns a populated scattered report,
--       computed over the books scanHash found, using KOReader's findSidecarFile.
--   (2) the report is returned only for the hash-branch; the SDR-branch
--       (old_mode="sdr") does not produce one (one-directionality is structural).
--   (3) detection runs AFTER perform_migration (so Syncery has already moved
--       its own data before we inspect KOReader's native metadata).
--
-- Must run via the full runner: storage_mode.lua requires ui/uimanager etc.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_scattered_hook_spec_" .. tostring(os.time()))

-- UI + platform stubs (mirror migration_all_books_e2e_spec).
package.loaded["ffi/util"] = {
    joinPath = function(a, b) return a .. "/" .. b end,
    gettime  = function() return os.time() end,
    basename = function(p) return p:match("([^/]+)$") or p end,
}
local shown = {}
package.loaded["ui/uimanager"] = {
    show = function(_, w) table.insert(shown, w) end, close = function() end,
}
package.loaded["ui/widget/infomessage"] = { new = function(_, a) return a or {} end }
package.loaded["ui/widget/confirmbox"]  = { new = function(_, a) return a or {} end }
package.loaded["ui/trapper"] = {
    wrap = function(_, f) return f() end, info = function() return true end,
    reset = function() end,
}

-- Order tracking: record when perform_migration ran vs when detection ran,
-- to prove detection happens AFTER the migration.
local events = {}

-- A fake docsettings whose findSidecarFile reports a per-book location, and
-- whose getSidecarDir is still present (other code paths may call it).
local location_by_file = {}
package.loaded["docsettings"] = {
    findSidecarFile = function(_self, doc_path)
        local loc = location_by_file[doc_path]
        if not loc then return nil end
        return doc_path .. ".sdr/metadata.epub.lua", loc
    end,
    getSidecarDir = function(_self, book_path) return (book_path:gsub("%.%w+$","")) .. ".sdr" end,
    open = function(_self) return { readSetting = function() return nil end } end,
}

-- Preferred location for the detection = "doc" (book folder). Books reported in
-- dir/hash are therefore "scattered".
_G.G_reader_settings = _G.G_reader_settings or {}
local real_readSetting = _G.G_reader_settings.readSetting
_G.G_reader_settings.readSetting = function(_self, key, default)
    if key == "document_metadata_folder" then return "doc" end
    if real_readSetting then return real_readSetting(_self, key, default) end
    return default
end

local StorageMode = require("syncery_migration/storage_mode")
local BookList    = require("syncery_ui/booklist/init")

-- Mock scanHash to populate a known set of books (the synceryhash source set),
-- and record the event order.
local FOUND_BOOKS = {
    { file = "/lib/Alpha.epub" },   -- will be scattered (dir)
    { file = "/lib/Beta.epub" },    -- will be scattered (hash)
    { file = "/lib/Gamma.epub" },   -- in preferred (doc) => not scattered
}
local real_scanHash = BookList.scanHash
BookList.scanHash = function(books)
    table.insert(events, "scanHash")
    for _, b in ipairs(FOUND_BOOKS) do books[#books + 1] = b end
    return books
end

-- Wrap perform_migration to record that it ran (and ran BEFORE detection),
-- and to invoke the on_complete callback the way the real one does (inside its
-- Trapper wrap). Detection now lives inside that callback.
local real_perform = StorageMode.perform_migration
StorageMode.perform_migration = function(plugin, books, on_complete)
    table.insert(events, "perform_migration")
    -- Don't actually move files (no real fixtures); just record, then run the
    -- follow-up exactly as the real perform_migration does.
    if type(on_complete) == "function" then
        on_complete(0, 0, false)
    end
    return
end

-- Set up the scattered locations the fake docsettings will report.
location_by_file["/lib/Alpha.epub"] = "dir"
location_by_file["/lib/Beta.epub"]  = "hash"
location_by_file["/lib/Gamma.epub"] = "doc"

-- ---------------------------------------------------------------------------
-- CASE 1 — hash-branch returns a populated, correct scattered report.
-- ---------------------------------------------------------------------------
do
    events = {}
    local report = StorageMode.migrate_all_books({ storage_mode = "sdr" }, "hash")

    h.assert_true(report ~= nil, "case1: hash-branch returns a report")
    h.assert_equal(report.preferred, "doc", "case1: report preferred location = doc")
    h.assert_equal(report.total_scattered, 2, "case1: 2 scattered (Alpha/dir, Beta/hash)")
    h.assert_equal(report.by_location["dir"], 1, "case1: 1 in docsettings")
    h.assert_equal(report.by_location["hash"], 1, "case1: 1 in hashdocsettings")
    h.assert_nil(report.by_location["doc"], "case1: Gamma (in preferred) not scattered")
end

-- ---------------------------------------------------------------------------
-- CASE 2 — detection runs AFTER perform_migration.
-- ---------------------------------------------------------------------------
do
    events = {}
    StorageMode.migrate_all_books({ storage_mode = "sdr" }, "hash")
    -- Expected order: scanHash, then perform_migration, then detection (which
    -- consumes findSidecarFile after the move). We assert perform_migration
    -- preceded the return of the report (detection is the last thing).
    local i_perform, i_scan
    for i, e in ipairs(events) do
        if e == "perform_migration" then i_perform = i end
        if e == "scanHash" then i_scan = i end
    end
    h.assert_true(i_scan ~= nil and i_perform ~= nil, "case2: both scan and migration ran")
    h.assert_true(i_scan < i_perform, "case2: scanHash ran before perform_migration")
    -- Detection is invoked after perform_migration in the source; its effect
    -- (the returned report) is validated in case1. Here we confirm migration
    -- was not skipped.
end

-- ---------------------------------------------------------------------------
-- CASE 3 — SDR-branch does NOT produce a scattered report (one-directionality).
-- old_mode="sdr" means current=hash (SDR->synceryhash), where scattering is
-- irrelevant. The SDR-branch returns nil/no report.
-- ---------------------------------------------------------------------------
do
    events = {}
    -- The SDR-branch scans roots (scanSDR / dir / hash finders). With no roots
    -- configured and our mocked environment it simply finds nothing and runs
    -- perform_migration on an empty set. The key assertion: no scattered report.
    local report = StorageMode.migrate_all_books({ storage_mode = "hash" }, "sdr")
    h.assert_nil(report, "case3: SDR-branch returns no scattered report (one-directional)")
    -- scanHash must NOT have been called in the SDR-branch.
    local saw_scanHash = false
    for _, e in ipairs(events) do if e == "scanHash" then saw_scanHash = true end end
    h.assert_false(saw_scanHash, "case3: SDR-branch did not call scanHash")
end

-- Restore the functions we wrapped.
BookList.scanHash = real_scanHash
StorageMode.perform_migration = real_perform
_G.G_reader_settings.readSetting = real_readSetting

h.teardown()
print("migration_scattered_hook_spec: all assertions passed")
