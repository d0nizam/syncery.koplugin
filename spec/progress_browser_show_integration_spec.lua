-- =============================================================================
-- spec/progress_browser_show_integration_spec.lua
-- =============================================================================
--
-- Integration test for the ACTUAL wiring inside ProgressBrowser.show()
-- not just the underlying
-- aggregate.lua claim (that is progress_browser_prefetch_spec.lua's job).
-- This calls the real .show(plugin) with stubbed UI widgets and inspects
-- the item_table actually built, so a regression in the merge condition
-- itself (not just in aggregate.lua) is caught.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_progress_browser_show_spec_" .. tostring(os.time()))

local test_dir = "/tmp/pbs_spec_" .. tostring(os.time())
os.execute("rm -rf " .. test_dir)
os.execute("mkdir -p " .. test_dir .. "/cloud_staging/prefetch")

-- Stub every UI dependency progress_browser/init.lua requires at load time.
package.loaded["ui/uimanager"] = { show = function() end, close = function() end,
    scheduleIn = function() end }
local last_menu
package.loaded["ui/widget/menu"] = {
    new = function(_, a) last_menu = a; return a or {} end,
}
package.loaded["ui/widget/buttondialog"] = { new = function(_, a) return a or {} end }
package.loaded["ui/widget/infomessage"]  = { new = function(_, a) return a or {} end }
package.loaded["ui/widget/confirmbox"]   = { new = function(_, a) return a or {} end }
package.loaded["device"] = {
    screen = { getWidth = function() return 600 end, getHeight = function() return 800 end },
}
package.loaded["syncery_ui/action_bar"] = { new = function() return {} end }
package.loaded["syncery_ui/status_ui/init"] = {}
-- Stub the real filesystem scan out entirely -- this test's target is the
-- prefetch MERGE, not ProgressEnum's own scanning machinery (covered by
-- progress_enum_spec.lua already).
package.loaded["syncery_ui/progress_browser/progress_enum"] = {
    enumerate = function() return {} end,
}

-- Force a fresh load of progress_browser/init.lua under these stubs, and
-- point PluginSync.enumerate_prefetch_staging at our real temp fixtures
-- via a real plugin.state_dir (Util.state_dir is not used here --
-- ProgressBrowser.show takes plugin directly, so state_dir is set on the
-- fake plugin passed in below).
package.loaded["syncery_ui/progress_browser/init"] = nil
local ProgressBrowser = require("syncery_ui/progress_browser/init")

local book_id = "1111111111111111111111111111111C"
local peer_device = "PEER0000000000000000000000000000"
local progress_content = string.format(
    '{"entries":{"%s":{"device_id":"%s","file":"/mnt/us/Books/Only On Peer.epub",' ..
    '"percent":0.2,"timestamp":%d}},"schema_version":1}',
    peer_device, peer_device, os.time())

local function write_progress()
    local f = io.open(test_dir .. "/cloud_staging/prefetch/syncery-progress-" .. book_id .. ".json", "wb")
    f:write(progress_content)
    f:close()
end

local plugin = { state_dir = test_dir .. "/", device_id = "THIS_DEVICE_0000000000000000000" }

do
    write_progress()
    last_menu = nil
    ProgressBrowser.show(plugin)
    h.assert_true(last_menu ~= nil, "Menu:new was called")
    h.assert_true(type(last_menu.item_table) == "table", "item_table is a table")
    h.assert_equal(#last_menu.item_table, 1,
        "the prefetch-pending, peer-only book produces exactly one row")
    h.assert_true(last_menu.item_table[1].text:find("Only On Peer", 1, true) ~= nil,
        "the row's text includes the title extracted from the peer's file field")
end

os.execute("rm -rf " .. test_dir)

h.report("progress_browser_show_integration_spec")


-- ----------------------------------------------------------------------------
-- ProgressBrowser._openRow (row-tap entry point, added alongside the
-- "locate the file" feature): is_prefetch_only / path_unresolved_here
-- routes through PrefetchLocate FIRST, populating r.book.book_path on a
-- match, THEN calling showBookDetail -- so the user can freely pick among
-- ALL the book's device positions afterward, not just open directly at
-- whichever one triggered the locate. A normal, already-resolving row is
-- unaffected: goes straight to showBookDetail, PrefetchLocate never even
-- required.
-- ----------------------------------------------------------------------------

do
    -- is_prefetch_only, auto-resolve fails -> falls through to prompt.
    local calls = {}
    package.loaded["syncery_ui/prefetch_locate"] = {
        try_auto_resolve = function(book_id, peer_path)
            table.insert(calls, { fn = "try_auto_resolve", book_id = book_id, peer_path = peer_path })
            return nil  -- simulate no learned rule matches yet
        end,
        prompt = function(book_id, peer_path, on_opened, explain_text)
            table.insert(calls, { fn = "prompt", book_id = book_id, peer_path = peer_path,
                explain_text = explain_text })
        end,
    }
    local saved_showBookDetail = ProgressBrowser.showBookDetail
    ProgressBrowser.showBookDetail = function() table.insert(calls, { fn = "showBookDetail" }) end

    local plugin2 = { state_dir = test_dir .. "/", device_id = "THIS_DEVICE_0000000000000000000" }
    local book = {
        title = "Prefetch Only Book", book_path = nil,
        is_prefetch_only = true, book_id = "SOME_BOOK_ID_000000000000000000",
        peer_path = "/peer/device/path/Book.epub",
    }
    ProgressBrowser._openRow(plugin2, { book = book, state = {}, agg = {}, conflict_count = 0 })

    h.assert_equal(#calls, 2, "both try_auto_resolve and prompt fire, in that order")
    h.assert_equal(calls[1].fn, "try_auto_resolve")
    h.assert_equal(calls[1].book_id, "SOME_BOOK_ID_000000000000000000")
    h.assert_equal(calls[1].peer_path, "/peer/device/path/Book.epub")
    h.assert_equal(calls[2].fn, "prompt",
        "auto-resolve returned nil -> falls through to prompt, not silently giving up")
    h.assert_equal(calls[2].book_id, "SOME_BOOK_ID_000000000000000000")
    h.assert_equal(calls[2].peer_path, "/peer/device/path/Book.epub")
    h.assert_nil(calls[2].explain_text,
        "is_prefetch_only uses PrefetchLocate.prompt's own default explain text")

    ProgressBrowser.showBookDetail = saved_showBookDetail
end

do
    -- path_unresolved_here (opened elsewhere, not here): DIFFERENT explain
    -- text than is_prefetch_only's default.
    local calls = {}
    package.loaded["syncery_ui/prefetch_locate"] = {
        try_auto_resolve = function() return nil end,
        prompt = function(book_id, peer_path, on_opened, explain_text)
            table.insert(calls, explain_text)
        end,
    }
    local saved_showBookDetail = ProgressBrowser.showBookDetail
    ProgressBrowser.showBookDetail = function() end

    local plugin2b = { state_dir = test_dir .. "/", device_id = "THIS_DEVICE_0000000000000000000" }
    local book = {
        title = "Opened Elsewhere Book", book_path = nil,
        path_unresolved_here = true, book_id = "OTHER_BOOK_ID_0000000000000",
        peer_path = "/peer/device/path/Other.epub",
    }
    ProgressBrowser._openRow(plugin2b, { book = book, state = {}, agg = {}, conflict_count = 0 })

    h.assert_equal(#calls, 1, "prompt called once")
    h.assert_true(calls[1] ~= nil, "path_unresolved_here supplies its OWN explain_text")
    h.assert_true(calls[1]:find("doesn't have a position", 1, true) ~= nil,
        "wording distinguishes 'opened elsewhere' from is_prefetch_only's "
        .. "'never opened anywhere yet'")

    ProgressBrowser.showBookDetail = saved_showBookDetail
end

do
    -- Auto-resolve SUCCEEDS: prompt must NOT fire; book_path is filled in
    -- and showBookDetail runs -- NOT a direct reader open. This is the
    -- key behavioural difference from the earlier (reverted) design: the
    -- user gets the full "choose which device's position" dialog, not an
    -- immediate jump to whichever position happened to trigger the locate.
    local calls = {}
    local shown_book
    package.loaded["syncery_ui/prefetch_locate"] = {
        try_auto_resolve = function() table.insert(calls, "try_auto_resolve")
            return "/resolved/local/Book.epub" end,
        prompt = function() table.insert(calls, "prompt") end,
    }
    local saved_showBookDetail = ProgressBrowser.showBookDetail
    ProgressBrowser.showBookDetail = function(_plugin, book, _state, _agg, _cc)
        table.insert(calls, "showBookDetail")
        shown_book = book
    end

    local plugin3 = { state_dir = test_dir .. "/", device_id = "THIS_DEVICE_0000000000000000000" }
    local book = {
        title = "Prefetch Only Book 2", book_path = nil,
        is_prefetch_only = true, book_id = "ANOTHER_BOOK_ID_00000000000000",
        peer_path = "/peer/device/path/Book2.epub",
    }
    ProgressBrowser._openRow(plugin3, { book = book, state = {}, agg = {}, conflict_count = 0 })

    h.assert_equal(#calls, 2, "try_auto_resolve then showBookDetail; prompt never fires")
    h.assert_equal(calls[1], "try_auto_resolve")
    h.assert_equal(calls[2], "showBookDetail")
    h.assert_equal(shown_book.book_path, "/resolved/local/Book.epub",
        "book_path filled in BEFORE showBookDetail runs -- the user then freely "
        .. "picks among all device positions, not forced straight into the reader")

    ProgressBrowser.showBookDetail = saved_showBookDetail
end

do
    -- A normal, already-resolving row: goes straight to showBookDetail,
    -- PrefetchLocate is never even required (require is lazy, inside the
    -- is_prefetch_only/path_unresolved_here branch only).
    package.loaded["syncery_ui/prefetch_locate"] = nil
    local calls = {}
    local saved_showBookDetail = ProgressBrowser.showBookDetail
    ProgressBrowser.showBookDetail = function() table.insert(calls, "showBookDetail") end

    local plugin4 = { state_dir = test_dir .. "/", device_id = "THIS_DEVICE_0000000000000000000" }
    local book = { title = "Normal Resolving Book", book_path = "/real/path/Book.epub" }
    local ok = pcall(ProgressBrowser._openRow, plugin4,
        { book = book, state = {}, agg = {}, conflict_count = 0 })

    h.assert_true(ok, "does not raise, and does not require PrefetchLocate at all, "
        .. "for a normal (already-resolving) row")
    h.assert_equal(#calls, 1, "showBookDetail called directly -- zero PrefetchLocate involvement")

    ProgressBrowser.showBookDetail = saved_showBookDetail
end
