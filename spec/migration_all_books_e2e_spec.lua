-- =============================================================================
-- spec/migration_all_books_e2e_spec.lua
-- =============================================================================
--
-- End-to-end test of StorageMode.migrate_all_books — the FULL flow that the
-- per-function tests in migration_storage_mode_spec do not cover: branch
-- selection (hash vs sdr), the three-location scan, dedup, and the actual move.
--
-- Reproduces the reported data-loss: a user on SDR storage with KOReader
-- metadata=doc switches to synceryhash and migrates.  Before the extension
-- fix, scanSDR reconstructed book.file WITHOUT the extension, so the
-- synceryhash destination hash was wrong — files were deleted from the SDR
-- source and written under a bogus hash dir that nothing else could find
-- (the book "vanished", no synceryhash folder appeared where expected).
--
-- This test asserts the files arrive at the destination derived from the REAL
-- book path, and the SDR source is consumed.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_migrate_all_e2e_" .. tostring(os.time()))

-- UI + platform stubs (the harness only stubs a subset).
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
package.loaded["ui/widget/inputdialog"] = { new = function(_, a) return a or {} end }
package.loaded["ui/widget/pathchooser"] = { new = function(_, a) return a or {} end }
package.loaded["ui/trapper"] = {
    wrap = function(_, f) return f() end, info = function() return true end,
    reset = function() end,
}
package.loaded["device"] = { home_dir = "/tmp",
    screen = { getWidth = function() return 600 end, getHeight = function() return 800 end } }
package.loaded["util"] = {
    splitFilePathName = function(file)
        if file == nil or file == "" then return "", "" end
        if string.find(file, "/") == nil then return "", file end
        return file:match("(.*/)(.*)")
    end,
    splitFileNameSuffix = function(file)
        if file == nil or file == "" then return "", "" end
        if string.find(file, "%.") == nil then return file, "" end
        return file:match("(.*)%.(.*)")
    end,
    makePath = function(p) os.execute("mkdir -p '" .. p .. "' 2>/dev/null") return true end,
    utf8sub = function(s, a, b) return s:sub(a, b) end,
}

local function wf(path, content)   -- ALWAYS closes (a prior bug: unclosed write → dofile nil)
    local f = io.open(path, "w"); f:write(content); f:close()
end

local lfs = require("lfs")

-- ---------------------------------------------------------------------------
-- The user's scenario: SDR storage, KOReader metadata=doc, switch to hash.
-- ---------------------------------------------------------------------------
do
    local base = "/tmp/migrate_all_e2e_data_" .. tostring(os.time())
        .. "_" .. tostring(math.random(1e6))
    os.execute("rm -rf '" .. base .. "'")
    local settings_dir = base .. "/koreader"
    local lib          = base .. "/library"
    os.execute("mkdir -p '" .. lib .. "' '" .. settings_dir .. "' 2>/dev/null")

    -- A real book + its Syncery SDR files BESIDE it (doc location), in a .sdr
    -- folder named WITHOUT the extension — the case that broke.
    os.execute("touch '" .. lib .. "/MyBook.epub'")
    local sdr = lib .. "/MyBook.sdr"
    os.execute("mkdir -p '" .. sdr .. "' 2>/dev/null")
    wf(sdr .. "/MyBook.syncery-progress.json",
       '{"schema_version":1,"entries":{"dev1":{"file":"' .. lib .. '/MyBook.epub","percent":0.4}}}')
    wf(sdr .. "/MyBook.syncery-annotations.json",
       '{"schema_version":1,"annotations":{}}')

    -- history.lua so deriveRootsFromHistory yields `lib` (no Syncthing folders).
    wf(settings_dir .. "/history.lua",
       'return { { file = "' .. lib .. '/MyBook.epub" } }')

    package.loaded["datastorage"] = {
        getDataDir            = function() return settings_dir end,
        getSettingsDir        = function() return settings_dir end,   -- hash root parent
        getDocSettingsDir     = function() return settings_dir .. "/docsettings" end,
        getDocSettingsHashDir = function() return settings_dir .. "/hashdocsettings" end,
    }
    package.loaded["syncery_settings"] = setmetatable({}, {
        __index = function(_, k)
            return function() return nil end
        end,
    })
    _G.G_reader_settings = {
        _t = { syncery_storage_mode = "hash", document_metadata_folder = "doc" },
        readSetting = function(self, k, d) local v = self._t[k]; if v == nil then return d end return v end,
        saveSetting = function(self, k, v) self._t[k] = v end,
        hasNot = function() return true end,
    }

    local StorageMode   = require("syncery_storage_mode")
    StorageMode.set("hash")   -- user has switched to synceryhash
    local AnnPaths      = require("syncery_ann/paths")
    local ProgressPaths = require("syncery_progress/paths")
    AnnPaths.set_storage_mode("hash")
    ProgressPaths.set_storage_mode("hash")

    -- The destination derived from the REAL book path (what must be created).
    local dst_prog = ProgressPaths.shared_progress_path(lib .. "/MyBook.epub")
    local dst_ann  = AnnPaths.shared_annotations_path(lib .. "/MyBook.epub")
    h.assert_false(lfs.attributes(dst_prog, "mode") == "file",
        "e2e precondition: synceryhash destination absent before migration")

    local Migration = require("syncery_migration/storage_mode")
    local plugin = { storage_mode = "hash", device_id = "dev1", device_label = "Test",
                     log_activity = function() end }
    -- old_mode = "sdr" is what the menu passes when current = hash (correct).
    Migration.migrate_all_books(plugin, "sdr")

    -- THE ASSERTIONS — files arrive at the correct hash-derived destination.
    h.assert_true(lfs.attributes(dst_prog, "mode") == "file",
        "e2e: progress file lands in synceryhash at the destination derived from the REAL .epub path (the data-loss bug stranded it under an extension-less hash)")
    h.assert_true(lfs.attributes(dst_ann, "mode") == "file",
        "e2e: annotations file also lands at the correct synceryhash destination")
    h.assert_false(lfs.attributes(sdr .. "/MyBook.syncery-progress.json", "mode") == "file",
        "e2e: the SDR source progress file is consumed (moved, not left behind)")

    -- No picker was shown (the scan found the book without one).
    local picker_shown = false
    for _, w in ipairs(shown) do
        if w.text and w.text:find("couldn't find your synced books") then picker_shown = true end
    end
    h.assert_false(picker_shown,
        "e2e: the picker is NOT shown — the history-derived root found the doc-location book")

    os.execute("rm -rf '" .. base .. "'")
end


-- ---------------------------------------------------------------------------
-- The reported scenario: FOUR books whose Syncery SDR files all live in
-- hashdocsettings (KOReader metadata=hash).  Before the seen-double-use fix,
-- the finders found all four, then dedup_books_by_file — sharing the finders'
-- `seen` — treated every one as an already-seen duplicate and dropped them,
-- so 0 (or, mixed with a doc book, 1) of 4 migrated and the sources stayed.
-- ---------------------------------------------------------------------------
do
    local base = "/tmp/migrate_all_e2e_hash_" .. tostring(os.time())
        .. "_" .. tostring(math.random(1e6))
    os.execute("rm -rf '" .. base .. "'")
    local settings_dir = base .. "/koreader"
    local lib          = base .. "/library"
    local hashds       = settings_dir .. "/hashdocsettings"
    os.execute("mkdir -p '" .. lib .. "' '" .. settings_dir .. "' '" .. hashds .. "' 2>/dev/null")

    local names  = { "Alpha", "Beta", "Gamma", "Delta" }
    local hashes = { "aa11bb22", "cc33dd44", "ee55ff66", "00778899" }
    for i, n in ipairs(names) do
        os.execute("touch '" .. lib .. "/" .. n .. ".epub'")
        local shard = hashes[i]:sub(1, 2)
        local sdr   = hashds .. "/" .. shard .. "/" .. hashes[i] .. ".sdr"
        os.execute("mkdir -p '" .. sdr .. "' 2>/dev/null")
        wf(sdr .. "/" .. n .. ".syncery-progress.json",
           '{"schema_version":1,"entries":{"dev1":{"file":"' .. lib .. "/" .. n .. '.epub","percent":0.3}}}')
        wf(sdr .. "/" .. n .. ".syncery-annotations.json",
           '{"schema_version":1,"annotations":{}}')
    end
    wf(settings_dir .. "/history.lua", "return { }")   -- no history; fixed tree only

    package.loaded["datastorage"] = {
        getDataDir            = function() return settings_dir end,
        getSettingsDir        = function() return settings_dir end,
        getDocSettingsDir     = function() return settings_dir .. "/docsettings" end,
        getDocSettingsHashDir = function() return hashds end,
    }
    package.loaded["syncery_settings"] = setmetatable({}, {
        __index = function(_, k)
            return function() return nil end
        end,
    })
    _G.G_reader_settings = {
        _t = { syncery_storage_mode = "hash", document_metadata_folder = "hash" },
        readSetting = function(self, k, d) local v = self._t[k]; if v == nil then return d end return v end,
        saveSetting = function(self, k, v) self._t[k] = v end,
        hasNot = function() return true end,
    }

    -- Fresh module state for the new datastorage stub.
    package.loaded["syncery_storage_mode"]      = nil
    package.loaded["syncery_ann/paths"]         = nil
    package.loaded["syncery_progress/paths"]    = nil
    package.loaded["syncery_migration/storage_mode"] = nil
    local StorageMode   = require("syncery_storage_mode")
    StorageMode.set("hash")
    local AnnPaths      = require("syncery_ann/paths")
    local ProgressPaths = require("syncery_progress/paths")
    AnnPaths.set_storage_mode("hash")
    ProgressPaths.set_storage_mode("hash")

    local Migration = require("syncery_migration/storage_mode")
    Migration.migrate_all_books(
        { storage_mode = "hash", device_id = "dev1", device_label = "T",
          log_activity = function() end }, "sdr")

    local migrated, sources_left = 0, 0
    for i, n in ipairs(names) do
        local dst = ProgressPaths.shared_progress_path(lib .. "/" .. n .. ".epub")
        if dst and lfs.attributes(dst, "mode") == "file" then migrated = migrated + 1 end
        local shard = hashes[i]:sub(1, 2)
        local src = hashds .. "/" .. shard .. "/" .. hashes[i] .. ".sdr/" .. n .. ".syncery-progress.json"
        if lfs.attributes(src, "mode") == "file" then sources_left = sources_left + 1 end
    end

    h.assert_equal(migrated, 4,
        "e2e hashdocsettings: ALL FOUR books migrate to synceryhash (the seen-double-use bug dropped finder-found books, migrating 0-of-4)")
    h.assert_equal(sources_left, 0,
        "e2e hashdocsettings: all four hashdocsettings sources are consumed (not left behind)")

    os.execute("rm -rf '" .. base .. "'")
end

h.teardown()
