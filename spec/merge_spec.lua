-- =============================================================================
-- spec/merge_spec.lua
-- =============================================================================
--
-- Unit tests for syncery_ann/merge.lua — the pure 3-way-merge function
-- plus the upsert/delete/list helpers.  No KOReader globals needed
-- beyond `os.date` (which lua provides natively), so this spec is the
-- cleanest of the bunch.
--
-- Each named test mutates `h.assertions_made` indirectly through
-- helpers.assert_*; the test runner reports the totals at the end.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup()

local Merge      = require("syncery_ann/merge")
local Identity   = require("syncery_ann/identity")
local TimeFormat = require("syncery_ann/time_format")


-- ── Tiny builder for test annotations ────────────────────────────────


--- Build a rolling-doc highlight annotation with the given fields.
local function highlight(opts)
    return {
        type     = "highlight",
        pos0     = opts.pos0 or "/body/p[1].0",
        pos1     = opts.pos1 or "/body/p[1].50",
        text     = opts.text or "some text",
        drawer   = "lighten",
        color    = opts.color or "yellow",
        datetime         = opts.datetime         or "2024-01-01 12:00:00",
        datetime_updated = opts.datetime_updated or "2024-01-01 12:00:00",
        deleted          = opts.deleted or false,
        device_id        = opts.device_id        or "phone",
        device_label     = opts.device_label     or "Phone",
    }
end


--- Convert a list of annotations to a state map keyed by identity.
local function as_map(anns)
    local m = {}
    for _, a in ipairs(anns) do
        m[Identity.compute_key(a)] = a
    end
    return m
end


-- ── Test 1: brand-new local annotation ───────────────────────────────
--
-- Local has annotation A.  Last-sync is empty (never synced).  Remote
-- is empty.  Expected: merged contains A.

do
    local A = highlight({ pos0 = "/p[1].0", pos1 = "/p[1].10", text = "alpha" })
    local merged = Merge.three_way(as_map({A}), {}, {})

    h.assert_equal(merged[Identity.compute_key(A)].text, "alpha",
        "new local annotation survives")
end


-- ── Test 2: remote-only annotation gets pulled in ────────────────────

do
    local B = highlight({ pos0 = "/p[2].0", pos1 = "/p[2].10", text = "beta" })
    local merged = Merge.three_way({}, {}, as_map({B}))

    h.assert_equal(merged[Identity.compute_key(B)].text, "beta",
        "remote-only annotation appears in merge")
end


-- ── Test 3: local deletion produces a tombstone ──────────────────────
--
-- Last-sync had X, local doesn't have it anymore, remote still has
-- the original X.  Expected: merged has X as a tombstone.

do
    local X = highlight({
        pos0 = "/p[1].0", pos1 = "/p[1].10",
        text = "original",
        datetime_updated = "2024-01-01 10:00:00",
    })
    local last_sync = as_map({X})
    local local_map = {}                       -- user deleted X locally
    local remote_map = as_map({X})             -- remote still has alive X

    local merged = Merge.three_way(local_map, last_sync, remote_map)
    local entry = merged[Identity.compute_key(X)]

    h.assert_true(entry ~= nil,    "deleted entry is still present")
    h.assert_true(entry.deleted,   "deleted entry is a tombstone")
end


-- ── Test 4: remote edit beats older local ────────────────────────────

do
    local pos0, pos1 = "/p[5].0", "/p[5].20"

    local local_v  = highlight({ pos0 = pos0, pos1 = pos1, text = "old note",
                                 datetime_updated = "2024-01-01 10:00:00" })
    local remote_v = highlight({ pos0 = pos0, pos1 = pos1, text = "fresh note",
                                 datetime_updated = "2024-06-01 10:00:00" })
    local last_sync = as_map({local_v})  -- both knew the old version

    local merged = Merge.three_way(as_map({local_v}), last_sync, as_map({remote_v}))
    h.assert_equal(merged[Identity.compute_key(local_v)].text, "fresh note",
        "newer remote wins over older local")
end


-- ── Test 5: tombstone wins datetime tie ──────────────────────────────
--
-- Both sides have the same datetime_updated but local is alive and
-- remote is a tombstone.  Tombstone should win (deletion happens-
-- after creation by causality).

do
    local pos0, pos1 = "/p[7].0", "/p[7].20"
    local same_time = "2024-05-01 12:00:00"

    local alive = highlight({
        pos0 = pos0, pos1 = pos1, text = "x", deleted = false,
        datetime_updated = same_time })
    local tomb = highlight({
        pos0 = pos0, pos1 = pos1, text = "x", deleted = true,
        datetime_updated = same_time })

    local merged = Merge.three_way(as_map({alive}), {}, as_map({tomb}))
    h.assert_true(merged[Identity.compute_key(alive)].deleted,
        "tombstone wins exact-datetime tie")
end


-- ── Test 6: re-running merge with same inputs is idempotent ──────────

do
    local A = highlight({ pos0 = "/p[1].0", pos1 = "/p[1].10", text = "alpha" })
    local B = highlight({ pos0 = "/p[2].0", pos1 = "/p[2].10", text = "beta" })
    local C = highlight({ pos0 = "/p[3].0", pos1 = "/p[3].10", text = "gamma", deleted = true })

    local local_map  = as_map({A, B})
    local last_sync  = as_map({A})
    local remote_map = as_map({A, C})

    local merged_once  = Merge.three_way(local_map, last_sync, remote_map)
    local merged_twice = Merge.three_way(merged_once, last_sync, remote_map)

    h.assert_deep_equal(merged_twice, merged_once, "merge is idempotent")
end


-- ── Test 7: list_alive_annotations strips tombstones ─────────────────

do
    local A = highlight({ pos0 = "/p[1].0", pos1 = "/p[1].10", text = "alive" })
    local B = highlight({ pos0 = "/p[2].0", pos1 = "/p[2].10", text = "dead",
                          deleted = true })

    local list = Merge.list_alive_annotations(as_map({A, B}))
    h.assert_equal(#list, 1,                "exactly one alive annotation")
    h.assert_equal(list[1].text, "alive",   "the alive one is the right one")
end


-- ── Test 8: upsert_annotation stamps device + datetime ───────────────

do
    local state = {}
    local fresh = highlight({
        pos0 = "/p[9].0", pos1 = "/p[9].10",
        text = "fresh", datetime_updated = nil, device_id = nil })

    local new_state = Merge.upsert_annotation(state, fresh, "kindle", "Kindle")
    local key = Identity.compute_key(fresh)
    local entry = new_state[key]

    h.assert_true(entry ~= nil,                       "upsert inserted")
    h.assert_equal(entry.device_id, "kindle",        "device_id stamped")
    h.assert_equal(entry.device_label, "Kindle",     "device_label stamped")
    h.assert_true(entry.datetime_updated ~= nil and entry.datetime_updated ~= "",
                                                     "datetime_updated set")
end


-- ── Test 9: delete_annotation writes a tombstone preserving fields ───

do
    local A = highlight({
        pos0 = "/p[11].0", pos1 = "/p[11].10",
        text = "to-be-deleted", color = "red" })
    local state = { [Identity.compute_key(A)] = A }

    local new_state = Merge.delete_annotation(state, A, "phone", "Phone")
    local tomb = new_state[Identity.compute_key(A)]

    h.assert_true(tomb.deleted,                  "tombstone deleted flag")
    h.assert_equal(tomb.text, "to-be-deleted",   "original text preserved")
    h.assert_equal(tomb.color, "red",            "original color preserved")
    h.assert_equal(tomb.device_id, "phone",      "deleting device recorded")
end


-- ── Test 10: tombstone carry-forward on slow peer scenario ───────────
--
-- Last-sync already had a tombstone for X.  Local doesn't have X
-- (already applied the deletion in a prior session).  Remote has the
-- same tombstone.  Expected: tombstone carries forward unchanged
-- (its timestamp is NOT bumped — the deletion already happened).

do
    local pos0, pos1 = "/p[13].0", "/p[13].10"
    local old_time   = "2024-01-01 09:00:00"

    local X_tomb = highlight({
        pos0 = pos0, pos1 = pos1, text = "x", deleted = true,
        datetime_updated = old_time })

    local local_map  = {}
    local last_sync  = { [Identity.compute_key(X_tomb)] = X_tomb }
    local remote_map = { [Identity.compute_key(X_tomb)] = X_tomb }

    local merged = Merge.three_way(local_map, last_sync, remote_map)
    local entry = merged[Identity.compute_key(X_tomb)]

    h.assert_true(entry.deleted,                            "still a tombstone")
    h.assert_equal(entry.datetime_updated, old_time,
        "tombstone timestamp NOT bumped on carry-forward")
end


-- ── Test 11: invalid annotation produces no key ─────────────────────

do
    local bad = { type = "highlight" }  -- no pos0/pos1
    h.assert_nil(Identity.compute_key(bad), "bad annotation -> nil key")
end


-- ── Test 12: local note edit survives a stale-timestamp tie ──────────
--
-- KOReader does NOT bump datetime_updated when the TEXT of an existing
-- note is edited (the bookmark type stays "note", so no AnnotationsModified
-- fires).  The edit therefore ties on datetime and the plain pick adopts the
-- remote (old) copy -- losing the edit.  The note-preservation pass must
-- re-assert it.  Crucially, the editor's local copy may carry an ADAPTED
-- style (foreign annotation restyled to this device); the merged result must
-- keep the remote's ORIGINAL style so an adapted style is never leaked.

do
    local STALE = "2024-06-01 10:00:00"
    local function noted(note, drawer, color)
        local a = highlight({ datetime_updated = STALE })
        a.note   = note
        a.drawer = drawer
        a.color  = color
        return a
    end
    local ancestor = noted("old note",    "lighten",    "yellow")  -- last-synced
    local remote   = noted("old note",    "lighten",    "yellow")  -- shared unchanged
    local localv   = noted("edited note", "underscore", nil)       -- edit + ADAPTED style, STALE dt

    local key = Identity.compute_key(localv)
    local merged = Merge.three_way(as_map({localv}), as_map({ancestor}), as_map({remote}))
    local m = merged[key]

    h.assert_equal(m.note, "edited note",
        "local note edit survives a stale-timestamp tie")
    h.assert_equal(m.drawer, "lighten",
        "merged keeps the remote ORIGINAL drawer (adapted local style not leaked)")
    h.assert_equal(m.color, "yellow",
        "merged keeps the remote ORIGINAL color (adapted local style not leaked)")
    h.assert_true(m.datetime_updated ~= STALE,
        "note edit gets a fresh datetime_updated so it propagates")
end


-- ── Test 13: two-sided note conflict is NOT forced to local ──────────
--
-- When BOTH sides changed the note vs the ancestor, the overlay must NOT
-- fire (it would make local always win); the deterministic datetime pick
-- decides.  Here remote is strictly newer, so remote wins.

do
    local function noted(note, dt)
        local a = highlight({ datetime_updated = dt }); a.note = note; return a
    end
    local ancestor = noted("old note",    "2024-06-01 10:00:00")
    local localv   = noted("local edit",  "2024-06-01 10:00:00")  -- stale
    local remote   = noted("remote edit", "2024-06-01 11:00:00")  -- newer
    local key = Identity.compute_key(localv)
    local merged = Merge.three_way(as_map({localv}), as_map({ancestor}), as_map({remote}))
    h.assert_equal(merged[key].note, "remote edit",
        "two-sided note conflict falls to the datetime pick, local not force-applied")
end


-- ── Test 14: remote-only note change does not trigger the overlay ────
--
-- Local left the note untouched; only remote changed it.  The overlay's
-- "local changed the note" guard must keep it from firing, and the normal
-- pick adopts the remote note.

do
    local function noted(note, dt)
        local a = highlight({ datetime_updated = dt }); a.note = note; return a
    end
    local ancestor = noted("old note",    "2024-06-01 10:00:00")
    local localv   = noted("old note",    "2024-06-01 10:00:00")  -- unchanged locally
    local remote   = noted("remote edit", "2024-06-01 11:00:00")
    local key = Identity.compute_key(localv)
    local merged = Merge.three_way(as_map({localv}), as_map({ancestor}), as_map({remote}))
    h.assert_equal(merged[key].note, "remote edit",
        "remote-only note change is adopted; the local overlay does not fire")
end


-- ── Test 15: adapted style leak is stripped from the merge winner ────
--
-- With adapt_highlight_style on, the local sidecar holds the adapt OUTPUT
-- for a foreign annotation (color=nil, drawer=device default).  An edit
-- makes the local side win the merge, so that display artifact would leak
-- into the shared file.  _strip_adapted_style_leak restores the author's
-- original style from the remote for fields that still equal the adapt
-- output (local device "kindle", device default drawer "underscore").

do
    local function foreign(color, drawer)
        local a = highlight({})          -- device_id = "phone" (foreign to "kindle")
        a.color  = color
        a.drawer = drawer
        return a
    end
    local KEY  = Identity.compute_key(foreign("yellow", "lighten"))
    local opts = { adapt_highlight_style = true, local_device_id = "kindle",
                   default_drawer = "underscore" }

    local merged = { [KEY] = foreign(nil, "underscore") }   -- adapt output
    Merge._strip_adapted_style_leak(merged, { [KEY] = foreign("yellow", "lighten") }, opts)
    h.assert_equal(merged[KEY].color,  "yellow",
        "adapted nil color restored to the author's original")
    h.assert_equal(merged[KEY].drawer, "lighten",
        "adapted device-default drawer restored to the author's original")
end


-- ── Test 16: deliberate restyle survives the de-leak ────────────────
--
-- A field that DIFFERS from the adapt output is a real user change and is
-- kept; only the still-artifact field is restored.

do
    local function foreign(color, drawer)
        local a = highlight({}); a.color = color; a.drawer = drawer; return a
    end
    local KEY  = Identity.compute_key(foreign("yellow", "lighten"))
    local opts = { adapt_highlight_style = true, local_device_id = "kindle",
                   default_drawer = "underscore" }
    local function orig() return { [KEY] = foreign("yellow", "lighten") } end

    -- deliberate recolor (color=red, not nil): keep red, restore the still-default drawer
    local m1 = { [KEY] = foreign("red", "underscore") }
    Merge._strip_adapted_style_leak(m1, orig(), opts)
    h.assert_equal(m1[KEY].color,  "red",     "deliberate recolor is kept")
    h.assert_equal(m1[KEY].drawer, "lighten", "the still-artifact drawer is restored alongside")

    -- deliberate restyle (drawer=strikeout, not default): keep it, restore the nil color
    local m2 = { [KEY] = foreign(nil, "strikeout") }
    Merge._strip_adapted_style_leak(m2, orig(), opts)
    h.assert_equal(m2[KEY].color,  "yellow",    "the still-artifact color is restored alongside")
    h.assert_equal(m2[KEY].drawer, "strikeout", "deliberate restyle is kept")
end


-- ── Test 17: de-leak gates (adapt off, own annotations) ─────────────

do
    local function ann(color, drawer, device_id)
        local a = highlight({}); a.color = color; a.drawer = drawer
        a.device_id = device_id
        return a
    end
    local KEY    = Identity.compute_key(ann("yellow", "lighten", "phone"))
    local remote = { [KEY] = ann("yellow", "lighten", "phone") }

    -- adapt OFF -> no-op even with an adapted-looking style
    local m1 = { [KEY] = ann(nil, "underscore", "phone") }
    Merge._strip_adapted_style_leak(m1, remote,
        { adapt_highlight_style = false, local_device_id = "kindle", default_drawer = "underscore" })
    h.assert_nil(m1[KEY].color,                 "adapt off: nothing restored (color stays nil)")
    h.assert_equal(m1[KEY].drawer, "underscore", "adapt off: drawer unchanged")

    -- OWN annotation (device_id == local) is never adapted -> untouched
    local m2 = { [KEY] = ann(nil, "underscore", "kindle") }
    Merge._strip_adapted_style_leak(m2, remote,
        { adapt_highlight_style = true, local_device_id = "kindle", default_drawer = "underscore" })
    h.assert_nil(m2[KEY].color,                 "own annotation: not foreign, left untouched")
    h.assert_equal(m2[KEY].drawer, "underscore", "own annotation: drawer unchanged")
end


-- ── Test 18: same-kind datetime tie is COMMUTATIVE (device-id tiebreak) ──
--
-- Two live annotations, same datetime_updated, different device_id.
-- _pick_newer_of_two must return the SAME winner regardless of argument
-- order (merge(a,b) == merge(b,a)), so two devices -- each calling
-- merge(own, remote) -- converge to identical bytes.  The old `return
-- annotation_b` fallback favoured argument order and failed this.

do
    local a = highlight({ device_id = "alpha", text = "A",
        datetime_updated = "2024-06-01 09:00:00" })
    local b = highlight({ device_id = "bravo", text = "B",
        datetime_updated = "2024-06-01 09:00:00" })

    local ab = Merge._pick_newer_of_two(a, b)
    local ba = Merge._pick_newer_of_two(b, a)
    h.assert_equal(ab.device_id, ba.device_id,
        "pick_newer_of_two: same-kind datetime tie is COMMUTATIVE (merge(a,b)==merge(b,a))")
    -- Deterministic winner = higher device_id ("bravo" > "alpha").
    h.assert_equal(ab.device_id, "bravo",
        "pick_newer_of_two: tie broken on device_id (higher wins), not argument order")
end

-- ── Per-type filtering: classify_type (key-aware) ────────────────────
--
-- The KEY decides bookmark-vs-range and survives tombstone compaction
-- (which drops drawer/pos/note); the `note` field only splits range into
-- highlight-vs-note.  See docs/PER_TYPE_FILTER_DESIGN.md §16.

do
    local RANGE_KEY = "/body/p[1].0||/body/p[1].50"   -- range -> highlight/note
    local BM_KEY    = "BOOKMARK|7"                     -- bookmark

    local hl = highlight({})                           -- drawer, no note
    local nt = highlight({}); nt.note = "a note"       -- drawer + note
    h.assert_equal(Merge.classify_type(RANGE_KEY, hl), "highlight",
        "range key, no note -> highlight")
    h.assert_equal(Merge.classify_type(RANGE_KEY, nt), "note",
        "range key + note -> note")
    h.assert_equal(Merge.classify_type(BM_KEY, { page = 7 }), "bookmark",
        "bookmark key -> bookmark")

    -- COMPACTED tombstone: GC dropped drawer/pos/note, so only the KEY is left
    -- to classify by.  A field-based classify would call this "bookmark" and
    -- (bookmarks-off) prep the highlight DELETION out of the merge -> §16.1.
    local compacted = { deleted = true, datetime_updated = "2024-01-01 00:00:00" }
    h.assert_equal(Merge.classify_type(RANGE_KEY, compacted), "highlight",
        "compacted range tombstone -> highlight (NOT bookmark)")
    h.assert_equal(Merge.classify_type(BM_KEY, compacted), "bookmark",
        "compacted bookmark tombstone -> bookmark")
end


-- ── Per-type filtering: _out_scope_keys (per-key ANY rule) ───────────
--
-- A key is out of scope iff ANY of the three maps classifies it to a
-- disabled type.  A key whose type DIFFERS across maps (a highlight that
-- gained a note) is wholly in or wholly out -- never split.  §11 Bug #1.

do
    local hl_a = highlight({ pos0 = "/p[1].0", pos1 = "/p[1].9", text = "H" })
    local kH   = Identity.compute_key(hl_a)
    local bm   = { page = 3, datetime = "2024-01-01 00:00:00",
                   datetime_updated = "2024-01-01 00:00:00" }
    local kB   = Identity.compute_key(bm)

    -- bookmarks disabled: only the bookmark key is out; the highlight stays in.
    local out = Merge._out_scope_keys(
        { [kH] = hl_a, [kB] = bm }, {}, {}, { bookmark = true })
    h.assert_true(out[kB] == true, "bookmark key is out of scope when bookmarks off")
    h.assert_true(out[kH] == nil,  "highlight key stays in scope when bookmarks off")

    -- ANY rule across maps: same range key is a bare highlight in local but a
    -- NOTE in remote; with notes disabled the WHOLE key is out (not split).
    local note_v = highlight({ pos0 = "/p[1].0", pos1 = "/p[1].9", text = "H" })
    note_v.note  = "added later"
    local kHN    = Identity.compute_key(note_v)     -- same key as hl_a's range
    local out2   = Merge._out_scope_keys(
        { [kHN] = hl_a }, {}, { [kHN] = note_v }, { note = true })
    h.assert_true(out2[kHN] == true,
        "range key out when ANY map classifies it a (disabled) note")

    -- nothing disabled -> empty out set.
    local out3 = Merge._out_scope_keys({ [kH] = hl_a, [kB] = bm }, {}, {}, {})
    h.assert_true(next(out3) == nil, "no disabled types -> no keys out of scope")
end
