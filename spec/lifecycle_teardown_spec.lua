-- =============================================================================
-- spec/lifecycle_teardown_spec.lua
-- =============================================================================
--
-- Tests for syncery_lifecycle/teardown.lua.  The teardown is a pure
-- sequencer — it calls back into the plugin and into UIManager.  We
-- record every such call against a fake plugin recorder and assert
-- on the call order, gating, and side effects.
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_lifecycle_teardown_spec_" .. tostring(os.time()))

local Teardown = require("syncery_lifecycle/teardown")


-- ----------------------------------------------------------------------------
-- Fake plugin recorder.  Tracks every method call so tests can assert
-- "Step 1 happened with this state", "Step 4 didn't fire because
-- use_syncthing was false", etc.  Each tracked method appends a call
-- record to self._calls; tests inspect that list.
--
-- opts let a test pre-seed the toggles + back-sync state.
-- ----------------------------------------------------------------------------


local function make_fake_plugin(opts)
    opts = opts or {}
    local plugin = {
        -- Tracked toggles + state (test-controlled defaults).
        destroyed                = opts.destroyed or false,
        use_cloud                = opts.use_cloud ~= false,
        use_syncthing            = opts.use_syncthing ~= false,
        _active_sync_box         = opts.active_sync_box,  -- nil unless set
        _transport               = opts.transport,
        _file_type_synced        = opts.file_type_synced ~= false,
        -- Close-push opt-in (default OFF).
        wake_wifi_for_sync       = opts.wake_wifi_for_sync,
        -- Transport readiness (B): default configured so existing tests, which
        -- only flip use_cloud/use_syncthing, keep exercising the seam.
        _cloud_configured        = opts.cloud_configured ~= false,
        _syncthing_configured    = opts.syncthing_configured ~= false,

        -- The state returned by getCurrentState (set to nil to test
        -- the "no document open" path).
        _state                   = opts.state ~= nil and opts.state
                                    or { file = "/books/test.epub", page = 7 },

        -- Call recording.
        _calls = {},
    }
    plugin.timers_cancel_all_count = 0
    local function record(method, ...)
        table.insert(plugin._calls, { method = method, args = {...} })
    end

    function plugin:getCurrentState() return self._state end
    function plugin:_writeSave(state, now, silent, trigger)
        record("_writeSave", state, now, silent, trigger)
    end
    function plugin:_syncBookViaOrchestrator(state)
        record("_syncBookViaOrchestrator", state)
    end
    function plugin:_doCloudUpload(state)   record("_doCloudUpload",   state) end
    function plugin:_doTriggerScan(state, scan_opts)
        record("_doTriggerScan", state, scan_opts)
    end
    function plugin:_isFileTypeSynced(file)
        record("_isFileTypeSynced", file)
        return self._file_type_synced
    end
    -- Close-push seam.  opts.go_online: "blocked" => link not raised, cb NOT run,
    -- false; "throw" => raises before cb; "throw_after" => runs cb then raises;
    -- otherwise runs cb and returns true.
    function plugin:_goOnlineToRun(cb)
        record("_goOnlineToRun")
        if opts.go_online == "throw" then error("goOnlineToRun boom") end
        if opts.go_online == "blocked" then return false end
        cb()
        if opts.go_online == "throw_after" then error("goOnlineToRun boom after cb") end
        return true
    end
    -- B: close-push gates on configured (not just enabled) transports.
    function plugin:_hasConfiguredTransportForClosePush()
        if self.use_cloud and self._cloud_configured then return true end
        if self.use_syncthing and self._syncthing_configured then return true end
        return false
    end
    -- F: link state captured before goOnlineToRun.  Default OFFLINE — close-push
    -- is the "I was offline, raise the link" case, where the E reset applies.
    function plugin:_isNetworkOnline() return opts.network_online == true end

    -- Mock the lifecycle.timers handle that teardown calls cancel_all on.
    plugin._lifecycle = {
        timers = {
            cancel_all = function() plugin.timers_cancel_all_count =
                plugin.timers_cancel_all_count + 1 end,
        },
    }

    -- Reachability verdict that the close-time push (Step 3) warms
    -- synchronously before _doCloudUpload, so the gate answers inline.
    plugin._cloud_reachability = {
        warm_blocking = function() record("warm_blocking") end,
        -- E: the online close-push path resets the verdict (as the delayed
        -- NetworkConnected would) before the flush.
        on_network_connected = function() record("on_network_connected") end,
    }

    -- Convenience predicate for the assertions.
    function plugin:called(method)
        for _, c in ipairs(self._calls) do
            if c.method == method then return c end
        end
        return nil
    end

    -- Index of the first call to `method` (for ordering assertions).
    function plugin:called_index(method)
        for i, c in ipairs(self._calls) do
            if c.method == method then return i end
        end
        return nil
    end

    -- How many times `method` was recorded (for "ran exactly once" checks).
    function plugin:count(method)
        local n = 0
        for _, c in ipairs(self._calls) do
            if c.method == method then n = n + 1 end
        end
        return n
    end

    return plugin
end


--- Build a fake UIManager with .close + .nextTick recorders.
--- nextTick fires the callback immediately for predictability —
--- in production it fires after the current event loop tick, but
--- for these tests we want to observe its effects synchronously.
local function make_fake_uimgr()
    local closed = {}
    local next_ticks_fired = 0
    return {
        close = function(self, box) table.insert(closed, box) end,
        nextTick = function(self, fn)
            next_ticks_fired = next_ticks_fired + 1
            fn()
        end,
        closed_boxes      = function() return closed end,
        next_ticks_fired  = function() return next_ticks_fired end,
    }
end


local function fixed_now() return 42 end


-- ----------------------------------------------------------------------------
-- Happy path: state present, all transports enabled.  Steps 1–4 all
-- happen; step 5 only cancels timers (no destroying).
-- ----------------------------------------------------------------------------


do
    local plugin = make_fake_plugin{}
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, {})

    h.assert_true(plugin:called("_writeSave")             ~= nil, "Step 1: _writeSave")
    h.assert_true(plugin:called("_syncBookViaOrchestrator") ~= nil, "Step 2: orchestrator back-sync")
    h.assert_true(plugin:called("_doCloudUpload")         ~= nil, "Step 3: cloud upload")
    h.assert_true(plugin:called("warm_blocking")          ~= nil, "Step 3: reachability warmed (close-time)")
    h.assert_true(plugin:called_index("warm_blocking") < plugin:called_index("_doCloudUpload"),
        "Step 3: warm_blocking runs BEFORE _doCloudUpload (so the gate answers inline)")
    h.assert_equal(ui.next_ticks_fired(),              1,         "Step 4: nextTick scheduled")
    h.assert_true(plugin:called("_doTriggerScan")         ~= nil, "Step 4: scan triggered inside nextTick")
    h.assert_equal(plugin.timers_cancel_all_count,     1,         "Step 5: cancel_all called")
    h.assert_false(plugin.destroyed,                              "destroyed not set (opts.destroying false)")
end


-- ----------------------------------------------------------------------------
-- _writeSave receives state + util_now() result + silent=true.
-- ----------------------------------------------------------------------------


do
    local plugin = make_fake_plugin{}
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, {})

    local call = plugin:called("_writeSave")
    h.assert_true(call ~= nil, "_writeSave was called")
    h.assert_equal(call.args[1], plugin._state, "first arg: state")
    h.assert_equal(call.args[2], 42,            "second arg: util_now() result")
    h.assert_true (call.args[3],                "third arg: silent=true")
    h.assert_equal(call.args[4], "suspend",     "fourth arg: suspend trigger (non-destroying flush)")
end


-- ----------------------------------------------------------------------------
-- _writeSave is labelled with the close trigger on a DESTROYING flush, so
-- the final-position push reads "merged via close" in the sync journal.
-- ----------------------------------------------------------------------------


do
    local plugin = make_fake_plugin{}
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, { destroying = true })

    local call = plugin:called("_writeSave")
    h.assert_true(call ~= nil, "_writeSave was called on a destroying flush")
    h.assert_equal(call.args[4], "close", "fourth arg: close trigger (destroying flush)")
end


-- ----------------------------------------------------------------------------
-- Step 2 is the orchestrator back-sync — a single unconditional call.
-- Phase 9 retired the legacy syncBookmarks/syncAnnotations pair and the
-- `_back_sync_completed` gate; the orchestrator owns its own completion
-- accounting and its wipe failsafe protects the unsynced-device case.
-- ----------------------------------------------------------------------------


do
    local plugin = make_fake_plugin{}
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, {})

    local call = plugin:called("_syncBookViaOrchestrator")
    h.assert_true(call ~= nil,             "orchestrator back-sync ran")
    h.assert_equal(call.args[1], plugin._state, "orchestrator got the current state")
end


-- ----------------------------------------------------------------------------
-- use_cloud = false → no cloud upload.
-- ----------------------------------------------------------------------------


do
    local plugin = make_fake_plugin{ use_cloud = false }
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, {})

    h.assert_nil(plugin:called("_doCloudUpload"),
        "_doCloudUpload NOT called when use_cloud=false")
end


-- ----------------------------------------------------------------------------
-- use_syncthing = false → nextTick still fires but the inner gate
-- skips both _isFileTypeSynced and _doTriggerScan.  Actually the
-- code orders the gate as "isFileTypeSynced then use_syncthing"; we
-- assert that no scan happens regardless of which branch the gate
-- short-circuits on.
-- ----------------------------------------------------------------------------


do
    local plugin = make_fake_plugin{ use_syncthing = false }
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, {})

    h.assert_nil(plugin:called("_doTriggerScan"),
        "_doTriggerScan NOT called when use_syncthing=false")
    -- nextTick still scheduled — the gate is inside the deferred
    -- callback, not at the schedule site.
    h.assert_equal(ui.next_ticks_fired(), 1,
        "nextTick is scheduled unconditionally; gate is inside")
end


-- ----------------------------------------------------------------------------
-- file type NOT in sync allowlist → no scan even with use_syncthing.
-- ----------------------------------------------------------------------------


do
    local plugin = make_fake_plugin{ file_type_synced = false }
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, {})

    h.assert_true(plugin:called("_isFileTypeSynced") ~= nil,
        "extension check happened")
    h.assert_nil(plugin:called("_doTriggerScan"),
        "_doTriggerScan SKIPPED for non-synced file type")
end


-- ----------------------------------------------------------------------------
-- No document open (getCurrentState returns nil) → none of Steps 1–4
-- run; only Step 5's cancel_all.
-- ----------------------------------------------------------------------------


do
    local plugin = make_fake_plugin{ state = false }  -- false → set _state nil below
    plugin._state = nil
    local ui = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, {})

    h.assert_nil(plugin:called("_writeSave"),               "no Step 1")
    h.assert_nil(plugin:called("_syncBookViaOrchestrator"), "no Step 2")
    h.assert_nil(plugin:called("_doCloudUpload"),   "no Step 3")
    h.assert_equal(ui.next_ticks_fired(), 0,        "no Step 4")
    h.assert_equal(plugin.timers_cancel_all_count, 1, "Step 5 still happens")
end


-- ----------------------------------------------------------------------------
-- opts.destroying = true → plugin.destroyed set; transport:shutdown
-- called.  Idempotent error in shutdown is swallowed (pcall).
-- ----------------------------------------------------------------------------


do
    local shutdown_count = 0
    local transport = {
        shutdown = function(self) shutdown_count = shutdown_count + 1 end,
    }
    local plugin = make_fake_plugin{ transport = transport }
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, { destroying = true })

    h.assert_true(plugin.destroyed,           "destroyed flag set")
    h.assert_equal(shutdown_count, 1,         "transport:shutdown called once")
end


-- ----------------------------------------------------------------------------
-- A throwing transport:shutdown doesn't propagate (we use pcall to
-- keep teardown finishing).
-- ----------------------------------------------------------------------------


do
    local transport = { shutdown = function() error("transport boom") end }
    local plugin = make_fake_plugin{ transport = transport }
    local ui     = make_fake_uimgr()

    local ok = pcall(Teardown.flush, plugin, ui, fixed_now, nil,
                     { destroying = true })

    h.assert_true(ok, "flush completed even though transport:shutdown raised")
    h.assert_true(plugin.destroyed,
        "destroyed still set despite shutdown raise")
    h.assert_equal(plugin.timers_cancel_all_count, 1,
        "cancel_all still happens despite shutdown raise")
end


-- ----------------------------------------------------------------------------
-- destroying = false (default) → destroyed NOT set, transport NOT
-- shut down.  Suspend semantics: we want to come back from this.
-- ----------------------------------------------------------------------------


do
    local shutdown_count = 0
    local transport = { shutdown = function() shutdown_count = shutdown_count + 1 end }
    local plugin = make_fake_plugin{ transport = transport }
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, {})

    h.assert_false(plugin.destroyed,    "destroyed NOT set on suspend-style flush")
    h.assert_equal(shutdown_count, 0,   "transport:shutdown NOT called")
end


-- ----------------------------------------------------------------------------
-- _active_sync_box is cleared (Step 0) and NOTHING is closed.
-- Phase 14 made it a boolean re-entry flag (the jump toast is owned by the
-- notification coordinator, which auto-dismisses on its own lifecycle), so
-- teardown no longer calls ui_manager:close on it — it just clears the flag.
-- (Calling close() on the boolean used to raise pre-flush — see the
-- pre-flush regression tests at the end of this file.)
-- ----------------------------------------------------------------------------


do
    local plugin = make_fake_plugin{ active_sync_box = true }
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, {})

    h.assert_equal(#ui.closed_boxes(), 0,        "nothing closed (toast owned by coordinator)")
    h.assert_nil(plugin._active_sync_box,        "_active_sync_box cleared (boolean flag)")
end


-- ----------------------------------------------------------------------------
-- A deferred scan that raises is caught + logged, not propagated.
-- ----------------------------------------------------------------------------


do
    local plugin = make_fake_plugin{}
    -- Replace _doTriggerScan with a thrower.
    plugin._doTriggerScan = function() error("scan boom") end
    local ui = make_fake_uimgr()

    local warn_messages = {}
    local logger = { warn = function(msg) table.insert(warn_messages, msg) end }

    local ok = pcall(Teardown.flush, plugin, ui, fixed_now, logger, {})
    h.assert_true(ok, "deferred scan error doesn't escape teardown")
    h.assert_equal(#warn_messages, 1, "logger.warn called once")
    h.assert_true(warn_messages[1]:find("deferred scan") ~= nil,
        "warn message identifies the deferred scan as the failure point")
end


-- ----------------------------------------------------------------------------
-- No-ui-manager call (test contexts that don't pass one) shouldn't
-- crash.  The active-box close and nextTick steps just no-op.
-- ----------------------------------------------------------------------------


do
    local plugin = make_fake_plugin{ active_sync_box = { tag = "x" } }
    -- Pass empty table for ui_manager — close/nextTick fields absent.
    local ok = pcall(Teardown.flush, plugin, {}, fixed_now, nil, {})

    h.assert_true(ok, "flush survives a no-method ui_manager")
    h.assert_true(plugin:called("_writeSave") ~= nil,
        "Step 1 still happens")
    h.assert_nil(plugin:called("_doTriggerScan"),
        "Step 4 skipped when nextTick is absent")
end


-- ----------------------------------------------------------------------------
-- A raise in a FLUSH STEP (Steps 1-4) is caught + logged and does NOT
-- strand the Step-5 cleanup (cancel_all + transport shutdown).  This is
-- the resilience the outer flush pcall guarantees — the same discipline
-- as the transport:shutdown pcall above, now extended to the flush body.
-- ----------------------------------------------------------------------------


do
    local shutdown_count = 0
    local transport = { shutdown = function() shutdown_count = shutdown_count + 1 end }
    local plugin = make_fake_plugin{ transport = transport }
    -- Make Step 2 (the annotation back-sync) raise mid-flush.
    plugin._syncBookViaOrchestrator = function() error("orchestrator boom") end
    local ui = make_fake_uimgr()

    local warn_messages = {}
    local logger = { warn = function(msg) table.insert(warn_messages, msg) end }

    local ok = pcall(Teardown.flush, plugin, ui, fixed_now, logger,
                     { destroying = true })

    h.assert_true(ok, "a raising flush step doesn't escape teardown")
    h.assert_equal(plugin.timers_cancel_all_count, 1,
        "Step 5 cancel_all still runs despite the flush-step raise")
    h.assert_equal(shutdown_count, 1,
        "Step 5 transport:shutdown still runs despite the flush-step raise")
    h.assert_true(plugin.destroyed,
        "destroyed still set despite the flush-step raise")
    h.assert_equal(#warn_messages, 1,
        "logger.warn called once for the flush error (Step 4 never reached)")
    h.assert_true(warn_messages[1]:find("teardown flush") ~= nil,
        "warn message identifies the flush as the failure point")
end


-- ----------------------------------------------------------------------------
-- PRE-FLUSH input raise #1 — the `_active_sync_box` regression.
-- Phase 14 made `_active_sync_box` a BOOLEAN flag (toast owned by the
-- notification coordinator), but teardown used to call
-- `ui_manager:close(_active_sync_box)` — i.e. close(true) — which RAISES
-- in real KOReader (UIManager:close indexes widget.name immediately, and
-- indexing a boolean errors). That raise sat BEFORE the flush pcall, so it
-- skipped the ENTIRE teardown including Step 5 (transport:shutdown +
-- cancel_all) — a data-loss path: progress unsaved, _shutdown unset.
--
-- The fix moved the pcall boundary up to cover Step 0 (clearing the flag)
-- and getCurrentState. This test pins the INVARIANT, not just "no throw":
-- Step 5 MUST still be reached after a pre-flush raise. To prove it would
-- fail without the fix, the fake `close` raises on any non-table arg, the
-- same way real UIManager:close does on a boolean.
-- ----------------------------------------------------------------------------


do
    local shutdown_count = 0
    local transport = { shutdown = function() shutdown_count = shutdown_count + 1 end }
    local plugin = make_fake_plugin{ transport = transport, active_sync_box = true }

    -- A UIManager whose close() raises on a non-widget arg — mirrors real
    -- KOReader (close(true) -> index a boolean -> error). If teardown ever
    -- calls close() on the boolean flag again, this raises pre-flush.
    local ui = make_fake_uimgr()
    ui.close = function(_, box)
        if type(box) ~= "table" then error("attempt to index a boolean value") end
    end

    local warn_messages = {}
    local logger = { warn = function(msg) table.insert(warn_messages, msg) end }

    local ok = pcall(Teardown.flush, plugin, ui, fixed_now, logger,
                     { destroying = true })

    -- The point of the fix: a pre-flush raise must NOT escape teardown...
    h.assert_true(ok, "pre-flush raise (_active_sync_box) doesn't escape teardown")
    -- ...and CRUCIALLY Step 5 is still reached (this is the real invariant;
    -- the data-loss bug was "Step 5 skipped", not "an error was thrown").
    h.assert_equal(shutdown_count, 1,
        "Step 5 transport:shutdown reached despite pre-flush raise")
    h.assert_equal(plugin.timers_cancel_all_count, 1,
        "Step 5 cancel_all reached despite pre-flush raise")
    h.assert_true(plugin.destroyed,
        "destroyed still set despite pre-flush raise")
    -- Step 0 cleared the flag (the fix replaced close-as-widget with a
    -- plain boolean clear).
    h.assert_nil(plugin._active_sync_box,
        "_active_sync_box cleared (boolean flag, not widget-closed)")
end


-- ----------------------------------------------------------------------------
-- PRE-FLUSH input raise #2 — getCurrentState (getProps) on a half-torn-down
-- document. getCurrentState is called pre-flush; if KOReader's
-- doc:getProps()/ui.rolling access raises during teardown, that raise also
-- sits before the flush pcall (same CLASS as #1, second real instance).
-- The moved boundary covers getCurrentState too: ok=false -> state=nil ->
-- Steps 1-4 skipped ("no state -> no flush"), Step 5 still reached.
-- ----------------------------------------------------------------------------


do
    local shutdown_count = 0
    local transport = { shutdown = function() shutdown_count = shutdown_count + 1 end }
    local plugin = make_fake_plugin{ transport = transport }
    -- getCurrentState raises (stand-in for a getProps/rolling access that
    -- throws on a document being torn down).
    plugin.getCurrentState = function() error("getProps boom") end
    local ui = make_fake_uimgr()

    local warn_messages = {}
    local logger = { warn = function(msg) table.insert(warn_messages, msg) end }

    local ok = pcall(Teardown.flush, plugin, ui, fixed_now, logger,
                     { destroying = true })

    h.assert_true(ok, "pre-flush raise (getCurrentState) doesn't escape teardown")
    -- Steps 1-4 must be SKIPPED (no usable state), not attempted with nil.
    h.assert_nil(plugin:called("_writeSave"),
        "Step 1 skipped when getCurrentState raised (no state -> no flush)")
    h.assert_nil(plugin:called("_syncBookViaOrchestrator"),
        "Step 2 skipped when getCurrentState raised")
    -- The real invariant: Step 5 still reached.
    h.assert_equal(shutdown_count, 1,
        "Step 5 transport:shutdown reached despite getCurrentState raise")
    h.assert_equal(plugin.timers_cancel_all_count, 1,
        "Step 5 cancel_all reached despite getCurrentState raise")
    h.assert_true(plugin.destroyed,
        "destroyed still set despite getCurrentState raise")
    h.assert_true(#warn_messages == 1 and warn_messages[1]:find("pre%-flush") ~= nil,
        "warn message identifies the pre-flush input as the failure point")
end


-- ----------------------------------------------------------------------------
-- G-wiring: a DESTROYING flush stashes the per-device delivery annotation list
-- (+ the device's adapt_highlight_style) into plugin._pending_anns, so the later
-- Syncery:onSaveSettings can deliver it to doc_settings' base "annotations"
-- key.  A non-destroying flush (suspend / autosave) must NOT stash.  Nil-safe
-- when the orchestrator returns no delivery_annotations (wipe-failsafe / early /
-- error).  See ANNOTATION_DELIVERY_DESIGN.md S2 / G-wiring and
-- PER_TYPE_FILTER_DESIGN §13-15 (delivery vs shared map).
-- ----------------------------------------------------------------------------


-- destroying = true + a successful sync -> stash filled.
do
    local plugin = make_fake_plugin{}
    plugin.adapt_highlight_style = true
    local merged = { annotations = { { text = "a", page = "/p[1]" },
                                     { text = "b", page = "/p[2]" } } }
    function plugin:_syncBookViaOrchestrator(_state)
        -- delivery_annotations is the per-device map; equals the shared list
        -- here (no per-type filtering in this fixture).
        return true, { merged_state = merged, delivery_annotations = merged.annotations }
    end
    local ui = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, { destroying = true })

    h.assert_true(type(plugin._pending_anns) == "table",
        "destroying flush stashes _pending_anns")
    h.assert_true(rawequal(plugin._pending_anns.annotations, merged.annotations),
        "stash carries the per-device delivery annotation list (same table)")
    h.assert_true(plugin._pending_anns.adapt_highlight_style == true,
        "stash carries the device's adapt_highlight_style flag")
end


-- Bug #2 guard (PER_TYPE_FILTER_DESIGN §11): when the per-device delivery map
-- DIFFERS from the shared merged map (per-type filtering active), the stash must
-- carry DELIVERY, never the shared merged_state.annotations -- otherwise a
-- disabled type's foreign entries would be written into this device's sidecar.
do
    local plugin = make_fake_plugin{}
    plugin.adapt_highlight_style = false
    local shared_map   = { ["k_shared"] = { text = "shared+foreign bookmark" } }
    local delivery_map = { ["k_local"]  = { text = "this device only" } }
    function plugin:_syncBookViaOrchestrator(_state)
        return true, {
            merged_state         = { annotations = shared_map },
            delivery_annotations = delivery_map,
        }
    end
    local ui = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, { destroying = true })

    h.assert_true(rawequal(plugin._pending_anns.annotations, delivery_map),
        "stash carries the DELIVERY map (per-device view)")
    h.assert_true(not rawequal(plugin._pending_anns.annotations, shared_map),
        "stash does NOT carry the shared merged map")
end


-- destroying = false (suspend / autosave) -> NO stash.
do
    local plugin = make_fake_plugin{}
    plugin.adapt_highlight_style = true
    function plugin:_syncBookViaOrchestrator(_state)
        return true, { merged_state = { annotations = { { text = "x" } } } }
    end
    local ui = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, {})   -- no destroying

    h.assert_nil(plugin._pending_anns,
        "non-destroying flush does NOT stash (suspend/autosave inert)")
end


-- destroying = true but orchestrator returns no merged_state
-- (wipe-failsafe / early-exit / error: bare false) -> nil-safe, NO stash.
do
    local plugin = make_fake_plugin{}
    plugin.adapt_highlight_style = true
    function plugin:_syncBookViaOrchestrator(_state)
        return false
    end
    local ui = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, { destroying = true })

    h.assert_nil(plugin._pending_anns,
        "destroying flush is nil-safe when no merged_state is returned")
end


-- The terminal (destroying) Syncthing scan is FORCED and runs INLINE (before the
-- Step 5 shutdown), so an offline autosave's pending retry can't make Step 5 drop
-- the close-time scan.
do
    local plugin = make_fake_plugin{}
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, { destroying = true })

    local c = plugin:called("_doTriggerScan")
    h.assert_true(c ~= nil, "destroying flush triggered the scan")
    h.assert_true(c.args[2] ~= nil and c.args[2].force == true,
        "terminal scan forced (bypasses debounce/backoff)")
end


-- The deferred (non-destroying) scan keeps normal backoff — only the terminal
-- scan bypasses policy.
do
    local plugin = make_fake_plugin{}
    local ui     = make_fake_uimgr()   -- default nextTick fires synchronously

    Teardown.flush(plugin, ui, fixed_now, nil, {})   -- suspend/autosave

    local c = plugin:called("_doTriggerScan")
    h.assert_true(c ~= nil, "non-destroying scan ran")
    h.assert_true(c.args[2] == nil or c.args[2].force ~= true,
        "deferred scan NOT forced (keeps normal debounce/backoff)")
end
-- ----------------------------------------------------------------------------
-- Close-push (KOSync goOnlineToRun pattern).  Gated on wake_wifi_for_sync +
-- destroying + a configured transport; flush must run EXACTLY ONCE in all paths.
-- ----------------------------------------------------------------------------


-- Default OFF: _goOnlineToRun is never consulted; flush runs once as before.
do
    local plugin = make_fake_plugin{}   -- wake_wifi_for_sync nil
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, { destroying = true })

    h.assert_nil(plugin:called("_goOnlineToRun"),
        "wake off: close-push seam not used")
    h.assert_equal(plugin:count("_writeSave"), 1, "flush ran exactly once")
end


-- Opt-in + destroying + transport, link raised (returns true): route through
-- the seam, run the flush ONCE (not twice).
do
    local plugin = make_fake_plugin{ wake_wifi_for_sync = true }
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, { destroying = true })

    h.assert_true(plugin:called("_goOnlineToRun") ~= nil,
        "wake on: routed through goOnlineToRun")
    h.assert_equal(plugin:count("_goOnlineToRun"), 1, "seam consulted once")
    h.assert_equal(plugin:count("_writeSave"),     1, "flush ran exactly once (no double)")
    h.assert_true(plugin:called("_doCloudUpload") ~= nil, "cloud push happened")
end


-- Opt-in but link could NOT be raised (returns false): fall through and flush
-- anyway, exactly once (offline; the network steps self-skip in production).
do
    local plugin = make_fake_plugin{ wake_wifi_for_sync = true, go_online = "blocked" }
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, { destroying = true })

    h.assert_true(plugin:called("_goOnlineToRun") ~= nil, "seam was tried")
    h.assert_equal(plugin:count("_writeSave"), 1,
        "flush still ran exactly once via the fallback")
end


-- NON-destroying flush (suspend): close-push is gated off, seam not used.
do
    local plugin = make_fake_plugin{ wake_wifi_for_sync = true }
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, {})   -- no destroying

    h.assert_nil(plugin:called("_goOnlineToRun"),
        "suspend: close-push not applied (destroying only)")
    h.assert_equal(plugin:count("_writeSave"), 1, "flush ran once")
end


-- goOnlineToRun raising BEFORE running cb must not strand Step 5; flush still
-- runs once via the fallback.
do
    local plugin = make_fake_plugin{ wake_wifi_for_sync = true, go_online = "throw" }
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, { destroying = true })

    h.assert_equal(plugin:count("_writeSave"), 1, "flush ran once via fallback after the raise")
    h.assert_equal(plugin.timers_cancel_all_count, 1, "Step 5 cancel_all still ran")
    h.assert_true(plugin.destroyed, "Step 5 destroyed still set")
end


-- goOnlineToRun raising AFTER running cb must not double-flush, and Step 5 runs.
do
    local plugin = make_fake_plugin{ wake_wifi_for_sync = true, go_online = "throw_after" }
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, { destroying = true })

    h.assert_equal(plugin:count("_writeSave"), 1, "flush ran exactly once (idempotent)")
    h.assert_equal(plugin.timers_cancel_all_count, 1, "Step 5 cancel_all still ran")
end


-- Opt-in + destroying but NO transport configured: nothing to push, seam unused.
do
    local plugin = make_fake_plugin{ wake_wifi_for_sync = true,
                                     use_cloud = false, use_syncthing = false }
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, { destroying = true })

    h.assert_nil(plugin:called("_goOnlineToRun"),
        "no transport: close-push seam not used")
    h.assert_equal(plugin:count("_writeSave"), 1, "flush ran once")
end


-- B: opt-in + destroying + master toggle ON but transport NOT configured
-- (cloud enabled, no server set) → seam unused, no Wi-Fi wake with nothing to push.
do
    local plugin = make_fake_plugin{ wake_wifi_for_sync = true,
                                     use_syncthing = false,
                                     cloud_configured = false }
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, { destroying = true })

    h.assert_nil(plugin:called("_goOnlineToRun"),
        "unconfigured transport: close-push seam not used despite the toggle")
    h.assert_equal(plugin:count("_writeSave"), 1, "flush ran once (offline)")
end


-- A: a DESTROYING flush triggers the Syncthing scan INLINE, before transport
-- shutdown — never via nextTick, which would fire post-shutdown (_shutdown=true)
-- and be dropped.  Uses an ASYNC uimgr that only QUEUES nextTick callbacks.
do
    local order = {}
    local transport = { shutdown = function() table.insert(order, "shutdown") end }
    local plugin = make_fake_plugin{ transport = transport }
    plugin._doTriggerScan = function() table.insert(order, "scan") end

    local queued = {}
    local ui = make_fake_uimgr()
    ui.nextTick = function(_, fn) table.insert(queued, fn) end   -- async: just queue

    Teardown.flush(plugin, ui, fixed_now, nil, { destroying = true })

    h.assert_equal(#queued, 0, "destroying: scan NOT deferred to nextTick")
    h.assert_equal(order[1], "scan",     "scan ran inline...")
    h.assert_equal(order[2], "shutdown", "...before transport shutdown (not lost)")
end


-- A (counterpart): a NON-destroying flush still DEFERS the scan via nextTick
-- (no shutdown follows, and we must not block the event loop).
do
    local plugin = make_fake_plugin{}
    local queued = {}
    local ui = make_fake_uimgr()
    ui.nextTick = function(_, fn) table.insert(queued, fn) end

    Teardown.flush(plugin, ui, fixed_now, nil, {})   -- suspend/autosave

    h.assert_equal(#queued, 1, "non-destroying: scan deferred to nextTick")
    h.assert_nil(plugin:called("_doTriggerScan"),
        "scan has NOT run yet (still queued)")
    queued[1]()                                       -- drain the tick
    h.assert_true(plugin:called("_doTriggerScan") ~= nil, "scan runs when the tick drains")
end


-- D: a Suspend re-entering Teardown.flush DURING the blocking goOnlineToRun
-- (e.g. an Android focus switch) must NOT run a duplicate flush.
do
    local plugin = make_fake_plugin{ wake_wifi_for_sync = true }
    local ui     = make_fake_uimgr()
    plugin._goOnlineToRun = function(self, cb)
        -- The OS emits Suspend while we block; it routes back into teardown.
        Teardown.flush(self, ui, fixed_now, nil, {})   -- re-entrant suspend flush
        cb()                                           -- then the link comes up
        return true
    end

    Teardown.flush(plugin, ui, fixed_now, nil, { destroying = true })

    h.assert_equal(plugin:count("_writeSave"), 1,
        "re-entrant suspend during close-push did NOT cause a second flush")
end


-- E: on the online close-push path the stale reachability verdict is reset
-- (mirrors the delayed NetworkConnected) BEFORE the cloud push, so a verdict
-- set unreachable while offline doesn't make Step 3 skip the upload.
do
    local plugin = make_fake_plugin{ wake_wifi_for_sync = true }
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, { destroying = true })

    h.assert_true(plugin:called("on_network_connected") ~= nil,
        "reachability verdict reset on the online close-push path")
    h.assert_true(plugin:called_index("on_network_connected")
                  < plugin:called_index("_doCloudUpload"),
        "verdict reset happens BEFORE the cloud upload")
end


-- E (counterpart): on the OFFLINE fallback (link not raised) the verdict is NOT
-- reset — we're still offline, the network steps self-skip.
do
    local plugin = make_fake_plugin{ wake_wifi_for_sync = true, go_online = "blocked" }
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, { destroying = true })

    h.assert_nil(plugin:called("on_network_connected"),
        "offline fallback does NOT reset reachability")
end


-- F+J: when close-push runs while ALREADY online, goOnlineToRun is SKIPPED
-- (J: its online check can WAN/DNS-probe and stall) and we flush directly; the
-- reachability verdict is NOT reset (F: a fresh note_failure for a genuinely
-- down server must stand instead of being cleared to fail-open).
do
    local plugin = make_fake_plugin{ wake_wifi_for_sync = true, network_online = true }
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, { destroying = true })

    h.assert_nil(plugin:called("_goOnlineToRun"),
        "J: already online -> goOnlineToRun skipped (no WAN/DNS-probe stall)")
    h.assert_nil(plugin:called("on_network_connected"),
        "F: already online -> stale-verdict reset SKIPPED (fresh failure preserved)")
    h.assert_true(plugin:called("_doCloudUpload") ~= nil, "flush still ran (direct)")
    h.assert_equal(plugin:count("_writeSave"), 1, "flush ran exactly once")
end


-- H: a raising readiness gate during close-push must NOT strand Step 5 — the
-- preflight runs outside the steps pcall, so the whole attempt is itself pcall'd.
do
    local shutdown_count = 0
    local transport = { shutdown = function() shutdown_count = shutdown_count + 1 end }
    local plugin = make_fake_plugin{ wake_wifi_for_sync = true, transport = transport }
    plugin._hasConfiguredTransportForClosePush = function() error("settings boom") end
    local ui = make_fake_uimgr()
    local warn_messages = {}
    local logger = { warn = function(m) table.insert(warn_messages, m) end }

    local ok = pcall(Teardown.flush, plugin, ui, fixed_now, logger, { destroying = true })

    h.assert_true(ok, "raising close-push gate doesn't escape teardown")
    h.assert_equal(plugin:count("_writeSave"), 1, "fell back to the offline flush")
    h.assert_equal(shutdown_count, 1, "Step 5 transport:shutdown still ran")
    h.assert_equal(plugin.timers_cancel_all_count, 1, "Step 5 cancel_all still ran")
    h.assert_true(plugin.destroyed, "Step 5 destroyed still set")
    h.assert_true(#warn_messages == 1 and warn_messages[1]:find("close%-push") ~= nil,
        "warn identifies the close-push attempt as the failure point")
end


-- H: goOnlineToRun raising mid-wait (offline path) clears the re-entrancy guard
-- flag and still reaches Step 5 via the fallback run_flush.
do
    local plugin = make_fake_plugin{ wake_wifi_for_sync = true, go_online = "throw" }
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, { warn = function() end }, { destroying = true })

    h.assert_nil(plugin._close_push_active, "guard flag cleared after a mid-wait raise")
    h.assert_equal(plugin:count("_writeSave"), 1, "offline fallback flushed once")
    h.assert_true(plugin.destroyed, "Step 5 still reached")
end


-- I: the terminal (destroying) Syncthing scan is FORCED (bypass backoff), so an
-- offline autosave's pending retry can't make Step 5 drop the close-time scan.
do
    local plugin = make_fake_plugin{}
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, { destroying = true })

    local c = plugin:called("_doTriggerScan")
    h.assert_true(c ~= nil, "destroying flush triggered the scan")
    h.assert_true(c.args[2] ~= nil and c.args[2].force == true,
        "terminal scan forced (bypasses debounce/backoff)")
end


-- I (counterpart): the deferred (non-destroying) scan keeps normal backoff —
-- only the terminal scan bypasses policy.
do
    local plugin = make_fake_plugin{}
    local ui     = make_fake_uimgr()   -- default nextTick fires synchronously

    Teardown.flush(plugin, ui, fixed_now, nil, {})   -- suspend/autosave

    local c = plugin:called("_doTriggerScan")
    h.assert_true(c ~= nil, "non-destroying scan ran")
    h.assert_true(c.args[2] == nil or c.args[2].force ~= true,
        "deferred scan NOT forced (keeps normal debounce/backoff)")
end


-- M: an excluded book (not sync-eligible) must NOT wake Wi-Fi on close — both
-- push paths self-skip on _isFileTypeSynced, so raising the radio buys nothing.
do
    local plugin = make_fake_plugin{ wake_wifi_for_sync = true, file_type_synced = false }
    local ui     = make_fake_uimgr()

    Teardown.flush(plugin, ui, fixed_now, nil, { destroying = true })

    h.assert_nil(plugin:called("_goOnlineToRun"),
        "excluded book: close-push seam not used (nothing to push)")
    h.assert_equal(plugin:count("_writeSave"), 1, "offline flush still ran once")
end


print("lifecycle_teardown_spec: all assertions passed")
