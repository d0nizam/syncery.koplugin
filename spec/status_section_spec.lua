-- =============================================================================
-- spec/status_section_spec.lua
-- =============================================================================
--
-- Tests for syncery_ui/status_section.lua — the Phase 6 home of the
-- status badge (`compose_badge`, formerly main.lua's `_statusBadge`)
-- and the smart-header logic (`get_status_header`, `header_needs_action`).
--
-- Covers:
--   * compose_badge: "no sync" when nothing is enabled.
--   * compose_badge: auxiliary badge ("cloud: ok" / "cloud: idle")
--     composed from the transport snapshot — NOT from the dropped
--     legacy per-push flags.
--   * compose_badge: Syncthing-on "idle" / "not configured" wording
--     (the dead time-based "synced N ago" / "unreachable" display was
--     removed — its backing fields were never written in production).
--   * compose_badge: pending-retry " …" suffix (hangs on "idle").
--   * get_status_header: ⚠ prefix on actionable problems, priority
--     ordering, "Retrying…" informational case.
--   * header_needs_action: derived from the header string — can never
--     disagree with get_status_header.
-- =============================================================================


local h            = require("spec.test_helpers")
local menu_support = require("spec.menu_test_support")
h.setup("/tmp/syncery_status_section_spec_" .. tostring(os.time()))
menu_support.install_stubs()

local S = require("syncery_ui/status_section")


-- ---------------------------------------------------------------------------
-- compose_badge — nothing enabled
-- ---------------------------------------------------------------------------

do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = false, use_cloud = false,
    }
    h.assert_equal(S.compose_badge(plugin), "no sync",
        "compose_badge: no transports → 'no sync'")
end


-- ---------------------------------------------------------------------------
-- compose_badge — auxiliary badge from the snapshot (Syncthing off)
-- ---------------------------------------------------------------------------

-- Cloud on, configured, but a push error is on record → "cloud: …".
do
    menu_support.install_stubs{ settings = { is_cloud_configured = true } }
    package.loaded["syncery_ui/status_section"] = nil
    local SS = require("syncery_ui/status_section")
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = false, use_cloud = true,
        _transport = menu_support.make_fake_transport({
            cloud = { display_name = "Cloud", available = true,
                      summary = "ready", orch_last_error_class = "network" },
        }),
    }
    h.assert_equal(SS.compose_badge(plugin), "cloud: …",
        "compose_badge: cloud with an error class → 'cloud: …'")
end


-- Cloud on but not configured → "cloud: not set".
do
    menu_support.install_stubs{ settings = { is_cloud_configured = false } }
    package.loaded["syncery_ui/status_section"] = nil
    local SS = require("syncery_ui/status_section")
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = false, use_cloud = true,
        _transport = menu_support.make_fake_transport({
            cloud = { display_name = "Cloud", available = false,
                      summary = "not configured" },
        }),
    }
    h.assert_equal(SS.compose_badge(plugin), "cloud: not set",
        "compose_badge: cloud not configured → 'cloud: not set'")
end


-- F1: a picked-but-UNSUPPORTED provider (e.g. FTP) is configured (has a
-- url/address) but NOT available. Without the structured flag it would fall
-- through to "cloud: idle" and look fine — the silent no-op F1 closes. It
-- must read distinctly.
do
    menu_support.install_stubs{ settings = { is_cloud_configured = true } }
    package.loaded["syncery_ui/status_section"] = nil
    local SS = require("syncery_ui/status_section")
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = false, use_cloud = true,
        _transport = menu_support.make_fake_transport({
            cloud = { display_name = "Cloud", available = false,
                      summary = "provider not supported for sync (ftp)",
                      unsupported_provider = true, provider_type = "ftp" },
        }),
    }
    h.assert_equal(SS.compose_badge(plugin), "cloud: unsupported provider",
        "compose_badge: unsupported provider reads distinctly, not 'idle'")
end


-- A picked server with NO cloud backend reads as "no backend" (enable one),
-- distinct from and ahead of "unsupported" / "idle".
do
    menu_support.install_stubs{ settings = { is_cloud_configured = true } }
    package.loaded["syncery_ui/status_section"] = nil
    local SS = require("syncery_ui/status_section")
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = false, use_cloud = true,
        _transport = menu_support.make_fake_transport({
            cloud = { display_name = "Cloud", available = false,
                      summary = "no cloud backend available (enable \"Cloud storage+\")",
                      backend_unavailable = true, provider_type = "webdav" },
        }),
    }
    h.assert_equal(SS.compose_badge(plugin), "cloud: no backend",
        "compose_badge: no backend reads distinctly, not 'idle' or 'unsupported'")
end


-- Cloud badge composes a single ' · ' fragment when only cloud is on.
do
    menu_support.install_stubs{ settings = { is_cloud_configured = true } }
    package.loaded["syncery_ui/status_section"] = nil
    local SS = require("syncery_ui/status_section")
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = false, use_cloud = true,
        _transport = menu_support.make_fake_transport({
            cloud  = { display_name = "Cloud",  available = true, summary = "ready" },
        }),
    }
    h.assert_equal(SS.compose_badge(plugin), "cloud: ok",
        "compose_badge: cloud only → 'cloud: ok'")
end


-- ---------------------------------------------------------------------------
-- compose_badge — Syncthing on
-- ---------------------------------------------------------------------------

-- restore default stubs for the Syncthing cases
menu_support.install_stubs()
package.loaded["syncery_ui/status_section"] = nil
S = require("syncery_ui/status_section")


-- Available → "idle".
--
-- After the dead time-display removal (last_sync_attempt/success were
-- never written in production) the Syncthing badge reports configured-
-- state only: "idle" when available, "not configured" otherwise.  There
-- is no "synced N min ago" — see status_section.lua's "WHAT CHANGED IN
-- THE MOVE" note.
do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        _transport = menu_support.make_fake_transport({
            syncthing = { display_name = "Syncthing", available = true,
                          summary = "ready" },
        }),
    }
    h.assert_equal(S.compose_badge(plugin), "idle",
        "compose_badge: available → 'idle'")
end


-- Transport unavailable → "not configured".
do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        _transport = menu_support.make_fake_transport({
            syncthing = { display_name = "Syncthing", available = false,
                          summary = "not configured" },
        }),
    }
    h.assert_equal(S.compose_badge(plugin), "not configured",
        "compose_badge: unavailable → 'not configured'")
end


-- Pending retry appends the " …" suffix — hangs on "idle" now, not on a
-- time-based string.
do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        _transport = menu_support.make_fake_transport({
            syncthing = { display_name = "Syncthing", available = true,
                          summary = "ready", orch_any_pending_retry = true },
        }),
    }
    h.assert_equal(S.compose_badge(plugin), "idle …",
        "compose_badge: pending retry → ' …' suffix on idle")
end


-- ---------------------------------------------------------------------------
-- get_status_header — actionable problems get the ⚠ prefix
-- ---------------------------------------------------------------------------

-- Syncthing toggle on but transport unavailable → ⚠.
do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        _transport = menu_support.make_fake_transport({
            syncthing = { display_name = "Syncthing", available = false,
                          summary = "not configured" },
        }),
    }
    local header = S.get_status_header(plugin)
    h.assert_true(header:sub(1, #"⚠") == "⚠",
        "get_status_header: unavailable transport → header starts with ⚠")
    h.assert_true(header:find("Syncthing") ~= nil,
        "get_status_header: ⚠ header names the transport")
    h.assert_true(S.header_needs_action(plugin),
        "header_needs_action: true for the ⚠ header")
end


-- auth_failed error class → ⚠ "authentication failed".
do
    local plugin = menu_support.make_fake_plugin{
        use_cloud = true,
        _transport = menu_support.make_fake_transport({
            cloud = { display_name = "Cloud", available = true,
                      summary = "ready", orch_last_error_class = "auth_failed" },
        }),
    }
    local header = S.get_status_header(plugin)
    h.assert_true(header:sub(1, #"⚠") == "⚠",
        "get_status_header: auth_failed → ⚠ prefix")
    h.assert_true(header:find("authentication") ~= nil,
        "get_status_header: auth_failed → 'authentication' in text")
end


-- Priority: syncthing problem wins over a cloud problem.
do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true, use_cloud = true,
        _transport = menu_support.make_fake_transport({
            syncthing = { display_name = "Syncthing", available = false,
                          summary = "not configured" },
            cloud     = { display_name = "Cloud", available = false,
                          summary = "not configured" },
        }),
    }
    local header = S.get_status_header(plugin)
    h.assert_true(header:find("Syncthing") ~= nil,
        "get_status_header: syncthing problem outranks cloud problem")
end


-- Mid-retry with no actionable problem → "Retrying…" (no ⚠).
do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        _transport = menu_support.make_fake_transport({
            syncthing = { display_name = "Syncthing", available = true,
                          summary = "ready", orch_any_pending_retry = true },
        }),
    }
    local header = S.get_status_header(plugin)
    h.assert_true(header:find("Retrying") ~= nil,
        "get_status_header: pending retry → 'Retrying…'")
    h.assert_false(S.header_needs_action(plugin),
        "header_needs_action: false for the informational 'Retrying…' header")
end


-- ---------------------------------------------------------------------------
-- header_needs_action — derived purely from the header string
-- ---------------------------------------------------------------------------

-- Single-source-of-truth property: header_needs_action agrees with the
-- ⚠ prefix of get_status_header for EVERY case, by construction.
do
    local cases = {
        -- {opts, transport_status, expect_needs_action}
        { { use_syncthing = false }, {}, false },
        { { use_syncthing = true },
          { syncthing = { display_name = "Syncthing", available = false,
                          summary = "x" } }, true },
        { { use_syncthing = true },
          { syncthing = { display_name = "Syncthing", available = true,
                          summary = "ready" } }, false },
    }
    for i, c in ipairs(cases) do
        local opts = c[1]
        opts._transport = menu_support.make_fake_transport(c[2])
        local plugin = menu_support.make_fake_plugin(opts)
        local header = S.get_status_header(plugin)
        local prefix_says = (header:sub(1, #"⚠") == "⚠")
        h.assert_equal(S.header_needs_action(plugin), prefix_says,
            "header_needs_action case " .. i .. " agrees with ⚠ prefix")
        h.assert_equal(S.header_needs_action(plugin), c[3],
            "header_needs_action case " .. i .. " matches expectation")
    end
end


-- ---------------------------------------------------------------------------
-- actionable_problem — which transport the "tap to resolve" should target
-- ---------------------------------------------------------------------------

-- No problem → (nil, nil): nothing to resolve, the header is informational.
do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        _transport = menu_support.make_fake_transport({
            syncthing = { display_name = "Syncthing", available = true, summary = "ready" },
        }),
    }
    local id = S.actionable_problem(plugin)
    h.assert_equal(id, nil, "actionable_problem: nil when nothing needs action")
end

-- Syncthing unavailable → ("syncthing", "config_needed").
do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        _transport = menu_support.make_fake_transport({
            syncthing = { display_name = "Syncthing", available = false, summary = "x" },
        }),
    }
    local id, kind = S.actionable_problem(plugin)
    h.assert_equal(id, "syncthing", "actionable_problem: identifies syncthing")
    h.assert_equal(kind, "config_needed", "actionable_problem: config_needed kind")
end

-- Cloud reachable but auth rejected → ("cloud", "auth_failed").
do
    local plugin = menu_support.make_fake_plugin{
        use_cloud = true,
        _transport = menu_support.make_fake_transport({
            cloud = { display_name = "Cloud", available = true,
                      summary = "ready", orch_last_error_class = "auth_failed" },
        }),
    }
    local id, kind = S.actionable_problem(plugin)
    h.assert_equal(id, "cloud", "actionable_problem: identifies cloud")
    h.assert_equal(kind, "auth_failed", "actionable_problem: auth_failed kind")
end

-- Priority: when both transports have a problem, Syncthing wins (same
-- order as the header text, so target and ⚠ display agree).
do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true, use_cloud = true,
        _transport = menu_support.make_fake_transport({
            syncthing = { display_name = "Syncthing", available = false, summary = "x" },
            cloud     = { display_name = "Cloud",     available = false, summary = "y" },
        }),
    }
    local id = S.actionable_problem(plugin)
    h.assert_equal(id, "syncthing",
        "actionable_problem: syncthing wins when both have problems")
end


h.teardown()
