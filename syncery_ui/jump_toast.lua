-- =============================================================================
-- syncery_ui/jump_toast.lua
-- =============================================================================
--
-- The short "another device moved ahead" invitation MESSAGE.
--
-- When jump_mode is "ask", _promptJump raises a non-blocking invitation.
-- The SHOW/finish control and the actual overlay are owned by the
-- notification coordinator (syncery_ui/notify.lua) and the shared toast widget
-- (syncery_ui/toast_widget.lua) respectively; this module is now just the
-- pure message + action label that the invite carries. Keeping it separate
-- keeps the wording (and its Bulgarian translations) unit-testable.
--
-- Strings via _(); Bulgarian lives in locale/bg.po.
-- =============================================================================


local I18n = require("syncery_i18n")
local _    = I18n.translate


local JumpToast = {}


-- A short one-line invitation. `opts`:
--   remote_label  string|nil  device name (defaults to "Another device")
--   percent       number|nil  fraction 0..1 -- the cross-device-stable unit
--   chapter       string|nil  resolved chapter title (from the shared font-
--                             independent xpointer); shown only alongside
--                             percent, as the human anchor
--   page          number|nil  a FIXED page number -- only for paging docs
--                             (PDF/CBZ), where pages coincide across devices
--
-- The remote device's stored PAGE is device-LOCAL for reflowable books (each
-- device re-lays-out the text with its own font/screen), so it is never shown
-- for them -- the caller passes `percent` (+ resolved `chapter`) instead, and
-- passes `page` only for paging docs whose pages are identical everywhere.
function JumpToast.message(opts)
    opts = opts or {}
    local label = opts.remote_label or _("Another device")
    -- Reflowable (EPUB): percent is comparable across devices; the resolved
    -- chapter is the meaningful anchor when available.
    if type(opts.percent) == "number" then
        local pct = math.floor(opts.percent * 100 + 0.5)
        if type(opts.chapter) == "string" and opts.chapter ~= "" then
            return string.format(_("%s is at %d%% — %s"), label, pct, opts.chapter)
        end
        return string.format(_("%s is at %d%%"), label, pct)
    -- Paging (PDF/CBZ): the page is fixed across devices, so it is the natural
    -- stable unit; the caller passes it only for these docs.
    elseif type(opts.page) == "number" then
        return string.format(_("%s is on page %d"), label, opts.page)
    end
    return string.format(_("%s is at a new position"), label)
end


-- The action button label.
function JumpToast.actionLabel()
    return _("Jump")
end


return JumpToast
