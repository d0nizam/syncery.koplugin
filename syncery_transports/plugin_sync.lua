-- =============================================================================
-- syncery_transports/plugin_sync.lua
-- =============================================================================
--
-- The plugin-facing transport glue: the cloud upload/schedule logic
-- for the plugin.
--
-- WHY THIS IS A SEPARATE MODULE, NOT METHODS ON THE ORCHESTRATOR
--
-- The obvious relocation target, `syncery_transports/orchestrator.lua`,
-- is the transport
-- *contract* Orchestrator — a deliberately plugin-agnostic, `.new()`-
-- constructed, fake-tested class that holds registered transports and
-- nothing else.  The helpers below are the opposite: they read many
-- distinct plugin members (`plugin._transport`, `plugin.use_cloud`,
-- `plugin:getCurrentState`, the cloud status fields …).  Making them
-- methods of the contract Orchestrator would pull plugin concerns into
-- a module whose entire value is being plugin-agnostic.
--
-- So the ad-hoc transport glue lives in a new sibling module instead,
-- out of main.lua.  Every function here takes the plugin instance as
-- its first parameter — the exact pattern `syncery_lifecycle/teardown.lua`
-- already uses.
--
-- PUBLIC SURFACE
--
--   PluginSync.schedule_cloud_upload(plugin, state)
--   PluginSync.do_cloud_upload(plugin, state)
--
-- main.lua keeps one-line delegator methods (`_scheduleCloudUpload`, etc.)
-- so existing call sites — `_save`, `teardown.lua` — are unchanged.
--
-- =============================================================================


local logger        = require("logger")
local Util          = require("syncery_util")
local Settings      = require("syncery_settings")
local AnnPaths      = require("syncery_ann/paths")
local ProgressPaths = require("syncery_progress/paths")
local I18n          = require("syncery_i18n")

local _ = I18n.translate


local PluginSync = {}


-- ----------------------------------------------------------------------------
-- schedule_cloud_upload — debounced cloud upload.  Cheap when cloud is
-- off; the work happens only on the timer fire, not on every save.
-- ----------------------------------------------------------------------------
function PluginSync.schedule_cloud_upload(plugin, state)
    if not plugin.use_cloud or not state then return end
    if not Settings.is_cloud_configured() then return end

    plugin:_schedule("_cloud_upload_action", plugin.cloud_upload_delay, function()
        PluginSync.do_cloud_upload(plugin, state)
    end)
end


-- ----------------------------------------------------------------------------
-- do_cloud_upload — upload progress + annotations for the current book.
-- When offline, schedules a wifi-backoff retry instead of a bare return.
-- ----------------------------------------------------------------------------
function PluginSync.do_cloud_upload(plugin, state)
    if not plugin.use_cloud then return end
    if not plugin._transport then return end
    if not Settings.is_cloud_configured() then
        return
    end
    state = state or plugin:getCurrentState()
    if not state or not plugin:_isFileTypeSynced(state.file) then return end

    -- Gate on CLOUD reachability (real internet + a bounded probe to the
    -- configured server), not the link-only `_isNetworkOnline`: KOReader runs
    -- the WebDAV/Dropbox transfer synchronously on the UI thread, so an
    -- enabled-but-unreachable cloud would freeze the UI.  Unreachable → defer
    -- via the cloud-scoped backoff (which re-probes reachability on retry).
    if not plugin:_isCloudReachable() then
        plugin._cloud_wifi_backoff:attempt{
            label = "cloud upload",
            run   = function() PluginSync.do_cloud_upload(plugin, state) end,
        }
        return
    end

    -- The cloud transport reads each file's content from disk inside
    -- its push(); we build the entries list and hand it to the bridge,
    -- which derives book_id internally.  Reading the content here means
    -- a single read per save (no double-open).
    local entries = {}
    local p_path = ProgressPaths.shared_progress_path(state.file)
    local a_path = AnnPaths.shared_annotations_path(state.file)

    if p_path then
        local f = io.open(p_path, "rb")
        if f then
            local content = f:read("*a")
            f:close()
            if content and content ~= "" then
                table.insert(entries, { kind = "progress", content = content })
            end
        end
    end
    if a_path then
        local f = io.open(a_path, "rb")
        if f then
            local content = f:read("*a")
            f:close()
            if content and content ~= "" then
                table.insert(entries, { kind = "annotations", content = content })
            end
        end
    end
    if #entries == 0 then return end

    plugin._transport:push_cloud_files(state.file, entries,
        plugin.ui and plugin.ui.doc_settings)

    -- Record the dispatch time for the upload-debounce window.  Sync
    -- status itself is owned by the orchestrator and read via
    -- `_transport:get_status()`; this module no longer tracks a
    -- per-push ok flag.
    plugin.cloud_last_upload_at = os.time()
end


return PluginSync
