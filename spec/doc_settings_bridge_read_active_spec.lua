-- =============================================================================
-- spec/doc_settings_bridge_read_active_spec.lua
-- =============================================================================
--
-- Tests for DocSettingsBridge._read_active_list — which annotation list the
-- sync engine reads as "what this device has locally".
--
-- THE BUG this guards against (fresh-book populate + cross-device loss):
--   KOReader keeps annotations in memory (ui.annotation.annotations) and only
--   writes that memory back to doc_settings["annotations"] at the next
--   onSaveSettings / onFlushSettings.  For a freshly-opened, never-saved book,
--   onReadSettings takes its first-run path: self.annotations is a NEW table,
--   NOT aliased to doc_settings (which has no "annotations" key yet).  So the
--   user's new highlights live in ui.annotation.annotations immediately while
--   doc_settings is still nil.
--
--   _read_active_list used to read doc_settings, so every first-session sync
--   read EMPTY.  Single-device that was only a delay (the annotations appear
--   on the 2nd open).  But cross-device it was permanent LOSS: if the book
--   already had annotations from another device (remote has [4,5]), the
--   close-time 3-way merge read empty-local, ADOPTED only the remote
--   ([4,5]) — the 3-way merge treats empty-local + empty-ancestor as a
--   non-destructive fresh-device adopt — and the close delivery (G) wrote
--   [4,5] over the live [1,2,3].  The "adopt is non-destructive" invariant
--   relies on the local read being ACCURATE; reading the lagging doc_settings
--   broke it.
--
-- THE FIX: in a live session prefer the in-memory list (always current).  The
-- doc_settings read stays as the fallback for bulk-ingest, which hands a
-- synthetic { doc_settings = ds } (no .annotation module) reading a sidecar
-- straight off disk.
--
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_read_active_spec_" .. tostring(os.time()))

local DocSettingsBridge = require("syncery_ann/doc_settings_bridge")


-- A fake doc_settings backed by a plain table.
local function make_doc_settings(seed)
    local store = seed or {}
    return {
        _store = store,
        saveSetting = function(_self, key, value) store[key] = value end,
        readSetting = function(_self, key) return store[key] end,
    }
end

-- _read_active_list returns the list as-is (identity keying happens later),
-- so a minimal shape is enough.
local function ann(page) return { page = page, text = "h" .. tostring(page) } end


-- ----------------------------------------------------------------------------
-- 1) LIVE SESSION, FRESH BOOK: live list full, doc_settings empty.
--    The whole bug.  Must return the live list, not the empty doc_settings.
-- ----------------------------------------------------------------------------
do
    local live = { ann(1), ann(2), ann(3) }
    local ui = {
        doc_settings = make_doc_settings({}),   -- no "annotations" key (fresh book)
        annotation   = { annotations = live },  -- KOReader's in-memory list
        paging       = false,
    }

    local got = DocSettingsBridge._read_active_list(ui)
    h.assert_equal(got, live, "fresh book: returns the in-memory list (by reference)")
    h.assert_equal(#got, 3,   "fresh book: all 3 new annotations are seen")
end


-- ----------------------------------------------------------------------------
-- 2) LIVE SESSION, live list disagrees with a stale doc_settings copy.
--    The live list is authoritative and wins.
-- ----------------------------------------------------------------------------
do
    local live = { ann(7), ann(8) }
    local ui = {
        doc_settings = make_doc_settings({ annotations = { ann(99) } }),  -- stale
        annotation   = { annotations = live },
        paging       = false,
    }

    local got = DocSettingsBridge._read_active_list(ui)
    h.assert_equal(got, live, "live list wins over a stale doc_settings copy")
    h.assert_equal(#got, 2,   "returns the 2 live entries, not the stale 1")
end


-- ----------------------------------------------------------------------------
-- 3) LIVE SESSION, EMPTY live list: an empty live list is authoritative too.
--    A genuine empty device must NOT pick up a non-empty doc_settings copy —
--    that emptiness is what makes the fresh-device adopt a real (safe) adopt.
-- ----------------------------------------------------------------------------
do
    local live = {}
    local ui = {
        doc_settings = make_doc_settings({ annotations = { ann(5) } }),  -- must NOT win
        annotation   = { annotations = live },
        paging       = false,
    }

    local got = DocSettingsBridge._read_active_list(ui)
    h.assert_equal(got, live, "empty live list returned as-is")
    h.assert_equal(#got, 0,   "no annotations leak in from doc_settings")
end


-- ----------------------------------------------------------------------------
-- 4) BULK-INGEST: synthetic { doc_settings = ds }, NO .annotation module.
--    Must fall through to the doc_settings disk read (rolling key).  This is
--    the load-bearing guard that the fix does NOT break bulk-ingest.
-- ----------------------------------------------------------------------------
do
    local disk = { ann(1), ann(2) }
    local ui = { doc_settings = make_doc_settings({ annotations = disk }) }  -- no ui.annotation

    local got = DocSettingsBridge._read_active_list(ui)
    h.assert_equal(got, disk, "synthetic ui falls back to the doc_settings rolling key")
    h.assert_equal(#got, 2,   "bulk-ingest reads both disk annotations")
end


-- ----------------------------------------------------------------------------
-- 5) BULK-INGEST, PAGING book: synthetic ui, doc_settings under the paging key.
--    The rolling/paging fallback still finds them.
-- ----------------------------------------------------------------------------
do
    local disk = { ann(1) }
    local ui = { doc_settings = make_doc_settings({ annotations_paging = disk }),
                 paging = true }  -- no ui.annotation

    local got = DocSettingsBridge._read_active_list(ui)
    h.assert_equal(#got, 1, "paging synthetic ui reads the paging key via fallback")
end


-- ----------------------------------------------------------------------------
-- 6) Contract unchanged: no doc_settings -> nil.
-- ----------------------------------------------------------------------------
do
    h.assert_nil(DocSettingsBridge._read_active_list({}),  "no doc_settings -> nil")
    h.assert_nil(DocSettingsBridge._read_active_list(nil), "nil ui -> nil")
end


print("doc_settings_bridge_read_active_spec: all assertions passed")
