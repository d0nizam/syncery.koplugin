-- =============================================================================
-- syncery_ui/toast_widget.lua
-- =============================================================================
--
-- The shared non-modal bottom toast used by the notification system
-- A bottom-anchored frame holds a message and, OPTIONALLY, a single
-- action
-- Button. With no action it is a plain status toast; with one it is an
-- actionable toast (e.g. "Jumped — Undo", the jump invitation).
--
-- NON-BLOCKING: only the Button (when present) registers a gesture, over its
-- own area, so taps elsewhere fall through to the reader. A button-less toast
-- registers no gesture at all. There is deliberately NO full-screen
-- tap-to-close. Showing, the display spell, dismissal, and the inter-toast
-- gap are all driven by the coordinator in syncery_ui/notify.lua via
-- UIManager — this widget just draws.
--
-- This module require()s real KOReader widgets, so it loads only inside a
-- running KOReader (main.lua wires it as the notification system's `present`;
-- no spec requires it). Its on-device rendering/positioning is NOT exercised
-- by the headless test matrix.
-- =============================================================================


local Blitbuffer      = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Button          = require("ui/widget/button")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")

local Screen = Device.screen


local ToastWidget = InputContainer:extend{
    text         = nil,
    action_label = nil,   -- nil = no button (plain status toast)
    on_tap       = nil,   -- called when the action button is tapped
}

function ToastWidget:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    local frame_pad = Size.padding.default
    local avail_w   = math.floor(screen_w * 0.92)

    local row = HorizontalGroup:new{ align = "center" }

    local action
    local msg_w = avail_w - (frame_pad * 4)
    if self.action_label and self.on_tap then
        action = Button:new{
            text     = self.action_label,
            radius   = Size.radius.button,
            callback = function() if self.on_tap then self.on_tap() end end,
        }
        local gap = Size.span.horizontal_default
        msg_w = avail_w - action:getSize().w - gap - (frame_pad * 4)
        if msg_w < Size.item.height_default then
            msg_w = math.floor(avail_w * 0.5)
        end
    end

    local message = TextBoxWidget:new{
        text  = self.text,
        face  = Font:getFace("infofont"),
        width = msg_w,
    }
    table.insert(row, message)
    if action then
        table.insert(row, HorizontalSpan:new{ width = Size.span.horizontal_default })
        table.insert(row, action)
    end

    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius     = Size.radius.window,
        padding    = frame_pad,
        margin     = Size.margin.default,
        row,
    }

    self.frame = frame
    -- Bottom-centre the frame; the container spans the screen for layout only
    -- (it consumes no input — only the Button, if any, does).
    self[1] = BottomContainer:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
        frame,
    }
end

-- Region the widget actually occupies, so UIManager refreshes the right area.
function ToastWidget:onShow()
    if self.frame and self.frame.dimen then
        self.dimen = self.frame.dimen
    end
    return true
end


local M = {}

-- Generic factory. spec = { text, action_label?, on_tap? }.
function M.new(spec)
    return ToastWidget:new{
        text         = spec.text,
        action_label = spec.action_label,
        on_tap       = spec.on_tap,
    }
end

-- Adapter for the notification coordinator: present(item, on_tap) -> widget.
-- `item` = { text, action = { label, fn }, ... }; the coordinator passes its
-- own on_tap (which finishes the toast, then runs item.action.fn).
function M.present(item, on_tap)
    return M.new{
        text         = item.text,
        action_label = item.action and item.action.label or nil,
        on_tap       = (item.action and on_tap) or nil,
    }
end

return M
