-- =============================================================================
-- syncery_ui/trash/init.lua
-- =============================================================================
--
-- The Deleted-annotations browser ("Trash Bin").
--
-- This module reads and writes the annotation engine's shared state
-- file directly:
--
--   * deleted annotations are tombstones in the position-keyed
--     `annotations` map (`deleted = true`);
--   * "restore" flips a tombstone back to a live annotation by
--     clearing `deleted` and stamping a fresh `datetime_updated` (UTC
--     string) so the change wins the next 3-way merge.
--
-- PUBLIC SURFACE
--
--   Trash.show(book_file, on_change_callback)  — the Trash Menu
--
-- TIMEZONE NOTE
--
-- `format_age` formats from an epoch difference; tombstone timestamps
-- are UTC datetime strings, so we parse them to epoch via
-- AnnTimeFormat.parse_utc_to_unix first.  No `os.date` formatting here.
--
-- =============================================================================


local UIManager   = require("ui/uimanager")
local TextViewer  = require("ui/widget/textviewer")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox  = require("ui/widget/confirmbox")
local Menu        = require("ui/widget/menu")
local Screen      = require("device").screen

local AnnStateStore = require("syncery_ann/state_store")
local AnnTimeFormat = require("syncery_ann/time_format")
local I18n        = require("syncery_i18n")
local _           = I18n.translate
local _n          = I18n.ngettext
local Util        = require("syncery_util")


local Trash = {}


-- ============================================================================
-- Annotation-store access — thin helpers over the engine's shared file
--
-- These helpers (listDeleted/load/restoreAnnotation) are kept
-- module-local but exposed on `Trash._store`
-- so specs can stub them without touching the engine.
-- ============================================================================


local Store = {}


-- Return the array of tombstones (deleted annotations) in a book's
-- shared annotation file.  The shared file keys annotations by
-- position; we flatten to a list and tag each with its map key so a
-- later restore can find it again.
function Store.list_deleted(book_file)
    local out = {}
    local state = AnnStateStore.load_shared(book_file)
    if not state or type(state.annotations) ~= "table" then
        return out
    end
    for key, ann in pairs(state.annotations) do
        if ann and ann.deleted then
            ann._trash_key = key
            table.insert(out, ann)
        end
    end
    return out
end


-- Load the full shared state (used for the per-device "deleted on"
-- label).  Returns the engine state table.
function Store.load(book_file)
    return AnnStateStore.load_shared(book_file)
end


-- Restore a single tombstone to a live annotation.  `ann_key` is the
-- position key from `list_deleted` (carried on `_trash_key`).  Flips
-- `deleted` off and stamps a fresh UTC `datetime_updated` so the 3-way
-- merge treats the restore as the newest change.
function Store.restore(book_file, ann_key, device_id, device_label)
    if not ann_key then return false end
    local state = AnnStateStore.load_shared(book_file)
    if not state or type(state.annotations) ~= "table" then
        return false
    end
    local ann = state.annotations[ann_key]
    if not ann then return false end

    ann.deleted          = false
    ann.datetime_updated = AnnTimeFormat.now()
    ann.device_id        = device_id
    ann.device_label     = device_label

    return AnnStateStore.save_shared(book_file, state)
        and true or false
end


-- Exposed for specs.
Trash._store = Store


-- ============================================================================
-- Helpers — used only here (no other caller)
-- ============================================================================


local PREVIEW_MAX_CHARS = 60


local function preview_text(ann)
    local body = ann.note or ann.text or ""
    body = body:gsub("[\r\n\t]+", " "):gsub("%s+", " ")
    if #body == 0 then
        return ann.type == "bookmark" and _("(bookmark)") or _("(no text)")
    end
    if #body > PREVIEW_MAX_CHARS then
        body = body:sub(1, PREVIEW_MAX_CHARS - 1) .. "\xe2\x80\xa6"
    end
    return body
end


-- Convert a tombstone's timestamp to an "N units ago" string.  The
-- annotation engine timestamps with UTC datetime strings (datetime_updated,
-- or datetime for the original creation time).
local function deleted_epoch(ann)
    if type(ann.datetime_updated) == "string" and ann.datetime_updated ~= "" then
        return AnnTimeFormat.parse_utc_to_unix(ann.datetime_updated)
    elseif type(ann.datetime) == "string" and ann.datetime ~= "" then
        return AnnTimeFormat.parse_utc_to_unix(ann.datetime)
    end
    return 0
end


local function format_age(ts)
    if not ts or ts <= 0 then return _("unknown time") end
    local age = os.difftime(os.time(), ts)
    if     age < 60    then return _("just now")
    elseif age < 3600  then return string.format(_("%d min ago"),  math.floor(age / 60))
    elseif age < 86400 then return string.format(_("%d hr ago"),   math.floor(age / 3600))
    else                    return string.format(_("%d days ago"), math.floor(age / 86400))
    end
end


local function type_marker(ann)
    if     ann.type == "highlight" then return "[H]"
    elseif ann.type == "note"      then return "[N]"
    elseif ann.type == "bookmark"  then return "[B]"
    else                                return "[?]"
    end
end


-- Exposed for specs.
Trash._preview_text  = preview_text
Trash._format_age    = format_age
Trash._type_marker   = type_marker
Trash._deleted_epoch = deleted_epoch


-- ============================================================================
-- show_detail — the per-annotation detail TextViewer with Restore
-- ============================================================================


local function show_detail(book_file, ann, on_change_callback, refresh)
    local detail_lines = {}
    table.insert(detail_lines, string.format(_("Type: %s"), ann.type or "?"))
    if ann.page    then table.insert(detail_lines, string.format(_("Page: %s"),    tostring(ann.page))) end
    if ann.chapter then table.insert(detail_lines, string.format(_("Chapter: %s"), tostring(ann.chapter))) end
    table.insert(detail_lines, string.format(_("Deleted: %s"), format_age(deleted_epoch(ann))))
    if ann.device_label and ann.device_label ~= "" then
        table.insert(detail_lines, string.format(_("Deleted on: %s"), ann.device_label))
    end
    table.insert(detail_lines, "")
    if ann.text and ann.text ~= "" then
        table.insert(detail_lines, _("Text:"))
        table.insert(detail_lines, ann.text)
        table.insert(detail_lines, "")
    end
    if ann.note and ann.note ~= "" then
        table.insert(detail_lines, _("Note:"))
        table.insert(detail_lines, ann.note)
    end

    local viewer
    viewer = TextViewer:new{
        title  = _("Deleted annotation"),
        text   = table.concat(detail_lines, "\n"),
        buttons_table = {{
            {
                text = _("Close"),
                callback = function() UIManager:close(viewer) end,
            },
            {
                text = _("Restore"),
                callback = function()
                    UIManager:close(viewer)
                    local dev_id    = Util.get_device_id()
                    local dev_label = Util.get_device_label and Util.get_device_label() or nil
                    if Store.restore(book_file, ann._trash_key, dev_id, dev_label) then
                        UIManager:show(InfoMessage:new{
                            text = _("Annotation restored."), timeout = 2,
                        })
                        if on_change_callback then on_change_callback() end
                        refresh()
                    else
                        UIManager:show(InfoMessage:new{
                            icon    = "notice-warning",
                            text    = _("Could not restore annotation."),
                            timeout = 3,
                        })
                    end
                end,
            },
        }},
    }
    UIManager:show(viewer)
end


-- ============================================================================
-- build_item_table — composes the Trash menu rows for the current
-- set of deleted annotations.
-- ============================================================================


local function build_item_table(book_file, on_change_callback, update_menu)
    local deleted = Store.list_deleted(book_file)
    local item_table = {}

    if #deleted == 0 then
        table.insert(item_table, {
            text     = _("Trash is empty \xe2\x80\x94 nothing to restore."),
            callback = function() end,
        })
        return item_table
    end

    -- Bulk restore at the top
    table.insert(item_table, {
        text = string.format(
            _n("Restore all (%d item)", "Restore all (%d items)", #deleted),
            #deleted),
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = string.format(
                    _n("Restore all %d deleted annotation?",
                       "Restore all %d deleted annotations?", #deleted),
                    #deleted),
                ok_text     = _("Restore all"),
                ok_callback = function()
                    local dev_id    = Util.get_device_id()
                    local dev_label = Util.get_device_label and Util.get_device_label() or nil
                    local count     = 0
                    for __, ann in ipairs(deleted) do
                        if Store.restore(book_file, ann._trash_key, dev_id, dev_label) then
                            count = count + 1
                        end
                    end
                    local failed = #deleted - count
                    local msg = string.format(
                        _n("%d annotation restored.",
                           "%d annotations restored.", count), count)
                    if failed > 0 then
                        -- Partial failure (e.g. a stale trash list, or a failed
                        -- store write): the success count alone would silently
                        -- hide it.  Report the shortfall and keep the warning on
                        -- screen until tapped, since the result diverged from
                        -- the "Restore all" intent.  Failed items stay as
                        -- recoverable tombstones (no data loss).
                        msg = msg .. "\n" .. string.format(
                            _n("%d annotation could not be restored.",
                               "%d annotations could not be restored.", failed),
                            failed)
                    end
                    UIManager:show(InfoMessage:new{
                        text    = msg,
                        icon    = failed > 0 and "notice-warning" or nil,
                        timeout = failed > 0 and nil or 2,
                    })
                    if on_change_callback then on_change_callback() end
                    update_menu()
                end,
            })
        end,
    })

    for __, ann in ipairs(deleted) do
        local who = ""
        if ann.device_label and ann.device_label ~= "" then
            who = " \xe2\x80\x94 " .. ann.device_label
        end
        local row = string.format("%s  %s  (%s%s)",
            type_marker(ann), preview_text(ann),
            format_age(deleted_epoch(ann)), who)
        local ann_ref = ann
        table.insert(item_table, {
            text = row,
            callback = function()
                show_detail(book_file, ann_ref, on_change_callback, update_menu)
            end,
        })
    end

    return item_table
end


-- ============================================================================
-- Trash.show — the Deleted-annotations browser
-- ============================================================================


function Trash.show(book_file, on_change_callback)
    if not book_file then
        UIManager:show(InfoMessage:new{ text = _("No document open") })
        return
    end

    local menu_widget
    local function update_menu()
        menu_widget:updateItems(
            build_item_table(book_file, on_change_callback, update_menu))
    end

    menu_widget = Menu:new{
        title         = _("Deleted annotations"),
        item_table    = build_item_table(book_file, on_change_callback, update_menu),
        is_borderless = true,
        is_popout     = false,
        width         = Screen:getWidth(),
        height        = Screen:getHeight(),
    }
    function menu_widget:onClose()
        UIManager:close(menu_widget)
        return true
    end
    UIManager:show(menu_widget)
end


return Trash
