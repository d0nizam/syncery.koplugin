-- =============================================================================
-- spec/menu_status_section_spec.lua
-- =============================================================================
--
-- Tests for syncery_ui/menu/status_section.lua — the Pattern 1
-- (Smart Header) home.  Covers:
--
--   * Header text resolution from the centralised snapshot.
--   * `⚠ — tap to resolve` suffix when a transport reports an
--     actionable problem.
--   * Per-book "Sync this book" toggle: Pattern 2 gating on
--     doc_settings being present.
--   * "Sync now" dynamic label: changes to "Syncing…" when any
--     transport is mid-retry.
--   * "Sync now" gated on document open (Pattern 2).
-- =============================================================================


local h            = require("spec.test_helpers")
local menu_support = require("spec.menu_test_support")
h.setup("/tmp/syncery_menu_status_spec_" .. tostring(os.time()))
local stubs = menu_support.install_stubs()

local S = require("syncery_ui/menu/status_section")


-- ---------------------------------------------------------------------------
-- Smart header text — defers to _statusBadge when nothing's enabled
-- ---------------------------------------------------------------------------

do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = false, use_cloud = false,
        status_badge = "no sync",
    }
    h.assert_equal(S.get_status_header(plugin), "no sync",
        "all transports off → defers to _statusBadge")
    h.assert_false(S.header_needs_action(plugin),
        "no transports → no actionable header")
end


-- Syncthing toggle on but transport reports "not configured" → ⚠.
do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        _transport = menu_support.make_fake_transport({
            syncthing = { display_name = "Syncthing",
                          available    = false,
                          summary      = "not configured" },
        }),
    }
    local header = S.get_status_header(plugin)
    h.assert_true(header:sub(1, 3) == "⚠",
        "needs_config: header starts with ⚠")
    h.assert_true(header:find("Syncthing") ~= nil,
        "needs_config: header mentions the transport name")
    h.assert_true(S.header_needs_action(plugin),
        "needs_config: header_needs_action returns true")
end


-- Toggle off + transport reports "disabled (toggle off)" → defers
-- to badge.  Even though the transport says it's unavailable, the
-- user toggling it OFF is not an actionable problem.
do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = false,  -- user explicitly turned it off
        use_cloud = true,       -- but turned this one on
        _transport = menu_support.make_fake_transport({
            -- Syncthing reports "disabled" because the user toggled it off.
            syncthing = { display_name = "Syncthing", available = false,
                          summary = "disabled (toggle off)" },
            -- Cloud available + ready.
            cloud     = { display_name = "Cloud", available = true,
                          summary = "ready" },
        }),
        status_badge = "cloud: ok",
    }
    h.assert_false(S.header_needs_action(plugin),
        "toggle off + other transport ready → no actionable problem")
end


-- Multiple problems: pick the highest-priority one (syncthing > cloud).
do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        use_cloud     = true,
        _transport = menu_support.make_fake_transport({
            syncthing = { display_name = "Syncthing", available = false,
                          summary = "not configured" },
            cloud     = { display_name = "Cloud",     available = false,
                          summary = "not configured" },
        }),
    }
    local header = S.get_status_header(plugin)
    h.assert_true(header:find("Syncthing") ~= nil,
        "multiple problems: Syncthing wins priority")
end


-- Pending retry surfaces as "Retrying…" (informational, no ⚠).
do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        _transport = menu_support.make_fake_transport({
            syncthing = { display_name = "Syncthing", available = true,
                          orch_any_pending_retry = true },
        }),
    }
    local header = S.get_status_header(plugin)
    h.assert_true(header:find("Retrying") ~= nil,
        "pending retry: header mentions Retrying")
    h.assert_false(S.header_needs_action(plugin),
        "pending retry: NOT actionable (no ⚠)")
end


-- Auth-failed reads as a SEPARATE actionable problem (not config-needed).
do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        _transport = menu_support.make_fake_transport({
            syncthing = { display_name = "Syncthing", available = true,
                          orch_last_error_class = "auth_failed" },
        }),
    }
    local header = S.get_status_header(plugin)
    h.assert_true(header:sub(1, 3) == "⚠",
        "auth_failed: starts with ⚠")
    h.assert_true(header:find("authentication") ~= nil,
        "auth_failed: header mentions authentication")
end


-- ---------------------------------------------------------------------------
-- Smart header menu row
-- ---------------------------------------------------------------------------

do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        _transport = menu_support.make_fake_transport({
            syncthing = { available = false, summary = "not configured", display_name = "Syncthing" },
        }),
        current_state = { file = "/tmp/b.epub", percent = 0.5 },
    }
    local row = S.smart_header(plugin)
    h.assert_true(type(row) == "table", "smart_header returns a row")
    h.assert_true(type(row.text_func) == "function", "smart_header is a text_func row")
    h.assert_true(type(row.callback)  == "function", "smart_header has a callback")
    h.assert_true(row.separator == true, "smart_header ends the cluster with a separator")

    local label = row.text_func()
    h.assert_true(label:find("⚠") ~= nil,
        "smart_header label includes ⚠ when needs action")
    h.assert_true(label:find("50%%") ~= nil,
        "smart_header label appends current percentage")
    h.assert_true(label:find("tap to resolve") ~= nil,
        "smart_header label says 'tap to resolve' when actionable")

    -- Actionable → the row is tappable, and tapping opens the failing
    -- transport's setup (resolve), NOT the read-only status detail.
    h.assert_equal(row.enabled_func(), true,
        "smart_header: enabled (tappable) when actionable")
    row.callback()
    h.assert_equal(plugin._calls.resolveStatusProblem, 1,
        "smart_header callback invokes plugin:resolveStatusProblem()")
    h.assert_equal(plugin._calls.showSyncStatus, nil,
        "smart_header does NOT open the status detail on an actionable tap")
end


-- Smart header WITHOUT problem omits the "tap to resolve" suffix.
do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        _transport = menu_support.make_fake_transport({
            syncthing = { available = true, summary = "ready", display_name = "Syncthing" },
        }),
        status_badge = "synced just now",
    }
    local row = S.smart_header(plugin)
    local label = row.text_func()
    h.assert_true(label:find("tap to resolve") == nil,
        "smart_header: no 'tap to resolve' when not actionable")
    -- Informational → the row is NOT tappable; the dedicated
    -- "Show device status" row is the way to open the status detail.
    h.assert_equal(row.enabled_func(), false,
        "smart_header: not tappable when merely informational")
end


-- ---------------------------------------------------------------------------
-- Sync-this-book toggle: Pattern 2 (gated on doc_settings)
-- ---------------------------------------------------------------------------


-- No book open: row is disabled.
do
    local plugin = menu_support.make_fake_plugin{ ui = nil }
    local row = S.sync_this_book_toggle(plugin)
    h.assert_equal(row.enabled_func(), false,
        "no doc: sync-this-book disabled")
end


-- Book open + no syncery_disabled setting → checked.
do
    local plugin = menu_support.make_fake_plugin{
        ui = menu_support.make_fake_ui{ settings = {} },
    }
    local row = S.sync_this_book_toggle(plugin)
    h.assert_equal(row.enabled_func(), true, "doc open: enabled")
    h.assert_equal(row.checked_func(), true,
        "doc open, no syncery_disabled flag → checked by default")
end


-- Tap flips the per-book flag.
do
    local plugin = menu_support.make_fake_plugin{
        ui = menu_support.make_fake_ui{ settings = {} },
    }
    local row = S.sync_this_book_toggle(plugin)
    row.callback(nil)
    h.assert_equal(plugin.ui._settings.syncery_disabled, true,
        "tap once: syncery_disabled now true")
    h.assert_equal(row.checked_func(), false,
        "checked_func reflects new disabled state")
    row.callback(nil)
    h.assert_equal(plugin.ui._settings.syncery_disabled, false,
        "tap again: flips back to false")
end


-- Long-press WITHOUT a book open shows the gate explanation.
do
    while #stubs.info._shown > 0 do table.remove(stubs.info._shown) end
    local plugin = menu_support.make_fake_plugin{ ui = nil }
    local row = S.sync_this_book_toggle(plugin)
    row.hold_callback()
    h.assert_equal(#stubs.info._shown, 1, "no-doc hold: one info shown")
    h.assert_true(stubs.info._shown[1].text:find("open a book first") ~= nil,
        "no-doc hold: gate message tells user to open a book")
end


-- ---------------------------------------------------------------------------
-- Sync-now: Pattern 3 dynamic label + Pattern 2 doc-open gate
-- ---------------------------------------------------------------------------


-- No book open: disabled.
do
    local plugin = menu_support.make_fake_plugin{ ui = nil }
    local row = S.sync_now(plugin)
    h.assert_equal(row.enabled_func(), false,
        "no doc: sync-now disabled")
end


-- Book open + no retries in flight → label is "Sync now".
do
    local plugin = menu_support.make_fake_plugin{
        ui = menu_support.make_fake_ui{ settings = {} },
        _transport = menu_support.make_fake_transport({
            syncthing = { available = true, summary = "ready" },
        }),
    }
    local row = S.sync_now(plugin)
    h.assert_equal(row.text_func(), "Sync now",
        "no retries: label is 'Sync now'")
    h.assert_equal(row.enabled_func(), true,
        "doc open: sync-now enabled")
end


-- A transport reporting `orch_any_pending_retry` flips the label to "Syncing…".
do
    local plugin = menu_support.make_fake_plugin{
        ui = menu_support.make_fake_ui{ settings = {} },
        _transport = menu_support.make_fake_transport({
            syncthing = { available = true, orch_any_pending_retry = true },
        }),
    }
    local row = S.sync_now(plugin)
    -- Have to clear the snapshot between reads or the cached one
    -- from get_status_header above could win — but each test_helpers
    -- spec gets a fresh `_menu_status_snapshot` because plugin is new.
    h.assert_equal(row.text_func(), "Syncing…",
        "pending retry: label flips to 'Syncing…'")
end


-- Tap fires syncNow on the plugin.
do
    local plugin = menu_support.make_fake_plugin{
        ui = menu_support.make_fake_ui{ settings = {} },
    }
    local row = S.sync_now(plugin)
    row.callback()
    h.assert_equal(plugin._calls.syncNow, 1, "sync-now callback fires plugin:syncNow()")
end


-- ---------------------------------------------------------------------------
-- build() composition
-- ---------------------------------------------------------------------------


do
    local plugin = menu_support.make_fake_plugin{
        ui = menu_support.make_fake_ui{ settings = {} },
    }
    local rows = S.build(plugin)
    h.assert_equal(#rows, 3, "build(): exactly three rows")

    -- Smart header caps the top of the cluster with a separator; sync-now now
    -- closes the bottom (the "Show device status" door that used to provide the
    -- closing separator was removed -- the Progress Browser replaces it).
    h.assert_true(rows[1].separator == true, "build(): smart_header has separator (caps cluster)")
    h.assert_true(rows[2].separator ~= true, "build(): sync-this-book has no separator")
    h.assert_true(rows[3].separator == true, "build(): sync-now closes the cluster with a separator")
end


-- ---------------------------------------------------------------------------
-- wiring audit: resolveStatusProblem (main.lua) routes the actionable tap
-- to the failing transport's SETUP, not the read-only status detail
-- ---------------------------------------------------------------------------

do
    local function slurp(path)
        local f = io.open(path, "r") or io.open("../" .. path, "r")
        if not f then return nil end
        local s = f:read("*a"); f:close()
        return s
    end
    local src = slurp("main.lua")
    h.assert_true(src ~= nil, "audit: could open main.lua")
    src = src or ""

    local body = src:match("function Syncery:resolveStatusProblem%(%)(.-)\nend")
    h.assert_true(body ~= nil,
        "wiring: Syncery:resolveStatusProblem is defined")
    body = body or ""
    h.assert_true(body:find("actionable_problem", 1, true) ~= nil,
        "wiring: resolveStatusProblem asks status_section.actionable_problem which transport")
    h.assert_true(body:find('"syncthing"', 1, true) ~= nil
        and body:find("showSyncthingWizard", 1, true) ~= nil,
        "wiring: a syncthing problem opens showSyncthingWizard")
    h.assert_true(body:find('"cloud"', 1, true) ~= nil
        and body:find("pickCloudDestination", 1, true) ~= nil,
        "wiring: a cloud problem opens pickCloudDestination")
end
