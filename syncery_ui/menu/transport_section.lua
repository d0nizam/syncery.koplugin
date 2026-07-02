-- =============================================================================
-- syncery_ui/menu/transport_section.lua
-- =============================================================================
--
-- The transport configuration section: Syncthing, Cloud.
-- Two independent transport blocks composed into a single submenu
-- (the "Transports" submenu).
--
-- This section is the natural home for two UX patterns:
--
--   Disabled-with-explanation.  Sub-items like the port, "API key",
--   "Test connection" are gated on `transport.is_available()` —
--   long-press explains "Configure the API key first" when disabled.
--
--   Dynamic labels.  The transport master toggle row uses `text_func`
--   to inline the current state — `"Syncthing (running)"` /
--   `"Syncthing (not configured)"` / `"Syncthing (3 conflicts)"` — so
--   the user can see what's going on without drilling into the submenu.
--
-- The actual edit dialogs (API key / folder ID input) and the
-- wizard kept their original shape — they were already small and
-- self-contained, and rewriting them would have risked regressions in
-- the heaviest part of the menu.
--
-- =============================================================================


local UIManager   = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox  = require("ui/widget/confirmbox")
local Menu        = require("ui/widget/menu")
local Screen      = require("device").screen

local Util      = require("syncery_util")
local Settings  = require("syncery_settings")
local Stignore  = require("syncery_transports/stignore")
local H         = require("syncery_ui/menu/_helpers")

local _  = H._
local _n = H._n


local T = {}


-- ============================================================================
-- 1. Syncthing edit dialogs (port / API key / folder ID)
--
-- Simple modal dialogs (no menu-state interaction), so they are kept
-- as-is — refactoring them further would be busy-work.
-- ============================================================================


--- Store the picker's chosen folder (storage scheme S-a): the id goes in
--- folder_id (the raw key providers + scan read), the path+label go in the
--- folder record.  Together they are the conceptual chosen `{id,path,label}`.
local function adopt_folder(folder)
    Settings.set_syncthing_folder_id(folder.folder_id)
    -- Persist the single chosen folder as a {folder_id, path, label} record.
    -- The folder list is fetched live by the picker, never stored, so this is
    -- the one folder every consumer reads (scan target, .stignore placement,
    -- booklist scan roots, manual push).
    Settings.set_syncthing_folder({
        folder_id = folder.folder_id, path = folder.path, label = folder.label,
    })

    -- Eager `.stignore`: put the conflict-suppression pattern in place the
    -- moment a folder is chosen, not only after the first scan fires.  The
    -- scan-path call in `main.lua:_doTriggerScan` stays as an idempotent
    -- safety net (a second write returns `already_present`).  Local file I/O
    -- only, never throws; same signature as the scan-path call.  pcall-guarded
    -- as defence in depth -- the picker must never fail because of `.stignore`.
    -- Return the write status so the caller can confirm selection and surface
    -- a `.stignore` failure (no_path / unwritable) instead of swallowing it.
    local ok, status = pcall(function()
        return Stignore.ensure_for_folder(folder.folder_id, Settings.get_syncthing_folder)
    end)
    return ok and status or "error"
end


--- Folder picker.  Fetches the active provider's folders live (through the
--- transport bridge → list_folders), then branches:
---   • 0 / error   → an explanatory InfoMessage; no folder chosen.
---   • exactly 1   → auto-adopt + a dismiss-only notice (it picked for you,
---                   and says how to change it).
---   • more than 1 → a tappable Menu (label-first, path as the hint); a tap
---                   stores the choice.
--- Foreground-only by construction: only reached from a Syncery setup UI the
--- user opened, so there is no mid-read pop.
--- Folder picker: a short, localized parenthetical flagging a Syncthing
--- folder's live state.  `state` is the getFolders folder state (KOSyncthing+) or the
--- /rest/db/status state we fetched for a manual folder
--- ("paused"/"error"/"syncing"/"scanning"/...).  nil for idle/unknown states
--- so healthy rows stay clean; reuses the existing "error" string.
function T.folder_state_suffix(state)
    if state == "paused"   then return _("paused")   end
    if state == "error"    then return _("error")    end
    if state == "syncing"  then return _("syncing")  end
    if state == "scanning" then return _("scanning") end
    return nil
end


function T.pickFolder(plugin)
    -- Bail before the synchronous HTTP call when offline so the UI
    -- never freezes on a doomed request.
    if not H.network_ready(plugin) then return end
    UIManager:show(InfoMessage:new{ text = _("Looking for Syncthing folders…"), timeout = 2 })

    -- Folder display name with an optional "(paused)"/"(error)"/"(syncing)"
    -- flag so the user can see a folder's state before committing to it.
    local function disp(f)
        local base = (type(f.label) == "string" and f.label ~= "") and f.label or f.folder_id
        local sfx  = T.folder_state_suffix(f.state)
        return sfx and (base .. " (" .. sfx .. ")") or base
    end

    -- Detect & persist the GUI scheme (https-first, like the companion
    -- plugin) before enumerating: an HTTPS-only Syncthing GUI (self-signed
    -- cert + HTTP->HTTPS redirect) is then reached directly even without a
    -- prior "Test connection", and push/status pick up the same scheme.
    -- The probe's verdict is ignored here -- list_folders surfaces the real
    -- outcome.
    H.test_syncthing_connection(function()
    plugin._transport:list_folders(function(folders, err)
        if type(folders) ~= "table" or #folders == 0 then
            local msg
            if err == "no_folders" then
                msg = _("Connected, but Syncthing reports no folders to sync.")
            elseif err == "auth_failed" then
                msg = _("API key rejected.\nCheck Syncthing → Settings → GUI → API Key.")
            elseif err == "not_available" then
                msg = _("No API key set.\nEnter the Syncthing API key first.")
            else
                msg = _("Could not reach Syncthing. Is it running?")
            end
            UIManager:show(InfoMessage:new{ icon = "notice-warning", text = msg, timeout = 6 })
            return
        end

        if #folders == 1 then
            local f = folders[1]
            adopt_folder(f)
            -- No timeout → dismiss-only.  It warns that the pick was automatic
            -- and tells the user how to change it.
            UIManager:show(InfoMessage:new{
                text = string.format(
                    _("Found and selected your only configured folder \"%s\". "
                      .. "If it's the wrong one, set the correct folder in Syncthing, "
                      .. "then choose it from the folder list."),
                    disp(f)),
            })
            return
        end

        -- More than one → a tappable picker.  Label only (the human name shown
        -- in Syncthing).  The path is deliberately NOT used as `mandatory`: a
        -- long Syncthing path (e.g. a nested docsettings mirror) makes Menu's
        -- per-item available_width go negative, which crashes TextBoxWidget's
        -- makeLine ("width must be strictly positive").  The label already
        -- identifies the folder; folders with identical labels stay
        -- distinguishable via the state suffix from disp().
        local menu_widget
        local items = {}
        for __, f in ipairs(folders) do
            items[#items + 1] = {
                text      = disp(f),
                callback  = function()
                    local stignore_status = adopt_folder(f)
                    UIManager:close(menu_widget)
                    -- The multi-folder picker was otherwise silent: confirm the
                    -- tap registered.  On a `.stignore`-write failure, surface
                    -- the status so a misconfigured/unwritable folder root is
                    -- visible rather than silently swallowed.
                    local text = string.format(_("Selected folder: %s"), disp(f))
                    if stignore_status ~= "written"
                            and stignore_status ~= "already_present" then
                        text = text .. "\n" .. string.format(
                            _("(.stignore not written: %s)"), tostring(stignore_status))
                    end
                    UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
                end,
            }
        end
        menu_widget = Menu:new{
            title         = _("Choose a folder to sync"),
            item_table    = items,
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
    end)
    end)
end


function T.testConnection(plugin)
    -- Bail out before the synchronous HTTP call when offline, so the
    -- UI never freezes on a doomed request (see H.network_ready).
    if not H.network_ready(plugin) then return end
    UIManager:show(InfoMessage:new{ text = _("Testing Syncthing connection…"), timeout = 2 })
    local function report(ok, code, diag)
        local icon, msg
        if ok then
            icon = "notice-info"
            msg  = _("Syncthing is reachable and the API key is valid.")
        elseif diag == "no_api_key" then
            icon = "notice-warning"
            msg  = _("No API key set.\nSet up the API key first.")
        elseif diag == "auth_failed" then
            icon = "notice-warning"
            msg  = _("API key rejected.\nCheck Syncthing → Settings → GUI → API Key.")
        elseif type(code) == "number" then
            icon = "notice-warning"
            msg  = string.format(_("Unexpected HTTP %d response from Syncthing."), code)
        else
            icon = "notice-warning"
            msg  = _("Could not reach Syncthing. Is it running?")
        end
        UIManager:show(InfoMessage:new{ icon = icon, text = msg, timeout = 6 })
    end
    -- When an automatic provider (KOSyncthing+ / config.xml) supplies the key,
    -- the manual key + scheme probe in H.test_syncthing_connection don't apply
    -- — test the live connection through the active provider (apiCall for
    -- KOSyncthing+, the config.xml-authoritative URL otherwise).
    if H.syncthing_auto_key_present() then
        plugin._transport:test_connection(report)
    else
        H.test_syncthing_connection(report)
    end
end


function T.showSyncthingWizard(plugin)
    local cfg = H.load_syncthing_cfg()

    -- One step: the API key.  The folder is chosen afterward via the live
    -- "Choose Syncthing folder" picker (which enumerates the real folders),
    -- so the wizard doesn't ask the user to type a folder id.
    local dlg
    dlg = InputDialog:new{
        title = _("Syncthing API key"),
        description = _("Find it in Syncthing \226\134\146 Settings \226\134\146 GUI \226\134\146 API Key.\nLeave empty if you don't use authentication.\n\nYou'll pick the folder to sync afterward from \"Choose Syncthing folder\"."),
        input = cfg.api_key or "",
        input_type = "string",
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dlg) end },
            { text = _("Test connection"), is_enter_default = true, callback = function()
                cfg.api_key = Util.trim(dlg:getInputText() or "")
                H.save_syncthing_cfg(cfg)
                UIManager:close(dlg)
                -- The API key is already saved above, so an offline
                -- bail-out here loses nothing -- skip the synchronous test and
                -- tell the user to retry once online (see H.network_ready).
                if not H.network_ready(plugin, _("No network connection.\nYour settings are saved \226\128\148 test the connection once you're back online.")) then
                    return
                end
                UIManager:show(InfoMessage:new{ text = _("Testing connection\226\128\166"), timeout = 2 })
                H.test_syncthing_connection(function(ok, code, diag)
                    if ok then
                        UIManager:show(InfoMessage:new{
                            icon = "notice-info",
                            text = _("Syncthing is reachable and the API key is valid.\n\nNow choose your folder from \"Choose Syncthing folder\"."),
                            timeout = 6,
                        })
                    else
                        local msg
                        if diag == "no_api_key" then
                            msg = _("No API key set.\nRestart the wizard and enter an API key.")
                        elseif diag == "auth_failed" then
                            msg = _("API key rejected.\nCheck Syncthing \226\134\146 Settings \226\134\146 GUI \226\134\146 API Key.")
                        else
                            msg = _("Could not reach Syncthing. Is it running?")
                        end
                        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = msg, timeout = 6 })
                    end
                end)
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end


-- ============================================================================
-- 3. Cloud dialogs / picker
-- ============================================================================


--- A KOReader plugin method may be a plain function OR a callable table
--- (some forks wrap methods); `obj:method()` works for both, but
--- `type(obj.method) == "function"` rejects the callable-table form.  This
--- is the exact reason the picker fell back to the standalone SyncService on
--- devices whose "Cloud storage+" wraps onShowCloudStorageList — test
--- callability, not the literal "function" type (mirrors AnnotationSync,
--- which only checks `if ui.cloudstorage then` and calls the method).
local function is_callable(x)
    if type(x) == "function" then return true end
    if type(x) ~= "table" then return false end
    local mt = getmetatable(x)
    return mt ~= nil and mt.__call ~= nil
end


--- Pure: which destination picker to use.  Returns "plugin" when the live
--- "Cloud storage+" plugin (ui.cloudstorage) exposes onShowCloudStorageList
--- — it shows the plugin's OWN UI and lists FTP servers — and "fallback"
--- otherwise (the built-in standalone SyncService picker, Dropbox/WebDAV
--- only).  Extracted so the routing decision is unit-testable without a UI.
function T.cloud_picker_kind(ui)
    local ui_cs = ui and ui.cloudstorage
    if ui_cs and is_callable(ui_cs.onShowCloudStorageList) then
        return "plugin"
    end
    return "fallback"
end


function T.pickCloudDestination(plugin, touchmenu_instance)
    -- Shared: persist the chosen server, refresh the parent menu's
    -- "Destination:" row, and confirm.  Fires later (the picker is async),
    -- so touchmenu_instance is captured in the closure.
    local function on_chosen(server)
        Settings.set_cloud_server(server)
        H.clear_status_snapshot(plugin)
        if touchmenu_instance then touchmenu_instance:updateItems() end
        local label = (server and (server.type or server.provider)) or "?"
        UIManager:show(InfoMessage:new{
            text    = string.format(_("Cloud destination set: %s.\nRestart KOReader if uploads don't appear."), label),
            timeout = 4,
        })
    end

    -- Prefer the "Cloud storage+" plugin's OWN picker (ui.cloudstorage):
    -- it shows the plugin UI and lists FTP servers.  onShowCloudStorageList
    -- invokes the callback with a SINGLE arg — the chosen server table
    -- {name,type,address,username,password,url} (cloudstorage.koplugin
    -- CloudStorage:showFolderChooseDialog).  This is the same entry point
    -- KOReader's own statistics / vocabulary-builder use.
    if T.cloud_picker_kind(plugin.ui) == "plugin" then
        plugin.ui.cloudstorage:onShowCloudStorageList(function(server)
            on_chosen(server)
        end)
        return
    end

    -- Fallback (plugin absent): the built-in standalone SyncService picker —
    -- Dropbox/WebDAV only, no FTP.  It calls onConfirm with a SINGLE arg
    -- (server) — `self.onConfirm(server)` in apps/cloudstorage/syncservice.lua.
    local ok_svc, SyncService = pcall(require, "apps/cloudstorage/syncservice")
    if not ok_svc or not SyncService then
        UIManager:show(InfoMessage:new{
            icon    = "notice-warning",
            text    = _("Cloud storage picker is unavailable in this KOReader build."),
            timeout = 5,
        })
        return
    end
    local picker = SyncService:new{}
    picker.onConfirm = function(server)
        on_chosen(server)
    end
    UIManager:show(picker)
end


function T.clearCloudDestination(plugin, touchmenu_instance)
    UIManager:show(ConfirmBox:new{
        text = _("Clear the saved cloud destination?\n\nNo files are deleted from the cloud — only this device's connection setting."),
        ok_text = _("Clear"),
        ok_callback = function()
            Settings.clear_cloud_server()
            H.clear_status_snapshot(plugin)
            if touchmenu_instance then touchmenu_instance:updateItems() end
            UIManager:show(InfoMessage:new{
                text = _("Cloud destination cleared."), timeout = 3,
            })
        end,
    })
end


function T.editCloudUploadDelay(plugin, touchmenu_instance)
    local dlg
    dlg = InputDialog:new{
        title       = _("Cloud upload delay (seconds)"),
        description = _("How long to debounce after a save before uploading.\n"
                     .. "Higher values protect rate-limited providers like Dropbox.\n"
                     .. "Minimum 15 s; recommended 60 s."),
        input       = tostring(plugin.cloud_upload_delay or 60),
        input_type  = "number",
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dlg) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                    local n = tonumber(dlg:getInputText() or "")
                    if not n or n < 15 then
                        UIManager:show(InfoMessage:new{
                            text = _("Please enter a number ≥ 15."), timeout = 3 })
                    else
                        plugin.cloud_upload_delay = math.floor(n)
                        if G_reader_settings then
                            G_reader_settings:saveSetting(
                                "syncery_cloud_upload_delay", plugin.cloud_upload_delay)
                        end
                        UIManager:close(dlg)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                        return
                    end
                    UIManager:close(dlg)
                end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end


--- Pure: is a cloud STORAGE BACKEND actually present in this build?  Returns
--- true when the active provider the selector would use is really available —
--- the "Cloud storage+" plugin (`ui.cloudstorage` with a callable `sync`), or
--- the built-in `apps/cloudstorage/syncservice` fallback.  This is NOT the same
--- as the transport's `is_available()`: syncservice's `syncable_providers()`
--- returns {dropbox,webdav} UNCONDITIONALLY, so a configured Dropbox/WebDAV
--- server makes `is_available()` report true even on a build with no backend at
--- all — the failure then only surfaces later as an opaque INTERNAL during the
--- actual sync.  `sync_service` is a test injection (the real module is
--- require()d lazily inside the selector); production passes nil.
function T.cloud_backend_available(ui, sync_service)
    local CloudProviders = require("syncery_transports/cloud/providers/init")
    local sel = CloudProviders.select{
        ui_cloudstorage_resolver = function() return ui and ui.cloudstorage end,
        sync_service             = sync_service,
    }
    return sel ~= nil and sel.provider ~= nil and sel.provider.is_available() == true
end


function T.testCloudConnection(plugin)
    -- Pre-flight: is a cloud backend actually present in this build?  Checked
    -- BEFORE the configuration test so a stripped build (no "Cloud storage+"
    -- plugin and no built-in syncservice) gets an honest answer now instead of
    -- the false "configured — will verify on next sync" the config test alone
    -- would give (see T.cloud_backend_available for why is_available() can't be
    -- used here).
    if not T.cloud_backend_available(plugin.ui) then
        UIManager:show(InfoMessage:new{
            icon    = "notice-warning",
            text    = _("Cloud storage isn't available in this KOReader build."),
            timeout = 6,
        })
        return
    end

    UIManager:show(InfoMessage:new{ text = _("Checking cloud settings…"), timeout = 2 })
    H.test_cloud_connection(function(ok)
        local icon, msg
        if ok then
            icon = "notice-info"
            msg  = _("Cloud destination is configured.\nSyncery will verify it can reach the server on the next sync.")
        else
            icon = "notice-warning"
            msg  = _("No cloud destination set.\nTap 'Pick destination' first.")
        end
        UIManager:show(InfoMessage:new{ icon = icon, text = msg, timeout = 6 })
    end)
end


-- ============================================================================
-- 4. Sub-submenus for each transport's config
--
-- These are the inner submenus the user opens from the master toggle
-- row.  Each item is disabled-with-explanation, gated on the transport's
-- configuration state — long-press on a disabled item explains "set
-- the API key first" rather than letting the user wonder why it's grey.
-- ============================================================================


--- Cloud config submenu — destination / backend / clear / delay / test.
function T.menuCloudConfig(plugin)
    return {
        {
            text_func = function()
                local desc = Settings.describe_cloud_server()
                return desc and string.format(_("Destination: %s"), desc)
                             or _("Destination: (not set)")
            end,
            help_text      = _("Where Syncery uploads JSON files. Tap to pick or change."),
            keep_menu_open = true,
            hold_callback  = H.helpHold(_("Tap to pick or change the cloud destination "
                                       .. "(Dropbox / WebDAV / FTP).")),
            callback       = H.safe("Pick cloud destination",
                function(tmi) T.pickCloudDestination(plugin, tmi) end),
        },
        {
            text           = _("Clear destination"),
            help_text      = _("Forget the saved destination on this device only."),
            keep_menu_open = true,
            enabled_func   = function() return Settings.is_cloud_configured() end,
            hold_callback  = H.gatedHold(
                function() return Settings.is_cloud_configured() end,
                _("There is no saved destination to clear yet."),
                _("Removes the saved server. No files are deleted.")),
            callback       = H.safe("Clear cloud destination",
                function(tmi) T.clearCloudDestination(plugin, tmi) end),
            separator      = true,
        },
        {
            text_func = function()
                return string.format(_("Upload delay: %d s"),
                    plugin.cloud_upload_delay or 60)
            end,
            help_text      = _("Debounce window after a save before uploading. "
                            .. "Higher values protect rate-limited providers."),
            keep_menu_open = true,
            hold_callback  = H.helpHold(_("Tap to change how long Syncery waits after a save "
                                       .. "before uploading to the cloud.")),
            callback       = H.safe("Edit cloud delay",
                function(tmi) T.editCloudUploadDelay(plugin, tmi) end),
        },
        {
            text           = _("Check cloud settings"),
            help_text      = _("Check that a cloud destination is set. Reachability is verified on the next sync."),
            keep_menu_open = true,
            enabled_func   = function() return Settings.is_cloud_configured() end,
            hold_callback  = H.gatedHold(
                function() return Settings.is_cloud_configured() end,
                _("Pick a destination first."),
                _("Tap to check the cloud destination is configured.")),
            callback       = H.safe("Test cloud",
                function() T.testCloudConnection(plugin) end),
        },
    }
end


--- Syncthing advanced submenu — the daemon listen port (API key and folder
--- picker live in menuSyncthingConfig; the scan-interval knob was removed).
function T.menuSyncthingAdvanced(plugin)
    return {
        H.makeNumericSetting{
            title      = _("Syncthing port"),
            help       = _("Default: 8384. Change only if your Syncthing GUI uses a non-standard port. It must be between 1024 and 65535."),
            get        = function() return Settings.get_syncthing_port() end,
            min        = 1024, max = 65535,
            label_func = function()
                return string.format(_("Syncthing port: %d"), Settings.get_syncthing_port())
            end,
            apply      = function(n) Settings.set_syncthing_port(n) end,
        },
    }
end


-- ============================================================================
-- 4b. Syncthing configuration submenu — the Syncthing options grouped
-- under the master toggle.
--
-- WHY A SUBMENU INSTEAD OF CONDITIONAL ROWS AT THE TRANSPORT LEVEL
--
-- These rows depend on `use_syncthing`. If they live at the same menu level
-- as the master toggle, flipping the toggle cannot reveal them: KOReader's
-- `touchmenu_instance:updateItems()` repaints the *current* item_table, but it
-- does NOT re-run the `sub_item_table_func` that produced that table — so a
-- conditional `if use_syncthing then table.insert(...)` is only re-evaluated
-- when the user leaves and re-enters the menu. Putting them one level deeper,
-- behind their own `sub_item_table_func`, makes them rebuild every time the
-- submenu is opened — which always happens AFTER the toggle was flipped — so
-- they are always fresh, with zero greyed-out clutter and no item-table
-- surgery. The master toggle and the "Configure…" entry are both plain rows at
-- the transport level, so `updateItems()` refreshes them in place.
-- ============================================================================


function T.menuSyncthingConfig(plugin)
    local test_help = _(
        "Send a ping to the Syncthing REST API to verify the API key "
        .. "is correct and Syncthing is running.")

    local rows = {}

    -- "Set up API key…" configures the manual provider only.  When an
    -- automatic provider (KOSyncthing+ / config.xml) supplies the key it
    -- always wins the provider chain, so a manually-entered key can never take
    -- effect — hide the row rather than offer a no-op.  The submenu rebuilds on
    -- every open, so a conditional row is safe (no stale-item-table trap).
    if not H.syncthing_auto_key_present() then
        rows[#rows + 1] = {
            text           = _("Set up API key…"),
            help_text      = _("Enter the Syncthing API key. Not needed when "
                            .. "KOSyncthing+ is installed — it supplies the key for you."),
            keep_menu_open = true,
            hold_callback  = H.helpHold(_("Tap to enter the Syncthing API key.")),
            callback       = H.safe("Set up API key",
                function() T.showSyncthingWizard(plugin) end),
        }
    end

    rows[#rows + 1] = {
        text           = _("Choose Syncthing folder"),
        help_text      = _("Ask Syncthing which folders it has and pick the one "
                        .. "to sync, so you don't have to type the folder ID by hand.\n\n"
                        .. "Works with any Syncthing reachable over its web address."),
        keep_menu_open = true,
        -- Gated on H.syncthing_key_usable (manual OR KOSyncthing+ OR
        -- config.xml), so a KOSyncthing+-only setup is not greyed out.
        enabled_func   = H.syncthing_key_usable,
        hold_callback  = H.gatedHold(H.syncthing_key_usable,
            _("No Syncthing API key yet — set one up first. Not needed with KOSyncthing+."),
            _("Tap to choose which Syncthing folder to sync.")),
        callback       = H.safe("Choose folder", function() T.pickFolder(plugin) end),
    }

    rows[#rows + 1] = {
        text           = _("Test connection"),
        help_text      = test_help,
        keep_menu_open = true,
        -- Same key-source gate as the folder picker (not the manual key alone).
        enabled_func   = H.syncthing_key_usable,
        hold_callback  = H.gatedHold(H.syncthing_key_usable,
            _("No Syncthing API key yet — set one up first. Not needed with KOSyncthing+."),
            test_help),
        callback       = H.safe("Test connection",
            function() T.testConnection(plugin) end),
        separator      = true,
    }

    rows[#rows + 1] = {
        text                = _("Advanced"),
        help_text           = _("Manually edit Syncthing settings: port."),
        keep_menu_open      = true,
        hold_callback       = H.helpHold(_("Tap to open the advanced Syncthing configuration.")),
        sub_item_table_func = function() return T.menuSyncthingAdvanced(plugin) end,
    }

    return rows
end


-- ============================================================================
-- 5. Per-transport labels — dynamic state-in-label
--
-- Each transport's master toggle row shows its live state inline.
-- "Syncthing: ready" / "Syncthing: not configured" / "Syncthing: error"
-- — so the user can see what's going on without drilling in.
--
-- The state strings come from `H.transport_state(snapshot, id)`, which
-- reads the centralised snapshot and returns one of five buckets.
-- ============================================================================


--- Map the H.transport_state buckets to user-facing strings.
--- Dynamic label in action — the same row gets different text depending
--- on the current state.
local function format_transport_state(state)
    if state == "ready"        then return _("ready")              end
    if state == "needs_config" then return _("not configured")     end
    if state == "syncing"      then return _("retrying…")          end
    if state == "error"        then return _("error")              end
    if state == "disabled"     then return _("off")                end
    if state == "unsupported"  then return _("unsupported")        end
    if state == "no_backend"   then return _("no backend")         end
    return state or "?"
end


--- Compose a "Name (state)" label for a transport master toggle.
local function labeled_transport(name, plugin, transport_id)
    local snap  = H.status_snapshot(plugin)
    local state = H.transport_state(snap, transport_id)
    return string.format("%s (%s)", name, format_transport_state(state))
end


-- ============================================================================
-- 6. Top-level transport section — the "Transports" submenu
-- ============================================================================


function T.build(plugin)
    local integration_help = _(
        "Nudges Syncthing's REST API after every save so changes propagate "
        .. "immediately, without waiting for Syncthing's own periodic scan cycle.\n\n"
        .. "Disable this if you use a different sync tool — Syncery will still "
        .. "write its JSON files; your sync tool just picks them up on its own schedule.")

    -- Syncthing block.  Dynamic label reflects live state.
    -- The master toggle is always visible; its configuration lives in a
    -- submenu (see T.menuSyncthingConfig for why a submenu, not conditional
    -- rows at this level — it is what makes the rows appear immediately after
    -- the toggle is flipped rather than only after leaving and re-entering).
    local items = {
        {
            text_func = function()
                return labeled_transport(_("Syncthing integration"),
                    plugin, "syncthing")
            end,
            help_text      = integration_help,
            keep_menu_open = true,
            checked_func   = function() return plugin.use_syncthing end,
            -- Tap toggles the master
            -- switch; long-press opens the per-transport status panel
            -- when Syncthing is on, or the help toast when it's off.
            hold_callback  = H.statusPanelHold(plugin, "syncthing",
                function() return plugin.use_syncthing == true end,
                integration_help),
            callback       = function(tmi)
                plugin.use_syncthing = not plugin.use_syncthing
                if G_reader_settings then
                    G_reader_settings:saveSetting("syncery_use_syncthing", plugin.use_syncthing)
                end
                -- is_available() reads `syncery_use_syncthing` directly now (the
                -- single canonical key saved just above) — the old D-3 mirror to
                -- `syncery_sync_via_syncthing` is gone, so there is nothing else
                -- to write and no way for the transport to diverge from this box.
                -- Transport state changed: drop the cached status snapshot so
                -- the live text_func rows (here and on parent levels) re-read
                -- it instead of showing the pre-toggle state.
                H.clear_status_snapshot(plugin)
                if tmi then tmi:updateItems() end
            end,
        },
        {
            text                = _("Configure Syncthing…"),
            help_text           = _("Wizard, manual API key / folder settings, connection test, and setup guides."),
            keep_menu_open      = true,
            -- Gated, not hidden: the row stays in place so flipping the master
            -- toggle (above) makes it tappable via updateItems immediately. The
            -- settings inside rebuild fresh on entry, so they are never stale.
            enabled_func        = function() return plugin.use_syncthing == true end,
            hold_callback       = H.gatedHold(
                function() return plugin.use_syncthing == true end,
                _("Enable Syncthing integration first."),
                _("Tap to configure Syncthing: wizard, API key / folder ID, test, and guides.")),
            sub_item_table_func = function() return T.menuSyncthingConfig(plugin) end,
            separator           = true,
        },
    }

    -- ── Cloud block ────────────────────────────────────────────────
    local cloud_help = _(
        "Upload Syncery's per-book JSON files to a cloud destination "
        .. "(Dropbox, WebDAV, or FTP) using KOReader's built-in cloud "
        .. "storage picker.\n\n"
        .. "A good fallback when Syncthing isn't an option (e.g. iOS, "
        .. "managed networks).  Uploads are debounced to protect rate-"
        .. "limited providers like Dropbox — the default delay is 60 s.\n\n"
        .. "Cloud and Syncthing can be enabled at the same time, but "
        .. "running both is rarely necessary.")

    table.insert(items, {
        text_func = function()
            return labeled_transport(_("Cloud storage"),
                plugin, "cloud")
        end,
        help_text      = cloud_help,
        keep_menu_open = true,
        checked_func   = function() return plugin.use_cloud end,
        -- Long-press opens the status panel when cloud is
        -- enabled, help toast otherwise.
        hold_callback  = H.statusPanelHold(plugin, "cloud",
            function() return plugin.use_cloud == true end,
            cloud_help),
        callback       = function(tmi)
            plugin.use_cloud = not plugin.use_cloud
            if G_reader_settings then
                G_reader_settings:saveSetting("syncery_use_cloud", plugin.use_cloud)
            end
            -- is_available() reads `syncery_use_cloud` directly now (the single
            -- canonical key saved just above) — the old D-3 mirror to
            -- `syncery_sync_via_cloud` is gone; nothing else to write.
            H.clear_status_snapshot(plugin)
            if tmi then tmi:updateItems() end
        end,
    })

    -- Cloud configuration: a gated row (not hidden), so flipping the master
    -- toggle above reveals it immediately via updateItems. The settings inside
    -- (menuCloudConfig) rebuild fresh on entry. Same rationale as Syncthing's
    -- "Configure Syncthing…" — see T.menuSyncthingConfig.
    table.insert(items, {
        text                = _("Cloud settings"),
        help_text           = _("Choose the cloud destination and tune upload behaviour."),
        keep_menu_open      = true,
        enabled_func        = function() return plugin.use_cloud == true end,
        hold_callback       = H.gatedHold(
            function() return plugin.use_cloud == true end,
            _("Enable Cloud storage first."),
            _("Tap to set up Dropbox / WebDAV / FTP and adjust upload timing.")),
        sub_item_table_func = function() return T.menuCloudConfig(plugin) end,
    })

    return items
end


return T
