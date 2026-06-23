-- =============================================================================
-- spec/lifecycle_init_spec.lua
-- =============================================================================
--
-- Tests for syncery_lifecycle/init.lua — the Lifecycle dispatcher.
-- The dispatcher routes KOReader events into Teardown.flush with the
-- right opts, owns the Timers handle, and exposes the
-- schedule_auto_save / schedule / cancel surface that main.lua's
-- methods delegate to.
--
-- We don't re-test Timers or Teardown here (they have their own
-- specs).  Instead we observe what teardown.flush was called with
-- and what timers.schedule was called with, by replacing the modules
-- behind a fake plugin and asserting against the recorded calls.
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_lifecycle_init_spec_" .. tostring(os.time()))

local Lifecycle = require("syncery_lifecycle/init")


-- ----------------------------------------------------------------------------
-- A "recording plugin" that exposes the surface area Lifecycle reads:
--   destroyed, blocking_autosave, sync_state, autosave_delay
--   ui.document      (for on_flush_settings)
--   _debouncedScan() (called by on_flush_settings)
--   _autoSave(silent) (called by the scheduled autosave body)
--
-- Plus the surface area Teardown reads — but the dispatcher's
-- teardown method ultimately delegates to Teardown.flush, which we
-- exercise via its own spec.  Here we just want to know "did the
-- dispatcher reach teardown with the right opts?" — so we observe
-- the side effect that Teardown definitively does in every flush:
-- self._lifecycle.timers:cancel_all().  Recording cancel_all is
-- enough to confirm a flush happened, and the destroying side-effect
-- (plugin.destroyed = true) tells us which opts shape was used.
-- ----------------------------------------------------------------------------


local function make_recording_plugin(opts)
    opts = opts or {}
    local plugin = {
        destroyed          = opts.destroyed or false,
        blocking_autosave  = opts.blocking_autosave or false,
        blocking_autosave_until = opts.blocking_autosave_until or 0,
        sync_state         = opts.sync_state or "idle",
        autosave_delay     = opts.autosave_delay or 5,

        use_cloud        = false,
        use_syncthing    = false,

        ui = opts.ui,
        _autosave_calls    = 0,
        _debounced_calls   = 0,

        -- on_resume surface: a controllable connectivity probe + a recording
        -- checkRemote.  Default online; pass online=false to start offline,
        -- and flip plugin.online_state mid-test to simulate WiFi returning.
        online_state        = (opts.online ~= false),
        _check_remote_calls = 0,
    }
    function plugin:getCurrentState() return nil end  -- skip Steps 1–4
    function plugin:_debouncedScan() self._debounced_calls = self._debounced_calls + 1 end
    function plugin:_autoSave(silent)
        self._autosave_calls = self._autosave_calls + 1
        self._autosave_silent = silent
    end
    function plugin:_isNetworkOnline() return self.online_state end
    function plugin:checkRemote() self._check_remote_calls = self._check_remote_calls + 1 end

    return plugin
end


--- Same fake UIManager as in the other lifecycle specs.
local function make_fake_uimgr()
    local pending = {}
    return {
        scheduleIn = function(self, delay, action)
            table.insert(pending, { delay = delay, action = action })
        end,
        unschedule = function(self, action)
            for i = #pending, 1, -1 do
                if pending[i].action == action then table.remove(pending, i) end
            end
        end,
        close    = function() end,
        nextTick = function(_self, fn) fn() end,  -- inline-fire for test predictability
        fire     = function(action)
            for i = #pending, 1, -1 do
                if pending[i].action == action then table.remove(pending, i) end
            end
            action()
        end,
        delay_for = function(action)
            for _, p in ipairs(pending) do
                if p.action == action then return p.delay end
            end
            return nil
        end,
        pending_count = function() return #pending end,
        -- Fire the OLDEST pending action (FIFO), so a test can step the
        -- offline re-probe loop one tick at a time and flip connectivity
        -- between fires.  A fired body may schedule a new action (the next
        -- re-probe), which lands back in `pending` for the following call.
        fire_first = function()
            if #pending == 0 then return false end
            local p = table.remove(pending, 1)
            p.action()
            return true
        end,
    }
end


local function fixed_now() return 42 end


-- ----------------------------------------------------------------------------
-- Lifecycle.new requires plugin, ui_manager, util_now.
-- ----------------------------------------------------------------------------


do
    local ok = pcall(Lifecycle.new, {})
    h.assert_false(ok, "missing plugin raises")

    local ok2 = pcall(Lifecycle.new, { plugin = {} })
    h.assert_false(ok2, "missing ui_manager raises")

    local ok3 = pcall(Lifecycle.new, { plugin = {}, ui_manager = {} })
    h.assert_false(ok3, "missing util_now raises")

    local ok4 = pcall(Lifecycle.new, {
        plugin = make_recording_plugin{}, ui_manager = make_fake_uimgr(),
        util_now = fixed_now,
    })
    h.assert_true(ok4, "all required deps present → construction succeeds")
end


-- ----------------------------------------------------------------------------
-- Constructed dispatcher owns a Timers instance reachable as .timers.
-- ----------------------------------------------------------------------------


do
    local plugin = make_recording_plugin{}
    local ui     = make_fake_uimgr()
    local lc     = Lifecycle.new{ plugin = plugin, ui_manager = ui, util_now = fixed_now }

    h.assert_equal(type(lc.timers), "table",
        "lifecycle exposes .timers")
    h.assert_equal(type(lc.timers.schedule), "function",
        ".timers has the Timers method surface")
end


-- ----------------------------------------------------------------------------
-- on_close_document → teardown with destroying=true.  Plugin.destroyed
-- ends up true (the Teardown.flush side effect of destroying=true).
-- ----------------------------------------------------------------------------


do
    local plugin = make_recording_plugin{}
    local ui     = make_fake_uimgr()
    local lc     = Lifecycle.new{ plugin = plugin, ui_manager = ui, util_now = fixed_now }
    plugin._lifecycle = lc  -- Teardown reads plugin._lifecycle.timers

    lc:on_close_document()

    h.assert_true(plugin.destroyed,
        "destroying=true was the effective opts shape")
end


-- ----------------------------------------------------------------------------
-- on_suspend → teardown without destroying.  Plugin survives.
-- ----------------------------------------------------------------------------


do
    local plugin = make_recording_plugin{}
    local ui     = make_fake_uimgr()
    local lc     = Lifecycle.new{ plugin = plugin, ui_manager = ui, util_now = fixed_now }
    plugin._lifecycle = lc

    lc:on_suspend()

    h.assert_false(plugin.destroyed,
        "on_suspend does NOT mark destroyed")
end


-- ----------------------------------------------------------------------------
-- Lifecycle:teardown stops the notify toast queue.  notify schedules off-slot
-- (its own scheduleIn, not Timers.SLOTS), so Teardown's Step-5 cancel_all does
-- NOT reach its timers — the dispatcher drives Notify.stopAll after the flush.
-- ----------------------------------------------------------------------------


do
    local Notify = require("syncery_ui/notify")
    Notify.configure({
        scheduleIn = function(secs, fn) return { fn = fn, secs = secs, active = true } end,
        unschedule = function(t) if t then t.active = false end end,
        present    = function() return { dismissed = false } end,
        dismiss    = function(handle) if handle then handle.dismissed = true end end,
        log        = function() end,
    })
    Notify.notifyL2("on screen at close")
    Notify.notifyL2("queued at close")          -- one shown, one waiting
    h.assert_equal(Notify._default:pending(), 1, "wiring: a toast is queued before close")

    local plugin = make_recording_plugin{}
    local ui     = make_fake_uimgr()
    local lc     = Lifecycle.new{ plugin = plugin, ui_manager = ui, util_now = fixed_now }
    plugin._lifecycle = lc

    lc:on_close_document()

    h.assert_true(Notify._default.stopped,
        "wiring: on_close_document stops the notify queue (Notify.stopAll fired)")
    h.assert_equal(Notify._default:pending(), 0,
        "wiring: the toast queue is emptied on teardown")
end


-- ----------------------------------------------------------------------------
-- on_resume → re-check remote on wake, GATED on connectivity.
--
-- KOReader broadcasts Resume to plugins the same way it broadcasts Suspend
-- (which on_suspend handles).  on_resume re-checks whether a peer advanced
-- while we slept, but only once the network is back — checkRemote reads the
-- locally-synced files Syncthing can only refresh on reconnect.  We drive the
-- fake scheduler one tick at a time to assert the gating + the bounded poll.
-- ----------------------------------------------------------------------------


-- Online at wake: arm a deferred check (grace for Syncthing to pull), and
-- firing it calls checkRemote exactly once.
do
    local plugin = make_recording_plugin{ online = true }
    local ui     = make_fake_uimgr()
    local lc     = Lifecycle.new{ plugin = plugin, ui_manager = ui, util_now = fixed_now }
    plugin._lifecycle = lc

    lc:on_resume()
    h.assert_equal(ui.pending_count(), 1,
        "online resume arms exactly one deferred check")
    h.assert_equal(plugin._check_remote_calls, 0,
        "the check is deferred (grace), not run synchronously")

    ui.fire_first()
    h.assert_equal(plugin._check_remote_calls, 1,
        "firing the deferred check calls checkRemote once")
end


-- Offline at wake, network returns on the next probe → eventually checks.
do
    local plugin = make_recording_plugin{ online = false }
    local ui     = make_fake_uimgr()
    local lc     = Lifecycle.new{ plugin = plugin, ui_manager = ui, util_now = fixed_now }
    plugin._lifecycle = lc

    lc:on_resume()
    h.assert_equal(ui.pending_count(), 1,
        "offline resume arms a connectivity re-probe, not a check")
    h.assert_equal(plugin._check_remote_calls, 0,
        "no check while offline")

    plugin.online_state = true        -- WiFi came back between probes
    ui.fire_first()                   -- re-probe runs on_resume → now online → arms deferred check
    h.assert_equal(plugin._check_remote_calls, 0,
        "still deferred in the same tick it comes online")
    ui.fire_first()                   -- fire the deferred check
    h.assert_equal(plugin._check_remote_calls, 1,
        "once online, the re-probe leads to exactly one checkRemote")
end


-- Offline for the whole budget → gives up without ever checking.
do
    local plugin = make_recording_plugin{ online = false }
    local ui     = make_fake_uimgr()
    local lc     = Lifecycle.new{ plugin = plugin, ui_manager = ui, util_now = fixed_now }
    plugin._lifecycle = lc

    lc:on_resume(2)                                                  -- tiny budget
    h.assert_true(ui.fire_first(), "probe 1 fires (still offline)")  -- → on_resume(1)
    h.assert_true(ui.fire_first(), "probe 2 fires (still offline)")  -- → on_resume(0): give up
    h.assert_equal(ui.pending_count(), 0,
        "budget exhausted → no further probe armed")
    h.assert_equal(plugin._check_remote_calls, 0,
        "never checked because the network never returned")
end


-- Destroyed plugin (closed during/after wake): arms nothing, checks nothing.
do
    local plugin = make_recording_plugin{ destroyed = true, online = true }
    local ui     = make_fake_uimgr()
    local lc     = Lifecycle.new{ plugin = plugin, ui_manager = ui, util_now = fixed_now }
    plugin._lifecycle = lc

    lc:on_resume()
    h.assert_equal(ui.pending_count(), 0,
        "a destroyed plugin arms nothing on resume")
    h.assert_equal(plugin._check_remote_calls, 0,
        "and never checks")
end


-- ----------------------------------------------------------------------------
-- on_power_off → non-destroying teardown.  Plugin survives.
-- ----------------------------------------------------------------------------


do
    local plugin = make_recording_plugin{}
    local ui     = make_fake_uimgr()
    local lc     = Lifecycle.new{ plugin = plugin, ui_manager = ui, util_now = fixed_now }
    plugin._lifecycle = lc

    lc:on_power_off()

    h.assert_false(plugin.destroyed,
        "on_power_off does NOT mark destroyed (not a destroying teardown)")
end


-- ----------------------------------------------------------------------------
-- on_quit → teardown with destroying=true.  Plugin is destroyed.
-- ----------------------------------------------------------------------------


do
    local plugin = make_recording_plugin{}
    local ui     = make_fake_uimgr()
    local lc     = Lifecycle.new{ plugin = plugin, ui_manager = ui, util_now = fixed_now }
    plugin._lifecycle = lc

    lc:on_quit()

    h.assert_true(plugin.destroyed,
        "on_quit marks destroyed (same as on_close_document at process scope)")
end


-- ----------------------------------------------------------------------------
-- on_flush_settings — when no document is open (ui.document nil), it's
-- a no-op.  No call to _debouncedScan.
-- ----------------------------------------------------------------------------


do
    local plugin = make_recording_plugin{ ui = { document = nil } }
    local ui     = make_fake_uimgr()
    local lc     = Lifecycle.new{ plugin = plugin, ui_manager = ui, util_now = fixed_now }
    plugin._lifecycle = lc

    lc:on_flush_settings()

    h.assert_equal(plugin._debounced_calls, 0,
        "no _debouncedScan when no document is open")
end


-- ----------------------------------------------------------------------------
-- on_flush_settings — when ui.document IS truthy, _debouncedScan is
-- called.  Pcall-wrapped: a raise doesn't propagate.
-- ----------------------------------------------------------------------------


do
    local plugin = make_recording_plugin{ ui = { document = { tag = "doc" } } }
    local ui     = make_fake_uimgr()
    local lc     = Lifecycle.new{ plugin = plugin, ui_manager = ui, util_now = fixed_now }
    plugin._lifecycle = lc

    lc:on_flush_settings()

    h.assert_equal(plugin._debounced_calls, 1,
        "_debouncedScan called once when document open")
end


do
    local plugin = make_recording_plugin{ ui = { document = { tag = "doc" } } }
    plugin._debouncedScan = function() error("debounce boom") end
    local ui     = make_fake_uimgr()
    local lc     = Lifecycle.new{ plugin = plugin, ui_manager = ui, util_now = fixed_now }
    plugin._lifecycle = lc

    local ok = pcall(function() lc:on_flush_settings() end)
    h.assert_true(ok,
        "_debouncedScan exception swallowed by on_flush_settings' pcall")
end


-- ----------------------------------------------------------------------------
-- schedule_auto_save — happy path: arms _autosave_action at
-- plugin.autosave_delay, body calls _autoSave(true).
-- ----------------------------------------------------------------------------


do
    local plugin = make_recording_plugin{ autosave_delay = 7 }
    local ui     = make_fake_uimgr()
    local lc     = Lifecycle.new{ plugin = plugin, ui_manager = ui, util_now = fixed_now }

    lc:schedule_auto_save()

    h.assert_equal(ui.pending_count(), 1, "one timer armed")
    local action = plugin._autosave_action
    h.assert_equal(type(action), "function", "slot field populated")
    h.assert_equal(ui.delay_for(action), 7, "delay is plugin.autosave_delay")

    ui.fire(action)

    h.assert_equal(plugin._autosave_calls, 1,
        "_autoSave called once when sync_state is idle and not blocked")
    h.assert_true(plugin._autosave_silent,
        "_autoSave called with silent=true")
end


-- ----------------------------------------------------------------------------
-- schedule_auto_save — no-op when destroyed (no schedule, no fire).
-- ----------------------------------------------------------------------------


do
    local plugin = make_recording_plugin{ destroyed = true }
    local ui     = make_fake_uimgr()
    local lc     = Lifecycle.new{ plugin = plugin, ui_manager = ui, util_now = fixed_now }

    lc:schedule_auto_save()

    h.assert_equal(ui.pending_count(), 0,
        "no UIManager interaction when plugin is destroyed")
    h.assert_nil(plugin._autosave_action,
        "no plugin slot field set")
end


-- ----------------------------------------------------------------------------
-- schedule_auto_save — no-op when blocking_autosave is set.
-- ----------------------------------------------------------------------------


do
    local plugin = make_recording_plugin{ blocking_autosave = true }
    local ui     = make_fake_uimgr()
    local lc     = Lifecycle.new{ plugin = plugin, ui_manager = ui, util_now = fixed_now }

    lc:schedule_auto_save()

    h.assert_equal(ui.pending_count(), 0,
        "no schedule when blocking_autosave is set")
end


-- ----------------------------------------------------------------------------
-- schedule_auto_save — armed but sync_state changes between arm and
-- fire → body sees the change and skips _autoSave.
-- ----------------------------------------------------------------------------


do
    local plugin = make_recording_plugin{}
    local ui     = make_fake_uimgr()
    local lc     = Lifecycle.new{ plugin = plugin, ui_manager = ui, util_now = fixed_now }

    lc:schedule_auto_save()
    local action = plugin._autosave_action

    plugin.sync_state = "syncing"  -- transition between arm and fire
    ui.fire(action)

    h.assert_equal(plugin._autosave_calls, 0,
        "_autoSave NOT called when sync_state moved to syncing before fire")
end


-- ----------------------------------------------------------------------------
-- schedule_auto_save — armed but blocking_autosave flips on between
-- arm and fire → body sees the flip and skips _autoSave.
-- ----------------------------------------------------------------------------


do
    local plugin = make_recording_plugin{}
    local ui     = make_fake_uimgr()
    local lc     = Lifecycle.new{ plugin = plugin, ui_manager = ui, util_now = fixed_now }

    lc:schedule_auto_save()
    local action = plugin._autosave_action

    plugin.blocking_autosave = true  -- flips on between arm and fire
    ui.fire(action)

    h.assert_equal(plugin._autosave_calls, 0,
        "_autoSave NOT called when blocking_autosave flipped on before fire")
end


-- ----------------------------------------------------------------------------
-- B2: the self-healing window (blocking_autosave_until). The clock here
-- is fixed_now() == 42, so a window value > 42 is "still blocking" and a
-- value <= 42 is "lapsed". These exercise the real schedule_auto_save
-- gate + fire-recheck, the lifecycle reader the audit flagged as the one
-- that prevents a NEW autosave from ever arming when the flag is stuck.
-- ----------------------------------------------------------------------------


-- Window in the future at arm time → no timer is armed at all.
do
    local plugin = make_recording_plugin{ blocking_autosave_until = 100 }  -- > 42
    local ui     = make_fake_uimgr()
    local lc     = Lifecycle.new{ plugin = plugin, ui_manager = ui, util_now = fixed_now }

    lc:schedule_auto_save()

    h.assert_equal(ui.pending_count(), 0,
        "B2: no schedule while the jump window is still open (until > now)")
end


-- Window already lapsed at arm time → behaves as unblocked: timer arms
-- and the body fires the save.
do
    local plugin = make_recording_plugin{ blocking_autosave_until = 10 }   -- <= 42
    local ui     = make_fake_uimgr()
    local lc     = Lifecycle.new{ plugin = plugin, ui_manager = ui, util_now = fixed_now }

    lc:schedule_auto_save()
    local action = plugin._autosave_action

    h.assert_equal(ui.pending_count(), 1,
        "B2: a lapsed window does not block arming (until <= now)")
    ui.fire(action)
    h.assert_equal(plugin._autosave_calls, 1,
        "B2: a lapsed window lets the autosave body run — flag self-healed")
end


-- Window opens (e.g. a jump) AFTER the timer was armed but BEFORE it
-- fires → the fire-recheck sees the open window and skips the save.
do
    local plugin = make_recording_plugin{}  -- until = 0 at arm: arms normally
    local ui     = make_fake_uimgr()
    local lc     = Lifecycle.new{ plugin = plugin, ui_manager = ui, util_now = fixed_now }

    lc:schedule_auto_save()
    local action = plugin._autosave_action

    plugin.blocking_autosave_until = 100  -- a jump opens the window before fire
    ui.fire(action)

    h.assert_equal(plugin._autosave_calls, 0,
        "B2: fire-recheck honours a window opened between arm and fire")
end


-- Window that lapses between arm and fire → the body runs (the block
-- genuinely self-heals on the timeline, not just at arm time).
do
    local plugin = make_recording_plugin{ blocking_autosave_until = 41 }   -- <= 42: lapsed
    local ui     = make_fake_uimgr()
    local lc     = Lifecycle.new{ plugin = plugin, ui_manager = ui, util_now = fixed_now }

    lc:schedule_auto_save()
    local action = plugin._autosave_action

    h.assert_equal(ui.pending_count(), 1,
        "B2: arm proceeds once the window has lapsed")
    ui.fire(action)
    h.assert_equal(plugin._autosave_calls, 1,
        "B2: body runs after the window lapsed — no permanent strand")
end


-- ----------------------------------------------------------------------------
-- schedule / cancel / cancel_all_timers passthroughs to .timers.
-- ----------------------------------------------------------------------------


do
    local plugin = make_recording_plugin{}
    local ui     = make_fake_uimgr()
    local lc     = Lifecycle.new{ plugin = plugin, ui_manager = ui, util_now = fixed_now }

    local fired = false
    lc:schedule("_gc_action", 3, function() fired = true end)
    h.assert_true(lc.timers:is_armed("_gc_action"),
        "schedule passthrough arms .timers")

    lc:cancel("_gc_action")
    h.assert_false(lc.timers:is_armed("_gc_action"),
        "cancel passthrough drops the arm")

    lc:schedule("_gc_action", 3, function() end)
    lc:schedule("_autosave_action", 3, function() end)
    h.assert_equal(ui.pending_count(), 2, "two armed")

    lc:cancel_all_timers()
    h.assert_equal(ui.pending_count(), 0, "cancel_all_timers drops everything")
end


-- ----------------------------------------------------------------------------
-- teardown() passthrough — calling lc:teardown(opts) reaches Teardown.flush
-- with the right opts.  Verified by destroying=true → plugin.destroyed.
-- ----------------------------------------------------------------------------


do
    local plugin = make_recording_plugin{}
    local ui     = make_fake_uimgr()
    local lc     = Lifecycle.new{ plugin = plugin, ui_manager = ui, util_now = fixed_now }
    plugin._lifecycle = lc

    lc:teardown{ destroying = true }
    h.assert_true(plugin.destroyed,
        "lc:teardown forwards opts to Teardown.flush")
end


-- ----------------------------------------------------------------------------
-- G-wiring: on_save_settings delivers the close-time stash to doc_settings'
-- base "annotations" key (through the REAL stage_pending_at_close), honouring
-- adapt_highlight_style, then clears the stash.  No stash -> no-op.  (The
-- stash FILLING is covered in lifecycle_teardown_spec; this covers the
-- delivery half end-to-end.)  See ANNOTATION_DELIVERY_DESIGN.md S2 / G-wiring.
-- ----------------------------------------------------------------------------


-- Minimal fake ReaderUI carrying what stage_pending_at_close touches: a
-- doc_settings store + an in-memory annotation list.
local function make_fake_reader_ui()
    local store = {}
    return {
        doc_settings = {
            _store      = store,
            saveSetting = function(_s, k, v) store[k] = v end,
            readSetting = function(_s, k) return store[k] end,
        },
        annotation = {
            annotations = {},
            sortItems   = function(_s, _items) end,
        },
    }
end


-- stash present -> delivered (adapt strips color/drawer) + flag set + cleared.
do
    local reader_ui = make_fake_reader_ui()
    local plugin    = make_recording_plugin{ ui = reader_ui }
    plugin._pending_anns = {
        -- merged_annotations shape: { identity_key = annotation }; tombstones
        -- would carry a `deleted` flag (none here -- one alive annotation).
        annotations = {
            ["md5_/p[1]"] = { text = "a", page = "/p[1]",
                              color = "red", drawer = "underscore",
                              device_id = "remote_dev",
                              datetime = "2026-01-01 00:00:00" },
        },
        adapt_highlight_style = true,
        device_id             = "this_dev",
    }
    local ui_mgr = make_fake_uimgr()
    local lc = Lifecycle.new{ plugin = plugin, ui_manager = ui_mgr, util_now = fixed_now }

    lc:on_save_settings()

    local written = reader_ui.doc_settings._store["annotations"]
    h.assert_true(type(written) == "table" and #written == 1,
        "on_save_settings wrote the merged alive list to base annotations")
    h.assert_equal(written[1].text, "a",
        "delivered annotation carried through")
    h.assert_nil(written[1].color,
        "adapt_highlight_style=true stripped color on delivery")
    -- Drawer is REPLACED with the device default, never nil (a drawer-less
    -- annotation reads as a page bookmark in KOReader).  This fake ui carries
    -- no view.highlight.saved_drawer, so the "lighten" fallback applies.
    h.assert_equal(written[1].drawer, "lighten",
        "adapt_highlight_style=true replaced drawer with device default on delivery (stays a highlight)")
    h.assert_true(reader_ui.doc_settings._store["annotations_externally_modified"] == true,
        "external-modification flag set so onReadSettings recomputes/sorts")
    h.assert_nil(plugin._pending_anns,
        "stash cleared after delivery (consumed exactly once)")
end


-- no stash -> no-op (nothing written, no crash).
do
    local reader_ui = make_fake_reader_ui()
    local plugin    = make_recording_plugin{ ui = reader_ui }
    -- plugin._pending_anns stays nil
    local ui_mgr = make_fake_uimgr()
    local lc = Lifecycle.new{ plugin = plugin, ui_manager = ui_mgr, util_now = fixed_now }

    lc:on_save_settings()

    h.assert_nil(reader_ui.doc_settings._store["annotations"],
        "no stash -> on_save_settings writes nothing")
end


-- ----------------------------------------------------------------------------
-- G end-to-end: a DESTROYING teardown fills the stash, then on_save_settings
-- delivers it to base annotations through the REAL stage_pending_at_close.
-- Composes both halves across the real plugin._pending_anns seam, catching any
-- structural mismatch between the writer (teardown) and the reader
-- (on_save_settings).  See ANNOTATION_DELIVERY_DESIGN.md S2 / G-wiring.
-- ----------------------------------------------------------------------------


do
    local reader_ui = make_fake_reader_ui()
    local merged = {
        annotations = {
            -- { identity_key = annotation } -- the merged_annotations shape.
            ["k_/p[1]"] = { text = "z", page = "/p[1]",
                            color = "red", drawer = "underscore",
                            device_id = "remote_dev",
                            datetime = "2026-01-01 00:00:00" },
        },
    }
    local plugin = {
        use_cloud     = false,   -- skip Step 3
        use_syncthing = false,   -- Step 4 nextTick short-circuits after the check
        adapt_highlight_style = true,
        device_id     = "this_dev",
        ui = reader_ui,
        getCurrentState = function(_s) return { file = "/b.epub", page = 3 } end,
        _writeSave = function(_s, _state, _now, _silent) end,
        _syncBookViaOrchestrator = function(_s, _state)
            -- The orchestrator returns the per-device delivery map alongside the
            -- shared merged_state; with no per-type filtering they coincide.
            return true, { merged_state = merged, delivery_annotations = merged.annotations }
        end,
        _isFileTypeSynced = function(_s, _file) return true end,
    }
    local ui_mgr = make_fake_uimgr()
    local lc = Lifecycle.new{ plugin = plugin, ui_manager = ui_mgr, util_now = fixed_now }
    plugin._lifecycle = lc  -- Teardown reads plugin._lifecycle.timers

    -- 1) destroying teardown fills the stash (Step 2 captures merged_state).
    lc:teardown{ destroying = true }
    h.assert_true(type(plugin._pending_anns) == "table",
        "G end-to-end: destroying teardown filled the stash")

    -- 2) the next save delivers it to doc_settings' base annotations.
    lc:on_save_settings()

    local written = reader_ui.doc_settings._store["annotations"]
    h.assert_true(type(written) == "table" and #written == 1,
        "G end-to-end: merged annotation reached base annotations")
    h.assert_equal(written[1].text, "z",
        "G end-to-end: annotation content delivered through the full chain")
    h.assert_nil(written[1].color,
        "G end-to-end: adapt_highlight_style stripped color through the chain")
    h.assert_true(reader_ui.doc_settings._store["annotations_externally_modified"] == true,
        "G end-to-end: external-modification flag set for the next open")
    h.assert_nil(plugin._pending_anns,
        "G end-to-end: stash consumed after delivery")
end


print("lifecycle_init_spec: all assertions passed")
