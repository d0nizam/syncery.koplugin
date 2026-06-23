-- =============================================================================
-- syncery_ui/menu/per_book_section.lua
-- =============================================================================
--
-- Per-book actions.  Everything in this section is meaningful only
-- when a document is open: pushing a TOC, undoing a jump, resetting
-- this book's synced data.
--
-- Disabled-with-reason is the dominant pattern here.
-- Every row is gated on `plugin.ui.doc_settings` being non-nil; when
-- no book is open, the rows go grey and long-press explains "open a
-- book first".  Rather than hiding the section entirely (which would
-- make the menu rearrange under the user's finger every time they
-- close a document), we keep the rows present-but-disabled.
--
-- The unsafe operations (Deep clean — irreversibly delete JSON files)
-- live under `advanced_section.lua`, not here: dangerous things go
-- under Advanced with extra friction.
--
-- =============================================================================


local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox  = require("ui/widget/confirmbox")
local ButtonDialog = require("ui/widget/buttondialog")

local AnnPaths      = require("syncery_ann/paths")
local AnnStateStore = require("syncery_ann/state_store")
local StatusLattice = require("syncery_ann/status_lattice")
local MetadataBridge = require("syncery_ann/metadata_bridge")
local AnnTimeFormat = require("syncery_ann/time_format")
local ProgressPaths = require("syncery_progress/paths")
local SyncJournal   = require("syncery_progress/sync_journal")
local Util          = require("syncery_util")
local DocSettingsBridge = require("syncery_ann/doc_settings_bridge")

local H = require("syncery_ui/menu/_helpers")
local _ = H._


local P = {}


-- ============================================================================
-- "Undo last jump" — gated on the 60-second undo window
-- ============================================================================


local function undo_jump_available(plugin)
    return (plugin.pre_jump_until and os.time() <= plugin.pre_jump_until) and true or false
end


function P.undo_jump(plugin)
    local help = _(
        "Return to the page you were on before the last jump.\n\n"
        .. "Available for 60 seconds after each jump.  After that window "
        .. "closes, use \"Jump to another device now…\" (under Reading "
        .. "position) to jump manually.")
    local gate_reason = _(
        "No recent jump to undo, or the 60-second undo window has closed.\n\n"
        .. "Open another book, jump to another device's position, then this "
        .. "item will become available again.")
    return {
        text           = _("Undo last jump"),
        help_text      = help,
        keep_menu_open = true,
        enabled_func   = function() return undo_jump_available(plugin) end,
        hold_callback  = H.gatedHold(
            function() return undo_jump_available(plugin) end,
            gate_reason, help),
        callback       = H.safe("Undo jump", function() plugin:_undoLastJump() end),
    }
end


-- ============================================================================
-- Full reset — mark all annotations as deleted on every device
--
-- This is the SAFE per-book reset.  Annotations become tombstones, so
-- they can be restored from the Trash Bin for the configured TTL
-- (default 90 days).  Progress files get unlinked and last-sync
-- ancestor wiped so the merge starts from a clean baseline.
--
-- The unsafe equivalent (Deep clean — physically delete JSON files)
-- lives under Advanced.
-- ============================================================================


-- ============================================================================
-- Delete all annotations for this book (KEEPS progress)
--
-- Distinct from Full reset: this clears only annotations (highlights,
-- notes, bookmarks) and KEEPS your reading position. Routed to the
-- backend `_deleteAllAnnotationsForCurrentBook`, which moves the
-- annotations to Trash but never touches the progress file. The mockup
-- places this in "This book" alongside Full reset so the user has the
-- finer-grained option without digging into the annotations submenu.
-- ============================================================================


function P.delete_all_annotations(plugin)
    local has_doc = function()
        return (plugin.ui and plugin.ui.doc_settings ~= nil) and true or false
    end
    local help = _(
        "Move every annotation (highlights, notes, bookmarks) for this book "
        .. "to the Trash Bin, but KEEP your reading position.\n\n"
        .. "Use this when you want clean annotations without losing where you "
        .. "are. Different from Full reset, which also clears progress. "
        .. "Restorable from the Trash Bin for 90 days.")
    return {
        text           = _("Delete annotations only (keeps progress)"),
        help_text      = help,
        keep_menu_open = true,
        enabled_func   = has_doc,
        hold_callback  = H.gatedHold(has_doc,
            _("Open a book first — this clears the current book's annotations."),
            _("Tap to move this book's annotations to Trash, keeping your progress.")),
        callback       = H.safe("Delete annotations only",
            function() plugin:_deleteAllAnnotationsForCurrentBook() end),
    }
end


function P.full_reset(plugin)
    return {
        text           = _("Full reset – mark all as deleted (all devices)"),
        help_text      = _(
            "Marks ALL annotations (on every device) as deleted and removes the "
            .. "progress file for this book.\n\n"
            .. "Reading status, rating, and render settings stay — they're the "
            .. "book's own KOReader state, not removed by this. The deleted "
            .. "annotations stay in the Trash Bin for a while, "
            .. "so they can be restored if you change your mind.\n\n"
            .. "To clear the screen, please reopen the book after performing this reset."),
        keep_menu_open = true,
        enabled_func   = function() return (plugin.ui and plugin.ui.doc_settings ~= nil) and true or false end,
        hold_callback  = H.gatedHold(
            function() return (plugin.ui and plugin.ui.doc_settings ~= nil) and true or false end,
            _("Open a book first — this reset operates on the current book."),
            _("Tap to mark all synced data for this book as deleted on every device.")),
        callback       = H.safe("Full reset", function()
            local state = plugin:getCurrentState()
            if not state then
                UIManager:show(InfoMessage:new{ text = _("No document open.") })
                return
            end

            UIManager:show(ConfirmBox:new{
                text = _("This deletes this book's annotations and reading progress on ALL devices.\n\nReading status, rating, and render settings stay — they're the book's own KOReader state.\n\nAre you sure?"),
                ok_text = _("Delete all"),
                ok_callback = function()
                    -- Mark every alive annotation in the shared file as
                    -- a tombstone.  The new engine stores annotations as
                    -- a position-keyed map and timestamps with UTC
                    -- datetime strings, so we iterate the map and
                    -- set `datetime_updated`, not a numeric `modified_at`.
                    local ann_data = AnnStateStore.load_shared(state.file)
                    local alive    = 0
                    if ann_data and type(ann_data.annotations) == "table" then
                        local now = AnnTimeFormat.now()
                        for _key, a in pairs(ann_data.annotations) do
                            if a and not a.deleted then
                                a.deleted          = true
                                a.datetime_updated = now
                                a.device_id        = plugin.device_id
                                a.device_label     = plugin.device_label
                                alive = alive + 1
                            end
                        end
                        local ok_save = AnnStateStore.save_shared(
                            state.file, ann_data)
                        if not ok_save then
                            UIManager:show(InfoMessage:new{
                                text = _("Could not update annotations file."),
                                timeout = 3,
                            })
                            return
                        end
                    end

                    -- Wipe BOTH shared and last-sync progress files, AND
                    -- the last-sync annotation ancestor.  Wiping only the
                    -- shared file would let the next 3-way merge resurrect
                    -- ghost entries (shared = empty, last-sync = old,
                    -- local = new → ghosts come back).  See P14.
                    local prog_path      = ProgressPaths.shared_progress_path(state.file)
                    local prog_last_sync = ProgressPaths.last_sync_progress_path(state.file)
                    local ann_last_sync  = AnnPaths.last_sync_annotations_path(state.file)
                    if prog_path      then os.remove(prog_path)      end
                    if prog_last_sync then os.remove(prog_last_sync) end
                    if ann_last_sync  then os.remove(ann_last_sync)  end

                    -- Clear annotations on disk AND in KOReader's in-memory
                    -- list (clear_all: annotations/annotations_paging/bookmarks
                    -- + the load-bearing in-memory clear that prevents the next
                    -- save from resurrecting them).  Summary is separate below.
                    DocSettingsBridge.clear_all(plugin.ui)
                    plugin.ui.doc_settings:saveSetting("summary", {})
                    pcall(function() plugin.ui.doc_settings:flush() end)

                    plugin:clearAnnotationCache(state.file)
                    plugin:cancelPendingSync()

                    UIManager:show(InfoMessage:new{
                        text = _("All synced data has been marked as deleted."),
                        timeout = 3,
                    })
                    plugin:_logActivity("Full book reset", string.format("annot=%d", alive))
                end,
            })
        end),
    }
end


-- ============================================================================
-- Status conflict — surfaced ONLY when this book's reading status genuinely
-- differs across devices (complete vs abandoned at the same generation, via
-- the lifecycle lattice).  P.status_conflict
-- returns a row only when such a conflict exists, so it appears at the top of
-- "This book" exactly when relevant and is absent otherwise (no permanent
-- disabled row).  Tapping opens a picker; choosing a value writes it at
-- generation+1 so it DOMINATES the conflict and converges on every device.
-- ============================================================================


-- KOReader's own user-facing names for the two terminal states (the only pair
-- that can conflict).  Other values fall back to the raw string.
local function status_label(value)
    if     value == "complete"  then return _("Finished")
    elseif value == "abandoned" then return _("On hold")
    end
    return value
end


local function device_of(candidate)
    return (candidate.device_label and candidate.device_label ~= "" and candidate.device_label)
           or candidate.device_id or _("an unknown device")
end


--- The open book's conflicted status candidates, or nil if there is no open
--- book / no shared file / no conflict.  Defensive: a menu build must never
--- crash, so the shared-file read is guarded.
local function current_status_conflict(plugin)
    local state = plugin and plugin.getCurrentState and plugin:getCurrentState()
    if not state or not state.file then return nil end
    local ok, shared = pcall(AnnStateStore.load_shared, state.file)
    if not ok or type(shared) ~= "table" or type(shared.metadata) ~= "table" then
        return nil
    end
    return StatusLattice.conflict_candidates(shared.metadata.status)
end


--- Write the chosen value as the resolution.  Crucially this does NOT just set
--- the local status and re-sync: an explicit resolution to the value THIS
--- device already contributed would not bump the generation through the normal
--- collect (status_lattice.local_entry only bumps when a device CHANGES its
--- value), so the conflict would survive.  Instead we resolve() the shared
--- entry to generation+1 (always dominating) and write it to the shared file;
--- the merge then preserves it (it reads the shared file as "remote", where the
--- higher generation wins) and propagates it everywhere.
local function resolve_to(plugin, chosen_value, chosen_label)
    local state = plugin and plugin.getCurrentState and plugin:getCurrentState()
    if not state or not state.file then return end

    -- Re-read: another device may have resolved it since the menu opened.
    local shared = AnnStateStore.load_shared(state.file)
    local status = (type(shared) == "table" and type(shared.metadata) == "table")
                   and shared.metadata.status or nil
    if not StatusLattice.is_conflict(status) then
        UIManager:show(InfoMessage:new{
            text = _("This status difference has already been resolved."),
            timeout = 3 })
        return
    end

    shared.metadata.status = StatusLattice.resolve(
        status, chosen_value, plugin.device_id, plugin.device_label)
    if not AnnStateStore.save_shared(state.file, shared) then
        UIManager:show(InfoMessage:new{
            text = _("Could not save the resolved status."),
            timeout = 3 })
        return
    end

    -- Journal the resolution (kind="status"); pcall-isolated so a diagnostic
    -- writer never breaks the resolution.  status_from is derived from the
    -- pre-resolution conflict candidates (the `status` local, captured before
    -- resolve() overwrote shared.metadata.status), sorted for a stable label.
    pcall(function()
        local cands = StatusLattice.conflict_candidates(status) or {}
        local from_values = {}
        for _idx, c in ipairs(cands) do from_values[#from_values + 1] = c.value end
        table.sort(from_values)
        SyncJournal.record_status_resolve(
            AnnPaths._book_content_id(state.file),
            table.concat(from_values, "-vs-"),
            chosen_value,
            { transport           = Util.transport_label(plugin.use_syncthing, plugin.use_cloud),
              max_entries         = plugin.journal_max_entries,
              writer_device_label = plugin.device_label })
    end)

    -- Reflect the choice in the open book immediately (the sync's own apply
    -- would also do this, but this updates the live status without waiting for
    -- the round-trip), then push so the other devices pick it up.
    MetadataBridge._apply_status(plugin.ui, state.file, chosen_value)
    if plugin.syncNow then plugin:syncNow() end
    if plugin._logActivity then
        plugin:_logActivity("Status conflict resolved", chosen_value)
    end

    UIManager:show(InfoMessage:new{
        text = string.format(_("Reading status set to '%s' on all devices."), chosen_label),
        timeout = 3 })
end


function P.status_conflict(plugin)
    local candidates = current_status_conflict(plugin)
    if not candidates then return nil end   -- no conflict -> no row at all

    return {
        text           = _("⚠ Reading status differs — tap to resolve"),
        help_text      = _(
            "This book is marked with different reading statuses on different "
            .. "devices. Tap to choose which one to keep on all of them."),
        keep_menu_open = true,
        callback       = H.safe("Resolve status conflict", function()
            local lines = {}
            for _idx, c in ipairs(candidates) do
                table.insert(lines,
                    string.format("• %s — %s", status_label(c.value), device_of(c)))
            end

            local dialog
            local value_row = {}
            for _idx, c in ipairs(candidates) do
                local label = status_label(c.value)
                table.insert(value_row, {
                    text = label,
                    callback = function()
                        UIManager:close(dialog)
                        resolve_to(plugin, c.value, label)
                    end,
                })
            end

            dialog = ButtonDialog:new{
                title = _("This book's reading status differs across your devices:")
                        .. "\n\n" .. table.concat(lines, "\n") .. "\n\n"
                        .. _("Tap a status below to keep it on all your devices."),
                title_align = "center",
                buttons = {
                    value_row,
                    {{ text = _("Cancel"),
                       callback = function() UIManager:close(dialog) end }},
                },
            }
            UIManager:show(dialog)
        end),
    }
end


-- ============================================================================
-- Public composition: the per-book submenu
--
-- The submenu the user opens from "Per-book actions" (or whatever
-- the top-level menu calls it).  We expose individual rows too so
-- buildTopMenu can lift "Push TOC" / "Undo jump" up to the top level
-- if it wants the "actionable at a glance" feel.
-- ============================================================================


--- The book-data-management submenu — just the SAFE reset.  Deep
--- clean and "reset all books" moved to advanced_section.
return P
