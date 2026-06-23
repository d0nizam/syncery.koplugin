-- =============================================================================
-- syncery_transports/interface.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- This file defines the contract every Syncery transport must follow.
-- A "transport" is the thing that moves bytes between this device and
-- other devices or servers.  Today Syncery has two:
--
--   • Syncthing  — peer-to-peer file replication via a Syncthing daemon
--   • Cloud      — Dropbox / WebDAV / FTP via KOReader's SyncService
--
-- They behave very differently underneath (Syncthing hands a file to
-- a daemon and walks away; Cloud makes a real round-trip HTTP call;
-- Cloud uploads a JSON blob), but the rest of the plugin should not
-- have to care.  The router calls every available transport's `push`
-- when there's local state to sync; the status panel calls every
-- transport's `status` when it draws.  Each transport interprets
-- those uniformly.
--
-- This file is pure documentation + a validator.  It contains no
-- transport logic itself.
--
--
-- WHY HAVE AN INTERFACE FILE AT ALL
--
-- Lua has no interface keyword.  Without a written-down contract,
-- transports drift: one returns `(ok, err)`, another returns `ok` with
-- the error in a third argument, a third raises a Lua error.  The
-- router then has to special-case each transport, which is exactly
-- the mess this rewrite is trying to leave behind.
--
-- The contract lives in code, not just in prose, because:
--
--   • `validate_implementation` is run by the router at registration
--     time, so a broken transport fails immediately with a readable
--     error instead of breaking the first time it's actually called.
--
--   • The contract spec (spec/transport_contract_spec.lua) runs every
--     transport through the same scenarios using a fake transport that
--     also has to satisfy this interface.  If the fake passes but a
--     real transport fails the same scenarios, the bug is in the real
--     transport, not in the test harness.
--
-- =============================================================================
--
-- THE INTERFACE
--
-- A Transport is a plain Lua table with the following functions.
-- Argument and return shapes documented per function.
--
--
--   id() → string
--     A stable, machine-friendly id.  Never user-facing.  Used for:
--       • the status-panel key
--       • the user toggle key (`syncery_use_<id>` in G_reader_settings)
--       • the log prefix
--     MUST NOT change between plugin versions — settings keys would orphan.
--     Examples: "syncthing", "cloud".
--
--
--   display_name() → string
--     The user-facing name shown in the status panel and menu.
--     May be translated; may include parenthetical detail.
--     Examples: "Syncthing", "Cloud (Dropbox)".
--
--
--   is_available() → bool
--     True if this transport can carry out push/pull right now.
--     Combines:
--       • the user toggle (`syncery_use_<id>` in G_reader_settings)
--       • configuration completeness (e.g. Cloud needs a configured server)
--       • reachability (e.g. Syncthing daemon up, possibly cached)
--     MUST be cheap — called frequently by the router and by every
--     menu redraw.  No blocking I/O.  Reachability checks may use a
--     short-TTL cache to satisfy this.
--
--
--   is_eventually_consistent() → bool
--     True for transports where a successful `push` only means "the
--     local action completed", not "remote received the bytes".
--     Currently:
--       • Syncthing → true   (push = trigger a folder scan; replication
--                             happens whenever the daemon and peers feel
--                             like it)
--       • Cloud     → false  (push = HTTP PUT that returned 200/201)
--     The contract spec uses this to decide whether the "push then pull
--     observes the pushed value" assertion applies.  The status panel
--     uses it to render a different summary ("pushed and confirmed" vs
--     "scan triggered, replication pending").
--
--
--   push(book_file, opts, callback)
--     Send our local state for `book_file` outbound.
--       book_file  — absolute path to the book the state belongs to
--       opts       — transport-specific table (e.g. device_id, payload, ...)
--       callback   — function(ok: bool, err: string|nil, extra: table|nil)
--     The callback MUST fire exactly once.  `err`, when present, MUST be
--     one of the documented strings in `Interface.ERRORS`.  `extra` is
--     optional transport-specific diagnostic data (e.g. HTTP status code).
--
--
--   pull(book_file, opts, callback)
--     Pull remote state inbound for `book_file`.  Same callback shape as
--     push, except `extra` is also used to deliver the pulled payload —
--     transport-specific (e.g. for Cloud, an upload-result
--     table).  For eventually-consistent transports this is allowed to
--     be a no-op that immediately calls callback(true, nil, nil).
--
--
--   status() → table
--     Structured status for the status panel UI.  Minimum required keys:
--       { display_name = string,
--         available    = bool,
--         summary      = string }    -- one-liner shown next to display_name
--     Transport-specific extra keys (e.g. `last_push_at`, `conflicts_count`)
--     are allowed; the status panel renders them in a transport-specific
--     section beneath the summary line.
--
--
-- OPTIONAL: capability flags
--
--   supports(capability_name) → bool
--     Used by router and UI to enable/disable transport-specific menus.
--     Known capabilities are listed in `Interface.CAPABILITIES`.
--     Transports that do not implement `supports` are treated as exposing
--     no optional capabilities — the router checks
--     `type(t.supports) == "function" and t.supports(cap)`.
--
-- =============================================================================


local Interface = {}


-- ----------------------------------------------------------------------------
-- Public constants
-- ----------------------------------------------------------------------------


--- Methods every Transport MUST implement.
--- Order is canonical (for stable validator error messages) but not
--- otherwise load-bearing.
Interface.REQUIRED_METHODS = {
    "id",
    "display_name",
    "is_available",
    "is_eventually_consistent",
    "push",
    "pull",
    "status",
}


--- Documented error strings for the second argument of push/pull
--- callbacks.  Transports use these so the router and status panel
--- can branch on outcomes deterministically without string-matching
--- free-form messages.
Interface.ERRORS = {
    NOT_AVAILABLE  = "not_available",   -- is_available() returned false
    UNREACHABLE    = "unreachable",     -- network/IO timeout, daemon down
    AUTH_FAILED    = "auth_failed",     -- 401 / 403 / bad credentials
    NOT_CONFIGURED = "not_configured",  -- missing URL, key, username, etc.
    REJECTED       = "rejected",        -- remote returned 4xx (non-auth)
    INTERNAL       = "internal",        -- bug in our code; reported via cb
                                        -- instead of `error()` so a single
                                        -- broken transport doesn't crash the
                                        -- whole save cycle.
}


--- Capability names recognized by the optional `supports(cap)` method.
--- Adding a new capability:  put it here, then have the transport that
--- can do it return true from supports(), and the consumer (router or
--- UI) gate its feature on that.
Interface.CAPABILITIES = {
    IGNORE_PATTERNS    = "ignore_patterns",    -- get/setFolderIgnore
    EVENT_SUBSCRIPTION = "event_subscription", -- push-style state updates
    CONFLICTS_DETAILED = "conflicts_detailed", -- structured conflict records

    -- Periodic-sync control surface.  KOSyncthing+ exposes a "run a
    -- sync every N minutes" timer that companion plugins can read
    -- (is enabled? interval? next-fire-at?) and control (enable, set
    -- interval, run now).  Transports backed by
    -- the plugin advertise this capability; the manual-config Syncthing
    -- transport (REST only) does not.  Cloud has no
    -- equivalent.
    PERIODIC_SYNC      = "periodic_sync",

    -- One-shot Quick Sync trigger.  KOSyncthing+ exposes
    -- `control.quickSync(on_complete)` which runs an immediate
    -- full-scan-then-replicate cycle without altering any timer
    -- schedule.  Companions surface it as a "Sync Now" button.
    -- Manual-config Syncthing has no equivalent (the closest is
    -- POST /rest/db/scan, but that's per-folder and the orchestrator's
    -- own push_book already covers that path).
    QUICK_SYNC         = "quick_sync",

    -- Daemon process control.  KOSyncthing+ exposes
    -- `control.start(cb)` / `control.stop(cb)` (fire-and-forget with a
    -- no-arg completion callback) and `status.isRunning()`.  A
    -- transport advertising this lets the UI offer a power-user
    -- start/stop action for the underlying daemon process.  Only the
    -- KOSyncthing+-backed Syncthing provider advertises it: manual-config
    -- Syncthing is REST-only (no way to launch a process that is not
    -- already running), and Cloud has no daemon at all.
    -- This is the one optional capability whose UI consumer
    -- (`status_panel.lua`) performs a WRITE — every other capability's
    -- consumer only reads.
    DAEMON_CONTROL     = "daemon_control",

    -- Conflict-scanner ignore registry.  KOSyncthing+ exposes
    -- `IgnoreRegistry:register(plugin_id, pattern)` so a companion can
    -- exclude its OWN files from the conflict scanner, keeping the
    -- Conflicts badge/menu accurate.  DISTINCT from IGNORE_PATTERNS:
    -- that writes the daemon's `.stignore` (stops conflict copies from
    -- REPLICATING across devices); this stops Syncery's own conflict
    -- files — which still exist locally — from being COUNTED/LISTED in
    -- KOSyncthing+'s conflict UI.  Only the KOSyncthing+-backed provider
    -- advertises it (manual REST has no scanner; Cloud has no equivalent).
    CONFLICT_IGNORE_REGISTRY = "conflict_ignore_registry",
}


-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------


--- Verify that `implementation` looks like a transport.
---
--- Returns true plus an empty list when the implementation has every
--- required method as a function.  Returns false plus a list of
--- human-readable problem strings otherwise.
---
--- Used by:
---   • the router at registration time (refuses to load a broken transport)
---   • the contract spec (catches the cheap class of bugs first)
---
--- We intentionally do NOT inspect argument arity or return types —
--- Lua makes those expensive to check, and the contract spec exercises
--- them at the behavioural level anyway.
---
---@param implementation any
---@return boolean ok
---@return string[] problems
function Interface.validate_implementation(implementation)
    local problems = {}

    if type(implementation) ~= "table" then
        table.insert(problems, string.format(
            "transport is not a table (got %s)", type(implementation)))
        return false, problems
    end

    for _, method_name in ipairs(Interface.REQUIRED_METHODS) do
        local member = implementation[method_name]
        if type(member) ~= "function" then
            table.insert(problems, string.format(
                "missing required method '%s' (got %s)",
                method_name, type(member)))
        end
    end

    return #problems == 0, problems
end


--- Check whether an error string is one of the documented values.
--- Used by tests that want to fail loudly when a transport invents a
--- new error string instead of using ERRORS.X.
---@param err string|nil
---@return boolean
function Interface.is_documented_error(err)
    if err == nil then return true end
    for _, documented in pairs(Interface.ERRORS) do
        if err == documented then return true end
    end
    return false
end


return Interface
