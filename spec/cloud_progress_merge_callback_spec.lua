-- =============================================================================
-- spec/cloud_progress_merge_callback_spec.lua
-- =============================================================================
--
-- Direct unit tests for the cloud PROGRESS merge callback built by
-- Adapter.make_progress_sync_callback (PROJECT_PLAN.md 18.9.2).
--
-- Same 3-path contract SyncService.sync invokes:
--   sync_cb(local_file, cached_file, income_file) -> bool
--
-- Progress differs from annotations (verified, 18.12.5):
--   * canonical file is a ONE-section envelope: { schema_version,
--     device_id, device_label, entries={ [device_id]=entry } };
--   * merge is syncery_progress/merge.three_way (3-way, (revision,
--     timestamp) newer-wins) — the SAME fn the progress Syncthing
--     orchestrator uses, so Cloud and Syncthing converge on the same file;
--   * NO live-state entry generation, NO wipe failsafe here (18.9.6).
--
-- Guard discipline is 1:1 with the annotation callback.
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_cloud_prog_cb_spec_" .. tostring(os.time()))

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

-- A progress entry for a device.
local function entry(device_id, revision, timestamp, percent, page)
    return {
        device_id = device_id,
        revision  = revision,
        timestamp = timestamp,
        percent   = percent or 0,
        page      = page or 0,
    }
end

local function state(opts)
    opts = opts or {}
    return {
        schema_version = opts.schema_version or 1,
        device_id      = opts.device_id,
        device_label   = opts.device_label,
        entries        = opts.entries or {},
    }
end

local function write_json(path, tbl)
    assert(JsonStore.write(path, tbl), "test setup: write failed for " .. path)
end
local function write_raw(path, bytes)
    local f = assert(io.open(path, "wb")); f:write(bytes); f:close()
end


-- ----------------------------------------------------------------------------
-- 1. First sync: income MISSING -> remote empty -> merged keeps local.
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    write_json(lf, state({ entries = { dev1 = entry("dev1", 3, 300, 0.5, 50) } }))
    local cb = Adapter.make_progress_sync_callback({ canonical_path = lf })
    h.assert_true(cb(lf, cf, inf), "first-sync (income missing) returns true")
    local m = JsonStore.read(lf)
    h.assert_true(m.entries.dev1 ~= nil,            "first-sync keeps local entry")
    h.assert_equal(m.entries.dev1.revision, 3,      "first-sync local revision intact")
end


-- ----------------------------------------------------------------------------
-- 2. Clean merge: distinct devices union.
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    write_json(lf,  state({ entries = { devA = entry("devA", 1, 100, 0.2, 20) } }))
    write_json(cf,  state({}))
    write_json(inf, state({ entries = { devB = entry("devB", 1, 100, 0.7, 70) } }))
    local cb = Adapter.make_progress_sync_callback({ canonical_path = lf })
    h.assert_true(cb(lf, cf, inf), "clean merge returns true")
    local m = JsonStore.read(lf)
    h.assert_true(m.entries.devA ~= nil, "clean merge keeps local-only device")
    h.assert_true(m.entries.devB ~= nil, "clean merge adopts remote-only device")
end


-- ----------------------------------------------------------------------------
-- 3. Same-device conflict: higher (revision, timestamp) wins.
--    Local rev=2, remote rev=5 for the SAME device -> remote wins.
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    write_json(lf,  state({ entries = { dev1 = entry("dev1", 2, 999, 0.3, 30) } }))  -- newer ts, older rev
    write_json(cf,  state({}))
    write_json(inf, state({ entries = { dev1 = entry("dev1", 5, 100, 0.8, 80) } }))  -- older ts, NEWER rev
    local cb = Adapter.make_progress_sync_callback({ canonical_path = lf })
    h.assert_true(cb(lf, cf, inf), "conflict merge returns true")
    local m = JsonStore.read(lf)
    h.assert_equal(m.entries.dev1.revision, 5,   "higher revision wins (not newer timestamp)")
    h.assert_equal(m.entries.dev1.percent,  0.8, "winning entry's payload kept")
end


-- ----------------------------------------------------------------------------
-- 4. ABORT on a CORRUPT ancestor -> never clobber; canonical NOT written.
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    local canon = DIR .. "/canon4.json"
    write_json(lf,  state({ entries = { dev1 = entry("dev1", 1, 100, 0.4, 40) } }))
    write_raw(cf, "{ not valid json ]")
    write_json(inf, state({}))
    local cb = Adapter.make_progress_sync_callback({ canonical_path = canon })
    h.assert_false(cb(lf, cf, inf), "corrupt ancestor -> abort (false)")
    local _, diag = JsonStore.read(canon)
    h.assert_equal(diag, "not_found", "corrupt ancestor: canonical NOT written")
end


-- ----------------------------------------------------------------------------
-- 5. MISSING ancestor is a clean first sync (distinct from corrupt) -> OK.
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    write_json(lf,  state({ entries = { devA = entry("devA", 1, 100, 0.2, 20) } }))
    write_json(inf, state({ entries = { devB = entry("devB", 1, 100, 0.7, 70) } }))
    local cb = Adapter.make_progress_sync_callback({ canonical_path = lf })
    h.assert_true(cb(lf, cf, inf), "missing ancestor -> first sync OK (true)")
    local m = JsonStore.read(lf)
    h.assert_true(m.entries.devA ~= nil and m.entries.devB ~= nil,
        "missing ancestor: both sides merged")
end


-- ----------------------------------------------------------------------------
-- 6. ABORT on CORRUPT income (invalid JSON that is NOT a 404 body).
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    write_json(lf,  state({ entries = { dev1 = entry("dev1", 1, 100, 0.4, 40) } }))
    write_json(cf,  state({}))
    write_raw(inf, "\x00\x01 server exploded \xff")
    local cb = Adapter.make_progress_sync_callback({ canonical_path = lf })
    h.assert_false(cb(lf, cf, inf), "corrupt income (non-404) -> abort (false)")
end


-- ----------------------------------------------------------------------------
-- 7. Income that is an UNPARSEABLE 404-ish body -> clean first sync -> OK.
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    write_json(lf,  state({ entries = { dev1 = entry("dev1", 2, 100, 0.4, 40) } }))
    write_json(cf,  state({}))
    write_raw(inf, "<html><title>404 Not Found</title></html>")
    local cb = Adapter.make_progress_sync_callback({ canonical_path = lf })
    h.assert_true(cb(lf, cf, inf), "404 income body -> treated empty -> true")
    local m = JsonStore.read(lf)
    h.assert_equal(m.entries.dev1.revision, 2, "404 income: local preserved")
end


-- ----------------------------------------------------------------------------
-- 8. ABORT on a CORRUPT local (broken JSON).
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    write_raw(lf, "}}} broken {{{")
    write_json(cf,  state({}))
    write_json(inf, state({}))
    local cb = Adapter.make_progress_sync_callback({ canonical_path = lf })
    h.assert_false(cb(lf, cf, inf), "corrupt local -> abort (false)")
end


-- ----------------------------------------------------------------------------
-- 9. Income valid JSON but WRONG SHAPE (entries not a table) -> abort.
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    write_json(lf,  state({}))
    write_json(cf,  state({}))
    write_raw(inf, '{"entries":"not-a-table"}')
    local cb = Adapter.make_progress_sync_callback({ canonical_path = lf })
    h.assert_false(cb(lf, cf, inf), "valid-JSON wrong-shape income -> abort")
end


-- ----------------------------------------------------------------------------
-- 10. Canonical reconcile WRITE FAILURE -> abort (false).
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    write_json(lf,  state({ entries = { dev1 = entry("dev1", 1, 100, 0.4, 40) } }))
    write_json(cf,  state({}))
    write_json(inf, state({}))
    -- Force the canonical write to fail with a path THROUGH a file (a
    -- merely-missing dir no longer fails — JsonStore.write makePath's it).
    os.execute("rm -rf /tmp/syncery_canon_blocker_p")
    os.execute("touch /tmp/syncery_canon_blocker_p")
    local cb = Adapter.make_progress_sync_callback({
        canonical_path = "/tmp/syncery_canon_blocker_p/canon.json",  -- parent is a file → write fails
    })
    h.assert_false(cb(lf, cf, inf), "canonical write failure -> abort (false)")
    os.execute("rm -rf /tmp/syncery_canon_blocker_p")
end


-- ----------------------------------------------------------------------------
-- 11. on_reconciled hook receives the merged state after a good persist.
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    write_json(lf,  state({ entries = { dev1 = entry("dev1", 1, 100, 0.4, 40) } }))
    write_json(cf,  state({}))
    write_json(inf, state({}))
    local seen
    local cb = Adapter.make_progress_sync_callback({
        canonical_path = lf,
        on_reconciled  = function(m) seen = m end,
    })
    h.assert_true(cb(lf, cf, inf), "hook case returns true")
    h.assert_true(seen ~= nil and seen.entries.dev1 ~= nil,
        "on_reconciled received the merged state")
end


-- ----------------------------------------------------------------------------
-- 12. Re-run safety (F3): on a 412 retry the ancestor (.sync) stays FIXED
--     while local has ALREADY absorbed the previous remote merge and income
--     changes. (revision, timestamp) newer-wins is idempotent — prove it.
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()

    -- Ancestor: devX previously synced at revision 1.
    write_json(cf, state({ entries = { devX = entry("devX", 1, 100, 0.1, 10) } }))
    -- Local round 1: devX unchanged; plus a local-only devY.
    write_json(lf, state({ entries = {
        devX = entry("devX", 1, 100, 0.1, 10),
        devY = entry("devY", 3, 300, 0.3, 30),
    } }))
    -- Income round 1: server has devX only (same rev).
    write_json(inf, state({ entries = { devX = entry("devX", 1, 100, 0.1, 10) } }))

    local cb = Adapter.make_progress_sync_callback({ canonical_path = lf })
    h.assert_true(cb(lf, cf, inf), "F3 round 1 returns true")
    local m1 = JsonStore.read(lf)
    h.assert_true(m1.entries.devY ~= nil, "F3 round1: local-only devY survives")

    -- 412 RETRY: ancestor fixed; local_file is now m1 (devX, devY);
    -- income round 2 brings a new server device devZ (and devX again).
    write_json(inf, state({ entries = {
        devX = entry("devX", 1, 100, 0.1, 10),
        devZ = entry("devZ", 4, 400, 0.4, 40),
    } }))
    h.assert_true(cb(lf, cf, inf), "F3 round 2 (re-run) returns true")
    local m2 = JsonStore.read(lf)
    h.assert_true(m2.entries.devX ~= nil, "F3 round2: devX retained")
    h.assert_true(m2.entries.devY ~= nil, "F3 round2: devY (absorbed earlier) NOT lost on re-run")
    h.assert_true(m2.entries.devZ ~= nil, "F3 round2: new remote devZ adopted")
    -- Idempotency proof: a THIRD run with the SAME income changes nothing.
    h.assert_true(cb(lf, cf, inf), "F3 round 3 (same income) returns true")
    local m3 = JsonStore.read(lf)
    h.assert_equal(m3.entries.devX.revision, m2.entries.devX.revision, "F3: devX stable across re-run")
    h.assert_equal(m3.entries.devY.revision, m2.entries.devY.revision, "F3: devY stable across re-run")
    h.assert_equal(m3.entries.devZ.revision, m2.entries.devZ.revision, "F3: devZ stable across re-run")
end


-- ----------------------------------------------------------------------------
-- 13. Ancestor participates as a floor (transport-convergence vs a naive
--     2-way): if BOTH local and remote are OLDER than the ancestor for a
--     device, the ancestor entry is preserved — exactly as the progress
--     Syncthing orchestrator's 3-way does. A 2-way merge_two_states(local,
--     income) would LOSE the ancestor's higher revision here.
-- ----------------------------------------------------------------------------
do
    local lf, cf, inf = paths()
    write_json(lf,  state({ entries = { devX = entry("devX", 2, 200, 0.2, 20) } }))  -- local older
    write_json(cf,  state({ entries = { devX = entry("devX", 9, 900, 0.9, 90) } }))  -- ANCESTOR highest
    write_json(inf, state({ entries = { devX = entry("devX", 3, 300, 0.3, 30) } }))  -- remote older
    local cb = Adapter.make_progress_sync_callback({ canonical_path = lf })
    h.assert_true(cb(lf, cf, inf), "floor case returns true")
    local m = JsonStore.read(lf)
    h.assert_equal(m.entries.devX.revision, 9,
        "ancestor floor preserved (3-way), would be lost by naive 2-way")
end


-- ----------------------------------------------------------------------------
-- 14. FRESH-DEVICE / WIPE coverage (PROJECT_PLAN.md 18.9.6 / 18.12.9).
--     Codifies that 3-way already does the right thing on the cloud progress
--     path -> no blocking interlock added to the callback.
-- ----------------------------------------------------------------------------

-- 14a. Fresh device: empty local, MISSING ancestor, full cloud income ->
--      adopt remote, lose nothing.
do
    local lf, cf, inf = paths()
    write_json(lf, state({}))                          -- empty local (fresh)
    -- cf absent (never synced)
    write_json(inf, state({ entries = { cloudDev = entry("cloudDev", 4, 400, 0.6, 60) } }))
    local cb = Adapter.make_progress_sync_callback({ canonical_path = lf })
    h.assert_true(cb(lf, cf, inf), "fresh device progress pull returns true")
    local m = JsonStore.read(lf)
    h.assert_true(m.entries.cloudDev ~= nil, "fresh device: cloud progress adopted, not wiped")
end

-- 14b. First device pushing TO fresh cloud: full local, MISSING ancestor,
--      EMPTY income -> keep our progress.
do
    local lf, cf, inf = paths()
    write_json(lf, state({ entries = { mine = entry("mine", 2, 200, 0.5, 50) } }))
    -- cf absent; income empty (fresh cloud)
    write_json(inf, state({}))
    local cb = Adapter.make_progress_sync_callback({ canonical_path = lf })
    h.assert_true(cb(lf, cf, inf), "first progress push to fresh cloud returns true")
    local m = JsonStore.read(lf)
    h.assert_true(m.entries.mine ~= nil, "first push: our progress KEPT (no data loss)")
    h.assert_equal(m.entries.mine.revision, 2, "first push: our revision intact")
end
