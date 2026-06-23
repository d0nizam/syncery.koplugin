-- =============================================================================
-- syncery_ui/status_ui/init.lua
-- =============================================================================
--
-- The Sync Status detail view and the Jump-to-device picker.
--
-- The manual device-jump in `showJumpDialog` confirms via the same
-- non-blocking action bar (with [Undo]) as the auto/ask jumps.  The
-- three text helpers (`truncate_label`, `get_progress_bar`,
-- `get_time_ago`) live here because they are only used here.
--
-- PUBLIC SURFACE
--
--   StatusUI.show(plugin, show_all)            — the status TextViewer
--   StatusUI.showJumpDialog(plugin, state, others)
--                                              — the device picker Menu
--
-- The `syncery_ui.lua` shim re-exports both, so `main.lua`'s
-- `showSyncStatus` / `_promptJump` reach them through it.
--
-- TIMEZONE NOTE
--
-- `get_time_ago` formats "N min ago" / "N hr ago" from an *epoch
-- difference* (`os.difftime(os.time(), ts)`).  Both arguments are
-- absolute epoch seconds, so the result is timezone-independent — the
-- only `os.date` call uses "%Y-%m-%d" for the >24h fallback, which is
-- intentionally local-date (the user wants to see "2024-03-15" in
-- their own calendar).  The 8-timezone test matrix exercises this.
--
-- =============================================================================


local UIManager   = require("ui/uimanager")
local TextViewer  = require("ui/widget/textviewer")
local InfoMessage = require("ui/widget/infomessage")
local Menu        = require("ui/widget/menu")
local Screen      = require("device").screen

local I18n        = require("syncery_i18n")
local _           = I18n.translate
local Util        = require("syncery_util")
local ActionBar   = require("syncery_ui/action_bar")

-- New progress engine: state store gives us the shared file, the bridge
-- gives us the view-only freshness filter for "is this device worth
-- showing on the status panel".
local ProgressStateStore = require("syncery_progress/state_store")
local ProgressBridge     = require("syncery_progress/progress_bridge")


local StatusUI = {}


-- ============================================================================
-- Text helpers (no other caller)
-- ============================================================================


local function truncate_label(s, max_bytes)
    if not s or max_bytes <= 0 then return "" end
    local ok_util, util = pcall(require, "util")
    if ok_util and util.utf8sub then
        return util.utf8sub(s, 1, max_bytes)
    end
    -- Fallback: raw string (should never happen on KOReader)
    return s
end


local STATUS_MAX_VISIBLE_DEVICES = 4


local function get_progress_bar(percent, width)
    width   = width or 20
    percent = math.max(0, math.min(1, percent or 0))
    local filled = math.floor(percent * width + 0.5)
    return string.rep("█", filled) .. string.rep("░", width - filled)
end


local function get_time_ago(timestamp)
    if not timestamp then return _("never") end
    local ago = os.difftime(os.time(), timestamp)
    if ago < 60    then return _("just now") end
    if ago < 3600  then return string.format(_("%d min ago"), math.floor(ago / 60)) end
    if ago < 86400 then return string.format(_("%d hr ago"),  math.floor(ago / 3600)) end
    return os.date("%Y-%m-%d", timestamp)
end


-- Exposed for the status_panel module + specs.  They are the same
-- formatters the panel uses for its "last sync N min ago" rows, so
-- there is exactly one timezone-safe implementation.
StatusUI._truncate_label   = truncate_label
StatusUI._get_progress_bar = get_progress_bar
StatusUI._get_time_ago     = get_time_ago


-- ============================================================================
-- StatusUI.show — the Sync Status detail TextViewer
-- ============================================================================


function StatusUI.show(plugin, show_all)
    if plugin._status_viewer then
        UIManager:close(plugin._status_viewer)
        plugin._status_viewer = nil
    end
    if plugin.destroyed then return end

    local state = plugin:getCurrentState()
    if not state then
        UIManager:show(InfoMessage:new{ text = _("No document open") })
        return
    end

    -- Load the shared progress state.  The new schema wraps entries
    -- under `.entries`; the freshness filter (view-only — never
    -- modifies the file) hides devices that haven't reported in
    -- recently so the status panel stays focused on what's relevant.
    local shared = ProgressStateStore.load_shared(state.file)
    -- The freshness window is user-configurable (`progress_freshness_days`);
    -- nil falls back to the bridge default.
    local entries = ProgressBridge.filter_fresh_for_display(
        shared.entries, plugin.progress_freshness_days)
    local my_entry = entries[plugin.device_id]
        -- Even when our own entry is "stale" (we've been off this book
        -- for >90 days), we still want to show our row.  Pull it
        -- straight from the unfiltered shared map as a fallback.
        or shared.entries[plugin.device_id]
    local last_saved = get_time_ago(my_entry and my_entry.timestamp)

    local lines = {}
    table.insert(lines, plugin:getBookTitle())
    local pct_str = state.percent and string.format(" (%d%%)", math.floor(state.percent * 100 + 0.5)) or ""
    table.insert(lines, string.format(_("Page %d of %d%s"),
        state.page, state.total_pages, pct_str))
    table.insert(lines, "")

    local me_label = truncate_label(plugin.device_label or Util.get_device_label(), 50) or _("This device")
    table.insert(lines, "  " .. _("This device: ") .. me_label .. "  \u{00B7}  " .. last_saved)
    local bar_str
    if state.percent then
        bar_str = get_progress_bar(state.percent, 20)
        pct_str = string.format("%d%%", math.floor(state.percent * 100 + 0.5))
    else
        bar_str = "?" .. string.rep(" ", 19)
        pct_str = "?"
    end
    table.insert(lines, string.format("    %s  %s", bar_str, pct_str))
    table.insert(lines, "")

    -- Other devices, newest-first
    local others = {}
    for dev_id, entry in pairs(entries) do
        if dev_id ~= plugin.device_id and type(entry) == "table" and entry.percent then
            table.insert(others, { id = dev_id, entry = entry })
        end
    end
    table.sort(others, function(a, b)
        return (a.entry.timestamp or 0) > (b.entry.timestamp or 0)
    end)

    local visible_count = #others
    local truncated = false
    if not show_all and #others > STATUS_MAX_VISIBLE_DEVICES then
        visible_count = STATUS_MAX_VISIBLE_DEVICES
        truncated = true
    end

    if #others == 0 then
        table.insert(lines, _("No other devices seen for this book."))
    else
        table.insert(lines, _("Other devices:"))
        for i = 1, visible_count do
            local o  = others[i]
            local ep = o.entry.percent or 0
            local label = truncate_label(o.entry.label, 50) or _("Unknown")
            table.insert(lines, "  " .. label .. "  \u{00B7}  " .. get_time_ago(o.entry.timestamp))
            table.insert(lines, string.format("    %s  %d%%",
                get_progress_bar(ep, 20), math.floor(ep * 100 + 0.5)))
        end
        if truncated then
            table.insert(lines, "\n" .. string.format(_("… and %d more"),
                #others - visible_count))
        end
    end

    local buttons = {}

    if #others > 0 then
        table.insert(buttons, {
            text = _("Jump to device…"),
            callback = function()
                UIManager:close(plugin._status_viewer)
                plugin._status_viewer = nil
                StatusUI.showJumpDialog(plugin, state, others)
            end
        })
    end

    if show_all then
        table.insert(buttons, {
            text = _("Show fewer"),
            callback = function()
                UIManager:close(plugin._status_viewer)
                plugin._status_viewer = nil
                StatusUI.show(plugin, false)
            end
        })
    elseif truncated then
        table.insert(buttons, {
            text = _("Show all"),
            callback = function()
                UIManager:close(plugin._status_viewer)
                plugin._status_viewer = nil
                StatusUI.show(plugin, true)
            end
        })
    end

    table.insert(buttons, {
        text = _("Close"),
        callback = function()
            UIManager:close(plugin._status_viewer)
            plugin._status_viewer = nil
        end
    })

    plugin._status_viewer = TextViewer:new{
        title         = _("Syncery Status"),
        text          = table.concat(lines, "\n"),
        buttons_table = { buttons },
    }
    UIManager:show(plugin._status_viewer)
end


-- ============================================================================
-- StatusUI.showJumpDialog — the device picker Menu
-- ============================================================================


function StatusUI.showJumpDialog(plugin, state, others)
    if plugin._jump_picker then
        UIManager:close(plugin._jump_picker)
        plugin._jump_picker = nil
    end

    local items = {}
    for __, o in ipairs(others) do
        local entry = o.entry
        local label = truncate_label(entry.label, 50) or _("Unknown")
        -- Reflowable books (xpath present) re-paginate per device, so the stored
        -- page is device-local -- show percent + the chapter resolved from the
        -- shared xpointer instead.  Paging docs (PDF) carry no xpath and a fixed
        -- page, which is the natural unit there.
        local pct      = string.format("%d%%", math.floor((entry.percent or 0) * 100 + 0.5))
        local time_ago = get_time_ago(entry.timestamp)
        local row_text
        if type(entry.xpath) == "string" and entry.xpath ~= "" then
            -- EPUB: percent + the chapter resolved from the shared xpointer when
            -- available (the page is device-local for reflowable books).
            local chapter = plugin:_resolveChapter(entry.xpath)
            if chapter then
                row_text = string.format("%s  (%s, %s, %s)", label, pct, chapter, time_ago)
            else
                row_text = string.format("%s  (%s, %s)", label, pct, time_ago)
            end
        else
            -- PDF: the page is identical across devices, so it is shown too.
            row_text = string.format("%s  (page %s, %s, %s)",
                label, tostring(entry.page or "?"), pct, time_ago)
        end
        table.insert(items, {
            text = row_text,
            callback = function()
                UIManager:close(plugin._jump_picker)
                plugin._jump_picker = nil
                plugin:_doJump(state, entry.page, entry.percent, entry.xpath)
                plugin:_schedule("_autosave_action", 0.5, function()
                    plugin:_save({ silent = true, trigger_sync = false, force = true })
                end)
                -- Confirm the manual pull with the same non-blocking bottom
                -- action bar as the auto/ask jumps (syncery_ui/action_bar.lua)
                -- -- an [Undo] button so the reader can step back within the
                -- undo window (pre_jump_until) while still paging freely.
                ActionBar.show(plugin.ui, {
                    text         = _("Jumped to position from ") .. label,
                    button_label = _("Undo"),
                    on_action    = function() plugin:_undoLastJump() end,
                    seconds      = 12,
                })
            end
        })
    end

    plugin._jump_picker = Menu:new{
        title  = _("Jump to device"),
        item_table = items,
        width  = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    local menu_ref = plugin._jump_picker
    function menu_ref:onClose()
        UIManager:close(self)
        plugin._jump_picker = nil
        return true
    end
    UIManager:show(plugin._jump_picker)
end


return StatusUI
