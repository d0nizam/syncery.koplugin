-- =============================================================================
-- spec/diagnostic_snapshot_spec.lua
-- =============================================================================
--
-- Tests for syncery_ui/diagnostic_snapshot.lua -- the PURE snapshot formatter.
--
-- It is pure (no widget requires, no os.time/os.date), so the whole thing is
-- exercised by feeding `data` tables and asserting on the produced text.
--
-- Coverage:
--   * header carries version + the pre-formatted date
--   * the Faults line: positive confirmation when empty, the list with the
--     warning glyph when non-empty (the Phase-2-ready render path)
--   * redaction: device/book ids truncated, book paths reduced to basename,
--     full forms never emitted
--   * the NEUTRAL-FACT rule: an off toggle / an excluded book are reported as
--     plain facts and NEVER raise the warning glyph (the rule that separates
--     configuration from breakage)
--   * essentials is a strict triage subset of full
--   * THIS BOOK is omitted when no book is open
--   * journal outcome counts + the not-OK reason surfacing
--   * empty journal / empty activity are handled
--
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_diag_snapshot_spec_" .. tostring(os.time()))

local DS = require("syncery_ui.diagnostic_snapshot")

-- ⚠ and ✓ as byte sequences, matching the module's escapes.
local WARN = "\xE2\x9A\xA0"
local OK   = "\xE2\x9C\x93"

-- plain substring (for glyphs, ids, unique phrases)
local function has(text, sub) return text:find(sub, 1, true) ~= nil end
-- pattern match (for "Label<spaces>value" -- tolerant of the column width)
local function matches(text, pat) return text:find(pat) ~= nil end


-- A representative, healthy data table.  Each test starts from a fresh copy
-- and mutates only what it is about.
local function sample()
    return {
        meta = {
            plugin_version   = "4.7.0",
            koreader_version = "v2025.04",
            platform         = "Kobo",
            device_label     = "Clara",
            device_id        = "abcdef1234567890",
            date_str         = "2026-06-12 14:30",
        },
        storage = { mode = "sdr", root = "/mnt/onboard/.adds/koreader/syncery" },
        toggles = {
            progress = true, annotations = true,
            highlights = true, notes = true, bookmarks = true,
            metadata = true, status = true, rating = true, collections = true,
            custom_metadata = false, handmade_toc = false,
            render = false, tombstone_ttl_days = 30,
            conflict_strategy = "sidecar-ignore (SDR)",
        },
        transports = {
            syncthing = { name = "Syncthing", enabled = true, available = true,
                          summary = "up to date", pending_retry = false },
            cloud     = { name = "Cloud", enabled = false, available = false,
                          summary = "not configured" },
        },
        this_book = {
            file = "/mnt/onboard/Books/Dune.epub", id = "deadbeefcafe0001",
            excluded = false, annotations = 12, percent = 0.42,
            shared_record = true, last_merge = "merged",
        },
        journal = {
            { outcome = "merged",  book_id = "aaaa1111" },
            { outcome = "noop",    book_id = "bbbb2222" },
            { outcome = "skipped", book_id = "cccc3333", skipped_reason = "would wipe remote",
              trigger = "remote_check" },
            { outcome = "failed",  book_id = "dddd4444", error = "save_shared_failed",
              trigger = "save" },
            { outcome = "merged",  book_id = "eeee5555", trigger = "close",
              annotations_pulled = 3, annotations_pushed = 1,
              metadata_changed = 2,
              annotations_before = 8, annotations_after = 12 },
        },
        activity = {
            { when = "14:29:00", kind = "Rescan all", detail = "quick_sync" },
            { when = "14:28:00", kind = "Resolved progress conflicts", detail = "" },
        },
        integrity = {
            store_exists = true, store_decode_ok = true,
            conflict_count = 0, tombstone_count = 3,
            metadata_tombstone_count = 2,
            stignore_applicable = true, stignore_present = true,
        },
    }
end


-- ---- header + faults (healthy: no warning anywhere) ----
do
    local r = DS.build(sample())
    h.assert_true(has(r.full, "Syncery 4.7.0"), "header carries the plugin version")
    h.assert_true(has(r.full, "2026-06-12 14:30"), "header carries the pre-formatted date")
    h.assert_true(has(r.full, "Faults: " .. OK .. " none detected"),
        "an empty fault set renders the positive confirmation")
    h.assert_false(has(r.full, WARN), "no warning glyph anywhere in a healthy snapshot")
end

-- ---- faults are DERIVED from integrity: a confirmed-corrupt store raises it ----
do
    local d = sample()
    d.integrity.store_exists    = true
    d.integrity.store_decode_ok = false        -- confirmed corrupt
    local r = DS.build(d)
    h.assert_true(has(r.full, WARN), "a confirmed fault shows the warning glyph")
    h.assert_true(has(r.full, "unreadable"), "the corrupt-store fault is described")
    h.assert_false(has(r.full, "none detected"),
        "the positive confirmation is gone once a fault exists")
    h.assert_true(#r.faults >= 1, "build returns the derived fault list")
end

-- ---- redaction ----
do
    local r = DS.build(sample())
    h.assert_true(has(r.full, "abcdef1"), "device id shown truncated to 7 chars")
    h.assert_false(has(r.full, "abcdef1234567890"), "full device id is never emitted")
    h.assert_true(has(r.full, "Dune.epub"), "book shown by basename")
    h.assert_false(has(r.full, "/mnt/onboard/Books/Dune.epub"), "full book path is never emitted")
    h.assert_true(has(r.full, "deadbee"), "book id shown truncated")
    h.assert_false(has(r.full, "deadbeefcafe0001"), "full book id is never emitted")
end

-- ---- NEUTRAL FACTS: configuration is reported WITHOUT a warning ----
do
    local d = sample()
    d.toggles.annotations = false      -- a deliberate user choice
    d.this_book.excluded  = true       -- another deliberate choice
    local r = DS.build(d)
    h.assert_true(matches(r.full, "Annotations%s+off"),
        "an off toggle is reported as a plain fact")
    h.assert_true(matches(r.full, "Excluded%s+yes"),
        "an excluded book is reported as a plain fact")
    h.assert_false(has(r.full, WARN),
        "configuration choices never raise the warning glyph")
end

-- ---- annotations row: master on lists the active sub-types ----
do
    local r = DS.build(sample())          -- master + all three subs on
    h.assert_true(matches(r.full, "Annotations%s+on %(highlights, notes, bookmarks%)"),
        "master on lists the enabled sub-types")
    -- Bookmarks is one of the sub-types, NOT a standalone WHAT'S SYNCED row.
    h.assert_false(matches(r.full, "Bookmarks%s+on"),
        "no standalone Bookmarks row (folded into the annotations sub-types)")
end

-- ---- annotations row: master on but every sub off -> effectively off ----
do
    local d = sample()
    d.toggles.highlights = false
    d.toggles.notes      = false
    d.toggles.bookmarks  = false          -- master on, but _annotations_enabled is false
    local r = DS.build(d)
    h.assert_true(matches(r.full, "Annotations%s+off %(no types%)"),
        "master on with no sub-types reports 'off (no types)', not a misleading 'on'")
    h.assert_false(has(r.full, WARN),
        "the no-types state is a neutral fact, not a fault")
end

-- ---- annotations row: a subset of sub-types ----
do
    local d = sample()
    d.toggles.notes = false               -- highlights + bookmarks remain
    local r = DS.build(d)
    h.assert_true(matches(r.full, "Annotations%s+on %(highlights, bookmarks%)"),
        "only the enabled sub-types are listed (notes omitted)")
end

-- ---- essentials is a strict triage subset of full ----
do
    local r = DS.build(sample())
    h.assert_true(has(r.essentials, "Syncery 4.7.0"), "essentials has the header")
    h.assert_true(has(r.essentials, "SYSTEM"), "essentials has SYSTEM")
    h.assert_true(has(r.essentials, "TRANSPORTS"), "essentials has TRANSPORTS")
    h.assert_true(has(r.essentials, "Faults:"), "essentials has the Faults line")
    h.assert_false(has(r.essentials, "RECENT SYNCS"), "essentials omits the merge detail")
    h.assert_false(has(r.essentials, "THIS BOOK"), "essentials omits the per-book block")
    -- everything essentials shows, full also shows; full additionally has detail
    h.assert_true(has(r.full, "SYSTEM") and has(r.full, "TRANSPORTS"),
        "full is a superset of essentials' core")
    h.assert_true(has(r.full, "RECENT SYNCS"), "full carries the merge detail")
end

-- ---- THIS BOOK omitted when no book is open ----
do
    local d = sample()
    d.this_book = nil
    local r = DS.build(d)
    h.assert_false(has(r.full, "THIS BOOK"), "no per-book block when no book is open")
    h.assert_true(has(r.full, "SYSTEM"), "the rest of the snapshot is unaffected")
    h.assert_true(has(r.full, "TRANSPORTS"), "transports still present")
end

-- ---- journal: outcome counts + the not-OK reason + enriched detail ----
do
    local r = DS.build(sample())
    h.assert_true(has(r.full, "2 merged"),  "merged count surfaced")
    h.assert_true(has(r.full, "1 noop"),    "noop count surfaced")
    h.assert_true(has(r.full, "1 skipped"), "skipped count surfaced")
    h.assert_true(has(r.full, "1 failed"),  "failed count surfaced")
    h.assert_true(has(r.full, "would wipe remote"), "the skipped reason is surfaced")
    h.assert_true(has(r.full, "cccc333"), "the skipped book id (truncated) is shown")
    h.assert_false(has(r.full, "aaaa1111"), "merged/noop ids are not in the not-OK list")
    -- Enriched RECENT SYNCS: the newest entry in full + failed reason + trigger.
    h.assert_true(has(r.full, "latest:"), "the newest entry's detail line is shown")
    h.assert_true(has(r.full, "[annotation]"),
        "the latest line carries the kind tag (defaulted: the fixture entry has no kind)")
    h.assert_true(has(r.full, "via close"), "the latest entry's trigger is surfaced")
    h.assert_true(has(r.full, "pulled 3 / pushed 1"), "the latest entry's pull/push direction is shown")
    h.assert_true(has(r.full, "2 metadata"), "the latest entry's metadata-change count is shown")
    h.assert_true(has(r.full, "8->12 alive"), "the latest entry's alive before->after is shown")
    h.assert_true(has(r.full, "save_shared_failed"),
        "a FAILED entry surfaces its error reason (failed carries error, not skipped_reason)")
    h.assert_true(has(r.full, "[save]"), "the failed entry's trigger is shown on its line")
end


-- ---- RECENT SYNCS v3 display: injected time + truncated book id + clean noop ----
do
    local d = sample()
    d.journal = {
        { outcome = "noop", book_id = "facefeed0000", trigger = "suspend",
          timestamp = 1781944701 },
    }
    d.format_ts = function(ts) return "T:" .. tostring(ts) end
    local r = DS.build(d)
    h.assert_true(has(r.full, "facefee"),
        "the latest line shows the truncated (7-char) book id")
    h.assert_true(has(r.full, "T:1781944701"),
        "the injected format_ts renders the journal epoch on the latest line")
    h.assert_false(has(r.full, "pulled 0"),
        "a noop latest line omits the zero pull/push detail")
end

-- ---- transports + activity surfaced ----
do
    local r = DS.build(sample())
    h.assert_true(has(r.full, "Syncthing"), "syncthing transport listed")
    h.assert_true(has(r.full, "up to date"), "transport summary surfaced")
    h.assert_true(has(r.full, "Cloud"), "cloud transport listed")
    h.assert_true(has(r.full, "Rescan all"), "activity kind surfaced")
    h.assert_true(has(r.full, "14:29:00"), "activity timestamp surfaced")
end

-- ---- metadata sub-toggles listed only when metadata is on ----
do
    local r = DS.build(sample())
    h.assert_true(has(r.full, "status, rating, collections"),
        "metadata sub-toggles listed when the master is on")

    local d = sample(); d.toggles.metadata = false
    local r2 = DS.build(d)
    h.assert_true(matches(r2.full, "Metadata%s+off"), "metadata off shown plainly")
    h.assert_false(has(r2.full, "status, rating"), "no sub-list when metadata is off")
end

-- ---- empty journal / empty activity handled ----
do
    local d = sample()
    d.journal = {}
    d.activity = {}
    local r = DS.build(d)
    h.assert_true(has(r.full, "no syncs recorded"), "empty journal handled")
    h.assert_true(has(r.full, "(none)"), "empty activity handled")
end

-- ---- RECENT SYNCS: a jump is counted in the summary and the latest line
--      shows the ADOPTED device (winning_device_label), not a trigger ----
do
    local d = sample()
    d.journal = {
        { outcome = "merged", book_id = "aaaa1111" },
        { outcome = "jumped", book_id = "bbbb2222", kind = "progress",
          winning_device_label = "My Phone" },
    }
    local r = DS.build(d)
    h.assert_true(has(r.full, "1 jumped"), "a jumped entry is counted in the summary")
    h.assert_true(has(r.full, "jumped via My Phone"),
        "the latest jump shows the adopted device")
end

-- ---- RECENT SYNCS: a non-zero outcome shows; a zero one is omitted ----
do
    local d = sample()
    d.journal = {
        { outcome = "merged", book_id = "aaaa1111" },
        { outcome = "merged", book_id = "bbbb2222" },
    }
    local r = DS.build(d)
    h.assert_true(has(r.full, "2 merged"), "the only non-zero outcome is shown")
    h.assert_false(has(r.full, "0 noop"), "a zero outcome is omitted, not shown as 0")
    h.assert_false(has(r.full, "0 jumped"), "a zero jumped is omitted")
end

-- ---- RECENT SYNCS: a status resolution shows what won (from -> to) ----
do
    local d = sample()
    d.journal = {
        { outcome = "merged", book_id = "cccc3333", kind = "status",
          status_from = "abandoned-vs-complete", status_to = "complete" },
    }
    local r = DS.build(d)
    h.assert_true(has(r.full, "[status]"), "the status entry carries its kind tag")
    h.assert_true(has(r.full, "abandoned-vs-complete -> complete"),
        "the status latest line shows from -> to")
end

-- ---- RECENT SYNCS: a bulk backfill shows the ingested count ----
do
    local d = sample()
    d.journal = {
        { outcome = "merged", book_id = "dddd4444", kind = "bulk", ingested = 12 },
    }
    local r = DS.build(d)
    h.assert_true(has(r.full, "[bulk]"), "the bulk entry carries its kind tag")
    h.assert_true(has(r.full, "12 ingested"), "the bulk latest line shows the ingested count")
end

-- ---- RECENT SYNCS: a progress push shows its pushed revision ----
do
    local d = sample()
    d.journal = {
        { outcome = "merged", book_id = "eeee5555", kind = "progress",
          trigger = "manual", revision = 7 },
    }
    local r = DS.build(d)
    h.assert_true(has(r.full, "rev 7"), "a progress push shows its pushed revision")
end

-- ---- FAULTS fire ONLY on confirmed-false, NEVER on nil (no false positives) ----
-- This is the rule that keeps an unknown from masquerading as breakage.
do
    -- Nothing checked at all -> the report must show NO fault.
    local d = sample()
    d.integrity = {}
    local r = DS.build(d)
    h.assert_true(has(r.full, "Faults: " .. OK .. " none detected"),
        "all-nil integrity raises no fault")
    h.assert_false(has(r.full, WARN), "no warning glyph when nothing is confirmed broken")

    -- Store present but decode UNKNOWN (nil) -> not a fault.
    local d2 = sample()
    d2.integrity = { store_exists = true, store_decode_ok = nil }
    h.assert_false(has(DS.build(d2).full, WARN),
        "a present store with unknown decode status is not a fault")

    -- .stignore not applicable (e.g. hash mode), presence nil -> not a fault.
    local d3 = sample()
    d3.integrity = { stignore_applicable = false, stignore_present = nil }
    h.assert_false(has(DS.build(d3).full, WARN),
        "an inapplicable .stignore raises no fault")

    -- .stignore applicable but presence UNKNOWN (nil -- root unresolved) -> not
    -- a fault either; only a confirmed-missing file is.
    local d4 = sample()
    d4.integrity = { stignore_applicable = true, stignore_present = nil }
    h.assert_false(has(DS.build(d4).full, WARN),
        "an applicable .stignore with unknown presence is not a fault")
end

-- ---- each confirmed-false fact raises its OWN specific fault ----
do
    local d = sample()
    d.integrity = { store_exists = true, store_decode_ok = false }
    h.assert_true(has(DS.build(d).full, "unreadable"), "corrupt store -> fault")

    local d2 = sample()
    d2.integrity = { stignore_applicable = true, stignore_present = false }
    h.assert_true(has(DS.build(d2).full, ".stignore missing"),
        "missing .stignore (SDR + configured folder) -> fault")

    -- both broken at once -> both listed under one warning line
    local d3 = sample()
    d3.integrity = { store_exists = true, store_decode_ok = false,
                     stignore_applicable = true, stignore_present = false }
    local r3 = DS.build(d3)
    h.assert_true(has(r3.full, "unreadable") and has(r3.full, ".stignore missing"),
        "both faults listed together")
    h.assert_true(#r3.faults == 2, "exactly two faults derived")
end

-- ---- STORAGE & INTEGRITY section reports facts NEUTRALLY ----
do
    local r = DS.build(sample())
    h.assert_true(has(r.full, "STORAGE & INTEGRITY"), "the section is present")
    h.assert_true(matches(r.full, "Store%s+ok"), "a valid store reads ok")
    h.assert_true(matches(r.full, "Conflicts%s+0 copies"), "conflict count shown")
    h.assert_true(matches(r.full, "Tombstones%s+3 recorded"), "tombstone count shown")
    h.assert_true(matches(r.full, "Metadata tombstones:%s+2 recorded"),
        "metadata tombstone count shown")
    h.assert_true(matches(r.full, "%.stignore%s+present"), "stignore present shown")

    -- a corrupt store reads UNREADABLE in the section (the warning is on Faults)
    local d = sample()
    d.integrity.store_exists = true
    d.integrity.store_decode_ok = false
    h.assert_true(has(DS.build(d).full, "UNREADABLE"),
        "corrupt store labelled plainly in the section")

    -- nothing checked -> store n/a, stignore n/a (no scary defaults)
    local d2 = sample()
    d2.integrity = {}
    local r2 = DS.build(d2)
    h.assert_true(has(r2.full, "no book open"), "store n/a when nothing checked")
    h.assert_true(matches(r2.full, "%.stignore%s+n/a"),
        "stignore n/a when not applicable")
    h.assert_false(has(r2.full, "Tombstones"),
        "tombstone line hidden when the count is unknown")
    h.assert_false(has(r2.full, "Metadata tombstones"),
        "metadata tombstone line hidden when the count is unknown")
end

-- ---- count_tombstones: deletions recorded in a decoded store, defensively ----
do
    local store = { annotations = {
        ["k1"] = { text = "a" },           -- active
        ["k2"] = { deleted = true },       -- tombstone
        ["k3"] = { text = "c" },           -- active
        ["k4"] = { deleted = true },       -- tombstone
    } }
    h.assert_equal(DS.count_tombstones(store), 2,
        "counts only the deleted == true entries")
    h.assert_equal(DS.count_tombstones({ annotations = {} }), 0, "empty store -> 0")
    h.assert_equal(DS.count_tombstones({}), 0, "no annotations key -> 0")
    h.assert_equal(DS.count_tombstones(nil), 0, "nil store -> 0 (defensive)")
end

-- ---- count_metadata_tombstones: cleared metadata fields in a decoded store ----
do
    local store = { metadata = {
        rating       = { deleted = true },          -- cleared
        summary_note = { value = "x" },             -- present
        collections  = { deleted = true },          -- cleared
        custom       = { value = { title = "T" } }, -- present
    } }
    h.assert_equal(DS.count_metadata_tombstones(store), 2,
        "counts only the deleted == true metadata fields")
    h.assert_equal(DS.count_metadata_tombstones({ metadata = {} }), 0, "empty metadata -> 0")
    h.assert_equal(DS.count_metadata_tombstones({}), 0, "no metadata key -> 0")
    h.assert_equal(DS.count_metadata_tombstones(nil), 0, "nil store -> 0 (defensive)")
end

-- ---- defensive: build(nil) still produces a valid report ----
do
    local r = DS.build(nil)
    h.assert_true(type(r) == "table" and type(r.full) == "string",
        "build(nil) returns a table with text")
    h.assert_true(has(r.full, "Faults: " .. OK .. " none detected"),
        "build(nil) still leads with the faults line")
end
