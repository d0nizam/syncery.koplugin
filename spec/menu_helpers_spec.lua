-- =============================================================================
-- spec/menu_helpers_spec.lua
-- =============================================================================
--
-- Tests for syncery_ui/menu/_helpers.lua — focused on the bits that
-- are NEW in Phase 4: the centralised status snapshot
-- (`H.status_snapshot` / `H.clear_status_snapshot`) and the
-- `H.transport_state` classifier that drives Pattern 3 labels.
--
-- The legacy helpers (load_/save_cfg, makeBoolToggle, safe, etc.)
-- are exercised indirectly by the section specs — they're simple
-- enough that an additional unit test here would duplicate coverage.
-- =============================================================================


local h            = require("spec.test_helpers")
local menu_support = require("spec.menu_test_support")
h.setup("/tmp/syncery_menu_helpers_spec_" .. tostring(os.time()))
local stubs = menu_support.install_stubs()

local H = require("syncery_ui/menu/_helpers")


-- A test that needs to inspect toasts uses the module-level `stubs`
-- table.  Resetting between scenarios is done by clearing the
-- recorder lists in-place, NOT by calling install_stubs() again
-- (which would create a NEW UIManager that H wouldn't see).
local function reset_stubs()
    while #stubs.uimgr._events > 0 do
        table.remove(stubs.uimgr._events)
    end
    while #stubs.info._shown > 0 do
        table.remove(stubs.info._shown)
    end
    while #stubs.confirm._shown > 0 do
        table.remove(stubs.confirm._shown)
    end
    while #stubs.textviewer._shown > 0 do
        table.remove(stubs.textviewer._shown)
    end
    while #stubs.inputdialog._shown > 0 do
        table.remove(stubs.inputdialog._shown)
    end
end


-- ---------------------------------------------------------------------------
-- status_snapshot
-- ---------------------------------------------------------------------------


-- Snapshot reads through _transport:get_status exactly once and caches.
do
    local call_count = 0
    local plugin = {
        _transport = {
            get_status = function(_)
                call_count = call_count + 1
                return { syncthing = { available = true, summary = "ready" } }
            end,
        },
    }

    local snap1 = H.status_snapshot(plugin)
    local snap2 = H.status_snapshot(plugin)
    local snap3 = H.status_snapshot(plugin)

    h.assert_equal(call_count, 1, "status_snapshot caches: only one get_status call across three lookups")
    h.assert_equal(snap1.syncthing.available, true, "snapshot returns the transport's data")
    h.assert_true(snap1 == snap2, "snapshot returns same table reference on cached read")
    h.assert_true(snap2 == snap3, "snapshot stays cached across N reads")
end


-- clear_status_snapshot lets the next read re-fetch.
do
    local call_count = 0
    local plugin = {
        _transport = {
            get_status = function(_)
                call_count = call_count + 1
                return { syncthing = { available = true } }
            end,
        },
    }

    H.status_snapshot(plugin)
    H.status_snapshot(plugin)
    h.assert_equal(call_count, 1, "before clear: still one call")

    H.clear_status_snapshot(plugin)
    H.status_snapshot(plugin)
    h.assert_equal(call_count, 2, "after clear: next snapshot triggers another get_status call")
end


-- Missing _transport: returns empty table, never crashes.
do
    local plugin = {}  -- no _transport field at all
    local snap = H.status_snapshot(plugin)
    h.assert_true(type(snap) == "table", "snapshot returns table even when _transport is nil")
    h.assert_nil(snap.syncthing, "no transports in snapshot when _transport is nil")
end


-- _transport that raises get_status: caught, snapshot is empty table.
do
    local plugin = {
        _transport = {
            get_status = function() error("simulated transport failure") end,
        },
    }
    local snap = H.status_snapshot(plugin)
    h.assert_true(type(snap) == "table", "snapshot returns table even when get_status raises")
    h.assert_nil(snap.syncthing, "snapshot is empty when get_status raised")
end


-- _transport.get_status returning a non-table: also handled.
do
    local plugin = {
        _transport = {
            get_status = function() return "definitely not a table" end,
        },
    }
    local snap = H.status_snapshot(plugin)
    h.assert_true(type(snap) == "table", "snapshot returns a table even if get_status returned a string")
end


-- ---------------------------------------------------------------------------
-- transport_state classifier
-- ---------------------------------------------------------------------------


-- Missing transport entry → "disabled".
do
    h.assert_equal(H.transport_state({}, "syncthing"),
        "disabled", "missing transport entry classifies as disabled")
end


-- Toggle off (summary contains "disabled") → "disabled".
do
    local snap = { syncthing = { available = false, summary = "disabled (toggle off)" } }
    h.assert_equal(H.transport_state(snap, "syncthing"),
        "disabled", "summary 'disabled (toggle off)' → disabled")
end


-- Toggle on but not configured (available false, summary doesn't say
-- "disabled") → "needs_config".
do
    local snap = { syncthing = { available = false, summary = "not configured" } }
    h.assert_equal(H.transport_state(snap, "syncthing"),
        "needs_config", "available=false + non-disabled summary → needs_config")
end


-- F1: picked-but-unsupported provider → "unsupported", distinct from
-- "needs_config". Driven by the STRUCTURED unsupported_provider flag, not by
-- parsing the summary string.
do
    local snap = { cloud = { available = false,
                             summary = "provider not supported for sync (ftp)",
                             unsupported_provider = true } }
    h.assert_equal(H.transport_state(snap, "cloud"),
        "unsupported", "unsupported_provider flag → 'unsupported', not 'needs_config'")
end


-- Canonical state: a picked server with NO cloud backend → "no_backend",
-- distinct from and taking precedence over "unsupported" (install/enable a
-- backend, don't re-pick the destination).
do
    local snap = { cloud = { available = false,
                             summary = "no cloud backend available (enable \"Cloud storage+\")",
                             backend_unavailable = true } }
    h.assert_equal(H.transport_state(snap, "cloud"),
        "no_backend", "backend_unavailable flag → 'no_backend'")
end


-- Available + pending retry → "syncing" (the retry wins over error
-- since it's the more recent state).
do
    local snap = { syncthing = { available = true, orch_any_pending_retry = true } }
    h.assert_equal(H.transport_state(snap, "syncthing"),
        "syncing", "available + pending_retry → syncing")
end


-- Available + last_error_class (no pending retry) → "error".
do
    local snap = { syncthing = {
        available = true,
        orch_last_error_class = "auth_failed",
        orch_any_pending_retry = false,
    } }
    h.assert_equal(H.transport_state(snap, "syncthing"),
        "error", "available + last_error_class → error")
end


-- Pending retry takes priority over the error class.
do
    local snap = { syncthing = {
        available = true,
        orch_last_error_class = "auth_failed",
        orch_any_pending_retry = true,
    } }
    h.assert_equal(H.transport_state(snap, "syncthing"),
        "syncing", "pending_retry wins over last_error_class")
end


-- Available + no retry + no error → "ready".
do
    local snap = { syncthing = { available = true, summary = "ready" } }
    h.assert_equal(H.transport_state(snap, "syncthing"),
        "ready", "available + clean → ready")
end


-- ---------------------------------------------------------------------------
-- safe (callback wrapper)
-- ---------------------------------------------------------------------------


-- safe-wrapped function that succeeds: the result of calling the
-- wrapper passes through cleanly.  No InfoMessage shown.
do
    reset_stubs()
    local wrapped = H.safe("ok action", function() return 42 end)
    wrapped()
    h.assert_equal(#stubs.info._shown, 0, "safe(): no toast on success")
end


-- safe-wrapped function that errors: an InfoMessage is shown with
-- label + error text.
do
    reset_stubs()
    local wrapped = H.safe("explosive action",
        function() error("kaboom") end)
    wrapped()
    h.assert_equal(#stubs.info._shown, 1, "safe(): one toast on error")
    local msg = stubs.info._shown[1]
    h.assert_true(msg.text:find("explosive action") ~= nil,
        "safe(): toast mentions the action label")
    h.assert_true(msg.text:find("kaboom") ~= nil,
        "safe(): toast mentions the error details")
end


-- ---------------------------------------------------------------------------
-- gatedHold (Pattern 2 — "why disabled" explanations)
-- ---------------------------------------------------------------------------


-- Condition false → shows the gate reason.
do
    reset_stubs()
    local hold = H.gatedHold(function() return false end,
        "gate reason", "normal help")
    hold()
    h.assert_equal(#stubs.info._shown, 1, "gatedHold: one info shown on disabled")
    h.assert_equal(stubs.info._shown[1].text, "gate reason",
        "gatedHold: shows gate_reason when condition is false")
end


-- Condition true → shows the help text.
do
    reset_stubs()
    local hold = H.gatedHold(function() return true end,
        "gate reason", "normal help")
    hold()
    h.assert_equal(#stubs.info._shown, 1, "gatedHold: one info shown on enabled")
    h.assert_equal(stubs.info._shown[1].text, "normal help",
        "gatedHold: shows help when condition is true")
end


-- ---------------------------------------------------------------------------
-- makeBoolToggle
-- ---------------------------------------------------------------------------


-- Plain toggle (no master): flips the field on tap.
do
    local plugin = { sync_progress = false }
    local item = H.makeBoolToggle(plugin, "sync_progress",
        "syncery_sync_progress",
        "Reading progress", "help text")

    h.assert_equal(item.checked_func(), false, "checked: initially off")
    item.callback()
    h.assert_equal(plugin.sync_progress, true, "callback flips the field")
    h.assert_equal(item.checked_func(), true, "checked: now on")
end


-- Master-gated toggle: enabled_func reflects master state.
do
    local plugin = { sync_annotations = true, sync_highlights = false }
    local item = H.makeBoolToggle(plugin, "sync_highlights",
        "syncery_sync_highlights",
        "Highlights", "help", "sync_annotations")

    h.assert_equal(item.enabled_func(), true,
        "master on → toggle enabled")
    plugin.sync_annotations = false
    h.assert_equal(item.enabled_func(), false,
        "master off → toggle disabled")
end


-- Master-off long-press shows the "enable master first" explanation.
do
    reset_stubs()
    local plugin = { sync_annotations = false, sync_highlights = false }
    local item = H.makeBoolToggle(plugin, "sync_highlights",
        "syncery_sync_highlights",
        "Highlights", "the help text", "sync_annotations")
    item.hold_callback()
    h.assert_equal(#stubs.info._shown, 1, "master-off hold: one info shown")
    h.assert_true(stubs.info._shown[1].text:find("master switch") ~= nil,
        "master-off hold: shows 'enable master first' style text")
end


-- Master-on long-press shows the normal help.
do
    reset_stubs()
    local plugin = { sync_annotations = true, sync_highlights = false }
    local item = H.makeBoolToggle(plugin, "sync_highlights",
        "syncery_sync_highlights",
        "Highlights", "the help text", "sync_annotations")
    item.hold_callback()
    h.assert_equal(#stubs.info._shown, 1, "master-on hold: one info shown")
    h.assert_equal(stubs.info._shown[1].text, "the help text",
        "master-on hold: shows the normal help text")
end
