-- =============================================================================
-- spec/sync_orchestrator_spec.lua
-- =============================================================================
--
-- Integration tests for syncery_ann/sync_orchestrator.lua.  These don't
-- touch disk or KOReader — every dependency is injected via the
-- `providers` parameter that `sync_book_with_providers` accepts.
--
-- The fake providers below are small enough to inline.  Each captures
-- its inputs and outputs so we can assert on what the orchestrator
-- did, in what order, with what data.
--
-- =============================================================================

local h = require("spec.test_helpers")
h.setup()

local Orchestrator = require("syncery_ann/sync_orchestrator")
local Identity     = require("syncery_ann/identity")
local TimeFormat   = require("syncery_ann/time_format")


-- ----------------------------------------------------------------------------
-- Fake-provider factory
-- ----------------------------------------------------------------------------


--- Build a minimal but complete set of fake providers backed by in-
--- memory state.  The returned `fakes` table also has handles to read
--- and mutate that state directly from tests:
---
---   fakes.shared_state       — what's "on disk" for the shared file
---   fakes.last_sync_state    — what's "on disk" for the last-sync file
---   fakes.doc_settings_map   — what doc_settings_bridge.read returns
---   fakes.calls              — log of provider-method calls
---
local function make_fakes(initial)
    initial = initial or {}

    local fakes = {
        shared_state    = initial.shared_state    or {
            schema_version = 1,
            annotations    = {},
            metadata       = {},
            render_settings = {},
        },
        last_sync_state = initial.last_sync_state or {
            schema_version = 1,
            annotations    = {},
            metadata       = {},
            render_settings = {},
        },
        doc_settings_map = initial.doc_settings_map or {},
        merged_applied   = nil,  -- what apply_and_refresh was called with
        calls            = {},
    }

    local function record(method, args)
        table.insert(fakes.calls, { method = method, args = args })
    end

    -- ── state_store ──────────────────────────────────────────────────
    fakes.state_store = {
        load_shared = function(_book_path)
            record("state_store.load_shared", {})
            return fakes.shared_state, "ok"
        end,
        load_last_sync = function(_book_path)
            record("state_store.load_last_sync", {})
            return fakes.last_sync_state, "ok"
        end,
        save_shared = function(_book_path, state, device_id, device_label)
            record("state_store.save_shared", {
                state = state, device_id = device_id, device_label = device_label,
            })
            fakes.shared_state = state
            return true
        end,
        save_last_sync = function(_book_path, state)
            record("state_store.save_last_sync", { state = state })
            fakes.last_sync_state = state
            return true
        end,
    }

    -- ── doc_settings_bridge ──────────────────────────────────────────
    fakes.doc_settings_bridge = {
        read_annotations_as_map = function(_ui)
            record("doc_settings_bridge.read_annotations_as_map", {})
            -- Shallow copy so the orchestrator's mutations don't
            -- bleed back into the fake's stored state.
            local copy = {}
            for k, v in pairs(fakes.doc_settings_map) do copy[k] = v end
            return copy, 0
        end,
        apply_and_refresh = function(_ui, state_map, options)
            record("doc_settings_bridge.apply_and_refresh", {
                state_map_size = (function()
                    local n = 0
                    for _ in pairs(state_map) do n = n + 1 end
                    return n
                end)(),
                options = options,
            })
            fakes.merged_applied = state_map
            return true, 0
        end,
    }

    -- ── metadata_bridge ──────────────────────────────────────────────
    fakes.metadata_bridge = {
        read_from_ui = function(_ui, _book_file, _toggles, _device_id, _device_label)
            record("metadata_bridge.read_from_ui", {})
            return initial.local_metadata or {}
        end,
        apply_from_remote = function(_ui, _book_file, remote_metadata, _toggles)
            record("metadata_bridge.apply_from_remote", { remote = remote_metadata })
            -- Pretend nothing changed unless the test set
            -- initial.metadata_apply_result.
            if initial.metadata_apply_result then
                return true, initial.metadata_apply_result
            end
            return false, {}
        end,
        merge = function(a, b)
            -- Pass-through "merge" for the test: pick whichever side
            -- has more keys (deterministic and predictable for asserts).
            local na, nb = 0, 0
            for _ in pairs(a or {}) do na = na + 1 end
            for _ in pairs(b or {}) do nb = nb + 1 end
            return (na >= nb) and (a or {}) or b
        end,
        three_way = function(local_md, remote_md, _ancestor_md)
            -- Pass-through for the test: same deterministic "more keys
            -- wins" shape as the merge fake above.  The ancestor is
            -- ignored here; the real 3-way resolution logic is covered in
            -- metadata_bridge_spec, this only exercises orchestration.
            local nl, nr = 0, 0
            for _ in pairs(local_md or {}) do nl = nl + 1 end
            for _ in pairs(remote_md or {}) do nr = nr + 1 end
            return (nl >= nr) and (local_md or {}) or remote_md
        end,
        make_toggles_from_plugin = function(_) return {} end,
    }

    -- ── render_settings_bridge ───────────────────────────────────────
    fakes.render_settings_bridge = {
        read_from_ui = function(_ui, _toggles)
            record("render_settings_bridge.read_from_ui", {})
            return initial.local_render
        end,
        apply_from_remote = function(_ui, remote_block, _toggles)
            record("render_settings_bridge.apply_from_remote", { remote = remote_block })
            return initial.render_apply_result == true
        end,
        merge = function(a, b)
            -- Pass-through "merge" for the test: pick whichever side has
            -- more keys (deterministic and predictable for asserts), same
            -- shape as the metadata_bridge fake above.
            local na, nb = 0, 0
            for _ in pairs(a or {}) do na = na + 1 end
            for _ in pairs(b or {}) do nb = nb + 1 end
            return (na >= nb) and (a or {}) or b
        end,
        make_toggles_from_plugin = function(_) return {} end,
    }

    -- ── conflict_resolver ────────────────────────────────────────────
    fakes.conflict_resolver = {
        resolve_all = function(_book_path)
            record("conflict_resolver.resolve_all", {})
            return initial.conflicts_found or 0,
                   initial.conflicts_merged or 0,
                   nil
        end,
    }

    -- ── merge / tombstones (real modules are pure, just pass-through) ─
    fakes.merge      = require("syncery_ann/merge")
    fakes.tombstones = require("syncery_ann/tombstones")

    return fakes
end


--- Make a minimal fake ReaderUI suitable for the orchestrator's
--- pre-flight checks (`not ui or not ui.doc_settings`).
local function make_fake_ui()
    return h.make_fake_ui({})
end


local function default_options()
    return {
        device_id    = "test-device",
        device_label = "Test",
        toggles = {
            annotations     = true,
            highlights      = true,
            notes           = true,
            bookmarks       = true,
            metadata        = true,
            status          = true,
            rating          = true,
            collections     = true,
            summary         = true,
            custom          = true,
            handmade        = true,
            render_settings = false,
        },
        tombstone_ttl_days = 30,
    }
end


-- ----------------------------------------------------------------------------
-- Pre-flight checks
-- ----------------------------------------------------------------------------


-- ── Test: missing UI ─────────────────────────────────────────────────

do
    local result = Orchestrator.sync_book_with_providers(
        nil, "/books/x.epub", default_options(), make_fakes())
    h.assert_false(result.ok,             "missing UI -> not ok")
    h.assert_equal(result.error, "no_ui", "missing UI -> 'no_ui'")
end


-- ── Test: missing book file ──────────────────────────────────────────

do
    local result = Orchestrator.sync_book_with_providers(
        make_fake_ui(), "", default_options(), make_fakes())
    h.assert_equal(result.error, "no_book_file", "empty book file -> 'no_book_file'")
end


-- ── Test: missing device_id ──────────────────────────────────────────

do
    local opts = default_options()
    opts.device_id = nil
    local result = Orchestrator.sync_book_with_providers(
        make_fake_ui(), "/books/x.epub", opts, make_fakes())
    h.assert_equal(result.error, "no_device_id", "missing device -> 'no_device_id'")
end


-- ── Test: nothing to persist -> no empty envelope written ────────────
--
-- master annotations ON is enough to pass the upstream _save master-gate, but
-- with annotations / metadata / render effectively off the merge yields an
-- empty state.  sync_book must NOT call save_shared then -- it used to, writing
-- an empty syncery-annotations.json for a book with nothing to sync (and the
-- same on the first save of a fresh book before any annotation is made).
do
    local opts = default_options()
    opts.toggles.annotations     = false   -- master off -> annotations not read
    opts.toggles.metadata        = false
    opts.toggles.render_settings = false
    local fakes  = make_fakes()            -- empty shared + last_sync
    local result = Orchestrator.sync_book_with_providers(
        make_fake_ui(), "/books/empty.epub", opts, fakes)

    h.assert_true(result.ok, "empty state -> ok (no error)")

    local wrote_shared = false
    for _, c in ipairs(fakes.calls) do
        if c.method == "state_store.save_shared" then wrote_shared = true end
    end
    h.assert_false(wrote_shared,
        "empty final_state -> save_shared NOT called (no empty envelope)")
    h.assert_true(result.skipped,
        "empty state -> skipped (distinct from a real noop in the journal)")
    h.assert_equal(result.skipped_reason, "empty",
        "empty-skip carries the 'empty' reason")
end


-- ----------------------------------------------------------------------------
-- Happy path: fresh local annotation gets pushed to shared
-- ----------------------------------------------------------------------------


do
    local fresh = {
        type     = "highlight",
        pos0     = "/p[1].0",
        pos1     = "/p[1].50",
        text     = "hello world",
        datetime_updated = "2024-11-17 18:00:00",
        deleted  = false,
    }
    local key = Identity.compute_key(fresh)

    local fakes = make_fakes({
        doc_settings_map = { [key] = fresh },
        -- No remote, no last-sync.  Should be a clean push.
    })

    local result = Orchestrator.sync_book_with_providers(
        make_fake_ui(), "/books/x.epub", default_options(), fakes)

    h.assert_true(result.ok,                              "happy path ok")
    h.assert_false(result.skipped,                        "not skipped")
    h.assert_equal(result.annotations_after, 1,           "1 annotation after")
    h.assert_equal(result.annotations_pushed, 1,          "1 pushed (was not in remote)")
    h.assert_equal(result.annotations_pulled, 0,          "0 pulled (remote empty)")

    -- The shared state should now contain our fresh annotation.
    h.assert_true(fakes.shared_state.annotations[key] ~= nil,
        "shared state has the annotation")
    h.assert_equal(fakes.shared_state.annotations[key].text, "hello world",
        "shared state preserves the text")

    -- last-sync should match the merged state.
    h.assert_true(fakes.last_sync_state.annotations[key] ~= nil,
        "last-sync also has the annotation")
end


-- ----------------------------------------------------------------------------
-- Fresh device: remote-only annotation is adopted SILENTLY (no prompt)
-- ----------------------------------------------------------------------------


do
    local remote_only = {
        type = "highlight",
        pos0 = "/p[2].0",
        pos1 = "/p[2].50",
        text = "remote thing",
        datetime_updated = "2024-11-17 18:00:00",
        deleted = false,
    }
    local rkey = Identity.compute_key(remote_only)

    local fakes = make_fakes({
        doc_settings_map = {},
        shared_state = {
            schema_version = 1,
            annotations = { [rkey] = remote_only },
            metadata = {},
            render_settings = {},
        },
        last_sync_state = {
            schema_version = 1,
            annotations = {}, metadata = {}, render_settings = {},
        },
    })

    local result = Orchestrator.sync_book_with_providers(
        make_fake_ui(), "/books/x.epub", default_options(), fakes)

    -- Fresh device: local empty + remote has data + last-sync empty + this
    -- device never synced.  This is the unambiguously adopt-worthy case --
    -- live remote annotations are genuine (a delete-that-synced would leave
    -- tombstones, not live entries).  fresh-device-adopt: the merge adopts
    -- the remote SILENTLY (no prompt).  See ANNOTATION_DELIVERY_DESIGN.md
    -- DEVICE FACT 4.
    h.assert_false(result.skipped,                 "fresh device -> not skipped (adopts silently)")
    h.assert_nil(result.skipped_reason,            "fresh device -> no skip reason")
    h.assert_equal(result.annotations_after, 1,    "remote adopted despite empty local")
    -- S1+S3: the pull reaches the canonical SHARED state; delivery to the
    -- live list happens at close (G), not in-session.
    h.assert_true(fakes.shared_state.annotations[rkey] ~= nil,
        "remote annotation adopted into shared state")
    h.assert_true(result.merged_state.annotations[rkey] ~= nil,
        "merged_state carries the pull for close-time delivery")
end


-- ----------------------------------------------------------------------------
-- 3-way deletion: remote has fresher edit, we still detect local delete
-- ----------------------------------------------------------------------------


do
    -- Last-sync (ancestor) had X.  Remote still has alive X.  Local
    -- doesn't have X anymore (user deleted it).  Expected:
    --   * merged contains a tombstone for X (we record the deletion)
    --   * the tombstone wins because local deletion happens-after.
    -- ... unless remote was modified MORE recently than the deletion.

    local pos0, pos1 = "/p[5].0", "/p[5].20"
    local X_ancestor = {
        type = "highlight", pos0 = pos0, pos1 = pos1,
        text = "original X",
        datetime_updated = "2024-01-01 10:00:00",
        deleted = false,
    }
    local key = Identity.compute_key(X_ancestor)

    -- Y is present alive on local so we don't trigger the wipe failsafe.
    local Y_local = {
        type = "highlight", pos0 = "/p[9].0", pos1 = "/p[9].20",
        text = "Y", datetime_updated = "2024-11-17 18:00:00",
        deleted = false,
    }
    local ykey = Identity.compute_key(Y_local)

    local fakes = make_fakes({
        doc_settings_map = { [ykey] = Y_local },  -- X is gone
        shared_state = {
            schema_version = 1,
            annotations = { [key] = X_ancestor },  -- remote still has alive X
            metadata = {}, render_settings = {},
        },
        last_sync_state = {
            schema_version = 1,
            annotations = { [key] = X_ancestor },
            metadata = {}, render_settings = {},
        },
    })

    local result = Orchestrator.sync_book_with_providers(
        make_fake_ui(), "/books/x.epub", default_options(), fakes)

    h.assert_true(result.ok, "3-way ok")
    -- The merge should detect the local deletion (X in last-sync, not
    -- in local) and emit a tombstone.  Then phase 2 compares the
    -- fresh tombstone to the alive remote X — the tombstone is newer.
    local merged_entry = fakes.shared_state.annotations[key]
    h.assert_true(merged_entry ~= nil, "merged still has X (as tomb)")
    h.assert_true(merged_entry.deleted, "X is now a tombstone")
end


-- ----------------------------------------------------------------------------
-- Conflict resolver is called before reading state
-- ----------------------------------------------------------------------------


do
    local fakes = make_fakes({
        conflicts_found  = 2,
        conflicts_merged = 2,
    })

    local result = Orchestrator.sync_book_with_providers(
        make_fake_ui(), "/books/x.epub", default_options(), fakes)

    h.assert_equal(result.conflicts_found,  2, "result reports 2 conflicts found")
    h.assert_equal(result.conflicts_merged, 2, "result reports 2 conflicts merged")

    -- conflict_resolver.resolve_all must be called before
    -- state_store.load_shared, otherwise the orchestrator would
    -- read the main file BEFORE folding in any conflict-file data.
    local cr_idx, ls_idx
    for i, call in ipairs(fakes.calls) do
        if call.method == "conflict_resolver.resolve_all"   then cr_idx = i end
        if call.method == "state_store.load_shared"         then ls_idx = i end
    end
    h.assert_true(cr_idx ~= nil and ls_idx ~= nil,  "both calls were made")
    h.assert_true(cr_idx < ls_idx,
        "conflict_resolver runs before state_store.load_shared")
end


-- ----------------------------------------------------------------------------
-- Annotations toggle off -> orchestrator preserves remote, never reads local
-- ----------------------------------------------------------------------------


do
    local remote_thing = {
        type = "highlight", pos0 = "/p[1].0", pos1 = "/p[1].50",
        text = "remote only", datetime_updated = "2024-11-17 18:00:00",
        deleted = false,
    }
    local rkey = Identity.compute_key(remote_thing)

    local fakes = make_fakes({
        shared_state = {
            schema_version = 1,
            annotations = { [rkey] = remote_thing },
            metadata = {}, render_settings = {},
        },
    })

    local opts = default_options()
    opts.toggles.annotations = false  -- master switch off

    local result = Orchestrator.sync_book_with_providers(
        make_fake_ui(), "/books/x.epub", opts, fakes)

    h.assert_true(result.ok, "annotations off -> still ok")

    -- doc_settings_bridge.read should NOT have been called (annotations off).
    local read_was_called = false
    for _, c in ipairs(fakes.calls) do
        if c.method == "doc_settings_bridge.read_annotations_as_map" then
            read_was_called = true; break
        end
    end
    h.assert_false(read_was_called,
        "doc_settings_bridge.read skipped when annotations are off")

    -- Remote annotations should still be present in the saved shared
    -- state (we don't delete them just because this device's master
    -- annotations toggle is off — other devices' data deserves
    -- preservation).
    h.assert_true(fakes.shared_state.annotations[rkey] ~= nil,
        "remote annotation preserved when local sync is off")
end


-- ----------------------------------------------------------------------------
-- Tombstone GC trims old deletion markers
-- ----------------------------------------------------------------------------


do
    -- Build a shared state with one alive entry and one very old
    -- tombstone (> 30 days).  After the sync, the tombstone should
    -- be dropped by the GC pass.

    local alive = {
        type = "highlight", pos0 = "/p[1].0", pos1 = "/p[1].50",
        text = "alive entry", datetime_updated = "2024-11-17 18:00:00",
        deleted = false,
    }
    local akey = Identity.compute_key(alive)

    -- 200 days before "now" (whatever os.time says when the test runs).
    local old_unix = os.time() - 200 * 86400
    local old_str  = os.date("!%Y-%m-%d %H:%M:%S", old_unix)
    local old_tomb = {
        type = "highlight", pos0 = "/p[99].0", pos1 = "/p[99].50",
        text = "ancient", datetime_updated = old_str, deleted = true,
    }
    local tkey = Identity.compute_key(old_tomb)

    local fakes = make_fakes({
        doc_settings_map = { [akey] = alive },
        shared_state = {
            schema_version = 1,
            annotations = { [akey] = alive, [tkey] = old_tomb },
            metadata = {}, render_settings = {},
        },
        last_sync_state = {
            schema_version = 1,
            annotations = { [akey] = alive, [tkey] = old_tomb },
            metadata = {}, render_settings = {},
        },
    })

    local result = Orchestrator.sync_book_with_providers(
        make_fake_ui(), "/books/x.epub", default_options(), fakes)

    h.assert_true(result.ok,                          "GC sync ok")
    h.assert_equal(result.tombstones_compacted, 1,    "1 tombstone compacted by GC")
    h.assert_true(fakes.shared_state.annotations[tkey] ~= nil,
        "old tombstone still in shared state (compacted, not dropped)")
    h.assert_true(fakes.shared_state.annotations[tkey].deleted,
        "compacted tombstone keeps deleted=true")
    h.assert_nil(fakes.shared_state.annotations[tkey].text,
        "compacted tombstone has the original text field stripped")
    h.assert_true(fakes.shared_state.annotations[akey] ~= nil,
        "alive entry still present")
end


-- ----------------------------------------------------------------------------
-- Render-settings toggle off -> no read, no apply
-- ----------------------------------------------------------------------------


do
    local fakes = make_fakes({
        local_render = { font_size = 22, datetime_updated = "2024-11-17 18:00:00" },
    })

    local opts = default_options()
    opts.toggles.render_settings = false  -- default

    local _result = Orchestrator.sync_book_with_providers(
        make_fake_ui(), "/books/x.epub", opts, fakes)

    local read_called, apply_called = false, false
    for _, c in ipairs(fakes.calls) do
        if c.method == "render_settings_bridge.read_from_ui"      then read_called  = true end
        if c.method == "render_settings_bridge.apply_from_remote" then apply_called = true end
    end
    h.assert_false(read_called,  "render_settings.read NOT called when toggle off")
    h.assert_false(apply_called, "render_settings.apply NOT called when toggle off")
end


-- ----------------------------------------------------------------------------
-- Adapt highlight style: under S1 the in-session apply is gone, so the flag
-- is no longer consumed here; the orchestrator still ACCEPTS it (main.lua
-- passes it through) and the merge runs normally.  The actual honoring of
-- adapt_highlight_style (stripping color/drawer) moves to the close-time
-- delivery (G / stage_pending_at_close) -- see ANNOTATION_DELIVERY_DESIGN.md
-- §3 (S1) and the step-5 G-wiring, which carries the flag and is tested
-- end-to-end there.
-- ----------------------------------------------------------------------------


do
    local fresh = {
        type = "highlight", pos0 = "/p[1].0", pos1 = "/p[1].50",
        text = "x", datetime_updated = "2024-11-17 18:00:00", deleted = false,
        color = "red", drawer = "underscore",
    }
    local key = Identity.compute_key(fresh)

    local fakes = make_fakes({
        doc_settings_map = { [key] = fresh },
    })

    local opts = default_options()
    opts.adapt_highlight_style = true

    local result = Orchestrator.sync_book_with_providers(
        make_fake_ui(), "/books/x.epub", opts, fakes)

    -- S1: apply_and_refresh is no longer called; the merge still runs with the
    -- option set and produces a merged state.  No in-session apply call exists.
    h.assert_true(result.ok, "orchestrator runs with adapt_highlight_style set")
    local apply_call
    for _, c in ipairs(fakes.calls) do
        if c.method == "doc_settings_bridge.apply_and_refresh" then
            apply_call = c
            break
        end
    end
    h.assert_nil(apply_call,
        "S1: apply_and_refresh is NOT called in-session (delivery moved to close/G)")
    h.assert_true(result.merged_state ~= nil and result.merged_state.annotations[key] ~= nil,
        "the annotation is in merged_state for close-time delivery")
end


-- ----------------------------------------------------------------------------
-- Direct unit tests for SyncOrchestrator._count_added_vs.
--
-- `annotations_pulled`/`annotations_pushed` count NEW annotations moved (see
-- the result-field comments).  A tombstone is a DELETION, not a new
-- annotation, and the local sidecar never stores tombstones -- so an
-- un-skipped tombstone in the merged map is absent from `before` and counts
-- as "new" on EVERY sync, firing the "N new annotations from another device"
-- reload affordance perpetually after a cross-device deletion.  The count
-- must skip tombstones.
-- ----------------------------------------------------------------------------
do
    local count = Orchestrator._count_added_vs

    local function alive(ts) return { datetime_updated = ts, deleted = false } end
    local function tomb(ts)  return { datetime_updated = ts, deleted = true } end

    -- Mixed: one unchanged alive (in before), one NEW alive (not in before),
    -- one tombstone (not in before).  Only the new alive counts.
    local before = { a = alive("2026-01-01 00:00:00") }
    local merged = {
        a = alive("2026-01-01 00:00:00"),   -- unchanged -> not counted
        b = alive("2026-02-01 00:00:00"),   -- NEW alive -> counted
        t = tomb("2026-03-01 00:00:00"),    -- deletion -> NOT counted
    }
    h.assert_equal(count(merged, before), 1,
        "_count_added_vs counts only the new alive annotation, not the tombstone")

    -- Pure deletion: merged holds only a tombstone, before is empty.  This is
    -- the perpetual-pulled=1 case -- must be 0.
    h.assert_equal(count({ t = tomb("2026-03-01 00:00:00") }, {}), 0,
        "_count_added_vs ignores a lone tombstone (no perpetual pulled=1)")

    -- An alive annotation whose timestamp advanced past `before` still counts.
    local before2 = { a = alive("2026-01-01 00:00:00") }
    local merged2 = { a = alive("2026-05-01 00:00:00") }
    h.assert_equal(count(merged2, before2), 1,
        "_count_added_vs still counts an alive annotation with an advanced timestamp")
end


-- ----------------------------------------------------------------------------
-- Per-type filtering helpers (PER_TYPE_FILTER_DESIGN §15.2)
-- ----------------------------------------------------------------------------

do
    -- _disabled_types: only the explicitly-false subs become disabled.
    local d = Orchestrator._disabled_types(
        { highlights = true, notes = false, bookmarks = false })
    h.assert_true(d.note     == true, "notes off -> note disabled")
    h.assert_true(d.bookmark == true, "bookmarks off -> bookmark disabled")
    h.assert_true(d.highlight == nil, "highlights on -> highlight NOT disabled")

    local none = Orchestrator._disabled_types(
        { highlights = true, notes = true, bookmarks = true })
    h.assert_true(next(none) == nil, "all subs on -> no disabled types")

    -- _without_keys: removes the listed keys; empty keys -> same table by ref.
    local m  = { a = 1, b = 2, c = 3 }
    local r  = Orchestrator._without_keys(m, { b = true })
    h.assert_true(r.a == 1 and r.c == 3, "without_keys keeps unlisted keys")
    h.assert_true(r.b == nil,            "without_keys drops the listed key")
    h.assert_true(Orchestrator._without_keys(m, {}) == m,
        "without_keys with empty set returns the SAME table (by ref, no-op)")
end


-- ----------------------------------------------------------------------------
-- Per-type filtering: bookmarks OFF (end-to-end)
-- ----------------------------------------------------------------------------
--
-- LOCAL holds an edited highlight (newer) + its own bookmark; REMOTE holds the
-- highlight (older) + ANOTHER device's bookmark; bookmarks are OFF.  Expected:
--   shared:   highlight (local wins) + remote's bookmark (passthrough); the
--             device's OWN bookmark is NOT pushed.
--   delivery: highlight + the device's own bookmark; remote's bookmark NOT
--             delivered.
--   pulled:   0 (remote's bookmark rides in shared but is not delivered).

do
    local H_local = { type = "highlight", pos0 = "/p[1].0", pos1 = "/p[1].50",
        drawer = "lighten", text = "H", datetime = "2024-11-17 18:00:00",
        datetime_updated = "2024-11-17 18:05:00", deleted = false }
    local H_remote = { type = "highlight", pos0 = "/p[1].0", pos1 = "/p[1].50",
        drawer = "lighten", text = "H", datetime = "2024-11-17 18:00:00",
        datetime_updated = "2024-11-17 18:00:00", deleted = false }
    local kH = Identity.compute_key(H_local)

    local B_own = { page = 10, datetime = "2024-11-17 18:01:00",
        datetime_updated = "2024-11-17 18:01:00", deleted = false }
    local kBown = Identity.compute_key(B_own)
    local B_other = { page = 20, datetime = "2024-11-17 18:02:00",
        datetime_updated = "2024-11-17 18:02:00", deleted = false }
    local kBother = Identity.compute_key(B_other)

    local fakes = make_fakes({
        doc_settings_map = { [kH] = H_local, [kBown] = B_own },
        shared_state = { schema_version = 1, metadata = {}, render_settings = {},
            annotations = { [kH] = H_remote, [kBother] = B_other } },
        last_sync_state = { schema_version = 1, metadata = {}, render_settings = {},
            annotations = { [kH] = H_remote } },
    })

    local opts = default_options()
    opts.toggles.bookmarks = false
    local result = Orchestrator.sync_book_with_providers(
        make_fake_ui(), "/books/pt.epub", opts, fakes)

    h.assert_true(result.ok, "per-type sync ok")

    -- shared file
    h.assert_true(fakes.shared_state.annotations[kH] ~= nil,     "shared keeps the highlight")
    h.assert_equal(fakes.shared_state.annotations[kH].datetime_updated,
        "2024-11-17 18:05:00", "shared highlight is the local (newer) one")
    h.assert_true(fakes.shared_state.annotations[kBother] ~= nil, "shared preserves remote's bookmark (passthrough)")
    h.assert_true(fakes.shared_state.annotations[kBown] == nil,   "device's OWN bookmark NOT pushed (off)")

    -- delivery (what this device writes back to doc_settings)
    h.assert_true(result.delivery_annotations[kH] ~= nil,        "delivery has the highlight")
    h.assert_true(result.delivery_annotations[kBown] ~= nil,     "delivery keeps the device's own bookmark")
    h.assert_true(result.delivery_annotations[kBother] == nil,   "delivery EXCLUDES remote's bookmark")

    -- counts
    h.assert_equal(result.annotations_pulled, 0, "remote bookmark NOT counted as pulled (excluded)")
end


-- ----------------------------------------------------------------------------
-- Per-type filtering: ON -> OFF transition must NOT tombstone (ancestor-prep)
-- ----------------------------------------------------------------------------
--
-- A bookmark was synced (present in local + remote + ancestor).  Bookmarks are
-- now OFF.  The bookmark must be PRESERVED in the shared file, never tombstoned.
-- This pins ancestor-prep: if the ancestor were NOT prepped, the deletion
-- detector would see the bookmark in the (full) ancestor but not in the prepped
-- local and tombstone it -> wiping a bookmark that everyone still has.

do
    local Bk = { page = 5, datetime = "2024-11-17 18:00:00",
        datetime_updated = "2024-11-17 18:00:00", deleted = false }
    local kBk = Identity.compute_key(Bk)

    local fakes = make_fakes({
        doc_settings_map = { [kBk] = Bk },
        shared_state = { schema_version = 1, metadata = {}, render_settings = {},
            annotations = { [kBk] = Bk } },
        last_sync_state = { schema_version = 1, metadata = {}, render_settings = {},
            annotations = { [kBk] = Bk } },
    })

    local opts = default_options()
    opts.toggles.bookmarks = false
    local result = Orchestrator.sync_book_with_providers(
        make_fake_ui(), "/books/onoff.epub", opts, fakes)

    h.assert_true(result.ok, "on->off sync ok")
    h.assert_true(fakes.shared_state.annotations[kBk] ~= nil,
        "bookmark still present in shared after bookmarks turned off")
    h.assert_true(not fakes.shared_state.annotations[kBk].deleted,
        "bookmark NOT tombstoned on on->off (ancestor-prep keeps it out of deletion detection)")
end
