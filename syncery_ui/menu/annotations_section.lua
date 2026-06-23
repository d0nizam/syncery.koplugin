-- =============================================================================
-- syncery_ui/menu/annotations_section.lua
-- =============================================================================
--
-- "What to sync" + per-type submenus + behavior toggles.
--
-- Owns three menu trees that all read/write annotation-related
-- settings:
--
--   1. `menuWhatToSync` — the master submenu visible from Settings.
--      Dynamic labels: each row inlines what's currently enabled, so
--      the user sees state without drilling in.
--
--   2. `menuAnnotationsSubmenu` — fine-grained per-type filters
--      (highlights / notes / bookmarks) plus Trash Bin and tombstone
--      retention.
--
--   3. `menuBookMetadataSubmenu` — book status / rating / collections /
--      custom-metadata / handmade-TOC toggles.
--
-- Plus the `menuBehavior` rows (adapt_highlight_style + jump_mode) —
-- both are annotation-/progress-display flags so they live alongside
-- the per-type toggles rather than under "maintenance".
--
-- =============================================================================


local UIManager   = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer  = require("ui/widget/textviewer")

local Util         = require("syncery_util")
local Trash        = require("syncery_ui/trash/init")

local H = require("syncery_ui/menu/_helpers")
local _ = H._


local A = {}


local DEFAULT_SYNC_EXTENSIONS = "*"


-- ============================================================================
-- File-types dialog (used by "What to sync" → "File types")
-- ============================================================================


function A.editSyncExtensions(plugin, touchmenu_instance)
    local current = plugin.sync_extensions or DEFAULT_SYNC_EXTENSIONS
    local known   = "epub, pdf, djvu, xps, cbt, cbz, fb2, pdb, txt, html, rtf, chm, doc, mobi, zip"
    local desc    = string.format(
        _("Comma-separated extensions to sync, or * for every format.\n\n"
       .. "Examples:\n"
       .. "  *   (all formats — default)\n"
       .. "  pdf, epub   (only these two)\n"
       .. "  epub, mobi, fb2\n\n"
       .. "Recognised: %s"), known)

    local dlg
    dlg = InputDialog:new{
        title       = _("File types to sync"),
        description = desc,
        input       = current,
        input_type  = "string",
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dlg) end },
            { text = _("Reset to *"), callback = function()
                    plugin.sync_extensions = DEFAULT_SYNC_EXTENSIONS
                    if G_reader_settings then
                        G_reader_settings:saveSetting("syncery_sync_extensions", DEFAULT_SYNC_EXTENSIONS)
                    end
                    -- Rebuild the extension cache so the new filter takes effect
                    -- this session (mirrors the Save path). Without this the stale
                    -- pre-reset cache keeps filtering out the now-included types
                    -- despite the "all file types will be synced" message below.
                    plugin:_rebuildExtensionCache()
                    UIManager:close(dlg)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                    UIManager:show(InfoMessage:new{
                        text = _("Reset: all file types will be synced."), timeout = 2 })
                end },
            { text = _("Save"), is_enter_default = true, callback = function()
                    local input   = dlg:getInputText() or ""
                    local cleaned = {}
                    local has_wildcard = false

                    for tok in input:gmatch("[^,]+") do
                        tok = Util.trim(tok)
                        if tok == "*" then
                            has_wildcard = true
                            break
                        end
                        tok = tok:lower():gsub("^%.+", "")
                        if tok ~= "" then table.insert(cleaned, tok) end
                    end

                    local final
                    if has_wildcard then
                        final = "*"
                    else
                        final = #cleaned > 0 and table.concat(cleaned, ", ") or "*"
                    end

                    local unknown = {}
                    if final ~= "*" then
                        local known_set = {}
                        for tok in known:gmatch("[^,%s]+") do known_set[tok:lower()] = true end
                        for __, tok in ipairs(cleaned) do
                            if not known_set[tok] then table.insert(unknown, tok) end
                        end
                    end

                    plugin.sync_extensions = final
                    if G_reader_settings then
                        G_reader_settings:saveSetting("syncery_sync_extensions", final)
                    end
                    plugin:_rebuildExtensionCache()
                    UIManager:close(dlg)
                    if touchmenu_instance then touchmenu_instance:updateItems() end

                    if #unknown > 0 then
                        UIManager:show(InfoMessage:new{
                            text    = string.format(
                                _("Saved: %s\n\nNote: unrecognised extension(s) kept as-is: %s"),
                                final, table.concat(unknown, ", ")),
                            timeout = 5 })
                    else
                        UIManager:show(InfoMessage:new{
                            text = string.format(_("Saved: sync %s files."), final), timeout = 2 })
                    end
                end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end


-- ============================================================================
-- Inline-preview helpers
--
-- When a master switch is on, list the enabled sub-types as a
-- `·`-separated mini-preview right in the parent row's label, so the
-- user can see what's currently being synced without opening the
-- submenu.
-- ============================================================================


--- Return a list of short type-labels matching the currently-enabled
--- sub-toggles under `master` (e.g., "Highlights" + "Notes" if both
--- sync_highlights and sync_notes are true).  Empty list when the
--- master switch is off.
local function enabled_annotation_types(plugin)
    if not plugin.sync_annotations then return {} end
    local enabled = {}
    if plugin.sync_highlights then table.insert(enabled, _("highlights")) end
    if plugin.sync_notes      then table.insert(enabled, _("notes"))      end
    if plugin.sync_bookmarks  then table.insert(enabled, _("bookmarks"))  end
    return enabled
end


local function enabled_metadata_types(plugin)
    if not plugin.sync_metadata then return {} end
    local enabled = {}
    if plugin.sync_status         then table.insert(enabled, _("status"))      end
    if plugin.sync_rating         then table.insert(enabled, _("rating"))      end
    if plugin.sync_collections    then table.insert(enabled, _("collections")) end
    if plugin.sync_custom_metadata then table.insert(enabled, _("custom"))     end
    if plugin.sync_handmade_toc   then table.insert(enabled, _("TOC"))         end
    return enabled
end


--- Compose a "Master (preview · preview)" label.  Falls back to
--- "Master (off)" / "Master (none)" when nothing is enabled.
local function inline_preview(master_label, master_on, enabled_list)
    if not master_on then
        return string.format("%s (%s)", master_label, _("off"))
    end
    if #enabled_list == 0 then
        return string.format("%s (%s)", master_label, _("none enabled"))
    end
    return string.format("%s (%s)", master_label, table.concat(enabled_list, " · "))
end


-- ============================================================================
-- Trash Bin row — a standalone row builder, placed in the annotations
-- submenu (menuAnnotationsSubmenu) alongside the per-type filters and the
-- "Annotation sync details" help.  Gated on an open book.
-- ============================================================================


function A.trashBinRow(plugin)
    local trash_help = string.format(_(
        "Browse and restore annotations that were deleted on any device.\n\n"
        .. "Deleted annotations become tombstones so the deletion propagates "
        .. "to other devices.  Tombstones expire after %d days "
        .. "(see Tombstone retention)."), plugin.tombstone_ttl_days or 90)
    local has_doc = function()
        return (plugin.ui and plugin.ui.doc_settings ~= nil) and true or false
    end
    return {
        text           = _("Trash Bin (deleted annotations)…"),
        help_text      = trash_help,
        keep_menu_open = true,
        enabled_func   = has_doc,
        hold_callback  = H.gatedHold(has_doc,
            _("Open a book first — the Trash Bin shows that book's deleted annotations."),
            trash_help),
        callback       = H.safe("Trash Bin", function()
            local state = plugin:getCurrentState()
            if not state then
                UIManager:show(InfoMessage:new{ text = _("No document open.") })
                return
            end
            -- The annotation orchestrator compacts old tombstones on every
            -- sync (compact, never drop), so there is no separate GC pass
            -- to run before opening the bin.
            Trash.show(state.file, function()
                -- A restore flips a tombstone back to a live annotation in
                -- the shared file; sync so it merges into doc_settings and
                -- propagates to other devices.
                plugin:_syncBookViaOrchestrator(state)
                plugin:clearAnnotationCache(state.file)
            end)
        end),
    }
end


-- ============================================================================
-- Annotations submenu
-- ============================================================================


function A.menuAnnotationsSubmenu(plugin)
    local highlights_help = _(
        "Sync text highlights across devices.\n\n"
        .. "Outbound filter only — highlights already received from other "
        .. "devices are never removed even when this is off.")

    local notes_help = _(
        "Sync annotation notes across devices.\n\n"
        .. "Outbound filter only — notes already received from other "
        .. "devices are never removed even when this is off.")

    local bookmarks_help = _(
        "Sync bookmarks across devices.\n\n"
        .. "Outbound filter only — bookmarks already received from other "
        .. "devices are never removed even when this is off.")

    return {
        H.makeBoolToggle(plugin, "sync_annotations", "syncery_sync_annotations",
            _("Sync annotations"),
            _("Master switch for all annotation syncing. Turn off to stop syncing highlights, notes, and bookmarks.")),

        {
            text          = _("── Sync specific types ──"),
            enabled_func  = function() return false end,
            hold_callback = H.helpHold(_(
                "These filters control which annotation types are saved and synced.\n\n"
                .. "They only take effect when the master switch above is enabled.")),
            separator     = true,
        },

        H.makeBoolToggle(plugin, "sync_highlights", "syncery_sync_highlights",
            _("Highlights"), highlights_help, "sync_annotations"),
        H.makeBoolToggle(plugin, "sync_notes", "syncery_sync_notes",
            _("Notes"), notes_help, "sync_annotations"),
        H.makeBoolToggle(plugin, "sync_bookmarks", "syncery_sync_bookmarks",
            _("Bookmarks"), bookmarks_help, "sync_annotations"),

        {
            text          = _("── Annotation maintenance ──"),
            enabled_func  = function() return false end,
            hold_callback = H.helpHold(_(
                "Tools for managing the annotations stored in Syncery's JSON file.")),
        },
        -- Trash Bin lives here, with the annotations it recovers (domain
        -- home). Deliberately OUTSIDE the sync_annotations master gate:
        -- recovering deleted annotations must work even when annotation
        -- sync is turned off (consent-first defaults start it OFF).
        A.trashBinRow(plugin),
        {
            text_func = function()
                local days = plugin.tombstone_ttl_days or 90
                return string.format(_("Tombstone retention: %d days"), days)
            end,
            help_text = _("Number of days deleted annotations stay in Trash before being permanently removed.\n\nLonger period gives more time for sync, shorter saves space."),
            keep_menu_open = true,
            callback = function(tmi)
                local dlg
                dlg = InputDialog:new{
                    title = _("Tombstone retention (days)"),
                    input = tostring(plugin.tombstone_ttl_days or 90),
                    input_type = "number",
                    buttons = {{
                        { text = _("Cancel"), callback = function() UIManager:close(dlg) end },
                        { text = _("Save"), is_enter_default = true, callback = function()
                            local input = tonumber(dlg:getInputText())
                            if input and input >= 1 and input <= 365 then
                                plugin.tombstone_ttl_days = input
                                if G_reader_settings then
                                    G_reader_settings:saveSetting("syncery_tombstone_ttl_days", input)
                                end
                                UIManager:close(dlg)
                                if tmi then tmi:updateItems() end
                                UIManager:show(InfoMessage:new{
                                    text = string.format(_("Tombstone retention set to %d days."), input),
                                    timeout = 2,
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("Please enter a number between 1 and 365."),
                                    timeout = 3,
                                })
                            end
                        end },
                    }},
                }
                UIManager:show(dlg)
                dlg:onShowKeyboard()
            end,
        },
    }
end


-- ============================================================================
-- Book metadata submenu
-- ============================================================================


function A.menuBookMetadataSubmenu(plugin)
    return {
        H.makeBoolToggle(plugin, "sync_metadata", "syncery_sync_metadata",
            _("Sync book metadata"),
            _("Master switch for book metadata syncing (status, rating, "
            .. "collections, custom info, handmade TOC).\n\n"
            .. "Metadata is sent together with the reading progress – it updates "
            .. "every few seconds while you read, or immediately on a manual 'Sync now'.")),
        {
            text = _("── Choose which metadata to sync ──"),
            enabled_func = function() return false end,
            hold_callback = H.helpHold(_("These fields are synced only when the master switch above is enabled.")),
            separator = true,
        },
        H.makeBoolToggle(plugin, "sync_status", "syncery_sync_status",
            _("Book status"),
            _("Sync the book's status (Finished, Reading, On Hold, etc.) across devices."),
            "sync_metadata"),
        H.makeBoolToggle(plugin, "sync_rating", "syncery_sync_rating",
            _("Rating"),
            _("Sync the star rating (0–5) across devices."),
            "sync_metadata"),
        H.makeBoolToggle(plugin, "sync_collections", "syncery_sync_collections",
            _("Collection membership"),
            _("Add or remove this book from Collections to match the most-recently-updated device."),
            "sync_metadata"),
        H.makeBoolToggle(plugin, "sync_custom_metadata", "syncery_sync_custom_metadata",
            _("Custom title / authors / series"),
            _("Sync user-edited book information (custom title, authors, series, language) "
            .. "across devices.\n\nDisabled by default — turn this on only if you actually "
            .. "edit book metadata manually on one device and want those edits to reach "
            .. "the others. Uses a timestamp to resolve conflicts: the device that "
            .. "edited most recently wins."),
            "sync_metadata"),
        H.makeBoolToggle(plugin, "sync_handmade_toc", "syncery_sync_handmade_toc",
            _("Receive handmade TOC"),
            _("Apply a hand-built table of contents pushed from another device.\n\n"
            .. "Disabled by default. This controls INCOMING TOCs only — sending "
            .. "your own is the manual action below. Only works on reflowable "
            .. "documents (EPUB, FB2)."),
            "sync_metadata"),
        {
            -- Sending a handmade TOC is always an explicit manual action (a
            -- TOC is a large artifact built once, never auto-synced), so this
            -- row sits right under the receive switch and is NOT gated: it
            -- stays tappable so you can push the current book's TOC any time.
            text           = _("Push this book's handmade TOC"),
            keep_menu_open = true,
            hold_callback  = H.helpHold(_(
                "Send the current book's hand-built table of contents to your "
                .. "other devices now.\n\n"
                .. "Sending is always manual — a handmade TOC is a large artifact "
                .. "built once, so it is never auto-synced. The TOC uses text "
                .. "positions (xpointers) that only work on reflowable formats "
                .. "(EPUB, FB2); PDF and image documents are skipped. To RECEIVE "
                .. "TOCs from other devices, enable the switch above.")),
            callback       = H.safe("Push handmade TOC",
                function() plugin:pushHandmadeToc() end),
        },
    }
end


--- Per-book render-settings submenu: a master switch + one opt-in
--- sub-toggle per field.  Mirrors menuBookMetadataSubmenu, but every
--- field is OFF by default (render settings are device-specific, so the
--- user picks exactly which ones follow them).  Changes take effect the
--- next time the book is opened.
function A.menuRenderSettingsSubmenu(plugin)
    return {
        H.makeBoolToggle(plugin, "sync_render_settings", "syncery_sync_render_settings",
            _("Sync font & layout"),
            _("Master switch for syncing this book's reading appearance.\n\n"
            .. "Off by default — and even when on, NOTHING syncs until you enable "
            .. "individual settings below. Render settings are device-specific, so "
            .. "you choose exactly which ones follow you. Only reflowable documents "
            .. "(EPUB, FB2); changes take effect the next time you open the book.")),
        {
            text = _("── Choose which settings to sync ──"),
            enabled_func = function() return false end,
            hold_callback = H.helpHold(_("Each is synced only when the master switch above is on, and stays off until you turn it on.")),
            separator = true,
        },
        H.makeBoolToggle(plugin, "sync_font_face", "syncery_sync_font_face",
            _("Font (typeface)"),
            _("Sync the chosen font across devices.\n\nThe font must be installed on "
            .. "each device for it to display; otherwise that device falls back to "
            .. "its default."),
            "sync_render_settings"),
        H.makeBoolToggle(plugin, "sync_font_size", "syncery_sync_font_size",
            _("Font size"),
            _("Sync the body font size across devices. KOReader renders it "
            .. "screen-aware, so the same size feels similar on different devices."),
            "sync_render_settings"),
        H.makeBoolToggle(plugin, "sync_line_spacing", "syncery_sync_line_spacing",
            _("Line spacing"),
            _("Sync the line spacing across devices."),
            "sync_render_settings"),
        H.makeBoolToggle(plugin, "sync_font_weight", "syncery_sync_font_weight",
            _("Font weight (boldness)"),
            _("Sync the font weight / boldness adjustment across devices."),
            "sync_render_settings"),
        H.makeBoolToggle(plugin, "sync_margins", "syncery_sync_margins",
            _("Page margins"),
            _("Sync the page margins across devices.\n\nMargins are the most "
            .. "screen-dependent setting: a comfortable margin on a phone is wrong "
            .. "on a large e-reader. Best left off unless your devices have similar "
            .. "screen sizes."),
            "sync_render_settings"),
    }
end


-- ============================================================================
-- "What to sync" submenu
--
-- This is the top-level submenu the user opens from Settings. Each
-- parent row is a dynamic label that summarises what's enabled below it.
-- ============================================================================


function A.menuWhatToSync(plugin)
    local position_help = _(
        "Everything about your reading position across devices: send this "
        .. "device's position, choose what happens when another device is "
        .. "ahead, or jump to a specific device on demand.")

    local annotations_help = _(
        "Sync highlights, notes, and bookmarks across devices.\n\n"
        .. "Open this submenu to enable/disable annotation syncing entirely, "
        .. "or control each type individually.")

    local metadata_help = _(
        "Sync book status (Finished / Reading / On Hold), star rating, "
        .. "collection membership, custom book info, and handmade table of "
        .. "contents across devices.\n\n"
        .. "Open this submenu to toggle metadata syncing and its individual fields.")

    local render_help = _(
        "Sync font size, font face, line spacing, font weight, and margins for "
        .. "individual books across devices.\n\n"
        .. "Off by default — most users prefer their per-device reading "
        .. "preferences to stay device-local (an e-ink reader has very "
        .. "different optimal margins than a phone screen).\n\n"
        .. "Only meaningful for reflowable documents (EPUB, FB2, MOBI). "
        .. "PDF and similar fixed-layout formats are unaffected.")

    local summary_help = _(
        "Sync the per-book summary note you can leave from the book's "
        .. "metadata screen.  Off by default — most people don't use it, "
        .. "and the field is small enough that adding it to sync increases "
        .. "merge surface area without much benefit.")

    local adapt_help = _(
        "Show highlights from other devices in this device's highlight "
        .. "style, without the colour they were given on the other device; "
        .. "your own highlights keep the style you gave them. Most useful on "
        .. "a grayscale e-reader, where a colour from a colour device isn't "
        .. "visible anyway.\n\n"
        .. "Does not alter the stored annotation; only affects how it is "
        .. "displayed here.\n\n"
        .. "Works even while syncing is paused.")

    local filetype_help = _(
        "Restrict syncing to certain file extensions, or use * for every "
        .. "format (the default).\n\n"
        .. "Useful if you keep non-book files in the same folder and want "
        .. "Syncery to ignore them.")

    -- GOVERNING PRINCIPLE: rows are grouped by the NATURE of the sync link,
    -- not by frequency.  "Reading position" is surfaced first because it is
    -- the one cluster where direction is a real choice; everything else is
    -- either symmetric ("synced both ways") or local to this device.
    return {
        {
            text                = _("Reading position"),
            help_text           = position_help,
            hold_callback       = H.helpHold(position_help),
            sub_item_table_func = function() return A.menuReadingPosition(plugin) end,
        },

        {
            text         = _("── synced both ways ──"),
            enabled_func = function() return false end,
            separator    = true,
        },
        {
            -- Inline preview: "Annotations (highlights · notes)"
            text_func = function()
                return inline_preview(_("Annotations"),
                    plugin.sync_annotations == true,
                    enabled_annotation_types(plugin))
            end,
            help_text           = annotations_help,
            hold_callback       = H.helpHold(annotations_help),
            sub_item_table_func = function() return A.menuAnnotationsSubmenu(plugin) end,
        },
        {
            -- Inline preview: "Book metadata (status · rating)"
            text_func = function()
                return inline_preview(_("Book metadata"),
                    plugin.sync_metadata == true,
                    enabled_metadata_types(plugin))
            end,
            help_text           = metadata_help,
            hold_callback       = H.helpHold(metadata_help),
            sub_item_table_func = function() return A.menuBookMetadataSubmenu(plugin) end,
        },
        {
            text                = _("Font & layout…"),
            help_text           = render_help,
            keep_menu_open      = true,
            hold_callback       = H.helpHold(render_help),
            sub_item_table_func = function() return A.menuRenderSettingsSubmenu(plugin) end,
        },
        H.makeBoolToggle(plugin, "sync_summary", "syncery_sync_summary",
            _("Per-book summary note"), summary_help),

        {
            text         = _("── on this device ──"),
            enabled_func = function() return false end,
            separator    = true,
        },
        {
            text           = _("Adapt highlight style to this device"),
            help_text      = adapt_help,
            keep_menu_open = true,
            checked_func   = function() return plugin.adapt_highlight_style end,
            hold_callback  = H.helpHold(adapt_help),
            callback       = function(tmi)
                plugin.adapt_highlight_style = not plugin.adapt_highlight_style
                if G_reader_settings then
                    G_reader_settings:saveSetting("syncery_adapt_highlight_style",
                        plugin.adapt_highlight_style)
                end
                if tmi then tmi:updateItems() end
            end,
        },
        {
            text_func = function()
                local ext = plugin.sync_extensions or DEFAULT_SYNC_EXTENSIONS
                return ext == "*"
                    and _("File types: all formats  (*)")
                    or  string.format(_("File types: %s"), ext)
            end,
            help_text      = filetype_help,
            keep_menu_open = true,
            hold_callback  = H.helpHold(filetype_help),
            callback       = H.safe("File types", function(tmi)
                A.editSyncExtensions(plugin, tmi)
            end),
        },
    }
end


-- ============================================================================
-- "Reading position" — the one What's-synced cluster where direction is a
-- genuine choice.  Three rows, one per direction of the link:
--   send    -- "Share my position from this device" (the sync_progress toggle)
--   receive -- "Another device's new position" (the jump_mode radio submenu;
--              the parent row shows the active mode inline)
--   pull    -- "Jump to another device now…" (opens the status panel via
--              showSyncStatus)
-- ============================================================================


function A.menuReadingPosition(plugin)
    local progress_help = _(
        "Send this device's reading position — your current page and "
        .. "percentage — so your other devices can follow it.\n\n"
        .. "Written automatically as you read and whenever you close or "
        .. "suspend the reader.")

    local jump_help = _(
        "What to do when another device reaches a new position in this book:\n\n"
        .. "Jump automatically — move to the new position, with a brief "
        .. "[Undo].\n"
        .. "Ask first — show a tappable note; you choose whether to jump.\n"
        .. "Never — stay put; this device is never moved by another.\n\n"
        .. "Either way you can still jump on demand from \"Jump to "
        .. "another device now…\" below.  Undo the last jump within "
        .. "60 seconds from Menu → Syncery → This book → Undo last jump.")

    local pull_help = _(
        "Pick another device and jump to its reading position on demand.  "
        .. "Works in any mode, including \"Never\".")

    local function jump_mode_label()
        local m = plugin.jump_mode or "ask"
        if m == "auto" then return _("Jump automatically")
        elseif m == "never" then return _("Never jump")
        else return _("Ask first") end
    end

    local rows = {
        -- send
        H.makeBoolToggle(plugin, "sync_progress", "syncery_sync_progress",
            _("Share my position from this device"), progress_help),
        -- receive
        {
            text_func = function()
                return string.format(_("Another device's new position: %s"),
                    jump_mode_label())
            end,
            help_text           = jump_help,
            keep_menu_open      = true,
            sub_item_table_func = function() return A.menuJumpMode(plugin) end,
            hold_callback       = H.helpHold(jump_help),
        },
    }

    -- pull — opens the current book's status panel on demand.  Book-dependent,
    -- so it is omitted entirely in the file browser (hidden, not greyed).
    if plugin.ui and plugin.ui.doc_settings ~= nil then
        table.insert(rows, {
            text           = _("Jump to another device now…"),
            help_text      = pull_help,
            keep_menu_open = true,
            hold_callback  = H.helpHold(pull_help),
            callback       = H.safe("Jump to another device", function()
                plugin:showSyncStatus()
            end),
        })
    end

    return rows
end


-- ============================================================================
-- Jump-mode radio submenu — how a newer remote position is received.
--   "auto"  jump straight away (with an [Undo] toast)
--   "ask"   non-blocking invite; the user taps to jump  (default)
--   "never" no automatic jump at all (manual jump from the status panel
--           still works -- it calls _doJump directly, bypassing _promptJump)
-- ============================================================================
function A.menuJumpMode(plugin)
    local function set(mode)
        return function(tmi)
            plugin.jump_mode = mode
            if G_reader_settings then
                G_reader_settings:saveSetting("syncery_jump_mode", mode)
            end
            if tmi then tmi:updateItems() end
        end
    end
    return {
        {
            text           = _("Jump automatically"),
            radio          = true,
            keep_menu_open = true,
            checked_func   = function() return plugin.jump_mode == "auto" end,
            callback       = set("auto"),
        },
        {
            text           = _("Ask first"),
            radio          = true,
            keep_menu_open = true,
            checked_func   = function() return plugin.jump_mode == "ask" end,
            callback       = set("ask"),
        },
        {
            text           = _("Never jump"),
            radio          = true,
            keep_menu_open = true,
            checked_func   = function() return plugin.jump_mode == "never" end,
            callback       = set("never"),
        },
    }
end


return A
