-- =============================================================================
-- spec/identity_spec.lua
-- =============================================================================
--
-- Tests for syncery_ann/identity.lua — the position-based key computation
-- that gives each annotation its "identity" for merge purposes.
--
-- The whole 3-way merge stands or falls on this module: if two devices
-- compute different keys for the same annotation, they merge as two
-- separate entries (data duplication); if they compute the same key for
-- two different annotations, one silently overwrites the other (data
-- loss).  So we exercise all three cases (rolling, paging, bookmark)
-- and the edge cases around malformed input.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup()

local Identity = require("syncery_ann/identity")


-- ── Rolling documents: XPointer strings ─────────────────────────────


do
    local key = Identity.compute_key({
        pos0 = "/body/DocFragment[11]/body/div/p[154]/span[2]/text().25",
        pos1 = "/body/DocFragment[11]/body/div/p[154]/span[2]/text().75",
    })
    h.assert_true(key ~= nil, "rolling doc key computed")
    h.assert_true(key:find("||", 1, true) ~= nil,
        "rolling key uses '||' separator between pos0 and pos1")
end


-- ── Rolling: two annotations at SAME position → same key ───────────


do
    local a = { pos0 = "/p[1].0", pos1 = "/p[1].10",
                text = "first selection",  color = "red"  }
    local b = { pos0 = "/p[1].0", pos1 = "/p[1].10",
                text = "different text",   color = "blue" }
    h.assert_equal(Identity.compute_key(a), Identity.compute_key(b),
        "identical positions yield same key regardless of text/color")
end


-- ── Rolling: different positions → different keys ─────────────────


do
    local a = { pos0 = "/p[1].0",  pos1 = "/p[1].10" }
    local b = { pos0 = "/p[2].0",  pos1 = "/p[2].10" }
    h.assert_true(Identity.compute_key(a) ~= Identity.compute_key(b),
        "different positions yield different keys")
end


-- ── Rolling: empty position strings → nil (refuse) ────────────────


do
    h.assert_nil(Identity.compute_key({ pos0 = "",       pos1 = "/p[1].10" }),
        "empty pos0 -> nil")
    h.assert_nil(Identity.compute_key({ pos0 = "/p[1].0", pos1 = ""        }),
        "empty pos1 -> nil")
end


-- ── Paging documents: coordinate tables, no zoom ──────────────────


do
    local ann = {
        page = 5,
        pos0 = { page = 5, x = 100, y = 200 },
        pos1 = { page = 5, x = 200, y = 250 },
    }
    local key = Identity.compute_key(ann)
    h.assert_true(key ~= nil, "paging doc key computed without zoom")
    h.assert_true(key:find("5|100|200||200|250", 1, true) ~= nil,
        "key contains page and normalized coords")
end


-- ── Paging: SAME physical position at different zoom levels → same key ─
--
-- The whole point of zoom normalization.  If you highlight at zoom 1.5
-- on phone and at zoom 2.0 on Kindle, the raw screen coords differ
-- but the physical position is the same, so the keys must match.

do
    local at_zoom_1 = {
        page = 3,
        pos0 = { page = 3, x = 100, y = 200, zoom = 1.0 },
        pos1 = { page = 3, x = 200, y = 250, zoom = 1.0 },
    }
    local at_zoom_2 = {
        page = 3,
        pos0 = { page = 3, x = 200, y = 400, zoom = 2.0 },
        pos1 = { page = 3, x = 400, y = 500, zoom = 2.0 },
    }
    h.assert_equal(Identity.compute_key(at_zoom_1), Identity.compute_key(at_zoom_2),
        "same physical position at different zoom yields same key")
end


-- ── Paging: zero zoom is treated as 1.0 (defensive) ───────────────


do
    -- Corrupted data with zoom=0 shouldn't crash; treated as zoom 1.
    local key = Identity.compute_key({
        page = 1,
        pos0 = { page = 1, x = 10, y = 20, zoom = 0 },
        pos1 = { page = 1, x = 30, y = 40, zoom = 0 },
    })
    h.assert_true(key ~= nil, "zero zoom doesn't crash")
end


-- ── Paging: fractional coords are floored (deterministic) ─────────


do
    local a = Identity.compute_key({
        page = 1,
        pos0 = { page = 1, x = 100.7, y = 200.3, zoom = 1.0 },
        pos1 = { page = 1, x = 200.9, y = 250.1, zoom = 1.0 },
    })
    local b = Identity.compute_key({
        page = 1,
        pos0 = { page = 1, x = 100.2, y = 200.8, zoom = 1.0 },
        pos1 = { page = 1, x = 200.4, y = 250.9, zoom = 1.0 },
    })
    h.assert_equal(a, b,
        "fractional drift within 1px floors to same key")
end


-- ── Bookmark (page-only) → BOOKMARK| prefix ───────────────────────


do
    local key = Identity.compute_key({ page = 42 })
    h.assert_equal(key, "BOOKMARK|42",
        "bookmark key is BOOKMARK|<page>")
end


-- ── Bookmark vs highlight with similar-looking keys do NOT collide ─


do
    local bookmark = Identity.compute_key({ page = 42 })
    -- A paging-doc annotation with page 42 and some coords.  The
    -- key for that is "42|x|y||x|y", which starts with "42" — same
    -- prefix as the bookmark's "42".  The "BOOKMARK|" prefix on the
    -- bookmark side prevents the collision.
    local paging  = Identity.compute_key({
        page = 42,
        pos0 = { page = 42, x = 100, y = 200, zoom = 1 },
        pos1 = { page = 42, x = 200, y = 250, zoom = 1 },
    })
    h.assert_true(bookmark ~= paging,
        "bookmark and paging-highlight on same page don't collide")
end


-- ── Mixed-type positions are rejected (refuse to guess) ───────────


do
    h.assert_nil(Identity.compute_key({
        pos0 = "/p[1].0",
        pos1 = { page = 1, x = 10, y = 20 },
    }), "mixed-type positions -> nil")
end


-- ── Missing pos0 or pos1 (non-bookmark) → nil ─────────────────────


do
    h.assert_nil(Identity.compute_key({ pos0 = "/p[1].0" }),
        "missing pos1 -> nil")
    -- pos1 alone without page → nil (page-only is the bookmark case)
    h.assert_nil(Identity.compute_key({ pos1 = "/p[1].10" }),
        "missing pos0 (and no page) -> nil")
end


-- ── Non-table annotation → nil ─────────────────────────────────────


do
    h.assert_nil(Identity.compute_key(nil),       "nil -> nil")
    h.assert_nil(Identity.compute_key("string"),  "string -> nil")
    h.assert_nil(Identity.compute_key(42),        "number -> nil")
end


-- ── is_valid agrees with compute_key ──────────────────────────────


do
    h.assert_true(Identity.is_valid({ pos0 = "/p[1].0", pos1 = "/p[1].10" }),
        "valid rolling -> is_valid = true")
    h.assert_false(Identity.is_valid({ pos0 = "" }),
        "malformed -> is_valid = false")
    h.assert_true(Identity.is_valid({ page = 1 }),
        "valid bookmark -> is_valid = true")
end


-- ── parse_key recovers components ─────────────────────────────────


do
    local kind, page, _ = Identity.parse_key("BOOKMARK|42")
    h.assert_equal(kind, "BOOKMARK", "parse identifies bookmark")
    h.assert_equal(page, "42",       "parse returns page string")

    local kind2, pos0_part, pos1_part = Identity.parse_key("/p[1].0||/p[1].50")
    h.assert_equal(kind2, "RANGE",     "parse identifies range")
    h.assert_equal(pos0_part, "/p[1].0", "pos0 component recovered")
    h.assert_equal(pos1_part, "/p[1].50","pos1 component recovered")

    h.assert_nil(Identity.parse_key("garbage with no separator"),
        "unparseable key -> nil")
    h.assert_nil(Identity.parse_key(nil),
        "non-string -> nil")
end


-- ── Round-trip: compute_key then parse_key recovers the inputs ────


do
    local pos0 = "/body/p[3]/span[1]/text().10"
    local pos1 = "/body/p[3]/span[1]/text().42"
    local key = Identity.compute_key({ pos0 = pos0, pos1 = pos1 })
    local kind, a, b = Identity.parse_key(key)
    h.assert_equal(kind, "RANGE",                       "RANGE kind recovered")
    h.assert_equal(a, pos0,                             "pos0 recovered exactly")
    h.assert_equal(b, pos1,                             "pos1 recovered exactly")
end
