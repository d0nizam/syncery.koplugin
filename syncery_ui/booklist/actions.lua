-- =============================================================================
-- syncery_ui/booklist/actions.lua
-- =============================================================================
--
-- Per-book actions for the "Manage all books" list.
--
-- PUBLIC SURFACE
--
--   Actions.resetPersonalData(plugin, book)  — wipe THIS device's data
--   Actions.fullReset(plugin, book)          — wipe all synced data
--   Actions.showActionsForBook(plugin, book) — the per-book action Menu
--   Actions.build_action_rows(plugin, book)  — the action rows as a
--                                              plain table (kept separate
--                                              so the rows can be unit-
--                                              tested without the Menu)
--
-- PER-BOOK ACTIONS
--
-- Per-book actions are reached by tapping a row in the "Manage all
-- books" list, which opens `showActionsForBook` — a small Menu of the
-- rows `build_action_rows` returns.  The rows are factored into their
-- own builder purely so they can be unit-tested without standing up a
-- Menu; `showActionsForBook` is the sole entry point.  (An earlier
-- design also wired these rows to a row `hold_callback` as a long-press
-- "express path", but that was removed: base `Menu`'s `onMenuHold` is a
-- no-op so the hook was dead, and it would only have duplicated tap —
-- the action Menu is a second layer either way.  See booklist/init.lua.)
--
-- =============================================================================


local UIManager   = require("ui/uimanager")
local Menu        = require("ui/widget/menu")
local ConfirmBox  = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Screen      = require("device").screen

local json     = require("rapidjson")
local Util     = require("syncery_util")
local I18n     = require("syncery_i18n")
local _        = I18n.translate

-- Annotations are a position-keyed MAP and the engine merges deletions on the
-- `datetime_updated` string (NOT a numeric `modified_at`), so the reset paths
-- below iterate with pairs and stamp datetime_updated — mirroring the in-book
-- reset in per_book_section.lua.  AnnTimeFormat.now() == os.date("%Y-%m-%d %H:%M:%S").
local AnnTimeFormat = require("syncery_ann/time_format")


local Actions = {}


-- ============================================================================
-- Helpers
-- ============================================================================


-- Load JSON from path, returning table or nil
local function load_json(path)
    if not path then return nil end
    local f = io.open(path, "r")
    if not f then return nil end
    local raw = f:read("*a"); f:close()
    if not raw or raw == "" then return nil end
    local ok, data = pcall(json.decode, raw)
    return (ok and type(data) == "table") and data or nil
end


-- Save table as JSON to path.
--
-- ANDROID NOTE: this is a DIRECT overwrite (io.open "w" + write +
-- close).  It is NOT the tmp-then-rename atomic pattern, so it does
-- NOT call `os.rename` — which means it is already safe on Android's
-- FUSE/SAF storage (the platform where rename silently fails).
-- There is no `os.rename` to branch here.  (If this were ever
-- changed to an atomic write it
-- would need the `Device:isAndroid()` branch from
-- `syncery_ann/json_store.lua`.)
local function save_json(path, data)
    local ok, encoded = pcall(json.encode, data)
    if not ok then return false end
    local f, err = io.open(path, "w")
    if not f then return false end
    f:write(encoded)
    f:close()
    return true
end


-- ============================================================================
-- resetPersonalData — wipe only the current device's data for a book
-- ============================================================================


function Actions.resetPersonalData(plugin, book)
    local device_id = plugin.device_id or Util.get_device_id()
    local success = true
    local changed = false

    -- Annotations: mark only this device's annotations as deleted
    local ann_data = load_json(book.annotations_path)
    if ann_data and type(ann_data.annotations) == "table" then
        local now = AnnTimeFormat.now()
        for _key, a in pairs(ann_data.annotations) do
            if a and not a.deleted and a.device_id == device_id then
                a.deleted          = true
                a.datetime_updated = now
                a.device_label     = plugin.device_label
                changed = true
            end
        end
        if changed then
            if not save_json(book.annotations_path, ann_data) then
                success = false
            end
        end
    end

    -- Progress: remove this device's entry.  Normalize the on-disk body
    -- via the state-store helper first so this code always sees the
    -- canonical `{ schema_version, entries = {...} }` shape.
    local ProgressStateStore = require("syncery_progress/state_store")
    local prog_raw  = load_json(book.progress_path)
    local prog_data = ProgressStateStore.normalize(prog_raw)
    if prog_data.entries[device_id] then
        prog_data.entries[device_id] = nil
        if not save_json(book.progress_path, prog_data) then
            success = false
        end
        changed = true
    end

    if success and changed then
        plugin:clearAnnotationCache(book.file)
        UIManager:show(InfoMessage:new{
            text = _("Your personal progress and annotations have been reset for this book."),
            timeout = 3,
        })
    elseif success and not changed then
        UIManager:show(InfoMessage:new{
            text = _("No personal data found for this book."),
            timeout = 3,
        })
    else
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Could not reset all data. Please check the file system."),
            timeout = 4,
        })
    end
end


-- ============================================================================
-- fullReset — mark all annotations deleted and remove the progress file
-- ============================================================================


function Actions.fullReset(plugin, book)
    local device_id = plugin.device_id or Util.get_device_id()
    local success = true

    -- Annotations: mark all as deleted
    local ann_data = load_json(book.annotations_path)
    if ann_data and type(ann_data.annotations) == "table" then
        local now = AnnTimeFormat.now()
        for _key, a in pairs(ann_data.annotations) do
            if a and not a.deleted then
                a.deleted          = true
                a.datetime_updated = now
                a.device_id        = device_id
                a.device_label     = plugin.device_label
            end
        end
        if not save_json(book.annotations_path, ann_data) then
            success = false
        end
    end

    -- Progress: delete the shared file AND the last-sync ancestor.
    -- Without removing last-sync, the next save on a device that
    -- still has this book open would resurrect every device's entry
    -- via the 3-way merge (last-sync becomes the only non-empty view).
    if book.progress_path then
        os.remove(book.progress_path)
    end
    if book.file then
        local ProgressPaths = require("syncery_progress/paths")
        local last_sync = ProgressPaths.last_sync_progress_path(book.file)
        if last_sync then os.remove(last_sync) end
    end

    if success then
        plugin:clearAnnotationCache(book.file)
        UIManager:show(InfoMessage:new{
            text = _("Local synced data has been deleted. Other devices may restore it later."),
            timeout = 3,
        })
    else
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Could not completely delete data. Some files may remain."),
            timeout = 4,
        })
    end
end


-- ============================================================================
-- build_action_rows — the per-book action rows
--
-- Returns the action rows as a plain list, used by `showActionsForBook`
-- (tap → opens these in a Menu).  Factored into its own builder so the
-- row set can be unit-tested directly, without standing up a Menu.
-- ============================================================================


function Actions.build_action_rows(plugin, book)
    return {
        {
            text = _("Reset my Syncery data for this book"),
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Reset this device's annotations and progress for this book?\n\n"
                             .. "Reading status, rating, and render settings stay. Only this device's "
                             .. "annotations and progress are cleared; those from your other devices are kept."),
                    ok_text = _("Reset"),
                    ok_callback = function()
                        Actions.resetPersonalData(plugin, book)
                    end,
                })
            end,
        },
        {
            text = _("Remove this book from Syncery on this device"),
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Mark this book's annotations as deleted and remove the local progress file.\n\n"
                             .. "Reading status, rating, and render settings stay — they're the book's "
                             .. "own KOReader state. Other devices can restore the annotations when they sync."),
                    ok_text = _("Delete all"),
                    ok_callback = function()
                        Actions.fullReset(plugin, book)
                    end,
                })
            end,
        },
        {
            text = _("Migrate this book to current storage mode"),
            callback = function()
                if book.mode == plugin.storage_mode then
                    UIManager:show(InfoMessage:new{ text = _("Already in the current storage mode."), timeout = 2 })
                else
                    local ok = plugin:migrateSingleBook(book)
                    if ok then
                        UIManager:show(InfoMessage:new{ text = _("Book migrated successfully."), timeout = 2 })
                    else
                        UIManager:show(InfoMessage:new{ text = _("Migration skipped (book may already be in new location or data unavailable)."), timeout = 3 })
                    end
                end
            end,
        },
    }
end


-- ============================================================================
-- showActionsForBook — the per-book action Menu (tap entry point)
-- ============================================================================


function Actions.showActionsForBook(plugin, book)
    local action_menu = Menu:new{
        title = book.display_name,
        item_table = Actions.build_action_rows(plugin, book),
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    UIManager:show(action_menu)
end


return Actions
