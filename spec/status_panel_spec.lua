-- =============================================================================
-- spec/status_panel_spec.lua
-- =============================================================================
--
-- Tests for syncery_ui/status_panel.lua — the per-transport status
-- panel (Pattern 5 / bookends lesson 5), the long-press destination
-- for a transport row in menuHowToSync.
--
-- Covers:
--   * compose: "not active" body when the transport has no snapshot
--     entry.
--   * compose: renders display name, availability, summary, error
--     class, pending-retry flag.
--   * compose: per-book section — lists only books with a pending
--     retry or recorded error; "no books waiting" when none.
--   * compose: per-book entries sorted newest-attempt-first.
--   * show: opens a TextViewer titled for the transport.
--   * _time_ago: timezone-safe relative formatter.
-- =============================================================================


local h            = require("spec.test_helpers")
local menu_support = require("spec.menu_test_support")
h.setup("/tmp/syncery_status_panel_spec_" .. tostring(os.time()))
menu_support.install_stubs()


-- Record UIManager:show targets so `show` can be asserted.
local shown = {}
local function reset_shown() for k in pairs(shown) do shown[k] = nil end end
package.loaded["ui/uimanager"] = {
    show  = function(_, w) table.insert(shown, w) end,
    close = function() end,
}
package.loaded["ui/widget/textviewer"]  = { new = function(_, a) return a or {} end }
package.loaded["ui/widget/infomessage"] = { new = function(_, a) return a or {} end }

package.loaded["syncery_ui/status_panel"] = nil
local Panel = require("syncery_ui/status_panel")


-- ---------------------------------------------------------------------------
-- compose — transport not active
-- ---------------------------------------------------------------------------

do
    local plugin = menu_support.make_fake_plugin{
        _transport = menu_support.make_fake_transport({}),  -- empty snapshot
    }
    local body = Panel.compose(plugin, "syncthing")
    h.assert_true(body:find("not active") ~= nil,
        "compose: no snapshot entry → 'not active' body")
end


-- ---------------------------------------------------------------------------
-- compose — renders the transport status fields
-- ---------------------------------------------------------------------------

do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        _transport = menu_support.make_fake_transport({
            syncthing = {
                display_name = "Syncthing",
                available    = true,
                summary      = "ready (replication via daemon)",
            },
        }),
    }
    local body = Panel.compose(plugin, "syncthing")
    h.assert_true(body:find("Syncthing") ~= nil,
        "compose: body names the transport")
    h.assert_true(body:find("ready %(replication") ~= nil,
        "compose: body includes the transport summary string")
    h.assert_true(body:find("Available: yes") ~= nil,
        "compose: body shows availability")
    h.assert_true(body:find("Pending retry: no") ~= nil,
        "compose: body shows the pending-retry flag")
end


-- ---------------------------------------------------------------------------
-- compose — error class surfaces
-- ---------------------------------------------------------------------------

do
    local plugin = menu_support.make_fake_plugin{
        use_cloud = true,
        _transport = menu_support.make_fake_transport({
            cloud = {
                display_name = "Cloud",
                available    = true,
                summary      = "ready",
                orch_last_error_class  = "auth_failed",
                orch_any_pending_retry = true,
            },
        }),
    }
    local body = Panel.compose(plugin, "cloud")
    h.assert_true(body:find("auth_failed") ~= nil,
        "compose: body surfaces the orchestrator error class")
    h.assert_true(body:find("Pending retry: yes") ~= nil,
        "compose: body shows pending retry when set")
end


-- ---------------------------------------------------------------------------
-- compose — cloud backend note (fallback only)
--
-- One backend (the "Cloud storage+" plugin) → normally no backend line at
-- all.  The ONLY surfaced case is the invisible syncservice fallback.
-- ---------------------------------------------------------------------------

do
    -- Normal: cloudstorage active, no fallback → the panel shows NO backend
    -- label and NO fallback note (there is nothing to disambiguate).
    local plugin = menu_support.make_fake_plugin{
        use_cloud = true,
        _transport = menu_support.make_fake_transport({
            cloud = {
                display_name   = "Cloud",
                available      = true,
                summary        = "ready",
                cloud_provider = "cloudstorage",
            },
        }),
    }
    local body = Panel.compose(plugin, "cloud")
    h.assert_false(body:find("Backend:", 1, true) ~= nil,
        "compose: no 'Backend:' line in the normal single-backend case")
    h.assert_false(body:find("Cloud storage+", 1, true) ~= nil,
        "compose: no backend label / note when the plugin is available")
end

do
    -- Fallback: plugin unavailable → cloud sync runs on the built-in
    -- syncservice (fell_back).  The panel surfaces one clear note: names the
    -- plugin, says it isn't available, warns FTP won't sync.
    local plugin = menu_support.make_fake_plugin{
        use_cloud = true,
        _transport = menu_support.make_fake_transport({
            cloud = {
                display_name       = "Cloud",
                available          = true,
                summary            = "ready",
                cloud_provider     = "syncservice",
                provider_fell_back = true,
            },
        }),
    }
    local body = Panel.compose(plugin, "cloud")
    h.assert_true(body:find("Cloud storage+", 1, true) ~= nil,
        "compose: fallback note names the Cloud storage+ plugin")
    h.assert_true(body:find("isn't", 1, true) ~= nil,
        "compose: fallback note says the plugin isn't available")
    h.assert_true(body:find("FTP", 1, true) ~= nil,
        "compose: fallback note warns FTP won't sync")
    h.assert_false(body:find("Backend:", 1, true) ~= nil,
        "compose: still no 'Backend:' line even on fallback")
end

do
    -- No backend at all: the header must use the translated "no backend"
    -- label, not the raw state token — and there must be no contradictory
    -- "using built-in cloud sync" fallback note (the transport suppresses
    -- provider_fell_back when state is no_backend).
    local plugin = menu_support.make_fake_plugin{
        use_cloud = true,
        _transport = menu_support.make_fake_transport({
            cloud = {
                display_name        = "Cloud",
                available           = false,
                summary             = "no cloud backend available (enable \"Cloud storage+\")",
                backend_unavailable = true,
                cloud_provider      = "syncservice",
            },
        }),
    }
    local body = Panel.compose(plugin, "cloud")
    h.assert_true(body:find("Cloud — no backend", 1, true) ~= nil,
        "compose: header maps no_backend to the translated label")
    h.assert_false(body:find("no_backend", 1, true) ~= nil,
        "compose: raw no_backend token never shown")
    h.assert_false(body:find("using built-in cloud sync", 1, true) ~= nil,
        "compose: no fallback note in the no-backend state")
end


-- ---------------------------------------------------------------------------
-- compose — no backend line for non-cloud transports
-- ---------------------------------------------------------------------------

do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        _transport = menu_support.make_fake_transport({
            syncthing = {
                display_name   = "Syncthing",
                available      = true,
                summary        = "ready",
                cloud_provider = "cloudstorage",  -- must be ignored for syncthing
            },
        }),
    }
    local body = Panel.compose(plugin, "syncthing")
    h.assert_false(body:find("Backend:") ~= nil,
        "compose: backend line is cloud-only (not shown for syncthing)")
end


-- ---------------------------------------------------------------------------
-- compose — per-book section: only interesting books
-- ---------------------------------------------------------------------------

do
    local now = os.time()
    local per_book = {
        cloud = {
            -- A book mid-retry — should appear.
            { book_file = "/books/Pending One.epub", state = {
                pending_retry_at = now + 60,
                last_attempt_at  = now - 120,
                consecutive_failures = 2,
            }},
            -- A book that synced cleanly — should NOT appear.
            { book_file = "/books/Clean.epub", state = {
                last_success_at = now - 30,
            }},
            -- A book with a recorded error — should appear.
            { book_file = "/books/Errored.epub", state = {
                last_error_class = "network",
                last_attempt_at  = now - 600,
            }},
        },
    }
    local plugin = menu_support.make_fake_plugin{
        use_cloud = true,
        _transport = menu_support.make_fake_transport({
            cloud = { display_name = "Cloud", available = true,
                      summary = "ready", orch_any_pending_retry = true },
        }, per_book),
    }
    local body = Panel.compose(plugin, "cloud")
    h.assert_true(body:find("Pending One.epub") ~= nil,
        "compose: per-book section lists the retrying book")
    h.assert_true(body:find("Errored.epub") ~= nil,
        "compose: per-book section lists the errored book")
    h.assert_false(body:find("Clean.epub") ~= nil,
        "compose: per-book section omits the cleanly-synced book")
    h.assert_true(body:find("%(2%):") ~= nil,
        "compose: per-book header shows the count of interesting books")
    h.assert_true(body:find("consecutive failures") ~= nil,
        "compose: per-book detail shows the consecutive-failure count")
    -- Basenames only — not full paths.
    h.assert_false(body:find("/books/Pending") ~= nil,
        "compose: per-book rows show basename, not full path")
end


-- ---------------------------------------------------------------------------
-- compose — newest attempt first
-- ---------------------------------------------------------------------------

do
    local now = os.time()
    local per_book = {
        cloud = {
            { book_file = "/b/Older.epub", state = {
                last_error_class = "network", last_attempt_at = now - 9000 }},
            { book_file = "/b/Newer.epub", state = {
                last_error_class = "network", last_attempt_at = now - 60 }},
        },
    }
    local plugin = menu_support.make_fake_plugin{
        use_cloud = true,
        _transport = menu_support.make_fake_transport({
            cloud = { display_name = "Cloud", available = true, summary = "x" },
        }, per_book),
    }
    local body = Panel.compose(plugin, "cloud")
    local pos_newer = body:find("Newer.epub")
    local pos_older = body:find("Older.epub")
    h.assert_true(pos_newer ~= nil and pos_older ~= nil,
        "compose: both books present")
    h.assert_true(pos_newer < pos_older,
        "compose: newest-attempt book is listed first")
end


-- ---------------------------------------------------------------------------
-- compose — "no books waiting" when nothing is interesting
-- ---------------------------------------------------------------------------

do
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        _transport = menu_support.make_fake_transport({
            syncthing = { display_name = "Syncthing", available = true,
                          summary = "ready" },
        }),  -- no per_book_map → peek_transport_books returns {}
    }
    local body = Panel.compose(plugin, "syncthing")
    h.assert_true(body:find("No books are waiting") ~= nil,
        "compose: 'no books waiting' when nothing is pending")
end


-- ---------------------------------------------------------------------------
-- show — opens a TextViewer titled for the transport
-- ---------------------------------------------------------------------------

do
    reset_shown()
    local plugin = menu_support.make_fake_plugin{
        use_syncthing = true,
        _transport = menu_support.make_fake_transport({
            syncthing = { display_name = "Syncthing", available = true,
                          summary = "ready" },
        }),
    }
    Panel.show(plugin, "syncthing")
    h.assert_equal(#shown, 1, "show: one widget shown")
    h.assert_true(shown[1].title ~= nil and shown[1].title:find("Syncthing") ~= nil,
        "show: the TextViewer is titled for the transport")
    h.assert_true(shown[1].text ~= nil and #shown[1].text > 0,
        "show: the TextViewer carries the composed body")
    h.assert_true(shown[1].buttons_table ~= nil,
        "show: the TextViewer has a Close button")
end


-- show with no transport_id → an InfoMessage, not a crash.
do
    reset_shown()
    local plugin = menu_support.make_fake_plugin{
        _transport = menu_support.make_fake_transport({}),
    }
    Panel.show(plugin, nil)
    h.assert_equal(#shown, 1, "show: nil transport_id → one widget")
    h.assert_true(shown[1].text:find("No transport") ~= nil,
        "show: nil transport_id → 'No transport selected' message")
end


-- ---------------------------------------------------------------------------
-- _time_ago — timezone-safe relative formatter
-- ---------------------------------------------------------------------------

do
    h.assert_equal(Panel._time_ago(nil), "never",
        "_time_ago: nil → 'never'")
    h.assert_equal(Panel._time_ago(os.time() - 10), "just now",
        "_time_ago: <60s → 'just now'")
    h.assert_equal(Panel._time_ago(os.time() - 300), "5 min ago",
        "_time_ago: 5 minutes → '5 min ago'")
    h.assert_equal(Panel._time_ago(os.time() - 7200), "2 hr ago",
        "_time_ago: 2 hours → '2 hr ago'")
    h.assert_equal(Panel._time_ago(os.time() - 172800), "2 days ago",
        "_time_ago: 2 days → '2 days ago'")
    -- Clock-skew guard: a future timestamp must not produce a negative
    -- or garbage age.
    h.assert_equal(Panel._time_ago(os.time() + 500), "just now",
        "_time_ago: future timestamp (clock skew) → 'just now'")
    -- Every branch uses os.difftime on two epoch values → timezone-
    -- independent.  The 7-timezone matrix verifies this stays true.
end


-- ===========================================================================
-- Phase 11 — daemon-control button
--
-- The panel's one write path: a "Start/Stop Syncthing daemon" button,
-- shown ONLY for a Syncthing transport whose bridge advertises the
-- daemon_control capability.
-- ===========================================================================


-- Build a bridge-shaped fake that ALSO carries the Phase 11 daemon
-- surface.  `daemon` opts: { supported = bool, running = bool|nil }.
local function make_daemon_bridge(status_map, daemon)
    daemon = daemon or {}
    local rec = {
        start_calls = 0,
        stop_calls  = 0,
        running     = daemon.running,
    }
    local bridge = {
        get_status = function(_) return status_map or {} end,
        peek_transport_books = function(_, _) return {} end,
        supports_daemon_control = function(_)
            return daemon.supported == true
        end,
        is_daemon_running = function(_)
            if daemon.supported ~= true then return nil end
            return rec.running
        end,
        start_daemon = function(_, cb)
            rec.start_calls = rec.start_calls + 1
            rec.running = true
            if cb then cb(true) end
        end,
        stop_daemon = function(_, cb)
            rec.stop_calls = rec.stop_calls + 1
            rec.running = false
            if cb then cb(true) end
        end,
    }
    return bridge, rec
end


-- daemon_button_state: hidden for non-Syncthing transports.
do
    local bridge = make_daemon_bridge({}, { supported = true, running = false })
    local plugin = menu_support.make_fake_plugin{ use_cloud = true,
        _transport = bridge }
    local state = Panel.daemon_button_state(plugin, "cloud")
    h.assert_false(state.show,
        "daemon button hidden for a non-Syncthing transport")
end


-- daemon_button_state: hidden when the bridge has no Phase 11 surface.
do
    local plugin = menu_support.make_fake_plugin{ use_syncthing = true,
        _transport = menu_support.make_fake_transport({
            syncthing = { display_name = "Syncthing", available = true,
                          summary = "ready" },
        }) }  -- plain fake, no is_daemon_running
    local state = Panel.daemon_button_state(plugin, "syncthing")
    h.assert_false(state.show,
        "daemon button hidden when the bridge lacks the daemon surface")
end


-- daemon_button_state: hidden when daemon_control capability absent.
do
    local bridge = make_daemon_bridge({}, { supported = false })
    local plugin = menu_support.make_fake_plugin{ use_syncthing = true,
        _transport = bridge }
    local state = Panel.daemon_button_state(plugin, "syncthing")
    h.assert_false(state.show,
        "daemon button hidden when daemon_control not advertised")
end


-- daemon_button_state: shown with a Start label when daemon is stopped.
do
    local bridge = make_daemon_bridge({}, { supported = true, running = false })
    local plugin = menu_support.make_fake_plugin{ use_syncthing = true,
        _transport = bridge }
    local state = Panel.daemon_button_state(plugin, "syncthing")
    h.assert_true(state.show, "daemon button shown for KOSyncthing+-backed Syncthing")
    h.assert_equal(state.running, false, "state reflects the stopped daemon")
    h.assert_true(state.label:find("Start") ~= nil,
        "label says Start when the daemon is stopped")
end


-- daemon_button_state: shown with a Stop label when daemon is running.
do
    local bridge = make_daemon_bridge({}, { supported = true, running = true })
    local plugin = menu_support.make_fake_plugin{ use_syncthing = true,
        _transport = bridge }
    local state = Panel.daemon_button_state(plugin, "syncthing")
    h.assert_true(state.show, "daemon button shown")
    h.assert_equal(state.running, true, "state reflects the running daemon")
    h.assert_true(state.label:find("Stop") ~= nil,
        "label says Stop when the daemon is running")
end


-- daemon_button_state: capability present but running state unknown →
-- still shown, with a neutral label.
do
    local bridge = make_daemon_bridge({}, { supported = true, running = nil })
    local plugin = menu_support.make_fake_plugin{ use_syncthing = true,
        _transport = bridge }
    local state = Panel.daemon_button_state(plugin, "syncthing")
    h.assert_true(state.show,
        "daemon button shown when capable even if running state unknown")
    h.assert_true(state.label:find("control") ~= nil,
        "neutral label when running state is unknown")
end


-- daemon_button_state: hidden on Android even when KOSyncthing+ advertises
-- daemon_control and the daemon is running.  On Android the plugin runs in
-- remote mode against a separate Syncthing app it cannot start or stop, so a
-- start/stop button would report success but change nothing.
do
    local saved_is_android = Panel._is_android
    Panel._is_android = function() return true end

    local bridge = make_daemon_bridge({}, { supported = true, running = true })
    local plugin = menu_support.make_fake_plugin{ use_syncthing = true,
        _transport = bridge }
    local state = Panel.daemon_button_state(plugin, "syncthing")
    h.assert_false(state.show,
        "daemon button hidden on Android even when KOSyncthing+-backed and capable")

    Panel._is_android = saved_is_android
end


-- daemon_button_state: shown on non-Android when KOSyncthing+-backed and capable —
-- the companion to the Android case, pinning the gate to the platform (a
-- broken gate that hid the button everywhere would fail here).
do
    local saved_is_android = Panel._is_android
    Panel._is_android = function() return false end

    local bridge = make_daemon_bridge({}, { supported = true, running = true })
    local plugin = menu_support.make_fake_plugin{ use_syncthing = true,
        _transport = bridge }
    local state = Panel.daemon_button_state(plugin, "syncthing")
    h.assert_true(state.show,
        "daemon button shown on non-Android when KOSyncthing+-backed and capable")

    Panel._is_android = saved_is_android
end


-- show: the daemon button appears in the TextViewer button row for a
-- KOSyncthing+-backed Syncthing transport, and tapping it invokes the bridge.
do
    reset_shown()
    local bridge, rec = make_daemon_bridge({
        syncthing = { display_name = "Syncthing", available = true,
                      summary = "ready" },
    }, { supported = true, running = false })
    local plugin = menu_support.make_fake_plugin{ use_syncthing = true,
        _transport = bridge }

    Panel.show(plugin, "syncthing")
    local viewer = shown[1]
    local row = viewer.buttons_table[1]
    h.assert_equal(#row, 2,
        "show: button row has Close + the daemon button")
    -- The daemon button is the second entry.
    local daemon_btn = row[2]
    h.assert_true(daemon_btn.text:find("Start") ~= nil,
        "show: daemon button labelled Start (daemon stopped)")

    -- Tapping it starts the daemon and shows a confirmation.
    daemon_btn.callback()
    h.assert_equal(rec.start_calls, 1,
        "show: tapping the daemon button invokes bridge:start_daemon")
end


-- show: no daemon button for a transport without the capability.
do
    reset_shown()
    local bridge = make_daemon_bridge({
        syncthing = { display_name = "Syncthing", available = true,
                      summary = "ready" },
    }, { supported = false })
    local plugin = menu_support.make_fake_plugin{ use_syncthing = true,
        _transport = bridge }

    Panel.show(plugin, "syncthing")
    local viewer = shown[1]
    h.assert_equal(#viewer.buttons_table[1], 1,
        "show: only the Close button when daemon_control is unavailable")
end


h.teardown()
