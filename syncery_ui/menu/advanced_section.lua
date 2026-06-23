-- =============================================================================
-- syncery_ui/menu/advanced_section.lua
-- =============================================================================
--
-- "Advanced" — the home for things that are dangerous, experimental,
-- or both.  Dangerous operations live behind an
-- extra layer of friction (a submenu the user has to dig into),
-- separating them from the day-to-day actions.
--
-- Two clusters live here:
--
--   1. **Dangerous per-book operations** — Deep clean.  Permanently
--      deletes the JSON files for the current book.  No tombstone,
--      no recovery.  Gated on a document being open.
--
--   2. **Annotation engine options** — the two opt-in sub-toggles
--      (sync_summary, sync_render_settings).  The annotation engine is
--      unconditional, so these are plain rows rather than sub-toggles
--      behind a master switch.
--
-- =============================================================================


local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox  = require("ui/widget/confirmbox")

local Util          = require("syncery_util")
local AnnPaths      = require("syncery_ann/paths")
local ProgressPaths = require("syncery_progress/paths")
local DocSettingsBridge = require("syncery_ann/doc_settings_bridge")
local Staging       = require("syncery_transports/cloud/staging")
local StorageMode   = require("syncery_storage_mode")

local H = require("syncery_ui/menu/_helpers")
local _ = H._


local Adv = {}


-- ============================================================================
-- Cloud-staging file paths for a book
--
-- The cloud transport stages each payload at
-- <hash_root>/cloud_staging/syncery-<kind>-<id>.json before upload, and
-- KOReader's SyncService keeps a `.sync` cached-ancestor beside it (the
-- "last uploaded" copy it diffs against next round) plus a transient
-- `.temp` while a sync is mid-flight (see frontend/apps/cloudstorage/
-- syncservice.lua).  Deep clean and its spec share THIS one definition of
-- what to remove so they cannot drift.  Returns {} for a book with no
-- resolvable content id.
-- ============================================================================
function Adv._cloud_staging_paths(book_file)
    local out = {}
    local book_id = AnnPaths._book_content_id(book_file)
    if not book_id then return out end
    local staging_dir = StorageMode.get_hash_root() .. "/cloud_staging"
    for __, kind in ipairs({ "progress", "annotations" }) do
        local name = Staging.cloud_name_for(kind, book_id)
        local base = name and Staging.staging_path_for(staging_dir, name)
        if base then
            out[#out + 1] = base            -- staged payload
            out[#out + 1] = base .. ".sync" -- SyncService cached ancestor
            out[#out + 1] = base .. ".temp" -- transient income (interrupted sync)
        end
    end
    return out
end


-- ============================================================================
-- Deep clean — permanently erase JSON files for the current book
-- ============================================================================


function Adv.deep_clean(plugin)
    return {
        text           = _("Deep clean \xe2\x80\x93 permanently erase all book data\xe2\x80\xa6"),
        help_text      = _(
            "Physically deletes all of this book's Syncery data files — the "
            .. "progress and annotations JSON plus their last-sync and "
            .. "cloud-staging copies.\n\n"
            .. "WARNING: This action is immediate and cannot be undone via Syncery. "
            .. "If another device syncs before the deletion propagates, it may restore "
            .. "old data. Use only when you are sure all devices are up\xe2\x80\x91to\xe2\x80\x91date and you "
            .. "no longer need the safety net of the Trash Bin.\n\n"
            .. "To clear the screen, please reopen the book after performing this reset."),
        keep_menu_open = true,
        enabled_func   = function() return (plugin.ui and plugin.ui.doc_settings ~= nil) and true or false end,
        hold_callback  = H.gatedHold(
            function() return (plugin.ui and plugin.ui.doc_settings ~= nil) and true or false end,
            _("Open a book first \xe2\x80\x94 deep clean operates on the current book."),
            _("Tap to permanently delete the Syncery JSON files for this book.")),
        callback       = H.safe("Deep clean", function()
            local state = plugin:getCurrentState()
            if not state then
                UIManager:show(InfoMessage:new{ text = _("No document open.") })
                return
            end

            UIManager:show(ConfirmBox:new{
                text = _("This will permanently erase Syncery JSON files for this book.\n\n"
                    .. "Your reading progress and all annotations (including deleted ones) "
                    .. "will be lost forever.\n\nAre you sure?"),
                ok_text = _("Delete files"),
                ok_callback = function()
                    local prog_path      = ProgressPaths.shared_progress_path(state.file)
                    local prog_last_sync = ProgressPaths.last_sync_progress_path(state.file)
                    local ann_path       = AnnPaths.shared_annotations_path(state.file)
                    local ann_last_sync  = AnnPaths.last_sync_annotations_path(state.file)

                    if prog_path      then os.remove(prog_path)      end
                    if prog_last_sync then os.remove(prog_last_sync) end
                    if ann_path       then os.remove(ann_path)       end
                    if ann_last_sync  then os.remove(ann_last_sync)  end

                    -- Hash mode: also remove the cached title and the
                    -- now-empty hash directory.  Use the SAME path builder
                    -- as the prog/ann paths above (_shared_book_state_dir),
                    -- so we target <hash_root>/synceryhash/<book_id>/ with the
                    -- correct hash root and the same book-id
                    -- derivation.  A bespoke partialMD5 + Util.state_dir()
                    -- path pointed at <hash_root>/<md5>/ — the pre-12.2
                    -- layout — and removed nothing real.
                    if plugin.storage_mode == "hash" then
                        local book_dir = AnnPaths._shared_book_state_dir(state.file)
                        if book_dir then
                            os.remove(book_dir .. "/title.txt")
                            -- Route through the ownership guard: this only
                            -- removes the dir because synceryhash/<id>/ is
                            -- Syncery-owned.  In SDR mode we never reach
                            -- here, so the book's .sdr (owned by KOReader)
                            -- is left intact — only our files were removed.
                            AnnPaths.remove_owned_directory(book_dir)
                        end
                    end

                    -- Cloud-staging artifacts for this book (a sibling of
                    -- synceryhash/ at the state-dir top level).  The cloud
                    -- transport stages each payload at
                    -- <hash_root>/cloud_staging/syncery-<kind>-<id>.json
                    -- before upload, and KOReader's SyncService keeps a
                    -- `.sync` cached-ancestor right next to it (plus a
                    -- transient `.temp` while a sync is mid-flight).  Both
                    -- the staged payload and the `.sync` persist between
                    -- syncs, so without this they survive deep clean — a
                    -- later cloud push would re-observe them, and the
                    -- "all book data" promise would be a lie.  Independent
                    -- of storage_mode (the staging dir is a cloud-transport
                    -- concern, not an SDR/hash one), so this is unconditional.
                    -- os.remove on an absent path is a harmless no-op.
                    for __, p in ipairs(Adv._cloud_staging_paths(state.file)) do
                        os.remove(p)
                    end

                    -- Clear annotations on disk AND in KOReader's in-memory
                    -- list (clear_all handles annotations/annotations_paging/
                    -- bookmarks + the load-bearing in-memory clear that stops
                    -- the next save from resurrecting them).  The summary key
                    -- is a separate concern, cleared explicitly below.
                    DocSettingsBridge.clear_all(plugin.ui)
                    plugin.ui.doc_settings:saveSetting("summary", {})
                    pcall(function() plugin.ui.doc_settings:flush() end)

                    plugin:clearAnnotationCache(state.file)
                    plugin:cancelPendingSync()

                    UIManager:show(InfoMessage:new{
                        text = _("Syncery JSON files have been permanently deleted."),
                        timeout = 3,
                    })
                    plugin:_logActivity("Deep clean", "JSON, last-sync, and cloud-staging files cleared")
                end,
            })
        end),
    }
end


-- ============================================================================
-- Annotation engine options
--
-- Two opt-in sub-toggles for the annotation engine.  Both default OFF.
-- There is no `use_new_sync_engine` master switch (the engine is the
-- only engine), so these are plain unconditional rows.
-- ============================================================================


-- ============================================================================
-- Reset all settings — a destructive operation, so it belongs in the
-- "Delete and reset" block,
-- not among the troubleshooting tools.
-- ============================================================================


function Adv.reset_all(plugin)
    local reset_help = _(
        "Erase every Syncery preference on this device (transports, "
        .. "what-to-sync toggles, storage mode, device name).\n\n"
        .. "The JSON files next to your books are NOT touched — only this "
        .. "device's settings. Restart KOReader afterwards.")
    return {
        text           = _("Reset all Syncery settings…"),
        help_text      = reset_help,
        keep_menu_open = true,
        hold_callback  = H.helpHold(reset_help),
        callback       = H.safe("Reset all settings",
            function() plugin:_resetAll() end),
    }
end


-- ============================================================================
-- Build the Advanced "Delete and reset" submenu — destructive only.
-- (summary / render settings moved to "What's synced → Other content
-- types"; they are rare what-to-sync flags, not dangerous operations.)
-- ============================================================================


function Adv.build(plugin)
    return {
        Adv.deep_clean(plugin),
        Adv.reset_all(plugin),
    }
end


return Adv
