-- =============================================================================
-- spec/doc_settings_refresh_spec.lua
-- =============================================================================
--
-- Tests for DocSettingsBridge.apply_and_refresh updating KOReader's IN-MEMORY
-- annotation list (the load-bearing fix for the open-document data-loss bug).
--
-- THE BUG this guards against:
--   ReaderAnnotation keeps its annotations in memory (ui.annotation.annotations)
--   and writes that memory back to doc_settings on every save (onSaveSettings).
--   If a sync writes the merged annotations to doc_settings but does NOT also
--   replace the in-memory list, the next KOReader save overwrites the merge with
--   the stale pre-sync copy — silently discarding the synced-in annotations.
--
--   The old _refresh_ui only "nudged" via two calls that were both no-ops
--   (onAnnotationsModified(nil) errors out; bookmark.onReadSettings doesn't
--   exist on ReaderBookmark), so the in-memory list stayed stale.
--
-- These tests use a fake ui that mimics KOReader: an in-memory annotations
-- list + an onSaveSettings that persists it back to doc_settings. We then
-- assert that after apply_and_refresh, a simulated save persists the MERGE.
--
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_doc_settings_refresh_spec_" .. tostring(os.time()))

local DocSettingsBridge = require("syncery_ann/doc_settings_bridge")


-- ----------------------------------------------------------------------------
-- A fake doc_settings backed by a plain table.
-- ----------------------------------------------------------------------------


local function make_doc_settings()
    local store = {}
    return {
        _store = store,
        saveSetting = function(_self, key, value) store[key] = value end,
        readSetting = function(_self, key) return store[key] end,
    }
end


-- ----------------------------------------------------------------------------
-- A fake ui that mimics KOReader's ReaderAnnotation behaviour:
--   * ui.annotation.annotations is the in-memory list
--   * ui.annotation.sortItems sorts in place (we use a trivial key sort)
--   * simulate_save() does what onSaveSettings does: write in-memory -> config
-- ----------------------------------------------------------------------------


local function make_ui(opts)
    opts = opts or {}
    local doc_settings = make_doc_settings()

    -- Seed doc_settings with a PRE-SYNC annotation list (what KOReader loaded).
    local key = opts.paging and "annotations_paging" or "annotations"
    doc_settings._store[key] = opts.initial_annotations or {}

    local annotation = {
        -- KOReader's in-memory list starts as the loaded (pre-sync) copy.
        annotations = opts.initial_annotations or {},
        sortItems = function(self, items)
            if #items > 1 then
                table.sort(items, function(a, b)
                    return tostring(a.pos0 or a.page) < tostring(b.pos0 or b.page)
                end)
            end
        end,
    }

    local ui = {
        paging       = opts.paging or false,
        rolling      = (not opts.paging) or nil,
        doc_settings = doc_settings,
        annotation   = annotation,
        -- Device's default highlight drawer (KOReader: view.highlight.saved_drawer).
        -- nil unless a test sets opts.saved_drawer -> derivation falls back to "lighten".
        view         = { highlight = { saved_drawer = opts.saved_drawer } },
    }

    -- Mimic onSaveSettings: persist the in-memory list back to doc_settings.
    function ui._simulate_save()
        doc_settings._store[key] = annotation.annotations
    end

    return ui, doc_settings, key
end


-- ----------------------------------------------------------------------------
-- Build a state_map (keyed by identity) of alive annotations.
-- ----------------------------------------------------------------------------


local function ann(key, pos0, text)
    return {
        pos0 = pos0,
        pos1 = pos0,
        text = text or ("text-" .. key),
        drawer = "lighten",
        datetime = "2026-01-01 00:00:00",
    }
end


-- ----------------------------------------------------------------------------
-- TEST 1: after apply_and_refresh, the merge reaches doc_settings — but the
-- LIVE in-memory list is deliberately NOT replaced.
--
-- Empirically validated on-device (2026-06): overwriting the live list from
-- the merge result resurrects locally-deleted annotations (the dialog-delete
-- flow can run the save while the live list is mid-update; the merge then
-- sees the stale pre-delete state and the overwrite restores the deleted
-- annotation permanently).  Deletion correctness wins.
-- ----------------------------------------------------------------------------


do
    local ui, doc_settings, key = make_ui{
        initial_annotations = { ann("old", "/body/p[1]", "stale-one") },
    }

    -- A sync merged in two annotations (the "old" one survives + a new one).
    local merged_state = {
        ["k_old"] = ann("old", "/body/p[1]", "stale-one"),
        ["k_new"] = ann("new", "/body/p[5]", "synced-in"),
    }

    local ok, count = DocSettingsBridge.apply_and_refresh(ui, merged_state, {
        strip_sync_metadata = true,
    })
    h.assert_true(ok, "apply_and_refresh succeeded")
    h.assert_equal(count, 2, "apply_and_refresh reports 2 alive annotations")

    -- The merge reached doc_settings (the on-disk truth for the next open).
    h.assert_equal(#doc_settings._store[key], 2,
        "doc_settings holds the merged 2")

    -- THE KEY ASSERTION (deletion-correctness guard): the LIVE list is NOT
    -- replaced by the merge result.  KOReader owns it; Syncery never
    -- overwrites it (that overwrite resurrected deleted annotations).
    h.assert_equal(#ui.annotation.annotations, 1,
        "live in-memory list is NOT overwritten by the merge (KOReader owns it)")
end


-- ----------------------------------------------------------------------------
-- TEST 2: a KOReader save after the sync persists the LIVE list (KOReader's
-- own state) — by design.  The live list is authoritative for what the user
-- sees and does; doc_settings convergence happens via the last_sync ancestor
-- on the next merge cycle.
-- ----------------------------------------------------------------------------


do
    local ui, doc_settings, key = make_ui{
        initial_annotations = { ann("old", "/body/p[1]", "stale-one") },
    }

    local merged_state = {
        ["k_old"] = ann("old", "/body/p[1]", "stale-one"),
        ["k_new"] = ann("new", "/body/p[5]", "synced-in"),
    }

    DocSettingsBridge.apply_and_refresh(ui, merged_state, { strip_sync_metadata = true })

    -- KOReader saves (close / autosave / menu): writes the LIVE list back.
    ui._simulate_save()

    local persisted = doc_settings._store[key]
    h.assert_equal(#persisted, 1,
        "a KOReader save persists the live list (1) — the live list is authoritative")
end


-- ----------------------------------------------------------------------------
-- TEST 3: paging document uses the paging key and still refreshes in-memory.
-- ----------------------------------------------------------------------------


do
    local ui, doc_settings, key = make_ui{
        paging = true,
        initial_annotations = { ann("p_old", 10, "stale-paging") },
    }
    h.assert_equal(key, "annotations_paging", "paging doc uses annotations_paging key")

    local merged_state = {
        ["k1"] = ann("p_old", 10, "stale-paging"),
        ["k2"] = ann("p_new", 20, "synced-paging"),
    }
    DocSettingsBridge.apply_and_refresh(ui, merged_state, { strip_sync_metadata = true })

    h.assert_equal(#doc_settings._store["annotations_paging"], 2,
        "paging: doc_settings holds the merged 2")
    h.assert_equal(#ui.annotation.annotations, 1,
        "paging: live in-memory list is NOT overwritten (KOReader owns it)")
end


-- ----------------------------------------------------------------------------
-- TEST 4: robustness — _refresh_ui with no ui.annotation must not crash, and
-- it never injects a list into the live memory (deletion-correctness).
-- ----------------------------------------------------------------------------


do
    -- ui without an annotation manager (document not fully loaded): no crash.
    local doc_settings = make_doc_settings()
    doc_settings._store["annotations"] = { ann("x", "/body/p", "x") }
    local ui_no_ann = { rolling = true, doc_settings = doc_settings }
    local okp = pcall(DocSettingsBridge._refresh_ui, ui_no_ann, nil)
    h.assert_true(okp, "_refresh_ui without ui.annotation does not crash")

    -- _refresh_ui must NOT inject the doc_settings list into the live memory:
    -- the live list belongs to KOReader (overwriting it resurrected deletions).
    local ui2 = {
        rolling = true,
        doc_settings = doc_settings,
        annotation = { annotations = {}, sortItems = function() end },
    }
    DocSettingsBridge._refresh_ui(ui2, nil)
    h.assert_equal(#ui2.annotation.annotations, 0,
        "_refresh_ui leaves the live list alone (no injection from doc_settings)")
end


-- ----------------------------------------------------------------------------
-- TEST 5 (clear_all — the Delete-all path): clears BOTH disk keys and the
-- in-memory list, and the cleared state SURVIVES the next KOReader save
-- (the deleted annotations are NOT resurrected).
-- ----------------------------------------------------------------------------


do
    local ui, doc_settings, key = make_ui{
        initial_annotations = {
            ann("a", "/body/p[1]", "one"),
            ann("b", "/body/p[2]", "two"),
        },
    }
    -- Sanity: we start non-empty in memory and on disk.
    h.assert_equal(#ui.annotation.annotations, 2, "clear_all: starts with 2 in memory")

    DocSettingsBridge.clear_all(ui)

    -- Disk keys cleared (all three, defensively).
    h.assert_equal(#doc_settings._store["annotations"], 0,
        "clear_all: annotations key emptied on disk")
    h.assert_equal(#doc_settings._store["annotations_paging"], 0,
        "clear_all: annotations_paging key emptied on disk")
    h.assert_equal(#doc_settings._store["bookmarks"], 0,
        "clear_all: bookmarks key emptied on disk")

    -- In-memory list cleared (the load-bearing part).
    h.assert_equal(#ui.annotation.annotations, 0,
        "clear_all: in-memory annotation list emptied")

    -- THE RESURRECTION GUARD: a save after clear_all must keep it empty.
    ui._simulate_save()
    h.assert_equal(#doc_settings._store[key], 0,
        "clear_all: deletion survives the next save (NOT resurrected)")
end


-- ----------------------------------------------------------------------------
-- TEST 6: clear_all robustness — no ui.annotation (doc not loaded) must not
-- crash, and still clears the disk keys.
-- ----------------------------------------------------------------------------


do
    local doc_settings = make_doc_settings()
    doc_settings._store["annotations"] = { ann("x", "/body/p", "x") }
    local ui_no_ann = { rolling = true, doc_settings = doc_settings }

    local okp = pcall(DocSettingsBridge.clear_all, ui_no_ann)
    h.assert_true(okp, "clear_all without ui.annotation does not crash")
    h.assert_equal(#doc_settings._store["annotations"], 0,
        "clear_all still empties the disk key when ui.annotation is absent")

    -- nil ui is a no-op (no crash).
    local okn = pcall(DocSettingsBridge.clear_all, nil)
    h.assert_true(okn, "clear_all(nil) is a safe no-op")
end


-- ----------------------------------------------------------------------------
-- TEST 7 (Opportunity B): when KOReader's native updateAnnotations is present,
-- apply_and_refresh calls it — which recomputes each item's stale pageno/pageref
-- from the current pagination — and prefers it over a bare sortItems.
-- ----------------------------------------------------------------------------


do
    local doc_settings = make_doc_settings()
    doc_settings._store["annotations"] = {}

    local update_called = false
    local sort_called   = false

    -- Fake annotation manager that mimics KOReader: updateAnnotations(true)
    -- recomputes pageno (here: from a fake "current pagination") and sorts.
    -- The live list is KOReader's own — seeded with an item carrying a STALE
    -- pageno (e.g. KOReader loaded it from a sidecar written by another
    -- device with different pagination).
    local annotation = {
        annotations = {
            { pos0 = "/body/p[1]", pos1 = "/body/p[1]", text = "x",
              drawer = "lighten", datetime = "2026-01-01 00:00:00",
              pageno = 42 },  -- stale pageno
        },
        sortItems = function() sort_called = true end,
        updateAnnotations = function(self, needs_update)
            update_called = true
            if needs_update then
                -- Mimic updatePageNumbers: recompute pageno for every item
                -- from the CURRENT device's pagination (here: page = 999 to
                -- prove the stale value was overwritten).
                for _, item in ipairs(self.annotations) do
                    item.pageno = 999
                end
            end
        end,
    }
    local ui = {
        rolling = true,
        doc_settings = doc_settings,
        annotation = annotation,
    }

    local merged_state = {
        ["k1"] = { pos0 = "/body/p[1]", pos1 = "/body/p[1]", text = "x",
                   drawer = "lighten", datetime = "2026-01-01 00:00:00",
                   pageno = 42 },
    }

    DocSettingsBridge.apply_and_refresh(ui, merged_state, { strip_sync_metadata = true })

    h.assert_true(update_called,
        "apply_and_refresh calls native updateAnnotations when available")
    h.assert_false(sort_called,
        "apply_and_refresh prefers updateAnnotations over a bare sortItems")
    h.assert_equal(ui.annotation.annotations[1].pageno, 999,
        "stale pageno in KOReader's OWN list is recomputed from current pagination")
end


-- ----------------------------------------------------------------------------
-- TEST 8 (THE on-device deletion-resurrection guard): a locally-deleted
-- annotation must NOT be restored into the live list by a sync apply.
--
-- THE BUG this guards against (empirically reproduced on-device, 2026-06):
--   User deletes an annotation → KOReader removes it from the live list →
--   a save/checkRemote cycle runs the merge against state that still
--   contains the annotation (stale doc_settings / shared file) → the merged
--   result includes the annotation → _refresh_ui used to do
--   `ui.annotation.annotations = merged_list`, restoring the deleted
--   annotation into the open document.  Permanently — the dialog closes,
--   the annotation stays.
--
--   The fix: _refresh_ui never replaces the live list.  KOReader owns it.
-- ----------------------------------------------------------------------------


do
    -- The user had one annotation and just deleted it: live list is empty,
    -- but the merge (from a stale shared file) still carries it.
    local ui, doc_settings, key = make_ui{
        initial_annotations = {},   -- live list: deletion already applied
    }
    local stale_merged = {
        ["k_zombie"] = ann("a", "/body/p[1]", "deleted-by-user"),
    }

    DocSettingsBridge.apply_and_refresh(ui, stale_merged, { strip_sync_metadata = true })

    -- doc_settings gets the merge (the shared-file view) — that's fine and
    -- converges via last_sync on later cycles…
    h.assert_equal(#doc_settings._store[key], 1,
        "deletion guard: merge reaches doc_settings (converges later)")

    -- …but the LIVE list must stay as the user left it: EMPTY.  This is the
    -- exact assertion that fails with the old overwrite behaviour.
    h.assert_equal(#ui.annotation.annotations, 0,
        "deletion guard: locally-deleted annotation is NOT restored into the live list")
end


-- ----------------------------------------------------------------------------
-- TEST 9 (THE HARD RULE — no live-list mutation, EVER): a sync apply whose
-- merge carries BOTH a tombstone for a live entry AND a new remote-alive
-- entry must leave the live list COMPLETELY untouched — same table object,
-- same length, same items.
--
-- Why this is the rule (empirically settled on-device, 2026-06, three
-- failed variants):
--   * replacing the table detached open dialogs (deletes landed in an
--     orphaned copy);
--   * ADDING merge entries re-added a just-deleted annotation
--     synchronously whenever tombstone synthesis failed (last_sync
--     discontinuity across plugin upgrades made that the common case);
--   * REMOVING tombstoned entries actively deleted live annotations on
--     open when shared files carried stale tombstones from earlier
--     sessions — real data loss of pre-Syncery annotations.
-- The live list belongs to KOReader alone.
-- ----------------------------------------------------------------------------


do
    local Identity = require("syncery_ann/identity")
    local ui, doc_settings, key = make_ui{
        initial_annotations = { ann("keep", "/body/p[1]", "mine-alive") },
    }
    local before_table = ui.annotation.annotations
    local before_len   = #before_table
    local before_first = before_table[1]

    -- Build the merged map keyed EXACTLY like production: by compute_key.
    local dead = ann("keep", "/body/p[1]", "mine-alive")
    dead.deleted = true
    dead.datetime_updated = "2026-06-12 00:00:00"
    local new_entry = ann("new", "/body/p[7]", "remote-alive")

    local merged = {
        [Identity.compute_key(dead)]      = dead,       -- tombstone for the LIVE entry
        [Identity.compute_key(new_entry)] = new_entry,  -- remote-alive, absent live
    }

    DocSettingsBridge.apply_and_refresh(ui, merged, { strip_sync_metadata = true })

    h.assert_true(rawequal(before_table, ui.annotation.annotations),
        "no-mutation: live list is the SAME table object")
    h.assert_equal(#ui.annotation.annotations, before_len,
        "no-mutation: live list length unchanged (no removal, no addition)")
    h.assert_true(rawequal(ui.annotation.annotations[1], before_first),
        "no-mutation: the live entry object itself is untouched")

    -- doc_settings still receives the merge (alive-only) — that is the
    -- channel through which the merge reaches the NEXT book open.
    h.assert_equal(#doc_settings._store[key], 1,
        "no-mutation: doc_settings got the merged alive list (k_new only)")
end


-- ----------------------------------------------------------------------------
-- TEST 11 (clear_all preserves table identity): Delete-all wipes the live
-- list IN PLACE — an open dialog holding the reference sees it empty, and
-- edits never land in an orphaned copy.
-- ----------------------------------------------------------------------------


do
    local ui, doc_settings, key = make_ui{
        initial_annotations = { ann("a", "/body/p[1]", "one"),
                                ann("b", "/body/p[2]", "two") },
    }
    local before_table = ui.annotation.annotations

    DocSettingsBridge.clear_all(ui)

    h.assert_true(rawequal(before_table, ui.annotation.annotations),
        "clear_all: live list is the SAME table object (wiped in place)")
    h.assert_equal(#ui.annotation.annotations, 0,
        "clear_all: live list emptied")
end


-- ----------------------------------------------------------------------------
-- stage_pending_at_close honours adapt_highlight_style (threaded param).
--
-- The close-time delivery (G) must strip color/drawer when this device has
-- adapt_highlight_style=true -- the SAME option the removed step-7 apply
-- honoured.  Before the fix the writer passed a hardcoded `false`, so an
-- adapt_highlight_style device silently kept incoming color/drawer.  These
-- assertions guard the param threaded through stash -> onSaveSettings ->
-- stage_pending_at_close (ANNOTATION_DELIVERY_DESIGN.md S2 / G-wiring).
-- ----------------------------------------------------------------------------


do
    -- colored_ann(device_id): a styled highlight authored by `device_id`.
    local function colored_ann(device_id)
        return {
            pos0 = "/body/p[3]", pos1 = "/body/p[3]",
            page = "/body/p[3]",          -- string page = rolling format
            text = "styled",
            color = "red",
            drawer = "underscore",
            device_id = device_id,
            datetime = "2026-01-01 00:00:00",
        }
    end

    -- adapt_highlight_style restyles ONLY annotations from OTHER devices.
    -- INCOMING (device_id ~= local) + adapt=TRUE -> color stripped, drawer
    -- REPLACED with this device's default drawer.  NOT nil: a drawer-less
    -- annotation reads as a page bookmark in KOReader (readerannotation: no
    -- drawer = page bookmark), so nil-ing it would corrupt the highlight TYPE.
    local ui_a = make_ui{ saved_drawer = "marker" }
    local r_a = DocSettingsBridge.stage_pending_at_close(
        ui_a, { k1 = colored_ann("remote_dev") }, true, "this_dev")
    h.assert_equal(r_a, "written", "stage_pending_at_close wrote (adapt=true)")
    local written_a = ui_a.doc_settings._store["annotations"]
    h.assert_true(type(written_a) == "table" and #written_a == 1,
        "stage_pending_at_close wrote one annotation (adapt=true)")
    h.assert_nil(written_a[1].color,
        "adapt restyles INCOMING: strips color at close")
    h.assert_equal(written_a[1].drawer, "marker",
        "adapt restyles INCOMING: replaces drawer with device default (stays a HIGHLIGHT)")

    -- OWN highlight (device_id == local) + adapt=TRUE -> left UNTOUCHED: the
    -- user's own style is preserved; only other devices' highlights adapt.
    local ui_own = make_ui{ saved_drawer = "marker" }
    DocSettingsBridge.stage_pending_at_close(
        ui_own, { k1 = colored_ann("this_dev") }, true, "this_dev")
    local written_own = ui_own.doc_settings._store["annotations"]
    h.assert_equal(written_own[1].color, "red",
        "adapt leaves OWN highlight's color untouched")
    h.assert_equal(written_own[1].drawer, "underscore",
        "adapt leaves OWN highlight's drawer untouched (own style preserved)")

    -- adapt_highlight_style = FALSE -> color/drawer preserved (even incoming).
    local ui_b = make_ui{}
    DocSettingsBridge.stage_pending_at_close(
        ui_b, { k1 = colored_ann("remote_dev") }, false, "this_dev")
    local written_b = ui_b.doc_settings._store["annotations"]
    h.assert_equal(written_b[1].color, "red",
        "adapt_highlight_style=false keeps color at close")
    h.assert_equal(written_b[1].drawer, "underscore",
        "adapt_highlight_style=false keeps drawer at close")

    -- A BOOKMARK (no drawer) from another device must stay a bookmark under
    -- adapt: no spurious drawer is added (which would turn it into a highlight).
    local ui_c = make_ui{ saved_drawer = "marker" }
    DocSettingsBridge.stage_pending_at_close(ui_c,
        { k1 = { pos0 = "/body/p[4]", page = "/body/p[4]", text = "mark",
                 device_id = "remote_dev",
                 datetime = "2026-01-01 00:00:00" } }, true, "this_dev")
    local written_c = ui_c.doc_settings._store["annotations"]
    h.assert_nil(written_c[1].drawer,
        "adapt_highlight_style=true leaves a bookmark drawer-less (stays a bookmark)")
end


-- ----------------------------------------------------------------------------
-- _prepare_for_doc_settings KEEPS datetime_updated (native field), strips the
-- Syncery bookkeeping fields.
--
-- THE BUG this guards against (perpetual re-pull):
--   datetime_updated is a NATIVE KOReader annotation field that our merge
--   compares against (Merge._pick_newer_of_two reads `datetime_updated or
--   datetime`).  An earlier version stripped it here as if it were Syncery
--   bookkeeping.  The doc_settings copy then lost its last-modified time;
--   every collect read the older `datetime` as the effective last-modified,
--   the merge always judged the shared side "newer", and the book re-pulled +
--   reloaded its annotations on EVERY sync, forever, for any edited annotation.
--   Keeping datetime_updated lets collect read back the value the merge
--   produced, so an unchanged annotation compares equal.
--
--   device_id / device_label / deleted ARE Syncery-internal and stay stripped.
-- ----------------------------------------------------------------------------


do
    local ann = {
        pos0 = "/body/p[5]", pos1 = "/body/p[5]",
        page = "/body/p[5]",
        text = "edited note",
        datetime         = "2026-06-16 12:28:38",   -- creation
        datetime_updated = "2026-06-16 12:28:43",   -- later edit (NATIVE field)
        device_id        = "remote_dev",
        device_label     = "Kindle",
        deleted          = false,
    }

    local clean = DocSettingsBridge._prepare_for_doc_settings(ann, false, true, nil, nil)

    h.assert_equal(clean.datetime_updated, "2026-06-16 12:28:43",
        "_prepare KEEPS datetime_updated (native field the merge compares)")
    h.assert_equal(clean.datetime, "2026-06-16 12:28:38",
        "_prepare keeps datetime (creation time)")
    h.assert_nil(clean.device_id,
        "_prepare strips device_id (Syncery-internal)")
    h.assert_nil(clean.device_label,
        "_prepare strips device_label (Syncery-internal)")
    h.assert_nil(clean.deleted,
        "_prepare strips deleted (Syncery-internal tombstone flag)")
end


print("doc_settings_refresh_spec: all assertions passed")
