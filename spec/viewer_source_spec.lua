-- =============================================================================
-- spec/viewer_source_spec.lua
-- =============================================================================
--
-- Tests for syncery_ui/annotation_viewer/viewer_source.lua -- the data adapter
-- that turns Syncery's SHARED annotation state into the note shape the lifted
-- annotationsviewer UI consumes, tagged with sync provenance.
--
-- The viewer is a READ-ONLY consumer of `load_shared`, so this is the whole
-- testable core; the UI on top is loadfile-only (requires KOReader widgets).
--
-- Covers:
--   * entry_to_note: field mapping (text->highlighted_text, note->user_note,
--     pageno->page), provenance passthrough, ann_type by KEY, sort stamp.
--   * notes_for_book: alive-only (tombstones excluded -- they're the Trash
--     Bin's job), graceful empty on no-path / malformed state.
--   * filter: book / device / type / case-insensitive text / others_only.
--   * sort_newest: newest-first by datetime_updated.
--   * devices_present: distinct devices, label fallback.
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_viewer_source_spec_" .. tostring(os.time()))

local ViewerSource  = require("syncery_ui/annotation_viewer/viewer_source")
local Identity      = require("syncery_ann/identity")
local AnnStateStore = require("syncery_ann/state_store")


-- Real keys so classify_type's parse_key path is exercised, not a fallback.
local RANGE_KEY    = Identity.compute_key({ pos0 = "/p[1].0", pos1 = "/p[1].10" })
local BOOKMARK_KEY = Identity.compute_key({ page = 5 })

local BOOK = { title = "Moby Dick", path = "/books/moby.epub", filename = "moby.epub" }


-- ---------------------------------------------------------------------------
-- entry_to_note -- field mapping + provenance + type
-- ---------------------------------------------------------------------------
do
    local entry = {
        text = "Call me Ishmael", note = "opening line", chapter = "Loomings",
        pageno = 3, pos0 = "/p[1].0", pos1 = "/p[1].10",
        datetime = "2026-01-01 10:00:00", datetime_updated = "2026-02-02 12:00:00",
        drawer = "lighten", color = "yellow",
        device_id = "devA", device_label = "My Kindle", deleted = false,
    }
    local n = ViewerSource.entry_to_note(entry, RANGE_KEY, BOOK)

    h.assert_equal(n.highlighted_text, "Call me Ishmael", "text -> highlighted_text")
    h.assert_equal(n.user_note, "opening line",          "note -> user_note")
    h.assert_equal(n.page, 3,                            "pageno -> page (legacy field)")
    h.assert_equal(n.chapter, "Loomings",                "chapter passthrough")
    h.assert_equal(n.book_title, "Moby Dick",            "book title from scan")
    h.assert_equal(n.book_path, "/books/moby.epub",      "book path from scan")
    h.assert_equal(n.device_label, "My Kindle",          "provenance label passthrough")
    h.assert_equal(n.device_id, "devA",                  "provenance id passthrough")
    h.assert_equal(n.datetime_updated, "2026-02-02 12:00:00", "sort stamp passthrough")
    h.assert_equal(n.ann_type, "note",                   "range entry WITH note -> note type")
    h.assert_equal(n._key, RANGE_KEY,                    "key carried for later use")
end

-- type classification by KEY: range WITHOUT note -> highlight; BOOKMARK -> bookmark
do
    local hl = ViewerSource.entry_to_note(
        { text = "just a highlight", pos0 = "/p[1].0", pos1 = "/p[1].10" }, RANGE_KEY, BOOK)
    h.assert_equal(hl.ann_type, "highlight", "range entry WITHOUT note -> highlight")

    local bm = ViewerSource.entry_to_note({ page = 5 }, BOOKMARK_KEY, BOOK)
    h.assert_equal(bm.ann_type, "bookmark", "BOOKMARK key -> bookmark")
end

-- page must be NUMERIC (the on-device go-to crash): KOReader stores a rolling
-- doc's `page` as an XPOINTER STRING; emit the numeric page, never the string,
-- or gotoNote's `page > 0` compares string-with-number and crashes.
do
    local XP = "/body/DocFragment[3]/body/div/p[7]/text().12"

    -- rolling doc: page is the xpointer string, pageno is the real number
    local rolling = ViewerSource.entry_to_note(
        { text = "x", page = XP, pageno = 42, pos0 = "/p[1].0", pos1 = "/p[1].5" },
        RANGE_KEY, BOOK)
    h.assert_equal(rolling.page, 42, "rolling: numeric pageno emitted, not the xpointer")
    h.assert_true(type(rolling.page) == "number", "rolling: page is a number")

    -- rolling doc with NO pageno: page must be nil, NEVER the xpointer string
    local no_pageno = ViewerSource.entry_to_note({ text = "x", page = XP }, RANGE_KEY, BOOK)
    h.assert_nil(no_pageno.page, "no pageno: page is nil, never the xpointer string")
    h.assert_true(type(no_pageno.page) ~= "string", "page is never a string (crash guard)")

    -- paged doc (PDF): page is already a number -> used directly
    local paged = ViewerSource.entry_to_note({ text = "x", page = 17 }, RANGE_KEY, BOOK)
    h.assert_equal(paged.page, 17, "paged: numeric page used directly")
end


-- ---------------------------------------------------------------------------
-- notes_for_book -- alive-only, graceful empties (stub load_shared)
-- ---------------------------------------------------------------------------
local _orig_load_shared = AnnStateStore.load_shared

do
    AnnStateStore.load_shared = function(_path)
        return {
            annotations = {
                [RANGE_KEY] = { text = "alive A", pos0 = "/p[1].0", pos1 = "/p[1].10",
                                device_id = "devA", device_label = "Kindle", deleted = false },
                ["/p[2].0||/p[2].5"] = { text = "alive B", device_id = "devB",
                                device_label = "Phone", deleted = false },
                ["/p[9].0||/p[9].9"] = { deleted = true, datetime_updated = "z",
                                device_id = "devA", device_label = "Kindle" },
            },
        }
    end

    local notes = ViewerSource.notes_for_book(BOOK)
    h.assert_equal(#notes, 2, "two alive entries returned, the tombstone excluded")

    -- confirm the tombstone is genuinely absent (no entry carries the deleted key)
    local saw_deleted = false
    for _, n in ipairs(notes) do
        if n._key == "/p[9].0||/p[9].9" then saw_deleted = true end
    end
    h.assert_false(saw_deleted, "deleted entry not surfaced by the alive viewer")
end

do
    -- no path -> empty, never nil
    local none = ViewerSource.notes_for_book({ title = "x", path = nil })
    h.assert_equal(#none, 0, "nil book path -> empty list")

    -- malformed state (no annotations table) -> empty
    AnnStateStore.load_shared = function(_) return { schema_version = 3 } end
    local empty = ViewerSource.notes_for_book(BOOK)
    h.assert_equal(#empty, 0, "state without annotations table -> empty list")
end

AnnStateStore.load_shared = _orig_load_shared


-- ---------------------------------------------------------------------------
-- filter -- each predicate independently
-- ---------------------------------------------------------------------------
local function sample()
    return {
        { book_path = "/a.epub", device_id = "devA", ann_type = "highlight",
          highlighted_text = "whales are mammals", user_note = "" },
        { book_path = "/a.epub", device_id = "devB", ann_type = "note",
          highlighted_text = "the sea", user_note = "REMEMBER this" },
        { book_path = "/b.epub", device_id = "devB", ann_type = "bookmark",
          highlighted_text = "", user_note = "" },
    }
end

do
    local by_book = ViewerSource.filter(sample(), { book = "/a.epub" })
    h.assert_equal(#by_book, 2, "book filter keeps only /a.epub")

    local by_device = ViewerSource.filter(sample(), { device = "devB" })
    h.assert_equal(#by_device, 2, "device filter keeps only devB")

    local by_type = ViewerSource.filter(sample(), { type = "bookmark" })
    h.assert_equal(#by_type, 1, "type filter keeps only bookmarks")
    h.assert_equal(by_type[1].book_path, "/b.epub", "the bookmark is the /b.epub one")
end

do
    -- text: case-insensitive, matches highlight OR note
    local hit_hl = ViewerSource.filter(sample(), { text = "WHALES" })
    h.assert_equal(#hit_hl, 1, "text match in highlighted_text, case-insensitive")

    local hit_note = ViewerSource.filter(sample(), { text = "remember" })
    h.assert_equal(#hit_note, 1, "text match in user_note, case-insensitive")

    local miss = ViewerSource.filter(sample(), { text = "zzzzz" })
    h.assert_equal(#miss, 0, "no text match -> empty")
end

do
    -- others_only: exclude this device
    local others = ViewerSource.filter(sample(),
        { others_only = true, this_device_id = "devA" })
    h.assert_equal(#others, 2, "others_only drops this device's (devA) notes")
    for _, n in ipairs(others) do
        h.assert_true(n.device_id ~= "devA", "no devA note survives others_only")
    end

    -- others_only WITHOUT this_device_id is a no-op (can't know "this")
    local noop = ViewerSource.filter(sample(),
        { others_only = true })
    h.assert_equal(#noop, 3, "others_only with no this_device_id is a no-op (keeps all)")
end


-- ---------------------------------------------------------------------------
-- sort_newest
-- ---------------------------------------------------------------------------
do
    local list = {
        { datetime_updated = "2026-01-01 00:00:00", _key = "old" },
        { datetime_updated = "2026-03-03 00:00:00", _key = "new" },
        { datetime_updated = "2026-02-02 00:00:00", _key = "mid" },
    }
    ViewerSource.sort_newest(list)
    h.assert_equal(list[1]._key, "new", "newest first")
    h.assert_equal(list[2]._key, "mid", "middle second")
    h.assert_equal(list[3]._key, "old", "oldest last")
end


-- ---------------------------------------------------------------------------
-- devices_present
-- ---------------------------------------------------------------------------
do
    local list = {
        { device_id = "devB", device_label = "Phone" },
        { device_id = "devA", device_label = "Kindle" },
        { device_id = "devB", device_label = "Phone" },   -- dup
        { device_id = nil,    device_label = nil      },   -- unknown
    }
    local devs = ViewerSource.devices_present(list)
    h.assert_equal(#devs, 3, "three distinct devices (Phone, Kindle, unknown)")
    -- sorted by label: "Kindle" < "Phone" < "unknown device"
    h.assert_equal(devs[1].label, "Kindle",         "sorted by label: Kindle first")
    h.assert_equal(devs[3].label, "unknown device", "nil label -> 'unknown device' last")
end


h.teardown()
