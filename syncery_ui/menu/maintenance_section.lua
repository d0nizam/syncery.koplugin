-- =============================================================================
-- syncery_ui/menu/maintenance_section.lua
-- =============================================================================
--
-- The "Tools" submenu (M.build) plus several rows that are DEFINED here but
-- composed into the Advanced menu by init.lua's buildAdvancedMenu.
--
-- M.build — the "Tools" menu — has two groups:
--
--   * "Your Syncery data" (always visible): backfill pre-Syncery
--     annotations, manage all synced books, remove orphaned sync files,
--     recent sync activity, and the sync journal.  All transport-agnostic
--     — they read/write Syncery's own local files, so they stay visible
--     regardless of which transport (if any) is on.
--
--   * Transport maintenance (conditional sections): the
--     Syncthing submenu (rescan / KOSyncthing+ integration status) renders
--     only when `use_syncthing` is true; the Cloud submenu (clean upload
--     staging) only when `use_cloud` is true.  Rows for an off transport
--     are hidden entirely rather than greyed out.
--
-- Defined here, consumed by Advanced: the storage-mode submenu
-- (`menuStorageMode`), the per-device settings (`menuThisDevice` — rename /
-- show device ID + QR), the "Copy diagnostic info" action
-- (`copyDiagnosticInfoItem`), and the "Book data save interval" knob
-- (`bookDataSaveIntervalItem`).  They live in this file for historical
-- reasons; buildAdvancedMenu is what places them.
--
-- =============================================================================


local UIManager   = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox  = require("ui/widget/confirmbox")
local QRMessage   = require("ui/widget/qrmessage")
local Device      = require("device")

local Util = require("syncery_util")
local StorageMode = require("syncery_storage_mode")
local H    = require("syncery_ui/menu/_helpers")
local _    = H._


local M = {}


-- ============================================================================
-- "This device" — rename + show ID
-- ============================================================================


function M.renameDevice(plugin, touchmenu_instance)
    local dlg
    dlg = InputDialog:new{
        title       = _("Name this device"),
        description = _("This label appears on other devices when they show your progress.\nMax 50 characters."),
        input       = plugin.device_label or Util.get_device_label() or "",
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dlg) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                    local new = Util.trim(dlg:getInputText() or "")
                    if #new > 0 then
                        -- Mirror + toast the CANONICAL saved value (F3):
                        -- set_device_label clips to 50 codepoints, so the
                        -- raw `new` may differ from what actually persisted.
                        local saved = Util.set_device_label(new)
                        if saved then plugin.device_label = saved end
                        UIManager:close(dlg)
                        -- Refresh the parent menu so the "Device name: …"
                        -- row reflects the new label immediately, then show
                        -- the confirmation (order matches the rest of the
                        -- codebase: mutate → updateItems → toast).
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                        UIManager:show(InfoMessage:new{
                            text = string.format(_("Device name set to: %s"),
                                saved or new), timeout = 2 })
                    else
                        UIManager:close(dlg)
                    end
                end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end


function M.menuThisDevice(plugin)
    local name_help = _(
        "The label that appears on other devices when they display your "
        .. "reading progress.  Max 50 characters.\n\n"
        .. "Choose something descriptive so you can tell your devices apart "
        .. "at a glance — e.g. \"Kindle Paperwhite\" or \"Living room Kobo\".")

    local id_help = _(
        "A unique identifier assigned to this device when Syncery first ran.\n\n"
        .. "This ID is embedded in every sync file so other devices know which "
        .. "entry belongs to whom.  It is read-only — tap to see the full value "
        .. "or a QR code you can scan from another device.")

    return {
        {
            text_func = function()
                local lbl = plugin.device_label or Util.get_device_label()
                return string.format(_("Device name: %s"), lbl)
            end,
            help_text      = name_help,
            keep_menu_open = true,
            hold_callback  = H.helpHold(name_help),
            callback       = H.safe("Rename device",
                function(touchmenu_instance) M.renameDevice(plugin, touchmenu_instance) end),
        },
        {
            text_func = function()
                local id = Util.get_device_id() or ""
                return string.format(_("Device ID: %s…"), id:sub(1, 16))
            end,
            help_text      = id_help,
            keep_menu_open = true,
            hold_callback  = H.helpHold(id_help),
            callback       = function()
                local id = Util.get_device_id() or ""
                if id == "" then
                    UIManager:show(InfoMessage:new{
                        text = _("No device ID assigned yet."), timeout = 3 })
                    return
                end
                -- Device ID is a long string the user must enter on ANOTHER
                -- device when pairing. Offer a QR code as the primary path
                -- (scan it from a phone / second reader) with the plain text
                -- as a fallback for manual copying.
                UIManager:show(ConfirmBox:new{
                    text        = string.format(_("Device ID:\n%s"), id),
                    ok_text     = _("Show QR code"),
                    cancel_text = _("Close"),
                    ok_callback = function()
                        UIManager:show(QRMessage:new{
                            text   = id,
                            width  = math.floor(Device.screen:getWidth()  * 0.8),
                            height = math.floor(Device.screen:getHeight() * 0.8),
                        })
                    end,
                })
            end,
        },
    }
end


-- ============================================================================
-- Storage mode submenu
-- ============================================================================


function M.menuStorageMode(plugin)
    local sdr_help = _(
        "Store Syncery JSON files in the book's metadata folder "
        .. "(determined by KOReader's 'Book metadata location' setting).\n\n"
        .. "Usually this is a .sdr sidecar folder next to the book. "
        .. "If you changed the metadata location in KOReader, Syncery will follow it.\n\n"
        .. "For reliable syncing, all devices using SDR mode must use the same "
        .. "'Book metadata location' setting (☰ → Document → Book metadata location). "
        .. "If the settings differ, devices will not see each other's progress or annotations.\n\n"
        .. "Note: Renaming or moving the book without its metadata folder "
        .. "can break the link to your progress and annotations.")

    local hash_help = _(
        "Store Syncery JSON files in a central folder named after a "
        .. "content hash of the book. This keeps your data safe when "
        .. "you rename or reorganise your book files.\n\n"
        .. "Synceryhash mode automatically ensures identical file paths on every device, "
        .. "regardless of the KOReader 'Book metadata location' setting. "
        .. "No extra configuration is required for reliable cross‑device sync.\n\n"
        .. "Files live under the Syncery state directory, e.g. "
        .. "koreader/settings/syncery/synceryhash/<md5>/.\n\n"
        .. "Make sure your sync tool (Syncthing, etc.) watches that "
        .. "central folder so your progress reaches other devices.")

    return {
        {
            text           = _("Book metadata folder (SDR)"),
            help_text      = sdr_help,
            keep_menu_open = true,
            radio          = true,
            checked_func   = function() return plugin.storage_mode == "sdr" end,
            hold_callback  = H.helpHold(sdr_help),
            callback       = H.safe("Set SDR mode", function(tmi)
                if plugin.storage_mode ~= "sdr" then
                    plugin:setStorageMode("sdr")
                    UIManager:show(InfoMessage:new{
                        text    = _("Switched to book metadata folder mode.\n\n"
                                .. "Files will be migrated the next time you open a book."),
                        timeout = 3,
                    })
                end
                if tmi then tmi:updateItems() end
            end),
        },
        {
            text           = _("Synceryhash"),
            help_text      = hash_help,
            keep_menu_open = true,
            radio          = true,
            checked_func   = function() return plugin.storage_mode == "hash" end,
            hold_callback  = H.helpHold(hash_help),
            callback       = H.safe("Set hash mode", function(tmi)
                if plugin.storage_mode ~= "hash" then
                    plugin:setStorageMode("hash")
                end
                if tmi then tmi:updateItems() end
            end),
        },
        {
            text           = _("Migrate all books to this storage mode…"),
            help_text      = _("Move all existing Syncery data from the previous storage location to the current one. Books already in the new location are skipped."),
            keep_menu_open = true,
            hold_callback  = H.helpHold(_("Move all existing Syncery data from the previous storage location to the current one. Books already in the new location are skipped.")),
            callback       = H.safe("Migrate all", function()
                UIManager:show(ConfirmBox:new{
                    text = _("Move all Syncery data from the previous storage location to the current one?\n\nBooks already in the new location will be skipped."),
                    ok_text = _("Migrate"),
                    ok_callback = function()
                        -- old_mode intentionally omitted: migrate_all_books now
                        -- checks whether the data is already in the current mode
                        -- (toggle-back-and-forth case) and derives the source
                        -- itself, instead of assuming "opposite of current".
                        plugin:_migrateAllBooks()
                    end,
                    cancel_text = _("Cancel"),
                })
            end),
        },
    }
end


-- ============================================================================
-- Cloud staging cleanup (conditional row builder)
--
-- This is a no-op when cloud isn't enabled, so we omit the row entirely
-- in that case rather than showing it disabled.
-- ============================================================================


local function clean_cloud_staging_row()
    local help = _(
        "Remove any leftover temporary upload files from the cloud "
        .. "staging directory.\n\n"
        .. "Syncery uses this directory while preparing files for "
        .. "Dropbox / WebDAV / FTP. Files there are normally removed "
        .. "right after upload — if any remain, it usually means a "
        .. "previous upload was interrupted by a crash or power loss.")
    return {
        text           = _("Clean cloud upload staging"),
        help_text      = help,
        keep_menu_open = true,
        hold_callback  = H.helpHold(_(
            "Tap to remove any temporary files Syncery left behind while "
            .. "preparing cloud uploads. No data is uploaded or downloaded.")),
        callback       = H.safe("Clean cloud staging", function()
            local lfs = Util.get_lfs()
            local staging_dir = (StorageMode.get_hash_root() or "") .. "/cloud_staging"
            local removed = 0
            if lfs and lfs.attributes(staging_dir, "mode") == "directory" then
                for entry in lfs.dir(staging_dir) do
                    if entry ~= "." and entry ~= ".." then
                        local p = staging_dir .. "/" .. entry
                        local ok = os.remove(p)
                        if ok then removed = removed + 1 end
                    end
                end
            end
            UIManager:show(InfoMessage:new{
                text = removed > 0
                    and string.format(_("Removed %d leftover staging file(s)."), removed)
                    or  _("Staging directory was already empty."),
                timeout = 3,
            })
        end),
    }
end


-- ============================================================================
-- Advanced rows surfaced directly: the diagnostic action and the one
-- behavioural knob worth keeping.  The set-once numeric tuning values
-- (device freshness, journal size, activity-log size) have no menu rows;
-- they keep their defaults (init in main.lua), and a previously-saved
-- value still applies.
-- ============================================================================


-- The "Copy diagnostic info" action, placed directly in the Advanced menu.
function M.copyDiagnosticInfoItem(plugin)
    local diag_help = _(
        "Builds a plain-text snapshot of Syncery's state — version and "
        .. "device, what is being synced, transport status, this book, and "
        .. "recent sync outcomes.\n\n"
        .. "Shows a QR code you can scan with a phone to lift it off the "
        .. "device, and copies the full text to the clipboard for pasting "
        .. "into a bug report.\n\n"
        .. "Ids are shortened and no credentials are included.")
    return {
        text           = _("Copy diagnostic info"),
        help_text      = diag_help,
        keep_menu_open = true,
        hold_callback  = H.helpHold(diag_help),
        callback       = H.safe("Copy diagnostic info",
            function() plugin:_copyDiagnosticInfo() end),
    }
end


-- "Book data save interval" -- how often _save persists progress + annotations
-- during reading.  Relocated here from the removed "Diagnostic windows" group.
function M.bookDataSaveIntervalItem(plugin)
    return H.makeNumericSetting{
        title      = _("Book data save interval (seconds)"),
        help       = _("How often reading progress and annotations are saved while reading. "
                    .. "Saved on book close and on sleep too, so a larger value here just saves battery."),
        get        = function() return plugin.min_save_interval or 5 end,
        min        = 5, max = 120, unit = _("s"),
        label_func = function()
            return string.format(_("Book data save interval: %d s"),
                plugin.min_save_interval or 5)
        end,
        apply      = function(n)
            plugin.min_save_interval = n
            if G_reader_settings then
                G_reader_settings:saveSetting("syncery_min_save_interval", n)
            end
        end,
    }
end


function M.build(plugin)
    local rescan_help = _(
        "Trigger an immediate Syncthing scan on every configured folder so "
        .. "changes are picked up without waiting for the next automatic cycle.\n\n"
        .. "Wi-Fi and a valid API key are required.")

    local orphan_help = _(
        "Find and delete Syncery's leftover sync files (.syncery-*.json) whose "
        .. "book no longer exists.\n\n"
        .. "Looks for your books in KOReader's home folder, plus any sync folders "
        .. "you've set up. Books are matched by content, so renamed or moved books "
        .. "are not affected — only files whose book is truly gone are removed.\n\n"
        .. "No book files are touched, and you'll see the list and confirm before "
        .. "anything is deleted.")

    local log_help = _(
        "Show an in-memory log of the sync events that happened during this "
        .. "reading session.\n\n"
        .. "Useful for confirming that saves and Syncthing scans fired as "
        .. "expected, or for diagnosing why something did not sync.")

    local conflicts_help = _(
        "Status and re-registration of Syncery's integration with the "
        .. "KOSyncthing+ plugin.\n\n"
        .. "When KOSyncthing+ is installed, Syncery registers its conflict-file "
        .. "patterns automatically at startup, so its conflict badge "
        .. "won't show files that Syncery resolves internally.\n\n"
        .. "Tap to verify the integration is active, or to re-register after "
        .. "installing KOSyncthing+.")

    local items = {}

    -- Library-wide bulk annotation ingest: backfill annotations that
    -- existed in KOReader BEFORE Syncery tracked the book; idempotent — already-synced
    -- books are skipped.  The per-book Trash Bin lives WITH the annotations
    -- (What's synced -> Annotations), its domain home.
    local bulk_help = _(
        "Scan for books that have native KOReader annotations and add "
        .. "them to Syncery — together with each book's reading status, "
        .. "rating, and the render settings you sync — without opening the "
        .. "book. Looks in your sync folders and in KOReader's central "
        .. "metadata folder.\n\n"
        .. "Useful right after install if you already have highlights and "
        .. "notes. It is idempotent: books already synced are skipped.")

    -- ================================================================
    -- "Your Syncery data" — data ops + hygiene + diagnostic viewers, ALL
    -- transport-agnostic (they read/write Syncery's own local files; they
    -- depend on the STORAGE MODE, not the transport).  Grouped together here,
    -- separate from the transport submenus below.
    -- ================================================================
    table.insert(items, {
        text          = _("── Your Syncery data ──"),
        enabled_func  = function() return false end,
        hold_callback = H.helpHold(_("Backfill, manage, and review your Syncery data.")),
    })

    -- (a) "Sync pre-Syncery data" —
    -- a one-time backfill of annotations PLUS metadata + render settings from
    -- before Syncery tracked the book (selection is annotation-driven; books
    -- with no annotations flow through normal sync on next open).
    table.insert(items, {
        text           = _("Sync pre-Syncery data…"),
        help_text      = bulk_help,
        keep_menu_open = true,
        hold_callback  = H.helpHold(bulk_help),
        callback       = H.safe("Scan books for data", function()
            UIManager:show(ConfirmBox:new{
                text = _(
                    "Scan your library for books with annotations and add "
                    .. "them — with their reading status, rating, and synced "
                    .. "render settings — to Syncery, without opening each "
                    .. "book?\n\n"
                    .. "Already-synced books are skipped."),
                ok_text = _("Scan"),
                ok_callback = function() plugin:_bulkIngestAnnotations() end,
                cancel_text = _("Cancel"),
            })
        end),
    })

    table.insert(items, {
        text           = _("Manage all synced books…"),
        help_text      = _("View a list of all books that have Syncery data and selectively reset or delete their synced information."),
        keep_menu_open = true,
        hold_callback  = H.helpHold(_("Tap to see a list of synced books and manage their data.")),
        callback       = H.safe("Manage all books", function()
            require("syncery_ui/booklist/init").showBookList(plugin)
        end),
    })

    -- Data hygiene: orphan cleanup bases the book set on home_dir (adding configured
    -- sync folders opportunistically), so it works with or without Syncthing and in
    -- every storage mode (including synceryhash).  Storage-mode-coupled like
    -- "Manage all synced books", so it lives here, not under a transport submenu.
    table.insert(items, {
        text           = _("Remove orphaned sync files…"),
        help_text      = orphan_help,
        keep_menu_open = true,
        hold_callback  = H.helpHold(orphan_help),
        callback       = H.safe("Remove orphans",
            function() plugin:_cleanupOrphans() end),
    })

    -- Diagnostic viewer (read-only record of what happened to your data):
    -- recent sync activity for this reading session.
    table.insert(items, {
        text           = _("Recent sync activity"),
        help_text      = log_help,
        keep_menu_open = true,
        hold_callback  = H.helpHold(log_help),
        callback       = H.safe("Activity log",
            function() plugin:_showActivityLog() end),
        separator      = true,   -- divides "Your Syncery data" from the transport submenus
    })

    -- ================================================================
    -- Transport maintenance — nested submenus (only the active
    -- transport's submenu appears).  These act on the transport machinery,
    -- not on Syncery's data, so they live OUTSIDE "Your Syncery data".
    -- ================================================================
    if plugin.use_syncthing then
        table.insert(items, {
            text                = _("Syncthing"),
            help_text           = _("Maintenance actions for the Syncthing integration."),
            keep_menu_open      = true,
            hold_callback       = H.helpHold(_("Maintenance actions for the Syncthing integration.")),
            sub_item_table_func = function()
                -- KOSyncthing+ row gated on the plugin being installed (can't query
                -- cheaply at module-load; the method handles "not installed" with a toast).
                local kosyncthing_installed = function() return plugin:_isSyncthingPluginInstalled() end
                return {
                    {
                        text           = _("Rescan all Syncthing folders"),
                        help_text      = rescan_help,
                        keep_menu_open = true,
                        hold_callback  = H.helpHold(rescan_help),
                        callback       = H.safe("Rescan all folders",
                            function() plugin:_rescanAllFolders() end),
                    },
                    {
                        text           = _("KOSyncthing+ integration status…"),
                        help_text      = conflicts_help,
                        keep_menu_open = true,
                        enabled_func   = kosyncthing_installed,
                        hold_callback  = H.gatedHold(kosyncthing_installed,
                            _("Install the KOSyncthing+ plugin to use its integration."),
                            conflicts_help),
                        callback       = H.safe("KOSyncthing+ integration",
                            function() plugin:_configureKOSyncthingPlusConflicts() end),
                    },
                }
            end,
        })
    end

    if plugin.use_cloud then
        table.insert(items, {
            text                = _("Cloud"),
            help_text           = _("Maintenance actions for the cloud upload pipeline."),
            keep_menu_open      = true,
            hold_callback       = H.helpHold(_("Maintenance actions for the cloud upload pipeline.")),
            sub_item_table_func = function()
                return { clean_cloud_staging_row() }
            end,
        })
    end

    return items
end


return M
