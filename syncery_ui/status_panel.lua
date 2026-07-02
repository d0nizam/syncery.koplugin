-- =============================================================================
-- syncery_ui/status_panel.lua
-- =============================================================================
--
-- Per-transport status panel.
--
-- WHAT IT IS
--
-- A modal `TextViewer` showing everything known about ONE transport:
--   * the transport's own `status()` snapshot — display name,
--     availability, the human summary string;
--   * the orchestrator's decoration — last error class, whether any
--     retry is pending;
--   * per-book pending state — every book this transport has touched
--     that currently has a pending retry or a recorded error, with a
--     "last attempt N min ago" line.
--
-- CONTEXTUAL ACTIONS
--
-- This is the long-press destination for a transport row in
-- `menuHowToSync`.  Tap a transport row → toggles its master switch
-- (existing behaviour).  Long-press → opens THIS panel.  The tap path
-- is the common action; the panel is the "I want to know what's
-- actually going on" power-user path: the common tap action stays
-- simple, the panel is the opt-in deep view.
--
-- SNAPSHOT DISCIPLINE
--
-- The panel does NOT call `_transport:get_status()` itself.  It takes
-- the already-captured snapshot from `menu/_helpers.lua`'s
-- `status_snapshot(plugin)` — the same per-render cache the menu's
-- smart header and badge read.  One transport query per menu render,
-- shared by every consumer.  The per-book retry data is the one thing
-- the snapshot doesn't carry, so the panel reads that — and only that
-- — through `plugin._transport:peek_transport_books(id)` (the Bridge
-- passthrough added for exactly this).
--
-- TIMEZONE NOTE
--
-- The "last attempt N min ago" line is formatted from an epoch
-- difference (`os.difftime(os.time(), ts)`); both operands are
-- absolute epoch seconds, so the result is timezone-independent.  No
-- `os.date` call in this module.  The 7-timezone test matrix
-- exercises this — a timezone-naive formatter here is precisely the
-- bug class it catches.
--
-- THE ONE WRITE PATH
--
-- The panel is read-only except for exactly ONE action: when the
-- transport is
-- Syncthing, available, and advertises the optional `daemon_control`
-- capability (only the KOSyncthing+-backed provider does — see
-- interface.lua / kosyncthing_plus_provider.lua), the panel adds a
-- "Start daemon" / "Stop daemon" button.  The label is chosen from
-- `bridge:is_daemon_running()`; the tap invokes
-- `bridge:start_daemon` / `:stop_daemon`.  Every transport that does
-- NOT advertise the capability — manual-config Syncthing
-- Cloud — gets no button and the panel stays read-only for it.  This
-- is the deliberate, capability-gated exception, not a general
-- relaxation.
--
-- =============================================================================


local UIManager   = require("ui/uimanager")
local TextViewer  = require("ui/widget/textviewer")
local InfoMessage = require("ui/widget/infomessage")

local H = require("syncery_ui/menu/_helpers")
local _ = H._


local Panel = {}


-- ============================================================================
-- Time-ago — timezone-safe relative formatter (epoch difference only)
-- ============================================================================


local function time_ago(ts)
    if not ts then return _("never") end
    local ago = os.difftime(os.time(), ts)
    if ago < 0     then return _("just now") end       -- clock skew guard
    if ago < 60    then return _("just now") end
    if ago < 3600  then return string.format(_("%d min ago"), math.floor(ago / 60)) end
    if ago < 86400 then return string.format(_("%d hr ago"),  math.floor(ago / 3600)) end
    return string.format(_("%d days ago"), math.floor(ago / 86400))
end


-- Exposed for the spec.
Panel._time_ago = time_ago


-- ============================================================================
-- Android detection (cached).  On Android the kosyncthing_plus plugin runs in
-- remote mode against a separate Syncthing app it cannot start or stop, so a
-- daemon start/stop button there would be a misleading no-op (see
-- daemon_button_state).  Exposed so the spec can override it to exercise both
-- platforms without a real Device.
-- ============================================================================


local _is_android_cached = nil
local function is_android()
    if _is_android_cached == nil then
        local ok, Device = pcall(require, "device")
        _is_android_cached = (ok and Device and type(Device.isAndroid) == "function"
                              and Device:isAndroid()) and true or false
    end
    return _is_android_cached
end


-- Exposed for the spec.
Panel._is_android = is_android


-- ============================================================================
-- compose — build the panel's text body for one transport
--
-- Separate from `show` so the rendering is unit-testable without
-- standing up a TextViewer.  Returns the body string.
-- ============================================================================


--- Build the panel body for `transport_id`.
---@param plugin table        the plugin instance
---@param transport_id string "syncthing" | "cloud"
---@return string body  the multi-line panel text
function Panel.compose(plugin, transport_id)
    local snapshot = H.status_snapshot(plugin)
    local s = snapshot[transport_id]

    local lines = {}

    if not s then
        -- No snapshot entry → transport not registered / disabled.
        -- The menu treats "no entry" as "disabled"; mirror that.
        table.insert(lines, _("This transport is not active."))
        table.insert(lines, "")
        table.insert(lines, _("Enable it from the sync menu to see its status here."))
        return table.concat(lines, "\n")
    end

    -- Header: display name + one-word state from the shared helper.
    local state = H.transport_state(snapshot, transport_id)
    local state_label = ({
        disabled     = _("disabled"),
        needs_config = _("needs setup"),
        no_backend   = _("no backend"),
        unsupported  = _("unsupported"),
        syncing      = _("retrying"),
        error        = _("error"),
        ready        = _("ready"),
    })[state] or state
    table.insert(lines, string.format("%s — %s",
        s.display_name or transport_id, state_label))
    table.insert(lines, "")

    -- The transport's own human-readable summary.
    if s.summary and s.summary ~= "" then
        table.insert(lines, _("Status: ") .. s.summary)
    end
    table.insert(lines, _("Available: ")
        .. (s.available and _("yes") or _("no")))

    -- Cloud backend note: with a single backend (the "Cloud storage+"
    -- plugin) there is normally nothing to show.  The ONLY case worth
    -- surfacing is the invisible fallback — the plugin isn't available, so
    -- cloud sync is running on the built-in syncservice (Dropbox/WebDAV
    -- only; FTP destinations can't sync).  ►► REMOVABLE with the syncservice
    -- fallback (koreader#15330): when the fallback goes, this block goes too.
    if transport_id == "cloud" and s.provider_fell_back then
        table.insert(lines, _("Note: the \"Cloud storage+\" plugin isn't "
            .. "available — using built-in cloud sync (Dropbox / WebDAV "
            .. "only; FTP won't sync)."))
    end

    -- Orchestrator decoration.
    if s.orch_last_error_class then
        table.insert(lines, _("Last error: ") .. tostring(s.orch_last_error_class))
    end
    table.insert(lines, _("Pending retry: ")
        .. (s.orch_any_pending_retry and _("yes") or _("no")))

    -- Per-book pending state.  This is the one piece the shared
    -- snapshot doesn't carry — read it through the bridge passthrough.
    local per_book = {}
    if plugin._transport
       and type(plugin._transport.peek_transport_books) == "function" then
        local ok, result = pcall(plugin._transport.peek_transport_books,
            plugin._transport, transport_id)
        if ok and type(result) == "table" then per_book = result end
    end

    -- Keep only books with something worth showing — a pending retry
    -- or a recorded error.  A book that synced cleanly carries no
    -- interesting state and would just be noise.
    local interesting = {}
    for __, rec in ipairs(per_book) do
        local st = rec.state or {}
        if st.pending_retry_at or st.last_error_class then
            table.insert(interesting, rec)
        end
    end
    -- Newest attempt first.
    table.sort(interesting, function(a, b)
        return (a.state.last_attempt_at or 0) > (b.state.last_attempt_at or 0)
    end)

    table.insert(lines, "")
    if #interesting == 0 then
        table.insert(lines, _("No books are waiting to sync on this transport."))
    else
        table.insert(lines, string.format(
            _("Books with pending sync state (%d):"), #interesting))
        for __, rec in ipairs(interesting) do
            local st = rec.state
            -- Show the book's basename — the full path is rarely
            -- useful and overflows the modal.
            local name = rec.book_file
                and (rec.book_file:match("([^/\\]+)$") or rec.book_file)
                or _("(unknown book)")
            table.insert(lines, "  " .. name)
            local detail
            if st.pending_retry_at then
                detail = string.format(_("    retry pending · last attempt %s"),
                    time_ago(st.last_attempt_at))
            else
                detail = string.format(_("    error: %s · last attempt %s"),
                    tostring(st.last_error_class), time_ago(st.last_attempt_at))
            end
            if st.consecutive_failures and st.consecutive_failures > 1 then
                detail = detail .. string.format(
                    _(" · %d consecutive failures"), st.consecutive_failures)
            end
            table.insert(lines, detail)
        end
    end

    return table.concat(lines, "\n")
end


-- ============================================================================
-- Daemon-control button — the panel's one write path
--
-- The button is shown ONLY for a Syncthing transport that is
-- available and advertises the optional `daemon_control` capability.
-- Capability detection lives on the transport/bridge layer; the panel
-- just asks.  `daemon_button_state` is separate from `show` so the
-- show/hide decision and the label choice are unit-testable without
-- standing up a TextViewer.
-- ============================================================================


--- Decide whether the daemon-control button should appear, and with
--- what label.  Returns a table:
---   { show = bool, running = bool|nil, label = string|nil }
--- `show` is false for every transport that is not a KOSyncthing+-backed
--- Syncthing; `running` is the daemon state when known (nil → label
--- falls back to a neutral "Daemon control").
---@param plugin table
---@param transport_id string
---@return table
function Panel.daemon_button_state(plugin, transport_id)
    -- Only Syncthing has a daemon; Cloud never does.
    if transport_id ~= "syncthing" then
        return { show = false }
    end
    -- On Android the daemon is owned by a separate Syncthing app (e.g.
    -- Syncthing-Fork or BasicSync); KOSyncthing+ runs in remote mode
    -- where control.start/stop are no-ops.  A start/stop
    -- button there reports success but changes nothing, so hide it.  The
    -- daemon's reachability is still surfaced via the transport's availability
    -- (is_available), independent of this control.
    if Panel._is_android() then
        return { show = false }
    end
    local bridge = plugin._transport
    if not bridge or type(bridge.is_daemon_running) ~= "function" then
        -- Bridge missing the daemon-control surface entirely (e.g. an older
        -- bridge, or a test transport that doesn't stub it) → no button.
        return { show = false }
    end

    -- is_daemon_running returns nil when daemon control is
    -- unavailable (transport absent / unavailable / capability not
    -- advertised) AND also when the capability IS available but the
    -- running-state read failed.  To distinguish "no capability" from
    -- "capability present, state unknown" we ask the bridge a second,
    -- cheap question if it exposes one; otherwise we treat nil as
    -- "no capability" and hide the button (the safe default — better
    -- to hide a control we cannot drive than to show a dead one).
    local ok, running = pcall(bridge.is_daemon_running, bridge)
    if not ok then
        return { show = false }
    end

    -- A bridge that can answer the daemon-control capability question
    -- directly lets us show the button even when the running-state
    -- read itself returned nil (capability present, state unknown).
    local capable = nil
    if type(bridge.supports_daemon_control) == "function" then
        local ok_c, c = pcall(bridge.supports_daemon_control, bridge)
        if ok_c then capable = c and true or false end
    end

    if capable == false then
        return { show = false }
    end
    if capable == nil and running == nil then
        -- No way to confirm the capability and no running state →
        -- assume unavailable, hide the button.
        return { show = false }
    end

    local label
    if running == true then
        label = _("Stop Syncthing daemon")
    elseif running == false then
        label = _("Start Syncthing daemon")
    else
        label = _("Syncthing daemon control")
    end
    return { show = true, running = running, label = label }
end





--- Open the per-transport status panel.
---@param plugin table
---@param transport_id string "syncthing" | "cloud"
function Panel.show(plugin, transport_id)
    if not transport_id then
        UIManager:show(InfoMessage:new{ text = _("No transport selected.") })
        return
    end

    local snapshot = H.status_snapshot(plugin)
    local s = snapshot[transport_id]
    local title = (s and s.display_name or transport_id) .. " — " .. _("status")

    -- The button row.  Close is always present.  A
    -- daemon-control button is appended ONLY for a KOSyncthing+-backed
    -- Syncthing transport that advertises `daemon_control` — the
    -- panel's one write path.
    local viewer

    local button_row = {
        {
            text     = _("Close"),
            callback = function() UIManager:close(viewer) end,
        },
    }

    local daemon = Panel.daemon_button_state(plugin, transport_id)
    if daemon.show then
        local was_running = daemon.running
        table.insert(button_row, {
            text     = daemon.label,
            callback = function()
                -- The action: start when stopped, stop when running.
                -- When the running state is unknown we default to a
                -- start attempt (the safe, non-destructive direction).
                local bridge = plugin._transport
                local function on_done(ok, err)
                    if ok then
                        UIManager:show(InfoMessage:new{
                            text    = was_running
                                and _("Syncthing daemon stopped.")
                                or  _("Syncthing daemon started."),
                            timeout = 2,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            icon    = "notice-warning",
                            text    = string.format(
                                _("Could not change the Syncthing daemon: %s"),
                                tostring(err or _("unknown error"))),
                            timeout = 4,
                        })
                    end
                    -- Best-effort refresh: close and reopen so the
                    -- button label reflects the new daemon state.
                    UIManager:close(viewer)
                    Panel.show(plugin, transport_id)
                end

                if was_running == true then
                    bridge:stop_daemon(on_done)
                else
                    bridge:start_daemon(on_done)
                end
            end,
        })
    end

    viewer = TextViewer:new{
        title = title,
        text  = Panel.compose(plugin, transport_id),
        buttons_table = { button_row },
    }
    UIManager:show(viewer)
end


return Panel
