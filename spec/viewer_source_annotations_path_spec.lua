-- =============================================================================
-- spec/viewer_source_annotations_path_spec.lua
-- =============================================================================
--
-- notes_for_book must read each book's annotations from the EXACT shared file
-- the scan found (book.annotations_path), not by re-deriving a sidecar path
-- from book.path.  The re-derivation (shared_annotations_path_for_read ->
-- getSidecarDir) misses books stored in a different KOReader metadata mode, or
-- recorded with a foreign-device / extension-less path -- exactly the
-- book-folder-mode books the booklist shows but the browser was dropping.
--
-- The annotations_path read is CONFLICT-AWARE: it routes through
-- ConflictResolver.merged_view(annotations_path), which folds any Syncthing
-- `.sync-conflict-*` copies of that file into a READ-ONLY merged view (newest
-- of each annotation) AND reports how many it folded.  notes_for_book stamps
-- that count onto each emitted note as `book_has_conflict` so the browser can
-- flag a book whose annotations were reconciled from a sync conflict.  A book
-- WITHOUT a scanned annotations_path (the open-book case) falls back to
-- load_shared(book.path) and is never flagged.
--
-- Proven by dispatch: stub the readers with distinguishable outputs and assert
-- which one each book shape routes to, that merged_view receives the scanned
-- annotations_path verbatim, that its conflict count drives book_has_conflict,
-- and that a merged_view failure degrades to the plain load_shared_from_path
-- read (the pcall guard) rather than crashing the whole all-books enumeration.
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_viewer_source_annpath_spec_" .. tostring(os.time()))

-- annotation_viewer/* is NOT in the runner's between-spec module clear list, so
-- a prior load of viewer_source may hold stale AnnStateStore / ConflictResolver
-- references.  Force viewer_source to re-bind THESE (freshly cleared) modules
-- so the stubs below actually intercept its calls.  conflict_resolver is
-- required before viewer_source so viewer_source binds this same instance.
package.loaded["syncery_ui/annotation_viewer/viewer_source"] = nil
local AnnStateStore    = require("syncery_ann/state_store")
local ConflictResolver = require("syncery_ann/conflict_resolver")
local ViewerSource     = require("syncery_ui/annotation_viewer/viewer_source")
local Identity         = require("syncery_ann/identity")

local RANGE_KEY = Identity.compute_key({ pos0 = "/p[1].0", pos1 = "/p[1].10" })

local function state_with(marker)
    return { schema_version = 3, annotations = {
        [RANGE_KEY] = {
            text = marker, pos0 = "/p[1].0", pos1 = "/p[1].10",
            datetime = "2026-01-01 00:00:00", datetime_updated = "2026-01-01 00:00:00",
        },
    } }
end

local orig_ls     = AnnStateStore.load_shared
local orig_lsfp   = AnnStateStore.load_shared_from_path
local orig_merged = ConflictResolver.merged_view

local seen_merged_arg = nil
local seen_lsfp_arg   = nil
-- merged_view returns (state, conflict_count); default stub reports 2 copies.
local function merged_stub(conflict_count)
    return function(file_path)
        seen_merged_arg = file_path
        return state_with("FROM_MERGED"), conflict_count
    end
end
AnnStateStore.load_shared           = function(_book_path) return state_with("FROM_DERIVE") end
AnnStateStore.load_shared_from_path = function(file_path)
    seen_lsfp_arg = file_path
    return state_with("FROM_PATH")
end
ConflictResolver.merged_view = merged_stub(2)


-- ---------------------------------------------------------------------------
-- a book carrying annotations_path is read CONFLICT-AWARE from THAT file
-- (merged_view), not re-derived from book.path; a reported conflict count
-- raises book_has_conflict (the book-level marker)
-- ---------------------------------------------------------------------------
do
    -- book.path is deliberately a path the re-derivation would resolve wrongly
    -- (foreign-device + extension-less); the scanned annotations_path is right.
    local notes = ViewerSource.notes_for_book({
        title = "T", filename = "x.epub",
        path = "/foreign-device/and-extension-less/book",
        annotations_path = "/real/scanned/book.epub.syncery-annotations.json",
    })
    h.assert_equal(#notes, 1, "one alive note returned")
    h.assert_equal(notes[1] and notes[1].highlighted_text, "FROM_MERGED",
        "read via ConflictResolver.merged_view (conflict-aware), NOT re-derived from book.path")
    h.assert_equal(seen_merged_arg, "/real/scanned/book.epub.syncery-annotations.json",
        "merged_view got the scanned annotations_path verbatim")
    h.assert_true(notes[1] and notes[1].book_has_conflict == true,
        "merged_view reporting conflict copies -> book_has_conflict true (book-level marker)")
end

-- ---------------------------------------------------------------------------
-- zero conflict copies -> book_has_conflict false (no marker)
-- ---------------------------------------------------------------------------
do
    ConflictResolver.merged_view = merged_stub(0)
    local notes = ViewerSource.notes_for_book({
        title = "T", filename = "x.epub", path = "/some/book",
        annotations_path = "/real/scanned/book.epub.syncery-annotations.json",
    })
    h.assert_true(notes[1] and notes[1].book_has_conflict == false,
        "merged_view reporting 0 conflict copies -> book_has_conflict false")
    ConflictResolver.merged_view = merged_stub(2)
end

-- ---------------------------------------------------------------------------
-- merged_view failure degrades to the plain load_shared_from_path read
-- (the pcall guard) -- one corrupt conflict copy must not crash the whole
-- all-books enumeration; the degraded read is not flagged
-- ---------------------------------------------------------------------------
do
    seen_lsfp_arg = nil
    ConflictResolver.merged_view = function(_) error("boom: corrupt conflict copy") end

    local notes = ViewerSource.notes_for_book({
        title = "T", filename = "x.epub", path = "/some/book",
        annotations_path = "/real/scanned/book.epub.syncery-annotations.json",
    })
    h.assert_equal(#notes, 1, "fallback still returns the canonical note")
    h.assert_equal(notes[1] and notes[1].highlighted_text, "FROM_PATH",
        "merged_view error -> load_shared_from_path fallback")
    h.assert_equal(seen_lsfp_arg, "/real/scanned/book.epub.syncery-annotations.json",
        "fallback passed the scanned annotations_path verbatim")
    h.assert_true(notes[1] and notes[1].book_has_conflict == false,
        "degraded read (merged_view failed) is not flagged -- conflict state unknown")

    ConflictResolver.merged_view = merged_stub(2)
end

-- ---------------------------------------------------------------------------
-- no scanned file (open-book case) -> fall back to deriving from book.path;
-- never flagged (that book resolves its own conflicts on its next sync)
-- ---------------------------------------------------------------------------
do
    local fb = ViewerSource.notes_for_book({
        title = "T", filename = "open.epub", path = "/open/open.epub",
    })
    h.assert_equal(#fb, 1, "fallback returns notes")
    h.assert_equal(fb[1] and fb[1].highlighted_text, "FROM_DERIVE",
        "no annotations_path -> load_shared(book.path)")
    h.assert_true(fb[1] and fb[1].book_has_conflict == false,
        "open-book read is never flagged")
end

AnnStateStore.load_shared           = orig_ls
AnnStateStore.load_shared_from_path = orig_lsfp
ConflictResolver.merged_view        = orig_merged

-- viewer_source isn't cleared between specs by the runner; drop it so the next
-- spec re-binds fresh modules.  Otherwise viewer_source keeps the instances
-- bound here, the runner clears state_store/conflict_resolver, and a later
-- spec's stubs can no longer intercept viewer_source's calls.
package.loaded["syncery_ui/annotation_viewer/viewer_source"] = nil

h.teardown()
