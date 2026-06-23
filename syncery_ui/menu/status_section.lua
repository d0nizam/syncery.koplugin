-- =============================================================================
-- syncery_ui/menu/status_section.lua
-- =============================================================================
--
-- Smart Header.
--
-- The first row of the Syncery menu is a one-line status summary.
-- It's the user's "what's going on right now" pane.  Three rules
-- govern it:
--
--   1. Reads ONLY cached/cheap data.  No HTTP, no disk scan.  The
--      transport snapshot from `H.status_snapshot` is the source of
--      truth.
--
--   2. When the header signals an actionable problem it acquires the
--      `⚠` prefix and a `— tap to resolve` suffix, and `enabled_func`
--      makes the row tappable.  When everything is fine the row is
--      informative-only AND non-tappable (enabled_func returns false).
--
--   3. Tapping the header (only possible in the actionable case) opens
--      the failing transport's SETUP via `plugin:resolveStatusProblem()`
--      — so "resolve" lands where the problem is fixed.  Everyday access
--      to the device-positions panel is the dedicated "Show device
--      status" row (top-level, door #2), not this header.
--
-- PHASE 6 CHANGE — header logic moved out
--
-- The header-text computation (`get_status_header` /
-- `header_needs_action`) lives in `syncery_ui/status_section.lua`
-- (a free module, no plugin-method round-trip).  This file
-- DELEGATES: `S.get_status_header` / `S.header_needs_action` forward
-- to that module.  The forwards are kept so the menu spec and any
-- caller addressing `menu.sections.status.get_status_header` keep
-- working.
--
-- That module reads the SAME `H.status_snapshot` cache, so the
-- single-query-per-render discipline is preserved — both modules
-- share one snapshot.
--
-- The section ALSO owns the two top-of-menu action rows:
--   - "Sync this book" toggle (per-book switch)
--   - "Sync now" trigger
--
-- These three rows make up the "what's happening right now" cluster
-- at the top of the menu, separated from the rest.
--
-- =============================================================================


local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")

local H            = require("syncery_ui/menu/_helpers")
local StatusModule = require("syncery_ui/status_section")
local _ = H._


local S = {}


-- ============================================================================
-- 1. Header text — delegates to syncery_ui/status_section.lua
-- ============================================================================


--- The plain-text status header.  Delegates to the standalone status
--- module (home of the badge + header logic).
function S.get_status_header(plugin)
    return StatusModule.get_status_header(plugin)
end


--- Whether the header reports an actionable problem.  Delegates to the
--- standalone status module, which derives this from the `⚠` prefix of
--- the header string — so the text and the boolean cannot disagree.
function S.header_needs_action(plugin)
    return StatusModule.header_needs_action(plugin)
end


-- ============================================================================
-- 2. The Smart Header menu row
-- ============================================================================


--- The header itself, as a menu item.  When there's an actionable
--- problem, the row text gets ` — tap to resolve` appended and the
--- row becomes tappable; tapping opens the status detail view (where
--- the user can drill into the failing transport and fix it).
---
--- When everything's fine the row is non-tappable and a tap does
--- nothing: `enabled_func` returns false, and TouchMenuItem:onTapSelect
--- (touchmenu.lua) returns early on a disabled row BEFORE reaching the
--- callback, so a tap on "synced 2 min ago" is swallowed — it does NOT
--- open the status detail.  The callback (`resolveStatusProblem`) is the
--- actionable-case handler: it runs only when there's a problem and the
--- row is enabled.  The always-available view of where devices are is
--- the Progress Browser (which replaced the old status-detail panel).
function S.smart_header(plugin)
    return {
        text_func = function()
            -- Compute the header string ONCE.  The `⚠`-prefix test is
            -- done inline here rather than via S.header_needs_action()
            -- (which would re-run get_status_header) — same single-
            -- source-of-truth derivation, no double computation.
            local header = S.get_status_header(plugin)
            local needs_action =
                type(header) == "string" and header:sub(1, #"⚠") == "⚠"
            local state  = plugin:getCurrentState()
            local pct    = ""
            if state and state.percent then
                pct = string.format(" (%.0f%%)", state.percent * 100)
            end
            if needs_action then
                return header .. _(" — tap to resolve") .. pct
            end
            return header .. pct
        end,
        help_text      = _(
            "Current Syncery status.\n\n"
            .. "When a transport needs setup or hits an error, this row "
            .. "becomes tappable — tap to open that transport's setup and "
            .. "fix it.  Otherwise open the Progress Browser to see where "
            .. "your devices are."),
        keep_menu_open = true,
        -- The row is tappable ONLY when it reports an
        -- actionable problem (the `⚠ … — tap to resolve` case).  When
        -- the status is merely informational ("synced 2 min ago",
        -- "idle", "no sync") the row goes grey and does nothing — the
        -- Progress Browser (top-level) is the always-available way to
        -- see device positions.  Derived from the SAME `⚠`-prefix test
        -- as the label, so the visual state and the tappability cannot
        -- disagree.
        enabled_func   = function() return S.header_needs_action(plugin) end,
        hold_callback  = H.helpHold(_(
            "When a transport needs attention, tap to open its setup and "
            .. "resolve the issue.")),
        callback       = H.safe("Resolve status problem",
            function() plugin:resolveStatusProblem() end),
        separator      = true,
    }
end


-- ============================================================================
-- 3. Per-book "Sync this book" toggle
-- ============================================================================


--- Per-book opt-out.  Stored in the book's doc_settings (not in
--- plugin globals — that's intentional, so the toggle stays with the
--- book even if Syncery is uninstalled and reinstalled).
---
--- Gated (disabled-with-explanation) on having an open document.  Without one,
--- doc_settings can't be read and the toggle has nothing to bind to —
--- so the row goes grey with an explanation on long-press.
function S.sync_this_book_toggle(plugin)
    local has_doc = function()
        return (plugin.ui and plugin.ui.doc_settings ~= nil) and true or false
    end
    return {
        text = _("Sync this book"),
        help_text = _(
            "When enabled, Syncery syncs reading progress and annotations "
            .. "for this book across devices.\n\n"
            .. "Uncheck to exclude this book — useful if you want your "
            .. "reading activity kept to this device only, or for books "
            .. "you are reading temporarily."),
        keep_menu_open = true,
        enabled_func = has_doc,
        checked_func = function()
            if not has_doc() then return false end
            return not (plugin.ui.doc_settings:readSetting("syncery_disabled"))
        end,
        hold_callback = H.gatedHold(has_doc,
            _("No document is open — open a book first to control its "
            .. "sync setting."),
            _("Enable to sync this book's progress and annotations. "
            .. "Disable to exclude it.")),
        callback = function(tmi)
            if not has_doc() then return end
            local current = plugin.ui.doc_settings:readSetting("syncery_disabled") or false
            plugin.ui.doc_settings:saveSetting("syncery_disabled", not current)
            UIManager:show(InfoMessage:new{
                text = current and _("Syncing enabled for this book.")
                                or _("Syncing disabled for this book."),
                timeout = 2,
            })
            if tmi then tmi:updateItems() end
        end,
    }
end


-- ============================================================================
-- 4. "Sync now" action
-- ============================================================================


--- Manual sync trigger.  Dynamic label: when any
--- transport reports `orch_any_pending_retry`, the label changes to
--- `"Syncing…"` to reflect that an attempt is in flight already.
--- Gated on having an open document — `syncNow` operates on the
--- current state.
function S.sync_now(plugin)
    local has_doc = function()
        return (plugin.ui and plugin.ui.doc_settings ~= nil) and true or false
    end
    local in_flight = function()
        local snap = H.status_snapshot(plugin)
        for __, id in ipairs({ "syncthing", "cloud" }) do
            local s = snap[id]
            if s and s.orch_any_pending_retry then return true end
        end
        return false
    end
    return {
        text_func = function()
            if in_flight() then return _("Syncing…") end
            return _("Sync now")
        end,
        help_text = _(
            "Save progress and annotations right now, then trigger a "
            .. "Syncthing folder scan so other devices receive the update "
            .. "immediately.\n\n"
            .. "Syncery saves automatically as you read — use this when "
            .. "you want to push an update without waiting."),
        keep_menu_open = true,
        enabled_func   = has_doc,
        hold_callback  = H.gatedHold(has_doc,
            _("No document is open — open a book first to sync it."),
            _("Tap to save and push now.")),
        callback       = H.safe("Sync now", function()
            if not has_doc() then return end
            plugin:syncNow()
        end),
        -- Last row of the status cluster when a book is open (the smart header
        -- already carries the separator in the no-book case), so it closes the
        -- cluster before the rest of the menu.
        separator      = true,
    }
end


-- ============================================================================
-- 5. Public entry — the cluster as a list of rows
-- ============================================================================


--- Returns the three top rows: smart header, sync-this-book, sync-now.
--- Composed into the top-level menu by `main_menu.lua`.
function S.build(plugin)
    local has_doc = (plugin.ui and plugin.ui.doc_settings ~= nil) and true or false
    -- The smart header always shows (it can report transport setup/errors even
    -- with no book open).  The per-book rows are omitted entirely in the file
    -- browser — hidden, not greyed.
    local rows = { S.smart_header(plugin) }
    if has_doc then
        table.insert(rows, S.sync_this_book_toggle(plugin))
        table.insert(rows, S.sync_now(plugin))
    end
    return rows
end


return S
