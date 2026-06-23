-- =============================================================================
-- syncery_ui/notify.lua
-- =============================================================================
--
-- Notification tiers + an e-ink-friendly toast queue.
--
-- Until now every notification was a modal InfoMessage. This module gives the
-- plugin a small, deliberate taxonomy:
--
--   L1 (silent)   — log only, no UI. For routine, expected events the user
--                   does not need to be interrupted for (e.g. "Sync now").
--   L2 (toast)    — a brief, NON-blocking bottom toast, optionally with a
--                   single action button. For confirmations the user should
--                   notice but not have to dismiss (e.g. "Rescan triggered",
--                   the first-run done toast, the auto-jump "Undo" toast, and
--                   the in-reading jump invitation).
--   L3 (modal)    — a blocking dialog the user must answer. For destructive
--                   or consequential actions. Those stay as ConfirmBox /
--                   InfoMessage at their call sites; this module just names
--                   the tier and offers a thin helper.
--
-- E-INK QUEUE: e-ink can't render two toasts at once without ugly overlap, so
-- L2 toasts are SERIALISED — one on screen at a time, each shown for a fixed
-- spell, with a short gap before the next (mirrors the approved mockup's
-- notifyL2 / drainQueue: ~4 s display, ~0.3 s gap, and a broken toast must
-- never stall the queue).
--
-- This file is PURE + dependency-injected: it owns the queue/drain CONTROL
-- (ordering, timing, finish-once, advance-after-gap) but no KOReader widgets.
-- The caller injects a scheduler and present/dismiss hooks; the real bottom
-- toast lives in syncery_ui/toast_widget.lua. A module-level singleton
-- (Notify.configure / Notify.notifyL1 / notifyL2 / notifyInvite) is what call
-- sites use; tests build isolated instances with Notify.new(fake_deps).
--
-- Strings are passed in already-translated by the caller (this module does no
-- i18n itself, so it stays trivially testable).
-- =============================================================================


local Notify = {}
Notify.__index = Notify


-- Mockup contract: display each status toast ~4 s, leave ~0.3 s before the next.
Notify.DISPLAY_SECONDS = 4
Notify.GAP_SECONDS     = 0.3
-- An interactive toast lingers longer than a fire-and-forget status toast.
-- (The notify system still supports one; Syncery's jump invite/undo moved to
-- the non-blocking action bar -- syncery_ui/action_bar.lua -- so nothing
-- currently raises it.)
Notify.INTERACTIVE_SECONDS = 6


-- ---------------------------------------------------------------------------
-- Construct a coordinator. `deps`:
--   scheduleIn(secs, fn) -> task        schedule fn after secs; returns a task
--   unschedule(task)                    cancel a scheduled task
--   present(item, on_tap) -> handle     show the toast; on_tap fires when the
--                                       action button is tapped; returns a
--                                       handle for dismiss()
--   dismiss(handle)                     remove a shown toast
--   log(msg)                            optional; used by L1 (silent) tier
-- ---------------------------------------------------------------------------
function Notify.new(deps)
    return setmetatable({
        deps     = deps or {},
        queue    = {},      -- pending items (FIFO, front = next)
        current  = nil,     -- the item on screen, or nil
        handle   = nil,     -- present() handle for the current item
        timeout  = nil,     -- scheduled auto-dismiss task for the current item
        gap_task = nil,     -- scheduled inter-toast gap drain (off-slot; stop() cancels it)
        finished = false,   -- whether the current item has already been ended
        stopped  = false,   -- teardown latch: once set, a late enqueue is a no-op
    }, Notify)
end


-- --- tiers -------------------------------------------------------------------

-- L1: silent. No UI — just a log line so it's traceable in diagnostics.
function Notify:l1(msg)
    if self.deps.log then pcall(self.deps.log, msg) end
end

-- L2: a queued status toast. `opts` (all optional):
--   action     = { label = "...", fn = function() ... end }
--   on_timeout = function() ... end   (run if it auto-dismisses untapped)
--   seconds    = number               (override display time)
function Notify:l2(text, opts)
    opts = opts or {}
    self:_enqueue({
        text        = text,
        action      = opts.action,
        on_timeout  = opts.on_timeout,
        seconds     = opts.seconds or Notify.DISPLAY_SECONDS,
        interactive = false,
    }, false)
end

-- An interactive L2 toast the user is meant to act on (e.g. the jump
-- invitation). It jumps to the FRONT of the queue (so it isn't buried behind
-- status spam) and lingers longer. `opts`:
--   text, action = { label, fn }, on_timeout, seconds
function Notify:invite(opts)
    opts = opts or {}
    self:_enqueue({
        text        = opts.text,
        action      = opts.action,
        on_timeout  = opts.on_timeout,
        seconds     = opts.seconds or Notify.INTERACTIVE_SECONDS,
        interactive = true,
    }, true)
end


-- --- queue / drain control ---------------------------------------------------

function Notify:_enqueue(item, front)
    if self.stopped then return end
    if front then
        table.insert(self.queue, 1, item)
    else
        self.queue[#self.queue + 1] = item
    end
    if not self.current then self:_showNext() end
end

function Notify:_showNext()
    local item = table.remove(self.queue, 1)
    if not item then
        self.current = nil
        return
    end
    self.current  = item
    self.finished = false

    -- pcall so a broken present() can't stall the queue (mockup's try/catch).
    local ok, handle = pcall(self.deps.present, item, function()
        self:_finish("action")
    end)
    self.handle = ok and handle or nil

    self.timeout = self.deps.scheduleIn(item.seconds, function()
        self:_finish("timeout")
    end)
end

function Notify:_finish(which)
    if self.finished then return end
    self.finished = true

    if self.handle then pcall(self.deps.dismiss, self.handle) end
    self.handle = nil
    if self.timeout then
        pcall(self.deps.unschedule, self.timeout)
        self.timeout = nil
    end

    local item = self.current
    if which == "action" and item and item.action and item.action.fn then
        pcall(item.action.fn)
    elseif which == "timeout" and item and item.on_timeout then
        pcall(item.on_timeout)
    end

    self.current = nil

    -- Leave a gap before the next toast (e-ink can't overlap). If the queue
    -- is empty we simply stop; a later enqueue restarts the drain.  Tracked in
    -- gap_task (overwritten each finish; at most one pending at a time) so a
    -- teardown stop() can cancel it — it's an off-slot timer cancel_all misses.
    if #self.queue > 0 then
        self.gap_task = self.deps.scheduleIn(Notify.GAP_SECONDS, function() self:_showNext() end)
    end
end

-- How many toasts are waiting (excludes the one on screen). For tests/diag.
function Notify:pending()
    return #self.queue
end

-- Teardown: cancel every off-slot scheduled task, drop the on-screen toast,
-- and empty the queue so nothing fires after the document/UI is gone.  notify
-- schedules through its own scheduleIn (UIManager, not Timers.SLOTS), so the
-- lifecycle's cancel_all does NOT reach these timers — this is the explicit
-- hook teardown calls.  The `stopped` latch turns a late enqueue into a no-op
-- rather than letting it restart the drain onto the next screen.  Does NOT run
-- the item's action / on_timeout: a teardown abort is not a user dismissal.
function Notify:stop()
    self.stopped = true
    if self.timeout  then pcall(self.deps.unschedule, self.timeout);  self.timeout  = nil end
    if self.gap_task then pcall(self.deps.unschedule, self.gap_task); self.gap_task = nil end
    if self.handle   then pcall(self.deps.dismiss, self.handle);      self.handle   = nil end
    self.current  = nil
    self.finished = false
    self.queue    = {}
end


-- --- module-level singleton (what call sites use) ----------------------------
--
-- These are deliberately NOT named l1/l2/invite: those are instance methods on
-- the same table, and a same-named module function would overwrite them. Call
-- sites use Notify.notifyL1 / notifyL2 / notifyInvite; tests use instances.

function Notify.configure(deps)
    Notify._default = Notify.new(deps)
    return Notify._default
end

local function default()
    return Notify._default
end

function Notify.notifyL1(msg)
    local d = default(); if d then d:l1(msg) end
end
function Notify.notifyL2(text, opts)
    local d = default(); if d then d:l2(text, opts) end
end
function Notify.notifyInvite(opts)
    local d = default(); if d then d:invite(opts) end
end

-- Module-level teardown for the singleton (call site: lifecycle teardown).
-- Named stopAll, not stop, so it does not collide with the Notify:stop instance
-- method on the same table (mirrors notifyL1/L2/Invite vs l1/l2/invite).
function Notify.stopAll()
    local d = default(); if d then d:stop() end
end


return Notify
