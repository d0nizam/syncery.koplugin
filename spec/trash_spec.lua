-- =============================================================================
-- spec/trash_spec.lua
-- =============================================================================
--
-- Tests for syncery_ui/trash/init.lua \xe2\x80\x94 the Deleted-annotations
-- browser.
--
-- Phase 9 retired the legacy annotation engine; the Trash module now
-- reads/writes the annotation engine's shared state file via the
-- module-local `Store` helpers (exposed as `Trash._store`).  This spec
-- stubs `Trash._store` directly rather than the underlying engine.
--
-- Covers:
--   * Trash.show: "No document open" when book_file is nil.
--   * Trash.show: "Trash is empty" row when nothing is deleted.
--   * Trash.show: one row per deleted annotation + the bulk-restore
--     row at the top.
--   * The moved helpers: type_marker, preview_text, format_age.
--   * format_age timezone-safety.
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_trash_spec_" .. tostring(os.time()))


-- ---------------------------------------------------------------------------
-- Stubs
-- ---------------------------------------------------------------------------

local shown = {}
local function reset_shown() for k in pairs(shown) do shown[k] = nil end end

local function recording_widget()
    return {
        new = function(_, args)
            local rec = args or {}
            rec._is_widget = true
            return rec
        end,
    }
end

-- The Menu mock needs updateItems so the in-place rebuild path works.
local menu_mock = {
    new = function(_, args)
        local rec = args or {}
        rec._is_widget = true
        rec.updateItems = function(self, items) self.item_table = items end
        return rec
    end,
}

package.loaded["ui/uimanager"] = {
    show  = function(_, w) table.insert(shown, w) end,
    close = function() end,
}
package.loaded["ui/widget/textviewer"]  = recording_widget()
package.loaded["ui/widget/infomessage"] = recording_widget()
package.loaded["ui/widget/confirmbox"]  = recording_widget()
package.loaded["ui/widget/menu"]        = menu_mock
package.loaded["device"] = {
    screen = { getWidth = function() return 600 end,
               getHeight = function() return 800 end },
}
package.loaded["syncery_i18n"] = {
    translate = function(s) return s end,
    ngettext  = function(s, p, n) if n == 1 then return s else return p end end,
}
package.loaded["syncery_util"] = {
    get_device_id    = function() return "dev1" end,
    get_device_label = function() return "TestDevice" end,
}


local Trash = require("syncery_ui/trash/init")


-- ---------------------------------------------------------------------------
-- Store stub.  `deleted_list` drives list_deleted; the spec swaps it
-- per test.  Each tombstone carries a `_trash_key` exactly as the real
-- Store.list_deleted would tag it.
-- ---------------------------------------------------------------------------

local deleted_list = {}
Trash._store.list_deleted = function() return deleted_list end
Trash._store.load         = function() return { annotations = {} } end
Trash._store.restore      = function() return true end


-- ---------------------------------------------------------------------------
-- show \xe2\x80\x94 no document open
-- ---------------------------------------------------------------------------

do
    reset_shown()
    Trash.show(nil)
    h.assert_equal(#shown, 1, "show: one widget when no book_file")
    h.assert_true(shown[1].text:find("No document") ~= nil,
        "show: 'No document open' message shown")
end


-- ---------------------------------------------------------------------------
-- show \xe2\x80\x94 empty trash
-- ---------------------------------------------------------------------------

do
    reset_shown()
    deleted_list = {}
    Trash.show("/books/x.epub")
    h.assert_equal(#shown, 1, "show: one Menu shown for empty trash")
    local m = shown[1]
    h.assert_equal(#m.item_table, 1, "show: empty trash \xe2\x86\x92 single row")
    h.assert_true(m.item_table[1].text:find("empty") ~= nil,
        "show: the row is the 'Trash is empty' message")
end


-- ---------------------------------------------------------------------------
-- show \xe2\x80\x94 rows for deleted annotations
-- ---------------------------------------------------------------------------

do
    reset_shown()
    -- The new engine timestamps with UTC datetime strings; build a few
    -- recent ones so format_age renders sensibly.
    local function utc_ago(seconds)
        return os.date("!%Y-%m-%d %H:%M:%S", os.time() - seconds)
    end
    deleted_list = {
        { _trash_key = "k1", type = "highlight", text = "First highlight",
          datetime_updated = utc_ago(100), device_label = "Phone" },
        { _trash_key = "k2", type = "note", note = "A note here",
          datetime_updated = utc_ago(7200) },
        { _trash_key = "k3", type = "bookmark",
          datetime_updated = utc_ago(200) },
    }
    Trash.show("/books/x.epub")
    local m = shown[1]
    -- 3 deleted + 1 bulk-restore row at the top = 4 rows.
    h.assert_equal(#m.item_table, 4,
        "show: bulk-restore row + one row per deleted annotation")
    h.assert_true(m.item_table[1].text:find("Restore all") ~= nil,
        "show: first row is the bulk-restore action")
    h.assert_true(m.item_table[2].text:find("First highlight") ~= nil,
        "show: highlight row shows the preview text")
    h.assert_true(m.item_table[2].text:find("%[H%]") ~= nil,
        "show: highlight row carries the [H] type marker")
    h.assert_true(m.item_table[3].text:find("A note here") ~= nil,
        "show: note row shows the note text")
end


-- ---------------------------------------------------------------------------
-- type_marker
-- ---------------------------------------------------------------------------

do
    h.assert_equal(Trash._type_marker{ type = "highlight" }, "[H]",
        "type_marker: highlight \xe2\x86\x92 [H]")
    h.assert_equal(Trash._type_marker{ type = "note" }, "[N]",
        "type_marker: note \xe2\x86\x92 [N]")
    h.assert_equal(Trash._type_marker{ type = "bookmark" }, "[B]",
        "type_marker: bookmark \xe2\x86\x92 [B]")
    h.assert_equal(Trash._type_marker{ type = "weird" }, "[?]",
        "type_marker: unknown \xe2\x86\x92 [?]")
end


-- ---------------------------------------------------------------------------
-- preview_text
-- ---------------------------------------------------------------------------

do
    h.assert_equal(Trash._preview_text{ type = "bookmark" }, "(bookmark)",
        "preview_text: empty bookmark \xe2\x86\x92 '(bookmark)'")
    h.assert_equal(Trash._preview_text{ type = "highlight" }, "(no text)",
        "preview_text: empty highlight \xe2\x86\x92 '(no text)'")
    h.assert_equal(Trash._preview_text{ text = "hello world" }, "hello world",
        "preview_text: short text passes through")
    -- Newlines/tabs collapse to single spaces.
    h.assert_equal(Trash._preview_text{ text = "a\n\tb   c" }, "a b c",
        "preview_text: whitespace collapses")
    -- Long text gets truncated with an ellipsis.
    local long = string.rep("x", 100)
    local p = Trash._preview_text{ text = long }
    h.assert_true(#p < #long, "preview_text: long text is truncated")
    h.assert_true(p:sub(-3) == "\xe2\x80\xa6", "preview_text: truncation ends with \xe2\x80\xa6")
end


-- ---------------------------------------------------------------------------
-- format_age \xe2\x80\x94 timezone-safe
-- ---------------------------------------------------------------------------

do
    h.assert_equal(Trash._format_age(nil), "unknown time",
        "format_age: nil \xe2\x86\x92 'unknown time'")
    h.assert_equal(Trash._format_age(0), "unknown time",
        "format_age: 0 \xe2\x86\x92 'unknown time'")
    h.assert_equal(Trash._format_age(os.time() - 10), "just now",
        "format_age: <60s \xe2\x86\x92 'just now'")
    h.assert_equal(Trash._format_age(os.time() - 600), "10 min ago",
        "format_age: 10 minutes \xe2\x86\x92 '10 min ago'")
    h.assert_equal(Trash._format_age(os.time() - 7200), "2 hr ago",
        "format_age: 2 hours \xe2\x86\x92 '2 hr ago'")
    h.assert_equal(Trash._format_age(os.time() - 172800), "2 days ago",
        "format_age: 2 days \xe2\x86\x92 '2 days ago'")
    -- All branches use os.difftime on two epoch values \xe2\x86\x92 no timezone
    -- dependency.  The 7-timezone matrix verifies this stays true.
end


-- ---------------------------------------------------------------------------
-- deleted_epoch \xe2\x80\x94 parses the UTC datetime string
-- ---------------------------------------------------------------------------

do
    -- No timestamp at all \xe2\x86\x92 0.
    h.assert_equal(Trash._deleted_epoch{}, 0,
        "deleted_epoch: no timestamp \xe2\x86\x92 0")
    -- A UTC string parses to a positive epoch.
    local e = Trash._deleted_epoch{
        datetime_updated = os.date("!%Y-%m-%d %H:%M:%S", os.time()) }
    h.assert_true(e > 0, "deleted_epoch: UTC string parses to positive epoch")
end


h.teardown()
