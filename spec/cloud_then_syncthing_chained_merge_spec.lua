-- =============================================================================
-- spec/cloud_then_syncthing_chained_merge_spec.lua
-- =============================================================================
--
-- Closes the undecided link in candidate A (PROJECT_PLAN.md 18.9.7 / 18.12.20
-- review): cloud-merged changes become visible via the Syncthing back-sync
-- path (_syncBookViaOrchestrator), which runs a SECOND merge with a DIFFERENT
-- ancestor (Syncthing's last_sync) than the cloud merge used (SyncService's
-- .sync). Two chained merges, two ancestors, one file. The proven 3-way
-- convergence is for ONE engine with ONE consistent ancestor; a CHAIN is not
-- automatically covered.
--
-- The dangerous outcomes to rule out:
--   (1) device B DELETES -> cloud brings the tombstone into canonical on A ->
--       the second (Syncthing) merge must NOT resurrect it (live UI still
--       shows it alive, Syncthing ancestor remembers it alive).
--   (2) device B CREATES -> cloud brings it alive into canonical on A -> the
--       second merge must ADOPT it, and a LATER chained merge must NOT
--       tombstone it as a "local deletion".
--
-- These run through the REAL annotation orchestrator + REAL merge engine, with
-- a doc_settings_bridge fake that faithfully models the write->read symmetry
-- (apply_and_refresh writes the live list; the next read_annotations_as_map
-- returns it) — because that symmetry is exactly what makes the chain safe.
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_chained_merge_spec_" .. tostring(os.time()))

local Orchestrator = require("syncery_ann/sync_orchestrator")

local function ann(ts, deleted)
    return {
        pos0 = "p0", pos1 = "p1", text = "note",
        datetime = "2026-01-01 00:00:00",
        datetime_updated = ts,
        deleted = deleted and true or false,
        device_id = "devB", device_label = "B",
    }
end
local KEY = "p0||p1"   -- Identity.compute_key for pos0="p0",pos1="p1"

-- Build a faithful fake set: the doc_settings "document" is a live keyed map
-- that apply_and_refresh WRITES (alive entries only, as KOReader would store)
-- and read_annotations_as_map READS back — the real write->read symmetry.
local function make_chain_fakes(initial)
    initial = initial or {}
    local fakes = {
        -- canonical (shared) — cloud reconcile writes here out-of-band.
        shared_state = initial.shared_state or {
            schema_version = 1, annotations = {}, metadata = {}, render_settings = {},
        },
        -- Syncthing's private ancestor.
        last_sync_state = initial.last_sync_state or {
            schema_version = 1, annotations = {}, metadata = {}, render_settings = {},
        },
        -- The LIVE document's annotation list, as a keyed map of ALIVE entries.
        live_doc = initial.live_doc or {},
        calls = {},
    }

    fakes.state_store = {
        load_shared    = function() return fakes.shared_state, "ok" end,
        load_last_sync = function() return fakes.last_sync_state, "ok" end,
        save_shared    = function(_b, state) fakes.shared_state = state; return true end,
        save_last_sync = function(_b, state) fakes.last_sync_state = state; return true end,
    }

    fakes.doc_settings_bridge = {
        read_annotations_as_map = function(_ui)
            -- Return a shallow copy of the live document's alive entries.
            local copy = {}
            for k, v in pairs(fakes.live_doc) do
                local e = {}; for fk, fv in pairs(v) do e[fk] = fv end
                copy[k] = e
            end
            return copy, 0
        end,
        apply_and_refresh = function(_ui, state_map, _options)
            -- Faithfully model KOReader: store ONLY alive entries (tombstones
            -- are filtered out by write_annotations_from_map in production),
            -- replacing the live list.
            local new_live = {}
            for k, v in pairs(state_map) do
                if v and not v.deleted then
                    local e = {}; for fk, fv in pairs(v) do e[fk] = fv end
                    new_live[k] = e
                end
            end
            fakes.live_doc = new_live
            return true, 0
        end,
    }

    -- Metadata / render bridges: no-op faithful stubs.
    fakes.metadata_bridge = {
        read_from_ui      = function() return {} end,
        merge             = function(a, _b) return a or {} end,
        three_way         = function(local_md, _remote, _ancestor) return local_md or {} end,
        apply_from_remote = function() return false, {} end,
    }
    fakes.render_settings_bridge = {
        read_from_ui      = function() return {} end,
        apply_from_remote = function() return false end,
        merge             = function(a, b) return a or b or {} end,
    }
    -- Conflict resolver: no Syncthing conflict files in these tests.
    fakes.conflict_resolver = { resolve_all = function() return 0, 0, nil end }

    return fakes
end

local function options()
    return {
        device_id = "devA", device_label = "A",
        toggles = {
            annotations = true, highlights = true, notes = true, bookmarks = true,
            metadata = true, render_settings = false,
        },
        tombstone_ttl_days = 30,
    }
end

local function count_alive(map)
    local n = 0
    for _, a in pairs(map or {}) do if a and not a.deleted then n = n + 1 end end
    return n
end


-- ----------------------------------------------------------------------------
-- (1) Peer DELETE must not resurrect through the second (Syncthing) merge.
--     Setup: A had the annotation alive and HAD synced it via Syncthing
--     (so live_doc has it AND last_sync remembers it alive). Cloud reconcile
--     then wrote a NEWER tombstone into canonical (shared_state). Now the user
--     opens the book -> _syncBookViaOrchestrator runs.
-- ----------------------------------------------------------------------------
do
    local fakes = make_chain_fakes({
        live_doc        = { [KEY] = ann("2026-01-01 00:00:00", false) },        -- UI still alive
        last_sync_state = { schema_version = 1, metadata = {}, render_settings = {},
                            annotations = { [KEY] = ann("2026-01-01 00:00:00", false) } },  -- ancestor alive
        shared_state    = { schema_version = 1, metadata = {}, render_settings = {},
                            annotations = { [KEY] = ann("2026-01-05 00:00:00", true) } },   -- cloud tombstone, newer
    })

    local res = Orchestrator.sync_book_with_providers(h.make_fake_ui({}), "/b.epub", options(), fakes)
    h.assert_true(res.ok, "(1) sync ok")
    h.assert_equal(count_alive(fakes.shared_state.annotations), 0,
        "(1) peer deletion stays deleted in canonical — NOT resurrected")
    h.assert_true(fakes.shared_state.annotations[KEY].deleted == true,
        "(1) tombstone preserved after the second merge")
    -- S1: the live document is no longer mutated in-session; the deletion is
    -- delivered to the live list at the next open (G).  The canonical
    -- tombstone preservation above is the invariant this test guards.
end


-- ----------------------------------------------------------------------------
-- (1b) Chain idempotency: run the SAME orchestrator merge a SECOND time
--      (another checkRemote tick). The tombstone must remain deleted; no flicker.
-- ----------------------------------------------------------------------------
do
    local fakes = make_chain_fakes({
        live_doc        = { [KEY] = ann("2026-01-01 00:00:00", false) },
        last_sync_state = { schema_version = 1, metadata = {}, render_settings = {},
                            annotations = { [KEY] = ann("2026-01-01 00:00:00", false) } },
        shared_state    = { schema_version = 1, metadata = {}, render_settings = {},
                            annotations = { [KEY] = ann("2026-01-05 00:00:00", true) } },
    })
    Orchestrator.sync_book_with_providers(h.make_fake_ui({}), "/b.epub", options(), fakes)
    -- Second tick — feeds the now-updated shared_state/last_sync/live_doc back in.
    local res2 = Orchestrator.sync_book_with_providers(h.make_fake_ui({}), "/b.epub", options(), fakes)
    h.assert_true(res2.ok, "(1b) second chained sync ok")
    h.assert_equal(count_alive(fakes.shared_state.annotations), 0,
        "(1b) tombstone STILL deleted after a second chained merge (no flicker)")
end


-- ----------------------------------------------------------------------------
-- (2) Peer CREATE arriving via cloud while the live UI does NOT yet have it.
--     The Syncthing visibility merge sees local-empty + canonical-nonempty +
--     last_sync-empty, which is the fresh-device condition.  fresh-device-adopt:
--     this is the unambiguously adopt-worthy case -- a live cloud annotation is
--     a genuine peer CREATE (a delete-that-synced would arrive as a TOMBSTONE,
--     not a live entry).  So the merge ADOPTS it SILENTLY (no prompt, no
--     allow_wipe needed): the create reaches canonical/merged_state and is
--     delivered to the live list at close (G).  See ANNOTATION_DELIVERY_DESIGN.md
--     DEVICE FACT 4.  Safe because S3 keeps the un-materialized pull out of the
--     ancestor, so the next tick does not synthesize a phantom tombstone (2b).
-- ----------------------------------------------------------------------------
do
    local fakes = make_chain_fakes({
        live_doc        = {},  -- A's UI doesn't have it yet
        last_sync_state = { schema_version = 1, metadata = {}, render_settings = {}, annotations = {} },
        shared_state    = { schema_version = 1, metadata = {}, render_settings = {},
                            annotations = { [KEY] = ann("2026-01-02 00:00:00", false) } },  -- cloud alive
    })

    local res = Orchestrator.sync_book_with_providers(h.make_fake_ui({}), "/b.epub", options(), fakes)
    h.assert_false(res.skipped, "(2) fresh device -> not skipped (peer CREATE adopted silently)")
    h.assert_nil(res.skipped_reason, "(2) no skip reason")
    -- The cloud create is adopted alive in canonical (NOT wiped, NOT skipped).
    h.assert_equal(count_alive(fakes.shared_state.annotations), 1,
        "(2) canonical keeps the cloud annotation alive (adopted)")
    h.assert_true(res.merged_state.annotations[KEY] ~= nil,
        "(2) annotation carried in merged_state for close-time delivery")
end


-- ----------------------------------------------------------------------------
-- (2b) With allow_wipe=true (the override path), the cloud annotation IS
--      adopted into canonical.  Under S1 it is NOT applied to the live doc
--      in-session (delivery is at close / G).  Under S3 the ancestor is kept
--      free of the un-materialized pull, so a SECOND chained merge must keep
--      it ALIVE in canonical (never a phantom tombstone), whether that merge
--      runs or skips via the failsafe.
-- ----------------------------------------------------------------------------
do
    local fakes = make_chain_fakes({
        live_doc        = {},
        last_sync_state = { schema_version = 1, metadata = {}, render_settings = {}, annotations = {} },
        shared_state    = { schema_version = 1, metadata = {}, render_settings = {},
                            annotations = { [KEY] = ann("2026-01-02 00:00:00", false) } },
    })
    local opts_force = options(); opts_force.allow_wipe = true

    local res = Orchestrator.sync_book_with_providers(h.make_fake_ui({}), "/b.epub", opts_force, fakes)
    h.assert_true(res.ok, "(2b) override sync ok")
    h.assert_equal(count_alive(fakes.shared_state.annotations), 1,
        "(2b) cloud annotation adopted alive in canonical")
    -- S1: not applied to the live document in-session; delivered at close (G).
    h.assert_true(res.merged_state.annotations[KEY] ~= nil,
        "(2b) annotation carried in merged_state for close-time delivery")
    -- S3: the un-materialized pull is kept OUT of the ancestor.
    h.assert_nil(fakes.last_sync_state.annotations[KEY],
        "(2b) ancestor excludes the un-materialized pull (S3)")

    -- SECOND chained merge: local still empty (not yet materialized), ancestor
    -- free of the pull (S3).  The annotation must remain ALIVE in canonical —
    -- the phantom tombstone is what S3 prevents.
    local res2 = Orchestrator.sync_book_with_providers(h.make_fake_ui({}), "/b.epub", options(), fakes)
    h.assert_equal(count_alive(fakes.shared_state.annotations), 1,
        "(2b) cloud annotation STILL alive after second chained merge — NOT tombstoned")
    local e = fakes.shared_state.annotations[KEY]
    h.assert_true(e ~= nil and not e.deleted,
        "(2b) annotation is alive (not a tombstone) after the chain")
end


-- ----------------------------------------------------------------------------
-- (3) S3 ancestor asymmetry: when a cloud annotation is adopted but is NOT
--     materialized into this device's local read (the fresh-device case), the
--     ancestor (last_sync) is DELIBERATELY kept free of it (S3 filter), while
--     the shared file has it.  This is how the phantom deletion is prevented:
--     the next merge sees the pull as remote-only (ancestor lacks it, local
--     lacks it -> adopt again, alive), never as "ancestor has k, local lacks
--     k -> deletion".  See _materialized_last_sync_annotations.
--
--     NOTE: this is the INVERSE of the pre-S3 strategy, which relied on the
--     ancestor AND the live doc both gaining the entry (write->read symmetry).
--     S3 replaces that with ancestor asymmetry: an un-materialized pull is
--     never written to the ancestor in the first place.
-- ----------------------------------------------------------------------------
do
    local fakes = make_chain_fakes({
        live_doc        = {},   -- fresh device: local read is empty
        last_sync_state = { schema_version = 1, metadata = {}, render_settings = {}, annotations = {} },
        shared_state    = { schema_version = 1, metadata = {}, render_settings = {},
                            annotations = { [KEY] = ann("2026-01-02 00:00:00", false) } },
    })
    local opts_force = options(); opts_force.allow_wipe = true
    Orchestrator.sync_book_with_providers(h.make_fake_ui({}), "/b.epub", opts_force, fakes)

    -- S3: the adopted pull is EXCLUDED from the ancestor because it was not in
    -- the local read (un-materialized).  This is the phantom guard.
    h.assert_nil(fakes.last_sync_state.annotations[KEY],
        "(3) ancestor (last_sync) EXCLUDES the un-materialized pull (S3 phantom guard)")
    -- The shared (canonical) file DOES have it -- delivery is convergent.
    h.assert_true(fakes.shared_state.annotations[KEY] ~= nil,
        "(3) shared file has the adopted annotation (convergent)")

    -- The real test of the guard: a SECOND merge must NOT tombstone it.  With
    -- the ancestor free of the pull, _detect_local_deletions has nothing to
    -- mistake for a deletion -> the annotation stays alive.
    local res2 = Orchestrator.sync_book_with_providers(h.make_fake_ui({}), "/b.epub", options(), fakes)
    -- (res2 may skip via the failsafe since local is still empty; either way
    -- the shared annotation must remain alive, never tombstoned.)
    h.assert_equal(count_alive(fakes.shared_state.annotations), 1,
        "(3) adopted annotation STILL alive after a second merge — no phantom tombstone")
    local KEY_entry = fakes.shared_state.annotations[KEY]
    h.assert_true(KEY_entry ~= nil and not KEY_entry.deleted,
        "(3) the annotation is alive (not a tombstone) — S3 prevented the phantom")
end

-- ----------------------------------------------------------------------------
-- (4) NOTE-EDIT PING-PONG (the S3 materialized-value regression).
--
-- Device B has an annotation materialized with note "v1" (live_doc + ancestor
-- both at "v1").  Device A edited the note to "v2" and it reached canonical
-- (shared, newer datetime).  B syncs:
--
--   First merge: B pulls "v2" (remote newer) -> merged note "v2".  Under S1 the
--   live list stays "v1" until close (G).  S3 must record the MATERIALIZED
--   (live) value "v1" in the ancestor -- NOT the merged "v2".
--
--   Second merge (B syncs again before closing, live still "v1"): with the
--   ancestor at "v1" (== live), _preserve_local_note_edits does NOT fire, the
--   winner stays "v2", the shared file is NOT regressed.
--
-- THE BUG (ancestor recorded merged "v2"): the second merge sees ancestor.note
-- "v2" != local.note "v1", _preserve_local_note_edits re-asserts the stale "v1"
-- with a BUMPED timestamp, and the shared file REGRESSES "v2" -> "v1".  Both
-- devices do this -> bidirectional ping-pong, the edit is lost.  This is the
-- EDIT analog of (2b)/(3), which guard the same ancestor-desync class for a
-- NEW pull via exclusion; an EDIT is materialized, so it is KEPT but must
-- carry the LIVE value.
-- ----------------------------------------------------------------------------
do
    local function ann_note(note_text, ts)
        return {
            pos0 = "p0", pos1 = "p1", text = "highlighted span",
            note = note_text,
            datetime = "2026-01-01 00:00:00",
            datetime_updated = ts,
            device_id = "devX", device_label = "X",
        }
    end

    local fakes = make_chain_fakes({
        live_doc        = { [KEY] = ann_note("v1", "2026-01-01 00:00:00") },  -- B materialized at v1
        last_sync_state = { schema_version = 1, metadata = {}, render_settings = {},
                            annotations = { [KEY] = ann_note("v1", "2026-01-01 00:00:00") } },  -- ancestor v1
        shared_state    = { schema_version = 1, metadata = {}, render_settings = {},
                            annotations = { [KEY] = ann_note("v2", "2026-01-02 00:00:00") } },  -- cloud edit v2, newer
    })

    -- First merge: B pulls v2.
    local res1 = Orchestrator.sync_book_with_providers(h.make_fake_ui({}), "/b.epub", options(), fakes)
    h.assert_true(res1.ok, "(4) first sync ok")
    -- S3 records the LIVE value (v1), NOT the merged value (v2).
    h.assert_true(fakes.last_sync_state.annotations[KEY] ~= nil,
        "(4) ancestor keeps the materialized key")
    h.assert_equal(fakes.last_sync_state.annotations[KEY].note, "v1",
        "(4) ancestor records the LIVE note v1, NOT the merged note v2 (S3)")
    -- S1: the live list is unchanged in-session (still v1).
    h.assert_equal(fakes.live_doc[KEY].note, "v1",
        "(4) live list stays v1 in-session (delivery at close / G)")

    -- Second merge: B syncs again, live still v1.  No re-assert -> no regression.
    local res2 = Orchestrator.sync_book_with_providers(h.make_fake_ui({}), "/b.epub", options(), fakes)
    h.assert_true(res2.ok, "(4) second sync ok")
    h.assert_equal(fakes.shared_state.annotations[KEY].note, "v2",
        "(4) shared note STAYS v2 -- NOT regressed to v1 (no ping-pong)")
end
