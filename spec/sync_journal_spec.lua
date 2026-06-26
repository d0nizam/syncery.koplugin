-- =============================================================================
-- spec/sync_journal_spec.lua
-- =============================================================================
--
-- Tests for syncery_progress/sync_journal.lua — the device-local,
-- append-only, bounded, schema-versioned merge-event journal (Phase
-- 7.1).
--
-- The journal writes to a real file (append mode, by design — see the
-- module header), so these tests point it at a temp path under the
-- harness test_root via the `opts.path` seam.  Time is pinned with
-- make_fake_clock so the `timestamp` field is deterministic and the
-- 7-timezone matrix can't perturb it (it's numeric epoch — A15 — so
-- it shouldn't, and this spec proves it).
--
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_sync_journal_spec_" .. tostring(os.time()))

local SyncJournal = require("syncery_progress/sync_journal")


-- ----------------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------------


local counter = 0
local function unique_journal_path()
    counter = counter + 1
    return h.test_root .. "/journal_" .. tostring(counter) .. ".ndjson"
end


--- Count physical lines in a file (0 if absent).
local function line_count(path)
    local f = io.open(path, "r")
    if not f then return 0 end
    local n = 0
    for _ in f:lines() do n = n + 1 end
    f:close()
    return n
end


--- A minimal annotation-orchestrator-shaped result object.  Only the
--- fields sync_journal.record_merge reads are populated; overrides via
--- the `over` table.
local function fake_result(over)
    over = over or {}
    local r = {
        ok                   = true,
        error                = nil,
        skipped              = false,
        skipped_reason       = nil,
        annotations_pulled   = 0,
        annotations_pushed   = 0,
        tombstones_compacted = 0,
        conflicts_merged     = 0,
        merged_state         = nil,
    }
    for k, v in pairs(over) do r[k] = v end
    return r
end


-- ----------------------------------------------------------------------------
-- append: writes one JSON line, round-trips the entry
-- ----------------------------------------------------------------------------


do
    local path = unique_journal_path()
    local ok = SyncJournal.append({ book_id = "b1", outcome = "merged" },
        { path = path })
    h.assert_true(ok, "append returns true on success")
    h.assert_equal(line_count(path), 1, "append wrote exactly one line")

    local entries = SyncJournal.read_all({ path = path })
    h.assert_equal(#entries, 1, "read_all returns the one entry")
    h.assert_equal(entries[1].book_id, "b1", "entry round-trips book_id")
end


-- ----------------------------------------------------------------------------
-- append: truly appends (does not overwrite a prior entry)
-- ----------------------------------------------------------------------------


do
    local path = unique_journal_path()
    SyncJournal.append({ book_id = "b1" }, { path = path })
    SyncJournal.append({ book_id = "b2" }, { path = path })
    SyncJournal.append({ book_id = "b3" }, { path = path })

    h.assert_equal(line_count(path), 3, "three appends -> three lines")

    local entries = SyncJournal.read_all({ path = path })
    h.assert_equal(#entries, 3, "read_all sees all three")
    h.assert_equal(entries[1].book_id, "b1", "oldest entry first")
    h.assert_equal(entries[3].book_id, "b3", "newest entry last")
end


-- ----------------------------------------------------------------------------
-- append: bounded — the ring trims to MAX_ENTRIES in the same call
-- ----------------------------------------------------------------------------


do
    local path = unique_journal_path()
    -- max_entries override keeps the test fast: bound of 5.
    for i = 1, 12 do
        SyncJournal.append({ book_id = "book_" .. i }, { path = path, max_entries = 5 })
    end

    h.assert_equal(line_count(path), 5,
        "file is trimmed to the ring bound after appends exceed it")

    local entries = SyncJournal.read_all({ path = path })
    h.assert_equal(#entries, 5, "read_all sees exactly the bound")
    h.assert_equal(entries[1].book_id, "book_8",
        "trim keeps the NEWEST entries (oldest dropped)")
    h.assert_equal(entries[5].book_id, "book_12",
        "most recent append survives at the tail")
end


-- ----------------------------------------------------------------------------
-- append: at exactly the bound, nothing is trimmed
-- ----------------------------------------------------------------------------


do
    local path = unique_journal_path()
    for i = 1, 5 do
        SyncJournal.append({ book_id = "x" .. i }, { path = path, max_entries = 5 })
    end
    h.assert_equal(line_count(path), 5, "exactly-at-bound file is untouched")
    local entries = SyncJournal.read_all({ path = path })
    h.assert_equal(entries[1].book_id, "x1", "oldest still present at the bound")
end


-- ----------------------------------------------------------------------------
-- append: rejects a non-table entry, doesn't create a file
-- ----------------------------------------------------------------------------


do
    local path = unique_journal_path()
    local ok = SyncJournal.append("not a table", { path = path })
    h.assert_false(ok, "append rejects a non-table entry")
    h.assert_equal(line_count(path), 0, "no file written for a bad entry")
end


-- ----------------------------------------------------------------------------
-- record_merge: builds a well-formed entry from a 'merged' result.
-- Records pulled/pushed SEPARATELY (not just the sum), the alive count
-- before/after the merge, the trigger (what started the sync), and the
-- readable device LABEL -- but NOT the opaque device id (dropped: the
-- journal is device-local, so the id is redundant; an id is supplied in
-- opts here to prove it is NOT stored).
-- ----------------------------------------------------------------------------


do
    local path  = unique_journal_path()
    local clock = h.make_fake_clock(1700000000)

    local result = fake_result{
        annotations_pulled   = 3,
        annotations_pushed   = 2,
        annotations_before   = 10,
        annotations_after    = 9,
        tombstones_compacted = 1,
        conflicts_merged     = 1,
        merged_state         = { device_id = "STALE-MERGED", schema_version = 1 },
    }

    local ok = SyncJournal.record_merge("book-abc", result, "syncthing",
        { path = path, clock = clock.now,
          writer_device_id = "PHONE", writer_device_label = "My Phone",
          trigger = "save" })
    h.assert_true(ok, "record_merge returns true")

    local e = SyncJournal.read_all({ path = path })[1]
    h.assert_equal(e.book_id, "book-abc",            "book_id recorded")
    h.assert_equal(e.transport, "syncthing",         "transport recorded")
    h.assert_equal(e.outcome, "merged",              "outcome classified as merged")
    h.assert_equal(e.kind, "annotation",             "entry carries kind=annotation (v4)")
    h.assert_equal(e.annotations_pulled, 3,          "annotations_pulled recorded separately")
    h.assert_equal(e.annotations_pushed, 2,          "annotations_pushed recorded separately")
    h.assert_equal(e.annotations_before, 10,         "alive count BEFORE the merge recorded")
    h.assert_equal(e.annotations_after, 9,           "alive count AFTER the merge recorded")
    h.assert_equal(e.tombstones_applied, 1,          "tombstones_applied recorded")
    h.assert_equal(e.conflicts_resolved, 1,          "conflicts_resolved recorded")
    h.assert_equal(e.trigger, "save",                "trigger recorded from opts")
    h.assert_nil(e.winning_device,
        "opaque winning_device id is NOT stored even when supplied (device-local journal)")
end


-- ----------------------------------------------------------------------------
-- record_merge: timestamp is the numeric epoch from the clock (A15)
-- ----------------------------------------------------------------------------


do
    local path  = unique_journal_path()
    local clock = h.make_fake_clock(1700000000)

    SyncJournal.record_merge("b", fake_result{ annotations_pushed = 1 }, "local",
        { path = path, clock = clock.now })

    local e = SyncJournal.read_all({ path = path })[1]
    h.assert_equal(type(e.timestamp), "number",
        "timestamp is a number, not a formatted string (A15)")
    h.assert_equal(e.timestamp, 1700000000,
        "timestamp is exactly the epoch the clock returned")
end


-- ----------------------------------------------------------------------------
-- record_merge: the event DECISION — non-events are DROPPED, real events land
--
-- Symmetric with record_progress's noop-skip.  A merge that touched
-- nothing (noop) and an empty-skip (a sync section off / book has no
-- data) write NO line -- on every close they would evict the meaningful
-- entries from the 300-ring.  A wipe_failsafe skip, a failure, and a
-- real merge DO land.  See A18 / the journal-noise analysis.
-- ----------------------------------------------------------------------------


do
    local path = unique_journal_path()

    -- Non-events are DROPPED.
    h.assert_false(
        SyncJournal.record_merge("b", fake_result(), "syncthing", { path = path }),
        "a clean-but-empty merge (noop) is dropped")
    h.assert_false(
        SyncJournal.record_merge("b",
            fake_result{ ok = true, skipped = true, skipped_reason = "empty" },
            "syncthing", { path = path }),
        "an empty-skip is dropped")
    h.assert_equal(line_count(path), 0, "neither non-event wrote a line")

    -- Real events STILL land: a wipe_failsafe skip protected data, a failure
    -- is a problem, a merge moved annotations.
    SyncJournal.record_merge("b",
        fake_result{ ok = false, skipped = true, skipped_reason = "wipe_failsafe" },
        "syncthing", { path = path })
    SyncJournal.record_merge("b",
        fake_result{ ok = false, error = "save_shared_failed" },
        "syncthing", { path = path })
    SyncJournal.record_merge("b",
        fake_result{ annotations_pushed = 2 },
        "syncthing", { path = path })

    local entries = SyncJournal.read_all({ path = path })
    h.assert_equal(#entries, 3, "the three real events landed")
    h.assert_equal(entries[1].outcome, "skipped", "failsafe-declined merge -> skipped")
    h.assert_equal(entries[1].skipped_reason, "wipe_failsafe",
        "a non-empty skip is kept with its reason")
    h.assert_equal(entries[2].outcome, "failed",  "errored merge -> failed")
    h.assert_equal(entries[2].error, "save_shared_failed",
        "failure reason recorded on the failed entry")
    h.assert_equal(entries[3].outcome, "merged",  "a merge that moved annotations -> merged")
end


-- ----------------------------------------------------------------------------
-- record_merge: logged entries rotate the ring bound
--
-- Now that non-events are dropped, ring rotation is exercised with real
-- events.  (A run of noops would write nothing -- see the drop above.)
-- ----------------------------------------------------------------------------


do
    local path = unique_journal_path()
    for i = 1, 8 do
        SyncJournal.record_merge("busy-book",
            fake_result{ annotations_pushed = 1 }, "local",
            { path = path, max_entries = 4 })
    end
    h.assert_equal(line_count(path), 4,
        "logged merges rotate the ring like any other entry")
end


-- ----------------------------------------------------------------------------
-- record_merge: missing winning device is fine (nil, not crash)
-- ----------------------------------------------------------------------------


do
    local path = unique_journal_path()
    -- No writer label in opts -> no winning device recorded.  The opaque
    -- winning_device id is never stored (dropped).
    SyncJournal.record_merge("b",
        fake_result{ annotations_pushed = 1, merged_state = { schema_version = 1 } },
        "syncthing", { path = path })

    local e = SyncJournal.read_all({ path = path })[1]
    h.assert_equal(e.outcome, "merged",        "merged outcome regardless of writer")
    h.assert_nil(e.winning_device,             "opaque winning_device id is never stored (dropped)")
end


-- ----------------------------------------------------------------------------
-- v3: zero-valued counts are omitted (short, legible line); the dropped
-- fields never reappear.  Verified on a LOGGED merge -- a pure noop is
-- dropped entirely now (see the event-decision test above), so omit-zeros
-- is exercised on a real entry that still carries some zero counts.
-- ----------------------------------------------------------------------------


do
    local path = unique_journal_path()
    -- A merge that only pushed: pulled / conflicts / tombstones are 0 and
    -- must be ABSENT (not stored as 0).
    SyncJournal.record_merge("b-quiet",
        fake_result{ annotations_pushed = 2 }, "local", { path = path })

    local e = SyncJournal.read_all({ path = path })[1]
    h.assert_equal(e.outcome, "merged",    "a push-only result classifies as merged")
    h.assert_equal(e.annotations_pushed, 2, "the non-zero pushed count is recorded")
    h.assert_nil(e.annotations_pulled,     "zero pulled is omitted, not stored as 0")
    h.assert_nil(e.conflicts_resolved,     "zero conflicts omitted")
    h.assert_nil(e.tombstones_applied,     "zero tombstones omitted")
    h.assert_nil(e.annotations_before,     "alive pair omitted when the book has no annotations")
    h.assert_nil(e.annotations_after,      "alive pair omitted when the book has no annotations")
    h.assert_nil(e.annotations_merged,     "annotations_merged is gone from the v3 schema")
    h.assert_nil(e.winning_device_label,   "winning_device_label is gone from the v3 schema")
end


-- ----------------------------------------------------------------------------
-- record_merge: rejects a non-table result without crashing
-- ----------------------------------------------------------------------------


do
    local path = unique_journal_path()
    local ok = SyncJournal.record_merge("b", nil, "local", { path = path })
    h.assert_false(ok, "record_merge with nil result returns false")
    h.assert_equal(line_count(path), 0, "nothing written for a nil result")
end


-- ----------------------------------------------------------------------------
-- read_all: tolerates a malformed line (skips it, doesn't crash)
-- ----------------------------------------------------------------------------


do
    local path = unique_journal_path()
    SyncJournal.append({ book_id = "good1" }, { path = path })
    -- Simulate a half-written line from a device that died mid-append.
    local f = io.open(path, "a")
    f:write("{ this is not valid json\n")
    f:close()
    SyncJournal.append({ book_id = "good2" }, { path = path })

    local entries = SyncJournal.read_all({ path = path })
    h.assert_equal(#entries, 2, "malformed line skipped, valid entries kept")
    h.assert_equal(entries[1].book_id, "good1", "first valid entry intact")
    h.assert_equal(entries[2].book_id, "good2", "second valid entry intact")
end


-- ----------------------------------------------------------------------------
-- read_all: empty / absent file -> empty list
-- ----------------------------------------------------------------------------


do
    local entries = SyncJournal.read_all({ path = unique_journal_path() })
    h.assert_equal(#entries, 0, "absent journal file reads as empty list")
end


-- ----------------------------------------------------------------------------
-- clear: removes the file
-- ----------------------------------------------------------------------------


do
    local path = unique_journal_path()
    SyncJournal.append({ book_id = "b" }, { path = path })
    h.assert_equal(line_count(path), 1, "entry written before clear")

    SyncJournal.clear({ path = path })
    h.assert_equal(line_count(path), 0, "clear removed the journal file")
    h.assert_equal(#SyncJournal.read_all({ path = path }), 0,
        "read_all after clear is empty")
end


-- ----------------------------------------------------------------------------
-- The default path: sync_journal_path resolves and is device-local
--
-- No `opts.path` override here — exercises the real path resolution
-- through syncery_progress/paths.lua, proving the journal lands under
-- the private state dir (NOT a synced sidecar).
-- ----------------------------------------------------------------------------


do
    local Paths = require("syncery_progress/paths")
    local jpath = Paths.sync_journal_path()
    h.assert_true(jpath ~= nil, "sync_journal_path resolves to non-nil")
    h.assert_true(jpath:match("/syncery/") ~= nil,
        "journal lives under the private syncery state dir (device-local)")
    h.assert_true(jpath:match("%.sdr/") == nil,
        "journal is NOT in a .sdr sidecar (which Syncthing would replicate)")
    h.assert_true(jpath:match("sync%-journal") ~= nil,
        "journal filename is recognisable")

    -- A full round-trip through the real default path.
    SyncJournal.clear()
    local ok = SyncJournal.record_merge("real-path-book",
        fake_result{ annotations_pushed = 1 }, "local")
    h.assert_true(ok, "record_merge works through the real default path")
    local entries = SyncJournal.read_all()
    h.assert_true(#entries >= 1, "entry readable back through the real default path")
    SyncJournal.clear()
end


-- ----------------------------------------------------------------------------
-- record_progress: kind="progress", write-site noop-skip, outcome
-- classification (merged / skipped / failed)
-- ----------------------------------------------------------------------------


--- A minimal progress-orchestrator-shaped result object.
local function fake_progress_result(over)
    over = over or {}
    local r = {
        ok               = true,
        error            = nil,
        skipped          = false,
        skipped_reason   = nil,
        position_pushed  = false,
        conflicts_merged = 0,
        local_revision   = 0,
    }
    for k, v in pairs(over) do r[k] = v end
    return r
end


do
    -- A pushed position lands a kind="progress" line.
    local path = unique_journal_path()
    SyncJournal.record_progress("book-prog", fake_progress_result({
        position_pushed = true, local_revision = 7,
    }), "syncthing", { path = path, trigger = "save" })
    local e = SyncJournal.read_all({ path = path })[1]
    h.assert_true(e ~= nil, "a pushed progress sync lands one entry")
    h.assert_equal(e.kind, "progress", "entry carries kind=progress")
    h.assert_equal(e.outcome, "merged", "a push classifies as merged")
    h.assert_equal(e.position_pushed, true, "position_pushed is recorded on a push")
    h.assert_equal(e.revision, 7, "the stamped revision is recorded on a push")
    h.assert_equal(e.trigger, "save", "trigger recorded from opts")
    h.assert_equal(e.transport, "syncthing", "transport recorded")
end


do
    -- A PURE noop (nothing pushed, no conflict, not skipped, no error) is
    -- dropped at the write site -- no line is written (anti-flood).  This
    -- is the test that pins the noop-skip: removing the early-return makes
    -- a line appear and flips both assertions.
    local path = unique_journal_path()
    local r = SyncJournal.record_progress("book-prog", fake_progress_result({}),
        "syncthing", { path = path, trigger = "save" })
    h.assert_false(r, "record_progress returns false on a pure noop")
    h.assert_equal(line_count(path), 0, "a pure-noop progress sync writes NO line")
end


do
    -- A conflict-only resolution (no position push) still lands a line.
    local path = unique_journal_path()
    SyncJournal.record_progress("book-prog", fake_progress_result({
        conflicts_merged = 2,
    }), "syncthing", { path = path })
    local e = SyncJournal.read_all({ path = path })[1]
    h.assert_true(e ~= nil, "a conflict-only progress sync lands one entry")
    h.assert_equal(e.outcome, "merged", "a conflict resolution classifies as merged")
    h.assert_equal(e.conflicts_resolved, 2, "conflicts_resolved is recorded")
    h.assert_nil(e.position_pushed, "position_pushed is absent when nothing was pushed")
    h.assert_nil(e.revision, "revision is absent when nothing was pushed")
end


do
    -- A skipped sync (with a reason) lands a line.
    local path = unique_journal_path()
    SyncJournal.record_progress("book-prog", fake_progress_result({
        skipped = true, skipped_reason = "empty",
    }), "syncthing", { path = path })
    local e = SyncJournal.read_all({ path = path })[1]
    h.assert_true(e ~= nil, "a skipped progress sync lands one entry")
    h.assert_equal(e.outcome, "skipped", "a skipped sync classifies as skipped")
    h.assert_equal(e.skipped_reason, "empty", "skipped_reason is recorded")
end


do
    -- A failed sync lands a line.
    local path = unique_journal_path()
    SyncJournal.record_progress("book-prog", fake_progress_result({
        ok = false, error = "save_failed",
    }), "syncthing", { path = path })
    local e = SyncJournal.read_all({ path = path })[1]
    h.assert_true(e ~= nil, "a failed progress sync lands one entry")
    h.assert_equal(e.outcome, "failed", "a failed sync classifies as failed")
    h.assert_equal(e.error, "save_failed", "error reason is recorded")
end


do
    -- Event filter: a routine autosave that only pushed a new reading
    -- position is dropped (the high-frequency flood).  Removing the
    -- early-return makes a line appear and flips both assertions.
    local path = unique_journal_path()
    local r = SyncJournal.record_progress("book-prog", fake_progress_result({
        position_pushed = true, local_revision = 9,
    }), "syncthing", { path = path, trigger = "autosave" })
    h.assert_false(r, "a routine autosave position push is dropped")
    h.assert_equal(line_count(path), 0, "a routine autosave push writes NO line")
end


do
    -- ...but an autosave that RESOLVED A CONFLICT still lands: a conflict is
    -- worth a line regardless of what triggered the sync.
    local path = unique_journal_path()
    SyncJournal.record_progress("book-prog", fake_progress_result({
        position_pushed = true, local_revision = 9, conflicts_merged = 1,
    }), "syncthing", { path = path, trigger = "autosave" })
    local e = SyncJournal.read_all({ path = path })[1]
    h.assert_true(e ~= nil, "an autosave that resolved a conflict still lands")
    h.assert_equal(e.outcome, "merged", "the conflict autosave is merged")
    h.assert_equal(e.conflicts_resolved, 1, "the resolved conflict is recorded")
end


do
    -- Event filter: a jump's follow-up position push (trigger="jump") is
    -- dropped -- record_jump already wrote the canonical "jumped" line, so
    -- the push is a redundant mechanical consequence.
    local path = unique_journal_path()
    local r = SyncJournal.record_progress("book-jump", fake_progress_result({
        position_pushed = true, local_revision = 4,
    }), "syncthing", { path = path, trigger = "jump" })
    h.assert_false(r, "a jump follow-up position push is dropped")
    h.assert_equal(line_count(path), 0, "a jump follow-up push writes NO line")
end


do
    -- ...but a jump-save that ALSO resolved a conflict still lands.
    local path = unique_journal_path()
    SyncJournal.record_progress("book-jump", fake_progress_result({
        position_pushed = true, local_revision = 4, conflicts_merged = 1,
    }), "syncthing", { path = path, trigger = "jump" })
    local e = SyncJournal.read_all({ path = path })[1]
    h.assert_true(e ~= nil, "a jump-save that resolved a conflict still lands")
    h.assert_equal(e.conflicts_resolved, 1, "the resolved conflict is recorded")
end


-- ----------------------------------------------------------------------------
-- record_jump: a canonical "jumped" event (kind="progress")
-- ----------------------------------------------------------------------------


do
    -- record_jump writes a "jumped" line naming the adopted device.
    local path = unique_journal_path()
    SyncJournal.record_jump("book-jump", {
        path = path,
        winning_device_label = "My Phone",
        transport = "syncthing",
    })
    local e = SyncJournal.read_all({ path = path })[1]
    h.assert_true(e ~= nil, "a jump lands one entry")
    h.assert_equal(e.kind, "progress", "a jump is kind=progress")
    h.assert_equal(e.outcome, "jumped", "a jump's outcome is jumped")
    h.assert_equal(e.winning_device_label, "My Phone", "the adopted device is recorded")
    h.assert_equal(e.transport, "syncthing", "transport recorded")
end


do
    -- winning_device_label is optional -- omitted when the source is unknown.
    local path = unique_journal_path()
    SyncJournal.record_jump("book-jump", { path = path })
    local e = SyncJournal.read_all({ path = path })[1]
    h.assert_true(e ~= nil, "a jump with no known device still lands")
    h.assert_equal(e.outcome, "jumped", "outcome is jumped")
    h.assert_nil(e.winning_device_label, "winning_device_label is absent when unknown")
end


-- ----------------------------------------------------------------------------
-- record_status_resolve: a status-conflict resolution (kind="status")
-- ----------------------------------------------------------------------------


do
    -- record_status_resolve writes a kind="status" resolution line.
    local path = unique_journal_path()
    SyncJournal.record_status_resolve("book-st", "abandoned-vs-complete", "complete", {
        path = path, transport = "syncthing",
    })
    local e = SyncJournal.read_all({ path = path })[1]
    h.assert_true(e ~= nil, "a resolution lands one entry")
    h.assert_equal(e.kind, "status", "a resolution is kind=status")
    h.assert_equal(e.outcome, "merged", "a resolution's outcome is merged")
    h.assert_equal(e.status_from, "abandoned-vs-complete", "the conflict is recorded")
    h.assert_equal(e.status_to, "complete", "the chosen value is recorded")
end


-- ----------------------------------------------------------------------------
-- record_bulk: a per-book bulk-ingest backfill (kind="bulk")
-- ----------------------------------------------------------------------------


do
    -- record_bulk writes a kind="bulk" backfill line with the ingested count.
    local path = unique_journal_path()
    SyncJournal.record_bulk("book-bulk", { path = path, ingested = 12, transport = "syncthing" })
    local e = SyncJournal.read_all({ path = path })[1]
    h.assert_true(e ~= nil, "a backfill lands one entry")
    h.assert_equal(e.kind, "bulk", "a backfill is kind=bulk")
    h.assert_equal(e.outcome, "merged", "a backfill's outcome is merged")
    h.assert_equal(e.ingested, 12, "the ingested count is recorded")
end


-- ----------------------------------------------------------------------------
-- record_merge: metadata coverage (S7) -- a metadata-only sync is an EVENT
-- ----------------------------------------------------------------------------
-- A sync that changed ONLY metadata (e.g. cleared a rating) has zero annotation
-- movement, so without the classify_outcome metadata clause it would classify as
-- "noop" and be DROPPED before any count.  It must land, as "merged", carrying the
-- metadata_changed count.


do
    local path = unique_journal_path()

    -- metadata-only (a cleared rating): no annotation movement at all.
    local ok = SyncJournal.record_merge("b",
        fake_result{ metadata_applied = { rating = true } },
        "syncthing", { path = path })
    h.assert_true(ok, "metadata-only sync is journaled (NOT dropped as noop)")

    local entries = SyncJournal.read_all({ path = path })
    h.assert_equal(#entries, 1, "the metadata-only event landed")
    h.assert_equal(entries[1].outcome, "merged", "metadata-only sync -> merged")
    h.assert_equal(entries[1].metadata_changed, 1, "metadata_changed counts the one applied field")

    -- count reflects multiple applied fields
    SyncJournal.record_merge("b",
        fake_result{ metadata_applied = { rating = true, summary_note = true, custom = true } },
        "syncthing", { path = path })
    local e2 = SyncJournal.read_all({ path = path })
    h.assert_equal(e2[2].metadata_changed, 3, "metadata_changed counts all applied fields")
end

-- An empty metadata_applied table with no annotation change is still a noop.
do
    local path = unique_journal_path()
    h.assert_false(
        SyncJournal.record_merge("b",
            fake_result{ metadata_applied = {} }, "syncthing", { path = path }),
        "empty metadata_applied + no annotation change -> still dropped as noop")
    h.assert_equal(line_count(path), 0, "no line written for the empty-metadata noop")
end

-- metadata_changed is OMITTED (nil) when zero, matching the other counts.
do
    local path = unique_journal_path()
    -- an annotation push (lands) but NO metadata change
    SyncJournal.record_merge("b",
        fake_result{ annotations_pushed = 2 }, "syncthing", { path = path })
    local entries = SyncJournal.read_all({ path = path })
    h.assert_equal(entries[1].outcome, "merged", "annotation-only merge lands")
    h.assert_nil(entries[1].metadata_changed,
        "metadata_changed omitted (nil) when no metadata changed")
end


-- ----------------------------------------------------------------------------
-- Report
-- ----------------------------------------------------------------------------

h.report("sync_journal_spec")
