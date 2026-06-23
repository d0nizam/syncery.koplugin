-- =============================================================================
-- spec/progress_orchestrator_spec.lua
-- =============================================================================
--
-- Tests for syncery_progress/sync_orchestrator.lua — the public entry
-- point of the progress subsystem.
--
-- Because the orchestrator pulls in state_store + conflict_resolver +
-- merge + progress_bridge, this spec also exercises those modules
-- end-to-end (state_store and conflict_resolver have no separate spec;
-- they're tested through here).
--
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_progress_orchestrator_spec_" .. tostring(os.time()))

local Orchestrator = require("syncery_progress/sync_orchestrator")
local Paths        = require("syncery_progress/paths")
local StateStore   = require("syncery_progress/state_store")
local JsonStore    = require("syncery_ann/json_store")


-- ----------------------------------------------------------------------------
-- Helper: make a fake ReaderUI + ensure a unique book file per test
-- ----------------------------------------------------------------------------


local counter = 0
local function unique_book_file()
    counter = counter + 1
    local p = h.test_root .. "/orch_book_" .. tostring(counter) .. ".epub"
    -- KOReader's docsettings stub expects the file to exist, but our
    -- ann_paths only needs it for hash computation (which doesn't read
    -- the file).  Still, touch it so any future code that does check
    -- existence is happy.
    local f = io.open(p, "wb")
    if f then f:write(""); f:close() end
    return p
end


local function make_fake_ui(book_file, opts)
    opts = opts or {}
    return {
        paging   = opts.paging or false,
        rolling  = (not opts.paging) and {
            current_page = opts.page or 1,
            total_pages  = opts.total_pages or 200,
            xpointer     = opts.xpath,
        } or nil,
        document = {
            file = book_file,
            getCurrentPage = function() return opts.page or 1 end,
            getPageCount   = function() return opts.total_pages or 200 end,
            getXPointer    = function() return opts.xpath or "" end,
            getProps       = function() return { title = "T" } end,
        },
        footer   = { percent_finished = opts.percent or 0 },
    }
end


-- Make sure we start each block in SDR mode (so the test book's
-- progress file lives in the .sdr sidecar that docsettings stubs
-- give us).
Paths.set_storage_mode("sdr")


-- ----------------------------------------------------------------------------
-- Pre-flight: missing inputs produce structured errors
-- ----------------------------------------------------------------------------


do
    local book = unique_book_file()

    local r = Orchestrator.sync_book(nil, book, { device_id = "X" })
    h.assert_equal(r.error, "no_ui", "nil ui produces no_ui error")

    r = Orchestrator.sync_book(make_fake_ui(book), nil, { device_id = "X" })
    h.assert_equal(r.error, "no_book_file", "nil book_file produces no_book_file error")

    r = Orchestrator.sync_book(make_fake_ui(book), book, { device_id = "" })
    h.assert_equal(r.error, "no_device_id", "empty device_id produces no_device_id error")
end


-- ----------------------------------------------------------------------------
-- Happy path: fresh book, first sync writes the file and last-sync
-- ----------------------------------------------------------------------------


do
    local book = unique_book_file()
    local ui   = make_fake_ui(book, { page = 50, total_pages = 200,
                                       percent = 0.245, xpath = "/p" })

    local r = Orchestrator.sync_book(ui, book, {
        device_id = "PHONE",
        device_label = "My Phone",
        sync_progress = true,
    })

    h.assert_true(r.ok, "happy-path sync reports ok=true")
    h.assert_false(r.skipped, "happy-path sync is not skipped")
    h.assert_equal(r.local_revision, 1, "first sync stamps revision=1")
    h.assert_equal(r.merged_entry_count, 1, "one entry in merged file")
    h.assert_equal(r.conflicts_found, 0, "no conflicts on fresh book")

    -- Verify the shared file actually exists and has the right shape.
    local p = Paths.shared_progress_path(book)
    local loaded, _ = JsonStore.read(p)
    h.assert_true(loaded ~= nil, "shared progress file was written to disk")
    h.assert_true(loaded.entries.PHONE ~= nil,
        "PHONE entry exists in shared file")
    h.assert_equal(loaded.entries.PHONE.revision, 1,
        "shared file has revision=1 for PHONE")
    h.assert_equal(loaded.entries.PHONE.percent, 0.245,
        "shared file has percent from live state")

    -- Verify the last-sync file was also written.
    local ls_path = Paths.last_sync_progress_path(book)
    local ls, _ = JsonStore.read(ls_path)
    h.assert_true(ls ~= nil, "last-sync file was written")
    h.assert_equal(ls.entries.PHONE.revision, 1,
        "last-sync file mirrors shared file after sync")
end


-- ----------------------------------------------------------------------------
-- position_pushed: true on a first write and on a move, false on an
-- idempotent re-sync (Lesson #45 -- the revision bump is the honest signal,
-- not "local_revision is set", which is set on every push_local run)
-- ----------------------------------------------------------------------------


do
    local book = unique_book_file()
    local function sync_at(page, xpath, percent)
        return Orchestrator.sync_book(
            make_fake_ui(book, { page = page, total_pages = 200,
                                 percent = percent, xpath = xpath }),
            book,
            { device_id = "PHONE", device_label = "My Phone", sync_progress = true })
    end

    local r1 = sync_at(50, "/p[1]", 0.25)
    h.assert_true(r1.position_pushed, "first write pushes a new position")
    h.assert_equal(r1.local_revision, 1, "first write stamps revision 1")

    -- Re-sync the SAME position: upsert is idempotent -> no bump, no push.
    local r2 = sync_at(50, "/p[1]", 0.25)
    h.assert_false(r2.position_pushed, "re-asserting the same position does NOT push")
    h.assert_equal(r2.local_revision, 1, "idempotent re-sync keeps revision 1 (no bump)")

    -- Move to a different position: upsert stamps -> push.
    local r3 = sync_at(80, "/p[2]", 0.40)
    h.assert_true(r3.position_pushed, "moving to a new position pushes")
    h.assert_equal(r3.local_revision, 2, "a move bumps revision to 2")
end


-- ----------------------------------------------------------------------------
-- Sequential syncs from the same device bump revision monotonically
-- ----------------------------------------------------------------------------


do
    local book = unique_book_file()
    local opts = { device_id = "PHONE", device_label = "My Phone",
                   sync_progress = true }

    local ui1 = make_fake_ui(book, { page = 10, total_pages = 100, percent = 0.10 })
    local r1  = Orchestrator.sync_book(ui1, book, opts)
    h.assert_equal(r1.local_revision, 1, "first sync: revision=1")

    local ui2 = make_fake_ui(book, { page = 20, total_pages = 100, percent = 0.20 })
    local r2  = Orchestrator.sync_book(ui2, book, opts)
    h.assert_equal(r2.local_revision, 2, "second sync: revision=2")

    local ui3 = make_fake_ui(book, { page = 30, total_pages = 100, percent = 0.30 })
    local r3  = Orchestrator.sync_book(ui3, book, opts)
    h.assert_equal(r3.local_revision, 3, "third sync: revision=3")

    -- Verify the file reflects the latest.
    local loaded = StateStore.load_shared(book)
    h.assert_equal(loaded.entries.PHONE.revision, 3, "shared file at rev=3")
    h.assert_equal(loaded.entries.PHONE.percent, 0.30, "shared file at percent=0.30")
end


-- ----------------------------------------------------------------------------
-- Wipe failsafe: percent=0, page<=1 + remote has real progress -> skipped
-- ----------------------------------------------------------------------------


do
    local book = unique_book_file()
    local opts = { device_id = "PHONE", device_label = "My Phone",
                   sync_progress = true }

    -- Plant existing remote progress (simulating "we already synced
    -- once with real data").  Write directly to the shared file so we
    -- can control the setup precisely.
    local p = Paths.shared_progress_path(book)
    JsonStore.write(p, {
        schema_version = 1,
        entries = {
            PHONE = { revision = 5, percent = 0.55, page = 100,
                      timestamp = 1000, device_id = "PHONE" },
        },
    })

    -- Now sync with a "freshly-opened, doc_settings not loaded" UI.
    local fresh_ui = make_fake_ui(book, { page = 1, total_pages = 0, percent = 0 })
    local r = Orchestrator.sync_book(fresh_ui, book, opts)

    h.assert_true(r.skipped, "fresh-open sync is skipped by failsafe")
    h.assert_equal(r.skipped_reason, "wipe_failsafe",
        "failsafe identifies itself as the skip reason")
    h.assert_false(r.ok, "skipped sync has ok=false")

    -- The shared file's content must NOT have been clobbered.
    local loaded = StateStore.load_shared(book)
    h.assert_equal(loaded.entries.PHONE.revision, 5,
        "shared file still at revision 5 (failsafe protected it)")
    h.assert_equal(loaded.entries.PHONE.percent, 0.55,
        "shared file percent preserved")
end


-- ----------------------------------------------------------------------------
-- Wipe failsafe: allow_wipe = true overrides
-- ----------------------------------------------------------------------------


do
    local book = unique_book_file()
    local p = Paths.shared_progress_path(book)
    JsonStore.write(p, {
        schema_version = 1,
        entries = {
            PHONE = { revision = 5, percent = 0.55, page = 100,
                      timestamp = 1000, device_id = "PHONE" },
        },
    })

    local fresh_ui = make_fake_ui(book, { page = 1, total_pages = 0, percent = 0 })
    local r = Orchestrator.sync_book(fresh_ui, book, {
        device_id = "PHONE", device_label = "My Phone",
        sync_progress = true,
        allow_wipe = true,
    })

    h.assert_true(r.ok, "allow_wipe overrides the failsafe")
    h.assert_false(r.skipped, "not skipped under allow_wipe")
    h.assert_equal(r.local_revision, 6, "revision bumped from 5 to 6")
end


-- ----------------------------------------------------------------------------
-- Master toggle off (sync_progress=false): no entry pushed, but file
-- is still loaded and conflicts still resolved
-- ----------------------------------------------------------------------------


do
    local book = unique_book_file()
    local p = Paths.shared_progress_path(book)
    JsonStore.write(p, {
        schema_version = 1,
        entries = {
            OTHER = { revision = 3, percent = 0.30, page = 50,
                      timestamp = 2000, device_id = "OTHER" },
        },
    })

    local ui = make_fake_ui(book, { page = 80, total_pages = 200, percent = 0.40 })
    local r = Orchestrator.sync_book(ui, book, {
        device_id = "PHONE",
        device_label = "My Phone",
        sync_progress = false,    -- master off
    })

    h.assert_true(r.ok, "sync_progress=false still returns ok=true")
    h.assert_equal(r.local_revision, 0, "no local entry pushed")
    h.assert_equal(r.merged_entry_count, 1,
        "merged file has 1 entry (OTHER preserved, PHONE not added)")

    local loaded = StateStore.load_shared(book)
    h.assert_nil(loaded.entries.PHONE, "PHONE was NOT added to the file")
    h.assert_equal(loaded.entries.OTHER.revision, 3, "OTHER preserved")
end


-- ----------------------------------------------------------------------------
-- 3-way merge: device B advanced on another device → our sync picks up B's
-- ----------------------------------------------------------------------------


do
    local book = unique_book_file()
    local opts = { device_id = "PHONE", device_label = "My Phone",
                   sync_progress = true }

    -- First sync from PHONE establishes our entry + last-sync.
    local ui_a = make_fake_ui(book, { page = 30, total_pages = 200, percent = 0.15 })
    Orchestrator.sync_book(ui_a, book, opts)

    -- Now simulate device TABLET coming in via Syncthing: it writes
    -- its own entry into the shared file.
    local p = Paths.shared_progress_path(book)
    local loaded = StateStore.load_shared(book)
    loaded.entries.TABLET = { revision = 1, percent = 0.80, page = 160,
                              timestamp = 3000, device_id = "TABLET" }
    JsonStore.write(p, loaded)

    -- Second sync from PHONE: should adopt TABLET's entry and bump PHONE's.
    local ui_b = make_fake_ui(book, { page = 40, total_pages = 200, percent = 0.20 })
    local r = Orchestrator.sync_book(ui_b, book, opts)

    h.assert_true(r.ok, "merge sync succeeded")
    h.assert_equal(r.local_revision, 2, "PHONE bumped to revision 2")
    h.assert_equal(r.merged_entry_count, 2, "both PHONE and TABLET present")

    loaded = StateStore.load_shared(book)
    h.assert_equal(loaded.entries.PHONE.percent, 0.20, "PHONE has new percent")
    h.assert_equal(loaded.entries.TABLET.percent, 0.80, "TABLET preserved")
    h.assert_equal(loaded.entries.TABLET.revision, 1, "TABLET still at rev 1")
end


-- ----------------------------------------------------------------------------
-- Conflict resolution: a *.sync-conflict-* file gets merged in
-- ----------------------------------------------------------------------------


do
    local book = unique_book_file()
    local p = Paths.shared_progress_path(book)

    -- Establish the main file via a sync.
    local ui = make_fake_ui(book, { page = 10, total_pages = 200, percent = 0.05 })
    Orchestrator.sync_book(ui, book, {
        device_id = "PHONE", device_label = "My Phone",
        sync_progress = true,
    })

    -- Plant a Syncthing conflict file next to the main file with a
    -- different device's entry.
    local conflict_path = p:gsub("%.json$",
        ".sync-conflict-20251101-120000-TAB.json")
    JsonStore.write(conflict_path, {
        schema_version = 1,
        entries = {
            TABLET = { revision = 7, percent = 0.70, page = 140,
                       timestamp = 4000, device_id = "TABLET" },
        },
    })

    -- Sync again: the conflict resolver should fold TABLET into the
    -- main file and delete the conflict file.
    local ui2 = make_fake_ui(book, { page = 20, total_pages = 200, percent = 0.10 })
    local r = Orchestrator.sync_book(ui2, book, {
        device_id = "PHONE", device_label = "My Phone",
        sync_progress = true,
    })

    h.assert_true(r.ok, "sync with conflict file succeeds")
    h.assert_equal(r.conflicts_found, 1, "found one conflict file")
    h.assert_equal(r.conflicts_merged, 1, "merged the conflict file")

    -- Conflict file should be gone.
    local f = io.open(conflict_path, "rb")
    h.assert_nil(f, "conflict file was deleted after successful merge")
    if f then f:close() end

    -- Merged file should have both devices.
    local loaded = StateStore.load_shared(book)
    h.assert_true(loaded.entries.PHONE ~= nil,  "PHONE still present")
    h.assert_true(loaded.entries.TABLET ~= nil, "TABLET adopted from conflict")
    h.assert_equal(loaded.entries.TABLET.revision, 7,
        "TABLET's revision from the conflict file")
end


-- ----------------------------------------------------------------------------
-- preview_local_entry returns what we'd push without any I/O
-- ----------------------------------------------------------------------------


do
    local book = unique_book_file()
    local ui   = make_fake_ui(book, { page = 99, total_pages = 200,
                                       percent = 0.495, xpath = "/x" })

    local preview = Orchestrator.preview_local_entry(ui, {
        device_label = "My Phone"
    })

    h.assert_true(preview ~= nil, "preview returns a non-nil entry")
    h.assert_equal(preview.page, 99, "preview captures page")
    h.assert_equal(preview.percent, 0.495, "preview captures percent")
    h.assert_equal(preview.label, "My Phone", "preview captures device label")
    h.assert_nil(preview.revision,
        "preview does NOT stamp revision (only sync does)")
    h.assert_nil(preview.timestamp,
        "preview does NOT stamp timestamp (only sync does)")

    -- Preview must not have written anything.
    local p = Paths.shared_progress_path(book)
    local on_disk, diag = JsonStore.read(p)
    h.assert_nil(on_disk, "preview did not write a shared file")
    h.assert_equal(diag, "not_found", "shared file genuinely doesn't exist")
end


-- ----------------------------------------------------------------------------
-- Injected providers: clock + bridge can be swapped for testing
-- ----------------------------------------------------------------------------


do
    local book = unique_book_file()
    local ui   = make_fake_ui(book, { page = 10, total_pages = 100, percent = 0.10 })

    local fake_clock = function() return 12345 end
    local r = Orchestrator.sync_book_with_providers(ui, book, {
        device_id = "PHONE", device_label = "My Phone",
        sync_progress = true,
    }, { clock = fake_clock })

    h.assert_true(r.ok, "sync with injected clock succeeds")
    local loaded = StateStore.load_shared(book)
    h.assert_equal(loaded.entries.PHONE.timestamp, 12345,
        "injected clock value lands on the entry")
end


-- ----------------------------------------------------------------------------
-- Wipe failsafe edge case: remote also at percent=0/page=1 → NOT a wipe
-- (otherwise a brand-new book opening for the first time would refuse
-- to record its starting position)
-- ----------------------------------------------------------------------------


do
    local book = unique_book_file()
    local p = Paths.shared_progress_path(book)
    JsonStore.write(p, {
        schema_version = 1,
        entries = {
            PHONE = { revision = 1, percent = 0, page = 1,
                      timestamp = 100, device_id = "PHONE" },
        },
    })

    local ui = make_fake_ui(book, { page = 1, total_pages = 200, percent = 0 })
    local r = Orchestrator.sync_book(ui, book, {
        device_id = "PHONE", device_label = "My Phone",
        sync_progress = true,
    })

    h.assert_true(r.ok,
        "saving zero-progress over zero-progress is NOT a wipe")
    -- Position unchanged (page 1 over page 1) → idempotent no-op: the wipe
    -- failsafe correctly does NOT fire (remote isn't real progress), and the
    -- upsert does NOT bump (nothing moved). The two are separate axes now.
    h.assert_equal(r.local_revision, 1, "unchanged position → no-op, revision not bumped")
end


-- ----------------------------------------------------------------------------
-- Empty local map merged with non-empty remote: remote entries are kept
-- (this ensures "another device wrote something we haven't seen yet" works)
-- ----------------------------------------------------------------------------


do
    local book = unique_book_file()
    local p = Paths.shared_progress_path(book)

    JsonStore.write(p, {
        schema_version = 1,
        entries = {
            STAR = { revision = 9, percent = 0.95, page = 190,
                     timestamp = 50000, device_id = "STAR" },
        },
    })

    -- PHONE is brand-new for this book; the failsafe must NOT fire
    -- because PHONE has no remote entry yet.
    local ui = make_fake_ui(book, { page = 1, total_pages = 200, percent = 0 })
    local r = Orchestrator.sync_book(ui, book, {
        device_id = "PHONE", device_label = "My Phone",
        sync_progress = true,
    })

    h.assert_true(r.ok,
        "first-time PHONE sync against a non-empty remote (different device) works")
    h.assert_equal(r.merged_entry_count, 2,
        "both STAR and PHONE in the merged file")
    local loaded = StateStore.load_shared(book)
    h.assert_equal(loaded.entries.STAR.revision, 9,
        "STAR's entry preserved verbatim")
end
