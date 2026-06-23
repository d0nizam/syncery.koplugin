-- =============================================================================
-- syncery_ann/doc_settings_bridge.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- It's the translator between KOReader's native annotation storage and
-- Syncery's keyed state-map representation.  Two directions:
--
--   READ:  KOReader stores annotations as a flat list in doc_settings,
--          under either "annotations" (rolling docs like EPUB) or
--          "annotations_paging" (PDF, DJVU, CBZ).  We turn that list
--          into a map keyed by position (from identity.compute_key).
--
--   WRITE: We take our keyed map, drop tombstones, and emit a list
--          that KOReader can store back into doc_settings.
--
-- Nobody else in the annotation subsystem talks to KOReader's
-- doc_settings directly.  Sync code uses our keyed map; this is the
-- one place that converts.
--
--
-- WHICH KEY: "annotations" OR "annotations_paging"?
--
-- KOReader picks the storage key by document type:
--   * Rolling documents  → "annotations"
--   * Paging documents   → "annotations_paging"
--
-- We use `ui.paging` to detect which.  If a fresh book has annotations
-- in the "wrong" key (legacy data, or imported from another tool), we
-- read from whichever is populated but always write back to the canonical
-- one for the document type.
--
--
-- ADAPT-HIGHLIGHT-STYLE
--
-- When this device has `adapt_highlight_style = true`, annotations that
-- came from ANOTHER device should display in THIS device's preferred
-- style, not whatever color/drawer the originating device used.  This
-- device's OWN highlights (stamped with our device_id by the
-- orchestrator's _stamp_local_annotations) keep the style the user gave
-- them.  The "from another device" test is `annotation.device_id ~=
-- local_device_id` (a nil local_device_id falls back to adapting all).
-- We REPLACE the `drawer`
-- field with this device's default highlight drawer
-- (view.highlight.saved_drawer, fallback "lighten") so the STYLE is
-- local, and we strip the `color` field -- KOReader then renders the
-- highlight with NO colour (for the default "lighten" style a plain
-- neutral/grey shading via darkenRect; underscore a grey line; strikeout
-- black).  It does NOT substitute this device's saved colour: the draw
-- path does `item.color and colorFromName(item.color)` (nil stays nil),
-- and only the legacy bookmark->annotation migration fills saved_color,
-- never a normal annotation.  So the colour is dropped, not re-coloured.
-- We do NOT nil the drawer: KOReader reads a drawer-less annotation as
-- a page bookmark (readerannotation: `if not item.drawer then -- page
-- bookmark`), so nil-ing it would silently turn the highlight into a
-- bookmark.  Bookmarks (no drawer) are left untouched.
--
-- This is a display-time preference; it does NOT affect what gets
-- stored in the shared JSON (other devices still see the original
-- color/drawer).  Hence: we only adapt on the way OUT to doc_settings,
-- never on the way back IN from sync.
--
--
-- BOOKMARKS ARE SEPARATE
--
-- KOReader stores "dog-ear" bookmarks in `doc_settings.bookmarks`,
-- not in the annotations list.  But annotations can become bookmarks
-- (a highlight with `drawer == "marker"`) and vice versa.  We treat
-- whatever KOReader hands us through the annotations list as a single
-- pool — Identity gives bookmark-style highlights their own key prefix
-- already, so they coexist without colliding.  The `bookmarks` list
-- itself is handled by separate sync code, not this bridge.
--
-- =============================================================================

local Identity = require("syncery_ann/identity")
local Merge    = require("syncery_ann/merge")
local logger   = require("logger")

local DocSettingsBridge = {}


-- ----------------------------------------------------------------------------
-- Constants
-- ----------------------------------------------------------------------------

local KEY_ROLLING = "annotations"
local KEY_PAGING  = "annotations_paging"


-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------


--- Read KOReader's current annotation list and convert it to our keyed map.
---
--- Returns a state map (key -> annotation table) suitable for feeding
--- into Merge.three_way().  Annotations whose positions can't be keyed
--- (corrupted data, missing pos0/pos1) are silently dropped — they
--- can't participate in a key-based merge.
---
--- The returned annotations are SHALLOW COPIES of what was in
--- doc_settings, so the caller is free to add bookkeeping fields
--- (device_id, etc.) without polluting KOReader's live data.  Native
--- fields including `datetime_updated` are carried through as-is.
---
--- @param ui table KOReader's ReaderUI instance (or anything with .doc_settings + .paging).
--- @return table The state map.  Empty table if no annotations exist.
--- @return number How many annotations were skipped due to invalid identity.
function DocSettingsBridge.read_annotations_as_map(ui)
    local state_map     = {}
    local skipped_count = 0

    local annotation_list = DocSettingsBridge._read_active_list(ui)
    if not annotation_list then
        return state_map, 0
    end

    for _, ann in ipairs(annotation_list) do
        local key = Identity.compute_key(ann)
        if key then
            -- Shallow-copy so later writers don't mutate the live list.
            local copy = {}
            for field_name, field_value in pairs(ann) do
                copy[field_name] = field_value
            end
            state_map[key] = copy
        else
            skipped_count = skipped_count + 1
        end
    end

    if skipped_count > 0 then
        logger.info(string.format(
            "Syncery doc_settings_bridge: skipped %d annotation(s) with no valid identity",
            skipped_count))
    end

    return state_map, skipped_count
end


--- Write our keyed state-map back into KOReader's annotation list.
---
--- Tombstones are filtered out — KOReader doesn't know about deleted
--- annotations, it just wants the list of live ones.  The list is
--- sorted by position-derived key for determinism (the same map always
--- produces the same on-disk list, which makes diffs and backup checks
--- behave sanely).
---
--- The options table controls per-device display preferences:
---
---   * options.adapt_highlight_style (bool):  when true, annotations from
---     OTHER devices adopt this device's STYLE: REPLACE `drawer` with this
---     device's default highlight drawer (never nil-ed -- a drawer-less
---     annotation reads as a page bookmark) and strip `color` (KOReader
---     then renders them with no colour -- neutral/grey for "lighten"; it
---     does NOT fill this device's saved colour).  This device's own
---     annotations (device_id == options.device_id) are left as-authored.
---   * options.strip_sync_metadata   (bool):  when true, also strip
---     our internal bookkeeping fields (device_id, device_label,
---     deleted) before handing the list to KOReader.  KOReader
---     tolerates extra fields, but stripping them keeps the
---     doc_settings file clean.  `datetime_updated` is NOT in this set —
---     it is a native KOReader field the merge depends on.  Default: true.
---
--- @param ui table KOReader's ReaderUI instance.
--- @param state_map table The state map to write.
--- @param options table|nil Optional preferences (see above).
--- @return boolean True on success.
--- @return number How many alive annotations were written.
function DocSettingsBridge.write_annotations_from_map(ui, state_map, options)
    options = options or {}
    local strip_sync_metadata = options.strip_sync_metadata
    if strip_sync_metadata == nil then strip_sync_metadata = true end

    if not ui or not ui.doc_settings then
        return false, 0
    end

    local default_drawer = DocSettingsBridge._device_default_drawer(ui)
    local local_device_id = options.device_id

    -- Build the list of alive annotations in deterministic key order.
    local alive_entries_with_keys = {}
    for key, annotation in pairs(state_map or {}) do
        if annotation and not annotation.deleted then
            table.insert(alive_entries_with_keys, { key = key, ann = annotation })
        end
    end
    table.sort(alive_entries_with_keys, function(a, b) return a.key < b.key end)

    local output_list = {}
    for _, entry in ipairs(alive_entries_with_keys) do
        local clean = DocSettingsBridge._prepare_for_doc_settings(
            entry.ann, options.adapt_highlight_style, strip_sync_metadata,
            default_drawer, local_device_id)
        table.insert(output_list, clean)
    end

    local target_key = DocSettingsBridge._target_key_for_ui(ui)
    ui.doc_settings:saveSetting(target_key, output_list)

    return true, #output_list, output_list
end


--- Apply a fresh state map: write doc_settings + refresh derived state.
---
--- DELIBERATELY does NOT touch KOReader's live in-memory annotation list —
--- in EITHER direction.  Empirically settled on-device (2026-06, three
--- rounds): every variant that mutated the live list mid-session failed.
---   * REPLACING the table detached open dialogs (deletes landed in an
---     orphaned copy — "the dialog closes, the annotation stays").
---   * ADDING merge entries back resurrected just-deleted annotations
---     synchronously whenever tombstone synthesis failed (it depends
---     entirely on last_sync continuity, which plugin upgrades and
---     storage changes cannot guarantee).
---   * REMOVING tombstoned entries actively deleted live annotations on
---     open when shared files carried stale/poisoned tombstones from
---     earlier sessions — real user data loss.
--- The live list belongs to KOReader alone.  Merge results reach the
--- reader on the next book open (KOReader loads doc_settings then);
--- doc_settings/shared stay convergent via the last_sync ancestor.
---
--- @param ui table The ReaderUI instance.
--- @param state_map table The merged state map (with tombstones).
--- @param options table|nil Same options as write_annotations_from_map.
--- @return boolean True on success.
--- @return number How many alive annotations were written.
function DocSettingsBridge.apply_and_refresh(ui, state_map, options)
    local ok, count =
        DocSettingsBridge.write_annotations_from_map(ui, state_map, options)
    if not ok then return false, 0 end

    DocSettingsBridge._refresh_ui(ui)
    return true, count
end


--- Persist a merged annotation map into doc_settings at DOCUMENT-CLOSE time,
--- so the NEXT open of this book loads it into KOReader's live list.
---
--- This is the delivery path for remote pulls AND remote deletions to an
--- already-open document.  It is NOT an in-session apply: it must run only
--- at close, AFTER ReaderAnnotation:onSaveSettings has written the live list
--- (so we overwrite KOReader's just-written value), and BEFORE the close
--- flush serialises doc_settings to disk.  KOReader's next-open
--- onReadSettings reads the base "annotations" key into the live list, and
--- the annotations_externally_modified flag we set triggers its pageno/sort
--- recompute.
---
--- WHY THE BASE KEY FOR BOTH FORMATS (traced to KOReader source):
--- onReadSettings reads the base "annotations" key as the PRIMARY for both
--- rolling and paging documents; the "_paging"/"_rolling" suffix keys are
--- only transient format-migration backups it never reads as primary.  So a
--- close-time write MUST target the base key, or a PDF/paging book would
--- never see it (the suffix is ignored on read).
---
--- THE PROTECTIVE GATE (distinguishes a legitimate full deletion from a
--- merge bug): if the merged map carries TOMBSTONES, an empty alive-set is a
--- real "everything was deleted" and we write the empty list (delivering the
--- deletion).  Only a TRULY empty map (no alive entries AND no tombstones —
--- i.e. the merge produced no information at all) combined with a non-empty
--- live list is treated as anomalous and SKIPPED, to avoid wiping the user's
--- annotations on a merge fault.
---
--- @param ui table The ReaderUI instance (live, document may be closing).
--- @param state_map table The merged annotation map (alive + tombstones).
--- @param adapt_highlight_style boolean When true, restyle annotations from
---        OTHER devices to this device's style: replace drawer with this
---        device's default, and strip color (KOReader renders them with no
---        colour -- not re-coloured); own annotations untouched.  Threaded
---        from the close-time stash.
--- @param local_device_id string This device's id; annotations whose device_id
---        differs are treated as incoming.  Threaded from the close-time stash.
--- @return string One of "written" | "skipped_empty" | "no_state".
function DocSettingsBridge.stage_pending_at_close(ui, state_map, adapt_highlight_style, local_device_id)
    if not ui or not ui.doc_settings then return "no_state" end
    if type(state_map) ~= "table" then return "no_state" end

    local default_drawer = DocSettingsBridge._device_default_drawer(ui)

    local alive_count, tombstone_count = 0, 0
    for _, entry in pairs(state_map) do
        if entry then
            if entry.deleted then tombstone_count = tombstone_count + 1
            else alive_count = alive_count + 1 end
        end
    end

    -- Protective gate: a truly empty merge (no alive, no tombstones) while the
    -- live list still holds annotations is anomalous — skip rather than wipe.
    -- A tombstone-bearing map with zero alive IS a legitimate full deletion
    -- and falls through to write the (empty) alive list.
    if alive_count == 0 and tombstone_count == 0 then
        local live = ui.annotation and ui.annotation.annotations
        if type(live) == "table" and #live > 0 then
            return "skipped_empty"
        end
    end

    -- Build the alive list in deterministic key order, stripped for storage.
    local alive_entries = {}
    for key, entry in pairs(state_map) do
        if entry and not entry.deleted then
            table.insert(alive_entries, { key = key, ann = entry })
        end
    end
    table.sort(alive_entries, function(a, b) return a.key < b.key end)

    local output_list = {}
    for _, entry in ipairs(alive_entries) do
        table.insert(output_list,
            DocSettingsBridge._prepare_for_doc_settings(
                entry.ann, adapt_highlight_style, true, default_drawer,
                local_device_id))
    end

    -- BASE key for BOTH formats (see function doc).  Also flag the external
    -- modification so onReadSettings recomputes pageno/pageref and re-sorts.
    ui.doc_settings:saveSetting(KEY_ROLLING, output_list)
    ui.doc_settings:saveSetting("annotations_externally_modified", true)

    return "written"
end


--- Clear ALL annotations for an open document — both on disk and in memory.
---
--- Mirror of apply_and_refresh for the empty case.  Clears the doc_settings
--- keys (annotations / annotations_paging / bookmarks) AND replaces
--- KOReader's in-memory annotation list with an empty one.  The in-memory
--- clear is load-bearing: ReaderAnnotation writes self.annotations back to
--- doc_settings on every save (onSaveSettings), so clearing only the on-disk
--- keys would let the next save resurrect the just-deleted annotations from
--- the stale in-memory copy.
---
--- Both keys are cleared defensively: a book read on a paging device once and
--- a rolling one later may have data under either key.
---
--- @param ui table The ReaderUI instance.
function DocSettingsBridge.clear_all(ui)
    if not ui then return end

    if ui.doc_settings then
        ui.doc_settings:saveSetting("annotations",        {})
        ui.doc_settings:saveSetting("annotations_paging", {})
        ui.doc_settings:saveSetting("bookmarks",          {})
    end

    -- Load-bearing in-memory clear — IN PLACE.  Never replace the table
    -- object: open dialogs and KOReader modules hold a reference to it; a
    -- fresh table would detach them and their edits would land in the
    -- orphaned copy.  (clear_all is the ONE permitted live-list mutation —
    -- it implements an explicit user action, Delete all, not a sync apply.)
    if ui.annotation and type(ui.annotation.annotations) == "table" then
        local list = ui.annotation.annotations
        for i = #list, 1, -1 do
            list[i] = nil
        end
    end
end


--- Find the annotation that currently corresponds to a given identity key.
---
--- Useful when KOReader hands us a position (after the user makes a
--- new highlight) and we need to look up "do we already have this
--- one in our state map?".  Returns the in-memory KOReader annotation
--- if found, or nil.
---
--- @param ui table The ReaderUI instance.
--- @param key string The identity key to look up.
--- @return table|nil The matching annotation, or nil.
function DocSettingsBridge.find_by_key(ui, key)
    local annotation_list = DocSettingsBridge._read_active_list(ui)
    if not annotation_list then return nil end

    for _, ann in ipairs(annotation_list) do
        if Identity.compute_key(ann) == key then
            return ann
        end
    end
    return nil
end


-- ----------------------------------------------------------------------------
-- Internal helpers
-- ----------------------------------------------------------------------------


--- Read the active annotation list for THIS book.
---
--- Live session: `ui.annotation.annotations` is the authoritative current
--- list — KOReader mutates it in place on every highlight/note/bookmark
--- change (readerannotation `addItem`), while `doc_settings["annotations"]`
--- only catches up at the next onSaveSettings/onFlushSettings.  A freshly
--- opened, never-saved book holds the user's new annotations in the live
--- list while doc_settings is still nil, so read the live list directly
--- whenever it is present.
---
--- Bulk-ingest passes a synthetic `{ doc_settings = ds }` (no `.annotation`
--- module, a sidecar read straight off disk); it falls through to the
--- doc_settings read — the document-type key first, then the other key if
--- it is populated and the canonical one is empty (imported legacy data).
--- Returns nil only when there is no doc_settings to read.
function DocSettingsBridge._read_active_list(ui)
    if not ui or not ui.doc_settings then return nil end

    -- Live session: the in-memory list is always current; prefer it.  The
    -- synthetic bulk-ingest ui carries no `.annotation`, so it falls through
    -- to the disk read below.
    local annotation = ui.annotation
    if annotation and type(annotation.annotations) == "table" then
        return annotation.annotations
    end

    local primary_key   = DocSettingsBridge._target_key_for_ui(ui)
    local secondary_key = (primary_key == KEY_ROLLING) and KEY_PAGING or KEY_ROLLING

    local primary = ui.doc_settings:readSetting(primary_key)
    if type(primary) == "table" and next(primary) ~= nil then
        return primary
    end

    local secondary = ui.doc_settings:readSetting(secondary_key)
    if type(secondary) == "table" and next(secondary) ~= nil then
        return secondary
    end

    -- Both empty; return the primary (possibly an empty table) so
    -- callers can still iterate safely.
    return primary or {}
end


--- Pick the doc_settings key that KOReader uses for THIS document type.
---
--- Paging documents (PDF, DJVU, CBZ) use "annotations_paging".  Anything
--- else (EPUB, FB2, MOBI, TXT) uses "annotations".  `ui.paging` is the
--- canonical signal — it's set by the engine at document-open time.
function DocSettingsBridge._target_key_for_ui(ui)
    if ui and ui.paging then
        return KEY_PAGING
    end
    return KEY_ROLLING
end


--- The drawer (highlight style) this device would use for a NEW highlight.
--- adapt_highlight_style uses it so an adapted highlight adopts the LOCAL
--- style without losing its drawer: a drawer-less annotation reads as a page
--- bookmark in KOReader (readerannotation: `if not item.drawer`).  Falls back
--- to "lighten" (KOReader's default) so the result is NEVER nil.
function DocSettingsBridge._device_default_drawer(ui)
    local view = ui and ui.view
    local highlight = view and view.highlight
    return (highlight and highlight.saved_drawer) or "lighten"
end


--- Make a copy of an annotation suitable for storing in doc_settings.
---
--- Two filtering passes:
---   1. If adapt_highlight_style is set AND the annotation came from
---      another device (annotation.device_id ~= local_device_id), strip
---      color (KOReader renders it with no colour -- not re-coloured) and
---      REPLACE the highlight drawer with this device's default (not nil --
---      a drawer-less annotation reads as a page bookmark), so it displays
---      in this device's STYLE.  Own annotations are left
---      untouched.
---   2. If strip_sync_metadata is set, drop the Syncery-specific
---      bookkeeping fields that KOReader doesn't need (device_id,
---      device_label, deleted).
---
--- We keep `datetime` (the original creation time) — KOReader uses it
--- as the "added on" date in the annotation list UI — and we ALSO keep
--- `datetime_updated`: it is a NATIVE KOReader field (last modification
--- time) that our merge compares against, so it must survive the
--- round-trip through doc_settings (see the strip block below).
function DocSettingsBridge._prepare_for_doc_settings(
        annotation, adapt_highlight_style, strip_sync_metadata, default_drawer,
        local_device_id)

    local clean = {}
    for field_name, field_value in pairs(annotation) do
        clean[field_name] = field_value
    end

    -- Only restyle annotations that came from ANOTHER device.  This device's
    -- own highlights (stamped with local_device_id) keep the style the user
    -- gave them.  A nil local_device_id adapts all (no owner id supplied).
    if adapt_highlight_style and annotation.device_id ~= local_device_id then
        clean.color = nil
        -- A drawer marks an annotation as a HIGHLIGHT; a page bookmark has
        -- none (readerannotation: `if not item.drawer then -- page bookmark`).
        -- Replace a highlight's drawer with this device's default so it adopts
        -- the local STYLE without changing its TYPE.  Setting it to nil would
        -- silently turn the highlight into a bookmark.  Bookmarks (no drawer)
        -- are left untouched.
        if clean.drawer ~= nil then
            clean.drawer = default_drawer or "lighten"
        end
    end

    if strip_sync_metadata then
        clean.device_id        = nil
        clean.device_label     = nil
        clean.deleted          = nil
        -- NOTE: datetime_updated is deliberately NOT stripped.  It is a
        -- NATIVE KOReader annotation field (readerannotation buildAnnotation:
        -- "last modification time"), which KOReader writes on edit and our
        -- merge compares against (Merge._pick_newer_of_two reads
        -- `datetime_updated or datetime`).  Stripping it desynchronises the
        -- doc_settings copy from the shared state: every subsequent collect
        -- reads an annotation whose effective last-modified falls back to the
        -- older `datetime`, the merge then always sees the shared side as
        -- "newer", and the book re-pulls + reloads its annotations on EVERY
        -- sync, forever.  Keeping it lets collect read back the same value the
        -- merge produced, so an unchanged annotation compares equal.
    end

    return clean
end


--- Refresh KOReader's DERIVED annotation state — never the list itself.
---
--- HARD RULE (settled empirically on-device, 2026-06, three failed
--- variants): Syncery does not add to, remove from, or replace
--- `ui.annotation.annotations`.  The live list belongs to KOReader alone.
--- See apply_and_refresh's doc for the three failure modes.
function DocSettingsBridge._refresh_ui(ui)
    if not ui then return end

    -- Refresh KOReader's derived state against the list KOReader owns:
    -- updateAnnotations(needs_update=true) recomputes each item's
    -- pageno/pageref from the CURRENT document's pagination AND sorts into
    -- position order (a pulled annotation carries the SOURCE device's
    -- pageno).  Native method preferred (the same one onReadSettings
    -- schedules); sortItems is the fallback for older builds / test fakes.
    if ui.annotation and type(ui.annotation.annotations) == "table" then
        if type(ui.annotation.updateAnnotations) == "function" then
            pcall(ui.annotation.updateAnnotations, ui.annotation, true)
        elseif type(ui.annotation.sortItems) == "function" then
            pcall(ui.annotation.sortItems, ui.annotation, ui.annotation.annotations)
        end
    end

    -- Broadcast a generic event so peripheral consumers (status badge,
    -- footer counters, an open bookmark list) can refresh themselves.
    local ok_event, Event = pcall(require, "ui/event")
    local ok_uim,   UIManager = pcall(require, "ui/uimanager")
    if ok_event and ok_uim and Event and UIManager then
        pcall(function()
            UIManager:broadcastEvent(Event:new("AnnotationsModified"))
        end)
    end
end


return DocSettingsBridge
