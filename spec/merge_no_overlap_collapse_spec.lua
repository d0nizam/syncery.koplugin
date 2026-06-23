-- =============================================================================
-- spec/merge_no_overlap_collapse_spec.lua
-- =============================================================================
--
-- Guard for the REMOVAL of the span-overlap collapse pass.
--
-- The pass (`_resolve_span_overlaps`, gated on an injected position
-- comparator) tombstoned the OLDER of ANY intersecting alive pair — not
-- just same-highlight divergent-extension duplicates, but DISTINCT, NESTED,
-- and TOUCHING highlights a user intentionally made (KOReader displays
-- overlapping highlights natively).  Cross-device it could silently delete a
-- user's own highlight; chained, it dropped spans that never overlapped the
-- survivor.  Identity-by-key already dedups the SAME highlight across devices
-- (rolling XPointer + zoom-normalised paging keys), so the pass was an
-- over-reaching add-on with no identity necessity (unlike a keyless plugin
-- that needs overlap AS identity).  It was removed; a duplicate is less bad
-- than a silent loss (the merge's own exact-tie rule already keeps both).
--
-- We pass a comparator to `three_way` ON PURPOSE: it was the lever the removed
-- pass used to collapse overlaps.  The merge must now IGNORE it and keep every
-- distinct highlight.  Restoring `_resolve_span_overlaps` makes these fail.
--
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_no_overlap_collapse_spec_" .. tostring(os.time()))

local Merge    = require("syncery_ann/merge")
local Identity = require("syncery_ann/identity")

-- Same logical span in two formats: rolling (XPointer strings) and paging
-- (coordinate tables) — the bug was format-independent, so guard both.
local function roll(s, e, dt)
    return { pos0 = string.format("%06d", s), pos1 = string.format("%06d", e),
             page = 1, datetime = dt, text = "h" }
end
local function page(s, e, dt)
    return { page = 1, pos0 = { x = s, y = 0, page = 1, zoom = 1 },
             pos1 = { x = e, y = 0, page = 1, zoom = 1 }, datetime = dt, text = "h" }
end
local function val(p) return type(p) == "string" and tonumber(p) or p.x end
-- KOReader sign convention: > 0 when `a` is BEFORE `b`.
local function comparator(a, b) return val(b) - val(a) end

local function keyed(list)
    local m = {}
    for _, a in ipairs(list) do m[Identity.compute_key(a)] = a end
    return m
end
local function alive(merged, ann)
    local e = merged[Identity.compute_key(ann)]
    return e ~= nil and not e.deleted
end
local function count_alive(merged)
    local n = 0
    for _, e in pairs(merged) do if e and not e.deleted then n = n + 1 end end
    return n
end

-- Run a "close" merge with the comparator supplied (the removed pass's lever).
local function merge(loc, anc, rem)
    return Merge.three_way(keyed(loc), keyed(anc or {}), keyed(rem or {}), comparator)
end

for _, fmt in ipairs({ { "rolling", roll }, { "paging", page } }) do
    local tag, mk = fmt[1], fmt[2]

    -- Partial overlap, distinct: BOTH survive (older not collapsed).
    do
        local a = mk(100, 200, "2026-06-12 10:00:00")
        local b = mk(150, 250, "2026-06-12 11:00:00")
        local m = merge({ a, b }, {}, {})
        h.assert_true(alive(m, a), tag .. ": partial-overlap older survives")
        h.assert_true(alive(m, b), tag .. ": partial-overlap newer survives")
    end

    -- Nested, distinct (sentence + phrase inside it): BOTH survive.
    do
        local outer = mk(100, 300, "2026-06-12 10:00:00")
        local inner = mk(150, 200, "2026-06-12 11:00:00")
        local m = merge({ outer, inner }, {}, {})
        h.assert_true(alive(m, outer), tag .. ": nested outer (older) survives")
        h.assert_true(alive(m, inner), tag .. ": nested inner survives")
    end

    -- Touching at a shared endpoint: BOTH survive.
    do
        local a = mk(100, 150, "2026-06-12 10:00:00")
        local b = mk(150, 200, "2026-06-12 11:00:00")
        local m = merge({ a, b }, {}, {})
        h.assert_true(alive(m, a), tag .. ": touching older survives")
        h.assert_true(alive(m, b), tag .. ": touching newer survives")
    end

    -- Transitive chain A-B-C (A & C disjoint): ALL THREE survive — the pass
    -- used to drop C though it never overlapped the survivor.
    do
        local a = mk(100, 200, "2026-06-12 12:00:00")   -- newest
        local b = mk(180, 280, "2026-06-12 11:00:00")
        local c = mk(260, 360, "2026-06-12 10:00:00")
        local m = merge({ a, b, c }, {}, {})
        h.assert_true(alive(m, a) and alive(m, b) and alive(m, c),
            tag .. ": overlap chain keeps all three")
    end

    -- Cross-device adopt: no local, two overlapping remote highlights — BOTH
    -- adopted, neither collapsed.
    do
        local a = mk(100, 200, "2026-06-12 10:00:00")
        local b = mk(150, 250, "2026-06-12 11:00:00")
        local m = merge({}, {}, { a, b })
        h.assert_true(alive(m, a) and alive(m, b),
            tag .. ": adopt of two overlapping remote keeps both")
    end

    -- CONTROL — identical span on two devices (SAME key): deduped by the KEY,
    -- not the pass.  Exactly ONE entry; removal does NOT create a duplicate.
    do
        local a = mk(100, 200, "2026-06-12 10:00:00")
        local b = mk(100, 200, "2026-06-12 11:00:00")   -- same span -> same key
        local m = merge({ a }, {}, { b })
        h.assert_equal(count_alive(m), 1, tag .. ": identical highlight dedups by key (1 entry)")
    end

    -- CONTROL — exact datetime tie, overlapping: both kept (unchanged).
    do
        local a = mk(100, 200, "2026-06-12 10:00:00")
        local b = mk(150, 250, "2026-06-12 10:00:00")   -- same datetime
        local m = merge({ a, b }, {}, {})
        h.assert_true(alive(m, a) and alive(m, b), tag .. ": exact tie keeps both")
    end
end

print("merge_no_overlap_collapse_spec: all assertions passed")
