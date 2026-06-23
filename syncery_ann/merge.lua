-- =============================================================================
-- syncery_ann/merge.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- It merges three views of the same annotations data and produces a
-- single consistent result:
--
--   * LOCAL view: what's on this device right now.
--   * LAST-SYNC view: what was on this device the last time we successfully
--                     synced with other devices (this is the "common
--                     ancestor" in 3-way-merge terminology).
--   * REMOTE view: what's currently in the shared JSON file (which
--                  other devices may have updated via Syncthing/cloud).
--
-- The result is "the right thing" — combining edits from this device
-- with edits from other devices, correctly handling deletions, and
-- preferring whichever side made the most recent change to any given
-- annotation.
--
--
-- WHY THREE VIEWS AND NOT TWO
--
-- Imagine you have an annotation X on device A.  On device B, X is
-- missing.  Why is X missing on B?  There are two possibilities:
--
--   1. The user deleted X on B yesterday.
--   2. The user hasn't synced B yet — X was never seen by B.
--
-- With only "local" and "remote" views, we cannot tell these apart.
-- If we assume case 1, we delete X on A.  If we assume case 2, we
-- copy X back to B.  Pick the wrong assumption and we either lose
-- the user's edits or undo their deletions.
--
-- The "last-sync" view is the missing puzzle piece.  It records what
-- B had seen at the time of its last successful sync.  Now we can
-- tell the cases apart:
--   * If X was in last-sync but not in local → user deleted it locally.
--   * If X was NOT in last-sync and not in local → it's new from remote,
--     adopt it.
--
-- This is the same logic that Git uses for 3-way merging.
--
--
-- HOW WE STORE THE DATA
--
-- Each "view" is a Lua table (map) where the keys are position-based
-- identity keys (from identity.lua) and the values are annotation
-- tables.  Annotations marked with `deleted = true` are "tombstones"
-- — they record that an annotation was deleted, and they participate
-- in the merge just like alive entries.
--
--
-- THE MERGE RULES (formal version)
--
-- For each key K that appears in any of the three views:
--
--   1. If K is in LAST-SYNC but not in LOCAL, the user deleted it.
--      Materialize a fresh tombstone in LOCAL (so it can travel to
--      remote in the next sync).
--
--   2. If K already had a tombstone in LAST-SYNC and isn't in LOCAL,
--      carry the tombstone forward unchanged (the deletion already
--      happened in an earlier sync round; don't bump its timestamp).
--
--   3. For each key in (LOCAL ∪ REMOTE), pick the version with the
--      newer `datetime_updated`.  On exact datetime ties, prefer the
--      tombstone — a deletion happens-after the alive state at the
--      same instant, by causality.
--
-- =============================================================================

local Identity   = require("syncery_ann/identity")
local TimeFormat = require("syncery_ann/time_format")

local Merge = {}


-- ----------------------------------------------------------------------------
-- The 3-way merge itself
-- ----------------------------------------------------------------------------


--- Run a 3-way merge of three annotation maps and produce the merged result.
---
--- All three input maps must use position-based keys (as produced by
--- identity.compute_key).  Pass nil or {} for "this side has no data".
---
--- This function is pure: it does not touch disk, does not modify any
--- of the input tables, and produces the same output for the same
--- input.  All persistence is the caller's responsibility.
---
---
--- @param local_map table|nil What's on this device right now.
--- @param last_sync_map table|nil What was here at the last successful sync.
--- @param remote_map table|nil What's in the shared JSON (other devices' edits).
--- @return table The merged map.
function Merge.three_way(local_map, last_sync_map, remote_map)
    local_map     = local_map     or {}
    last_sync_map = last_sync_map or {}
    remote_map    = remote_map    or {}

    -- We're going to insert fresh tombstones into local_map for
    -- deletions detected by comparing local against last-sync.  But we
    -- don't want to modify the caller's table — make a shallow copy.
    local working_local = {}
    for key, value in pairs(local_map) do
        working_local[key] = value
    end

    Merge._detect_local_deletions(working_local, last_sync_map)

    local merged = Merge._combine_local_and_remote(working_local, remote_map)

    -- KOReader does NOT bump datetime_updated when the TEXT of an existing
    -- note is edited: the bookmark type is unchanged (highlight-with-note stays
    -- "note"), so setBookmarkNote fires no AnnotationsModified event and
    -- onAnnotationsModified never stamps a new time.  Such an edit therefore
    -- ties on datetime, and the newer-wins pick above adopts the remote (old)
    -- copy, silently discarding the edit.  Re-assert note edits that the
    -- ancestor proves are LOCAL-ONLY, taking everything else (incl. style) from
    -- the merge winner so an adapted local style is never leaked to the shared.
    Merge._preserve_local_note_edits(merged, working_local, remote_map, last_sync_map)

    return merged
end


-- ----------------------------------------------------------------------------
-- Per-type filtering (honest highlights / notes / bookmarks sub-toggles)
-- ----------------------------------------------------------------------------


--- Classify an annotation entry as "note", "highlight" or "bookmark".
--- The KEY is authoritative for bookmark-vs-range and survives tombstone
--- compaction, which drops drawer/pos/note (tombstones.lua
--- FIELDS_TO_PRESERVE_ON_COMPACT); a live entry's `note` only splits a RANGE
--- key into highlight-vs-note.  Mirrors KOReader's getBookmarkType
--- (readerbookmark.lua:608) for live entries while staying correct for
--- compacted tombstones.
function Merge.classify_type(key, entry)
    local kind = Identity.parse_key(key)
    if kind == "BOOKMARK" then
        return "bookmark"
    elseif kind == "RANGE" then
        if entry and entry.note then return "note" end
        return "highlight"                  -- compacted range tombstone -> highlight
    end
    -- Malformed/absent key (compute_key would have rejected it at read, so live
    -- entries never land here): best-effort field fallback.
    if entry and entry.drawer then
        if entry.note then return "note" end
        return "highlight"
    end
    return "bookmark"
end


--- The set of keys that are out of scope because their type is disabled.
--- Decided per KEY across all three maps (out iff ANY side classifies the key
--- to a disabled type), so a key whose type differs between maps (a highlight
--- that became a note) is wholly in or wholly out -- never split, never
--- spuriously tombstoned.
--- @param disabled_types table set keyed by type name, e.g. { bookmark = true }
--- @return table set of out-of-scope keys
function Merge._out_scope_keys(local_map, last_sync_map, remote_map, disabled_types)
    local out = {}
    for _, map in ipairs({ local_map, last_sync_map, remote_map }) do
        for key, entry in pairs(map or {}) do
            if disabled_types[Merge.classify_type(key, entry)] then
                out[key] = true
            end
        end
    end
    return out
end


-- ----------------------------------------------------------------------------
-- Single-edit helpers (the convenient API for normal user actions)
-- ----------------------------------------------------------------------------


--- Insert or update a single annotation, returning a new state map.
---
--- This is what you call when the user creates a highlight or edits
--- an existing one.  It computes the right position key, stamps the
--- annotation with the current device's info and a fresh timestamp,
--- and inserts it into a new copy of the state.
---
--- @param state_map table The current state.
--- @param annotation table The annotation to insert.
--- @param device_id string This device's ID (goes into the annotation).
--- @param device_label string|nil Optional friendly label.
--- @return table A new state map with the annotation inserted.
function Merge.upsert_annotation(state_map, annotation, device_id, device_label)
    local key = Identity.compute_key(annotation)
    if not key then
        -- Malformed annotation; can't be keyed, can't be stored.
        return state_map
    end

    -- Build the new entry as a copy of the annotation with extra
    -- bookkeeping fields filled in.
    local new_entry = {}
    for field_name, field_value in pairs(annotation) do
        new_entry[field_name] = field_value
    end

    new_entry.deleted          = false
    new_entry.datetime_updated = TimeFormat.now()
    new_entry.device_id        = device_id or new_entry.device_id
    new_entry.device_label     = device_label or new_entry.device_label

    -- Preserve the original creation timestamp across edits.  If this
    -- is a brand-new annotation with no prior `datetime`, use "now"
    -- as the creation time too.
    local existing_entry = state_map[key]
    if existing_entry and existing_entry.datetime then
        new_entry.datetime = existing_entry.datetime
    elseif not new_entry.datetime then
        new_entry.datetime = new_entry.datetime_updated
    end

    -- Build the output state map: copy everything from the input,
    -- then overwrite this key.
    local new_state = {}
    for k, v in pairs(state_map) do
        new_state[k] = v
    end
    new_state[key] = new_entry

    return new_state
end


--- Mark an annotation as deleted by writing a tombstone at its key.
---
--- The tombstone keeps the annotation's original fields (text, drawer,
--- etc.) — that way another device can still display "annotation X
--- was deleted on device Y" if it wants to.
---
--- Accepts EITHER an annotation table (we'll compute the key) OR the
--- key string directly (useful when the caller already has it).
---
--- @param state_map table The current state.
--- @param annotation_or_key table|string The annotation, or its key.
--- @param device_id string|nil This device's ID (recorded on the tombstone).
--- @param device_label string|nil Optional friendly label.
--- @return table A new state map with the tombstone written.
function Merge.delete_annotation(state_map, annotation_or_key, device_id, device_label)
    local key
    if type(annotation_or_key) == "string" then
        key = annotation_or_key
    else
        key = Identity.compute_key(annotation_or_key)
    end
    if not key then
        return state_map
    end

    local existing_entry = state_map[key] or {}

    local tombstone = {}
    for field_name, field_value in pairs(existing_entry) do
        tombstone[field_name] = field_value
    end
    tombstone.deleted          = true
    tombstone.datetime_updated = TimeFormat.now()
    tombstone.device_id        = device_id or tombstone.device_id
    tombstone.device_label     = device_label or tombstone.device_label

    local new_state = {}
    for k, v in pairs(state_map) do
        new_state[k] = v
    end
    new_state[key] = tombstone

    return new_state
end


--- Extract the list of alive (non-deleted) annotations from a state map.
---
--- This is what we hand to KOReader when populating its doc_settings
--- annotation list.  KOReader doesn't know about tombstones; it just
--- wants the things that should currently be visible.
---
--- @param state_map table The full state.
--- @return table A list (1-indexed array) of alive annotations.
function Merge.list_alive_annotations(state_map)
    local alive_list = {}
    for _, annotation in pairs(state_map or {}) do
        if annotation and not annotation.deleted then
            table.insert(alive_list, annotation)
        end
    end
    return alive_list
end


-- ----------------------------------------------------------------------------
-- Internal: the two phases of the 3-way merge
-- ----------------------------------------------------------------------------


--- Step 1: detect local deletions and add them as tombstones.
---
--- Walks the last-sync map.  For every key that exists in last-sync
--- but NOT in the local map, the user must have deleted it on this
--- device.  We materialize a tombstone in `working_local` so Step 2
--- can treat it as a normal entry.
---
--- We also carry forward tombstones that were already in last-sync —
--- they may still be needed for slower peers to learn about the
--- deletion.  (Without this, an old tombstone disappears from the
--- working set the moment last-sync drops it, and a peer that hasn't
--- synced yet would see the alive entry come back.)
---
--- @param working_local table Map we're filling in (modified in place).
--- @param last_sync_map table The common ancestor view.
function Merge._detect_local_deletions(working_local, last_sync_map)
    local now = TimeFormat.now()

    for key, last_sync_entry in pairs(last_sync_map) do
        local local_has_this_key = working_local[key] ~= nil
        if not local_has_this_key then
            local was_already_tombstoned = last_sync_entry
                and last_sync_entry.deleted

            if was_already_tombstoned then
                -- Carry forward an existing tombstone unchanged.
                -- Don't bump its timestamp — the deletion already
                -- happened, this isn't a new event.
                working_local[key] = last_sync_entry
            else
                -- The user deleted this on the local side.  Build a
                -- fresh tombstone, copying the original fields so
                -- peers can still see what was removed.
                local fresh_tombstone = {}
                for field_name, field_value in pairs(last_sync_entry) do
                    fresh_tombstone[field_name] = field_value
                end
                fresh_tombstone.deleted          = true
                fresh_tombstone.datetime_updated = now
                working_local[key] = fresh_tombstone
            end
        end
    end
end


--- Step 2: combine the local and remote maps, picking the newer version per key.
---
--- For each key K appearing in either map, look at both versions and
--- pick whichever has the newer datetime_updated.  This handles all
--- the "ordinary" merge cases:
---   - local has it, remote doesn't → local wins (it's new locally)
---   - remote has it, local doesn't → remote wins (it's new on the
---     other device)
---   - both have it, same datetime → tombstone-aware tie-break
---   - both have it, different datetimes → newer wins
---
--- @param working_local table The local view (post-deletion-detection).
--- @param remote_map table The remote view.
--- @return table The merged map.
function Merge._combine_local_and_remote(working_local, remote_map)
    local merged_map        = {}
    local keys_seen_locally = {}

    -- Walk the local map first.
    for key, local_entry in pairs(working_local) do
        keys_seen_locally[key] = true
        merged_map[key] = Merge._pick_newer_of_two(local_entry, remote_map[key])
    end

    -- Then walk the remote map; any keys we haven't already handled
    -- are remote-only and adopt the remote version directly.
    for key, remote_entry in pairs(remote_map) do
        if not keys_seen_locally[key] then
            merged_map[key] = remote_entry
        end
    end

    return merged_map
end


--- Re-assert local note edits that the plain newer-wins merge discarded.
---
--- KOReader updates an annotation's `datetime_updated` only when the bookmark
--- TYPE changes (e.g. highlight -> note via AnnotationsModified).  Editing the
--- TEXT of an EXISTING note leaves the type as "note", so no event fires and
--- `datetime_updated` keeps its stale value.  `_pick_newer_of_two` compares
--- only that field, so a stale-timestamped note edit ties with the remote and
--- the remote (old) copy wins -- the edit is lost.
---
--- This pass uses the last-sync ancestor to tell apart the safe case from a
--- genuine conflict.  For each key present locally, it overlays the local note
--- onto the merge winner ONLY when:
---   * all three sides (local, remote, ancestor) hold the key, none deleted,
---   * LOCAL changed the note vs the ancestor, AND
---   * REMOTE did NOT change the note (so this is not a two-sided edit), AND
---   * the merge winner does not already carry the local note (the pick lost
---     it -- i.e. the remote won the datetime tie).
--- The winner supplies every other field, including `color`/`drawer`: on a
--- datetime tie the winner is the remote, whose style is the author's
--- ORIGINAL, so a locally-adapted style is never written back to the shared
--- file.  A fresh `datetime_updated` is stamped so the edit propagates as a
--- normal newer-wins change (and the ancestor adopts it, so the next merge
--- sees no further local-only note delta).
---
--- Two-sided note conflicts (both edited) fail the REMOTE-unchanged guard and
--- fall through to the datetime pick's deterministic tie-break unchanged.
---
--- @param merged table The post-combine merged map (mutated in place).
--- @param working_local table The local view (post deletion-detection).
--- @param remote_map table The remote view.
--- @param last_sync_map table The last-synced ancestor view.
function Merge._preserve_local_note_edits(merged, working_local, remote_map, last_sync_map)
    for key, local_entry in pairs(working_local) do
        local remote_entry = remote_map[key]
        local ancestor     = last_sync_map[key]
        local winner       = merged[key]

        if local_entry and remote_entry and ancestor and winner
           and not local_entry.deleted
           and not remote_entry.deleted
           and not winner.deleted
           and ancestor.note    ~= local_entry.note   -- local changed the note
           and remote_entry.note == ancestor.note     -- remote did not (no conflict)
           and winner.note      ~= local_entry.note   -- the pick discarded it
        then
            local overlaid = {}
            for field_name, field_value in pairs(winner) do
                overlaid[field_name] = field_value
            end
            overlaid.note             = local_entry.note
            overlaid.datetime_updated = TimeFormat.now()
            merged[key] = overlaid
        end
    end
end


--- Strip an adapted highlight style that leaked into the merge winner.
---
--- When this device restyles foreign highlights for display
--- (`adapt_highlight_style`), `_prepare_for_doc_settings` writes the ADAPT
--- OUTPUT into the local sidecar: `color = nil` and `drawer = <device
--- default>` for any annotation NOT authored locally.  That output is a
--- pure DISPLAY transform -- the shared (canonical) file always keeps the
--- author's original style, and adapt is never applied on the way OUT.
---
--- But the next collect reads the adapted sidecar back, so an EDIT to a
--- foreign annotation (note add, recolor, restyle -- anything that bumps
--- `datetime_updated`) makes the local side win `_pick_newer_of_two`, and
--- the whole local annotation -- adapted style included -- becomes the
--- merge winner.  Saved to the shared file, that overwrites the author's
--- original color/drawer for EVERY device.
---
--- This pass restores the original from the remote for exactly the fields
--- that still equal the adapt output (so they are display artifacts, not
--- deliberate user changes):
---   * `color`: the adapt output is nil.  A nil merged color is restored to
---     the remote's color (a no-op when the remote color is also nil -- e.g.
---     the author truly had none).  A NON-nil color is a deliberate recolor
---     (adapt would have nilled it) and is kept.
---   * `drawer`: the adapt output is the device default.  A merged drawer
---     equal to that default is restored to the remote's drawer (no-op when
---     they already match).  Any OTHER drawer is a deliberate restyle and is
---     kept.
--- Only FOREIGN annotations are touched (the device's own highlights are
--- never adapted).  The reference is the LOCAL adapt flag and the LOCAL
--- device default, because only the local sidecar is ever adapted -- there
--- is no cross-device adapt history to reconstruct.
---
--- Residual corner (benign): a user who deliberately sets a field to exactly
--- the neutral adapt-output value (a drawer equal to the device default)
--- cannot be told apart from the artifact, so the author's original is kept
--- instead.  Narrow, and the original is a reasonable result -- unlike the
--- pre-fix behavior, which leaked on EVERY foreign edit.
---
--- Mutates `merged` in place by REPLACING entries with shallow copies (never
--- mutating the shared local/remote annotation tables the merge returned).
---
--- @param merged table The merged map (mutated in place).
--- @param remote_map table The remote (shared, original-style) view.
--- @param opts table { adapt_highlight_style:bool, local_device_id:string,
---                     default_drawer:string }.  No-op unless adapt is on.
function Merge._strip_adapted_style_leak(merged, remote_map, opts)
    if not (opts and opts.adapt_highlight_style) then return end
    local default_drawer  = opts.default_drawer or "lighten"
    local local_device_id = opts.local_device_id

    for key, entry in pairs(merged) do
        if entry and not entry.deleted
           and entry.device_id ~= local_device_id   -- foreign annotation only
        then
            local remote = remote_map and remote_map[key]
            if remote then
                local new_color  = entry.color
                local new_drawer = entry.drawer

                -- color: adapt writes nil.  Restore the original when the
                -- merged color is nil and the remote actually has one.
                if entry.color == nil and remote.color ~= nil then
                    new_color = remote.color
                end

                -- drawer: adapt writes the device default.  Restore the
                -- original when the merged drawer equals that default and the
                -- remote's differs (and is a real highlight drawer).
                if entry.drawer ~= nil and entry.drawer == default_drawer
                   and remote.drawer ~= nil and remote.drawer ~= entry.drawer then
                    new_drawer = remote.drawer
                end

                if new_color ~= entry.color or new_drawer ~= entry.drawer then
                    local fixed = {}
                    for field_name, field_value in pairs(entry) do
                        fixed[field_name] = field_value
                    end
                    fixed.color  = new_color
                    fixed.drawer = new_drawer
                    merged[key]  = fixed
                end
            end
        end
    end
end


--- Decide which of two annotations (at the same key) "wins" a merge.
---
--- The rule: whichever was edited later wins, comparing the strings
--- of their `datetime_updated` fields.  Our datetime format
--- ("YYYY-MM-DD HH:MM:SS") sorts the same as time order, so a string
--- comparison gives the right answer.
---
--- Tie-breaking: when datetimes are equal (sometimes happens at
--- second precision when two events fall in the same second), prefer
--- a tombstone over an alive entry.  Rationale: a deletion is
--- causally after the creation of the same annotation, so even if
--- the recorded times happen to match, the tombstone "happened
--- later" in user intent.
---
--- @param annotation_a table|nil One of the two annotations.
--- @param annotation_b table|nil The other one.
--- @return table|nil The newer of the two, or whichever isn't nil.
function Merge._pick_newer_of_two(annotation_a, annotation_b)
    if annotation_a == nil then return annotation_b end
    if annotation_b == nil then return annotation_a end

    local datetime_a = TimeFormat.last_modified_of(annotation_a)
    local datetime_b = TimeFormat.last_modified_of(annotation_b)

    if datetime_a == datetime_b then
        local a_is_tombstone = annotation_a.deleted == true
        local b_is_tombstone = annotation_b.deleted == true

        if a_is_tombstone and not b_is_tombstone then
            return annotation_a
        end
        if b_is_tombstone and not a_is_tombstone then
            return annotation_b
        end
        -- Both same kind (both live or both tombstones), same datetime: break
        -- the tie on a device-INDEPENDENT property so _pick_newer_of_two(a,b) ==
        -- _pick_newer_of_two(b,a) and both devices converge on the same winner.
        -- The old `return annotation_b` favoured argument order ("incoming"
        -- wins), which is not commutative -- and under conflict-file resolution
        -- the argument order is not a stable local-vs-remote, so two devices
        -- could keep different entries.  device_id is stamped on every
        -- annotation (see SyncOrchestrator._stamp_local_annotations); this
        -- mirrors MetadataBridge._metadata_tiebreak and StatusLattice's origin
        -- selection -- one convergence rule across every merge unit.
        local id_a = annotation_a.device_id or ""
        local id_b = annotation_b.device_id or ""
        if id_a ~= id_b then
            return (id_a > id_b) and annotation_a or annotation_b
        end
        return annotation_b   -- same device_id => identical entry, order irrelevant
    end

    if datetime_a > datetime_b then
        return annotation_a
    else
        return annotation_b
    end
end




return Merge
