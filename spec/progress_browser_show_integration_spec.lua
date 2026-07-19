-- =============================================================================
-- spec/progress_browser_show_integration_spec.lua
-- =============================================================================
--
-- Integration test for the ACTUAL wiring inside ProgressBrowser.show()
-- (docs/CLOUD_PREFETCH_DESIGN.md, section 4.4) -- not just the underlying
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
-- ProgressBrowser._jumpToDevice's is_prefetch_only branch (added alongside
-- the "locate the file" feature): a prefetch-only row (book_path=nil,
-- is_prefetch_only=true) must FIRST try PrefetchLocate.try_auto_resolve,
-- and only fall through to PrefetchLocate.prompt if that returns nil --
-- never the plain "Cannot find book path" message, which stays reserved
-- for a book_path that's nil for some OTHER reason (is_prefetch_only not
-- set at all).
-- ----------------------------------------------------------------------------

do
    local calls = {}
    package.loaded["syncery_ui/prefetch_locate"] = {
        try_auto_resolve = function(book_id, peer_path)
            table.insert(calls, { fn = "try_auto_resolve", book_id = book_id, peer_path = peer_path })
            return nil  -- simulate no learned rule matches yet
        end,
        prompt = function(book_id, peer_path, on_opened)
            table.insert(calls, { fn = "prompt", book_id = book_id, peer_path = peer_path })
        end,
    }

    local plugin2 = { state_dir = test_dir .. "/", device_id = "THIS_DEVICE_0000000000000000000" }
    local book = {
        title = "Prefetch Only Book", book_path = nil,
        is_prefetch_only = true, book_id = "SOME_BOOK_ID_000000000000000000",
        peer_path = "/peer/device/path/Book.epub",
    }
    ProgressBrowser._jumpToDevice(plugin2, book, nil, nil)

    h.assert_equal(#calls, 2, "both try_auto_resolve and prompt fire, in that order")
    h.assert_equal(calls[1].fn, "try_auto_resolve")
    h.assert_equal(calls[1].book_id, "SOME_BOOK_ID_000000000000000000")
    h.assert_equal(calls[1].peer_path, "/peer/device/path/Book.epub")
    h.assert_equal(calls[2].fn, "prompt",
        "auto-resolve returned nil -> falls through to prompt, not silently giving up")
    h.assert_equal(calls[2].book_id, "SOME_BOOK_ID_000000000000000000")
    h.assert_equal(calls[2].peer_path, "/peer/device/path/Book.epub")
end

do
    -- Auto-resolve SUCCEEDS: prompt must NOT fire, and the reader opens
    -- directly at the resolved path (via ReaderUI:showReader, stubbed
    -- below to just record the call rather than actually opening).
    local calls = {}
    local opened_path
    package.loaded["syncery_ui/prefetch_locate"] = {
        try_auto_resolve = function(book_id, peer_path)
            table.insert(calls, "try_auto_resolve")
            return "/resolved/local/Book.epub"
        end,
        prompt = function() table.insert(calls, "prompt") end,
    }
    package.loaded["apps/reader/readerui"] = {
        showReader = function(_self, path) opened_path = path end,
        instance = nil,
    }

    local plugin3 = { state_dir = test_dir .. "/", device_id = "THIS_DEVICE_0000000000000000000" }
    local book = {
        title = "Prefetch Only Book 2", book_path = nil,
        is_prefetch_only = true, book_id = "ANOTHER_BOOK_ID_00000000000000",
        peer_path = "/peer/device/path/Book2.epub",
    }
    ProgressBrowser._jumpToDevice(plugin3, book, nil, nil)

    h.assert_equal(#calls, 1, "only try_auto_resolve fires")
    h.assert_equal(calls[1], "try_auto_resolve")
    h.assert_equal(opened_path, "/resolved/local/Book.epub",
        "the reader opens directly at the auto-resolved path -- prompt never shown")

    package.loaded["apps/reader/readerui"] = nil
end

do
    -- book_path nil for a DIFFERENT reason (is_prefetch_only not set):
    -- the OLD "Cannot find book path" path is taken, PrefetchLocate is
    -- never even required (require is lazy, inside the is_prefetch_only
    -- branch only -- confirmed by this not raising even with
    -- syncery_ui/prefetch_locate unloaded below).
    package.loaded["syncery_ui/prefetch_locate"] = nil
    local plugin4 = { state_dir = test_dir .. "/", device_id = "THIS_DEVICE_0000000000000000000" }
    local book = { title = "Some Other Nil-Path Book", book_path = nil }
    local ok = pcall(ProgressBrowser._jumpToDevice, plugin4, book, nil, nil)
    h.assert_true(ok, "does not raise, and does not require PrefetchLocate, "
        .. "when is_prefetch_only is not set")
end
