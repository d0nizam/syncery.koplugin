-- =============================================================================
-- spec/status_ui_spec.lua
-- =============================================================================
--
-- Tests for syncery_ui/status_ui/init.lua — the Sync Status detail
-- view + Jump-to-device picker, split out of syncery_ui.lua in Phase 6.
--
-- Covers:
--   * StatusUI.show: "No document open" when getCurrentState is nil.
--   * StatusUI.show: renders a TextViewer with the book title + page line.
--   * StatusUI.show: "Jump to device…" button appears only with other
--     devices present.
--   * StatusUI.show: device-list truncation past STATUS_MAX_VISIBLE
--     and the "Show all" button.
--   * StatusUI.showJumpDialog: builds one row per other device.
--   * Timezone-safety of the moved `_get_time_ago` formatter.
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_status_ui_spec_" .. tostring(os.time()))


-- ---------------------------------------------------------------------------
-- Stubs
-- ---------------------------------------------------------------------------

local shown = {}        -- every UIManager:show() arg
local function reset_shown() for k in pairs(shown) do shown[k] = nil end end

local function recording_widget()
    return {
        new = function(_, args)
            local rec = args or {}
            rec._is_widget = true
            return rec
        end,
    }
end

package.loaded["ui/uimanager"] = {
    show  = function(_, w) table.insert(shown, w) end,
    close = function() end,
}
package.loaded["ui/widget/textviewer"]  = recording_widget()
package.loaded["ui/widget/infomessage"] = recording_widget()
package.loaded["ui/widget/menu"]        = recording_widget()
package.loaded["ui/widget/confirmbox"]  = recording_widget()
package.loaded["device"] = {
    screen = { getWidth = function() return 600 end,
               getHeight = function() return 800 end },
}
package.loaded["syncery_i18n"] = {
    translate = function(s) return s end,
    ngettext  = function(s, p, n) if n == 1 then return s else return p end end,
}
package.loaded["syncery_util"] = {
    get_device_label = function() return "TestDevice" end,
    get_device_id    = function() return "dev1" end,
}
package.loaded["util"] = { utf8sub = function(s, a, b) return s:sub(a, b) end }


-- Fake progress engine.  The spec drives StatusUI rendering directly
-- by handing it the device map; the real state store is exercised by
-- its own spec.
local fake_shared = { entries = {} }
package.loaded["syncery_progress/state_store"] = {
    load_shared = function() return fake_shared end,
}
package.loaded["syncery_progress/progress_bridge"] = {
    -- Identity filter — the freshness window is the bridge's own
    -- concern and has its own spec; here we want every device shown.
    filter_fresh_for_display = function(entries) return entries end,
}

-- Action bar: capture every ActionBar.show so the manual-jump confirmation
-- can be asserted (it replaced first a blocking InfoMessage, then a blocking
-- toast -- now a non-blocking bottom bar). Stubbed because the real module
-- pulls in live KOReader widgets.
local bars = {}
local function reset_bars() for k in pairs(bars) do bars[k] = nil end end
package.loaded["syncery_ui/action_bar"] = {
    show = function(ui, spec) table.insert(bars, { ui = ui, spec = spec }) end,
}


local StatusUI = require("syncery_ui/status_ui/init")


-- ---------------------------------------------------------------------------
-- Fake plugin
-- ---------------------------------------------------------------------------

local function make_plugin(opts)
    opts = opts or {}
    return {
        destroyed    = false,
        device_id    = "dev1",
        device_label = "TestDevice",
        getCurrentState = function() return opts.state end,
        getBookTitle    = function() return opts.title or "Some Book" end,
        _doJump   = function() end,
        _schedule = function() end,
        _save     = function() end,
    }
end


-- ---------------------------------------------------------------------------
-- show — no document open
-- ---------------------------------------------------------------------------

do
    reset_shown()
    local plugin = make_plugin{ state = nil }
    StatusUI.show(plugin)
    h.assert_equal(#shown, 1, "show: one widget shown when no document")
    h.assert_true(shown[1].text ~= nil and shown[1].text:find("No document") ~= nil,
        "show: the widget is the 'No document open' message")
end


-- ---------------------------------------------------------------------------
-- show — renders the status TextViewer
-- ---------------------------------------------------------------------------

do
    reset_shown()
    fake_shared.entries = {
        dev1 = { percent = 0.42, page = 42, timestamp = os.time() - 120,
                 label = "TestDevice", file = "/books/x.epub" },
    }
    local plugin = make_plugin{
        state = { file = "/books/x.epub", page = 42, total_pages = 100,
                  percent = 0.42, is_rolling = false },
        title = "Moby Dick",
    }
    StatusUI.show(plugin)
    h.assert_equal(#shown, 1, "show: one TextViewer shown")
    local v = shown[1]
    h.assert_true(v.text:find("Moby Dick") ~= nil,
        "show: viewer text includes the book title")
    h.assert_true(v.text:find("Page 42 of 100") ~= nil,
        "show: viewer text includes the page line")
    h.assert_true(v.buttons_table ~= nil,
        "show: viewer has a buttons_table")
    -- Only "Close" — no other devices, so no "Jump to device…".
    local found_jump = false
    for _, b in ipairs(v.buttons_table[1]) do
        if b.text:find("Jump") then found_jump = true end
    end
    h.assert_false(found_jump,
        "show: no 'Jump to device…' button when this is the only device")
end


-- ---------------------------------------------------------------------------
-- show — "Jump to device…" appears with other devices
-- ---------------------------------------------------------------------------

do
    reset_shown()
    fake_shared.entries = {
        dev1 = { percent = 0.42, page = 42, timestamp = os.time() - 120,
                 label = "TestDevice" },
        dev2 = { percent = 0.71, page = 71, timestamp = os.time() - 60,
                 label = "Phone" },
    }
    local plugin = make_plugin{
        state = { file = "/books/x.epub", page = 42, total_pages = 100,
                  percent = 0.42 },
    }
    StatusUI.show(plugin)
    local v = shown[1]
    local found_jump = false
    for _, b in ipairs(v.buttons_table[1]) do
        if b.text:find("Jump") then found_jump = true end
    end
    h.assert_true(found_jump,
        "show: 'Jump to device…' button present with another device")
    h.assert_true(v.text:find("Phone") ~= nil,
        "show: the other device's label is rendered")
end


-- ---------------------------------------------------------------------------
-- show — truncation past STATUS_MAX_VISIBLE_DEVICES (4)
-- ---------------------------------------------------------------------------

do
    reset_shown()
    fake_shared.entries = { dev1 = { percent = 0.1, page = 1,
                                     timestamp = os.time(), label = "Me" } }
    for i = 2, 8 do
        fake_shared.entries["dev" .. i] = {
            percent = 0.1 * i, page = i, timestamp = os.time() - i,
            label = "Device" .. i,
        }
    end
    local plugin = make_plugin{
        state = { file = "/books/x.epub", page = 1, total_pages = 100,
                  percent = 0.1 },
    }
    StatusUI.show(plugin)
    local v = shown[1]
    h.assert_true(v.text:find("more") ~= nil,
        "show: '… and N more' appears past the visible-device cap")
    local found_show_all = false
    for _, b in ipairs(v.buttons_table[1]) do
        if b.text:find("Show all") then found_show_all = true end
    end
    h.assert_true(found_show_all,
        "show: 'Show all' button present when truncated")
end


-- ---------------------------------------------------------------------------
-- showJumpDialog — one row per other device
-- ---------------------------------------------------------------------------

do
    reset_shown()
    local plugin = make_plugin{
        state = { file = "/books/x.epub", page = 1, total_pages = 100 },
    }
    local others = {
        { id = "dev2", entry = { percent = 0.5, page = 50,
                                 timestamp = os.time(), label = "Phone" } },
        { id = "dev3", entry = { percent = 0.9, page = 90,
                                 timestamp = os.time(), label = "Tablet" } },
    }
    StatusUI.showJumpDialog(plugin, plugin.getCurrentState(), others)
    h.assert_equal(#shown, 1, "showJumpDialog: one Menu shown")
    local m = shown[1]
    h.assert_equal(#m.item_table, 2,
        "showJumpDialog: one row per other device")
    h.assert_true(m.item_table[1].text:find("Phone") ~= nil,
        "showJumpDialog: first row labels the first device")
end


-- Manual jump from "Show device status" bypasses jump_mode="never": tapping a
-- device row always calls _doJump directly (it never routes through the
-- _promptJump "never" gate), so the explicit pull stays available even when
-- automatic jumps are off.
do
    reset_shown()
    local jumped = false
    local plugin = make_plugin{
        state = { file = "/books/x.epub", page = 1, total_pages = 100 },
    }
    plugin.jump_mode = "never"
    plugin._doJump   = function() jumped = true end
    local others = {
        { id = "dev2", entry = { percent = 0.5, page = 50,
                                 timestamp = os.time(), label = "Phone" } },
    }
    StatusUI.showJumpDialog(plugin, plugin.getCurrentState(), others)
    shown[1].item_table[1].callback()
    h.assert_true(jumped,
        "manual status-panel jump calls _doJump even when jump_mode='never'")
end


-- The manual pull confirms with the same non-blocking bottom action bar as
-- auto/ask, carrying an [Undo] button -- not a blocking InfoMessage or toast.
do
    reset_shown()
    reset_bars()
    local plugin = make_plugin{
        state = { file = "/books/x.epub", page = 1, total_pages = 100 },
    }
    local others = {
        { id = "dev2", entry = { percent = 0.5, page = 50,
                                 timestamp = os.time(), label = "Phone" } },
    }
    StatusUI.showJumpDialog(plugin, plugin.getCurrentState(), others)
    shown[1].item_table[1].callback()

    h.assert_equal(#bars, 1,
        "manual jump confirms via exactly one action bar")
    local bar = (bars[1] and bars[1].spec) or {}
    h.assert_true(type(bar.text) == "string"
        and bar.text:find("Jumped to position from", 1, true) ~= nil,
        "manual jump bar names the source device")
    h.assert_true(bar.button_label ~= nil
        and type(bar.on_action) == "function",
        "manual jump bar carries an [Undo] button with a handler")

    -- No blocking InfoMessage is shown for the jump confirmation any more.
    local infomsg_shown = false
    for _, w in ipairs(shown) do
        if w.text and tostring(w.text):find("Jumped to position from", 1, true) then
            infomsg_shown = true
        end
    end
    h.assert_true(not infomsg_shown,
        "manual jump no longer shows a blocking InfoMessage")
end


-- ---------------------------------------------------------------------------
-- _get_time_ago — timezone-safe formatter
-- ---------------------------------------------------------------------------

do
    h.assert_equal(StatusUI._get_time_ago(nil), "never",
        "_get_time_ago: nil → 'never'")
    h.assert_equal(StatusUI._get_time_ago(os.time() - 10), "just now",
        "_get_time_ago: <60s → 'just now'")
    h.assert_equal(StatusUI._get_time_ago(os.time() - 300), "5 min ago",
        "_get_time_ago: 5 minutes → '5 min ago'")
    h.assert_equal(StatusUI._get_time_ago(os.time() - 7200), "2 hr ago",
        "_get_time_ago: 2 hours → '2 hr ago'")
    -- The relative-time branches use os.difftime on two epoch values,
    -- so they are timezone-independent.  This is the assertion the
    -- 7-timezone matrix is verifying does not drift.
end


-- ---------------------------------------------------------------------------
-- _get_progress_bar — clamps and fills
-- ---------------------------------------------------------------------------

do
    local full = StatusUI._get_progress_bar(1.0, 10)
    h.assert_equal(full, string.rep("█", 10),
        "_get_progress_bar: 100% → all filled")
    local empty = StatusUI._get_progress_bar(0.0, 10)
    h.assert_equal(empty, string.rep("░", 10),
        "_get_progress_bar: 0% → all empty")
    local over = StatusUI._get_progress_bar(5.0, 10)
    h.assert_equal(over, string.rep("█", 10),
        "_get_progress_bar: >100% clamps to full")
end


h.teardown()
