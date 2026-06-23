-- =============================================================================
-- syncery_ui/annotation_viewer/viewer_source.lua
-- =============================================================================
--
-- Data adapter for the sync-aware annotation viewer.
--
-- This is the SYNC-AWARE swap.  The viewer UI is lifted/adapted from the
-- third-party `annotationsviewer` plugin (AGPL-3.0, same licence as Syncery
-- and KOReader -- see docs/ANNOTATION_VIEWER_DESIGN.md for attribution), whose
-- list/detail widgets consume a fixed "note" shape.  annotationsviewer sources
-- those notes from each book's LOCAL `.sdr` sidecar; we source them from
-- Syncery's SHARED `syncery-annotations.json` (via `AnnStateStore.load_shared`)
-- so every note carries:
--
--   * `device_label` / `device_id` -- provenance ("from which device"), the
--     thing a local-only viewer structurally cannot show;
--   * the all-devices view -- the shared file holds entries from every device;
--   * `ann_type` -- highlight / note / bookmark, by KEY (survives tombstone
--     compaction).
--
-- Tombstones (deleted entries) are filtered OUT here -- they belong to the
-- Trash Bin, which is the MIRROR of this module over the same file
-- (`Store.list_deleted` keeps `deleted`, we keep `not deleted`).
--
-- This module is PURE (no UI, no global state, no filesystem walk of its own:
-- the book list is injected by the UI layer, which reuses the booklist scan).
-- That keeps it fully unit-testable headless.
-- =============================================================================

local AnnStateStore = require("syncery_ann/state_store")
local Merge         = require("syncery_ann/merge")
local ConflictResolver = require("syncery_ann/conflict_resolver")

local ViewerSource = {}

-- ---------------------------------------------------------------------------
-- entry_to_note -- map one ALIVE shared-state entry to the UI note shape.
--
--   entry : the position-keyed shared annotation (a copy of the native
--           KOReader annotation + Syncery bookkeeping fields).
--   key   : the position key (authoritative for type classification).
--   book  : { title = <display title>, path = <book file>,
--             filename = <basename> } from the booklist scan.
--
-- The output keys match exactly what the lifted annotationsviewer widgets
-- read (`highlighted_text`, `user_note`, `book_title`, ...), PLUS the
-- sync-aware fields.  `book_authors` / `tags` are absent from the shared file
-- and left nil; the UI already guards nil for both.
-- ---------------------------------------------------------------------------
function ViewerSource.entry_to_note(entry, key, book)
    book = book or {}
    return {
        -- book-level (from the scan)
        book_title    = book.title,
        book_path     = book.path,
        book_filename = book.filename,
        book_authors  = nil,
        -- native content (annotationsviewer shape)
        -- `page` must be a NUMBER for go-to (GotoPage).  KOReader stores an
        -- annotation's `page` as an XPOINTER STRING for rolling docs -- the
        -- numeric page lives in `pageno`.  Never emit the xpointer string here,
        -- or a downstream `page > 0` compares string-with-number (an on-device
        -- crash, hit on bookmarks: their pos0 is nil, so gotoNote cannot
        -- re-resolve the page from the xpointer).
        page             = (type(entry.pageno) == "number" and entry.pageno)
                            or (type(entry.page) == "number" and entry.page)
                            or nil,
        chapter          = entry.chapter,
        pos0             = entry.pos0,
        pos1             = entry.pos1,
        highlighted_text = entry.text,
        user_note        = entry.note,
        datetime         = entry.datetime,
        drawer           = entry.drawer,
        color            = entry.color,
        tags             = nil,
        -- sort key (the shared file's last-change stamp; falls back to
        -- creation `datetime` when an entry predates the field)
        datetime_updated = entry.datetime_updated,
        -- sync-aware
        device_id    = entry.device_id,
        device_label = entry.device_label,
        ann_type     = Merge.classify_type(key, entry),
        _key         = key,
    }
end

-- ---------------------------------------------------------------------------
-- notes_for_book -- all ALIVE notes for one book, from its shared file.
--
-- Returns {} (never nil) on any failure (no path, unreadable, malformed),
-- so the caller can always `ipairs` the result.  Reading is side-effect-free.
-- ---------------------------------------------------------------------------
function ViewerSource.notes_for_book(book)
    local out = {}
    if not book then return out end

    -- Prefer the exact shared file the scan found (book.annotations_path):
    -- re-deriving the sidecar path from book.path misses books stored in a
    -- different KOReader metadata mode, or recorded with a foreign-device /
    -- extension-less path.  Fall back to deriving from book.path for callers
    -- with no scanned file -- showCurrentBookNotes builds the book from the
    -- open document, whose canonical sidecar in the current mode exists.
    local state
    local conflict_count = 0
    if book.annotations_path then
        -- Conflict-aware read: fold any Syncthing `.sync-conflict-*` copies of
        -- this book's annotations into a READ-ONLY merged view (newest of each
        -- annotation), so the browser surfaces annotations a sync conflict split
        -- off into a sibling file.  pcall + canonical fallback: merged_view runs
        -- for EVERY book in the all-books view, so one corrupt conflict copy
        -- must not abort the whole enumeration — degrade to the plain read.
        -- merged_view also reports how many conflict copies it folded, used
        -- below to flag the book.
        local ok, merged, n = pcall(ConflictResolver.merged_view, book.annotations_path)
        if ok then
            state, conflict_count = merged, (n or 0)
        else
            state = AnnStateStore.load_shared_from_path(book.annotations_path)
        end
    elseif book.path then
        state = AnnStateStore.load_shared(book.path)
    else
        return out
    end
    if not state or type(state.annotations) ~= "table" then
        return out
    end

    -- Book-level marker: when this book's annotations were reconciled from a
    -- Syncthing sync conflict, tag every emitted note so the browser can flag
    -- the book.  The open-book path leaves this false (conflict_count stays 0):
    -- that book resolves its own conflicts on its next sync.
    local book_has_conflict = conflict_count > 0
    for key, entry in pairs(state.annotations) do
        if entry and not entry.deleted then
            local note = ViewerSource.entry_to_note(entry, key, book)
            note.book_has_conflict = book_has_conflict
            -- Carry the EXACT file merged_view read, so the browser's "Resolve
            -- conflict" action resolves that file (path-based, cross-mode
            -- correct).  nil in the open-book branch, where the button is gated
            -- off (book_has_conflict is false there).
            note.annotations_path = book.annotations_path
            table.insert(out, note)
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- notes_for_books -- aggregate alive notes across a list of books.
--
-- `books` is the list produced by the booklist scan at the UI layer (each
-- { title, path, filename }); injected here so the model stays testable
-- without a real filesystem walk.  The UI layer owns the cancellable scan
-- (booklist `make_cancellable_walk`) and de-dup (identity from
-- JSON content, not `.sdr` location) BEFORE calling this.
-- ---------------------------------------------------------------------------
function ViewerSource.notes_for_books(books)
    local out = {}
    for _, book in ipairs(books or {}) do
        local notes = ViewerSource.notes_for_book(book)
        for _, n in ipairs(notes) do
            table.insert(out, n)
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- filter -- apply the basic (lean) filter.
--
-- opts:
--   book           -- keep only this book_path
--   device         -- keep only this device_id
--   type           -- keep only this ann_type ("highlight"/"note"/"bookmark")
--   text           -- case-insensitive substring over highlight + note
--   others_only    -- keep only notes NOT from `this_device_id`
--   this_device_id -- this device's id (injected; required for others_only)
--
-- Predicates are independent (AND); a nil opt is ignored.  Returns a NEW
-- list; the input is not mutated.
-- ---------------------------------------------------------------------------
function ViewerSource.filter(notes, opts)
    opts = opts or {}
    local out = {}
    for _, n in ipairs(notes or {}) do
        local ok = true
        if ok and opts.book   and n.book_path ~= opts.book   then ok = false end
        if ok and opts.device and n.device_id ~= opts.device then ok = false end
        if ok and opts.type   and n.ann_type  ~= opts.type   then ok = false end
        if ok and opts.others_only and opts.this_device_id
           and n.device_id == opts.this_device_id then
            ok = false
        end
        if ok and opts.text and opts.text ~= "" then
            local hay = ((n.highlighted_text or "") .. " "
                         .. (n.user_note or "")):lower()
            if not hay:find(opts.text:lower(), 1, true) then ok = false end
        end
        if ok then table.insert(out, n) end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- sort_newest -- newest-first by datetime_updated (fallback datetime).
-- Sorts in place and returns the list.  String compare matches the ISO-ish
-- timestamp format the engine stamps (lexicographic == chronological).
-- ---------------------------------------------------------------------------
function ViewerSource.sort_newest(notes)
    table.sort(notes, function(a, b)
        local ka = a.datetime_updated or a.datetime or ""
        local kb = b.datetime_updated or b.datetime or ""
        return ka > kb
    end)
    return notes
end

-- ---------------------------------------------------------------------------
-- devices_present -- the distinct device list across notes, for the filter
-- picker.  Returns an array of { id, label }, label falling back to the id
-- (or "unknown device" when both are absent).  Deterministic order (by label).
-- ---------------------------------------------------------------------------
function ViewerSource.devices_present(notes)
    local seen, out = {}, {}
    for _, n in ipairs(notes or {}) do
        local id = n.device_id or "__unknown__"
        if not seen[id] then
            seen[id] = true
            table.insert(out, {
                id    = n.device_id,
                label = n.device_label or n.device_id or "unknown device",
            })
        end
    end
    table.sort(out, function(a, b) return (a.label or "") < (b.label or "") end)
    return out
end

return ViewerSource
