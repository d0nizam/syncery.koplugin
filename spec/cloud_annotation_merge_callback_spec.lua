-- =============================================================================
-- spec/cloud_annotation_merge_callback_spec.lua
-- =============================================================================
--
-- Direct unit tests for the cloud ANNOTATION merge callback built by
-- Adapter.make_annotation_sync_callback (PROJECT_PLAN.md 18.9.1).
--
-- The callback is the 3-path contract SyncService.sync invokes:
--   sync_cb(local_file, cached_file, income_file) -> bool
-- where local_file = our staged canonical envelope, cached_file (.sync) =
-- the merge ANCESTOR, income_file (.temp) = the downloaded REMOTE state.
--
-- These are the highest-value tests: the callback is pure-ish and
-- headless-testable. We exercise it against REAL on-disk envelopes via
-- JsonStore (rapidjson -> cjson under the harness) and the REAL merge
-- engine (Merge.three_way + MetadataBridge.merge + the orchestrator's
-- render picker), so the test proves Cloud converges identically to
-- Syncthing on the whole envelope (the A-vs-B decision, 18.12.3).
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_cloud_ann_cb_spec_" .. tostring(os.time()))

local Adapter   = require("syncery_transports/cloud/sync_service_adapter")
local JsonStore = require("syncery_ann/json_store")

local DIR = h.test_root .. "/cb"
os.execute("mkdir -p '" .. DIR .. "' 2>/dev/null")

local _n = 0
local function paths()
    _n = _n + 1
    local base = DIR .. "/book" .. _n .. ".json"
    return base, base .. ".sync", base .. ".temp"
end

-- Build an annotation entry at a rolling-doc position key.
local function ann(pos0, pos1, text, ts, deleted)
    return {
        pos0 = pos0, pos1 = pos1, text = text,
        datetime = ts, datetime_updated = ts,
        deleted = deleted and true or false,
        device_id = "devX",
    }
end
local function key(pos0, pos1) return pos0 .. "||" .. pos1 end

local function envelope(opts)
    opts = opts or {}
    return {
        schema_version  = opts.schema_version or 1,
        device_id       = opts.device_id,
        device_label    = opts.device_label,
        annotations     = opts.annotations or {},
        metadata        = opts.metadata or {},
        render_settings = opts.render_settings or {},
    }
end

local function write_json(path, tbl)
    assert(JsonStore.write(path, tbl), "test setup: write failed for " .. path)
end
local function write_raw(path, bytes)
    local f = assert(io.open(path, "wb"))
    f:write(bytes); f:close()
end


-- ----------------------------------------------------------------------------
-- 1. First sync: income MISSING -> remote treated as empty -> merged = local.
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    local k = key("a", "b")
    write_json(lf, envelope({ annotations = { [k] = ann("a", "b", "local note", "2026-01-01 00:00:00") } }))
    -- no cached, no income files on disk
    local cb = Adapter.make_annotation_sync_callback({ canonical_path = lf })
    local ok = cb(lf, cf, inf)
    h.assert_true(ok, "first-sync (income missing) returns true")
    local merged = JsonStore.read(lf)
    h.assert_true(merged.annotations[k] ~= nil, "first-sync keeps local annotation")
    h.assert_equal(merged.annotations[k].text, "local note", "first-sync local text intact")
end


-- ----------------------------------------------------------------------------
-- 2. Clean merge, no conflict: distinct keys union.
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    local k1, k2 = key("a", "b"), key("c", "d")
    write_json(lf,  envelope({ annotations = { [k1] = ann("a", "b", "local", "2026-01-02 00:00:00") } }))
    write_json(cf,  envelope({}))  -- ancestor empty (present but no annotations)
    write_json(inf, envelope({ annotations = { [k2] = ann("c", "d", "remote", "2026-01-02 00:00:00") } }))
    local cb = Adapter.make_annotation_sync_callback({ canonical_path = lf })
    h.assert_true(cb(lf, cf, inf), "clean merge returns true")
    local m = JsonStore.read(lf)
    h.assert_true(m.annotations[k1] ~= nil, "clean merge keeps local-only key")
    h.assert_true(m.annotations[k2] ~= nil, "clean merge adopts remote-only key")
end


-- ----------------------------------------------------------------------------
-- 3. Annotation conflict at same key: newer datetime_updated wins.
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    local k = key("a", "b")
    write_json(lf,  envelope({ annotations = { [k] = ann("a", "b", "OLD local", "2026-01-02 00:00:00") } }))
    write_json(cf,  envelope({}))
    write_json(inf, envelope({ annotations = { [k] = ann("a", "b", "NEW remote", "2026-01-05 00:00:00") } }))
    local cb = Adapter.make_annotation_sync_callback({ canonical_path = lf })
    h.assert_true(cb(lf, cf, inf), "conflict merge returns true")
    local m = JsonStore.read(lf)
    h.assert_equal(m.annotations[k].text, "NEW remote", "newer (remote) wins the conflict")
end


-- ----------------------------------------------------------------------------
-- 4. Metadata conflict AND annotation conflict in the SAME pass.
--    This is the A-vs-B decision expressed as a test: all three envelope
--    sections must converge in one callback invocation.
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    local k = key("a", "b")
    write_json(lf, envelope({
        annotations = { [k] = ann("a", "b", "local note", "2026-01-02 00:00:00") },
        metadata    = { status = { generation = 0, candidates = { { value = "reading", device_id = "L" } } } },
    }))
    write_json(cf, envelope({}))
    write_json(inf, envelope({
        annotations = { [k] = ann("a", "b", "remote note", "2026-01-09 00:00:00") },
        metadata    = { status = { generation = 0, candidates = { { value = "complete", device_id = "R" } } } },
    }))
    local cb = Adapter.make_annotation_sync_callback({ canonical_path = lf })
    h.assert_true(cb(lf, cf, inf), "combined merge returns true")
    local m = JsonStore.read(lf)
    h.assert_equal(m.annotations[k].text, "remote note", "annotation: newer remote wins")
    h.assert_equal(m.metadata.status.candidates[1].value, "complete",
        "metadata status: forward state wins via the lattice (same pass)")
end


-- ----------------------------------------------------------------------------
-- Cloud metadata is 3-way against the .sync ancestor for the generic fields
-- (rating/note/collections/custom), not 2-way newer-wins.  Discriminating
-- case: local equals the ancestor (this device did NOT change the rating),
-- remote changed it with an OLDER timestamp.  3-way adopts the side that
-- changed (remote) -> 3; a 2-way newer-wins merge would keep 5 by timestamp.
-- (Status is the exception: it is merged by the lattice, not the ancestor --
-- see metadata_bridge_spec and docs/SYNC_CONFLICT_STRATEGY.md §9.)
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    write_json(cf, envelope({
        metadata = { rating = { value = 5, datetime_updated = "2026-01-05 00:00:00" } },
    }))
    write_json(lf, envelope({
        metadata = { rating = { value = 5, datetime_updated = "2026-01-05 00:00:00" } },
    }))
    write_json(inf, envelope({
        metadata = { rating = { value = 3, datetime_updated = "2026-01-01 00:00:00" } },
    }))
    local cb = Adapter.make_annotation_sync_callback({ canonical_path = lf })
    h.assert_true(cb(lf, cf, inf), "ancestor-aware merge returns true")
    local m = JsonStore.read(lf)
    h.assert_equal(m.metadata.rating.value, 3,
        "cloud metadata is 3-way: remote's change beats an unchanged local (older ts)")
end


-- ----------------------------------------------------------------------------
-- 5. render_settings: newer datetime_updated wins (2-way).
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    write_json(lf, envelope({
        render_settings = { copt_font_size = { value = 20, datetime_updated = "2026-01-01 00:00:00" } },
    }))
    write_json(cf, envelope({}))
    write_json(inf, envelope({
        render_settings = { copt_font_size = { value = 28, datetime_updated = "2026-01-09 00:00:00" } },
    }))
    local cb = Adapter.make_annotation_sync_callback({ canonical_path = lf })
    h.assert_true(cb(lf, cf, inf), "render merge returns true")
    local m = JsonStore.read(lf)
    h.assert_equal(m.render_settings.copt_font_size.value, 28,
        "render: newer per-field entry wins (centralized merge)")
end


-- ----------------------------------------------------------------------------
-- 6. ABORT on a CORRUPT ancestor (broken JSON) -> never clobber.
--    Canonical must NOT be written.
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    local canon = DIR .. "/canon6.json"
    write_json(lf,  envelope({ annotations = { [key("a","b")] = ann("a","b","local","2026-01-02 00:00:00") } }))
    write_raw(cf, "{ this is not valid json ]")
    write_json(inf, envelope({}))
    local cb = Adapter.make_annotation_sync_callback({ canonical_path = canon })
    h.assert_false(cb(lf, cf, inf), "corrupt ancestor -> abort (false)")
    local _, diag = JsonStore.read(canon)
    h.assert_equal(diag, "not_found", "corrupt ancestor: canonical NOT written")
end


-- ----------------------------------------------------------------------------
-- 7. MISSING ancestor is a clean first sync (distinct from corrupt) -> OK.
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    write_json(lf,  envelope({ annotations = { [key("a","b")] = ann("a","b","local","2026-01-02 00:00:00") } }))
    -- cf intentionally absent
    write_json(inf, envelope({ annotations = { [key("c","d")] = ann("c","d","remote","2026-01-02 00:00:00") } }))
    local cb = Adapter.make_annotation_sync_callback({ canonical_path = lf })
    h.assert_true(cb(lf, cf, inf), "missing ancestor -> first sync OK (true)")
    local m = JsonStore.read(lf)
    h.assert_true(m.annotations[key("a","b")] ~= nil and m.annotations[key("c","d")] ~= nil,
        "missing ancestor: both sides merged")
end


-- ----------------------------------------------------------------------------
-- 8. ABORT on CORRUPT income (invalid JSON that is NOT a 404 body).
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    write_json(lf,  envelope({ annotations = { [key("a","b")] = ann("a","b","local","2026-01-02 00:00:00") } }))
    write_json(cf,  envelope({}))
    write_raw(inf, "\x00\x01 garbage server error body \xff")
    local cb = Adapter.make_annotation_sync_callback({ canonical_path = lf })
    h.assert_false(cb(lf, cf, inf), "corrupt income (non-404) -> abort (false)")
end


-- ----------------------------------------------------------------------------
-- 9. Income that is an UNPARSEABLE 404-ish body -> clean first sync -> OK.
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    local k = key("a", "b")
    write_json(lf,  envelope({ annotations = { [k] = ann("a","b","local","2026-01-02 00:00:00") } }))
    write_json(cf,  envelope({}))
    write_raw(inf, "<html><title>404 Not Found</title></html>")
    local cb = Adapter.make_annotation_sync_callback({ canonical_path = lf })
    h.assert_true(cb(lf, cf, inf), "404 income body -> treated empty -> true")
    local m = JsonStore.read(lf)
    h.assert_equal(m.annotations[k].text, "local", "404 income: local preserved")
end


-- ----------------------------------------------------------------------------
-- 10. ABORT on a CORRUPT local (broken JSON).
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    write_raw(lf, "}}} broken {{{")
    write_json(cf,  envelope({}))
    write_json(inf, envelope({}))
    local cb = Adapter.make_annotation_sync_callback({ canonical_path = lf })
    h.assert_false(cb(lf, cf, inf), "corrupt local -> abort (false)")
end


-- ----------------------------------------------------------------------------
-- 11. Income is valid JSON but WRONG SHAPE (foreign body) -> abort.
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    write_json(lf,  envelope({}))
    write_json(cf,  envelope({}))
    write_raw(inf, '{"annotations":"not-a-table"}')
    local cb = Adapter.make_annotation_sync_callback({ canonical_path = lf })
    h.assert_false(cb(lf, cf, inf), "valid-JSON wrong-shape income -> abort")
end


-- ----------------------------------------------------------------------------
-- 12. Canonical reconcile WRITE FAILURE -> abort (false), so SyncService
--     never advances the ancestor while canonical lags.
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    write_json(lf,  envelope({ annotations = { [key("a","b")] = ann("a","b","local","2026-01-02 00:00:00") } }))
    write_json(cf,  envelope({}))
    write_json(inf, envelope({}))
    -- Force the canonical write to fail with a path THROUGH a file (a
    -- merely-missing dir no longer fails — JsonStore.write makePath's it).
    os.execute("rm -rf /tmp/syncery_canon_blocker")
    os.execute("touch /tmp/syncery_canon_blocker")
    local cb = Adapter.make_annotation_sync_callback({
        canonical_path = "/tmp/syncery_canon_blocker/canon.json",  -- parent is a file → write fails
    })
    h.assert_false(cb(lf, cf, inf), "canonical write failure -> abort (false)")
    os.execute("rm -rf /tmp/syncery_canon_blocker")
end


-- ----------------------------------------------------------------------------
-- 13. on_reconciled hook receives the merged envelope after a good persist.
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    local k = key("a", "b")
    write_json(lf,  envelope({ annotations = { [k] = ann("a","b","local","2026-01-02 00:00:00") } }))
    write_json(cf,  envelope({}))
    write_json(inf, envelope({}))
    local seen
    local cb = Adapter.make_annotation_sync_callback({
        canonical_path = lf,
        on_reconciled  = function(m) seen = m end,
    })
    h.assert_true(cb(lf, cf, inf), "hook case returns true")
    h.assert_true(seen ~= nil and seen.annotations[k] ~= nil,
        "on_reconciled received the merged envelope")
end


-- ----------------------------------------------------------------------------
-- 14. Re-run safety (F3): on a 412 retry the ancestor (.sync) stays FIXED
--     while local has ALREADY absorbed the previous remote merge and income
--     changes. The merge must converge and lose nothing.
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    local kX, kY, kZ = key("x0","x1"), key("y0","y1"), key("z0","z1")

    -- Ancestor: X was previously synced.
    write_json(cf, envelope({ annotations = { [kX] = ann("x0","x1","X","2026-01-01 00:00:00") } }))
    -- Local round 1: X unchanged; plus a local-only addition Y.
    write_json(lf, envelope({ annotations = {
        [kX] = ann("x0","x1","X","2026-01-01 00:00:00"),
        [kY] = ann("y0","y1","Y-local","2026-01-03 00:00:00"),
    } }))
    -- Income round 1: server has X only.
    write_json(inf, envelope({ annotations = { [kX] = ann("x0","x1","X","2026-01-01 00:00:00") } }))

    local cb = Adapter.make_annotation_sync_callback({ canonical_path = lf })
    h.assert_true(cb(lf, cf, inf), "F3 round 1 returns true")
    local m1 = JsonStore.read(lf)
    h.assert_true(m1.annotations[kY] ~= nil and m1.annotations[kY].deleted ~= true,
        "F3 round1: local-only Y survives (not in ancestor -> not a deletion)")

    -- 412 RETRY: ancestor fixed (cf untouched); local_file is now m1 (X,Y);
    -- income round 2 brings a new server entry Z (and still has X).
    write_json(inf, envelope({ annotations = {
        [kX] = ann("x0","x1","X","2026-01-01 00:00:00"),
        [kZ] = ann("z0","z1","Z-remote","2026-01-04 00:00:00"),
    } }))
    h.assert_true(cb(lf, cf, inf), "F3 round 2 (re-run) returns true")
    local m2 = JsonStore.read(lf)
    h.assert_true(m2.annotations[kX] ~= nil, "F3 round2: X retained")
    h.assert_true(m2.annotations[kY] ~= nil and m2.annotations[kY].deleted ~= true,
        "F3 round2: Y (absorbed earlier) NOT wrongly deleted on re-run")
    h.assert_true(m2.annotations[kZ] ~= nil, "F3 round2: new remote Z adopted")
end


-- ----------------------------------------------------------------------------
-- 15. The comparator is threaded through to the merge engine.
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    write_json(lf,  envelope({}))
    write_json(cf,  envelope({}))
    write_json(inf, envelope({}))
    local got_comparator
    local fake_three_way = function(_l, _a, _r, comparator)
        got_comparator = comparator
        return {}
    end
    local my_cmp = function() return 0 end
    local cb = Adapter.make_annotation_sync_callback({
        canonical_path  = lf,
        comparator      = my_cmp,
        merge_three_way = fake_three_way,
    })
    h.assert_true(cb(lf, cf, inf), "comparator-threading case returns true")
    h.assert_equal(got_comparator, my_cmp, "comparator passed to Merge.three_way")
end


-- ----------------------------------------------------------------------------
-- 16. FRESH-DEVICE / WIPE coverage (PROJECT_PLAN.md 18.9.6 / 18.12.9).
--     These CODIFY the proof that 3-way already does the right thing on the
--     cloud path, so NO blocking interlock is added to the callback. The
--     live-state artefact the orchestrator failsafe guards cannot arise here
--     (the callback reads files, not live UI), and the canonical-writer audit
--     showed the file is never falsely-empty.
-- ----------------------------------------------------------------------------

-- 16a. Fresh device: empty local, MISSING ancestor (never synced), full cloud
--      income. Must ADOPT remote, lose nothing — NOT wipe.
do
    local lf, cf, inf = paths()
    local k = key("p0", "p1")
    write_json(lf, envelope({}))                       -- empty local (fresh install)
    -- cf intentionally absent: this device has never synced.
    write_json(inf, envelope({ annotations = {
        [k] = ann("p0", "p1", "cloud note", "2026-01-01 00:00:00"),
    } }))
    local cb = Adapter.make_annotation_sync_callback({ canonical_path = lf })
    h.assert_true(cb(lf, cf, inf), "fresh device pull returns true")
    local m = JsonStore.read(lf)
    h.assert_true(m.annotations[k] ~= nil and m.annotations[k].deleted ~= true,
        "fresh device: cloud annotation adopted, not wiped")
end

-- 16b. First device pushing TO a fresh cloud: full local, MISSING ancestor,
--      EMPTY income (cloud has nothing yet). Must KEEP our notes (no wipe).
do
    local lf, cf, inf = paths()
    local k = key("p0", "p1")
    write_json(lf, envelope({ annotations = {
        [k] = ann("p0", "p1", "my note", "2026-01-01 00:00:00"),
    } }))
    -- cf absent (never synced); income empty (fresh cloud).
    write_json(inf, envelope({}))
    local cb = Adapter.make_annotation_sync_callback({ canonical_path = lf })
    h.assert_true(cb(lf, cf, inf), "first-push-to-fresh-cloud returns true")
    local m = JsonStore.read(lf)
    h.assert_true(m.annotations[k] ~= nil and m.annotations[k].deleted ~= true,
        "first push to fresh cloud: our note KEPT (no data loss)")
end

-- 16c. Deletion from a PEER arrives as a TOMBSTONE in income (not an empty
--      file). The callback applies it -> alive drops to 0. This is the
--      legitimate deletion path; it MUST propagate (an interlock would wrongly
--      block it).
do
    local lf, cf, inf = paths()
    local k = key("p0", "p1")
    local live = ann("p0", "p1", "note", "2026-01-01 00:00:00")
    write_json(lf, envelope({ annotations = { [k] = live } }))
    write_json(cf, envelope({ annotations = { [k] = live } }))  -- ancestor: alive
    write_json(inf, envelope({ annotations = {
        [k] = ann("p0", "p1", "note", "2026-01-05 00:00:00", true),  -- peer tombstone, newer
    } }))
    local cb = Adapter.make_annotation_sync_callback({ canonical_path = lf })
    h.assert_true(cb(lf, cf, inf), "peer-tombstone merge returns true")
    local m = JsonStore.read(lf)
    h.assert_true(m.annotations[k] ~= nil and m.annotations[k].deleted == true,
        "peer deletion (tombstone) propagated, not blocked")
end
