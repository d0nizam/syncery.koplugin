-- =============================================================================
-- syncery_lifecycle/timers.lua
-- =============================================================================
--
-- Owns the plugin's debounced/deferred work.  Every periodic or
-- delayed action in `main.lua` — autosave, debounced scan, cloud
-- pull, cloud upload, tombstone GC, the first-run prompt, etc. —
-- routes through `Timers:schedule(slot, delay, fn)`.  The slot name
-- is the cancel handle, which is what makes "re-arming a still-pending
-- timer cancels the previous arm" work.
--
-- WHY A DEDICATED MODULE
--
-- The legacy code kept the schedule/cancel machinery inline on
-- `Syncery:` (as `_schedule` and `_cancelAllTimers`), with the cancel
-- tokens stored as fields directly on the plugin object (`_autosave_
-- action`, `_debounce_scan_action`, ...).  That made the destroyed-
-- check ("don't fire if the plugin is being torn down") live inside
-- the wrapper closure rather than at the call site, which is correct
-- but obscured by the inline structure.
--
-- Pulling timers out into a class makes three things explicit:
--   1. The slot list — exactly which delayed actions exist — is
--      visible at the top of one file.
--   2. The destroyed-check is a property of *every* scheduled
--      callback, applied uniformly.  No call site can forget.
--   3. The UIManager dependency is injected, so the unit tests can
--      hand in a fake scheduler and assert exactly what got scheduled
--      with what delay.
--
-- WHAT STAYS THE SAME (call-site compatibility)
--
-- The `Syncery:_schedule(slot, delay, body)` and
-- `Syncery:_cancelAllTimers()` methods on the plugin object remain —
-- they're now one-line delegators to this module.  ~25 call sites
-- across `main.lua` don't need to change.  Same with the cancel
-- tokens being readable as `self[slot]` on the plugin: callers like
-- `_debouncedScan` explicitly check `if self._debounce_scan_action`
-- and then `UIManager:unschedule(self._debounce_scan_action)`.  We
-- mirror those fields on the plugin so those checks keep working.
--
-- DESTROYED CHECK
--
-- Every scheduled body is wrapped in a guard that skips the call
-- when `plugin.destroyed == true`.  This is the same guarantee the
-- legacy inline `_schedule` provided — without it, a save+close+
-- reopen sequence could fire stale autosave or scan callbacks
-- against a plugin instance whose document state has been
-- invalidated.  pcall around the body keeps a failing scheduled
-- callback from crashing UIManager's scheduler.
-- =============================================================================


local Timers = {}
Timers.__index = Timers


-- ----------------------------------------------------------------------------
-- Slot names.  These are the only valid keys for `schedule(slot, ...)`.
-- Listed here (rather than passed by callers as arbitrary strings) so
-- the cancel-all loop has a complete inventory and so a typo at the
-- call site is grep-detectable.
--
-- Field-on-plugin compatibility: each slot name doubles as the field
-- the plugin can read to test "is this timer armed?" — used in
-- _debouncedScan to choose between immediate fire and reschedule.
-- ----------------------------------------------------------------------------


Timers.SLOTS = {
    "_autosave_action",
    "_check_remote_action",
    "_cloud_upload_action",
    "_debounce_scan_action",
    "_firstrun_action",
    "_gc_action",
    "_open_cloud_pull",          -- scheduled in main.lua (onReaderReady — open-moment cloud pull)
    "_post_pull_check",          -- scheduled in main.lua (on_reconciled — re-check after a cloud pull reconciles)
    "_resume_recheck_action",    -- scheduled in syncery_lifecycle/init.lua (resume re-probe)
    "_sync_annotations_action",  -- scheduled in main.lua (onAnnotationsModified)
    "_sync_bookmarks_action",
    "_sync_now_action",
    "_sync_unlock_action",
}


-- ----------------------------------------------------------------------------
-- Construction
--
-- opts.ui_manager (table)  — KOReader's UIManager.  Required.  We use
--                             :scheduleIn(delay, fn) and :unschedule(fn).
-- opts.plugin     (table)  — the Syncery plugin instance.  Used for
--                             two things only: reading `plugin.destroyed`
--                             to decide whether to fire a scheduled
--                             callback, and writing `plugin[slot] = token`
--                             so legacy field-checks at call sites
--                             continue to work.
-- opts.logger     (table)  — optional; logger:warn(msg) is called when
--                             a scheduled body raises.  Falls back to a
--                             no-op when not provided (test contexts).
-- ----------------------------------------------------------------------------


--- Build a new Timers instance.
--- @param opts table
--- @return table
function Timers.new(opts)
    opts = opts or {}
    assert(type(opts.ui_manager) == "table",
        "Timers.new: ui_manager is required")
    assert(type(opts.plugin) == "table",
        "Timers.new: plugin is required")

    local self = setmetatable({}, Timers)
    self._ui_manager = opts.ui_manager
    self._plugin     = opts.plugin
    self._logger     = opts.logger or { warn = function() end }
    -- Internal slot→action_token map.  Mirrored onto the plugin so
    -- legacy call sites that read `self._debounce_scan_action` directly
    -- keep working.
    self._slots = {}
    -- Reverse index of the valid slot names, so schedule() can reject an
    -- off-slot name LOUDLY.  An unknown slot would be stored in _slots but
    -- never reached by cancel_all (which iterates the static SLOTS), so it
    -- would silently escape teardown/reset cancellation — exactly the
    -- defect BUG-2 fixed for two real slots.
    self._slot_set = {}
    for _, s in ipairs(Timers.SLOTS) do self._slot_set[s] = true end
    return self
end


-- ----------------------------------------------------------------------------
-- schedule
--
-- Arm a timer in `slot` to fire `body` after `delay` seconds.  If the
-- slot is already armed, cancel the previous arm first — that's the
-- semantics call sites assume (e.g. `scheduleAutoSave` is called on
-- every PageUpdate/PosUpdate event; each call should re-debounce, not
-- pile up).
--
-- The wrapped action:
--   • Clears the slot field on first entry, so the slot is considered
--     "not pending" even before the body finishes.  This is what lets
--     a body call schedule(same_slot, ...) without infinite recursion.
--   • Bails out early if the plugin is destroyed.  Same guarantee as
--     the legacy inline _schedule.
--   • pcall-wraps the body so a faulty callback can't crash UIManager.
-- ----------------------------------------------------------------------------


--- Schedule `body` to fire after `delay` seconds, stored in `slot`.
--- Cancels any prior arm of the same slot.
--- @param slot  string   one of Timers.SLOTS
--- @param delay number   seconds (passed to UIManager:scheduleIn)
--- @param body  function the callback to run
function Timers:schedule(slot, delay, body)
    assert(type(slot) == "string", "Timers:schedule: slot must be a string")
    assert(self._slot_set[slot],
        "Timers:schedule: unknown slot '" .. tostring(slot)
        .. "' — add it to Timers.SLOTS, or cancel_all will silently miss it")
    assert(type(body) == "function", "Timers:schedule: body must be a function")

    -- Cancel any prior arm in this slot first.  Both the internal
    -- map and the plugin-side mirror must clear, or a later
    -- `cancel_all` would unschedule the new action twice.
    self:cancel(slot)

    local action
    action = function()
        -- Self-unregister BEFORE running.  Two reasons:
        --   (a) so the body can re-schedule the same slot without
        --       cancelling itself,
        --   (b) so `plugin[slot]` reads as nil during body execution,
        --       which matches the contract callers like
        --       `_debouncedScan` rely on (it tests the slot field to
        --       know whether a scan is pending).
        if self._slots[slot] == action then
            self._slots[slot] = nil
            self._plugin[slot] = nil
        end

        -- Destroyed gate: skip if the plugin has been torn down
        -- between the arm and the fire.  Same semantics as the
        -- legacy inline _schedule.
        if self._plugin.destroyed then return end

        local ok, err = pcall(body)
        if not ok then
            self._logger.warn("Syncery: scheduled task ("
                .. slot .. ") failed: " .. tostring(err))
        end
    end

    self._slots[slot]  = action
    self._plugin[slot] = action  -- legacy field-check compatibility
    self._ui_manager:scheduleIn(delay, action)
end


-- ----------------------------------------------------------------------------
-- cancel — drop one slot's arm if present.  No-op when nothing is
-- scheduled.  Both the internal map and the plugin-side mirror must
-- clear (the plugin mirror is what legacy call sites read).
-- ----------------------------------------------------------------------------


--- Cancel the timer in `slot` if armed.
--- @param slot string
function Timers:cancel(slot)
    local action = self._slots[slot]
    if action then
        self._ui_manager:unschedule(action)
        self._slots[slot]  = nil
        self._plugin[slot] = nil
    end
end


-- ----------------------------------------------------------------------------
-- cancel_all — drop every known slot.  Called from `_flushPersistedState`
-- as part of teardown, and as the final step of every lifecycle event.
-- Iterates the static SLOTS list rather than `self._slots` so unknown
-- "rogue" entries on the plugin (set by something other than this
-- module) also get cleared — defensive against the legacy code's habit
-- of stashing UIManager actions on `self` ad-hoc.
-- ----------------------------------------------------------------------------


--- Cancel every scheduled timer.  Idempotent.
function Timers:cancel_all()
    for _, slot in ipairs(Timers.SLOTS) do
        self:cancel(slot)
    end
end


-- ----------------------------------------------------------------------------
-- is_armed — testing hook + a sometimes-useful predicate.  The legacy
-- code checks the plugin field directly (`if self._debounce_scan_action
-- then ...`); this method is the same thing, scoped to the module so
-- tests don't reach into the plugin's private fields.
-- ----------------------------------------------------------------------------


--- Return true iff `slot` is currently armed.
--- @param slot string
--- @return boolean
function Timers:is_armed(slot)
    return self._slots[slot] ~= nil
end


return Timers
