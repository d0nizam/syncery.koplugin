-- =============================================================================
-- spec/booklist_init_spec.lua
-- =============================================================================
--
-- Tests for syncery_ui/booklist/init.lua — specifically displayBookMenu's
-- per-book row summary (Phase 21.11). Each book row shows a "synced N ago"
-- suffix derived from the annotations file's mtime — the SAME single stat the
-- list already performed for the old bullet marker, now used for real info
-- instead of being thrown away. A book whose annotations file is missing shows
-- no suffix.
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_booklist_init_spec_" .. tostring(os.time()))


-- ---------------------------------------------------------------------------
-- Stubs — capture the Menu's item_table so we can read row text.
-- ---------------------------------------------------------------------------

local last_menu = nil

package.loaded["ui/uimanager"]            = { show = function() end, close = function() end }
package.loaded["ui/widget/infomessage"]   = { new = function(_, a) return a or {} end }
package.loaded["ui/widget/confirmbox"]    = { new = function(_, a) return a or {} end }
package.loaded["ui/widget/menu"]          = { new = function(_, a)
    last_menu = a or {}
    return last_menu
end }
package.loaded["device"] = {
    screen = { getWidth = function() return 600 end, getHeight = function() return 800 end },
}
package.loaded["ui/trapper"] = {
    info = function() return true end, reset = function() end,
    wrap = function(_, fn) fn() end,
}
package.loaded["syncery_i18n"] = {
    translate = function(s) return s end,
    ngettext  = function(s, p, n) if n == 1 then return s else return p end end,
}

-- A real-ish Util: file_mtime reads the actual filesystem (the test writes
-- real temp files), everything else is a thin stub.
package.loaded["syncery_util"] = {
    file_mtime = function(path)
        local lfs = require("lfs")
        local attr = lfs.attributes(path)
        return (attr and attr.modification) or 0
    end,
    file_extension = function(p) return (p or ""):match("%.([^.]+)$") end,
}
package.loaded["syncery_ui/booklist/scan"]    = { getScanRoots = function() return {} end }
package.loaded["syncery_ui/booklist/actions"] = {
    showActionsForBook = function() end,
    build_action_rows  = function() return {} end,
}

package.loaded["syncery_ui/booklist/init"] = nil
local BookList = require("syncery_ui/booklist/init")


-- Helper: find a row whose text contains `needle`.
local function find_row_text(menu, needle)
    for _, row in ipairs(menu.item_table or {}) do
        if row.text and row.text:find(needle, 1, true) then return row.text end
    end
    return nil
end


-- ---------------------------------------------------------------------------
-- A recent annotations file → row shows a "synced ... ago" suffix.
-- ---------------------------------------------------------------------------
do
    local ann = h.test_root .. "/recent.syncery-annotations.json"
    local f = io.open(ann, "w"); f:write("{}"); f:close()
    -- Freshly written → mtime is ~now → "synced just now".

    local plugin = { storage_mode = "sdr" }
    BookList.displayBookMenu(plugin, {
        { mode = "sdr", display_name = "Recent Book",
          annotations_path = ann, progress_path = ann },
    })

    local row = find_row_text(last_menu, "Recent Book")
    h.assert_true(row ~= nil, "row for the book is present")
    h.assert_true(row:find("synced") ~= nil,
        "recent annotations file → row shows a 'synced ... ago' suffix")
end


-- ---------------------------------------------------------------------------
-- Missing annotations file → no suffix (just the name).
-- ---------------------------------------------------------------------------
do
    local plugin = { storage_mode = "sdr" }
    BookList.displayBookMenu(plugin, {
        { mode = "sdr", display_name = "Never Synced",
          annotations_path = h.test_root .. "/does-not-exist.json",
          progress_path = h.test_root .. "/does-not-exist.json" },
    })

    local row = find_row_text(last_menu, "Never Synced")
    h.assert_true(row ~= nil, "row for the never-synced book is present")
    h.assert_true(row:find("synced") == nil,
        "missing annotations file → no 'synced' suffix")
end


-- ---------------------------------------------------------------------------
-- Affordance shape: tap-only.  Base Menu's onMenuHold is a no-op stub, so a
-- per-item hold_callback would be dead (never invoked in production) and is
-- deliberately NOT set.  `search_field` is a phantom Menu key (Menu never reads
-- it) and is not passed.  Tap (`callback`) is the single affordance.
-- ---------------------------------------------------------------------------
do
    local opened = 0
    package.loaded["syncery_ui/booklist/actions"].showActionsForBook =
        function() opened = opened + 1 end

    local ann = h.test_root .. "/shape.syncery-annotations.json"
    local f = io.open(ann, "w"); f:write("{}"); f:close()

    local plugin = { storage_mode = "sdr" }
    BookList.displayBookMenu(plugin, {
        { mode = "sdr", display_name = "Shape Book",
          annotations_path = ann, progress_path = ann },
    })

    -- The phantom Menu key is not passed.
    h.assert_true(last_menu.search_field == nil,
        "displayBookMenu does not pass the phantom 'search_field' Menu key")

    -- Find the book row (skip the "Migrate all books" header row).
    local book_row
    for _, row in ipairs(last_menu.item_table or {}) do
        if row.text and row.text:find("Shape Book", 1, true) then book_row = row end
    end
    h.assert_true(book_row ~= nil, "book row is present")

    -- No dead hold_callback (base Menu onMenuHold never invokes it).
    h.assert_true(book_row.hold_callback == nil,
        "book row has no hold_callback (base Menu onMenuHold is a no-op → it would be dead)")

    -- Tap still opens the action menu.
    h.assert_true(type(book_row.callback) == "function",
        "book row tap callback is present")
    book_row.callback()
    h.assert_equal(opened, 1, "tapping a book row opens the action menu")
end


h.teardown()
