-- =============================================================================
-- spec/menu_annotations_section_spec.lua
-- =============================================================================
--
-- Tests for syncery_ui/menu/annotations_section.lua.
--
-- Focus areas:
--   * Pattern 3 inline previews: "Annotations (highlights · notes)" /
--     "Book metadata (status · rating)".
--   * Pattern 2 gating: Trash Bin and "Delete all annotations" are
--     gated on a document being open.
--   * Master-switch propagation for sub-toggles.
-- =============================================================================


local h            = require("spec.test_helpers")
local menu_support = require("spec.menu_test_support")
h.setup("/tmp/syncery_menu_annotations_spec_" .. tostring(os.time()))
local stubs = menu_support.install_stubs()

local A = require("syncery_ui/menu/annotations_section")


-- ---------------------------------------------------------------------------
-- Pattern 3: inline previews on the "What to sync" rows
-- ---------------------------------------------------------------------------


-- Master annotations off → label says "(off)".
do
    local plugin = menu_support.make_fake_plugin{
        sync_annotations = false,
    }
    local items = A.menuWhatToSync(plugin)
    -- Row 1 = Reading position cluster, row 2 = "synced both ways" divider,
    -- row 3 = the Annotations row.
    local ann_label = items[3].text_func()
    h.assert_true(ann_label:find("Annotations") ~= nil,
        "annotations row labelled 'Annotations'")
    h.assert_true(ann_label:find("off") ~= nil,
        "master off → label contains '(off)'")
end


-- Master on, no sub-types enabled → "(none enabled)".
do
    local plugin = menu_support.make_fake_plugin{
        sync_annotations = true,
        sync_highlights = false, sync_notes = false, sync_bookmarks = false,
    }
    local ann_label = A.menuWhatToSync(plugin)[3].text_func()
    h.assert_true(ann_label:find("none enabled") ~= nil,
        "master on + no types → 'none enabled' preview")
end


-- Master on, two sub-types → "(highlights · notes)".
do
    local plugin = menu_support.make_fake_plugin{
        sync_annotations = true,
        sync_highlights = true, sync_notes = true, sync_bookmarks = false,
    }
    local ann_label = A.menuWhatToSync(plugin)[3].text_func()
    h.assert_true(ann_label:find("highlights") ~= nil,
        "preview includes 'highlights'")
    h.assert_true(ann_label:find("notes") ~= nil,
        "preview includes 'notes'")
    h.assert_true(ann_label:find("bookmarks") == nil,
        "preview omits unselected type 'bookmarks'")
    h.assert_true(ann_label:find("·") ~= nil,
        "preview uses '·' separator between types")
end


-- menuWhatToSync is reorganised by the nature of the sync link:
-- a Reading-position cluster first, then "synced both ways", then
-- "on this device".
do
    local plugin = menu_support.make_fake_plugin{}
    local rows = A.menuWhatToSync(plugin)
    h.assert_equal(#rows, 10,
        "menuWhatToSync: 10 rows (position + 2 dividers + 5 both-ways + 2 local)")
    h.assert_equal(rows[1].text, "Reading position",
        "row 1 is the Reading position cluster")
    h.assert_true(rows[1].sub_item_table_func ~= nil,
        "Reading position is a submenu")
    h.assert_true(rows[2].text:find("synced both ways") ~= nil,
        "row 2 is the 'synced both ways' section divider")
    h.assert_equal(rows[7].text, "Statistics & Vocabulary",
        "row 7 is the Statistics & Vocabulary category (both-ways group)")
    h.assert_true(rows[7].sub_item_table_func ~= nil,
        "Statistics & Vocabulary is a submenu")
    h.assert_true(rows[8].text:find("on this device") ~= nil,
        "row 8 is the 'on this device' section divider")
end


-- Metadata row: now lives directly in What's-synced (row 4, both-ways group).
do
    local plugin = menu_support.make_fake_plugin{
        sync_metadata = true,
        sync_status = true, sync_rating = true,
    }
    local meta_label = A.menuWhatToSync(plugin)[4].text_func()
    h.assert_true(meta_label:find("Book metadata") ~= nil,
        "metadata row labelled 'Book metadata'")
    h.assert_true(meta_label:find("status") ~= nil,
        "preview includes 'status'")
    h.assert_true(meta_label:find("rating") ~= nil,
        "preview includes 'rating'")
end


-- Font & layout (render) submenu is row 5; the summary toggle is row 6.
do
    local plugin = menu_support.make_fake_plugin{ sync_summary = false, sync_render_settings = false }
    local rows = A.menuWhatToSync(plugin)
    h.assert_true(type(rows[5].sub_item_table_func) == "function",
        "Font & layout is a submenu row")
    h.assert_true(rows[5].callback == nil,
        "render submenu row has no direct toggle callback")
    h.assert_true(type(rows[6].checked_func) == "function",
        "summary toggle present")
    rows[6].callback(nil)
    h.assert_equal(plugin.sync_summary, true,
        "summary toggle flips sync_summary")
end


-- File types row: now in the "on this device" group (row 10).
do
    local plugin = menu_support.make_fake_plugin{ sync_extensions = "*" }
    local types_label = A.menuWhatToSync(plugin)[10].text_func()
    h.assert_true(types_label:find("all formats") ~= nil,
        "wildcard → 'all formats' label")
end
do
    local plugin = menu_support.make_fake_plugin{ sync_extensions = "pdf, epub" }
    local types_label = A.menuWhatToSync(plugin)[10].text_func()
    h.assert_true(types_label:find("pdf, epub") ~= nil,
        "specific extensions → inlined in label")
end


-- Adapt highlight style now lives in the "on this device" group (row 9).
do
    local plugin = menu_support.make_fake_plugin{ adapt_highlight_style = false }
    local rows = A.menuWhatToSync(plugin)
    h.assert_equal(rows[9].text, "Adapt highlight style to this device",
        "row 9 is the adapt-highlight toggle")
    rows[9].callback(nil)
    h.assert_equal(plugin.adapt_highlight_style, true,
        "adapt toggle flips adapt_highlight_style")
end


-- Reading position cluster: send toggle + receive submenu + on-demand pull.
do
    local plugin = menu_support.make_fake_plugin{
        jump_mode = "ask",
        ui = menu_support.make_fake_ui{ settings = {} },   -- book open → pull row present
    }
    local rows = A.menuReadingPosition(plugin)
    h.assert_equal(#rows, 3,
        "Reading position (book open): 3 rows (send, receive, pull)")
    -- send: the sync_progress toggle, relabelled.
    h.assert_true(type(rows[1].checked_func) == "function",
        "row 1 is the send toggle")
    rows[1].callback(nil)
    h.assert_equal(plugin.sync_progress, false,
        "send toggle flips sync_progress (was on by default)")
    -- receive: jump_mode submenu, parent shows the active mode inline.
    h.assert_true(rows[2].sub_item_table_func ~= nil,
        "row 2 is the jump_mode (receive) submenu")
    h.assert_true(rows[2].text_func():find("Ask first") ~= nil,
        "receive parent shows the active mode inline")
    -- pull: on-demand jump opens the status panel.
    h.assert_true(rows[3].text:find("Jump to another device") ~= nil,
        "row 3 is the on-demand pull action")
    local opened = false
    plugin.showSyncStatus = function() opened = true end
    rows[3].callback(nil)
    h.assert_true(opened,
        "pull row opens the status panel (showSyncStatus)")
end


-- File browser (no book open): the on-demand pull row is omitted (hidden, not
-- greyed) — it opens the current book's status panel, which needs a book.  The
-- send toggle and receive submenu (global settings) stay.
do
    local plugin = menu_support.make_fake_plugin{ jump_mode = "ask" }   -- no ui → no doc
    local rows = A.menuReadingPosition(plugin)
    h.assert_equal(#rows, 2,
        "Reading position (no book): 2 rows (send, receive) — pull omitted")
    for _, row in ipairs(rows) do
        local t = (type(row.text) == "string" and row.text) or ""
        h.assert_true(t:find("Jump to another device") == nil,
            "no book: the on-demand pull row is absent")
    end
end


-- ---------------------------------------------------------------------------
-- menuAnnotationsSubmenu structure
-- ---------------------------------------------------------------------------


-- Trash Bin is exposed as A.trashBinRow and placed in the annotations
-- submenu (its domain home), gated on an open book (Pattern 2).
do
    local plugin = menu_support.make_fake_plugin{
        ui = menu_support.make_fake_ui{ settings = {} },
    }
    local row = A.trashBinRow(plugin)
    h.assert_true(row ~= nil and row.text:find("Trash Bin") ~= nil,
        "trashBinRow builds the Trash Bin row")
    h.assert_equal(row.enabled_func(), true, "doc open: Trash Bin enabled")
end

do
    local plugin = menu_support.make_fake_plugin{ ui = nil }
    local row = A.trashBinRow(plugin)
    h.assert_equal(row.enabled_func(), false, "no doc: Trash Bin disabled")
end


-- Trash Bin appears in the annotations submenu (its domain home), and is
-- OUTSIDE the master gate so recovery works even with annotation sync off.
do
    local plugin = menu_support.make_fake_plugin{
        sync_annotations = false,
        ui = menu_support.make_fake_ui{ settings = {} },
    }
    local items = A.menuAnnotationsSubmenu(plugin)
    local trash_row = menu_support.find_row(items, "Trash Bin (deleted annotations)…")
    h.assert_true(trash_row ~= nil,
        "Trash Bin present in annotations submenu (domain home)")
    h.assert_equal(trash_row.enabled_func(), true,
        "Trash Bin enabled even when sync_annotations is OFF (ungated recovery)")
end


-- ---------------------------------------------------------------------------
-- menuBookMetadataSubmenu — master gate on sub-toggles
-- ---------------------------------------------------------------------------


do
    local plugin = menu_support.make_fake_plugin{
        sync_metadata = false,
        sync_status   = false,
    }
    local items = A.menuBookMetadataSubmenu(plugin)
    -- The "Book status" sub-toggle should be present but disabled.
    local status_row = menu_support.find_row(items, "Book status")
    h.assert_true(status_row ~= nil, "Book status row present")
    h.assert_equal(status_row.enabled_func(), false,
        "master off: 'Book status' disabled")
end


do
    local plugin = menu_support.make_fake_plugin{ sync_metadata = true }
    local items = A.menuBookMetadataSubmenu(plugin)
    local status_row = menu_support.find_row(items, "Book status")
    h.assert_equal(status_row.enabled_func(), true,
        "master on: 'Book status' enabled")
end


-- Handmade TOC: a master-gated RECEIVE switch + an UNGATED manual push.
do
    local plugin = menu_support.make_fake_plugin{ sync_metadata = false }
    local items = A.menuBookMetadataSubmenu(plugin)

    -- Receive switch: a master-gated sub-toggle like the others.
    local recv = menu_support.find_row(items, "Receive handmade TOC")
    h.assert_true(recv ~= nil, "'Receive handmade TOC' row present")
    h.assert_equal(recv.enabled_func(), false,
        "master off: 'Receive handmade TOC' disabled")

    -- Push action: sits beside the switch but is NOT gated, so it stays
    -- tappable even with the metadata master off.
    local push = menu_support.find_row(items, "Push this book's handmade TOC")
    h.assert_true(push ~= nil, "'Push this book's handmade TOC' row present")
    h.assert_nil(push.enabled_func,
        "push action is ungated (no enabled_func) even with master off")
    h.assert_true(type(push.callback) == "function",
        "push action has a callback")

    push.callback()
    h.assert_equal(plugin._calls.pushHandmadeToc, 1,
        "tapping the push action fires plugin:pushHandmadeToc()")
end


-- ---------------------------------------------------------------------------
-- menuRenderSettingsSubmenu — master gate + per-field opt-in sub-toggles
-- ---------------------------------------------------------------------------


-- Master OFF: every render sub-toggle is present but disabled.
do
    local plugin = menu_support.make_fake_plugin{
        sync_render_settings = false,
        sync_font_size       = false,
        sync_margins         = false,
    }
    local items = A.menuRenderSettingsSubmenu(plugin)
    for _, label in ipairs({ "Font (typeface)", "Font size", "Line spacing",
                             "Font weight (boldness)", "Page margins" }) do
        local row = menu_support.find_row(items, label)
        h.assert_true(row ~= nil, "render sub-toggle present: " .. label)
        h.assert_equal(row.enabled_func(), false,
            "master off: '" .. label .. "' disabled")
    end
end


-- Master ON: sub-toggles become enabled, and flipping one sets exactly
-- that field's flag (and nothing else).
do
    local plugin = menu_support.make_fake_plugin{
        sync_render_settings = true,
        sync_font_size       = false,
        sync_margins         = false,
    }
    local items = A.menuRenderSettingsSubmenu(plugin)

    local size_row = menu_support.find_row(items, "Font size")
    h.assert_equal(size_row.enabled_func(), true,
        "master on: 'Font size' enabled")
    size_row.callback(nil)
    h.assert_equal(plugin.sync_font_size, true,
        "tapping 'Font size' sets sync_font_size")
    h.assert_equal(plugin.sync_margins, false,
        "tapping 'Font size' leaves sync_margins untouched (per-field choice)")

    -- Margins is its own opt-in even within render sync.
    local margins_row = menu_support.find_row(items, "Page margins")
    margins_row.callback(nil)
    h.assert_equal(plugin.sync_margins, true,
        "tapping 'Page margins' sets sync_margins")
end


-- The master row itself flips sync_render_settings.
do
    local plugin = menu_support.make_fake_plugin{ sync_render_settings = false }
    local items = A.menuRenderSettingsSubmenu(plugin)
    local master = menu_support.find_row(items, "Sync font & layout")
    h.assert_true(master ~= nil, "master 'Sync font & layout' row present")
    master.callback(nil)
    h.assert_equal(plugin.sync_render_settings, true,
        "master row flips sync_render_settings")
end


-- ---------------------------------------------------------------------------
-- menuJumpMode — the receive-mode radio (auto / ask / never)
-- ---------------------------------------------------------------------------


do
    local plugin = menu_support.make_fake_plugin{ jump_mode = "auto" }
    -- The radio submenu reflects jump_mode.
    local modes = A.menuJumpMode(plugin)
    h.assert_equal(#modes, 3, "menuJumpMode: 3 radio options")
    h.assert_equal(modes[1].checked_func(), true,  "auto radio checked when jump_mode=auto")
    h.assert_equal(modes[2].checked_func(), false, "ask radio unchecked when jump_mode=auto")
    h.assert_equal(modes[3].checked_func(), false, "never radio unchecked when jump_mode=auto")

    -- Selecting "never" flips jump_mode and the radio reflects it.
    modes[3].callback(nil)
    h.assert_equal(plugin.jump_mode, "never", "selecting Never sets jump_mode")
    local modes2 = A.menuJumpMode(plugin)
    h.assert_equal(modes2[3].checked_func(), true, "never radio checked after selecting")
end


-- ---------------------------------------------------------------------------
-- editSyncExtensions — wildcard normalisation
-- ---------------------------------------------------------------------------


do
    -- Run through the wildcard handling: opening the dialog stores
    -- the dlg in inputdialog._shown; setting input then triggering
    -- the Save button verifies normalisation.  We pre-load the dialog
    -- input to "*, pdf" — should normalise to "*".
    while #stubs.inputdialog._shown > 0 do table.remove(stubs.inputdialog._shown) end
    local plugin = menu_support.make_fake_plugin{ sync_extensions = "pdf" }
    A.editSyncExtensions(plugin)
    h.assert_equal(#stubs.inputdialog._shown, 1, "editSyncExtensions: dialog shown")

    local dlg = stubs.inputdialog._shown[1]
    dlg.input = "*, pdf"
    -- Buttons[1][3] is Save (Cancel, Reset, Save)
    local save_btn = dlg.buttons[1][3]
    h.assert_equal(save_btn.text, "Save", "third button is Save")
    save_btn.callback()
    h.assert_equal(plugin.sync_extensions, "*",
        "wildcard absorbs other extensions: result is just '*'")
end


-- ---------------------------------------------------------------------------
-- editSyncExtensions — "Reset to *" must rebuild the extension cache
--
-- Regression gate: the Reset button sets sync_extensions to "*" and tells
-- the user "all file types will be synced", but _isFileTypeSynced filters
-- by a cached set that is only rebuilt when nil / on Save / at init.  If
-- Reset skips the rebuild, the stale pre-reset cache keeps filtering out
-- the newly-included types for the rest of the session, so the message
-- lies.  Mirrors the Save path (which already rebuilds).
-- ---------------------------------------------------------------------------


do
    while #stubs.inputdialog._shown > 0 do table.remove(stubs.inputdialog._shown) end
    local plugin = menu_support.make_fake_plugin{ sync_extensions = "pdf" }
    A.editSyncExtensions(plugin)
    local dlg = stubs.inputdialog._shown[1]
    -- Buttons[1][2] is "Reset to *" (Cancel, Reset, Save)
    local reset_btn = dlg.buttons[1][2]
    h.assert_true(reset_btn.text:find("Reset") ~= nil, "second button is Reset")
    reset_btn.callback()
    h.assert_equal(plugin.sync_extensions, "*",
        "Reset sets sync_extensions to '*'")
    h.assert_equal(plugin._calls["_rebuildExtensionCache"], 1,
        "Reset rebuilds the extension cache so the new filter takes effect now")
end
