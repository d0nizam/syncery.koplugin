-- =============================================================================
-- syncery_ui/wizard_window.lua
-- =============================================================================
--
-- The coherent first-run wizard window: ONE centred panel whose body is
-- swapped IN PLACE per step (:setStep(desc)) — replacing the old chain of
-- modal ButtonDialogs that closed and reopened on every tap and every toggle.
-- The title sits at the top (wrapping to two lines if long, with a ✕ close and
-- a divider); the body (subtitle + items) sits top-aligned directly under the
-- title; the footer is pinned just below it with Back on the left and the
-- primary action (Next / Done) on the right. The panel is sized to its content
-- (the text is large, so it fills naturally) with only a small gap below — no
-- forced height. The choice/recap steps render here with real Buttons /
-- CheckButtons; the two text steps (API key, device name) are shown by the
-- presenter as a KOReader InputDialog on top (system keyboard handled for us).
--
-- House-style precedent: syncery_ui/toast_widget.lua. Like it, this module
-- require()s real KOReader widgets, so it loads only inside a running KOReader
-- (main.lua wires it into the wizard presenter's env; no spec require()s it).
-- Its on-device rendering/positioning is NOT exercised by the headless matrix
-- — the wizard's logic (syncery_ui/wizard.lua) and the presenter's step->desc
-- mapping ARE (the presenter spec stubs this window).
--
-- `desc` (data only — the presenter builds it, a stub records it):
--   title      string
--   subtitle   string | nil
--   items      array, each one of:
--     { type = "button_row", text, sub, on_tap }           -- transport choice (tap advances)
--     { type = "check_row",  text, sub, checked, on_tap }  -- what-to-sync toggle
--     { type = "note",       title, body }                 -- reassurance box
--     { type = "recap_line", text, sub }                   -- recap line (+ optional note)
--   footer     array of { label, on_tap }                  -- Back (left) / Next|Done (right)
--   on_dismiss function | nil                               -- the title-bar close (✕)
-- =============================================================================


local Blitbuffer      = require("ffi/blitbuffer")
local Button          = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local CheckButton     = require("ui/widget/checkbutton")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TitleBar        = require("ui/widget/titlebar")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")

local Screen = Device.screen

-- Large, readable, consistent type: one size for every title/label, one for
-- every piece of secondary text. Everything wraps — no single-line overflow.
local SZ_TITLE = 22   -- option / checkbox / recap / reassurance titles
local SZ_SUB   = 18   -- subtitles, descriptions, reassurance body


local WizardWindow = InputContainer:extend{
    desc   = nil,    -- current step description (data)
    _shown = false,
    -- We paint an opaque full-screen backdrop (see _build), so tell UIManager
    -- this widget covers the whole screen: it must NOT repaint the menu behind
    -- it (which otherwise shows around the centred panel).
    covers_fullscreen = true,
}

function WizardWindow:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    -- A centred panel sized to its content (big text fills it; only a small
    -- gap remains below). Width is most of the screen.
    self.panel_w  = math.floor(self.screen_w * 0.92)
    self.inner_w  = self.panel_w - 2 * Size.border.window - 2 * Size.padding.large
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    if self.desc then self:_build() end
end


-- Build self[1] (the centred panel) from self.desc. Called on init and on every
-- :setStep — that in-place rebuild is what kills the close/reopen chain.
function WizardWindow:_build()
    local d       = self.desc or {}
    local iw      = self.inner_w
    local vspan   = Size.span.vertical_default
    local fg_soft = Blitbuffer.COLOR_DARK_GRAY
    local sep     = Blitbuffer.COLOR_LIGHT_GRAY

    -- ----- title bar: two-line title + ✕ close + divider -------------------
    local title = TitleBar:new{
        width            = iw,
        title            = d.title or "",
        title_face       = Font:getFace("smalltfont"),
        title_multilines = true,
        align            = "left",
        with_bottom_line = true,
        close_callback   = d.on_dismiss and function() d.on_dismiss() end or nil,
    }

    -- ----- body: subtitle + items (top-aligned below the title) ------------
    local body = VerticalGroup:new{ align = "left" }

    if d.subtitle and #d.subtitle > 0 then
        table.insert(body, TextBoxWidget:new{
            text      = d.subtitle,
            face      = Font:getFace("cfont", SZ_SUB),
            width     = iw,
            alignment = "left",
            fgcolor   = fg_soft,
        })
    end

    -- Rows of the same kind (transport options, the two checkboxes, recap
    -- lines) are separated by a thin divider, as in the mockups; a plain gap
    -- separates the subtitle and the reassurance box.
    local prev_row = false
    for _, it in ipairs(d.items or {}) do
        local is_row = it.type == "button_row" or it.type == "check_row"
                    or it.type == "recap_line"
        if #body > 0 then
            if is_row and prev_row then
                table.insert(body, VerticalSpan:new{ width = math.floor(vspan / 2) })
                table.insert(body, LineWidget:new{
                    dimen = Geom:new{ w = iw, h = Size.line.thin }, background = sep,
                })
                table.insert(body, VerticalSpan:new{ width = math.floor(vspan / 2) })
            else
                table.insert(body, VerticalSpan:new{ width = vspan })
            end
        end

        if it.type == "button_row" then
            table.insert(body, Button:new{
                text                 = it.text,
                width                = iw,
                align                = "left",
                bordersize           = 0,
                margin               = 0,
                text_font_size       = SZ_TITLE,
                avoid_text_truncation = true,
                callback             = it.on_tap,
            })
            if it.sub and #it.sub > 0 then
                table.insert(body, TextBoxWidget:new{
                    text = it.sub, face = Font:getFace("cfont", SZ_SUB),
                    width = iw, alignment = "left", fgcolor = fg_soft,
                })
            end

        elseif it.type == "check_row" then
            table.insert(body, CheckButton:new{
                text          = it.text,
                checked       = it.checked == true,
                width         = iw,
                single_line   = false,
                face          = Font:getFace("cfont", SZ_TITLE),
                checkmark_face = Font:getFace("cfont", SZ_TITLE),
                parent        = self,
                callback      = it.on_tap,
            })
            if it.sub and #it.sub > 0 then
                table.insert(body, TextBoxWidget:new{
                    text = it.sub, face = Font:getFace("cfont", SZ_SUB),
                    width = iw, alignment = "left", fgcolor = fg_soft,
                })
            end

        elseif it.type == "note" then
            local box = VerticalGroup:new{ align = "left" }
            if it.title and #it.title > 0 then
                table.insert(box, TextBoxWidget:new{
                    text = it.title, bold = true, face = Font:getFace("cfont", SZ_TITLE),
                    width = iw - 2 * Size.padding.default, alignment = "left",
                })
                table.insert(box, VerticalSpan:new{ width = math.floor(vspan / 2) })
            end
            table.insert(box, TextBoxWidget:new{
                text = it.body or "", face = Font:getFace("cfont", SZ_SUB),
                width = iw - 2 * Size.padding.default, alignment = "left", fgcolor = fg_soft,
            })
            table.insert(body, FrameContainer:new{
                bordersize = Size.border.thin, radius = Size.radius.button,
                padding = Size.padding.default, box,
            })

        elseif it.type == "recap_line" then
            table.insert(body, TextBoxWidget:new{
                text = it.text, bold = true, face = Font:getFace("cfont", SZ_TITLE),
                width = iw, alignment = "left",
            })
            if it.sub and #it.sub > 0 then
                table.insert(body, TextBoxWidget:new{
                    text = it.sub, face = Font:getFace("cfont", SZ_SUB),
                    width = iw, alignment = "left", fgcolor = fg_soft,
                })
            end
        end
        prev_row = is_row
    end

    -- ----- footer: Back (left) ........ primary (right) --------------------
    local footer
    if d.footer and #d.footer > 0 then
        local btns = {}
        for _, b in ipairs(d.footer) do
            btns[#btns + 1] = Button:new{
                text = b.label, radius = Size.radius.button, callback = b.on_tap,
            }
        end
        local row = HorizontalGroup:new{ align = "center" }
        if #btns == 1 then
            table.insert(row, btns[1])
        else
            -- first to the left edge, last to the right edge, flex between
            local w_first, w_last = 0, 0
            pcall(function() w_first = btns[1]:getSize().w end)
            pcall(function() w_last = btns[#btns]:getSize().w end)
            local flex = math.max(Size.span.horizontal_default, iw - w_first - w_last)
            table.insert(row, btns[1])
            table.insert(row, HorizontalSpan:new{ width = flex })
            table.insert(row, btns[#btns])
        end
        footer = VerticalGroup:new{ align = "left" }
        table.insert(footer, LineWidget:new{
            dimen = Geom:new{ w = iw, h = Size.line.thin }, background = sep,
        })
        table.insert(footer, VerticalSpan:new{ width = vspan })
        table.insert(footer, row)
    end

    -- ----- assemble: title, content top-aligned, footer just below ---------
    -- Sized to content (no forced height): the big text fills the panel and
    -- only a small gap is left below the footer.
    local inner = VerticalGroup:new{ align = "left" }
    table.insert(inner, title)
    table.insert(inner, VerticalSpan:new{ width = vspan })
    table.insert(inner, body)
    if footer then
        table.insert(inner, VerticalSpan:new{ width = vspan })
        table.insert(inner, footer)
    end

    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius     = Size.radius.window,
        padding    = Size.padding.large,
        width      = self.panel_w,
        inner,
    }
    self.frame = frame

    -- An OPAQUE full-screen backdrop (so nothing behind shows through) with the
    -- panel centred on it (both axes), sized to its content.
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding    = 0,
        margin     = 0,
        width      = self.screen_w,
        height     = self.screen_h,
        CenterContainer:new{
            dimen = Geom:new{ w = self.screen_w, h = self.screen_h },
            frame,
        },
    }
end


-- Swap the visible step in place (no close/reopen).
function WizardWindow:setStep(desc)
    self.desc = desc
    self:_build()
    if self._shown then
        -- Flashing full-screen refresh: the opaque backdrop repaints over the
        -- previous (differently-sized) panel, and the flash clears e-ink ghosts
        -- so steps don't pile up on screen.  ("ui" is a non-flashing partial
        -- refresh that leaves the old panel ghosted on e-ink.)
        UIManager:setDirty(self, "flashui")
    end
end

function WizardWindow:onShow()
    self._shown = true
    -- Flash on first paint too: a NEW window is created and shown after the
    -- name-entry InputDialog closes, and UIManager:show's default refresh is
    -- non-flashing -- it would leave the keyboard / previous panel ghosted on
    -- e-ink.  flashui (refresh priority 7) upgrades that first refresh, so the
    -- opaque backdrop repaints the whole screen with a clearing flash.
    UIManager:setDirty(self, "flashui")
    return true
end

function WizardWindow:onCloseWidget()
    self._shown = false
    return true
end


-- ---------------------------------------------------------------------------
-- WizardBackdrop -- a bare opaque full-screen white fill, shown BEHIND the
-- text-step InputDialog (device name / API key).  Those steps are a centred
-- KOReader InputDialog, not a panel in this window; the presenter closes the
-- panel before showing the dialog (one window at a time), and the dialog does
-- not cover the whole screen, so without this the menu behind shows through in
-- the uncovered margins.  This restores the wizard's white background while the
-- system keyboard is up.  It carries NO input: the InputDialog on top owns all
-- interaction; this is purely a paint layer, torn down with the dialog.
--
-- INVARIANT (load-bearing — verified against KOReader inputdialog.lua): the
-- teardown is COMPLETE only because the text-step InputDialog has no
-- `save_callback` and no `add_nav_bar`, so it injects no `id="close"` button.
-- Both tap-outside (`onTap` -> `onCloseDialog`) and hardware Back
-- (`key_events.CloseDialog`) close the dialog ONLY by invoking that "close"
-- button's callback; with none present they are no-ops, so the dialog can be
-- closed ONLY via the presenter's Back / primary buttons — both of which call
-- `close_backdrop()`.  If a future change gives that dialog a `save_callback`
-- (or any "close"-id button), Back / tap-outside would close it WITHOUT
-- `close_backdrop()`, orphaning this full-screen backdrop (an undismissable
-- white screen).  Wire `close_backdrop()` into any such button.
-- ---------------------------------------------------------------------------
local WizardBackdrop = InputContainer:extend{
    covers_fullscreen = true,  -- UIManager must not repaint the menu behind it
}

function WizardBackdrop:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding    = 0,
        margin     = 0,
        width      = sw,
        height     = sh,
        CenterContainer:new{
            dimen = Geom:new{ w = sw, h = sh },
            VerticalGroup:new{},  -- empty: the white frame IS the whole point
        },
    }
end

function WizardBackdrop:onShow()
    -- flashui (refresh priority 7) so the white repaints the whole screen
    -- cleanly on e-ink, mirroring WizardWindow:onShow -- UIManager's default
    -- non-flashing show could otherwise leave the prior panel ghosted behind
    -- the dialog.
    UIManager:setDirty(self, "flashui")
    return true
end


local M = {}

-- Factory: spec = { desc }. The first desc carries the first step; the
-- presenter calls window:setStep(desc) for every subsequent step.
function M.new(spec)
    spec = spec or {}
    return WizardWindow:new{ desc = spec.desc }
end

-- Factory: the bare white full-screen backdrop for the text steps (no args).
function M.new_backdrop()
    return WizardBackdrop:new{}
end

return M
