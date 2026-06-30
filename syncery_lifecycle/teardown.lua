-- =============================================================================
-- syncery_lifecycle/teardown.lua
-- =============================================================================
--
-- The "make sure everything is on disk before we lose this window"
-- routine.  Four KOReader events share its semantics with slightly
-- different "how strong is this teardown" knobs:
--
--   onCloseDocument  — done with THIS book for this session.
--                       Mark plugin.destroyed = true, shut down the
--                       transport stack.
--   onSuspend        — device going to sleep.  Just flush; nothing
--                       to tear down (we'll wake up here).
--   onPowerOff       — device shutting down.  Flush; tear-down opts
--                       accepted for call-site compat but
--                       effectively a no-op — nothing under the transport
--                       stack (no KOSyncthing+ subscription to drop, no retry
--                       queue to shut down — both gone).
--   onQuit           — KOReader process exiting.  Same flush plus
--                       destroying = true, same as close-document but
--                       at process scope.
--
-- WHY A SEPARATE MODULE
--
-- These four events share the same eight operations, factored into
-- `_flushPersistedState(opts)` instead of a method on `Syncery:`
-- alongside ~80 others.
-- Pulling it out makes the call sequence explicit, makes the steps
-- testable in isolation (with a fake plugin recorder), and removes
-- 80 lines from main.lua.
--
-- THE STEPS (numbered to match the comment block inside `flush`)
--
--   1. Persist progress JSON (`plugin:_writeSave`).  Always safe, even
--      with empty in-memory state — writes the same bytes back, no
--      no-op detection needed at this layer.
--
--   2. Flush annotations/bookmarks back to KOReader's doc_settings,
--      but ONLY when this session has at least once completed a back-
--      sync.  Skipping this on the first session prevents over-
--      writing a freshly-pulled remote state with the half-built
--      in-memory state of a book that was just opened.
--
--   3. Opportunistic cloud push.  Gated internally —
--      calling it unconditionally is safe when the transport is
--      disabled or the daemon is down.
--
--   4. Deferred Syncthing scan trigger.  The scan goes through
--      UIManager:nextTick so the OS sees Step 1's bytes on disk before
--      the scan walks the directory.  Only fires when use_syncthing is
--      on AND the file extension is in the sync allowlist.
--
--   5. Lifecycle-specific tidy-up.  destroying=true sets
--      plugin.destroyed (= true) and shuts down the transport stack.
--      Either way, every armed timer is cancelled.
-- =============================================================================


local Teardown = {}


-- ----------------------------------------------------------------------------
-- flush_persisted_state
--
-- Run the full sequence against `plugin`.  Reads:
--   plugin.ui                         — KOReader ReaderUI (for nextTick)
--   plugin.use_cloud                  — bool, gate Step 3 cloud upload
--   plugin.use_syncthing              — bool, gate Step 4 scan
--   plugin._active_sync_box           — open InfoMessage we should close
--   plugin._transport                 — transport stack (for shutdown)
--   plugin._lifecycle._timers         — owned by Lifecycle.new, see init.lua
--
-- Calls into `plugin`:
--   plugin:getCurrentState()          — returns nil when no doc open
--   plugin:_writeSave(state, t, silent)
--   plugin:_syncBookViaOrchestrator(state)
--   plugin:_doCloudUpload(state)
--   plugin:_doTriggerScan(state)
--   plugin:_isFileTypeSynced(state.file)
--
-- Writes:
--   plugin.destroyed           = true (only when opts.destroying)
--   plugin._active_sync_box    = nil  (Step 0: cleared as a boolean flag)
--
-- Calls into externals:
--   ui_manager:nextTick(fn)           — for Step 4's deferred scan
--   util:now()                        — passed to _writeSave for the timestamp
--   transport:shutdown()              — when opts.destroying
--
-- opts:
--   destroying       — bool, set plugin.destroyed = true; shut down transport
-- ----------------------------------------------------------------------------


--- Run the lifecycle flush sequence against `plugin`.
---
--- @param plugin     table   the Syncery plugin instance
--- @param ui_manager table   KOReader's UIManager (close + nextTick)
--- @param util_now   function function() returning the current Unix time
--- @param logger     table   logger:warn(msg) for soft errors
--- @param opts       table?
function Teardown.flush(plugin, ui_manager, util_now, logger, opts)
    opts   = opts or {}
    logger = logger or { warn = function() end }

    -- D: re-entrancy guard.  A blocking close-push goOnlineToRun can let the OS
    -- emit Suspend/Resume (e.g. an Android focus switch while the Wi-Fi dialog is
    -- up); those reach us AGAIN through the lifecycle handlers and would run a
    -- second, non-destroying flush mid-close.  Skip any flush re-entered while a
    -- close-push is in flight (KOSync nulls its handlers for the same reason).
    if plugin._close_push_active then return end

    -- ------------------------------------------------------------------
    -- Steps 0-4 are a BEST-EFFORT flush, ALL isolated in one pcall so that
    -- an unhandled raise ANYWHERE in the pre-Step-5 input cannot strand the
    -- Step-5 cleanup below (transport shutdown + cancel_all).  This is the
    -- "throwing must not skip teardown" discipline the shutdown pcall
    -- already applied — the boundary was simply one or two expressions too
    -- low.  Two real pre-pcall raisers prompted moving it up: closing the
    -- (now boolean) `_active_sync_box` as if it were a widget, and
    -- `getCurrentState` reaching into a half-torn-down `ui.document`.  The
    -- error is logged (real logger), never swallowed silently.
    --
    -- `state` is returned OUT of the pcall so the `if state then` gate for
    -- Steps 1-4 works unchanged: if Step 0 / getCurrentState raises,
    -- ok=false -> state stays nil -> Steps 1-4 are skipped ("no state ->
    -- no flush"), and Step 5 still runs.
    -- ------------------------------------------------------------------
    local ok, state = pcall(function()
        -- Step 0: drop the active-sync re-entry guard.  `_active_sync_box` is
        -- a boolean flag (the jump toast is owned by the
        -- notification coordinator, which auto-dismisses it on its own
        -- lifecycle — it is NOT a widget handle held here), so there is
        -- nothing to close from teardown; just clear the flag.
        plugin._active_sync_box = nil

        return plugin:getCurrentState()
    end)
    if not ok then
        logger.warn("Syncery: teardown pre-flush error: " .. tostring(state))
        state = nil
    end

    if state then
        -- Steps 1-4 are a BEST-EFFORT flush.  Isolate them in a pcall so
        -- that an unhandled raise in any step cannot strand the Step-5
        -- cleanup below (cancel_all + transport shutdown) — the same
        -- "throwing must not skip teardown" discipline the shutdown pcall
        -- already applies.  The error is logged (real logger), never
        -- swallowed silently.
        -- Steps 1-4 as a thunk so the dispatch below can run them inline or after
        -- raising the network (close-push).
        local steps = function()
            -- Step 1: persist progress JSON.  Cheap, always safe.  Pass the
            -- close/suspend trigger (mirroring the annotation sync below) so
            -- the final-position push is labelled in the sync journal: under
            -- the event filter close/suspend progress always lands, and the
            -- label is what makes the line read "merged via close".
            plugin:_writeSave(state, util_now(), true,
                opts.destroying and "close" or "suspend")

            -- Step 2: annotation back-sync via the orchestrator (pull +
            -- merge + push, bookmarks included).  Runs unconditionally —
            -- the orchestrator owns its own completion accounting, and its
            -- wipe failsafe protects the case where this device has not
            -- pulled remote state yet (it refuses to push empty-over-full).
            local _had_data, result = plugin:_syncBookViaOrchestrator(state,
                { trigger = opts.destroying and "close" or "suspend" })

            -- Close-time annotation delivery (G): on a DESTROYING flush
            -- (close-document / quit), stash the merged annotation list so
            -- Syncery:onSaveSettings can write it to doc_settings' base
            -- "annotations" key AFTER ReaderAnnotation:onSaveSettings runs.
            -- Verified against KOReader source: the core handler returns nil
            -- (does not stop the SaveSettings broadcast), no core module's
            -- onSaveSettings returns true, and plugins are registered after
            -- the core modules, so our handler runs last and overwrites the
            -- live-list write (ANNOTATION_DELIVERY_DESIGN.md S2 / G-wiring).
            -- Nil-safe: _syncBookViaOrchestrator returns its result (carrying
            -- delivery_annotations) only on a successful, non-wipe sync; early /
            -- error / wipe returns drop it, leaving the stash untouched.  Gated
            -- on destroying so suspend / autosave never stage a list;
            -- on_power_off passes no destroying, so delivery there defers to the
            -- next normal close (eventually consistent — the merge persists in
            -- the shared store regardless).
            --
            -- We stage `delivery_annotations`, NOT `merged_state.annotations`:
            -- under per-type filtering the shared (merged) map and THIS device's
            -- map differ -- the shared file preserves a disabled type's entries
            -- from other devices, but this device must not have them written
            -- into its own sidecar, while keeping its OWN disabled-type entries.
            -- delivery_annotations is exactly that per-device view (it equals
            -- merged_state.annotations when no type is filtered).  Staged
            -- exclusively, with no fallback.
            if opts.destroying and result and type(result.delivery_annotations) == "table" then
                plugin._pending_anns = {
                    annotations           = result.delivery_annotations,
                    adapt_highlight_style = plugin.adapt_highlight_style,
                    device_id             = plugin.device_id,
                }
            end

            -- Step 3: opportunistic auxiliary push.  Gated internally, so
            -- calling unconditionally is safe when disabled.
            if plugin.use_cloud then
                -- This is a TERMINAL push: Step 5 below shuts the transport
                -- down on the destroying path, so there is no future tick for
                -- the async reachability probe to resolve on.  Without help,
                -- _doCloudUpload's gate would consult the cold/cached-but-stale
                -- verdict, DEFER via the cloud backoff, and the deferred retry
                -- would fire after shutdown -> "push_book after shutdown" ->
                -- the close-time upload is dropped.  Warm the verdict
                -- synchronously first (one bounded connect to the cached IP, no
                -- DNS) so the gate gets a firm answer and the push proceeds (or
                -- is correctly skipped) INLINE, before the shutdown.
                if plugin._cloud_reachability then
                    pcall(function() plugin._cloud_reachability:warm_blocking() end)
                end
                plugin:_doCloudUpload(state)
            end

            -- Step 4: tell Syncthing to scan our file.  The orchestrator's
            -- transport.is_available() handles "is daemon up?" so no pre-flight
            -- status shortcut is needed here.
            local function trigger_scan(force)
                if not plugin:_isFileTypeSynced(state.file) then return end
                if not plugin.use_syncthing then return end

                local ok, err = pcall(function()
                    plugin:_doTriggerScan(state, { force = force })
                end)
                if not ok then
                    logger.warn("Syncery: deferred scan error: " .. tostring(err))
                end
            end

            -- A: on a DESTROYING flush run the scan INLINE — Step 5 below shuts
            -- the transport down synchronously right after, so a nextTick scan
            -- would fire post-shutdown (_shutdown=true) and be dropped.  Step 1's
            -- _writeSave is synchronous, so the bytes are already on disk here.
            -- I: force=true on this terminal scan — an offline autosave attempt
            -- may have left it in_backoff, and Step 5 cancels the pending retry,
            -- so the policy must be bypassed or the close-time scan is lost.
            -- Non-destroying (suspend/autosave): defer via nextTick (no shutdown
            -- follows) and keep the normal debounce/backoff (force=false).
            if opts.destroying then
                trigger_scan(true)
            elseif ui_manager and ui_manager.nextTick then
                ui_manager:nextTick(function() trigger_scan(false) end)
            end
        end

        -- BEST-EFFORT and idempotent: Steps 1-4 must never strand Step 5's
        -- cleanup, and must run at most once however the dispatch below reaches us.
        local flushed = false
        local function run_flush()
            if flushed then return end
            flushed = true
            local flush_ok, flush_err = pcall(steps)
            if not flush_ok then
                logger.warn("Syncery: teardown flush error: " .. tostring(flush_err))
            end
        end

        -- E: when close-push RAISES the link, KOReader's NetworkConnected event
        -- is delayed and hasn't reset the reachability verdict yet.  A stale
        -- `unreachable` (set by an earlier NetworkDisconnected) with no cached IP
        -- would make Step 3's gate skip the cloud push.  Apply the same reset the
        -- real event would, synchronously, BEFORE the flush.
        -- F: but ONLY when the link was actually raised (was offline).  If we were
        -- already online, goOnlineToRun runs this immediately and the verdict may
        -- be a FRESH note_failure (server genuinely down, not an offline blip) —
        -- clearing it would fail open and block the close on a dead server.  So
        -- gate the reset on the pre-raise link state captured below.
        local was_online      -- set in the close-push branch, before goOnlineToRun
        local function online_flush()
            if not was_online and plugin._cloud_reachability
                    and plugin._cloud_reachability.on_network_connected then
                pcall(function() plugin._cloud_reachability:on_network_connected() end)
            end
            run_flush()
        end

        -- KOSync close-push: on a terminal flush, raise Wi-Fi and flush once
        -- online, when opted in and a transport is actually CONFIGURED (B: not
        -- just a master toggle, or we'd wake the radio with nothing to push).
        -- H: the readiness gate, the link probe, and goOnlineToRun all run
        -- OUTSIDE the steps pcall, so wrap the whole attempt — a raising Settings
        -- lookup or NetworkMgr probe must not skip the unconditional run_flush()
        -- and Step 5 below.  The fallback run_flush() is a no-op if close_push
        -- already flushed, else it runs the offline path (network steps self-skip).
        local function close_push()
            -- M: also require THIS book to be sync-eligible — both push paths
            -- (cloud upload, Syncthing scan) self-skip on _isFileTypeSynced, so
            -- for an excluded book (extension/per-book disable) waking Wi-Fi would
            -- buy nothing.  Cheap (the push paths call it anyway).
            if not (opts.destroying and plugin.wake_wifi_for_sync
                    and plugin:_hasConfiguredTransportForClosePush()
                    and plugin:_isFileTypeSynced(state.file)) then
                return
            end
            was_online = plugin:_isNetworkOnline()
            if was_online then
                -- J: already connected — skip goOnlineToRun (its online check can
                -- run a WAN/DNS probe that stalls on captive/local-only Wi-Fi);
                -- we already have the cheap link verdict, so flush directly.
                online_flush()
                return
            end
            -- Offline: raise Wi-Fi, flush once online.  D: guard a Suspend/Resume
            -- emitted during the blocking wait so it can't run a duplicate flush.
            plugin._close_push_active = true
            plugin:_goOnlineToRun(online_flush)
            plugin._close_push_active = nil
        end
        local ok_cp, err_cp = pcall(close_push)
        if not ok_cp then
            plugin._close_push_active = nil   -- clear if a raise happened mid-wait
            logger.warn("Syncery: close-push error: " .. tostring(err_cp))
        end
        run_flush()
    end

    -- Step 5: lifecycle-specific tidying.  The only work here is the
    -- destroying path (full transport shutdown); there is no separate
    -- queue to drain — the orchestrator's per-(transport, book) state
    -- replaces the old RetryQueue, and there's no companion-API
    -- subscription to tear down.
    if opts.destroying then
        plugin.destroyed = true
        -- Shut down the transport stack: cancels pending
        -- retries inside the orchestrator and prevents further
        -- push_book calls from dispatching.  Idempotent — calling
        -- shutdown twice is harmless (the orchestrator no-ops).
        if plugin._transport then
            pcall(function() plugin._transport:shutdown() end)
        end
    end

    -- Always cancel every armed timer.  The Lifecycle dispatcher
    -- owns the Timers object; teardown reaches it through the same
    -- plugin._lifecycle ref that called us.
    if plugin._lifecycle and plugin._lifecycle.timers then
        plugin._lifecycle.timers:cancel_all()
    end
end


return Teardown
