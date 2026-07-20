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

-- Prefetch-only carry-through: a book row with is_prefetch_only/book_id/
-- peer_path (syncery_ui/prefetch_locate.lua's inputs) must propagate onto
-- the resulting note, so AllNotesViewer:openBookAtNote can offer the
-- "locate the file" flow instead of the plain "Cannot find book path".
do
    local PREFETCH_BOOK = {
        title = "Never Opened Here", path = nil, filename = nil,
        is_prefetch_only = true, book_id = "SOME_BOOK_ID_00000000000000000",
        peer_path = "/peer/device/path/Book.epub",
    }
    local entry = { text = "x", pos0 = "/p[1].0", pos1 = "/p[1].10" }
    local n = ViewerSource.entry_to_note(entry, RANGE_KEY, PREFETCH_BOOK)

    h.assert_true(n.is_prefetch_only, "is_prefetch_only carried through")
    h.assert_equal(n.book_id, "SOME_BOOK_ID_00000000000000000", "book_id carried through")
    h.assert_equal(n.peer_path, "/peer/device/path/Book.epub", "peer_path carried through")
    h.assert_nil(n.book_path, "book_path stays nil for a prefetch-only row")
end

-- A normal (non-prefetch) book must NOT pick up these fields from nowhere.
do
    local n = ViewerSource.entry_to_note(
        { text = "x", pos0 = "/p[1].0", pos1 = "/p[1].10" }, RANGE_KEY, BOOK)
    h.assert_nil(n.is_prefetch_only, "ordinary book: is_prefetch_only stays nil")
    h.assert_nil(n.book_id, "ordinary book: book_id stays nil (not part of BOOK fixture)")
end

-- path_unresolved_here carry-through (symmetric with is_prefetch_only, but
-- a DIFFERENT situation -- book_enum.lua's Scan.scanHash step 3: the book
-- WAS opened, just not on this device): must propagate distinctly, so
-- openBookAtNote can offer its own, different explain text.
do
    local UNRESOLVED_BOOK = {
        title = "Opened Elsewhere", path = nil, filename = nil,
        path_unresolved_here = true, book_id = "OTHER_BOOK_ID_0000000000000",
        peer_path = "/peer/device/path/Other.epub",
    }
    local entry = { text = "x", pos0 = "/p[1].0", pos1 = "/p[1].10" }
    local n = ViewerSource.entry_to_note(entry, RANGE_KEY, UNRESOLVED_BOOK)

    h.assert_true(n.path_unresolved_here, "path_unresolved_here carried through")
    h.assert_nil(n.is_prefetch_only, "is_prefetch_only stays nil -- distinct situation")
    h.assert_equal(n.book_id, "OTHER_BOOK_ID_0000000000000", "book_id carried through")
    h.assert_equal(n.peer_path, "/peer/device/path/Other.epub", "peer_path carried through")
    h.assert_nil(n.book_path, "book_path stays nil for an unresolved-here row")
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


-- ---------------------------------------------------------------------------
-- _dedupe_by_text (display-level dedup for the cross-device re-stamped-
-- duplicate symptom -- see notes_for_book's own comment for the full
-- rationale: stage_pending_at_close deliberately strips device_id for a
-- byte-identical-file guarantee, and the "empty device_id = needs
-- stamping" heuristic elsewhere then re-stamps a delivered peer highlight
-- with THIS device's identity on a later read, which can end up with a
-- different pos0/pos1-derived key for what is visually the same
-- highlight).
-- ---------------------------------------------------------------------------

do
    local notes = {
        { chapter = "Ch1", highlighted_text = "Same highlight text",
          datetime = "2026-07-18 09:00:00", device_label = "a54xnaeea" },
        { chapter = "Ch1", highlighted_text = "Same highlight text",
          datetime = "2026-07-17 10:00:00", device_label = "Linux" },
    }
    local out = ViewerSource._dedupe_by_text(notes)
    h.assert_equal(#out, 1, "duplicate collapses to one entry")
    h.assert_equal(out[1].device_label, "Linux", "the OLDER (earlier datetime) entry survives")
end

do
    local notes = {
        { chapter = "Ch1", highlighted_text = "A repeated phrase", datetime = "2026-07-17 09:00:00" },
        { chapter = "Ch5", highlighted_text = "A repeated phrase", datetime = "2026-07-17 10:00:00" },
    }
    local out = ViewerSource._dedupe_by_text(notes)
    h.assert_equal(#out, 2, "different chapters -> both kept, not treated as duplicates")
end

do
    local notes = {
        { chapter = "Ch1", highlighted_text = "First highlight", datetime = "2026-07-17 09:00:00" },
        { chapter = "Ch1", highlighted_text = "Second highlight", datetime = "2026-07-17 10:00:00" },
    }
    local out = ViewerSource._dedupe_by_text(notes)
    h.assert_equal(#out, 2, "different text -> both kept")
end

do
    local notes = {
        { chapter = "Ch1", highlighted_text = nil, page = 5, datetime = "2026-07-17 09:00:00" },
        { chapter = "Ch1", highlighted_text = "", page = 5, datetime = "2026-07-17 10:00:00" },
    }
    local out = ViewerSource._dedupe_by_text(notes)
    h.assert_equal(#out, 2, "no-text entries (bookmarks) are always kept, never grouped")
end

do
    local notes = {
        { chapter = "Ch1", highlighted_text = "X", datetime = "2026-07-19 00:00:00", device_label = "third" },
        { chapter = "Ch1", highlighted_text = "X", datetime = "2026-07-17 00:00:00", device_label = "oldest" },
        { chapter = "Ch1", highlighted_text = "X", datetime = "2026-07-18 00:00:00", device_label = "middle" },
    }
    local out = ViewerSource._dedupe_by_text(notes)
    h.assert_equal(#out, 1, "three-way duplicate collapses to one")
    h.assert_equal(out[1].device_label, "oldest", "the genuinely oldest of three survives")
end

do
    local notes = {
        { chapter = "Ch1", highlighted_text = "Y", datetime = "", device_label = "first-seen" },
        { chapter = "Ch1", highlighted_text = "Y", datetime = "", device_label = "second-seen" },
    }
    local out = ViewerSource._dedupe_by_text(notes)
    h.assert_equal(#out, 1, "still collapses to one even with unknown ages")
    h.assert_equal(out[1].device_label, "first-seen",
        "unknown-age tie is stable: keeps the first one seen, not arbitrary reshuffling")
end

do
    local notes = {
        { chapter = "Ch1", highlighted_text = "Z", datetime = "", datetime_updated = "2026-07-18 00:00:00" },
        { chapter = "Ch1", highlighted_text = "Z", datetime = "", datetime_updated = "2026-07-17 00:00:00" },
    }
    local out = ViewerSource._dedupe_by_text(notes)
    h.assert_equal(#out, 1)
    h.assert_equal(out[1].datetime_updated, "2026-07-17 00:00:00",
        "falls back to datetime_updated for the age comparison when datetime is empty")
end

do
    h.assert_deep_equal(ViewerSource._dedupe_by_text({}), {}, "empty input -> empty output, no raise")
end


-- ---------------------------------------------------------------------------
-- Integration: notes_for_books (aggregate) applies the dedup, catching
-- the REAL on-device shape of the bug -- confirmed via the actual
-- canonical annotations.json content: it holds exactly ONE entry per
-- file. The duplication is TWO SEPARATE book-list rows for the same
-- book_id (e.g. a stale row from before the "locate" flow resolved
-- this book, alongside the fresh one after), each with its OWN
-- annotations_path, each correctly returning ONE note on its own --
-- notes_for_book alone cannot catch this (it only ever sees one book's
-- file); aggregating first, then deduping, does.
-- ---------------------------------------------------------------------------

do
    local ConflictResolver = require("syncery_ann/conflict_resolver")
    local saved_merged_view = ConflictResolver.merged_view
    local per_path_state = {
        ["/fake/stale.json"] = {
            annotations = {
                ["/body/DocFragment[7]/body/p[3]/text()[3].220||/body/DocFragment[7]/body/p[3]/text()[3].280"] = {
                    text = "There is a small, almost hidden beach in Macau",
                    chapter = "1. The Bigger Picture",
                    datetime = "2026-07-17 00:00:00", device_label = "Linux",
                    pos0 = "/body/DocFragment[7]/body/p[3]/text()[3].220",
                    pos1 = "/body/DocFragment[7]/body/p[3]/text()[3].280",
                },
            },
        },
        ["/fake/fresh.json"] = {
            annotations = {
                ["/body/DocFragment[7]/body/p[3]/text()[3].221||/body/DocFragment[7]/body/p[3]/text()[3].281"] = {
                    text = "There is a small, almost hidden beach in Macau",
                    chapter = "1. The Bigger Picture",
                    datetime = "2026-07-18 00:00:00", device_label = "a54xnaeea",
                    pos0 = "/body/DocFragment[7]/body/p[3]/text()[3].221",
                    pos1 = "/body/DocFragment[7]/body/p[3]/text()[3].281",
                },
            },
        },
    }
    ConflictResolver.merged_view = function(path)
        return per_path_state[path] or { annotations = {} }, 0
    end

    local books = {
        { title = "You and Your Profile", annotations_path = "/fake/stale.json" },
        { title = "You and Your Profile", annotations_path = "/fake/fresh.json" },
    }
    local notes = ViewerSource.notes_for_books(books)

    h.assert_equal(#notes, 1,
        "END-TO-END: two SEPARATE book rows for the same book_id, each with "
        .. "its own single-entry file, collapse to ONE displayed note when "
        .. "aggregated then deduped")
    h.assert_equal(notes[1].device_label, "Linux",
        "the older (original) entry is the one displayed")

    ConflictResolver.merged_view = saved_merged_view
end


h.teardown()
