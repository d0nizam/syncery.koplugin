-- =============================================================================
-- syncery_ui/menu/init.lua
-- =============================================================================
--
-- Menu orchestrator.  Composes the section modules into the top-level
-- menu main.lua hits via addToMainMenu:
--
--   * `buildTopMenu(plugin)`      — the Syncery top-level menu, organized
--                                   by user intent: status,
--                                   What's synced, Transports, Progress
--                                   Browser, Annotation Browser, This book,
--                                   Tools, Advanced.
--   * `buildTransportsMenu(plugin)` — the Transports submenu (Syncthing /
--                                   cloud transport setup).
--   * `buildAdvancedMenu(plugin)` — storage, this device, help, and the
--                                   delete/reset block.
--
-- The section files don't import each other; they all import
-- `_helpers`, and `init.lua` is the only place that knows about all
-- of them.  That keeps the dependency graph fan-in (everyone reads
-- helpers; only init knows everyone).
--
-- Status-snapshot cache discipline: `buildTopMenu` wraps the section calls
-- in a `pcall` and then unconditionally clears the status snapshot
-- via `H.clear_status_snapshot(plugin)` so the next render starts
-- fresh — even if a section raised.  Without that clear, a stale
-- snapshot could survive across menu opens and show wrong data.
--
-- Separator-based grouping is applied to the
-- top menu: the three clusters (status / per-book / settings+help)
-- are separated by `separator = true` rows.  The status section
-- already includes its own separator; we add one before "Settings".
--
-- =============================================================================


local H              = require("syncery_ui/menu/_helpers")
local StatusSection  = require("syncery_ui/menu/status_section")
local TransportSec   = require("syncery_ui/menu/transport_section")
local AnnSec         = require("syncery_ui/menu/annotations_section")
local PerBookSec     = require("syncery_ui/menu/per_book_section")
local MaintSec       = require("syncery_ui/menu/maintenance_section")
local AdvSec         = require("syncery_ui/menu/advanced_section")

local _ = H._


local Menu = {}


-- Sections exposed so tests and future code can address them
-- individually.  Sections are addressable as Menu.sections.X (there is
-- no single `MenuBuilder.*` namespace).
Menu.sections = {
    status      = StatusSection,
    transport   = TransportSec,
    annotations = AnnSec,
    per_book    = PerBookSec,
    maintenance = MaintSec,
    advanced    = AdvSec,
}

-- Helpers are exposed so spec files (or future sections) can use the
-- same `safe / helpHold / gatedHold / makeBoolToggle / status_snapshot`
-- without needing a separate require.
Menu.helpers = H


-- ============================================================================
-- Settings submenu
--
-- The "Settings" branch the user opens from the top menu.  Each row
-- is a sub_item_table_func that lazy-builds its section — the section
-- code only runs when the user actually opens it, keeping the top
-- menu cheap to render.
-- ============================================================================


-- ============================================================================
-- Transports — intent grouping
--
-- "Transports" answers "how does this device sync" — the Syncthing and
-- cloud transport setup.  (The status-panel door is at the top level,
-- next to the smart header.)
-- ============================================================================


function Menu.buildTransportsMenu(plugin)
    local rows = {}

    -- Transport setup (Syncthing / Cloud). The transport section
    -- builds the per-transport rows; the architectural entry for the
    -- unified wizard lives inside it.
    local ok, transport_rows = pcall(TransportSec.build, plugin)
    if ok then
        for __, row in ipairs(transport_rows) do table.insert(rows, row) end
    end

    return rows
end


-- ============================================================================
-- Advanced — the single predictable home for set-once / diagnostic items
-- (THE GOVERNING PRINCIPLE). Storage mode and "This device" move here from
-- the old Maintenance section; the danger block and diagnostics are their
-- own submenus (mockup finding B — keeps the e-ink screen short).
-- ============================================================================


function Menu.buildAdvancedMenu(plugin)
    return {
        {
            text_func           = function()
                local mode = (plugin.storage_mode == "hash")
                    and _("Synceryhash") or _("SDR sidecar")
                return string.format(_("Storage mode: %s"), mode)
            end,
            help_text           = _(
                "SDR keeps files in each book's sidecar folder; Synceryhash "
                .. "keeps them by content so they survive renames."),
            keep_menu_open      = true,
            hold_callback       = H.helpHold(_(
                "Choose where Syncery stores its JSON files: SDR sidecars "
                .. "or a Synceryhash directory.")),
            sub_item_table_func = function() return MaintSec.menuStorageMode(plugin) end,
        },
        {
            text_func           = function()
                return string.format(_("This device: %s"),
                    require("syncery_util").get_device_label())
            end,
            help_text           = _("Rename this device or view its ID."),
            keep_menu_open      = true,
            hold_callback       = H.helpHold(_(
                "The name other devices see for this one, and its unique ID.")),
            sub_item_table_func = function() return MaintSec.menuThisDevice(plugin) end,
        },
        MaintSec.copyDiagnosticInfoItem(plugin),
        MaintSec.bookDataSaveIntervalItem(plugin),
        {
            text                = _("Delete and reset"),
            help_text           = _(
                "Destructive operations: deep clean this book's files, or "
                .. "reset all Syncery settings."),
            keep_menu_open      = true,
            hold_callback       = H.helpHold(_(
                "Deep clean (permanently delete this book's JSON files) and "
                .. "reset-all-settings live here. Each confirms before acting.")),
            sub_item_table_func = function() return AdvSec.build(plugin) end,
        },
    }
end


-- ============================================================================
-- Top-level menu — organized by intent, not implementation.
--
-- Order follows the GOVERNING PRINCIPLE (frequency, then reach):
--   1. Status cluster — smart header, Sync this book, Sync now.
--   2. What's synced  — everyday core + "Other content types…" disclosure.
--   3. Transports     — Syncthing / cloud transport setup.
--   4. This book      — per-book actions.
--   5. Tools          — backfill, manage books, cleanup, journal, transport upkeep.
--   6. Advanced       — storage, device, help, delete/reset.
-- ============================================================================


function Menu.buildTopMenu(plugin)
    -- First-run dialog is a side-effect of menu open;
    -- kept for behaviour parity. Wrapped in pcall so a malformed
    -- plugin doesn't crash menu rendering.
    pcall(function() plugin:maybeShowFirstRunDialog() end)

    local items = {}
    -- Per-book rows are hidden (not greyed) in the file browser.  The whole
    -- menu is rebuilt on every open (addToMainMenu uses sub_item_table_func),
    -- so they reappear the moment a book is open.
    local has_doc = (plugin.ui and plugin.ui.doc_settings ~= nil) and true or false
    local function insert_if_doc(item)
        if has_doc then table.insert(items, item) end
    end
    local function append_all(list)
        for __, row in ipairs(list) do table.insert(items, row) end
    end

    -- 0. A genuine reading-status conflict for the open book is an actionable
    --    issue, so surface it ABOVE the status cluster — visible without diving
    --    into "This book".  Reuses the same row builder (and resolve picker);
    --    returns nil when there is no open book / no conflict, so it is absent
    --    the rest of the time.  It still also appears under "This book".
    local conflict_row = PerBookSec.status_conflict(plugin)
    if conflict_row then table.insert(items, conflict_row) end

    -- 1. Status cluster (smart header + sync-this-book + sync-now). The
    --    status section sets its own trailing separator.
    local ok_status, status_rows = pcall(StatusSection.build, plugin)
    if ok_status then append_all(status_rows) end

    -- 2. What's synced — dynamic inline preview in the row label.
    table.insert(items, {
        text_func = function()
            local bits = {}
            if plugin.sync_progress    then table.insert(bits, _("progress"))    end
            if plugin.sync_annotations then table.insert(bits, _("annotations")) end
            if plugin.sync_metadata    then table.insert(bits, _("metadata"))    end
            if #bits == 0 then return _("What's synced (nothing yet)") end
            if #bits >= 3 then return _("What's synced (all)")         end
            return string.format(_("What's synced (%s)"), table.concat(bits, " · "))
        end,
        help_text           = _(
            "Choose which data Syncery saves and syncs: progress, "
            .. "annotations, book metadata, and the rarer content types."),
        keep_menu_open      = true,
        hold_callback       = H.helpHold(_(
            "Choose what Syncery saves and syncs. The everyday types are "
            .. "shown directly; the rarer ones live under 'Other content types'.")),
        sub_item_table_func = function() return AnnSec.menuWhatToSync(plugin) end,
    })

    -- 3. Transports.
    table.insert(items, {
        text                = _("Transports"),
        help_text           = _(
            "Set up how this device syncs: Syncthing or cloud storage."),
        keep_menu_open      = true,
        hold_callback       = H.helpHold(_(
            "Sync setup. Long-press a transport row to open its panel.")),
        sub_item_table_func = function() return Menu.buildTransportsMenu(plugin) end,
    })

    -- 3a. Progress Browser — cross-device reading-PROGRESS dashboard
    --     (sync-aware; reads the SHARED progress state).  Lands on the
    --     all-books view even while reading: the in-reading prompt does the
    --     in-book job, so this dashboard is for review across the library.
    table.insert(items, {
        text                = _("Progress Browser"),
        help_text           = _(
            "See where every device has read to, across all your synced books."),
        keep_menu_open      = false,
        hold_callback       = H.helpHold(_(
            "Reads the shared sync state, so it shows each synced book's "
            .. "reading position on every device — including your other "
            .. "devices. Read-only.\n\n"
            .. "Position is shown as a percentage, which is comparable across "
            .. "devices; page numbers are not (they vary by font and screen). "
            .. "Tap a book to see every device's position.")),
        callback            = function() plugin:onSynceryProgressBrowser() end,
    })

    -- 3b. Annotation Browser — browse synced highlights/notes across all books
    --     (sync-aware; reads the SHARED state).  Current-book view while
    --     reading, all-books view in the file browser.
    table.insert(items, {
        text                = _("Annotation Browser"),
        help_text           = _(
            "Browse your synced highlights and notes across all books."),
        keep_menu_open      = false,
        hold_callback       = H.helpHold(_(
            "Reads the shared sync state, so it shows your highlights and notes "
            .. "from all synced books in one place — including ones made on "
            .. "your other devices. Read-only.\n\n"
            .. "It shows each book's LAST SYNCED state. If you add or delete "
            .. "annotations in a book and have not reopened it since, those "
            .. "changes show up here only after that book is reopened — that is "
            .. "when Syncery reconciles it (and propagates it to your other "
            .. "devices).\n\n"
            .. "So if you tap an annotation, the book opens, and nothing is "
            .. "there — that is the reason.")),
        callback            = function() plugin:onSynceryAnnotationBrowser() end,
    })

    -- 4. This book — per-book actions.  Book-dependent: the whole entry is
    --    omitted in the file browser (hidden, not greyed).
    insert_if_doc({
        text                = _("This book"),
        help_text           = _(
            "Actions for the book you're reading: undo the last jump, "
            .. "clear annotations, or fully reset it."),
        keep_menu_open      = true,
        hold_callback       = H.helpHold(_(
            "Per-book actions for the open book.")),
        separator           = true,
        sub_item_table_func = function()
            local rows = {}
            -- Surfaced only when this book's reading status genuinely conflicts
            -- across devices; otherwise status_conflict returns nil and the row
            -- is absent.
            local conflict = PerBookSec.status_conflict(plugin)
            if conflict then table.insert(rows, conflict) end
            table.insert(rows, PerBookSec.undo_jump(plugin))
            table.insert(rows, PerBookSec.delete_all_annotations(plugin))
            table.insert(rows, PerBookSec.full_reset(plugin))
            return rows
        end,
    })

    -- 5. "Tools" — data management + maintenance + diagnostics (was
    --    "Something not working?", which mis-framed proactive features —
    --    backfill, manage books, the journal — as troubleshooting).
    table.insert(items, {
        text                = _("Tools"),
        help_text           = _(
            "Manage and maintain your Syncery data: backfill old annotations, "
            .. "manage synced books, remove leftover files, view the sync "
            .. "journal, and transport upkeep."),
        keep_menu_open      = true,
        hold_callback       = H.helpHold(_(
            "Backfill, manage, and clean your synced data; review the sync "
            .. "journal; run transport maintenance.")),
        separator           = true,
        sub_item_table_func = function() return MaintSec.build(plugin) end,
    })

    -- 6. Advanced — set-once / diagnostic / destructive, one predictable home.
    table.insert(items, {
        text                = _("Advanced"),
        help_text           = _(
            "Storage mode, this device, how Syncery works, and "
            .. "delete/reset. Rarely needed."),
        keep_menu_open      = true,
        hold_callback       = H.helpHold(_(
            "One predictable home for the rare set-once and diagnostic "
            .. "items, plus destructive operations.")),
        separator           = true,
        sub_item_table_func = function() return Menu.buildAdvancedMenu(plugin) end,
    })

    -- 7. Check for plugin updates — its own entry below Advanced.  A separate,
    --    rarely-used action: fetch the latest Syncery release from GitHub,
    --    show the notes, install it, and restart.
    table.insert(items, {
        text           = _("Check for plugin updates"),
        help_text      = _(
            "Check GitHub for a newer Syncery release and install it."),
        keep_menu_open = true,
        hold_callback  = H.helpHold(_(
            "Fetches the latest release, shows the notes, and installs it "
            .. "in place with a restart.")),
        callback       = H.safe("Check for plugin updates",
            function() require("syncery_update").check() end),
    })

    -- Clear the status snapshot cache so the next render starts
    -- fresh (text_func closures re-populate it at render time).
    H.clear_status_snapshot(plugin)

    return items
end


return Menu
