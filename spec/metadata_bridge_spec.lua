-- =============================================================================
-- spec/metadata_bridge_spec.lua
-- =============================================================================
--
-- Smoke tests for syncery_ann/metadata_bridge.lua.  The module is ~600
-- lines and has six field handlers; this spec doesn't try to cover
-- everything, it just nails down the core promises the orchestrator
-- depends on:
--
--   1. Reading from a fresh UI bumps the per-field timestamp once,
--      and a second read with no UI changes doesn't bump it.
--   2. Reading with the master toggle off returns an empty section.
--   3. apply_from_remote with strictly newer remote actually writes,
--      with equal/older it does not.
--   4. merge() is per-field newer-wins, with absent-on-one-side fields
--      preserved from the other side.
--   5. Fingerprinting normalizes list order so reordered collections
--      don't look like edits.
--
-- The spec uses the fake-UI helper from spec.test_helpers; we DON'T
-- run the real ReadCollection (collections field is skipped here).
-- =============================================================================

local h = require("spec.test_helpers")
h.setup()

local MetadataBridge = require("syncery_ann/metadata_bridge")
local StatusLattice  = require("syncery_ann/status_lattice")


-- ----------------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------------


local function full_toggles()
    return {
        master = true, status = true, rating = true, collections = false,
        summary = true, custom = true, handmade = true,
    }
end


--- Build a UI with summary fields preset (status / rating / note).
local function ui_with_summary(opts)
    return h.make_fake_ui({
        settings = {
            summary = {
                status = opts.status,
                rating = opts.rating,
                note   = opts.note,
            },
        },
    })
end


-- Model D status-entry builders (the status_lattice {generation, candidates}
-- shape).  st(gen, {value, dev}, ...) builds an entry; st1 is the single-
-- candidate case.  st_value / st_conflict read a merged section's status.
local function st(gen, ...)
    local cands = {}
    for _, v in ipairs({ ... }) do
        cands[#cands + 1] = { value = v[1], device_id = v[2], device_label = v[2] }
    end
    return { generation = gen, candidates = cands }
end
local function st1(gen, value, dev) return st(gen, { value, dev }) end
local function st_value(m)    return StatusLattice.resolved_value(m and m.status) end
local function st_conflict(m) return StatusLattice.is_conflict(m and m.status) end


-- ----------------------------------------------------------------------------
-- Tests
-- ----------------------------------------------------------------------------


-- ── Test 1: master toggle off → empty section, no UI reads ─────────


do
    local ui = ui_with_summary({ status = "reading", rating = 4 })
    local toggles = full_toggles()
    toggles.master = false

    local md = MetadataBridge.read_from_ui(
        ui, "/books/x.epub", toggles, "dev", "Dev")

    h.assert_deep_equal(md, {},
        "master off -> empty metadata section")
end


-- ── Test 2: read produces field entries; status is a lattice entry ──
--
-- Status is collected as a {generation, candidates} entry (status_lattice),
-- its generation classified against the ancestor; the other fields stay flat
-- {value, datetime_updated, ...} with "" datetime so a conflict in them falls
-- to the device-id tiebreak, not collect order.


do
    local ui = h.make_fake_ui({
        settings = { summary = { status = "reading", rating = 5 } },
    })
    -- No ancestor -> first status -> generation 0.
    local md = MetadataBridge.read_from_ui(
        ui, "/books/x.epub", full_toggles(), "phone", "Phone")

    h.assert_true(md.status ~= nil,                   "status field present")
    h.assert_equal(st_value(md), "reading",           "status value preserved")
    h.assert_equal(md.status.generation, 0,           "first status -> generation 0")
    h.assert_equal(md.status.candidates[1].device_id,    "phone", "device_id stamped")
    h.assert_equal(md.status.candidates[1].device_label, "Phone", "device_label stamped")

    h.assert_true(md.rating ~= nil,                   "rating field present")
    h.assert_equal(md.rating.value, 5,                "rating value preserved")
    h.assert_equal(md.rating.datetime_updated, "",
        "non-status field carries empty datetime (device-id tiebreak)")
end


-- ── Test 3: re-reading unchanged values is stable ──────────────────
--
-- A sync must not make a field look "newer" just by re-reading it.  For
-- status, stability is the generation: an unchanged status against the same
-- ancestor carries the same generation; the other fields stay "".


do
    local ui = h.make_fake_ui({
        settings = { summary = { status = "reading", rating = 5 } },
    })
    local anc = { status = st1(0, "reading", "phone") }
    local first  = MetadataBridge.read_from_ui(
        ui, "/books/x.epub", full_toggles(), "phone", "Phone", anc)
    local second = MetadataBridge.read_from_ui(
        ui, "/books/x.epub", full_toggles(), "phone", "Phone", anc)

    h.assert_equal(second.status.generation, first.status.generation,
        "unchanged status carries the same generation across re-read")
    h.assert_equal(st_value(second), st_value(first),
        "unchanged status keeps its value across re-read")
    h.assert_equal(second.rating.datetime_updated,
                   first.rating.datetime_updated,
        "rating datetime stable across re-read (always empty)")
end


-- ── Test 4: status generation is classified against the ancestor ───
--
-- A FORWARD lifecycle move (reading -> complete) carries the ancestor's
-- generation; a REOPEN (complete -> reading) bumps it so it dominates the
-- value it overrides.  This is collect-time classification (read_from_ui), the
-- heart of the clock-free Model D resolution.


do
    -- forward: ancestor reading@0, live complete -> generation stays 0
    local ui_fwd = h.make_fake_ui({ settings = { summary = { status = "complete" } } })
    local fwd = MetadataBridge.read_from_ui(
        ui_fwd, "/books/x.epub", full_toggles(), "phone", "Phone",
        { status = st1(0, "reading", "phone") })
    h.assert_equal(st_value(fwd), "complete",   "forward move adopts the new value")
    h.assert_equal(fwd.status.generation, 0,    "forward move carries the generation")

    -- reopen: ancestor complete@0, live reading -> generation bumps to 1
    local ui_re = h.make_fake_ui({ settings = { summary = { status = "reading" } } })
    local reopen = MetadataBridge.read_from_ui(
        ui_re, "/books/x.epub", full_toggles(), "phone", "Phone",
        { status = st1(0, "complete", "phone") })
    h.assert_equal(st_value(reopen), "reading",  "reopen adopts the new value")
    h.assert_equal(reopen.status.generation, 1,  "reopen bumps the generation (dominates)")
end


-- ── Test 5: nil values are not emitted ─────────────────────────────


do
    local ui = ui_with_summary({})   -- nothing set

    local md = MetadataBridge.read_from_ui(
        ui, "/books/x.epub", full_toggles(), "p", "P")

    h.assert_nil(md.status,
        "no status set -> no status entry (would not overwrite remote)")
    h.assert_nil(md.rating,
        "no rating set -> no rating entry")
    h.assert_nil(md.summary_note,
        "no note set -> no summary_note entry")
end


-- ── Test 6: apply adopts a field whose merged value differs from local ─
--
-- apply_from_remote receives the ALREADY-merged metadata; its job is to make
-- KOReader match it.  A RESOLVED status (single candidate) is written when it
-- differs from this device's value; no timestamp is consulted.


do
    local stored = { summary = { status = "reading" } }
    local ui = h.make_fake_ui({ settings = stored })

    local merged = { status = st1(0, "complete", "B") }   -- resolved

    local changed, applied = MetadataBridge.apply_from_remote(
        ui, "/books/x.epub", merged, full_toggles())

    h.assert_true(changed,                            "apply reports a change")
    h.assert_true(applied.status,                     "status field marked applied")
    h.assert_equal(stored.summary.status, "complete", "summary.status overwritten")
end


-- ── Test 7: apply no-ops when the merged value equals local ────────
--
-- A field this device already holds (e.g. one it itself won) must not be
-- re-reported as a change.  For status, _apply_status no-ops when the live
-- value already equals the resolved value.


do
    local stored = { summary = { status = "reading" } }
    local ui = h.make_fake_ui({ settings = stored })

    local merged = { status = st1(0, "reading", "B") }   -- resolved, equals local

    local changed, applied = MetadataBridge.apply_from_remote(
        ui, "/books/x.epub", merged, full_toggles())

    h.assert_false(changed,                           "no change when merged == local")
    h.assert_nil(applied.status,                      "status not in applied set")
    h.assert_equal(stored.summary.status, "reading",  "summary.status unchanged")
end


-- ── Test 7b: apply does NOT write an unresolved status conflict ────
--
-- When the merged status is still a conflict (complete vs abandoned at the
-- same generation), apply leaves the local value untouched -- each device
-- keeps its own choice until the user resolves it.  See
-- docs/SYNC_CONFLICT_STRATEGY.md §9.


do
    local stored = { summary = { status = "reading" } }
    local ui = h.make_fake_ui({ settings = stored })

    local merged = { status = st(0, { "complete", "A" }, { "abandoned", "B" }) }
    h.assert_true(st_conflict(merged), "precondition: merged status is a conflict")

    local changed, applied = MetadataBridge.apply_from_remote(
        ui, "/books/x.epub", merged, full_toggles())

    h.assert_false(changed,                           "a conflict applies nothing")
    h.assert_nil(applied.status,                      "status not in applied set on conflict")
    h.assert_equal(stored.summary.status, "reading",
        "local status preserved while the conflict is unresolved")
end


-- ── Test 7c: apply updates the BookList cache for status/rating ────
--
-- KOReader keeps the FileManager/History badge fresh by calling
-- BookList.setBookInfoCacheProperty at each status/rating mutation
-- (readerstatus.markBook).  Syncery must mirror that when it applies a synced
-- change, or the badge stays stale until the book is reopened.  Observed by
-- injecting a recording BookList via package.loaded -- the production code
-- does a guarded require, which otherwise fails (no-ops) in the headless suite.


do
    local recorded = {}
    package.loaded["ui/widget/booklist"] = {
        setBookInfoCacheProperty = function(file, prop, value)
            table.insert(recorded, { file = file, prop = prop, value = value })
        end,
    }

    -- status change -> exactly one cache update carrying the new status
    local ui_s = h.make_fake_ui({ settings = { summary = { status = "reading" } } })
    MetadataBridge._apply_status(ui_s, "/books/x.epub", "complete")
    h.assert_equal(#recorded, 1,                  "status change updates the cache once")
    h.assert_equal(recorded[1].file, "/books/x.epub", "cache update carries the book file")
    h.assert_equal(recorded[1].prop, "status",    "cache update targets the status property")
    h.assert_equal(recorded[1].value, "complete", "cache update carries the new status")

    -- rating change -> one more cache update carrying the new rating
    local ui_r = h.make_fake_ui({ settings = { summary = { rating = 2 } } })
    MetadataBridge._apply_rating(ui_r, "/books/x.epub", 5)
    h.assert_equal(#recorded, 2,                  "rating change updates the cache")
    h.assert_equal(recorded[2].prop, "rating",    "cache update targets the rating property")
    h.assert_equal(recorded[2].value, 5,          "cache update carries the new rating")

    -- a no-op apply (value already matches) must NOT touch the cache
    MetadataBridge._apply_status(ui_s, "/books/x.epub", "complete")
    h.assert_equal(#recorded, 2,                  "an unchanged status does not touch the cache")

    package.loaded["ui/widget/booklist"] = nil
end


-- ── Test 7d: collections apply PERSISTS via ReadCollection:write ────
--
-- addRemoveItemMultiple only mutates ReadCollection's in-memory model;
-- KOReader persists collection edits via the collection UI's close handler
-- (which Syncery doesn't go through) and ReadCollection has no flush-on-exit,
-- so without an explicit write() the synced membership is lost on restart.


do
    local calls = { add = false, write = false, file = nil, desired = nil }
    local membership = {}   -- file -> { coll -> true }; models ReadCollection.coll
    package.loaded["readcollection"] = {
        addRemoveItemMultiple = function(_self, file, desired)
            calls.add = true; calls.file = file; calls.desired = desired
            -- set-semantics; here every desired collection exists, so the book
            -- lands in exactly `desired`.
            membership[file] = {}
            for coll in pairs(desired) do membership[file][coll] = true end
        end,
        getCollectionsWithFile = function(_self, file)
            return membership[file] or {}
        end,
        write = function(_self) calls.write = true end,
    }

    local changed = MetadataBridge._apply_collections(
        nil, "/books/x.epub", { "Favorites", "Sci-fi" })

    h.assert_true(calls.add,   "collections apply updates the in-memory model (addRemoveItemMultiple)")
    h.assert_equal(calls.file, "/books/x.epub", "addRemoveItemMultiple gets the book file")
    h.assert_true(calls.desired and calls.desired["Favorites"] and calls.desired["Sci-fi"],
        "desired set carries the remote collection names")
    h.assert_true(calls.write, "collections apply persists via ReadCollection:write (else lost on restart)")
    h.assert_true(changed,     "collections apply reports success when membership took effect")

    package.loaded["readcollection"] = nil
end


-- ── Test 7e: collections apply reports FALSE on a silent no-op ──────
--
-- addRemoveItemMultiple returns nothing and can no-op (e.g. the book_file no
-- longer resolves to a collection entry).  _apply_collections must verify via
-- getCollectionsWithFile and report false rather than a false success (BUG-3).


do
    package.loaded["readcollection"] = {
        addRemoveItemMultiple = function(_self, _file, _desired) end,  -- silent no-op
        getCollectionsWithFile = function(_self, _file) return {} end, -- nothing landed
        write = function(_self) end,
    }

    local changed = MetadataBridge._apply_collections(
        nil, "/books/x.epub", { "Favorites" })

    h.assert_false(changed,
        "BUG-3: collections apply reports false when the membership did not take effect")

    package.loaded["readcollection"] = nil
end


-- ── Test 7f: apply falls back to pcall-success without the read API ─
--
-- An older core may lack getCollectionsWithFile; we then can't verify, so a
-- non-throwing apply still reports success (no regression).


do
    package.loaded["readcollection"] = {
        addRemoveItemMultiple = function(_self, _file, _desired) end,
        write = function(_self) end,
        -- no getCollectionsWithFile
    }

    local changed = MetadataBridge._apply_collections(
        nil, "/books/x.epub", { "Favorites" })

    h.assert_true(changed,
        "collections apply falls back to pcall-success without getCollectionsWithFile")

    package.loaded["readcollection"] = nil
end


-- ── Test 8: merge() resolves each field per its own rule ───────────
--
-- The 2-way merge (conflict-resolver path) routes status through the lattice
-- and every other field through the date/device-id tiebreak.


do
    local md_a = {
        status = st1(0, "reading", "A"),
        rating = { value = 3, datetime_updated = "2024-06-01 00:00:00" },
    }
    local md_b = {
        status = st1(0, "complete", "B"),
        rating = { value = 5, datetime_updated = "2024-01-01 00:00:00" },
    }

    local merged = MetadataBridge.merge(md_a, md_b)
    h.assert_equal(st_value(merged), "complete",
        "status: forward state wins via the lattice (finished anywhere)")
    h.assert_equal(merged.rating.value, 3,
        "rating: newer date wins (generic tiebreak)")
end


-- ── Test 8b: merge() surfaces the one true status conflict ─────────
--
-- With no ancestor and the same generation, complete vs abandoned is the only
-- genuinely ambiguous case -> the lattice yields a 2-candidate CONFLICT (not a
-- silent rank pick).  A non-status conflict still falls to device-id.  Both
-- are symmetric (argument order is irrelevant).


do
    local md_a = {
        status = st1(0, "complete",  "dev_A"),
        rating = { value = 3, datetime_updated = "", device_id = "dev_A" },
    }
    local md_b = {
        status = st1(0, "abandoned", "dev_B"),
        rating = { value = 5, datetime_updated = "", device_id = "dev_B" },
    }

    local merged = MetadataBridge.merge(md_a, md_b)
    h.assert_true(st_conflict(merged),
        "complete vs abandoned at the same generation -> surfaced conflict")
    h.assert_equal(merged.rating.value, 5,
        "non-status same-date conflict -> higher device-id wins")

    -- Argument order is irrelevant (the lattice merge is commutative).
    local merged2 = MetadataBridge.merge(md_b, md_a)
    h.assert_true(st_conflict(merged2),         "status conflict symmetric")
    h.assert_equal(merged2.rating.value, 5,     "rating tiebreak symmetric")
end


-- ── Test 9: merge() keeps fields present on only one side ─────────


do
    local md_a = {
        status = st1(0, "reading", "A"),
    }
    local md_b = {
        rating = { value = 5, datetime_updated = "2024-01-01 00:00:00" },
    }
    local merged = MetadataBridge.merge(md_a, md_b)
    h.assert_equal(st_value(merged), "reading", "a-only status preserved")
    h.assert_equal(merged.rating.value, 5,       "b-only rating preserved")
end


-- ── Test 10: merge() tolerates nil / empty inputs ─────────────────


do
    h.assert_deep_equal(MetadataBridge.merge(nil, nil),  {},  "both nil -> empty")
    h.assert_deep_equal(MetadataBridge.merge({},  nil),  {},  "b nil  -> a")
    h.assert_deep_equal(MetadataBridge.merge(nil, {}),   {},  "a nil  -> b")
end


-- ── Test 11: list fingerprint is order-insensitive ────────────────
--
-- Collections come from a hash table — order is undefined.  Re-reading
-- the same collections in different order must NOT look like an edit.

do
    -- We exercise _fingerprint_value directly because exercising
    -- through collections requires the ReadCollection global.
    local fp_a = MetadataBridge._fingerprint_value({"Sci-Fi", "Favorites"})
    local fp_b = MetadataBridge._fingerprint_value({"Favorites", "Sci-Fi"})
    h.assert_equal(fp_a, fp_b,
        "list fingerprint is order-insensitive")
end


-- ── Test 12: make_toggles_from_plugin defaults ────────────────────


do
    local t = MetadataBridge.make_toggles_from_plugin(nil)
    h.assert_true(t.master,      "nil plugin -> master on")
    h.assert_true(t.status,      "nil plugin -> status on")
    h.assert_true(t.rating,      "nil plugin -> rating on")
    h.assert_true(t.collections, "nil plugin -> collections on")
end


-- ── Test 13: handmade_toc is receive-only (never auto-sent) ───────
--
-- A handmade TOC is a large hand-built artifact; an LWW auto-overwrite
-- could silently destroy real work, so it is NEVER auto-pushed by the
-- metadata read — only by the explicit manual push.  Even on a rolling
-- document with a TOC present and the toggle on, read_from_ui must omit
-- handmade_toc from the outgoing section.

do
    local stored = {
        handmade_toc = {{ title = "Ch 1", xpointer = "/body/DocFragment[1]", depth = 1 }},
        handmade_toc_enabled = true,
    }
    local ui = h.make_fake_ui({ paging = false, settings = stored })

    local md = MetadataBridge.read_from_ui(
        ui, "/books/x.epub", full_toggles(), "p", "P")
    h.assert_nil(md.handmade_toc,
        "handmade_toc is receive-only: never auto-sent by read_from_ui")
end


-- ── Test 14: apply handmade TOC writes the real KOReader keys ──────
--
-- KOReader reads the TOC from the "handmade_toc" doc-setting (the list
-- itself, NOT a "handmade".toc wrapper) gated by "handmade_toc_enabled".
-- Applying a remote TOC must write BOTH, update the live module, and
-- trigger a rebuild via setupToc.

do
    local rebuilt = false
    local ui = h.make_fake_ui({
        paging   = false,
        settings = {},
        handmade = {
            toc         = {},
            toc_enabled = false,
            setupToc    = function(_self) rebuilt = true end,
        },
    })
    local remote = {{ title = "Intro", xpointer = "/body/DocFragment[1]", depth = 1 }}

    local changed = MetadataBridge._apply_handmade_toc(ui, "/books/x.epub", remote)

    h.assert_true(changed, "apply reports a change")
    h.assert_equal(type(ui._settings.handmade_toc), "table",
        "handmade_toc list persisted")
    h.assert_equal(ui._settings.handmade_toc[1].title, "Intro",
        "persisted TOC carries the remote entry")
    h.assert_true(ui._settings.handmade_toc_enabled,
        "handmade_toc_enabled set so the TOC renders")
    h.assert_nil(ui._settings.handmade,
        "phantom 'handmade' key NOT written")
    h.assert_equal(ui.handmade.toc[1].title, "Intro",
        "live module toc updated")
    h.assert_true(ui.handmade.toc_enabled,
        "live module toc_enabled set")
    h.assert_true(rebuilt,
        "setupToc() called to rebuild the displayed TOC")
end


-- ── Test 15: apply handmade TOC echo guard (identical = no-op) ─────
--
-- If the live document already holds this exact TOC (our own pushed TOC
-- coming back on the next pull), apply must do nothing: no write, no
-- rebuild, and the local enable state is left untouched.  The content
-- compare must see through distinct table identities (same fields).

do
    local rebuilt = false
    local incoming = {{ title = "Intro", xpointer = "/body/DocFragment[1]", depth = 1 }}
    local ui = h.make_fake_ui({
        paging   = false,
        settings = {},
        handmade = {
            -- structurally identical to `incoming`, but a different table
            toc         = {{ title = "Intro", xpointer = "/body/DocFragment[1]", depth = 1 }},
            toc_enabled = false,   -- user disabled locally; must stay false
            setupToc    = function(_self) rebuilt = true end,
        },
    })

    local changed = MetadataBridge._apply_handmade_toc(ui, "/books/x.epub", incoming)

    h.assert_false(changed, "identical TOC reports no change")
    h.assert_nil(ui._settings.handmade_toc,
        "no persist on echo (nothing written)")
    h.assert_false(ui.handmade.toc_enabled,
        "local enable state preserved on echo (not forced true)")
    h.assert_false(rebuilt, "no rebuild on echo")
end


-- ============================================================================
-- 3-way metadata merge: STATUS via the lattice, other fields via the ancestor
-- ============================================================================
--
-- three_way routes status through status_lattice.merge (clock-free 2-way; the
-- ancestor is moot for status because the generation already encodes
-- causality) and every other field through the ancestor comparison.  See
-- docs/SYNC_CONFLICT_STRATEGY.md §9 and docs/METADATA_3WAY_MERGE_DESIGN.md.

local function mk(value, date, dev)
    return { value = value, datetime_updated = date, device_id = dev }
end


-- Status agreement: both sides hold the same value -> kept.
do
    local m = MetadataBridge.three_way(
        { status = st1(0, "complete", "A") },
        { status = st1(0, "complete", "B") },
        { status = st1(0, "reading",  "X") })
    h.assert_equal(st_value(m), "complete", "3-way status: agreeing sides keep the value")
end


-- Status forward-wins: reading vs complete (same generation) -> complete.
-- "Finished anywhere => finished"; the ancestor never enters the decision.
do
    local m = MetadataBridge.three_way(
        { status = st1(0, "reading",  "A") },
        { status = st1(0, "complete", "B") },
        { status = st1(0, "reading",  "X") })
    h.assert_equal(st_value(m), "complete", "3-way status: forward state wins (finished anywhere)")
end


-- THE REPORTED BUG (the user's real sidecars): Phone marked complete, Kindle
-- is still reading and re-saved with a LATER timestamp.  The old date-LWW merge
-- picked Kindle's reading and clobbered complete.  The lattice picks complete
-- because complete > reading -- timestamps are never consulted.
do
    local m = MetadataBridge.three_way(
        { status = st1(0, "complete", "Phone") },
        { status = st1(0, "reading",  "Kindle") },
        { status = st1(0, "reading",  "Kindle") })
    h.assert_equal(st_value(m), "complete",
        "3-way status: a still-reading remote never clobbers a real complete")
end


-- Generation dominance: a reopen (bumped generation) overrides a stale
-- complete -- the deliberate later move wins, clock-free.
do
    local m = MetadataBridge.three_way(
        { status = st1(0, "complete", "A") },
        { status = st1(1, "reading",  "B") },   -- B reopened: generation bumped
        { status = st1(0, "complete", "X") })
    h.assert_equal(st_value(m), "reading", "3-way status: higher generation (reopen) dominates")
end


-- The ONE true conflict: complete vs abandoned at the same generation are
-- incomparable terminal states -> surfaced as a 2-candidate conflict, never an
-- arbitrary pick.
do
    local m = MetadataBridge.three_way(
        { status = st1(0, "complete",  "dev_A") },
        { status = st1(0, "abandoned", "dev_B") },
        { status = st1(0, "reading",   "X") })
    h.assert_true(st_conflict(m),
        "3-way status: complete vs abandoned (same gen) is the only genuine conflict")
end


-- Conflict, non-status field, same date -> device-id (no precedence).
do
    local m = MetadataBridge.three_way(
        { rating = mk(3, "2026-06-15", "dev_A") },
        { rating = mk(5, "2026-06-15", "dev_B") },
        { rating = mk(1, "2026-06-01", "X") })
    h.assert_equal(m.rating.value, 5, "3-way conflict (non-status): higher device_id wins")
end


-- Absent local status = no opinion -> adopt remote (never a wipe).
do
    local m = MetadataBridge.three_way(
        {},
        { status = st1(0, "complete", "B") },
        { status = st1(0, "complete", "B") })
    h.assert_equal(st_value(m), "complete",
        "3-way status: absent local is no-opinion, adopts remote (no wipe)")
end


-- Absent remote, present local -> keep local.
do
    local m = MetadataBridge.three_way(
        { status = st1(0, "complete", "A") }, {}, {})
    h.assert_equal(st_value(m), "complete", "3-way status: present local kept when remote absent")
end


-- Absent on both -> field omitted entirely.
do
    local m = MetadataBridge.three_way({}, {}, { status = st1(0, "reading", "X") })
    h.assert_nil(m.status, "3-way status: absent on both sides is omitted")
end


-- First sync (EMPTY ancestor): the enabling-metadata-sync case still resolves
-- by the lattice -> reading vs complete -> complete (no ancestor needed).
do
    local m = MetadataBridge.three_way(
        { status = st1(0, "complete", "A") },
        { status = st1(0, "reading",  "B") },
        {})
    h.assert_equal(st_value(m), "complete",
        "3-way status first-sync (empty ancestor): forward state wins")
end


-- Convergence: the complete-vs-abandoned conflict is byte-identical from both
-- device perspectives -- the lattice merge is commutative, so no flip-flop.
do
    local A   = { status = st1(0, "complete",  "dev_A") }
    local B   = { status = st1(0, "abandoned", "dev_B") }
    local anc = { status = st1(0, "reading",   "X") }
    local from_a = MetadataBridge.three_way(A, B, anc)
    local from_b = MetadataBridge.three_way(B, A, anc)
    h.assert_true(st_conflict(from_a) and st_conflict(from_b),
        "3-way status conflict surfaces from both perspectives")
    h.assert_deep_equal(from_a.status, from_b.status,
        "3-way status conflict converges byte-identically (commutative)")
end


-- Set-valued field (collections): a reordered list equal to the ancestor must
-- NOT look like a change (fingerprint normalizes order) -> no false conflict,
-- and the newer remote stamp is moot because nothing moved off the ancestor.
do
    local m = MetadataBridge.three_way(
        { collections = mk({ "fav", "scifi" }, "2026-06-15", "A") },
        { collections = mk({ "scifi", "fav" }, "2026-06-16", "B") },
        { collections = mk({ "scifi", "fav" }, "2026-06-01", "X") })
    h.assert_deep_equal(m.collections.value, { "fav", "scifi" },
        "3-way: reordered set equals ancestor (no false conflict from key order)")
end


-- ============================================================================
-- METADATA CLEAR TOMBSTONE (Batch 1: S1 sentinel + S3 D2 + S2 clear-detection)
-- ============================================================================
-- A cleared non-status field is materialized as a tombstone ({deleted=true})
-- and must propagate in BOTH directions; the fingerprint sentinel keeps it
-- distinct from "absent" so _three_way_field doesn't treat a clear as no-opinion.

local function tomb(date, dev)
    return { deleted = true, datetime_updated = date or "", device_id = dev }
end

-- S1: local clear propagates (tombstone wins over the value it replaced).
do
    local m = MetadataBridge.three_way(
        { rating = tomb("", "A") },     -- local cleared
        { rating = mk(4, "", "B") },    -- remote still has the value
        { rating = mk(4, "", "X") })    -- ancestor had the value
    h.assert_true(m.rating ~= nil and m.rating.deleted == true,
        "clear-tombstone: local clear propagates (tombstone wins)")
end

-- S1: remote clear adopted (the direction the nil-fingerprint bug missed).
do
    local m = MetadataBridge.three_way(
        { rating = mk(4, "", "A") },    -- local still has the value
        { rating = tomb("", "B") },     -- remote cleared
        { rating = mk(4, "", "X") })    -- ancestor had the value
    h.assert_true(m.rating ~= nil and m.rating.deleted == true,
        "clear-tombstone: remote clear adopted (tombstone wins)")
end

-- Both sides cleared -> a tombstone survives.
do
    local m = MetadataBridge.three_way(
        { rating = tomb("", "A") },
        { rating = tomb("", "B") },
        { rating = mk(4, "", "X") })
    h.assert_true(m.rating ~= nil and m.rating.deleted == true,
        "clear-tombstone: both clear -> tombstone")
end

-- Re-add after a clear: a new value beats the old tombstone ancestor.
do
    local m = MetadataBridge.three_way(
        { rating = tomb("", "A") },     -- local still cleared
        { rating = mk(7, "", "B") },    -- remote re-added a value
        { rating = tomb("", "X") })     -- ancestor was the clear
    h.assert_equal(m.rating and m.rating.value, 7,
        "clear-tombstone: remote re-add after clear -> value wins")
end

-- S3 (D2): a clear vs a concurrent DIFFERENT-value edit, same datetime "" ->
-- the clear wins on the tie (mirrors the annotation delete-on-tie pick).
do
    local m = MetadataBridge.three_way(
        { rating = tomb("", "A") },     -- local cleared
        { rating = mk(9, "", "B") },    -- remote set a different value
        { rating = mk(5, "", "X") })    -- ancestor was yet another value
    h.assert_true(m.rating ~= nil and m.rating.deleted == true,
        "clear-tombstone D2: clear beats a concurrent edit on a tie")
end

-- S3 (D2): the tombstone-on-tie pick is symmetric (same winner either order).
do
    local w1 = MetadataBridge._metadata_tiebreak("rating", tomb("", "A"), mk(9, "", "B"))
    local w2 = MetadataBridge._metadata_tiebreak("rating", mk(9, "", "B"), tomb("", "A"))
    h.assert_true(w1.deleted == true and w2.deleted == true,
        "clear-tombstone D2: tombstone-on-tie pick is symmetric")
end

-- A value never collides with the tombstone sentinel.
do
    local m = MetadataBridge.three_way(
        { rating = mk("hello", "", "A") },
        { rating = mk("hello", "", "B") },
        { rating = mk("x", "", "X") })
    h.assert_equal(m.rating and m.rating.value, "hello",
        "clear-tombstone: a value never collides with the sentinel")
end

-- S2: _detect_field_clear materializes a tombstone for a toggled-ON field that
-- was in the ancestor and is now absent.
do
    local md = {}
    MetadataBridge._detect_field_clear(md, { rating = mk(4, "", "X") },
        "rating", true, "A", "Acer")
    h.assert_true(md.rating ~= nil and md.rating.deleted == true,
        "clear-detection: cleared toggled-on field -> tombstone")
    h.assert_equal(md.rating.datetime_updated, "",
        "clear-detection: fresh tombstone carries empty datetime")
end

-- S2 INVARIANT: a toggled-OFF field is absent = no-opinion, NEVER a tombstone
-- (this is what keeps per-field filtering safe).
do
    local md = {}
    MetadataBridge._detect_field_clear(md, { rating = mk(4, "", "X") },
        "rating", false, "A", "Acer")
    h.assert_nil(md.rating,
        "clear-detection INVARIANT: toggled-off field -> no tombstone")
end

-- S2: an existing ancestor tombstone is carried forward without a re-stamp, as
-- a COPY (not the ancestor table).
do
    local md = {}
    local existing = { deleted = true, datetime_updated = "2026-01-01",
                       device_id = "B", device_label = "Kobo" }
    MetadataBridge._detect_field_clear(md, { rating = existing },
        "rating", true, "A", "Acer")
    h.assert_true(md.rating ~= nil and md.rating.deleted == true,
        "clear-detection: carry forward an existing tombstone")
    h.assert_equal(md.rating.datetime_updated, "2026-01-01",
        "clear-detection: carry forward does NOT re-stamp")
    h.assert_true(md.rating ~= existing,
        "clear-detection: carry forward COPIES (not the ancestor table)")
end

-- S2: a field the ancestor never carried is not a clear.
do
    local md = {}
    MetadataBridge._detect_field_clear(md, {}, "rating", true, "A", "Acer")
    h.assert_nil(md.rating,
        "clear-detection: never-synced field -> no tombstone")
end

-- S2: no ancestor at all (first sync / backfill) -> never fabricate a clear.
do
    local md = {}
    MetadataBridge._detect_field_clear(md, nil, "rating", true, "A", "Acer")
    h.assert_nil(md.rating,
        "clear-detection: nil ancestor (backfill) -> no tombstone")
end


-- ============================================================================
-- METADATA CLEAR TOMBSTONE (Batch 2: S4 apply clear paths + F6/F7/F5)
-- ============================================================================

-- S4a: _apply_rating_clear -> summary.rating = nil + cache 0 (KOReader un-rate).
do
    local recorded = {}
    package.loaded["ui/widget/booklist"] = {
        setBookInfoCacheProperty = function(file, prop, value)
            table.insert(recorded, { prop = prop, value = value })
        end,
    }
    local ui = h.make_fake_ui({ settings = { summary = { rating = 4, status = "reading" } } })
    local changed = MetadataBridge._apply_rating_clear(ui, "/books/x.epub")
    h.assert_true(changed, "rating clear: returns changed")
    h.assert_nil(ui._settings.summary.rating, "rating clear: summary.rating set to nil")
    h.assert_equal(ui._settings.summary.status, "reading", "rating clear: status untouched")
    h.assert_equal(recorded[#recorded].prop, "rating", "rating clear: cache targets rating")
    h.assert_equal(recorded[#recorded].value, 0, "rating clear: cache set to 0 (KOReader un-rate), not nil")

    -- already clear -> no-op (no cache touch)
    local n = #recorded
    local ui2 = h.make_fake_ui({ settings = { summary = { status = "reading" } } })
    h.assert_false(MetadataBridge._apply_rating_clear(ui2, "/books/x.epub"),
        "rating clear: already-clear -> no-op")
    h.assert_equal(#recorded, n, "rating clear: no-op does not touch the cache")
end

-- S4d: a rating TOMBSTONE applied via apply_from_remote clears the local rating
-- (value-gated; reports applied.rating).
do
    package.loaded["ui/widget/booklist"] = { setBookInfoCacheProperty = function() end }
    local ui = h.make_fake_ui({ settings = { summary = { rating = 4 } } })
    local toggles = { master = true, rating = true, status = false,
                      collections = false, summary = false, custom = false, handmade = false }
    local changed, applied = MetadataBridge.apply_from_remote(
        ui, "/books/x.epub", { rating = { deleted = true, datetime_updated = "" } }, toggles)
    h.assert_true(changed, "apply tombstone: reports a change")
    h.assert_true(applied.rating == true, "apply tombstone: applied.rating recorded (clear counts)")
    h.assert_nil(ui._settings.summary.rating, "apply tombstone: local rating cleared")

    -- a device already clear -> the tombstone is a no-op (value-gate)
    local ui_clear = h.make_fake_ui({ settings = { summary = {} } })
    local _, applied2 = MetadataBridge.apply_from_remote(
        ui_clear, "/books/x.epub", { rating = { deleted = true } }, toggles)
    h.assert_nil(applied2.rating, "apply tombstone: already-clear device no-ops")
end

-- F6: a note clear writes nil (KOReader stores a cleared note as nil), not "".
do
    local ui = h.make_fake_ui({ settings = { summary = { note = "great book", rating = 4 } } })
    local changed = MetadataBridge._apply_summary_note(ui, "/books/x.epub", nil)
    h.assert_true(changed, "note clear: returns changed")
    h.assert_nil(ui._settings.summary.note, "note clear F6: summary.note set to nil (NOT empty string)")
    h.assert_equal(ui._settings.summary.rating, 4, "note clear: rating untouched")
end

-- S4b + F7 + F5: _apply_custom_clear nils the custom props, DELETES the sidecar
-- when empty (not flush), restores live doc_props from the backup, evicts cache.
do
    local removed = {}
    package.loaded["util"] = { splitFilePathName = function(p) return (p:gsub("/[^/]*$", "/")) end }
    package.loaded["ui/event"] = { new = function(_s, n, f) return { name = n } end }
    package.loaded["ui/uimanager"] = { broadcastEvent = function(_s, e) removed.broadcast = e and e.name end }
    local cprops = { title = "Custom T", authors = "Custom A", series_index = 2 }
    package.loaded["docsettings"] = {
        removeSidecarDir = function(dir) removed.dir = dir end,
        openSettingsFile = function(path)
            return {
                sidecar_file = path,
                readSetting = function(_s, k)
                    if k == "custom_props" then return cprops end
                    if k == "doc_props" then return { title = "Orig Title", authors = "Orig Author" } end
                end,
                saveSetting = function(_s, k, v) if k == "custom_props" then cprops = v end end,
                flushCustomMetadata = function() removed.flushed = true; return true end,
            }
        end,
    }
    local cache_reset = false
    local ui = h.make_fake_ui({ settings = {} })
    ui.doc_props = { title = "Custom T", authors = "Custom A" }
    ui.doc_settings.getCustomMetadataFile = function(_s, reset)
        if reset then cache_reset = true; return end
        return "/books/x.sdr/custom_metadata.lua"
    end
    local real_os_remove = os.remove
    os.remove = function(p) removed.file = p; return true end

    local persisted = MetadataBridge._apply_custom_clear(ui, "/books/x.epub")
    os.remove = real_os_remove  -- restore immediately

    h.assert_true(persisted, "custom clear: returns persisted")
    h.assert_nil(cprops.title, "custom clear: title niled")
    h.assert_equal(removed.file, "/books/x.sdr/custom_metadata.lua",
        "custom clear F7: sidecar FILE removed (not flushed empty)")
    h.assert_true(removed.flushed == nil, "custom clear F7: did NOT flush an empty file")
    h.assert_true(cache_reset, "custom clear F7: getCustomMetadataFile(true) cache reset")
    h.assert_equal(ui.doc_props.title, "Orig Title", "custom clear F5: doc_props.title restored to original")
    h.assert_nil(ui.doc_props.series_index, "custom clear F5: cleared key with no original -> nil")
    h.assert_equal(removed.broadcast, "InvalidateMetadataCache", "custom clear: FileManager cache evicted")

    package.loaded["docsettings"] = nil
    package.loaded["util"] = nil
    package.loaded["ui/event"] = nil
    package.loaded["ui/uimanager"] = nil
end
