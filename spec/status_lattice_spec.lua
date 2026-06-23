-- =============================================================================
-- spec/status_lattice_spec.lua
-- =============================================================================
--
-- Unit tests for syncery_ann/status_lattice.lua -- the pure "Model D"
-- (lifecycle lattice + generation) status conflict resolver from
-- docs/SYNC_CONFLICT_STRATEGY.md §9.  Pure functions, no I/O, no KOReader
-- globals.
--
-- The case table in §9.5 is walked end-to-end in the "§9.5 scenarios"
-- block by composing local_entry (collect) + merge.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup()

local SL = require("syncery_ann/status_lattice")


-- ── builders / extractors ────────────────────────────────────────────


-- entry(gen, {value, dev}, {value, dev}, ...)
local function entry(gen, ...)
    local cands = {}
    for _, v in ipairs({ ... }) do
        cands[#cands + 1] = { value = v[1], device_id = v[2], device_label = v[2] }
    end
    return { generation = gen, candidates = cands }
end

local function single(gen, value, dev)
    return entry(gen, { value, dev })
end

-- sorted "v1,v2" string of an entry's candidate values
local function vals(e)
    e = SL.normalize(e)
    if not e then return "<nil>" end
    local vs = {}
    for _, c in ipairs(e.candidates) do vs[#vs + 1] = c.value end
    table.sort(vs)
    return table.concat(vs, ",")
end

local function gen(e)
    e = SL.normalize(e)
    return e and e.generation or nil
end


-- ── Lattice primitives ───────────────────────────────────────────────

do
    h.assert_true(SL._comparable("reading", "complete"), "reading/complete comparable")
    h.assert_true(SL._comparable("new", "abandoned"),    "new/abandoned comparable")
    h.assert_false(SL._comparable("complete", "abandoned"),
        "complete/abandoned are the ONLY incomparable pair")
    h.assert_true(SL._comparable("complete", "complete"), "equal values comparable")

    -- forward / reopen classification
    h.assert_true(SL.is_forward("reading", "complete"),   "reading->complete is forward")
    h.assert_true(SL.is_forward("new", "reading"),        "new->reading is forward")
    h.assert_true(SL.is_forward("reading", "abandoned"),  "reading->abandoned is forward")
    h.assert_true(SL.is_forward(nil, "complete"),         "nil->anything is forward")
    h.assert_true(SL.is_forward("complete", "complete"),  "no-op is forward")
    h.assert_false(SL.is_forward("complete", "reading"),  "complete->reading is a reopen (backward)")
    h.assert_false(SL.is_forward("abandoned", "reading"), "abandoned->reading is a reopen (backward)")
    h.assert_false(SL.is_forward("complete", "abandoned"),"complete->abandoned is sideways")
    h.assert_false(SL.is_forward("abandoned", "complete"),"abandoned->complete is sideways")
end


-- ── _frontier ────────────────────────────────────────────────────────

do
    local function front_str(set)
        local out = {}
        for v in pairs(SL._frontier(set)) do out[#out + 1] = v end
        table.sort(out)
        return table.concat(out, ",")
    end
    h.assert_equal(front_str({ reading = true, complete = true }), "complete",
        "frontier{reading,complete} = complete (forward wins)")
    h.assert_equal(front_str({ ["new"] = true, reading = true }), "reading",
        "frontier{new,reading} = reading")
    h.assert_equal(front_str({ complete = true, abandoned = true }), "abandoned,complete",
        "frontier{complete,abandoned} = both (the conflict)")
    h.assert_equal(front_str({ reading = true, complete = true, abandoned = true }),
        "abandoned,complete",
        "frontier{reading,complete,abandoned} = {complete,abandoned} (reading absorbed)")
    h.assert_equal(front_str({ complete = true }), "complete", "frontier of a singleton")
end


-- ── normalize / is_conflict / resolved_value ─────────────────────────

do
    h.assert_nil(SL.normalize(nil),            "nil entry -> nil")
    h.assert_nil(SL.normalize({}),             "empty table -> nil (no opinion)")
    h.assert_nil(SL.normalize({ value = "" }), "empty value -> nil")
    h.assert_nil(SL.normalize({ generation = 3, candidates = {} }), "no candidates -> nil")

    h.assert_false(SL.is_conflict(single(0, "complete", "a")), "single candidate is not a conflict")
    h.assert_true(SL.is_conflict(entry(0, { "complete", "a" }, { "abandoned", "b" })),
        "two candidates is a conflict")

    h.assert_equal(SL.resolved_value(single(2, "abandoned", "a")), "abandoned",
        "resolved_value of a resolved entry")
    h.assert_nil(SL.resolved_value(entry(0, { "complete", "a" }, { "abandoned", "b" })),
        "resolved_value of a conflict is nil")
    h.assert_nil(SL.resolved_value(nil), "resolved_value of nil is nil")

    -- conflict_candidates: what the surfacing UI reads
    local cc = SL.conflict_candidates(entry(0, { "complete", "a" }, { "abandoned", "b" }))
    h.assert_true(cc ~= nil and #cc == 2, "conflict_candidates returns both candidates")
    h.assert_equal(cc[1].value, "abandoned", "conflict_candidates canonically sorted (abandoned first)")
    h.assert_equal(cc[2].value, "complete",  "conflict_candidates canonically sorted (complete second)")
    h.assert_nil(SL.conflict_candidates(single(2, "complete", "a")),
        "a resolved status has no conflict candidates")
    h.assert_nil(SL.conflict_candidates(nil), "nil entry has no conflict candidates")
end


-- ── merge: generation dominance + frontier ───────────────────────────

do
    -- higher generation dominates regardless of lattice position
    local m = SL.merge(single(1, "reading", "a"), single(0, "complete", "b"))
    h.assert_equal(vals(m), "reading", "higher generation wins (reading@1 over complete@0)")
    h.assert_equal(gen(m), 1, "winner keeps its generation")

    -- same generation, comparable -> forward wins
    m = SL.merge(single(0, "reading", "a"), single(0, "complete", "b"))
    h.assert_equal(vals(m), "complete", "same gen: forward wins (finished anywhere => finished)")
    h.assert_equal(gen(m), 0, "same-gen merge keeps the generation")

    -- same generation, incomparable -> conflict
    m = SL.merge(single(0, "complete", "a"), single(0, "abandoned", "b"))
    h.assert_true(SL.is_conflict(m), "same gen complete vs abandoned -> conflict")
    h.assert_equal(vals(m), "abandoned,complete", "conflict holds both candidates")

    -- nil handling
    h.assert_equal(vals(SL.merge(nil, single(0, "reading", "a"))), "reading", "merge(nil, X) = X")
    h.assert_equal(vals(SL.merge(single(0, "reading", "a"), nil)), "reading", "merge(X, nil) = X")
    h.assert_nil(SL.merge(nil, nil), "merge(nil, nil) = nil")
end


-- ── byte-identity: idempotence + order independence ──────────────────

do
    -- idempotence
    local x = single(2, "complete", "a")
    h.assert_equal(vals(SL.merge(x, x)), "complete", "merge(X, X) value stable")
    h.assert_equal(gen(SL.merge(x, x)), 2, "merge(X, X) generation stable")

    -- order independence of the conflict
    local L = single(0, "complete", "kindle")
    local R = single(0, "abandoned", "phone")
    h.assert_equal(vals(SL.merge(L, R)), vals(SL.merge(R, L)),
        "merge is commutative on values")

    -- deterministic origin when the SAME value comes from two devices:
    -- the device_id tiebreak (lower wins) must not depend on argument order,
    -- or the on-disk bytes would differ between devices.
    local lo = single(0, "complete", "aaa")
    local hi = single(0, "complete", "zzz")
    local m1 = SL.merge(lo, hi)
    local m2 = SL.merge(hi, lo)
    h.assert_equal(SL.normalize(m1).candidates[1].device_id, "aaa",
        "same-value origin picks the lower device_id")
    h.assert_equal(SL.normalize(m1).candidates[1].device_id,
                   SL.normalize(m2).candidates[1].device_id,
        "origin pick is order-independent (byte-identity)")
end


-- ── local_entry: generation classification ───────────────────────────

do
    -- first status from no ancestor -> generation 0
    local e = SL.local_entry(nil, "reading", "a", "A")
    h.assert_equal(gen(e), 0, "first status -> generation 0")
    h.assert_equal(vals(e), "reading", "first status value")

    -- no-op against ancestor -> carry generation
    e = SL.local_entry(single(3, "complete", "a"), "complete", "a", "A")
    h.assert_equal(gen(e), 3, "unchanged status carries the ancestor generation")

    -- forward move -> carry generation
    e = SL.local_entry(single(2, "reading", "a"), "complete", "a", "A")
    h.assert_equal(gen(e), 2, "forward move (reading->complete) carries generation")
    h.assert_equal(vals(e), "complete", "forward move value")

    -- reopen (backward) -> bump
    e = SL.local_entry(single(2, "complete", "a"), "reading", "a", "A")
    h.assert_equal(gen(e), 3, "reopen (complete->reading) bumps generation")
    h.assert_equal(vals(e), "reading", "reopen value")

    -- sideways (complete->abandoned) -> bump
    e = SL.local_entry(single(0, "complete", "a"), "abandoned", "a", "A")
    h.assert_equal(gen(e), 1, "sideways (complete->abandoned) bumps generation")

    -- clearing status -> no opinion
    h.assert_nil(SL.local_entry(single(1, "reading", "a"), nil, "a", "A"),
        "nil live value -> no local entry")

    -- ancestor is a CONFLICT, our side unchanged -> carry (keep contributing)
    local conflict = entry(0, { "complete", "b" }, { "abandoned", "a" })
    e = SL.local_entry(conflict, "abandoned", "a", "A")  -- device a's own side is abandoned
    h.assert_equal(gen(e), 0, "conflict ancestor, own side unchanged -> carry generation")
    h.assert_equal(vals(e), "abandoned", "still contributes our own side")

    -- ancestor is a CONFLICT, our side changed (resolve via native dialog) -> bump
    e = SL.local_entry(conflict, "complete", "a", "A")   -- a adopts complete
    h.assert_equal(gen(e), 1, "conflict ancestor, side changed -> resolution -> bump")
    h.assert_equal(vals(e), "complete", "resolution value")
end


-- ── resolve: explicit conflict collapse dominates ────────────────────

do
    local conflict = entry(0, { "complete", "b" }, { "abandoned", "a" })
    local res = SL.resolve(conflict, "complete", "a", "A")
    h.assert_equal(gen(res), 1, "resolution is generation+1")
    h.assert_false(SL.is_conflict(res), "resolution is a single value")
    -- and it dominates the conflict when merged back
    local m = SL.merge(res, conflict)
    h.assert_equal(vals(m), "complete", "resolution dominates the conflict on merge")
    h.assert_false(SL.is_conflict(m), "conflict is collapsed after resolution")
end


-- ── §9.5 scenarios (end-to-end: collect + merge) ─────────────────────
--
-- Each device's contribution is built with local_entry against the common
-- ancestor; the two contributions are then merged, as the orchestrator will.

do
    -- Case 1: forward concurrent -- A stays reading, B reads to the end.
    local anc = single(0, "reading", "shared")
    local a = SL.local_entry(anc, "reading",  "a", "A")
    local b = SL.local_entry(anc, "complete", "b", "B")
    local m = SL.merge(a, b)
    h.assert_equal(vals(m), "complete", "Case 1: finished anywhere => finished, no conflict")
    h.assert_false(SL.is_conflict(m), "Case 1: resolved")

    -- Case 2: revert -- book complete everywhere, A reopens to reading.
    anc = single(0, "complete", "shared")
    a = SL.local_entry(anc, "reading",  "a", "A")  -- reopen -> gen 1
    b = SL.local_entry(anc, "complete", "b", "B")  -- stays complete -> gen 0
    m = SL.merge(a, b)
    h.assert_equal(vals(m), "reading", "Case 2: deliberate reopen wins over stale complete (clock-free)")
    h.assert_equal(gen(m), 1, "Case 2: winner is the bumped generation")

    -- Case 3: concurrent reopen vs stay (same shape as Case 2).
    h.assert_false(SL.is_conflict(m), "Case 3: no conflict, reopen dominates")

    -- Case 4 (A progresses past B's reopen): ancestor already reading@1.
    anc = single(1, "reading", "shared")
    a = SL.local_entry(anc, "complete", "a", "A")  -- forward from reading@1 -> complete@1
    b = single(1, "reading", "b")                  -- B's reopened reading@1
    m = SL.merge(a, b)
    h.assert_equal(vals(m), "complete", "Case 4: A finishing after B reopened wins via lattice")

    -- Case 5: the ONLY true conflict -- concurrent complete vs abandoned.
    anc = single(0, "reading", "shared")
    a = SL.local_entry(anc, "complete",  "a", "A")
    b = SL.local_entry(anc, "abandoned", "b", "B")
    m = SL.merge(a, b)
    h.assert_true(SL.is_conflict(m), "Case 5: complete vs abandoned -> surfaced conflict")
    h.assert_equal(vals(m), "abandoned,complete", "Case 5: both candidates held")

    -- Case 6: the demonstrated data (reading vs complete) auto-resolves.
    anc = single(0, "reading", "shared")
    a = SL.local_entry(anc, "reading",  "phone",  "Phone")
    b = SL.local_entry(anc, "complete", "kindle", "Kindle")
    m = SL.merge(a, b)
    h.assert_false(SL.is_conflict(m), "Case 6: demonstrated reading/complete -> no popup")
    h.assert_equal(vals(m), "complete", "Case 6: resolves to complete (finished anywhere)")
end
