-- =============================================================================
-- syncery_ann/tombstones.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- It compacts old deletion markers ("tombstones") so the annotation
-- file doesn't grow unboundedly, WITHOUT ever dropping the deletion
-- marker itself.  When a user deletes an annotation, we don't actually
-- remove it from our data — we replace it with a `{ deleted = true,
-- datetime_updated = ... }` record.  This is a "tombstone".
--
--
-- WHY WE KEEP TOMBSTONES
--
-- Imagine you have two devices, A and B, both with annotation X.  You
-- delete X on device A.  Some time later, device B finally syncs.  How
-- does B learn that X should be removed?
--
-- If A's sync data just had X missing, B wouldn't know whether X "was
-- deleted on A" or "never existed on A".  B might assume the latter
-- and helpfully send X back to A, undoing the deletion.
--
-- Tombstones solve this.  When A's data arrives at B, X is still
-- present, but with `deleted = true`.  Now B knows: "A intentionally
-- removed X".  B applies the deletion locally.
--
--
-- WHY WE NO LONGER *DELETE* OLD TOMBSTONES (CHANGED IN PHASE 2 REVISION)
--
-- The previous implementation removed tombstones from the map after a
-- TTL (default 90 days).  That avoided unbounded file growth, but it
-- introduced a real resurrection bug: if a device was offline for
-- longer than the TTL while another device deleted annotations, the
-- offline device would, on its next sync, see "X in my local, X in my
-- last-sync, X NOT in remote, no tombstone" — and it would push X
-- back as if it were a new local creation.  Deletions could undo
-- themselves silently.
--
-- The simpler fix is to keep the tombstone marker forever, but COMPACT
-- it after a TTL.  The compacted form drops every field except the
-- two the merge actually inspects (`deleted`, `datetime_updated`) and
-- the device identity fields (`device_id`, `device_label`) which are
-- a few bytes each.  A heavy annotator (1000 deletions over years)
-- adds maybe 80 KB of compacted tombstones — negligible on every
-- device we target.
--
-- The trade-off this gives up: the original annotation fields (text,
-- drawer, color, position) are not preserved past the TTL.  A
-- hypothetical "show me what was deleted last month" UI would stop
-- working after the compaction window.  We accept that — no such UI
-- exists today, and correctness of deletion propagation is more
-- important than forensics.
--
--
-- WHAT THIS MEANS FOR THE MERGE
--
-- Compaction is a NO-OP from the merge's perspective.  The merge
-- only looks at `deleted` and `datetime_updated`.  Both survive
-- compaction.  Pre-compaction tombstones merged with post-compaction
-- tombstones at the same key are tie-broken by `datetime_updated`,
-- which is identical because compaction doesn't bump the timestamp.
-- (See the second tie-break in `merge._pick_newer_of_two` — both
-- sides are tombstones; the function falls through to "prefer the
-- incoming side", which happens to be the compacted form on whichever
-- device GC ran first.  Either resolution is correct.)
--
-- =============================================================================

local TimeFormat = require("syncery_ann/time_format")

local Tombstones = {}

-- ----------------------------------------------------------------------------
-- Constants
-- ----------------------------------------------------------------------------

local DEFAULT_TTL_DAYS = 30
local SECONDS_PER_DAY  = 86400

-- Fields preserved during compaction.  Everything else (text, drawer,
-- color, page, pos0, pos1, pboxes, note, etc.) is dropped to shrink
-- the file.  `device_id` and `device_label` are kept because they're
-- a few bytes total and useful for the (future) UI that says "X was
-- deleted on Kindle PW".
local FIELDS_TO_PRESERVE_ON_COMPACT = {
    deleted          = true,
    datetime_updated = true,
    device_id        = true,
    device_label     = true,
}


-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------


--- Compact tombstones older than the time-to-live (TTL) limit.
---
--- Returns a NEW state map; the input is not modified.  Alive entries
--- (those with deleted = false or no deleted field at all) are always
--- preserved verbatim.  Tombstones younger than the TTL are also
--- preserved verbatim.  Tombstones older than the TTL get compacted
--- to a minimal `{ deleted, datetime_updated, device_id, device_label }`
--- form — the tombstone marker itself stays forever so a device that
--- comes back from a long absence still learns about the deletion.
---
--- @param state_map table The annotations map (key -> annotation table).
--- @param ttl_days number|nil Days before a tombstone is compacted (default 30).
--- @return table A new state map.
--- @return number How many tombstones were compacted in this pass.
function Tombstones.collect_garbage(state_map, ttl_days)
    ttl_days = ttl_days or DEFAULT_TTL_DAYS

    local cutoff_time = os.time() - (ttl_days * SECONDS_PER_DAY)

    local cleaned_map     = {}
    local compacted_count = 0

    for key, annotation in pairs(state_map or {}) do
        if annotation and annotation.deleted then
            -- This is a tombstone.  Is it old enough to compact?
            local annotation_time = TimeFormat.parse_utc_to_unix(
                annotation.datetime_updated)

            -- Unparseable datetime: treat as "very old".  An unparseable
            -- tombstone is bad data; compact it to the minimal shape so
            -- it stops taking up space, but DO NOT drop it (we still
            -- need its marker to propagate the deletion).
            if annotation_time == 0 or annotation_time < cutoff_time then
                -- Don't re-compact an already-minimal tombstone.  Without
                -- this check the per-pass count would be inflated by all
                -- previously-compacted entries every time GC runs.
                if Tombstones._is_already_compacted(annotation) then
                    cleaned_map[key] = annotation
                else
                    cleaned_map[key] = Tombstones._compact(annotation)
                    compacted_count = compacted_count + 1
                end
            else
                -- Young tombstone — keep verbatim.
                cleaned_map[key] = annotation
            end
        else
            -- Alive entry — always keep.
            cleaned_map[key] = annotation
        end
    end

    return cleaned_map, compacted_count
end


--- Count tombstones in a state map.
---
--- Useful for status badges and maintenance menus that want to show
--- "you have N pending deletions".
---
--- @param state_map table The annotations map.
--- @return number How many tombstones are in the map.
function Tombstones.count(state_map)
    local count = 0
    for _, annotation in pairs(state_map or {}) do
        if annotation and annotation.deleted then
            count = count + 1
        end
    end
    return count
end


-- ----------------------------------------------------------------------------
-- Internal helpers
-- ----------------------------------------------------------------------------


--- Strip a tombstone down to its minimal form.
---
--- Keeps only the fields listed in `FIELDS_TO_PRESERVE_ON_COMPACT`.
--- Returns a NEW table — the input is not modified, so callers can
--- safely keep the original around if they need it.
---
--- @param tombstone table The full tombstone.
--- @return table A new, minimal tombstone.
function Tombstones._compact(tombstone)
    local minimal = {}
    for field_name in pairs(FIELDS_TO_PRESERVE_ON_COMPACT) do
        if tombstone[field_name] ~= nil then
            minimal[field_name] = tombstone[field_name]
        end
    end
    return minimal
end


--- Does this tombstone already look like a compacted one?
---
--- A compacted tombstone has none of the optional annotation fields
--- (text, drawer, color, page, pos0, pos1, etc.) — only the
--- preservation set.  We check this by looking for any field NOT in
--- the preservation set: if even one is present, the tombstone is
--- still "full" and re-compacting it would actually do work.
---
--- @param tombstone table The tombstone to inspect.
--- @return boolean True if already minimal, false otherwise.
function Tombstones._is_already_compacted(tombstone)
    for field_name in pairs(tombstone) do
        if not FIELDS_TO_PRESERVE_ON_COMPACT[field_name] then
            return false
        end
    end
    return true
end


return Tombstones
