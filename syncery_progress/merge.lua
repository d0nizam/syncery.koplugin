-- =============================================================================
-- syncery_progress/merge.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- It merges three views of the same progress data and produces a
-- single consistent result:
--
--   * LOCAL view: what's on this device right now (our own entry,
--                 plus whatever other-device entries we cached the
--                 last time we read the shared file).
--   * LAST-SYNC view: what the shared file looked like the last time
--                     we successfully synced (the "common ancestor").
--   * REMOTE view: what's currently in the shared JSON file (other
--                  devices may have updated their entries via
--                  Syncthing or cloud sync).
--
-- The merged result has the "best" entry for every device that
-- appears anywhere, by `(revision, timestamp)` lexicographic order.
--
--
-- WHY 3-WAY HERE TOO (DESPITE PROGRESS HAVING NO DELETIONS)
--
-- The annotations subsystem uses 3-way because deletions need a
-- third reference point to be detected.  Progress entries don't
-- get deleted in the same way (you replace a reading position, you
-- don't tombstone it).  So a pure 2-way "max(revision) wins"
-- would technically suffice for normal operation.
--
-- We still take three inputs because:
--   * Symmetry with the annotations API makes the orchestrator's
--     job mechanical.
--   * The wipe failsafe in the orchestrator needs to compare local
--     against last-sync to recognize "this is a real edit, not a
--     fresh-open before doc_settings has loaded".
--   * Per-device pruning (if ever added) WOULD need the ancestor —
--     "I removed device X" vs "I never had device X" are
--     indistinguishable from 2-way data alone.
--
-- The merge itself ignores last-sync for value selection; it's
-- passed in for parity with future deletion-aware logic.
--
--
-- THE MERGE RULES
--
-- For each device_id K appearing in any of the three views:
--
--   1. Collect the candidate entries for K from local and remote
--      (last-sync's K, if any, is treated as the floor — see #3).
--   2. Pick the candidate with the highest revision.  Tie-break by
--      timestamp (numeric, epoch seconds).
--   3. If both local and remote have older entries than last-sync
--      for K (shouldn't happen under normal conditions, but a
--      Syncthing weirdness could produce it), prefer last-sync.
--
-- "Pick the highest revision" is the right rule because revision is
-- a monotonic counter bumped on every save by the writing device.
-- Each device owns its entry (only it bumps the revision), so the
-- file with the highest revision for device D came from D's most
-- recent save.
--
-- =============================================================================

local Merge = {}


-- ----------------------------------------------------------------------------
-- The 3-way merge itself
-- ----------------------------------------------------------------------------


--- Run a 3-way merge of three progress maps and produce the merged result.
---
--- All three input maps are keyed by device_id.  Pass nil or {} for
--- "this side has no data".
---
--- This function is pure: no disk I/O, no input mutation, fully
--- deterministic.  All persistence is the caller's responsibility.
---
--- @param local_map table|nil { [device_id] = entry } on this device.
--- @param last_sync_map table|nil { [device_id] = entry } at last successful sync.
--- @param remote_map table|nil { [device_id] = entry } currently in the shared file.
--- @return table The merged map.
function Merge.three_way(local_map, last_sync_map, remote_map)
    local_map     = local_map     or {}
    last_sync_map = last_sync_map or {}
    remote_map    = remote_map    or {}

    local merged = {}

    -- Collect every device_id that appears anywhere.  We don't need
    -- a fast-path for "all three agree" — the merge is O(n) anyway.
    local all_keys = {}
    for k in pairs(local_map)     do all_keys[k] = true end
    for k in pairs(last_sync_map) do all_keys[k] = true end
    for k in pairs(remote_map)    do all_keys[k] = true end

    for device_id in pairs(all_keys) do
        local local_entry     = local_map[device_id]
        local last_sync_entry = last_sync_map[device_id]
        local remote_entry    = remote_map[device_id]

        merged[device_id] = Merge._pick_best_of_three(
            local_entry, last_sync_entry, remote_entry)
    end

    return merged
end


-- ----------------------------------------------------------------------------
-- Single-write helper (the convenient API for normal saves)
-- ----------------------------------------------------------------------------


--- True iff two entries describe the SAME reading position.
---
--- We compare the position-DEFINING fields only: `page` (the unit of
--- position for paged books) and `xpath` (for rolling books, where page
--- is a font-dependent approximation).  Both are exact, nil-safe compares
--- (a paged book has xpath == nil on both sides → equal).
---
--- Deliberately NOT `percent`: it is DERIVED from page/xpath, so including
--- it would let float jitter at an unchanged position read as a "move".
--- page+xpath fully pin the position, so they are sufficient AND
--- jitter-proof.  We err toward "different" (either field differing counts
--- as a move) so a real move is never mistaken for a no-op.
---
--- @param a table An entry (needs `page`, `xpath`).
--- @param b table An entry (needs `page`, `xpath`).
--- @return boolean
function Merge._same_position(a, b)
    return a.page == b.page and a.xpath == b.xpath
end


--- Insert or update this device's entry, returning a new state map.
---
--- A TRUE upsert: it bumps the revision counter and stamps a fresh
--- timestamp ONLY when the position actually changed.  Re-asserting the
--- SAME position (e.g. a save triggered by an annotation, with no page
--- turn) is a no-op — `state_map` is returned untouched, no revision bump,
--- no timestamp refresh.  This keeps "the position changed" and "we wrote
--- something" as separate axes: an unchanged position must not masquerade
--- as a fresh reading event (which would refresh recency → spurious jump
--- target, and bump the revision → defeat the per-device ack suppression).
---
--- The new revision is `max(existing revisions for this device_id) + 1`.
--- (We don't look at OTHER devices' revisions — those are theirs to
--- own.  Walking only `state_map[device_id]` keeps the counter
--- monotonic for THIS device specifically.)
---
--- @param state_map table The current state (a { [device_id] = entry } map).
--- @param device_id string This device's ID — the key in the map.
--- @param entry_fields table The progress data (percent, page, xpath, ...).
--- @param now_epoch_seconds number|nil Override for the timestamp; defaults to os.time().
--- @return table A new state map (or the input unchanged on a no-op).
function Merge.upsert_local_entry(state_map, device_id, entry_fields, now_epoch_seconds)
    if not device_id or device_id == "" then
        return state_map
    end

    -- Idempotency: re-asserting the same position is a no-op.  No revision
    -- bump, no timestamp refresh, the map is returned untouched.  Only an
    -- actual move (or a first write, where there is no existing entry) falls
    -- through to stamp a new entry.  `state_map[device_id]` is reliably THIS
    -- device's own last-written entry (device_id is unique per device, and the
    -- per-key 3-way merge keeps our latest), so this correctly answers "did MY
    -- position change since I last wrote?".
    local existing = state_map[device_id]
    if existing and entry_fields and Merge._same_position(entry_fields, existing) then
        return state_map
    end

    local previous_revision = 0
    if state_map[device_id] and type(state_map[device_id].revision) == "number" then
        previous_revision = state_map[device_id].revision
    end

    local new_entry = {}
    for field_name, field_value in pairs(entry_fields or {}) do
        new_entry[field_name] = field_value
    end
    new_entry.device_id = device_id
    new_entry.revision  = previous_revision + 1
    new_entry.timestamp = now_epoch_seconds or os.time()

    local new_state = {}
    for k, v in pairs(state_map or {}) do
        new_state[k] = v
    end
    new_state[device_id] = new_entry

    return new_state
end


-- ----------------------------------------------------------------------------
-- Inspection helpers
-- ----------------------------------------------------------------------------


--- Find the entry with the highest (revision, timestamp) in a state map.
---
--- Used by the bridge to pick "what should we suggest the user jump to"
--- (when the best entry on the file is not from this device).
---
--- Optional `exclude_device_id` lets callers say "find the best entry
--- NOT from this device" — useful for the jump-to-other-device prompt.
---
--- @param state_map table A { [device_id] = entry } map.
--- @param exclude_device_id string|nil Optional device_id to skip.
--- @return table|nil The best entry, or nil if the map is empty.
--- @return string|nil The device_id of the best entry.
function Merge.pick_best(state_map, exclude_device_id)
    local best_entry = nil
    local best_device_id = nil
    for device_id, entry in pairs(state_map or {}) do
        if device_id ~= exclude_device_id and type(entry) == "table" then
            if Merge._is_strictly_newer(entry, best_entry) then
                best_entry = entry
                best_device_id = device_id
            end
        end
    end
    return best_entry, best_device_id
end


--- True iff `a` should beat `b` for "newest" purposes.
---
--- Compares (revision, timestamp) lexicographically.  A nil `b`
--- always loses (anything beats nothing).
function Merge._is_strictly_newer(a, b)
    if not a then return false end
    if not b then return true  end

    local rev_a = tonumber(a.revision)  or 0
    local rev_b = tonumber(b.revision)  or 0
    if rev_a ~= rev_b then return rev_a > rev_b end

    local ts_a = tonumber(a.timestamp) or 0
    local ts_b = tonumber(b.timestamp) or 0
    return ts_a > ts_b
end


-- ----------------------------------------------------------------------------
-- Internal: per-key picker
-- ----------------------------------------------------------------------------


--- Pick whichever of (local, last_sync, remote) is best for one device_id.
---
--- Algorithm:
---   1. Walk all three candidates; ignore nils.
---   2. Apply `_is_strictly_newer` pairwise to find the best by
---      (revision, timestamp).  Ties: prefer LOCAL > REMOTE > LAST-SYNC.
---      (Local wins ties because if WE bumped a revision and another
---      device happens to have the same one, we trust ourselves; remote
---      wins over last-sync because last-sync is by definition older
---      or equal.)
function Merge._pick_best_of_three(local_entry, last_sync_entry, remote_entry)
    -- Start by treating local as the baseline; then beat it.
    local best = local_entry
    if Merge._is_strictly_newer(remote_entry, best) then
        best = remote_entry
    end
    if Merge._is_strictly_newer(last_sync_entry, best) then
        best = last_sync_entry
    end

    -- Edge case: if `best` is still nil it means all three were nil,
    -- which shouldn't happen (the caller wouldn't have asked about
    -- this device_id), but be defensive.
    return best
end


return Merge
