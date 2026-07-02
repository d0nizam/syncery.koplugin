-- =============================================================================
-- syncery_ui/status_section.lua
-- =============================================================================
--
-- The status badge + smart-header text — a free module in `syncery_ui/`,
-- alongside the `menu/` package.
--
-- The badge is a pure projection of transport state into a short
-- string.  As a free module (rather than a method on the plugin
-- object) it can be unit-tested directly and the menu reads it without
-- a plugin-method round-trip — no UI string-formatting logic on the
-- plugin, no call back into a plugin method.
--
-- The badge reads per-transport health from `_transport:get_status()`
-- exclusively — `available` + `orch_last_error_class` +
-- `orch_any_pending_retry`.  It does NOT read separately-set plugin
-- fields (per-push result flags written after each push attempt), which
-- could drift from reality the way a snapshot read straight from the
-- transport cannot.
--
-- The Syncthing badge reports configured-state only — not a "synced
-- N min ago" / "Syncthing unreachable" display.  For folder-drop
-- Syncthing, peer propagation is asynchronous and unobservable here,
-- so a "synced N min ago" would over-claim a completion the plugin
-- can't see.  Actionable faults surface via the header's `⚠` path.
--
-- `compose_badge(plugin)` is the public entry the menu's smart header
-- calls.
--
-- SINGLE-SOURCE HEADER LOGIC
--
-- `get_status_header` and `header_needs_action` are derived from ONE
-- string.  `header_needs_action(plugin)` does not re-run the priority
-- logic — it inspects the header string for the `⚠` prefix.  The two
-- functions therefore CANNOT get out of sync (the bug class where a
-- header says "⚠ ..." but `needs_action` returns false because the
-- two computed the priority slightly differently).  This is the
-- pattern the KOSyncthing+ plugin uses for the same problem; it is
-- imported here deliberately.
--
-- SNAPSHOT DISCIPLINE
--
-- This module never calls `_transport:get_status()` itself.  It takes
-- the already-captured snapshot from `menu/_helpers.lua`'s
-- `status_snapshot(plugin)` — the shared snapshot cache.  Both this module
-- and `menu/status_section.lua` share that one snapshot per render;
-- they do not each issue their own transport query.
--
-- =============================================================================


local I18n     = require("syncery_i18n")
local Settings = require("syncery_settings")
local H        = require("syncery_ui/menu/_helpers")

local _ = I18n.translate


local S = {}


-- Configuration-needed marker used by the orchestrator.  Pulled from
-- the policy module so a future rename can't drift these strings;
-- tolerate the require failing in test fakes.
local CLASS_CONFIG_NEEDED = (function()
    local ok, policy = pcall(require, "syncery_transports/policy")
    if ok and policy and policy.CLASSES and policy.CLASSES.CONFIG_NEEDED then
        return policy.CLASSES.CONFIG_NEEDED
    end
    return "config_needed"
end)()


-- ============================================================================
-- 1. compose_badge — the short status badge (replaces _statusBadge)
-- ============================================================================


--- Build the short auxiliary-transport badge fragment.  Used when
--- Syncthing is OFF — composes a "cloud: idle"-style
--- string from whatever non-Syncthing transports are enabled.
---
--- Reads ONLY the snapshot (transport status) and `Settings.is_*_
--- configured()`.  It reads the snapshot's `available` +
--- `orch_last_error_class` + `orch_any_pending_retry` (not any
--- separately-set per-push flags):
---   not configured  → "<t>: not set"
---   error class set → "<t>: …"   (a push failed, retry pending/over)
---   pending retry   → "<t>: …"   (a push is mid-retry)
---   available, idle → "<t>: idle"
---   otherwise       → "<t>: ok"
local function compose_aux_badge(plugin, snapshot)
    local parts = {}

    local function aux(toggle, id, configured, label)
        if not toggle then return end
        local s = snapshot[id]
        -- A server is picked but NO cloud backend can dispatch it (neither
        -- "Cloud storage+" nor the built-in syncservice).  Distinct from — and
        -- takes precedence over — "unsupported": the fix is to enable a backend,
        -- not to re-pick the destination.
        if s and s.backend_unavailable then
            table.insert(parts, string.format(_("%s: no backend"), label))
        -- A picked-but-unsupported provider (e.g. FTP, which SyncService
        -- can't sync) reads as configured() but is NOT available. Without
        -- this branch it would fall through to "idle" and look fine, which
        -- is exactly the silent no-op F1 closes. Show it distinctly.
        elseif s and s.unsupported_provider then
            table.insert(parts, string.format(_("%s: unsupported provider"), label))
        elseif not configured then
            table.insert(parts, string.format(_("%s: not set"), label))
        elseif s and (s.orch_last_error_class or s.orch_any_pending_retry) then
            table.insert(parts, string.format(_("%s: …"), label))
        elseif s and s.available then
            table.insert(parts, string.format(_("%s: ok"), label))
        else
            table.insert(parts, string.format(_("%s: idle"), label))
        end
    end

    aux(plugin.use_cloud,  "cloud",
        Settings.is_cloud_configured(),  _("cloud"))

    return table.concat(parts, " · ")
end


--- Compose the single short badge.  Priority when several transports
--- are on: Syncthing wins (richest data), then the auxiliary badge.
--- The "no sync" badge means no transport is enabled at all.
---
--- This is the function the menu's `addToMainMenu` text_func and the
--- smart header call.
function S.compose_badge(plugin)
    local snapshot = H.status_snapshot(plugin)

    if not plugin.use_syncthing and not plugin.use_cloud then
        return _("no sync")
    end

    -- Syncthing off → auxiliary-transport badge.
    if not plugin.use_syncthing then
        return compose_aux_badge(plugin, snapshot)
    end

    -- Syncthing on.  The badge reports configured-state, not sync-
    -- completion: with folder-drop Syncthing a push is a scan nudge and
    -- propagation to the peer is asynchronous and unobservable here, so
    -- there is no honest "synced N min ago" to show.  Availability (was
    -- `get_syncthing_api_key() == ""`) splits "idle" from "not
    -- configured"; actionable faults surface via the header's `⚠` path.
    --
    -- The pending-retry suffix " …" is read from the orchestrator-
    -- decorated `orch_any_pending_retry` flag.
    local st = snapshot.syncthing
    local retry_suffix = (st and st.orch_any_pending_retry) and " …" or ""

    if st and st.available then
        return _("idle") .. retry_suffix
    end
    return _("not configured")
end


-- ============================================================================
-- 2. get_status_header — the smart-header line
-- ============================================================================


--- Pick the highest-priority actionable problem in the snapshot.
--- Returns (transport_id, kind) where kind is "config_needed" or
--- "auth_failed", or nil if no actionable problem exists.
---
--- Order: syncthing → cloud (Syncthing carries the richest
--- payload; the order is not user-visible but matters when several
--- transports have problems and one must be surfaced).
local function find_actionable_problem(plugin, snapshot)
    local order = { "syncthing", "cloud" }
    local toggle_for = {
        syncthing = plugin.use_syncthing,
        cloud     = plugin.use_cloud,
    }
    for __, id in ipairs(order) do
        local s = snapshot[id]
        if s and toggle_for[id] then
            if s.orch_last_error_class == CLASS_CONFIG_NEEDED then
                return id, "config_needed"
            end
            if not s.available then
                return id, "config_needed"
            end
            if s.orch_last_error_class == "auth_failed" then
                return id, "auth_failed"
            end
        end
    end
    return nil, nil
end


--- Public: the actionable problem the smart header is reporting, if
--- any.  Returns (transport_id, kind) — e.g. ("cloud", "config_needed")
--- or ("syncthing", "auth_failed") — or (nil, nil) when nothing needs
--- action.  Reads the SAME snapshot as `get_status_header`, so the
--- "tap to resolve" target and the displayed `⚠` problem can never
--- point at different transports.
function S.actionable_problem(plugin)
    local snapshot = H.status_snapshot(plugin)
    return find_actionable_problem(plugin, snapshot)
end


--- The plain-text status header.  Starts with `⚠ ` exactly when
--- there is an actionable problem; anything else is informational.
---
--- Priority:
---   1. No transports enabled  → the "no sync" badge.
---   2. Actionable problem     → `⚠ <transport> needs setup` /
---                               `⚠ <transport> authentication failed`.
---   3. Mid-retry              → `Retrying <transport>…` (informational).
---   4. Otherwise              → `compose_badge` ("synced N min ago" etc).
function S.get_status_header(plugin)
    local snapshot = H.status_snapshot(plugin)

    if not plugin.use_syncthing and not plugin.use_cloud then
        return S.compose_badge(plugin)
    end

    local problem_id, problem_kind = find_actionable_problem(plugin, snapshot)
    if problem_id then
        local display = (snapshot[problem_id] and snapshot[problem_id].display_name)
                        or problem_id
        if problem_kind == "auth_failed" then
            return string.format(_("⚠ %s authentication failed"), display)
        end
        return string.format(_("⚠ %s needs setup"), display)
    end

    for __, id in ipairs({ "syncthing", "cloud" }) do
        local s = snapshot[id]
        if s and s.orch_any_pending_retry then
            return string.format(_("Retrying %s…"), s.display_name or id)
        end
    end

    return S.compose_badge(plugin)
end


--- Whether the header reports an actionable problem.
---
--- DERIVED FROM THE HEADER STRING.  This does NOT re-run the priority
--- logic in `find_actionable_problem` — it inspects the result of
--- `get_status_header` for the `⚠` prefix.  Consequence: the header
--- text and this boolean cannot disagree.  If `get_status_header`
--- ever returns a `⚠`-prefixed string, this returns true; otherwise
--- false.  (Pattern imported from KOSyncthing+'s
--- `headerNeedsAction`.)
function S.header_needs_action(plugin)
    local header = S.get_status_header(plugin)
    return type(header) == "string" and header:sub(1, #"⚠") == "⚠"
end


return S
