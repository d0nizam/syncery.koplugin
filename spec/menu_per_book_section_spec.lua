-- =============================================================================
-- spec/menu_per_book_section_spec.lua
-- =============================================================================
--
-- Tests for syncery_ui/menu/per_book_section.lua.  All rows here are
-- gated on a document being open (Pattern 2).
-- =============================================================================


local h            = require("spec.test_helpers")
local menu_support = require("spec.menu_test_support")
h.setup("/tmp/syncery_menu_perbook_spec_" .. tostring(os.time()))
local stubs = menu_support.install_stubs()

local P = require("syncery_ui/menu/per_book_section")


-- Note: "Push handmade TOC" moved out of per_book_section into What's
-- Synced (now an ungated action beside the Receive-TOC switch); its row
-- behaviour is covered by menu_annotations_section_spec.


-- ---------------------------------------------------------------------------
-- undo_jump — gated on the 30-second window
-- ---------------------------------------------------------------------------


-- No recent jump: disabled.
do
    local plugin = menu_support.make_fake_plugin{ pre_jump_until = nil }
    local row = P.undo_jump(plugin)
    h.assert_equal(row.enabled_func(), false,
        "no pre_jump_until: undo disabled")
end


-- Within the window: enabled.
do
    local plugin = menu_support.make_fake_plugin{
        pre_jump_until = os.time() + 30,
    }
    local row = P.undo_jump(plugin)
    h.assert_equal(row.enabled_func(), true,
        "within undo window: enabled")

    row.callback()
    h.assert_equal(plugin._calls._undoLastJump, 1,
        "tap fires plugin:_undoLastJump()")
end


-- Past the window: disabled.
do
    local plugin = menu_support.make_fake_plugin{
        pre_jump_until = os.time() - 1,
    }
    local row = P.undo_jump(plugin)
    h.assert_equal(row.enabled_func(), false,
        "past undo window: disabled")
end


-- Long-press past the window shows the gate explanation.
do
    while #stubs.info._shown > 0 do table.remove(stubs.info._shown) end
    local plugin = menu_support.make_fake_plugin{
        pre_jump_until = os.time() - 1,
    }
    local row = P.undo_jump(plugin)
    row.hold_callback()
    h.assert_equal(#stubs.info._shown, 1, "one info shown on hold")
    h.assert_true(stubs.info._shown[1].text:find("60%-second") ~= nil
                  or stubs.info._shown[1].text:find("60") ~= nil,
        "gate message mentions the 60-second window")
end


-- ---------------------------------------------------------------------------
-- full_reset — gated on doc open
-- ---------------------------------------------------------------------------


-- No doc: disabled.
do
    local plugin = menu_support.make_fake_plugin{ ui = nil }
    local row = P.full_reset(plugin)
    h.assert_equal(row.enabled_func(), false,
        "no doc: full reset disabled")
end


-- Doc open: enabled and tap shows a confirm dialog.
do
    while #stubs.confirm._shown > 0 do table.remove(stubs.confirm._shown) end
    local plugin = menu_support.make_fake_plugin{
        ui = menu_support.make_fake_ui{ settings = {} },
        current_state = { file = "/tmp/book.epub" },
    }
    local row = P.full_reset(plugin)
    h.assert_equal(row.enabled_func(), true, "doc open: enabled")

    row.callback()
    h.assert_equal(#stubs.confirm._shown, 1,
        "full_reset tap shows a confirm dialog (Pattern 2 friction)")
end


-- Hold WITHOUT a doc shows the gate explanation.
do
    while #stubs.info._shown > 0 do table.remove(stubs.info._shown) end
    local plugin = menu_support.make_fake_plugin{ ui = nil }
    local row = P.full_reset(plugin)
    row.hold_callback()
    h.assert_equal(#stubs.info._shown, 1, "hold no-doc: one info")
    h.assert_true(stubs.info._shown[1].text:find("Open a book first") ~= nil,
        "gate message tells user to open a book")
end


-- (menuBookDataManagement was a dead wrapper that only returned
-- {full_reset}; removed in Phase 13 — full_reset is now listed directly
-- under the "This book" top-level entry. Its coverage lives in the
-- full_reset test above.)


-- ---------------------------------------------------------------------------
-- delete_all_annotations — annotations only, KEEPS progress (Phase 13)
-- ---------------------------------------------------------------------------


-- Gated on an open document (Pattern 2).
do
    local plugin = menu_support.make_fake_plugin{ ui = nil }
    local row = P.delete_all_annotations(plugin)
    h.assert_equal(row.enabled_func(), false,
        "delete-annotations: disabled when no book open")
end


-- Labelled to distinguish it from Full reset (keeps progress).
do
    local plugin = menu_support.make_fake_plugin{
        ui = menu_support.make_fake_ui{ settings = {} },
    }
    local row = P.delete_all_annotations(plugin)
    h.assert_equal(row.enabled_func(), true, "doc open: enabled")
    h.assert_true(row.text:find("keeps progress") ~= nil,
        "label makes clear progress is kept (distinct from Full reset)")
    -- Tap routes to the annotations-only backend.
    plugin._deleteAllAnnotationsForCurrentBook = function(self)
        self._del_called = true
    end
    row.callback()
    h.assert_true(plugin._del_called == true,
        "delete-annotations tap invokes _deleteAllAnnotationsForCurrentBook")
end


-- ---------------------------------------------------------------------------
-- status_conflict — surfaced ONLY when the open book's reading status conflicts
-- across devices (complete vs abandoned at the same generation; Model D).
-- Returns nil otherwise, so the row is absent unless genuinely relevant.
-- ---------------------------------------------------------------------------


local AnnStateStore     = require("syncery_ann/state_store")
local _orig_load_shared = AnnStateStore.load_shared
local _orig_save_shared = AnnStateStore.save_shared

-- Run fn with load_shared stubbed to return `state`, then restore.
local function with_shared(state, fn)
    AnnStateStore.load_shared = function(_file) return state end
    local ok, err = pcall(fn)
    AnnStateStore.load_shared = _orig_load_shared
    if not ok then error(err) end
end


-- A genuine complete-vs-abandoned conflict -> picker with value buttons;
-- choosing one writes the resolution (generation+1) to the shared file + pushes.
do
    while #stubs.info._shown > 0 do table.remove(stubs.info._shown) end
    while #stubs.buttondialog._shown > 0 do table.remove(stubs.buttondialog._shown) end

    local saved  = {}
    local synced = { n = 0 }
    AnnStateStore.save_shared = function(file, state)
        saved.file = file; saved.state = state; return true
    end

    local plugin = menu_support.make_fake_plugin{
        ui = menu_support.make_fake_ui{ settings = { summary = {} } },
        device_id = "B", device_label = "Kindle",
    }
    plugin.getCurrentState = function() return { file = "/books/x.epub" } end
    plugin.syncNow = function(_self) synced.n = synced.n + 1 end

    local conflict_state = {
        metadata = { status = { generation = 0, candidates = {
            { value = "complete",  device_id = "A", device_label = "Phone" },
            { value = "abandoned", device_id = "B", device_label = "Kindle" },
        } } },
    }

    with_shared(conflict_state, function()
        local row = P.status_conflict(plugin)
        h.assert_true(row ~= nil, "conflict present -> a row is returned")
        h.assert_true(row.text:find("differs") ~= nil,
            "row text signals a status conflict")

        row.callback()
        h.assert_equal(#stubs.buttondialog._shown, 1, "tap opens the resolution picker")
        local dlg = stubs.buttondialog._shown[1]
        h.assert_true(dlg.title:find("Finished") ~= nil and dlg.title:find("Phone") ~= nil,
            "picker shows Finished on Phone")
        h.assert_true(dlg.title:find("On hold") ~= nil and dlg.title:find("Kindle") ~= nil,
            "picker shows On hold on Kindle")

        -- Find the "Finished" value button and choose it.
        local finished_btn
        for _, btn in ipairs(dlg.buttons[1]) do
            if btn.text == "Finished" then finished_btn = btn end
        end
        h.assert_true(finished_btn ~= nil, "a Finished value button is offered")
        finished_btn.callback()

        h.assert_equal(saved.file, "/books/x.epub", "resolution writes the shared file")
        local st = saved.state.metadata.status
        h.assert_equal(st.generation, 1, "resolution bumps generation (dominates the conflict)")
        h.assert_equal(#st.candidates, 1, "resolution collapses to a single value")
        h.assert_equal(st.candidates[1].value, "complete", "resolution keeps the chosen value")
        h.assert_equal(synced.n, 1, "resolution pushes via syncNow")
    end)

    AnnStateStore.save_shared = _orig_save_shared
end


-- A resolved status (single candidate) -> NO row.
do
    local plugin = menu_support.make_fake_plugin{}
    plugin.getCurrentState = function() return { file = "/books/x.epub" } end
    with_shared({
        metadata = { status = { generation = 1, candidates = {
            { value = "complete", device_id = "A", device_label = "Phone" },
        } } },
    }, function()
        h.assert_nil(P.status_conflict(plugin),
            "a resolved status surfaces no conflict row")
    end)
end


-- No open book -> NO row (no shared-file read needed).
do
    local plugin = menu_support.make_fake_plugin{}
    plugin.getCurrentState = function() return nil end
    h.assert_nil(P.status_conflict(plugin), "no open book -> no conflict row")
end
