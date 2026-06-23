-- =============================================================================
-- spec/migration_scattered_ui_spec.lua
-- =============================================================================
--
-- Step 3: the three-state advisory shown after a synceryhash -> SDR migration.
--
--   state 1  total_scattered > 0          -> full advisory: intro + per-location
--                                            breakdown + the gear→Document→Move
--                                            book metadata path.
--   state 2  scanned > 0, scattered == 0  -> short "all already in selected
--                                            location" confirmation.
--   state 3  total_scanned == 0           -> NO advisory (silence) — we make no
--                                            claim when nothing was scanned or
--                                            the detection API is unavailable.
--
-- We exercise the REAL perform_migration (its Trapper wrap runs the on_complete
-- callback that builds the advisory), mock scanHash to supply a known book set,
-- and inject a docsettings whose findSidecarFile reports each book's location.
--
-- The advisory is now the migration-result message's dismiss FOLLOW-UP
-- (perform_migration shows it via the result message's dismiss_callback), so it
-- reads AFTER the result, not stacked on top.  This spec drives that path: it
-- runs migrate_all_books, then fire_followups() to simulate dismissing the
-- result, and asserts the advisory then appears with the right CONTENT and
-- STATE SELECTION.
--
-- HONEST LIMIT: the harness's UIManager/InfoMessage stubs do not reproduce
-- KOReader's real widget lifecycle, so this proves the dismiss_callback WIRING
-- (the result carries the follow-up; firing it shows the advisory) but not that
-- KOReader fires onCloseWidget exactly once at dismiss -- that rests on
-- InfoMessage's dismiss_callback being a supported Trapper idiom (the Lazarus
-- hack in infomessage.lua preserves it).
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_scattered_ui_spec_" .. tostring(os.time()))

-- UI + platform stubs. We capture every InfoMessage text shown.
package.loaded["ffi/util"] = {
    joinPath = function(a, b) return a .. "/" .. b end,
    gettime  = function() return os.time() end,
    basename = function(p) return p:match("([^/]+)$") or p end,
}
local shown = {}          -- captured widgets (for dismiss-callback follow-ups)
local shown_texts = {}
package.loaded["ui/uimanager"] = {
    show = function(_, w)
        shown[#shown + 1] = w
        if type(w) == "table" and w.text then
            shown_texts[#shown_texts + 1] = w.text
        end
    end,
    close = function() end,
}

-- Approach A shows the scattered advisory as the migration-result message's
-- dismiss FOLLOW-UP (sequential, not stacked).  Simulate the user dismissing
-- each shown message so any queued follow-up appears -- iterating, since a
-- follow-up could in principle carry its own.
local function fire_followups()
    local i = 1
    while i <= #shown do
        local w = shown[i]
        if type(w) == "table" and type(w.dismiss_callback) == "function"
           and not w._fired then
            w._fired = true
            w.dismiss_callback()
        end
        i = i + 1
    end
end
package.loaded["ui/widget/infomessage"] = { new = function(_, a) return a or {} end }
package.loaded["ui/widget/confirmbox"]  = { new = function(_, a) return a or {} end }
package.loaded["ui/trapper"] = {
    wrap = function(_, f) return f() end,   -- SYNCHRONOUS (see HONEST LIMIT above)
    info = function() return true end,
    reset = function() end,
}

-- Injected docsettings: findSidecarFile reports a per-book location.
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

-- preferred location = "doc" (book folder).
_G.G_reader_settings = _G.G_reader_settings or {}
local real_readSetting = _G.G_reader_settings.readSetting
_G.G_reader_settings.readSetting = function(_self, key, default)
    if key == "document_metadata_folder" then return "doc" end
    if real_readSetting then return real_readSetting(_self, key, default) end
    return default
end

local StorageMode = require("syncery_migration/storage_mode")
local BookList    = require("syncery_ui/booklist/init")

-- Controllable book set for scanHash.
local SCAN_SET = {}
local real_scanHash = BookList.scanHash
BookList.scanHash = function(books)
    for _, b in ipairs(SCAN_SET) do books[#books + 1] = b end
    return books
end

-- Helper: did any shown text contain `needle`?
local function shown_contains(needle)
    for _, t in ipairs(shown_texts) do
        if t:find(needle, 1, true) then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- STATE 1 — scattered > 0: full advisory with breakdown + path.
-- ---------------------------------------------------------------------------
do
    shown_texts = {}; shown = {}
    location_by_file = {
        ["/lib/A.epub"] = "dir",   -- scattered (docsettings)
        ["/lib/B.epub"] = "hash",  -- scattered (hashdocsettings)
        ["/lib/C.epub"] = "doc",   -- in preferred
    }
    SCAN_SET = { { file = "/lib/A.epub" }, { file = "/lib/B.epub" }, { file = "/lib/C.epub" } }

    StorageMode.migrate_all_books({ storage_mode = "sdr" }, "hash")

    -- Sequencing: the migration-result message is up first; the advisory is NOT
    -- shown until that result is dismissed.
    h.assert_true(shown_contains("Migrated"),
        "state1: the migration-result message is shown first")
    h.assert_false(shown_contains("metadata.lua files are"),
        "state1: the advisory is NOT shown until the result is dismissed")
    local completion
    for _, w in ipairs(shown) do
        if type(w) == "table" and w.text and w.text:find("Migrated", 1, true) then completion = w end
    end
    h.assert_true(completion ~= nil and completion.timeout == nil,
        "state1: the result message is sticky while a follow-up waits")
    h.assert_true(completion ~= nil and type(completion.dismiss_callback) == "function",
        "state1: the result message carries the advisory as a dismiss follow-up")

    fire_followups()

    h.assert_true(shown_contains("metadata.lua files are"),
        "state1: full advisory intro shown (after the result is dismissed)")
    h.assert_true(shown_contains("koreader/docsettings"),
        "state1: docsettings breakdown line shown")
    h.assert_true(shown_contains("koreader/hashdocsettings"),
        "state1: hashdocsettings breakdown line shown")
    h.assert_true(shown_contains("Move book metadata"),
        "state1: the consolidation path (Move book metadata) shown")
    h.assert_true(shown_contains("Document"),
        "state1: the gear->Document path shown")
    -- The short "all already" confirmation must NOT appear in this state.
    h.assert_false(shown_contains("already in the selected location"),
        "state1: short confirmation NOT shown when there are scattered files")
end

-- ---------------------------------------------------------------------------
-- STATE 2 — scanned > 0, scattered == 0: short confirmation.
-- ---------------------------------------------------------------------------
do
    shown_texts = {}; shown = {}
    location_by_file = {
        ["/lib/D.epub"] = "doc",   -- both in preferred => none scattered
        ["/lib/E.epub"] = "doc",
    }
    SCAN_SET = { { file = "/lib/D.epub" }, { file = "/lib/E.epub" } }

    StorageMode.migrate_all_books({ storage_mode = "sdr" }, "hash")
    fire_followups()   -- reveal the dismiss follow-up (the short confirmation)

    h.assert_true(shown_contains("already in the selected location"),
        "state2: short confirmation shown when nothing scattered")
    h.assert_false(shown_contains("Move book metadata"),
        "state2: full advisory NOT shown when nothing scattered")
end

-- ---------------------------------------------------------------------------
-- STATE 3 — scanned == 0: silence (no advisory of either kind).
-- A book set whose findSidecarFile returns nil for all => no metadata found.
-- ---------------------------------------------------------------------------
do
    shown_texts = {}; shown = {}
    location_by_file = {}   -- no book has metadata => total_scanned == 0
    SCAN_SET = { { file = "/lib/F.epub" }, { file = "/lib/G.epub" } }

    StorageMode.migrate_all_books({ storage_mode = "sdr" }, "hash")
    fire_followups()   -- no follow-up exists in this state; nothing to reveal

    h.assert_false(shown_contains("metadata.lua files are"),
        "state3: no full advisory when nothing scanned")
    h.assert_false(shown_contains("already in the selected location"),
        "state3: no short confirmation when nothing scanned (we make no claim)")
end

-- Restore.
BookList.scanHash = real_scanHash
_G.G_reader_settings.readSetting = real_readSetting

h.teardown()
print("migration_scattered_ui_spec: all assertions passed")
