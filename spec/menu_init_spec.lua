-- =============================================================================
-- spec/menu_init_spec.lua
-- =============================================================================
--
-- Tests for syncery_ui/menu/init.lua — the orchestrator.
--
-- Two things matter at this level:
--   1. Composition: buildTopMenu produces the right list and
--      buildSettingsMenu hooks up the right submenus.
--   2. Pattern 1 cache discipline: the snapshot is cleared between
--      menu renders so stale data doesn't survive.
-- =============================================================================


local h            = require("spec.test_helpers")
local menu_support = require("spec.menu_test_support")
h.setup("/tmp/syncery_menu_init_spec_" .. tostring(os.time()))
local stubs = menu_support.install_stubs()

local Menu = require("syncery_ui/menu/init")


-- ---------------------------------------------------------------------------
-- Sections are addressable
-- ---------------------------------------------------------------------------


do
    h.assert_true(Menu.sections.status      ~= nil, "sections.status exists")
    h.assert_true(Menu.sections.transport   ~= nil, "sections.transport exists")
    h.assert_true(Menu.sections.annotations ~= nil, "sections.annotations exists")
    h.assert_true(Menu.sections.per_book    ~= nil, "sections.per_book exists")
    h.assert_true(Menu.sections.maintenance ~= nil, "sections.maintenance exists")
    h.assert_true(Menu.sections.advanced    ~= nil, "sections.advanced exists")
    h.assert_true(Menu.helpers              ~= nil, "helpers exposed")
end


-- ---------------------------------------------------------------------------
-- buildTopMenu structure (Phase 13 intent layout)
-- ---------------------------------------------------------------------------


do
    local plugin = menu_support.make_fake_plugin{
        ui = menu_support.make_fake_ui{ settings = {} },   -- book open → full menu
    }
    local items = Menu.buildTopMenu(plugin)
    h.assert_equal(#items, 11,
        "buildTopMenu: 11 rows (3 status + What's synced + Transports + "
        .. "Progress Browser + Annotation Browser + This book + Tools + "
        .. "Advanced + Check for plugin updates)")

    -- Row 1 (smart header) caps the status cluster with a separator.
    h.assert_true(items[1].separator == true,
        "row 1 (smart header) ends the status cluster with a separator")

    -- Row 3 (Sync now) now closes the status cluster with a separator (the
    -- old "Show device status" door that used to do this is gone -- the
    -- Progress Browser replaces it).
    h.assert_true(items[3].separator == true,
        "row 3 (Sync now) closes the status cluster with a separator")

    -- Rows 4..7 are the intent buckets / browsers.
    h.assert_true(items[4].sub_item_table_func ~= nil,
        "row 4 (What's synced) is a submenu")
    h.assert_true(items[5].sub_item_table_func ~= nil,
        "row 5 (Transports) is a submenu")
    h.assert_true(items[6].sub_item_table_func == nil and items[6].callback ~= nil,
        "row 6 (Progress Browser) is a callback row, not a submenu")
    h.assert_true(items[7].sub_item_table_func == nil and items[7].callback ~= nil,
        "row 7 (Annotation Browser) is a callback row, not a submenu")
    h.assert_true(items[8].sub_item_table_func ~= nil,
        "row 8 (This book) is a submenu")
    h.assert_true(items[9].sub_item_table_func ~= nil,
        "row 9 (Tools) is a submenu")
    h.assert_true(items[10].sub_item_table_func ~= nil,
        "row 10 (Advanced) is a submenu")

    -- Row 10 (Advanced) closes its group with a separator, so the standalone
    -- "Check for plugin updates" row below it reads as separate.
    h.assert_true(items[10].separator == true,
        "row 10 (Advanced) ends with a separator before the update row")

    -- Row 11: the separate "Check for plugin updates" entry — a callback row
    -- (not a submenu) that triggers the GitHub self-update flow.
    h.assert_equal(items[11].text, "Check for plugin updates",
        "row 11 is the Check for plugin updates entry")
    h.assert_true(items[11].sub_item_table_func == nil and items[11].callback ~= nil,
        "row 11 (Check for plugin updates) is a callback row, not a submenu")

    -- "This book" and "Tools" close their groups with a
    -- separator (visual lifecycle chunking, bookends lesson 6).
    h.assert_true(items[8].separator == true,
        "row 8 (This book) ends its group with a separator")
    h.assert_true(items[9].separator == true,
        "row 9 (Tools) ends its group with a separator")
end


-- File browser (no book open): per-book rows are HIDDEN, not greyed.  The
-- book-dependent rows (Sync this book, Sync now, Show device status, This book)
-- are absent; only the global rows remain.  buildTopMenu is rebuilt per open,
-- so they return once a book is open (the full-menu test above covers that).
do
    local plugin = menu_support.make_fake_plugin{}   -- no ui → no doc_settings
    local items = Menu.buildTopMenu(plugin)
    h.assert_equal(#items, 8,
        "buildTopMenu (no book): 8 global rows (header + What's synced + "
        .. "Transports + Progress Browser + Annotation Browser + Tools + Advanced "
        .. "+ Check for plugin updates)")
    local labels = {}
    for _, it in ipairs(items) do
        if type(it.text) == "string" then labels[it.text] = true end
    end
    h.assert_true(labels["Show device status"] ~= true,
        "no book: Show device status is omitted (hidden, not greyed)")
    h.assert_true(labels["This book"] ~= true,
        "no book: This book is omitted")
    h.assert_true(labels["Sync this book"] ~= true,
        "no book: Sync this book is omitted")
end


-- buildTopMenu calls maybeShowFirstRunDialog (legacy side-effect).
do
    local plugin = menu_support.make_fake_plugin{}
    local first_run_count = 0
    plugin.maybeShowFirstRunDialog = function() first_run_count = first_run_count + 1 end

    Menu.buildTopMenu(plugin)
    h.assert_equal(first_run_count, 1,
        "buildTopMenu fires maybeShowFirstRunDialog once")
end


-- A plugin method that raises inside maybeShowFirstRunDialog doesn't
-- crash menu rendering — Pattern 1 protects against this with pcall.
do
    local plugin = menu_support.make_fake_plugin{}
    plugin.maybeShowFirstRunDialog = function() error("oh no") end

    local ok = pcall(function()
        Menu.buildTopMenu(plugin)
    end)
    h.assert_true(ok, "buildTopMenu survives a crashing maybeShowFirstRunDialog")
end


-- ---------------------------------------------------------------------------
-- buildTransportsMenu / buildAdvancedMenu structure (intent submenus)
-- ---------------------------------------------------------------------------


do
    local plugin = menu_support.make_fake_plugin{}
    local tr = Menu.buildTransportsMenu(plugin)
    h.assert_true(#tr >= 1, "buildTransportsMenu: has transport rows")
    -- The status-panel door moved to the top level (asserted in the
    -- buildTopMenu test above); this submenu is transport setup only, so
    -- the first row is the Syncthing master toggle (a checked_func row),
    -- not the status door.
    h.assert_true(tr[1].checked_func ~= nil,
        "buildTransportsMenu: first row is a transport toggle, not the status door")
end


do
    local plugin = menu_support.make_fake_plugin{}
    local adv = Menu.buildAdvancedMenu(plugin)
    h.assert_true(#adv >= 4, "buildAdvancedMenu: storage + device + delete/reset")
    -- Storage row inlines the mode (Pattern 3).
    h.assert_true(adv[1].text_func():find("Storage mode") ~= nil,
        "buildAdvancedMenu: row 1 shows the storage mode")
    -- Delete/reset is a submenu (the danger block).
    local last = adv[#adv]
    h.assert_equal(last.text, "Delete and reset",
        "buildAdvancedMenu: last row is the delete/reset submenu")
    h.assert_true(last.sub_item_table_func ~= nil,
        "buildAdvancedMenu: delete/reset is a submenu")

    -- Phase-4: the diagnostic action and the save-interval knob now sit
    -- directly in Advanced; the old "Diagnostic windows" submenu was removed.
    local function adv_has(sub)
        for _, row in ipairs(adv) do
            local lbl = row.text or (row.text_func and row.text_func())
            if lbl and lbl:find(sub, 1, true) then return true end
        end
        return false
    end
    h.assert_true(adv_has("Copy diagnostic info"),
        "buildAdvancedMenu: 'Copy diagnostic info' is a direct row (Phase 4)")
    h.assert_true(adv_has("Book data save interval"),
        "buildAdvancedMenu: 'Book data save interval' is a direct row (Phase 4)")
    h.assert_true(not adv_has("Diagnostic windows"),
        "buildAdvancedMenu: the old 'Diagnostic windows' submenu is gone (Phase 4)")
end


-- Pattern 3: the "What's synced" row inlines what's enabled.
do
    local plugin = menu_support.make_fake_plugin{
        sync_progress = true, sync_annotations = false, sync_metadata = false,
        ui = menu_support.make_fake_ui{ settings = {} },   -- book open → row 4 is What's synced
    }
    local what_label = Menu.buildTopMenu(plugin)[4].text_func()
    h.assert_true(what_label:find("progress") ~= nil,
        "what's-synced label inlines 'progress' when only progress is on")
    h.assert_true(what_label:find("annotations") == nil,
        "label omits 'annotations' when off")
end


do
    local plugin = menu_support.make_fake_plugin{
        sync_progress = true, sync_annotations = true, sync_metadata = true,
        ui = menu_support.make_fake_ui{ settings = {} },   -- book open → row 4 is What's synced
    }
    local what_label = Menu.buildTopMenu(plugin)[4].text_func()
    h.assert_true(what_label:find("all") ~= nil,
        "what's-synced label says '(all)' when everything is on")
end


-- Consent-first: with nothing enabled the label says 'nothing yet'.
do
    local plugin = menu_support.make_fake_plugin{
        sync_progress = false, sync_annotations = false, sync_metadata = false,
        ui = menu_support.make_fake_ui{ settings = {} },   -- book open → row 4 is What's synced
    }
    local what_label = Menu.buildTopMenu(plugin)[4].text_func()
    h.assert_true(what_label:find("nothing yet") ~= nil,
        "what's-synced label says 'nothing yet' when consent-first defaults are off")
end


-- ---------------------------------------------------------------------------
-- Pattern 1 cache discipline: snapshot cleared between renders
-- ---------------------------------------------------------------------------


do
    local call_count = 0
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        _transport = {
            get_status = function(_)
                call_count = call_count + 1
                return { syncthing = { available = true } }
            end,
        },
    }

    -- buildTopMenu produces the row list but text_func is NOT
    -- invoked at build time (KOReader calls text_func lazily when
    -- rendering each row).  We simulate KOReader's render pass by
    -- walking the items and invoking each text_func once — that's
    -- what triggers the centralised snapshot read.
    local function render_pass(items)
        for _, row in ipairs(items) do
            if row.text_func then row.text_func() end
        end
    end

    local items = Menu.buildTopMenu(plugin)
    render_pass(items)
    local count_after_first = call_count
    h.assert_true(count_after_first >= 1,
        "first render: snapshot populated when text_func is invoked")

    -- Importantly, multiple text_funcs in the SAME render share the
    -- snapshot — get_status was called once even though multiple
    -- rows read transport state.  (That's Pattern 1's whole point.)
    -- We don't assert a specific count because future sections might
    -- read state from new rows; the floor is `>= 1` and `<= rows`.

    -- The post-render clear lets the second render re-fetch.
    local items2 = Menu.buildTopMenu(plugin)
    render_pass(items2)
    h.assert_true(call_count > count_after_first,
        "second render: snapshot re-populated (cache cleared between renders)")
end


-- The snapshot field is cleared at the end of buildTopMenu — sections
-- that capture text_func closures will refer to the SAME plugin and
-- the new snapshot on the next render.
do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        _transport = menu_support.make_fake_transport({
            syncthing = { available = true, summary = "ready" },
        }),
    }
    Menu.buildTopMenu(plugin)
    h.assert_nil(plugin._menu_status_snapshot,
        "after buildTopMenu: _menu_status_snapshot cleared on the plugin")
end
