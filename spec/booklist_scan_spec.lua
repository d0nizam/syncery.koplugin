-- =============================================================================
-- spec/booklist_scan_spec.lua
-- =============================================================================
--
-- Tests for syncery_ui/booklist/scan.lua — the disk-scan unit split
-- out of syncery_booklist.lua in Phase 6.
--
-- Covers:
--   * getScanRoots: extracts folder paths from Settings.
--   * _book_path_from_sdr_progress: derives the book path from an
--     SDR progress-file path, including the .sdr-folder up-one-level
--     case.
--   * make_cancellable_walk: appends discovered books, honours the
--     cancellation predicate, and fires the progress callback.
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_booklist_scan_spec_" .. tostring(os.time()))


-- ---------------------------------------------------------------------------
-- Stubs
-- ---------------------------------------------------------------------------

package.loaded["ui/uimanager"]            = { show = function() end, close = function() end }
package.loaded["ui/widget/infomessage"]   = { new = function(_, a) return a end }
package.loaded["ui/widget/confirmbox"]    = { _shown = {}, new = function(self, a)
    a = a or {}; table.insert(self._shown, a); return a
end }
package.loaded["ui/widget/pathchooser"]   = { new = function(_, a) return a or {} end }
package.loaded["device"]                  = { home_dir = "/mnt/us",
    screen = { getWidth = function() return 600 end, getHeight = function() return 800 end } }
package.loaded["ui/widget/inputdialog"]   = { new = function(_, a)
    a = a or {}; a.onShowKeyboard = function() end
    a.getInputText = function() return "" end
    return a
end }
package.loaded["ui/trapper"] = {
    info  = function() return true end,
    reset = function() end,
    wrap  = function(_, fn) fn() end,
}
package.loaded["ffi/util"] = {
    joinPath = function(a, b) return a .. "/" .. b end,
    gettime  = function() return os.time() end,
}
package.loaded["syncery_i18n"] = {
    translate = function(s) return s end,
    ngettext  = function(s, p, n) if n == 1 then return s else return p end end,
}
-- util stub — provides the REAL KOReader functions verbatim from
-- frontend/util.lua (ground truth). The earlier stub invented a
-- `splitFilePath` that does NOT exist in KOReader, which masked a crash:
-- the code called the non-existent function and only failed on-device.
-- The fix composes the two real functions; this stub mirrors them exactly
-- so the test validates against reality.
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
    utf8sub = function(s, a, b) return s:sub(a, b) end,
}

-- Settings stub — the single chosen folder is swappable per test.
local syncthing_folder = nil
package.loaded["syncery_settings"] = setmetatable({}, {
    __index = function(_, k)
        if k == "get_syncthing_folder" then
            return function() return syncthing_folder end
        end
        return function() return nil end
    end,
})


local Scan = require("syncery_ui/booklist/scan")


-- ---------------------------------------------------------------------------
-- getScanRoots
-- ---------------------------------------------------------------------------

do
    syncthing_folder = nil
    h.assert_deep_equal(Scan.getScanRoots(), {},
        "getScanRoots: no folder configured → empty list")
end

do
    syncthing_folder = { folder_id = "lib", path = "/books/library" }
    h.assert_deep_equal(Scan.getScanRoots(), { "/books/library" },
        "getScanRoots: the chosen folder's path")
end

do
    syncthing_folder = { folder_id = "lib", path = "" }     -- empty path → skipped
    h.assert_deep_equal(Scan.getScanRoots(), {},
        "getScanRoots: empty path → empty list")
end

do
    syncthing_folder = { folder_id = "lib" }                -- no path → skipped
    h.assert_deep_equal(Scan.getScanRoots(), {},
        "getScanRoots: no path → empty list")
end


-- ---------------------------------------------------------------------------
-- deriveRootsFromHistory — book folders from KOReader's history.lua
-- ---------------------------------------------------------------------------
do
    local base = "/tmp/syncery_hist_roots_" .. tostring(os.time())
        .. "_" .. tostring(math.random(1e6))
    local data_dir = base .. "/koreader"
    local folder_a = base .. "/Books/Fiction"
    local folder_b = base .. "/Books/Tech"
    os.execute("rm -rf '" .. base .. "'")
    os.execute("mkdir -p '" .. data_dir .. "' 2>/dev/null")
    os.execute("mkdir -p '" .. folder_a .. "' 2>/dev/null")
    os.execute("mkdir -p '" .. folder_b .. "' 2>/dev/null")
    -- history.lua: two books in folder_a, one in folder_b, one in a folder
    -- that no longer exists (must be skipped).
    local f = io.open(data_dir .. "/history.lua", "w")
    f:write("return {\n")
    f:write(string.format("  { time = 3, file = %q },\n", folder_a .. "/Alpha.epub"))
    f:write(string.format("  { time = 2, file = %q },\n", folder_a .. "/Beta.pdf"))   -- same folder → dedup
    f:write(string.format("  { time = 1, file = %q },\n", folder_b .. "/Gamma.epub"))
    f:write(string.format("  { time = 0, file = %q },\n", base .. "/Gone/Old.epub")) -- folder missing
    f:write("}\n")
    f:close()

    local saved_ds = package.loaded["datastorage"]
    package.loaded["datastorage"] = {
        getDataDir = function() return data_dir end,
    }

    local roots = Scan.deriveRootsFromHistory()
    local set = {}
    for _, r in ipairs(roots) do set[r] = true end

    h.assert_equal(#roots, 2,
        "history-roots: two existing folders (duplicate folder collapsed, missing skipped)")
    h.assert_true(set[folder_a] ~= nil,
        "history-roots: folder of Alpha/Beta included once")
    h.assert_true(set[folder_b] ~= nil,
        "history-roots: folder of Gamma included")
    h.assert_nil(set[base .. "/Gone"],
        "history-roots: folder that no longer exists is skipped")

    -- No history.lua → empty, no crash.
    package.loaded["datastorage"] = {
        getDataDir = function() return base .. "/nonexistent" end,
    }
    h.assert_equal(#Scan.deriveRootsFromHistory(), 0,
        "history-roots: absent history.lua → empty list")

    package.loaded["datastorage"] = saved_ds
    os.execute("rm -rf '" .. base .. "'")
end


-- ---------------------------------------------------------------------------
-- _book_path_from_sdr_progress
-- ---------------------------------------------------------------------------

do
    -- Progress file sitting beside the book (no .sdr folder).
    local p = Scan._book_path_from_sdr_progress(
        "/books/My Book.syncery-progress.json")
    h.assert_equal(p, "/books/My Book",
        "_book_path_from_sdr_progress: beside-the-book case strips suffix")
end

do
    -- Progress file inside a .sdr sidecar → go up one level.
    local p = Scan._book_path_from_sdr_progress(
        "/books/My Book.sdr/My Book.syncery-progress.json")
    h.assert_equal(p, "/books/My Book",
        "_book_path_from_sdr_progress: .sdr sidecar → parent dir + book name")
end

do
    -- A path that is NOT a progress file → nil.
    local p = Scan._book_path_from_sdr_progress("/books/random.json")
    h.assert_nil(p,
        "_book_path_from_sdr_progress: non-progress path → nil")
end

do
    -- Regression (the splitFilePath crash): a real on-device sidecar path
    -- under KOReader's hash-metadata tree. With the real util functions this
    -- must derive a book path, NOT return nil and NOT raise. The old fake
    -- splitFilePath stub hid that the production call would crash here.
    local p = Scan._book_path_from_sdr_progress(
        "/mnt/us/koreader/hashdocsettings/59/x.sdr/My Book.syncery-progress.json")
    h.assert_equal(p, "/mnt/us/koreader/hashdocsettings/59/My Book",
        "_book_path_from_sdr_progress: real .sdr path → parent + book name (no crash)")
end


-- ---------------------------------------------------------------------------
-- book_file_from_progress_json — reads the REAL book path (with extension)
-- from inside the progress JSON.  This is the fix for the migration data-loss:
-- the .sdr-name reconstruction drops the extension, which breaks the
-- synceryhash destination hash.
-- ---------------------------------------------------------------------------
do
    local base = "/tmp/syncery_bfpj_" .. tostring(os.time()) .. "_" .. tostring(math.random(1e6))
    os.execute("rm -rf '" .. base .. "'"); os.execute("mkdir -p '" .. base .. "' 2>/dev/null")
    local pf = base .. "/MyBook.syncery-progress.json"
    local f = io.open(pf, "w")
    f:write('{"schema_version":1,"entries":{"dev1":{"file":"/mnt/us/Books/MyBook.epub","percent":0.3}}}')
    f:close()

    h.assert_equal(Scan._book_file_from_progress_json(pf), "/mnt/us/Books/MyBook.epub",
        "book_file_from_progress_json: returns the real path WITH extension from the JSON entries")

    -- Empty / missing entries → nil (caller falls back to the .sdr-name path).
    local ef = base .. "/Empty.syncery-progress.json"
    local g = io.open(ef, "w"); g:write('{"schema_version":1,"entries":{}}'); g:close()
    h.assert_nil(Scan._book_file_from_progress_json(ef),
        "book_file_from_progress_json: no usable file entry → nil (fallback)")
    h.assert_nil(Scan._book_file_from_progress_json(base .. "/does-not-exist.json"),
        "book_file_from_progress_json: missing file → nil")

    os.execute("rm -rf '" .. base .. "'")
end


-- ---------------------------------------------------------------------------
-- scanSDR — book.file carries the REAL extension (reproduces the reported
-- migration data-loss).  A .sdr folder named without the extension
-- ("MyBook.sdr") must still yield "/…/MyBook.epub" so the migration computes
-- the correct synceryhash hash, not a bogus one from "MyBook".
-- ---------------------------------------------------------------------------
do
    local base = "/tmp/syncery_scansdr_ext_" .. tostring(os.time()) .. "_" .. tostring(math.random(1e6))
    os.execute("rm -rf '" .. base .. "'")
    local lib = base .. "/library"
    local sdr = lib .. "/MyBook.sdr"
    os.execute("mkdir -p '" .. sdr .. "' 2>/dev/null")
    os.execute("touch '" .. lib .. "/MyBook.epub'")
    local f = io.open(sdr .. "/MyBook.syncery-progress.json", "w")
    f:write('{"schema_version":1,"entries":{"dev1":{"file":"' .. lib .. '/MyBook.epub","percent":0.4}}}')
    f:close()

    local books = {}
    Scan.scanSDR({ lib }, books)

    h.assert_equal(#books, 1, "scanSDR: finds the one book")
    h.assert_equal(books[1].file, lib .. "/MyBook.epub",
        "scanSDR: book.file carries the REAL .epub extension (read from JSON), NOT the extension-less .sdr-name reconstruction")
    h.assert_true(books[1].file:match("%.epub$") ~= nil,
        "scanSDR: book.file ends in .epub (the data-loss bug produced no extension)")

    os.execute("rm -rf '" .. base .. "'")
end


-- ---------------------------------------------------------------------------
-- make_cancellable_walk — cancellation predicate is honoured
-- ---------------------------------------------------------------------------

do
    -- A walk that is "already cancelled" must append nothing and not
    -- even touch the filesystem.
    local books = {}
    local walk = Scan.make_cancellable_walk(books,
        function() return true end,    -- always cancelled
        nil)
    walk("/nonexistent", "%.json$", {})
    h.assert_equal(#books, 0,
        "make_cancellable_walk: cancelled-on-entry appends nothing")
end


-- ---------------------------------------------------------------------------
-- make_cancellable_walk — discovers progress files in a real temp tree
-- ---------------------------------------------------------------------------

do
    -- Build a small real directory tree under the test root.
    local root = h.test_root .. "/scan_tree"
    os.execute("mkdir -p '" .. root .. "/sub' 2>/dev/null")
    -- Two progress files + one unrelated file.
    local function touch(path, body)
        local f = io.open(path, "w"); f:write(body or "{}"); f:close()
    end
    touch(root .. "/Book One.syncery-progress.json")
    touch(root .. "/sub/Book Two.syncery-progress.json")
    touch(root .. "/notes.txt", "ignore me")

    -- Real lfs + real ffi joinPath for this test.
    package.loaded["libs/libkoreader-lfs"] = require("lfs")
    package.loaded["ffi/util"] = {
        joinPath = function(a, b) return a .. "/" .. b end,
        gettime  = function() return os.time() end,
    }
    package.loaded["syncery_ui/booklist/scan"] = nil
    local Scan2 = require("syncery_ui/booklist/scan")

    local books = {}
    local walk = Scan2.make_cancellable_walk(books,
        function() return false end, nil)
    walk(root, "%.syncery%-progress%.json$", {})

    h.assert_equal(#books, 2,
        "make_cancellable_walk: finds both progress files, skips notes.txt")
    -- Each discovered book carries a progress_path and a mode.
    local all_sdr = true
    for _, b in ipairs(books) do
        if b.mode ~= "sdr" then all_sdr = false end
    end
    h.assert_true(all_sdr,
        "make_cancellable_walk: discovered books are tagged mode='sdr'")
end


-- ---------------------------------------------------------------------------
-- make_cancellable_walk — a hashdocsettings (content-hash) annotations-only
-- .sdr is REACHED (its prefixed *.syncery-annotations.json name matches the
-- pattern) but DROPPED: the .sdr-LOCATION reconstruction yields a non-resolving
-- path (the dir is md5-named, not a book path), so the existence-gate drops it.
-- This is exactly what lets find_synced_books be the SOLE pathless emitter for
-- a not-opened hashdocsettings book -- the general walk never emits a duplicate,
-- so the de-dup needs no annotations_path key.
-- ---------------------------------------------------------------------------
do
    local root = h.test_root .. "/scan_hashdoc_drop"
    -- hashdocsettings-shaped .sdr: md5-named dir, prefixed annotations file, NO
    -- progress sibling, and NO real book at the reconstructed location.
    os.execute("mkdir -p '" .. root .. "/hashdocsettings/59/abcdef.sdr' 2>/dev/null")
    do
        local f = io.open(root .. "/hashdocsettings/59/abcdef.sdr/My Book.epub.syncery-annotations.json", "w")
        f:write('{"schema_version":1,"annotations":{}}'); f:close()
    end

    package.loaded["libs/libkoreader-lfs"] = require("lfs")
    package.loaded["ffi/util"] = {
        joinPath = function(a, b) return a .. "/" .. b end,
        gettime  = function() return os.time() end,
    }
    package.loaded["syncery_ui/booklist/scan"] = nil
    local ScanW = require("syncery_ui/booklist/scan")

    local books = {}
    local walk = ScanW.make_cancellable_walk(books, function() return false end, nil)
    walk(root, "%.syncery%-progress%.json$", {})

    h.assert_equal(#books, 0,
        "make_cancellable_walk: a hashdocsettings annotations-only .sdr is reached but DROPPED (non-resolving reconstruction) -> walk is not a second pathless emitter")
end


-- ---------------------------------------------------------------------------
-- make_cancellable_walk — for a .sdr in a CENTRAL tree (docsettings/), the
-- discovered `file` must be the REAL book path read from the JSON, NOT the
-- path reconstructed from the .sdr's filesystem LOCATION.  Regression for the
-- duplicate-book bug: find_synced_books_in_dir reads the real path from the
-- JSON, so if this walk emitted the location-reconstructed (docsettings-
-- prefixed) path instead, the two scans produced DIFFERENT `file` values for
-- the same book and the de-dup could not collapse them — the book showed
-- twice (once with its extension, once without).  Display must also be the
-- extension-stripped title, matching the dir/hash finders + scanHash.
-- ---------------------------------------------------------------------------
do
    package.loaded["libs/libkoreader-lfs"] = require("lfs")
    package.loaded["ffi/util"] = {
        joinPath = function(a, b) return a .. "/" .. b end,
        gettime  = function() return os.time() end,
    }
    package.loaded["syncery_ui/booklist/scan"] = nil
    local Scan3 = require("syncery_ui/booklist/scan")

    -- A .sdr living UNDER a docsettings-style prefix, whose name mirrors the
    -- book path.  Its JSON records the book's REAL location elsewhere.
    local base = h.test_root .. "/dirloc_" .. tostring(os.time())
    local real_book = "/realbooks/BG/Sizif.epub"
    local sdr = base .. "/koreader/docsettings/realbooks/BG/Sizif.sdr"
    os.execute("mkdir -p '" .. sdr .. "' 2>/dev/null")
    local pf = sdr .. "/Sizif.epub.syncery-progress.json"
    local f = io.open(pf, "w")
    f:write('{"schema_version":1,"entries":{"dev1":{"device_id":"dev1","file":"'
        .. real_book .. '","percent":0.06}}}')
    f:close()

    -- Precondition: the LOCATION reconstruction gives the WRONG (docsettings-
    -- prefixed) path — confirming the two derivations genuinely diverge here,
    -- so the assertions below actually exercise the fix.
    local reconstructed = Scan3._book_path_from_sdr_progress(pf)
    h.assert_true(reconstructed ~= nil and reconstructed ~= real_book,
        "precondition: .sdr-location reconstruction differs from the real book path")

    local books = {}
    local walk = Scan3.make_cancellable_walk(books, function() return false end, nil)
    walk(base, "%.syncery%-progress%.json$", {})

    h.assert_equal(#books, 1,
        "make_cancellable_walk: one row for the central-tree .sdr")
    h.assert_equal(books[1].file, real_book,
        "make_cancellable_walk: file is the REAL path from the JSON, not the "
        .. ".sdr-location reconstruction (de-dup can now collapse it with the dir finder)")
    h.assert_equal(books[1].display_name, "Sizif",
        "make_cancellable_walk: display is the extension-stripped title")
end


-- ---------------------------------------------------------------------------
-- CROSS-SCAN de-dup — a `.sdr` reached by BOTH find_synced_books_in_dir AND
-- the root walk (the real on-device configuration: the synced Syncthing folder
-- sits INSIDE the docsettings tree, so a walk root descends into the same tree
-- the dir finder covers) must yield ONE row, not two.  Regression for the
-- duplicate-book bug reproduced from real device data: the walk used to pick
-- the FIRST pairs() entry (no existence check, no local preference) while the
-- dir finder picked THIS device's resolving entry, so a book read on several
-- devices got two different `file` keys the de-dup could not collapse — it
-- showed twice, and intermittently (pairs() order shifts across restarts).
-- Both now route through the shared HashLocationFinder.resolve_book_file, so
-- they always compute the SAME path.  Reverting the walk to the old first-hit
-- pick makes this fail (two rows).
-- ---------------------------------------------------------------------------
do
    package.loaded["libs/libkoreader-lfs"] = require("lfs")
    package.loaded["ffi/util"] = { joinPath = function(a, b) return a .. "/" .. b end }
    package.loaded["syncery_ann/hash_location_finder"] = nil
    package.loaded["syncery_ui/booklist/scan"] = nil
    local ScanX = require("syncery_ui/booklist/scan")
    local HLFX  = require("syncery_ann/hash_location_finder")
    local lfs   = require("libs/libkoreader-lfs")
    local StateStore = require("syncery_progress/state_store")

    local stamp  = tostring(os.time()) .. "_" .. tostring(math.random(1000000))
    local base   = h.test_root .. "/xscan_" .. stamp
    local dsroot = base .. "/koreader/docsettings"

    local saved_ds = package.loaded["datastorage"]
    package.loaded["datastorage"] = {
        getDataDir        = function() return base end,
        getDocSettingsDir = function() return dsroot end,
    }
    local _saved_grs = _G.G_reader_settings
    _G.G_reader_settings = { _t = {},
        readSetting = function(self, k) return self._t[k] end,
        saveSetting = function(self, k, v) self._t[k] = v end }

    local DEV_A = "aaaadevice000000000000000000000000000000"
    local DEV_Z = "zzzzdevice000000000000000000000000000000"

    -- One .sdr in the docsettings tree, reachable by BOTH scans.
    local sdr = dsroot .. "/books/BG/Crime.sdr"
    os.execute("mkdir -p '" .. sdr .. "' 2>/dev/null")
    local pf = sdr .. "/Crime.epub.syncery-progress.json"

    local local_book   = "/tmp/xscan_local_" .. stamp .. ".epub"
    io.open(local_book, "w"):close()                 -- present here
    local foreign_book = "/tmp/xscan_foreign_" .. stamp .. ".epub"  -- never created

    local function write_two(path, fileA, fileZ)
        local f = io.open(path, "w")
        f:write('{"schema_version":1,"entries":{'
            .. '"' .. DEV_A .. '":{"device_id":"' .. DEV_A .. '","file":"' .. fileA .. '","percent":0.2},'
            .. '"' .. DEV_Z .. '":{"device_id":"' .. DEV_Z .. '","file":"' .. fileZ .. '","percent":0.3}}}')
        f:close()
    end

    -- Probe which key pairs() yields first (via the walk's own load path) and
    -- make THAT the foreign/absent device, so the OLD first-hit walk would
    -- deterministically pick the absent foreign path — the break is not flaky.
    write_two(pf, local_book, foreign_book)
    local function first_key(p)
        local norm = StateStore.normalize(ScanX._load_json(p))
        for k in pairs(norm.entries) do return k end
    end
    local FOREIGN = first_key(pf)
    local LOCAL   = (FOREIGN == DEV_A) and DEV_Z or DEV_A
    if LOCAL == DEV_A then write_two(pf, local_book, foreign_book)
    else                   write_two(pf, foreign_book, local_book) end
    G_reader_settings:saveSetting("syncery_device_id", LOCAL)

    -- Run BOTH scans over the SAME tree (order mirrors the booklist/browser:
    -- the dir finder first, then the root walk), then de-dup by `file`.
    local raw = {}
    for _, b in ipairs(HLFX.find_synced_books_in_dir({}, {})) do raw[#raw + 1] = b end
    local walk = ScanX.make_cancellable_walk(raw, function() return false end, nil)
    walk(dsroot, "%.syncery%-progress%.json$", {})
    local seen, deduped = {}, {}
    for _, b in ipairs(raw) do
        local key = b.file or b.annotations_path
        if key and not seen[key] then seen[key] = true; deduped[#deduped + 1] = b end
    end

    h.assert_true(#raw >= 2,
        "cross-scan precondition: both the dir finder and the walk emitted a row")
    h.assert_equal(#deduped, 1,
        "cross-scan: the walk and the dir finder collapse to ONE row for a "
        .. "multi-device book (the duplicate is gone)")
    h.assert_equal(deduped[1].file, local_book,
        "cross-scan: the surviving row carries THIS device's present local path")

    os.remove(local_book)
    package.loaded["datastorage"] = saved_ds
    _G.G_reader_settings = _saved_grs
    package.loaded["syncery_ann/hash_location_finder"] = nil
    package.loaded["syncery_ui/booklist/scan"] = nil
end


-- ---------------------------------------------------------------------------
-- display_label — the shared extension-stripping label used by every SDR
-- scan path, so the same book reads identically wherever it surfaced.
-- ---------------------------------------------------------------------------
do
    h.assert_equal(Scan._display_label("/a/b/My Book.epub", "fb"), "My Book",
        "display_label: strips the extension")
    h.assert_equal(Scan._display_label("/a/b/Plain", "fb"), "Plain",
        "display_label: no extension → unchanged")
    h.assert_equal(Scan._display_label(nil, "fb"), "fb",
        "display_label: nil book file → fallback")
end


-- ---------------------------------------------------------------------------
-- scanHash round-trip: writer (sharded _shared_book_state_dir) and scanner
-- must agree on the synceryhash/<shard>/<id>/ layout.
-- ---------------------------------------------------------------------------
do
    local AnnPaths = require("syncery_ann/paths")
    AnnPaths.set_storage_mode("hash")

    -- Write a progress file through the REAL builder, so the path is
    -- whatever the builder produces (now sharded).  If the scanner's
    -- enumeration ever diverges from the builder's layout, this breaks.
    local book = "/tmp/scanhash_roundtrip_book.epub"
    local book_dir = AnnPaths._shared_book_state_dir(book)
    h.assert_true(book_dir ~= nil, "builder produced a book dir")
    -- Sanity: the builder really sharded (…./synceryhash/<2hex>/<id>/).
    h.assert_true(
        book_dir:match("/synceryhash/[0-9a-f][0-9a-f]/[0-9a-f]+$") ~= nil,
        "builder path is sharded by 2 hex chars")

    local pf = io.open(book_dir .. "/syncery-progress.json", "w")
    pf:write('{"entries":{"dev1":{"file":"' .. book .. '","percent":0.5}}}')
    pf:close()

    local found = {}
    Scan.scanHash(found)

    local hit = nil
    for _, b in ipairs(found) do
        if b.progress_path == book_dir .. "/syncery-progress.json" then
            hit = b
            break
        end
    end
    h.assert_true(hit ~= nil,
        "scanHash finds a book written under the sharded layout")
    h.assert_equal(hit.mode, "hash", "scanned book is tagged mode='hash'")
    h.assert_equal(hit.file, book, "scanned book recovered its source file path")
end


-- ---------------------------------------------------------------------------
-- REGRESSION (data-loss fix): scanHash must be synceryhash-ONLY.  It has two
-- callers — booklist DISPLAY and migration (migrate_all_books old_mode=hash).
-- Migration moves synceryhash books OUT; if scanHash also returned
-- hashdocsettings books (already at their SDR destination), migration's
-- move_one would see src==dst and os.remove the live file.  So scanHash must
-- NOT surface hashdocsettings books — that belongs to the display path only.
-- ---------------------------------------------------------------------------
do
    local base = "/tmp/syncery_scanhash_synceryhash_only_" .. tostring(os.time())
        .. "_" .. tostring(math.random(1e6))
    local sync_state = base .. "/syncery_state"
    local hashdoc    = base .. "/koreader/hashdocsettings"
    os.execute("rm -rf '" .. base .. "'")
    os.execute("mkdir -p '" .. sync_state .. "' 2>/dev/null")        -- NO synceryhash/ child
    -- Plant a Syncery file ONLY in hashdocsettings (an already-migrated,
    -- SDR-storage book that migration must NOT touch).
    local sdr = hashdoc .. "/59/599fcbdeadbeef.sdr"
    os.execute("mkdir -p '" .. sdr .. "' 2>/dev/null")
    local pf = io.open(sdr .. "/Nietzsche.syncery-progress.json", "w")
    pf:write('{"schema_version":1,"entries":{"dev1":{"file":"/mnt/us/Books/Nietzsche.pdf","percent":0.4}}}')
    pf:close()

    local StorageMode = require("syncery_storage_mode")
    local saved_root = StorageMode.get_hash_root
    StorageMode.get_hash_root = function() return sync_state end
    local saved_ds = package.loaded["datastorage"]
    package.loaded["datastorage"] = {
        getDocSettingsHashDir = function() return hashdoc end,
        getDocSettingsDir     = function() return base .. "/koreader/docsettings" end,
    }
    package.loaded["syncery_ui/booklist/scan"] = nil
    local Scan3 = require("syncery_ui/booklist/scan")

    local found = {}
    Scan3.scanHash(found)

    -- scanHash must find NOTHING here: synceryhash/ is empty/absent, and the
    -- hashdocsettings book must NOT be returned (that would feed migration a
    -- book it then deletes).
    local leaked = false
    for _, b in ipairs(found) do
        if b.file == "/mnt/us/Books/Nietzsche.pdf" then leaked = true end
    end
    h.assert_true(not leaked,
        "scanHash is synceryhash-only: does NOT return hashdocsettings books (data-loss guard)")
    h.assert_equal(#found, 0,
        "scanHash returns no books when only hashdocsettings has data")

    StorageMode.get_hash_root = saved_root
    package.loaded["datastorage"] = saved_ds
    package.loaded["syncery_ui/booklist/scan"] = nil
    os.execute("rm -rf '" .. base .. "'")
end


-- ---------------------------------------------------------------------------
-- scanHash — annotations-ONLY synceryhash books (progress sync OFF).
--
-- A synceryhash book with only syncery-annotations.json (no progress file) must
-- still surface: display name from title.txt, annotations_path carried, mode
-- "hash".  The book path is recovered from KOReader's native metadata at the
-- same-md5 hashdocsettings .sdr (HashLocationFinder.doc_path_for_hash),
-- existence-gated; pathless (file=nil) when that native metadata is absent or
-- its doc_path does not resolve locally.  A book WITH a progress file still
-- takes the progress branch.
-- ---------------------------------------------------------------------------
do
    local base = "/tmp/syncery_scanhash_annonly_" .. tostring(os.time())
        .. "_" .. tostring(math.random(1e6))
    local sync_state = base .. "/syncery_state"
    local hashdoc    = base .. "/koreader/hashdocsettings"
    local books      = base .. "/books"
    os.execute("rm -rf '" .. base .. "'")
    os.execute("mkdir -p '" .. books .. "' 2>/dev/null")

    local function ann_of(id)
        return sync_state .. "/synceryhash/" .. id:sub(1,2) .. "/" .. id
            .. "/syncery-annotations.json"
    end
    local function mkbook_ann(id, title)
        local d = sync_state .. "/synceryhash/" .. id:sub(1,2) .. "/" .. id
        os.execute("mkdir -p '" .. d .. "' 2>/dev/null")
        local af = io.open(d .. "/syncery-annotations.json", "w")
        af:write('{"schema_version":1,"annotations":{}}'); af:close()
        local tf = io.open(d .. "/title.txt", "w"); tf:write(title); tf:close()
    end
    local function mk_native(id, doc_path)
        local sdr = hashdoc .. "/" .. id:sub(1,2) .. "/" .. id .. ".sdr"
        os.execute("mkdir -p '" .. sdr .. "' 2>/dev/null")
        local mf = io.open(sdr .. "/metadata.epub.lua", "w")
        mf:write('return { ["doc_path"] = "' .. doc_path .. '" }'); mf:close()
    end

    -- A: annotations-only + matching native metadata + book present → file recovered.
    local a_file = books .. "/Idiot.epub"
    do local fh = io.open(a_file, "w"); fh:write("epub"); fh:close() end
    mkbook_ann("aa11bb22cc01", "The Idiot")
    mk_native("aa11bb22cc01", a_file)

    -- B: annotations-only, NO native metadata → pathless.
    mkbook_ann("bb22cc33dd02", "War and Peace")

    -- C: annotations-only + native metadata whose doc_path is ABSENT → gate → pathless.
    mkbook_ann("cc33dd44ee03", "Crime and Punishment")
    mk_native("cc33dd44ee03", books .. "/Gone.epub")

    -- D: BOTH files → progress branch (priority), file from progress entry.
    local d_file = books .. "/Both.epub"
    do local fh = io.open(d_file, "w"); fh:write("epub"); fh:close() end
    local d_dir = sync_state .. "/synceryhash/dd/dd44ee55ff04"
    os.execute("mkdir -p '" .. d_dir .. "' 2>/dev/null")
    do local pf = io.open(d_dir .. "/syncery-progress.json", "w")
       pf:write('{"schema_version":1,"entries":{"dev1":{"file":"' .. d_file
           .. '","percent":0.3}}}'); pf:close() end
    do local af = io.open(d_dir .. "/syncery-annotations.json", "w")
       af:write('{"schema_version":1,"annotations":{}}'); af:close() end
    do local tf = io.open(d_dir .. "/title.txt", "w"); tf:write("Both Book"); tf:close() end

    local StorageMode = require("syncery_storage_mode")
    local saved_root = StorageMode.get_hash_root
    StorageMode.get_hash_root = function() return sync_state end
    local saved_ds = package.loaded["datastorage"]
    package.loaded["datastorage"] = {
        getDocSettingsHashDir = function() return hashdoc end,
        getDocSettingsDir     = function() return base .. "/koreader/docsettings" end,
    }
    package.loaded["syncery_ui/booklist/scan"] = nil
    local Scan4 = require("syncery_ui/booklist/scan")

    local found = {}
    Scan4.scanHash(found)

    local byann, byfile = {}, {}
    for _, b in ipairs(found) do
        if b.annotations_path then byann[b.annotations_path] = b end
        if b.file then byfile[b.file] = b end
    end

    local a = byann[ann_of("aa11bb22cc01")]
    h.assert_true(a ~= nil, "scanHash annonly: annotations-only book surfaced")
    h.assert_equal(a and a.mode, "hash", "scanHash annonly: tagged mode=hash")
    h.assert_equal(a and a.display_name, "The Idiot",
        "scanHash annonly: display name from title.txt")
    h.assert_equal(a and a.progress_path, nil, "scanHash annonly: no progress_path")
    h.assert_equal(a and a.file, a_file,
        "scanHash annonly: file recovered via native doc_path cross-lookup")

    local b = byann[ann_of("bb22cc33dd02")]
    h.assert_true(b ~= nil,
        "scanHash annonly: pathless book still surfaced (no native metadata)")
    h.assert_equal(b and b.file, nil,
        "scanHash annonly: pathless when no native metadata (file=nil)")
    h.assert_equal(b and b.display_name, "War and Peace",
        "scanHash annonly: pathless book named from title.txt")

    local c = byann[ann_of("cc33dd44ee03")]
    h.assert_true(c ~= nil,
        "scanHash annonly: book with absent doc_path still surfaced")
    h.assert_equal(c and c.file, nil,
        "scanHash annonly: existence-gate drops a non-resolving doc_path (file=nil)")

    local d = byfile[d_file]
    h.assert_true(d ~= nil, "scanHash annonly: both-files book surfaced via progress")
    h.assert_true(d and d.progress_path ~= nil,
        "scanHash annonly: both-files row is the PROGRESS row")

    StorageMode.get_hash_root = saved_root
    package.loaded["datastorage"] = saved_ds
    package.loaded["syncery_ui/booklist/scan"] = nil
    os.execute("rm -rf '" .. base .. "'")
end


-- promptForScanRoot offers a ConfirmBox with a Browse OK button (no raw text
-- field) and, when the KOReader metadata dir resolves, a second button for it.
do
    local cb = package.loaded["ui/widget/confirmbox"]
    cb._shown = {}
    -- DataStorage stub so koreader_metadata_dir() resolves a folder.
    package.loaded["datastorage"] = {
        getDocSettingsDir = function() return "/tmp/koreader_docsettings" end,
    }
    -- Re-require scan with the stub in place.
    package.loaded["syncery_ui/booklist/scan"] = nil
    local Scan2 = require("syncery_ui/booklist/scan")

    local got_roots = nil
    Scan2.promptForScanRoot(function(roots) got_roots = roots end)

    local box = cb._shown[#cb._shown]
    h.assert_true(box ~= nil, "promptForScanRoot shows a ConfirmBox")
    h.assert_true(type(box.ok_callback) == "function",
        "ConfirmBox OK (Browse) is wired")
    h.assert_true(box.other_buttons ~= nil,
        "ConfirmBox offers the KOReader-metadata-folder button when it resolves")
    -- Tapping the metadata-folder button calls back with that dir.
    local meta_btn = box.other_buttons[1][1]
    h.assert_true(meta_btn ~= nil and type(meta_btn.callback) == "function",
        "metadata-folder button has a callback")
    meta_btn.callback()
    h.assert_true(got_roots ~= nil and got_roots[1] == "/tmp/koreader_docsettings",
        "metadata-folder button passes the central dir to the callback")

    -- promptForRoot (the old raw-text, Kindle-prefilled flow) was removed,
    -- replaced by promptForScanRoot (the visual picker above).  Lock it gone.
    h.assert_true(Scan2.promptForRoot == nil,
        "the dead promptForRoot (raw-text Kindle-prefill flow) is removed")

    package.loaded["syncery_ui/booklist/scan"] = nil
end


-- ---------------------------------------------------------------------------
-- REGRESSION (multi-device migration, syncery_ui/booklist/scan.lua): a book
-- read on several devices carries ONE progress entry PER device, each stamped
-- with that device's OWN path. scanHash must pick the entry whose path exists
-- on THIS device (the local one), not an arbitrary `pairs()` first hit. The old
-- first-hit pick returned ANOTHER device's (foreign) path on a multi-device
-- setup, so the migration safety net saw a non-existent file, skipped the book,
-- and mislabelled it "already in new location" while its data stayed in
-- synceryhash. `pairs()` order is UNSPECIFIED and build-dependent (on the
-- reporting user's device it yielded the foreign entry first); the fix is
-- order-independent. To keep this guard meaningful on ANY build, the test
-- PROBES -- via scanHash's exact load path -- which key this build yields
-- first, and makes THAT the foreign (absent) device, so reverting to the
-- first-hit pick always selects the foreign path and the assertions fail.
-- ---------------------------------------------------------------------------
do
    local Scan       = require("syncery_ui/booklist/scan")
    local AnnPaths   = require("syncery_ann/paths")
    local lfs        = require("libs/libkoreader-lfs")
    local StateStore = require("syncery_progress/state_store")
    AnnPaths.set_storage_mode("hash")

    local KINDLE  = "dev_1778532242_000001_a93e56debc596d3b918f1d4d0e0df962"
    local SAMSUNG = "dev_1779017986_000001_a93e56debc596d3b918f1d4d0e0df962"
    local stamp   = tostring(os.time())

    -- This spec has no G_reader_settings; install a minimal one so
    -- Util.get_device_id() reports the local device (restored at end).
    local _saved_grs = _G.G_reader_settings
    _G.G_reader_settings = { _t = {},
        readSetting = function(self, k) return self._t[k] end,
        saveSetting = function(self, k, v) self._t[k] = v end }

    -- Two-entry JSON writer (Kindle key -> fileK, Samsung key -> fileS).
    local function write_two_entry(path, fileK, fileS)
        local f = io.open(path, "w")
        f:write('{"schema_version":1,"entries":{'
            .. '"' .. KINDLE  .. '":{"device_id":"' .. KINDLE  .. '","file":"' .. fileK .. '","percent":0.3},'
            .. '"' .. SAMSUNG .. '":{"device_id":"' .. SAMSUNG .. '","file":"' .. fileS .. '","percent":0.4}}}')
        f:close()
    end
    -- The key scanHash's pairs() loop yields FIRST, via its EXACT load path
    -- (Scan._load_json + state_store.normalize). Deterministic for a build, so
    -- it equals what the reverted first-hit pick would select.
    local function first_key(progress_path)
        local norm = StateStore.normalize(Scan._load_json(progress_path))
        for k in pairs(norm.entries) do return k end
    end

    -- Book A: two entries; both candidate paths created on disk for now.
    local pathK = "/tmp/devsel_K_" .. stamp .. ".epub"
    local pathS = "/tmp/devsel_S_" .. stamp .. ".epub"
    io.open(pathK, "w"):close()
    io.open(pathS, "w"):close()
    local dirA = AnnPaths._shared_book_state_dir("/tmp/devsel_book_A.epub")
    os.execute("mkdir -p '" .. dirA .. "' 2>/dev/null")
    local pA = dirA .. "/syncery-progress.json"
    write_two_entry(pA, pathK, pathS)

    -- Roles from the probe: the pairs()-first key is the foreign device.
    local DEV_FOREIGN  = first_key(pA)
    local DEV_LOCAL    = (DEV_FOREIGN == KINDLE) and SAMSUNG or KINDLE
    local local_path   = (DEV_LOCAL == KINDLE) and pathK or pathS
    local foreign_path = (DEV_LOCAL == KINDLE) and pathS or pathK
    G_reader_settings:saveSetting("syncery_device_id", DEV_LOCAL)
    os.remove(foreign_path)                      -- foreign device's path: absent here

    -- Book C: same two keys, BOTH paths on disk (device_id isolation).
    local pathKc = "/tmp/devsel_Kc_" .. stamp .. ".epub"
    local pathSc = "/tmp/devsel_Sc_" .. stamp .. ".epub"
    io.open(pathKc, "w"):close()
    io.open(pathSc, "w"):close()
    local dirC = AnnPaths._shared_book_state_dir("/tmp/devsel_book_C.epub")
    os.execute("mkdir -p '" .. dirC .. "' 2>/dev/null")
    local pC = dirC .. "/syncery-progress.json"
    write_two_entry(pC, pathKc, pathSc)
    local local_path_c = (DEV_LOCAL == KINDLE) and pathKc or pathSc

    -- Book B: same two keys, NEITHER path on disk (book not on this device).
    local absent1 = "/tmp/devsel_absent1_" .. stamp .. ".epub"
    local absent2 = "/tmp/devsel_absent2_" .. stamp .. ".epub"
    local dirB = AnnPaths._shared_book_state_dir("/tmp/devsel_book_B.epub")
    os.execute("mkdir -p '" .. dirB .. "' 2>/dev/null")
    local pB = dirB .. "/syncery-progress.json"
    write_two_entry(pB, absent1, absent2)

    local found = {}
    Scan.scanHash(found)
    local hitA, hitB, hitC
    for _, b in ipairs(found) do
        if b.progress_path == pA then hitA = b end
        if b.progress_path == pB then hitB = b end
        if b.progress_path == pC then hitC = b end
    end

    -- PRIMARY GUARD (real bug): scanHash picks THIS device's resolving entry,
    -- not the pairs()-first (foreign) one. Reverting to the old first-hit pick
    -- selects the foreign/absent path and both assertions below fail.
    h.assert_true(hitA ~= nil, "scanHash found the multi-device book")
    h.assert_equal(hitA.file, local_path,
        "scanHash picks THIS device's entry, not the pairs()-first foreign one")
    h.assert_true(lfs.attributes(hitA.file, "mode") == "file",
        "the chosen book.file resolves on disk (migration safety net will NOT skip it)")

    -- DEVICE-ID ISOLATION: with BOTH paths on disk, only matching this device's
    -- id yields the local path (a resolving-only pick would take pairs()-first).
    h.assert_true(hitC ~= nil, "scanHash found the both-on-disk book")
    h.assert_equal(hitC.file, local_path_c,
        "both paths on disk: scanHash picks THIS device's path by device_id")

    -- DISPLAY PRESERVATION: a book absent on this device is still named for the
    -- management view (book.file falls back to a recorded path; migration's
    -- safety net then correctly skips it).
    h.assert_true(hitB ~= nil, "scanHash still returns a book absent on this device")
    h.assert_true(hitB.file == absent1 or hitB.file == absent2,
        "absent-everywhere book still carries a recorded path for display")

    _G.G_reader_settings = _saved_grs           -- restore (do not leak across specs)
    package.loaded["syncery_ui/booklist/scan"] = nil
end


-- ---------------------------------------------------------------------------
-- make_cancellable_walk — must NOT descend into Syncthing's internal folders.
-- Under Trash-Can versioning `.stversions` keeps a verbatim copy of a changed
-- sidecar's `<book>.sdr/<book>.syncery-progress.json`.  Recursing it re-emits
-- that stale copy; when its recorded book path differs from the live one (the
-- file was renamed since), the two rows carry DIFFERENT `file` values and the
-- de-dup cannot collapse them -> the book shows twice.  The walk must skip
-- `.stversions` (and `.stfolder`) entirely.
-- ---------------------------------------------------------------------------
do
    package.loaded["libs/libkoreader-lfs"] = require("lfs")
    package.loaded["ffi/util"] = {
        joinPath = function(a, b) return a .. "/" .. b end,
        gettime  = function() return os.time() end,
    }
    package.loaded["syncery_ui/booklist/scan"] = nil
    local ScanV = require("syncery_ui/booklist/scan")
    local lfs_real = require("lfs")

    local base = h.test_root .. "/stversions_walk_" .. tostring(os.time())
    local live_sdr = base .. "/books/MyBook.sdr"
    os.execute("mkdir -p '" .. live_sdr .. "' 2>/dev/null")
    local live_pf = live_sdr .. "/MyBook.epub.syncery-progress.json"
    do local f = io.open(live_pf, "w")
       f:write('{"schema_version":1,"entries":{"dev1":{"device_id":"dev1",'
           .. '"file":"/realbooks/MyBook.epub","percent":0.1}}}'); f:close() end
    -- STALE copy inside `.stversions`, recording a DIFFERENT (pre-rename) path,
    -- so a path-keyed de-dup could NOT collapse it against the live row.
    local stale_sdr = base .. "/books/.stversions/MyBook.sdr"
    os.execute("mkdir -p '" .. stale_sdr .. "' 2>/dev/null")
    local stale_pf = stale_sdr .. "/MyBook.epub.syncery-progress.json"
    do local f = io.open(stale_pf, "w")
       f:write('{"schema_version":1,"entries":{"dev1":{"device_id":"dev1",'
           .. '"file":"/realbooks/OldName.epub","percent":0.1}}}'); f:close() end

    h.assert_true(lfs_real.attributes(live_pf, "mode") == "file"
        and lfs_real.attributes(stale_pf, "mode") == "file",
        "precondition: live + .stversions progress files both exist on disk")

    local books = {}
    local walk = ScanV.make_cancellable_walk(books, function() return false end, nil)
    walk(base, "%.syncery%-progress%.json$", {})

    h.assert_equal(#books, 1,
        "make_cancellable_walk: skips .stversions -> only the live book is emitted")
    h.assert_equal(books[1].file, "/realbooks/MyBook.epub",
        "make_cancellable_walk: the emitted row is the LIVE path, not the "
        .. ".stversions copy's stale path")
    package.loaded["syncery_ui/booklist/scan"] = nil
end


-- ---------------------------------------------------------------------------
-- make_cancellable_walk — annotations-only books (progress sync OFF), doc mode
--
-- A book with progress sync off has only *.syncery-annotations.json beside it
-- (no progress file).  The walk must still emit it, reconstructing the path
-- from the .sdr location.  Progress takes priority when both exist (sibling
-- check).  Phase 1 emits only when the reconstructed path resolves on disk.
-- ---------------------------------------------------------------------------
do
    package.loaded["libs/libkoreader-lfs"] = require("lfs")
    package.loaded["ffi/util"] = {
        joinPath = function(a, b) return a .. "/" .. b end,
        gettime  = function() return os.time() end,
    }
    package.loaded["syncery_ui/booklist/scan"] = nil
    local ScanV = require("syncery_ui/booklist/scan")

    local base = h.test_root .. "/annonly_walk_" .. tostring(os.time())
        .. "_" .. tostring(math.random(1e6))
    local books_dir = base .. "/books"
    os.execute("mkdir -p '" .. books_dir .. "' 2>/dev/null")

    -- A — annotations-only, present: .sdr beside the book, only the annotations
    -- file, real book file on disk.  Must be emitted (path reconstructed).
    local a_file = books_dir .. "/AnnOnly.epub"
    do local f = io.open(a_file, "w"); f:write("epub"); f:close() end
    os.execute("mkdir -p '" .. books_dir .. "/AnnOnly.sdr' 2>/dev/null")
    do local f = io.open(books_dir .. "/AnnOnly.sdr/AnnOnly.epub.syncery-annotations.json", "w")
       f:write('{"schema_version":1,"annotations":{}}'); f:close() end

    -- B — both files, present: progress takes priority -> one row (progress).
    local b_file = books_dir .. "/Both.epub"
    do local f = io.open(b_file, "w"); f:write("epub"); f:close() end
    os.execute("mkdir -p '" .. books_dir .. "/Both.sdr' 2>/dev/null")
    do local f = io.open(books_dir .. "/Both.sdr/Both.epub.syncery-progress.json", "w")
       f:write('{"schema_version":1,"entries":{"dev1":{"device_id":"dev1","file":"'
           .. b_file .. '","percent":0.1}}}'); f:close() end
    do local f = io.open(books_dir .. "/Both.sdr/Both.epub.syncery-annotations.json", "w")
       f:write('{"schema_version":1,"annotations":{}}'); f:close() end

    -- C — annotations-only, ABSENT: only the annotations file, no real book
    -- file.  Reconstruction does not resolve -> must NOT be emitted.
    os.execute("mkdir -p '" .. books_dir .. "/Absent.sdr' 2>/dev/null")
    do local f = io.open(books_dir .. "/Absent.sdr/Absent.epub.syncery-annotations.json", "w")
       f:write('{"schema_version":1,"annotations":{}}'); f:close() end

    local books = {}
    local walk = ScanV.make_cancellable_walk(books, function() return false end, nil)
    walk(base, "%.syncery%-progress%.json$", {})
    local byfile = {}
    for _, b in ipairs(books) do byfile[b.file or ""] = b end

    h.assert_true(byfile[a_file] ~= nil,
        "walk annonly: an annotations-only book (no progress file) is emitted")
    h.assert_equal((byfile[a_file] or {}).progress_path, nil,
        "walk annonly: its row has no progress_path")
    h.assert_true((byfile[a_file] or {}).annotations_path ~= nil,
        "walk annonly: its row carries the annotations path")
    h.assert_true(byfile[b_file] ~= nil,
        "walk annonly: a both-files book is emitted once via progress priority")
    h.assert_true((byfile[b_file] or {}).progress_path ~= nil,
        "walk annonly: the both-files row is the PROGRESS row, not annotations-only")
    local b_count = 0
    for _, b in ipairs(books) do if b.file == b_file then b_count = b_count + 1 end end
    h.assert_equal(b_count, 1,
        "walk annonly: the both-files book is emitted EXACTLY once (sibling-check = progress priority)")
    h.assert_true(byfile[books_dir .. "/Absent.epub"] == nil,
        "walk annonly: an annotations-only book with NO local file is NOT emitted (existence-gated)")

    package.loaded["syncery_ui/booklist/scan"] = nil
end


-- ---------------------------------------------------------------------------
-- scanSDR — the migration root-walk shares make_cancellable_walk's hazard and
-- must skip `.stversions`/`.stfolder` too (a stale archived copy migrated as a
-- second book would trip move_one's src-deletion branch on a phantom path).
-- ---------------------------------------------------------------------------
do
    package.loaded["libs/libkoreader-lfs"] = require("lfs")
    package.loaded["ffi/util"] = {
        joinPath = function(a, b) return a .. "/" .. b end,
        gettime  = function() return os.time() end,
    }
    package.loaded["syncery_ui/booklist/scan"] = nil
    local ScanS = require("syncery_ui/booklist/scan")

    local base = h.test_root .. "/stversions_sdr_" .. tostring(os.time())
    local live_sdr = base .. "/books/MyBook.sdr"
    os.execute("mkdir -p '" .. live_sdr .. "' 2>/dev/null")
    do local f = io.open(live_sdr .. "/MyBook.epub.syncery-progress.json", "w")
       f:write('{"schema_version":1,"entries":{"dev1":{"device_id":"dev1",'
           .. '"file":"/realbooks/MyBook.epub","percent":0.1}}}'); f:close() end
    local stale_sdr = base .. "/books/.stversions/MyBook.sdr"
    os.execute("mkdir -p '" .. stale_sdr .. "' 2>/dev/null")
    do local f = io.open(stale_sdr .. "/MyBook.epub.syncery-progress.json", "w")
       f:write('{"schema_version":1,"entries":{"dev1":{"device_id":"dev1",'
           .. '"file":"/realbooks/OldName.epub","percent":0.1}}}'); f:close() end

    local books = {}
    ScanS.scanSDR({ base }, books)
    h.assert_equal(#books, 1,
        "scanSDR: skips .stversions -> only the live book is emitted")
    h.assert_equal(books[1].file, "/realbooks/MyBook.epub",
        "scanSDR: the emitted row is the LIVE path, not the .stversions stale path")
    package.loaded["syncery_ui/booklist/scan"] = nil
end


-- ---------------------------------------------------------------------------
-- scanHash — synceryhash/ is itself a synced folder, so `.stversions` appears
-- at the shard level.  scanHash's flat-layout tolerance (it tries each
-- top-level entry as a book dir before descending) would read a flat
-- `.stversions/syncery-progress.json` archive as a stray book and emit a
-- phantom.  The shard-level skip must suppress it.
-- ---------------------------------------------------------------------------
do
    package.loaded["libs/libkoreader-lfs"] = require("lfs")
    package.loaded["ffi/util"] = {
        joinPath = function(a, b) return a .. "/" .. b end,
        gettime  = function() return os.time() end,
    }
    local base = h.test_root .. "/stversions_hash_" .. tostring(os.time())
    local sync_state = base .. "/syncery_state"
    local hashroot   = sync_state .. "/synceryhash"
    -- A REAL sharded book (the normal layout scanHash reaches via 2-level descent).
    local real_dir = hashroot .. "/a1/a1b2c3"
    os.execute("mkdir -p '" .. real_dir .. "' 2>/dev/null")
    do local f = io.open(real_dir .. "/syncery-progress.json", "w")
       f:write('{"entries":{"dev1":{"file":"/realbooks/Real.epub","percent":0.5}}}'); f:close() end
    -- A FLAT `.stversions` archive that the flat-layout tolerance would mis-read.
    local stale_dir = hashroot .. "/.stversions"
    os.execute("mkdir -p '" .. stale_dir .. "' 2>/dev/null")
    do local f = io.open(stale_dir .. "/syncery-progress.json", "w")
       f:write('{"entries":{"dev1":{"file":"/realbooks/Phantom.epub","percent":0.5}}}'); f:close() end

    local StorageMode = require("syncery_storage_mode")
    local saved_root = StorageMode.get_hash_root
    StorageMode.get_hash_root = function() return sync_state end
    package.loaded["syncery_ui/booklist/scan"] = nil
    local ScanH = require("syncery_ui/booklist/scan")

    local found = {}
    ScanH.scanHash(found)

    local saw_phantom = false
    for _, b in ipairs(found) do
        if b.file == "/realbooks/Phantom.epub" then saw_phantom = true end
    end
    h.assert_false(saw_phantom,
        "scanHash: skips .stversions -> the flat archive is NOT read as a phantom book")
    h.assert_equal(#found, 1,
        "scanHash: only the real sharded book is emitted")

    StorageMode.get_hash_root = saved_root
    package.loaded["syncery_ui/booklist/scan"] = nil
    os.execute("rm -rf '" .. base .. "'")
end


h.teardown()
