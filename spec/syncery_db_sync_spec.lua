-- =============================================================================
-- spec/syncery_db_sync_spec.lua
-- =============================================================================
--
-- Tests for syncery_db_sync.lua -- the trigger-only gating/throttling for the
-- Reading Statistics + Vocabulary Builder plugins.
--
-- Covers:
--   * decide() -- the PURE gate, every reason code, and gate precedence (the
--     most-fundamental off-state is the reported one)
--   * run() -- master-OFF inertness, dispatch on fire, per-DB independence
--     (sub-toggles), cloudstorage/server gates, module absence, and pcall
--     safety when a plugin's sync raises
--
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_db_sync_spec_" .. tostring(os.time()))

local DbSync = require("syncery_db_sync")


-- ----------------------------------------------------------------------------
-- Fakes.
-- ----------------------------------------------------------------------------


-- Syncery Settings stub.  Any field omitted from `vals` takes its real default
-- (master OFF, sub-toggles ON) so each test states only what it varies.
local function settings_with(vals)
    vals = vals or {}
    local function pick(v, dflt) if v == nil then return dflt else return v end end
    return {
        get_db_sync_enabled  = function() return pick(vals.master,   false) end,
        get_db_sync_stats    = function() return pick(vals.stats,    true)  end,
        get_db_sync_vocab    = function() return pick(vals.vocab,    true)  end,
    }
end


-- ReaderUI stub.  The plugins are present as bare instances (so mod_present is
-- true); run() no longer calls their handlers -- it dispatches an Event, which
-- ui.send_event captures and maps to the same per-DB counters the assertions
-- read (calls.stats / calls.vocab).  opts: cloud=false drops cloudstorage;
-- stats=false / vocab=false drop that module; stats_throws makes the stats
-- dispatch raise (to prove run() pcall-absorbs it).
local function ui_with(opts)
    opts = opts or {}
    local calls = {}
    local ui = { calls = calls }
    if opts.cloud ~= false then ui.cloudstorage = {} end
    if opts.stats ~= false then ui.statistics = {} end
    if opts.vocab ~= false then
        -- Registered under the DIRECTORY name "vocabbuilder" (not the
        -- settings_key "vocabulary_builder") -- a genuine key guard: if run()
        -- looked the module up under the wrong key it would get nil ->
        -- module_absent and the dispatch assertions below would fail.
        ui.vocabbuilder = {}
    end
    ui.send_event = function(name)
        if name == "SyncBookStats" then
            if opts.stats_throws then error("boom") end
            calls.stats = (calls.stats or 0) + 1
        elseif name == "SyncVocabBuilder" then
            calls.vocab = (calls.vocab or 0) + 1
        end
    end
    return ui
end


-- G_reader_settings stub: server presence per plugin.
local function gset_with(stats_server, vocab_server)
    local store = {
        statistics         = stats_server and { sync_server = stats_server } or {},
        vocabulary_builder = vocab_server and { server = vocab_server }      or {},
    }
    return { readSetting = function(self, k) return store[k] end }
end


local function base_opts()
    return {
        master = true, sub = true, mod_present = true, cloud_present = true,
        has_server = true,
    }
end


-- Wrap DbSync.run, injecting the stub ui's Event recorder as send_event, so the
-- call sites read like production deps without each repeating it.  (Production
-- wires send_event to UIManager:sendEvent(Event:new(name)).)
local function run_db_deps(deps)
    deps.send_event = deps.ui and deps.ui.send_event
    return DbSync.run(deps)
end


-- ----------------------------------------------------------------------------
-- decide() -- pure gate, every reason code.
-- ----------------------------------------------------------------------------


do
    local all = DbSync.decide(base_opts())
    h.assert_true(all.fire, "all gates pass -> fire")
    h.assert_equal(all.reason, "fire", "all gates pass -> reason 'fire'")

    local o = base_opts(); o.master = false
    h.assert_false(DbSync.decide(o).fire, "master off -> no fire")
    h.assert_equal(DbSync.decide(o).reason, "master_off", "master off -> reason")

    o = base_opts(); o.sub = false
    h.assert_equal(DbSync.decide(o).reason, "subtoggle_off", "sub-toggle off -> reason")

    o = base_opts(); o.mod_present = false
    h.assert_equal(DbSync.decide(o).reason, "module_absent", "module absent -> reason")

    o = base_opts(); o.cloud_present = false
    h.assert_equal(DbSync.decide(o).reason, "cloudstorage_absent", "cloudstorage absent -> reason")

    o = base_opts(); o.has_server = false
    h.assert_equal(DbSync.decide(o).reason, "no_server", "no server -> reason")
end


-- ----------------------------------------------------------------------------
-- decide() -- gate precedence.
-- ----------------------------------------------------------------------------


do
    -- precedence: master off AND no server -> master_off wins (don't nag about
    -- a server when the feature is off).
    local o = base_opts(); o.master = false; o.has_server = false
    h.assert_equal(DbSync.decide(o).reason, "master_off",
        "master off takes precedence over no_server")
end


-- ----------------------------------------------------------------------------
-- run() -- master OFF is fully inert (the invariant: behaviour == pre-feature).
-- ----------------------------------------------------------------------------


do
    local ui = ui_with({})
    local report = run_db_deps({
        ui = ui, settings = settings_with({ master = false }),
        gset = gset_with("wd", "wd"),
    })
    h.assert_nil(ui.calls.stats, "master OFF -> statistics sync NOT called")
    h.assert_nil(ui.calls.vocab, "master OFF -> vocab sync NOT called")
    h.assert_false(report.statistics.fired,         "master OFF -> statistics not fired")
    h.assert_equal(report.statistics.reason, "master_off", "master OFF -> reason")
    h.assert_equal(report.vocabulary_builder.reason, "master_off", "master OFF -> vocab reason")
end


-- ----------------------------------------------------------------------------
-- run() -- all gates pass: both dispatched, both reported fired.
-- ----------------------------------------------------------------------------


do
    local ui = ui_with({})
    local report = run_db_deps({
        ui = ui, settings = settings_with({ master = true }),
        gset = gset_with("wd", "wd"),
    })
    h.assert_equal(ui.calls.stats, 1, "all gates pass -> statistics sync dispatched once")
    h.assert_equal(ui.calls.vocab, 1, "all gates pass -> vocab sync dispatched once")
    h.assert_true(report.statistics.fired,         "all gates pass -> statistics fired")
    h.assert_true(report.vocabulary_builder.fired, "all gates pass -> vocab fired")
end


-- ----------------------------------------------------------------------------
-- run() -- per-DB independence: stats sub-toggle off, vocab on.
-- ----------------------------------------------------------------------------


do
    local ui = ui_with({})
    local report = run_db_deps({
        ui = ui, settings = settings_with({ master = true, stats = false, vocab = true }),
        gset = gset_with("wd", "wd"),
    })
    h.assert_nil(ui.calls.stats,   "stats sub-toggle off -> stats NOT dispatched")
    h.assert_equal(ui.calls.vocab, 1, "vocab sub-toggle on -> vocab dispatched")
    h.assert_equal(report.statistics.reason, "subtoggle_off", "stats off -> reason")
    h.assert_true(report.vocabulary_builder.fired, "vocab -> fired")
end


-- ----------------------------------------------------------------------------
-- run() -- cloudstorage absent and no-server gates.
-- ----------------------------------------------------------------------------


do
    local ui = ui_with({ cloud = false })
    local report = run_db_deps({
        ui = ui, settings = settings_with({ master = true }),
        gset = gset_with("wd", "wd"),
    })
    h.assert_nil(ui.calls.stats, "cloudstorage absent -> not dispatched")
    h.assert_equal(report.statistics.reason, "cloudstorage_absent", "cloudstorage absent -> reason")

    local ui2 = ui_with({})
    local report2 = run_db_deps({
        ui = ui2, settings = settings_with({ master = true }),
        gset = gset_with(nil, "wd"),        -- stats has no server
    })
    h.assert_nil(ui2.calls.stats,   "stats no server -> not dispatched")
    h.assert_equal(ui2.calls.vocab, 1, "vocab has server -> dispatched")
    h.assert_equal(report2.statistics.reason, "no_server", "stats no server -> reason")
end


-- ----------------------------------------------------------------------------
-- run() -- module absent (plugin disabled) and pcall safety (sync raises).
-- ----------------------------------------------------------------------------


do
    local ui = ui_with({ stats = false })       -- ui.statistics nil
    local report = run_db_deps({
        ui = ui, settings = settings_with({ master = true }),
        gset = gset_with("wd", "wd"),
    })
    h.assert_equal(report.statistics.reason, "module_absent", "stats module absent -> reason")
    h.assert_equal(ui.calls.vocab, 1, "vocab still dispatched when stats module absent")

    -- A raising sync must not propagate out of run().
    local ui2 = ui_with({ stats_throws = true })
    local ok = pcall(function()
        return run_db_deps({
            ui = ui2, settings = settings_with({ master = true }),
            gset = gset_with("wd", "wd"),
        })
    end)
    h.assert_true(ok, "a raising plugin sync is absorbed -- run() does not propagate")
end


-- ----------------------------------------------------------------------------
-- actionable_summary(report) -- the ONE surfaceable issue, or nil.
-- ----------------------------------------------------------------------------
do
    local fired = { fired = true, reason = "fire" }
    local function R(reason) return { fired = false, reason = reason } end

    h.assert_nil(DbSync.actionable_summary(nil), "nil report -> nil")
    h.assert_nil(DbSync.actionable_summary("x"), "non-table report -> nil")

    h.assert_nil(DbSync.actionable_summary({ statistics = fired, vocabulary_builder = fired }),
        "all fired -> nil")

    h.assert_nil(DbSync.actionable_summary({
        statistics = R("master_off"), vocabulary_builder = R("subtoggle_off") }),
        "master_off / subtoggle_off -> nil (not actionable)")
    h.assert_nil(DbSync.actionable_summary({
        statistics = R("module_absent"), vocabulary_builder = R("module_absent") }),
        "module_absent -> nil (not user-actionable)")

    local s1 = DbSync.actionable_summary({ statistics = R("no_server"), vocabulary_builder = fired })
    h.assert_equal(s1.kind, "no_server",     "single no_server -> no_server kind")
    h.assert_equal(#s1.dbs, 1,               "one DB listed")
    h.assert_equal(s1.dbs[1], "statistics",  "the right DB id")

    local s2 = DbSync.actionable_summary({
        statistics = R("no_server"), vocabulary_builder = R("no_server") })
    h.assert_equal(#s2.dbs, 2,                       "both DBs listed")
    h.assert_equal(s2.dbs[1], "statistics",          "DBS order: statistics first")
    h.assert_equal(s2.dbs[2], "vocabulary_builder",  "DBS order: vocabulary second")

    local s3 = DbSync.actionable_summary({
        statistics = R("cloudstorage_absent"), vocabulary_builder = R("no_server") })
    h.assert_equal(s3.kind, "cloudstorage_absent",  "cloudstorage_absent dominates")
    h.assert_true(s3.dbs == nil,                    "cloudstorage_absent result carries no dbs list")
end


print("syncery_db_sync_spec: all assertions passed")
