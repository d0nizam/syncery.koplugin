-- =============================================================================
-- syncery_ann/status_lattice.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- Pure, dependency-free conflict resolution for a book's reading STATUS
-- (KOReader's `summary.status`) across devices.  This is the "Model D"
-- design: a lifecycle LATTICE plus a
-- scalar GENERATION counter.  No wall clock, no version vectors.
--
-- WHY STATUS IS SPECIAL
--
-- The other metadata fields (rating, note, ...) are opaque values merged
-- last-writer-wins-ish.  Status is a small enum with STRUCTURE:
--
--     new  <  reading  <  complete
--     new  <  reading  <  abandoned
--     complete  ||  abandoned          (the two terminal states, incomparable)
--
-- `complete` and `abandoned` sit at the top and are NOT comparable to each
-- other -- so the ONLY genuinely ambiguous conflict is complete-vs-abandoned
-- ("did you finish it, or give up?").  Everything else is ordered, which
-- means most "conflicts" have a correct, clock-free answer:
--   * concurrent forward progress -> the further state wins
--     (LOCKED rule: "finished anywhere => finished")
--   * a deliberate move BACKWARD or SIDEWAYS (reopen: complete->reading;
--     switch: complete->abandoned) bumps the GENERATION, so it dominates the
--     stale value it overrides -- the user's latest deliberate action wins
--     WITHOUT consulting any clock.
--
-- THE GENERATION
--
-- `generation` is a Lamport-style counter that increments ONLY on a
-- backward/sideways (reopen-like) move.  Forward moves ride the current
-- generation and are resolved by the lattice.  A higher generation always
-- dominates -- that is how a reopen, and how a user's explicit conflict
-- resolution, win everywhere without a clock.
--
-- ON-DISK SHAPE
--
--   metadata.status = {
--     generation = <int>,
--     candidates = {                       -- canonically sorted by value
--       { value = <state>, device_id = <id>, device_label = <label> },
--       ...
--     },
--   }
--
--   #candidates == 1  -> RESOLVED   (the value is candidates[1].value)
--   #candidates == 2  -> CONFLICT   (always exactly {abandoned, complete})
--
-- This module is PURE (table/pairs/ipairs/tonumber only) so it unit-tests in
-- isolation.  metadata_bridge.lua wires it into collect/merge/apply.
-- =============================================================================

local StatusLattice = {}

-- Lattice level for the chain  new < reading < {complete, abandoned}.
-- complete and abandoned share level 2 but are INCOMPARABLE (see _comparable).
local LEVEL    = { ["new"] = 0, reading = 1, abandoned = 2, complete = 2 }
local TERMINAL = { abandoned = true, complete = true }

StatusLattice.LEVEL = LEVEL  -- exposed for callers/tests that validate states


-- ── Lattice primitives ───────────────────────────────────────────────


--- Are two states comparable (one <= the other) in the lattice?
--- The only incomparable pair is {complete, abandoned}.
function StatusLattice._comparable(a, b)
    if a == b then return true end
    if TERMINAL[a] and TERMINAL[b] then return false end
    return true
end


--- Is moving `prev_value` -> `new_value` a FORWARD (or no-op) move?
--- Forward = comparable AND new is at least as advanced as prev.  Backward
--- (complete->reading), sideways (complete->abandoned) and any incomparable
--- move are NOT forward, so the caller bumps the generation.  From nil (no
--- prior status) anything is forward.
function StatusLattice.is_forward(prev_value, new_value)
    if prev_value == nil or prev_value == "" then return true end
    if new_value == prev_value then return true end
    if not StatusLattice._comparable(prev_value, new_value) then
        return false
    end
    return (LEVEL[new_value] or 0) >= (LEVEL[prev_value] or 0)
end


--- The FRONTIER (maximal antichain) of a set of values under the lattice:
--- every value that is not strictly below some other value in the set.
--- `value_set` is a set (value -> true).  Returns a set of maximal values.
--- For this lattice the result is one of: {new}, {reading}, {complete},
--- {abandoned}, or {complete, abandoned}.
function StatusLattice._frontier(value_set)
    local maximal = {}
    for v in pairs(value_set) do
        local dominated = false
        for w in pairs(value_set) do
            if v ~= w
               and StatusLattice._comparable(v, w)
               and (LEVEL[v] or 0) < (LEVEL[w] or 0) then
                dominated = true
                break
            end
        end
        if not dominated then maximal[v] = true end
    end
    return maximal
end


-- ── Entry helpers ────────────────────────────────────────────────────


--- Canonically sort candidates by value (deterministic -> byte-identical
--- across devices).  Mutates and returns the list.
local function sort_candidates(cands)
    table.sort(cands, function(a, b)
        return tostring(a.value) < tostring(b.value)
    end)
    return cands
end


--- Normalize the canonical { generation, candidates } status entry into a
--- sorted form, or nil if there's no opinion (non-table input, no
--- candidates key, or an empty candidate set).
function StatusLattice.normalize(entry)
    if type(entry) ~= "table" then return nil end

    if entry.candidates ~= nil then
        local cands = {}
        for _, c in ipairs(entry.candidates) do
            if type(c) == "table" and c.value ~= nil and c.value ~= "" then
                cands[#cands + 1] = {
                    value        = c.value,
                    device_id    = c.device_id,
                    device_label = c.device_label,
                }
            end
        end
        if #cands == 0 then return nil end
        return {
            generation = tonumber(entry.generation) or 0,
            candidates = sort_candidates(cands),
        }
    end

    return nil
end


--- True if the entry is an unresolved conflict (>= 2 candidates).
function StatusLattice.is_conflict(entry)
    local e = StatusLattice.normalize(entry)
    return e ~= nil and #e.candidates >= 2
end


--- The single resolved value, or nil if absent / still in conflict.
function StatusLattice.resolved_value(entry)
    local e = StatusLattice.normalize(entry)
    if e and #e.candidates == 1 then return e.candidates[1].value end
    return nil
end


--- The candidate list for a status in conflict (>= 2 incomparable terminal
--- values), canonically sorted, each { value, device_id, device_label }; nil if
--- the status is absent or resolved.  The surfacing UI reads this to show the
--- per-device breakdown ("complete on A vs abandoned on B").
function StatusLattice.conflict_candidates(entry)
    local e = StatusLattice.normalize(entry)
    if e and #e.candidates >= 2 then return e.candidates end
    return nil
end


-- ── The merge (Model D) ──────────────────────────────────────────────


--- Merge two status entries.  Commutative, associative, idempotent, so any
--- order of sync converges to the same (byte-identical) result.
---   * higher generation dominates (a reopen / explicit resolution wins)
---   * same generation -> the lattice FRONTIER of the union of candidate
---     values (forward/max wins; complete+abandoned -> a 2-candidate conflict)
function StatusLattice.merge(left, right)
    local l = StatusLattice.normalize(left)
    local r = StatusLattice.normalize(right)
    if l == nil then return r end
    if r == nil then return l end

    if l.generation > r.generation then return l end
    if r.generation > l.generation then return r end

    -- Same generation: union the candidate values (deterministic origin per
    -- value so the bytes match regardless of which side we merged first),
    -- then keep only the lattice-maximal ones.
    local origin = {}     -- value -> { value, device_id, device_label }
    local function absorb(c)
        local cur = origin[c.value]
        if cur == nil
           or (tostring(c.device_id or "") < tostring(cur.device_id or "")) then
            origin[c.value] = {
                value        = c.value,
                device_id    = c.device_id,
                device_label = c.device_label,
            }
        end
    end
    for _, c in ipairs(l.candidates) do absorb(c) end
    for _, c in ipairs(r.candidates) do absorb(c) end

    local value_set = {}
    for v in pairs(origin) do value_set[v] = true end
    local front = StatusLattice._frontier(value_set)

    local cands = {}
    for v in pairs(front) do cands[#cands + 1] = origin[v] end
    return { generation = l.generation, candidates = sort_candidates(cands) }
end


-- ── Collect: this device's local contribution ────────────────────────


--- Build THIS device's status entry from the live value, classifying the
--- generation against the ancestor (`prev_entry`, what this device last
--- synced -- may be nil, a single value, or a conflict).
---
--- Returns a single-candidate { generation, candidates = {{...}} }, or nil
--- when there is no local status (no opinion).  The merge re-derives any
--- conflict from this single contribution plus the remote side.
---
--- Generation rules:
---   * unchanged / forward move      -> carry the ancestor's generation
---   * backward / sideways (reopen)  -> ancestor generation + 1 (dominates)
---   * ancestor is itself a conflict:
---       - live == our own side      -> carry (we keep contributing our side)
---       - live != our own side      -> resolution -> generation + 1
function StatusLattice.local_entry(prev_entry, new_value, device_id, device_label)
    if new_value == nil or new_value == "" then return nil end

    local prev     = StatusLattice.normalize(prev_entry)
    local prev_gen = (prev and prev.generation) or 0

    local function single(gen)
        return {
            generation = gen,
            candidates = { {
                value        = new_value,
                device_id    = device_id,
                device_label = device_label,
            } },
        }
    end

    if prev == nil then
        return single(prev_gen)                 -- first status; forward from none
    end

    if #prev.candidates == 1 then
        if StatusLattice.is_forward(prev.candidates[1].value, new_value) then
            return single(prev_gen)             -- forward / no-op -> carry
        end
        return single(prev_gen + 1)             -- reopen -> dominate
    end

    -- Ancestor is a conflict: find this device's own side.
    local own
    for _, c in ipairs(prev.candidates) do
        if c.device_id == device_id then own = c.value; break end
    end
    if new_value == own then
        return single(prev_gen)                 -- unchanged -> keep contributing our side
    end
    return single(prev_gen + 1)                 -- changed -> resolution -> dominate
end


-- ── Resolution: collapse a conflict to a chosen value ─────────────────


--- Produce the entry a user's explicit conflict resolution should write: the
--- chosen value at generation+1 so it DOMINATES the conflicting generation
--- and converges everywhere in one action.
function StatusLattice.resolve(conflict_entry, chosen_value, device_id, device_label)
    local e   = StatusLattice.normalize(conflict_entry)
    local gen = ((e and e.generation) or 0) + 1
    return {
        generation = gen,
        candidates = { {
            value        = chosen_value,
            device_id    = device_id,
            device_label = device_label,
        } },
    }
end


return StatusLattice
