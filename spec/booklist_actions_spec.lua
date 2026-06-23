-- =============================================================================
-- spec/booklist_actions_spec.lua
-- =============================================================================
--
-- Tests for syncery_ui/booklist/actions.lua — the per-book reset
-- actions + the per-book action-row builder, split out of
-- syncery_booklist.lua in Phase 6.
--
-- Covers:
--   * build_action_rows: shape — 3 rows, each with a callback.
--   * showActionsForBook: opens a Menu carrying those rows.
--   * resetPersonalData: removes this device's progress entry +
--     marks this device's annotations deleted; leaves others alone.
--   * resetPersonalData: "no personal data" path when nothing matches.
--   * fullReset: marks every annotation deleted.
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_booklist_actions_spec_" .. tostring(os.time()))


-- ---------------------------------------------------------------------------
-- Stubs
-- ---------------------------------------------------------------------------

local shown = {}
local function reset_shown() for k in pairs(shown) do shown[k] = nil end end

package.loaded["ui/uimanager"] = {
    show  = function(_, w) table.insert(shown, w) end,
    close = function() end,
}
package.loaded["ui/widget/infomessage"] = { new = function(_, a) return a or {} end }
package.loaded["ui/widget/confirmbox"]  = { new = function(_, a) return a or {} end }
package.loaded["ui/widget/menu"]        = { new = function(_, a) return a or {} end }
package.loaded["device"] = {
    screen = { getWidth = function() return 600 end,
               getHeight = function() return 800 end },
}
package.loaded["syncery_i18n"] = {
    translate = function(s) return s end,
    ngettext  = function(s, p, n) if n == 1 then return s else return p end end,
}
package.loaded["syncery_util"] = {
    get_device_id = function() return "dev1" end,
    now = function() return 1700000000 end,
}

-- Progress state-store stub: normalize() returns the body if it has
-- `entries`, else an empty state (mirrors the real helper).
package.loaded["syncery_progress/state_store"] = {
    normalize = function(raw)
        if type(raw) ~= "table" then return { entries = {} } end
        if raw.entries then return raw end
        return { entries = {} }
    end,
}
package.loaded["syncery_progress/paths"] = {
    last_sync_progress_path = function() return nil end,
}


local Actions = require("syncery_ui/booklist/actions")


-- ---------------------------------------------------------------------------
-- Fake plugin
-- ---------------------------------------------------------------------------

local function make_plugin(opts)
    opts = opts or {}
    return {
        device_id    = "dev1",
        storage_mode = opts.storage_mode or "sdr",
        clearAnnotationCache = function() end,
        migrateSingleBook    = function() return true end,
    }
end


-- ---------------------------------------------------------------------------
-- build_action_rows — action-row shape
-- ---------------------------------------------------------------------------

do
    local rows = Actions.build_action_rows(make_plugin(),
        { display_name = "X", mode = "sdr" })
    h.assert_equal(#rows, 3,
        "build_action_rows: three per-book actions")
    for i, r in ipairs(rows) do
        h.assert_true(type(r.callback) == "function",
            "build_action_rows: row " .. i .. " has a callback")
        h.assert_true(type(r.text) == "string" and #r.text > 0,
            "build_action_rows: row " .. i .. " has label text")
    end
    -- Exact labels (honesty rename): #1 resets THIS device's data; #2 removes the
    -- whole local copy of the book. Pinned so the wording cannot silently drift.
    h.assert_equal(rows[1].text, "Reset my Syncery data for this book",
        "build_action_rows: row 1 label is the honest per-device reset")
    h.assert_equal(rows[2].text, "Remove this book from Syncery on this device",
        "build_action_rows: row 2 label is the honest local-removal")
end


-- ---------------------------------------------------------------------------
-- Row 1 confirms before resetting (parity with row 2; it clears this device's
-- progress + annotations, so it must ask first rather than fire on tap).
-- ---------------------------------------------------------------------------

do
    reset_shown()
    local rows = Actions.build_action_rows(make_plugin(),
        { display_name = "X", mode = "sdr" })
    rows[1].callback()
    local box = shown[#shown]
    h.assert_true(box ~= nil and type(box.ok_callback) == "function",
        "row 1 (reset my data) shows a ConfirmBox before running")
    h.assert_true(box.ok_text ~= nil and #box.ok_text > 0,
        "row 1 confirm carries an OK label")
end


-- ---------------------------------------------------------------------------
-- showActionsForBook — opens a Menu carrying the action rows
-- ---------------------------------------------------------------------------

do
    reset_shown()
    Actions.showActionsForBook(make_plugin(),
        { display_name = "Some Book", mode = "sdr" })
    h.assert_equal(#shown, 1, "showActionsForBook: one Menu shown")
    h.assert_equal(shown[1].title, "Some Book",
        "showActionsForBook: Menu titled with the book name")
    h.assert_equal(#shown[1].item_table, 3,
        "showActionsForBook: Menu carries the three action rows")
end


-- ---------------------------------------------------------------------------
-- resetPersonalData — removes only this device's data
-- ---------------------------------------------------------------------------

do
    reset_shown()
    -- Build a book with a progress file (this device + another) and
    -- an annotations file (this device + another).
    local root = h.test_root
    local prog_path = root .. "/reset_progress.json"
    local ann_path  = root .. "/reset_annotations.json"

    local json = require("rapidjson")
    local function write(path, tbl)
        local f = io.open(path, "w"); f:write(json.encode(tbl)); f:close()
    end
    write(prog_path, { entries = {
        dev1 = { percent = 0.3, page = 30 },
        dev2 = { percent = 0.7, page = 70 },
    }})
    -- Real on-disk shape: a position-keyed MAP (string keys), not an array.
    write(ann_path, { annotations = {
        ["/body/p[1]/text().0||/body/p[1]/text().5"] = { id = "a1", device_id = "dev1", deleted = false, datetime = "2026-01-01 00:00:00" },
        ["/body/p[2]/text().0||/body/p[2]/text().9"] = { id = "a2", device_id = "dev2", deleted = false, datetime = "2026-01-01 00:00:00" },
    }})

    Actions.resetPersonalData(make_plugin(),
        { progress_path = prog_path, annotations_path = ann_path,
          file = "/books/x.epub" })

    -- Progress: dev1 gone, dev2 kept.
    local function read(path)
        local f = io.open(path, "r"); local raw = f:read("*a"); f:close()
        return json.decode(raw)
    end
    local prog = read(prog_path)
    h.assert_nil(prog.entries.dev1,
        "resetPersonalData: this device's progress entry removed")
    h.assert_true(prog.entries.dev2 ~= nil,
        "resetPersonalData: other device's progress entry kept")

    -- Annotations: a1 (dev1) marked deleted, a2 (dev2) untouched.
    local ann = read(ann_path)
    local a1, a2
    for _key, a in pairs(ann.annotations) do
        if a.id == "a1" then a1 = a elseif a.id == "a2" then a2 = a end
    end
    h.assert_true(a1 ~= nil and a1.deleted == true,
        "resetPersonalData: this device's annotation marked deleted")
    h.assert_true(a1 ~= nil and type(a1.datetime_updated) == "string" and a1.datetime_updated ~= "",
        "resetPersonalData: deletion stamps datetime_updated (not modified_at)")
    h.assert_false(a2.deleted,
        "resetPersonalData: other device's annotation left alone")

    -- A success InfoMessage was shown.
    h.assert_true(#shown >= 1,
        "resetPersonalData: a result message is shown")
end


-- ---------------------------------------------------------------------------
-- resetPersonalData — "no personal data" path
-- ---------------------------------------------------------------------------

do
    reset_shown()
    local root = h.test_root
    local prog_path = root .. "/reset_none_progress.json"
    local ann_path  = root .. "/reset_none_annotations.json"
    local json = require("rapidjson")
    local function write(path, tbl)
        local f = io.open(path, "w"); f:write(json.encode(tbl)); f:close()
    end
    -- Only another device's data present.
    write(prog_path, { entries = { dev2 = { percent = 0.5 } } })
    write(ann_path,  { annotations = {
        ["/body/p[1]/text().0||/body/p[1]/text().3"] = { id = "b1", device_id = "dev2", deleted = false } } })

    Actions.resetPersonalData(make_plugin(),
        { progress_path = prog_path, annotations_path = ann_path,
          file = "/books/y.epub" })

    h.assert_true(#shown >= 1,
        "resetPersonalData: shows a message even when nothing matched")
    h.assert_true(shown[1].text:find("No personal data") ~= nil,
        "resetPersonalData: 'No personal data found' when nothing matched")
end


-- ---------------------------------------------------------------------------
-- fullReset — marks every annotation deleted
-- ---------------------------------------------------------------------------

do
    reset_shown()
    local root = h.test_root
    local prog_path = root .. "/full_progress.json"
    local ann_path  = root .. "/full_annotations.json"
    local json = require("rapidjson")
    local function write(path, tbl)
        local f = io.open(path, "w"); f:write(json.encode(tbl)); f:close()
    end
    write(prog_path, { entries = { dev1 = { percent = 0.3 },
                                   dev2 = { percent = 0.7 } } })
    write(ann_path, { annotations = {
        ["/body/p[1]/text().0||/body/p[1]/text().5"] = { id = "c1", device_id = "dev1", deleted = false, datetime = "2026-01-01 00:00:00" },
        ["/body/p[2]/text().0||/body/p[2]/text().9"] = { id = "c2", device_id = "dev2", deleted = false, datetime = "2026-01-01 00:00:00" },
    }})

    Actions.fullReset(make_plugin(),
        { progress_path = prog_path, annotations_path = ann_path,
          file = "/books/z.epub" })

    -- Annotations: every entry deleted.
    local f = io.open(ann_path, "r"); local raw = f:read("*a"); f:close()
    local ann = json.decode(raw)
    local all_deleted = true
    local count = 0
    for _key, a in pairs(ann.annotations) do
        count = count + 1
        if not a.deleted then all_deleted = false end
        if type(a.datetime_updated) ~= "string" or a.datetime_updated == "" then all_deleted = false end
    end
    h.assert_true(count == 2,
        "fullReset: both annotations still present (loop not empty)")
    h.assert_true(all_deleted,
        "fullReset: every annotation is marked deleted with datetime_updated")

    -- Progress file removed.
    local pf = io.open(prog_path, "r")
    h.assert_nil(pf, "fullReset: the progress file is removed")
    if pf then pf:close() end
end


h.teardown()
