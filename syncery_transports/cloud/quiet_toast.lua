-- =============================================================================
-- syncery_transports/cloud/quiet_toast.lua
-- =============================================================================
--
-- Suppresses the ONE "Successfully synchronized." toast that the cloud
-- backends pop on every successful sync.
--
-- WHY THIS EXISTS (verified against KOReader source)
-- --------------------------------------------------
-- Both cloud backends — the "Cloud storage+" plugin (`Cloud:sync`, the former
-- SyncService, koreader#9709) and the built-in standalone
-- `apps/cloudstorage/syncservice` (`SyncService.sync`) — finish a successful
-- sync with:
--
--     UIManager:show(Notification:new{ text = _("Successfully synchronized."),
--                                      timeout = 2 })
--
-- That call goes through `UIManager:show` DIRECTLY, bypassing the maskable
-- `Notification:notify` path — so the global `notification_sources_to_show_mask`
-- setting does NOT gate it, and the `is_silent` argument those backends accept
-- gates only the FAILURE InfoMessages, never this success toast.  There is no
-- parameter that silences it.  Syncery syncs opportunistically on book close;
-- a toast every close is noise, so we intercept the one string.
--
-- DESIGN — a window-checked, transparent filter over UIManager:show
-- ----------------------------------------------------------------
-- `suppress(grace)` installs (once) a thin wrapper around `UIManager.show`.
-- The wrapper swallows a widget ONLY when BOTH hold:
--     * we are inside an active suppression window (clock < suppress_until), and
--     * the widget's text equals the exact success string.
-- Every other widget — and that same string outside a window — passes through
-- to the original `show` UNCHANGED.  A provider calls `suppress(grace)` just
-- before dispatching its sync; the toast fires within `grace` seconds and is
-- swallowed.
--
-- This is deliberately chosen over a save/restore monkeypatch: there is no
-- restore that can fail or fire too early relative to the async, possibly
-- network-deferred sync, and overlapping syncs simply extend the window.  As
-- hygiene the wrapper still un-installs itself once the window lapses (a single
-- self-rescheduling check), but correctness does NOT depend on that — the
-- clock check keeps the wrapper transparent even if it lingers.  Because only
-- the exact success string is ever swallowed (and only that string, only right
-- after we triggered a sync), the worst conceivable side effect is one
-- suppressed toast; no other UI is ever affected.
--
-- The success string is resolved through the GLOBAL gettext (the same module
-- the backends use, so the translated text matches at runtime) and NOT through
-- Syncery's own `_` alias, so it never enters Syncery's translation catalog
-- (the i18n extractor scans only `_(`/`_n(` calls).
--
-- Headless / unsupported (no UIManager or gettext, e.g. a test harness):
-- `suppress` is a no-op returning false and the sync runs normally.
-- =============================================================================

local M = {}

-- The exact msgid both backends show on success.  Looked up via the global
-- gettext at runtime (see header) — intentionally NOT an `_("...")` call.
local SUCCESS_MSGID = "Successfully synchronized."

-- Overridable clock (seconds).  Tests inject a controllable one; production
-- uses os.time (1 s resolution is ample for a multi-second window).
M._clock = os.time

-- Module-level wrapper state.  Persists for the session: the wrapper is
-- installed at most once and stays transparent outside suppression windows.
local installed       = false
local suppress_until  = 0
local target          = nil   -- cached translated success string

-- Resolve UIManager + the translated success string, or nil if we cannot
-- safely intercept (missing module, or a stub lacking the methods we need).
local function resolve()
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if not ok_ui or type(UIManager) ~= "table"
       or type(UIManager.show) ~= "function"
       or type(UIManager.scheduleIn) ~= "function" then
        return nil
    end
    if target == nil then
        local ok_gt, Gettext = pcall(require, "gettext")
        if not ok_gt or Gettext == nil then return nil end
        -- Gettext may be a function or a callable table; pcall handles both.
        local ok_t, t = pcall(Gettext, SUCCESS_MSGID)
        if not ok_t or type(t) ~= "string" then return nil end
        target = t
    end
    return UIManager
end

--- Open (or extend) a window during which the single "Successfully
--- synchronized." toast is swallowed.  Call right before dispatching a cloud
--- sync.  Returns true when interception is active, false when headless.
---@param grace_seconds number|nil  window length (default 60 s)
function M.suppress(grace_seconds)
    local UIManager = resolve()
    if not UIManager then return false end

    suppress_until = M._clock() + (grace_seconds or 60)

    if not installed then
        local orig_show = UIManager.show
        local wrapper
        wrapper = function(self, widget, ...)
            if M._clock() < suppress_until
               and type(widget) == "table" and widget.text == target then
                return  -- inside a window + the one success toast → swallow
            end
            return orig_show(self, widget, ...)
        end
        UIManager.show = wrapper
        installed = true

        -- Hygiene: drop the wrapper once the window lapses.  Re-checks (and
        -- re-schedules) if another suppress() extended the window meanwhile.
        -- Correctness does not rely on this firing — the clock check above
        -- already makes the wrapper transparent outside the window.
        local function check_restore()
            local remaining = suppress_until - M._clock()
            if remaining > 0 then
                UIManager:scheduleIn(remaining, check_restore)
            elseif UIManager.show == wrapper then
                UIManager.show = orig_show
                installed = false
            else
                -- Someone re-patched show on top of us; leave it alone.
                installed = false
            end
        end
        UIManager:scheduleIn(grace_seconds or 60, check_restore)
    end

    return true
end

-- Test-only: reset module state so a spec starts from a clean slate.
function M._reset()
    installed      = false
    suppress_until = 0
    target         = nil
end

return M
