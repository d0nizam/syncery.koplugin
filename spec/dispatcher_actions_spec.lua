-- =============================================================================
-- spec/dispatcher_actions_spec.lua
-- =============================================================================
--
-- Phase 14.5 — dispatcher actions / gesture discoverability.
--
-- This is a STATIC audit of main.lua (which can't be loaded headless), and it
-- is deliberately data-driven rather than a hard-coded list: it parses every
-- Dispatcher:registerAction(...) and every Syncery:onSyncery<X> handler, then
-- enforces the invariant that they line up BOTH ways:
--   * every registered action's `event = "Syncery<X>"` has a matching
--     `Syncery:onSyncery<X>` handler (so no gesture fires into the void), and
--   * every onSyncery<X> handler is reachable by a registered action (so no
--     user-facing action is menu-only by accident — the exact gap Phase 12.3
--     found for rescan and Phase 14.5 found for the status panel).
--
-- Because it discovers the sets from source, a future handler added without an
-- action (or vice versa) fails this spec automatically, without anyone having
-- to update a list here.
-- =============================================================================


local h = require("spec.test_helpers")

local function slurp(path)
    local f = io.open(path, "r") or io.open("../" .. path, "r")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return s
end

local src = slurp("main.lua")
h.assert_true(src ~= nil, "audit: could open main.lua")
src = src or ""


-- --- collect registered actions: id + event --------------------------------
-- A registerAction block looks like:
--   Dispatcher:registerAction("syncery_now", {
--       category = "none", event = "SynceryNow", ...
--   })
local actions = {}   -- id -> event
for id in src:gmatch('registerAction%("([%w_]+)"') do
    actions[id] = false   -- event filled in below if we can pair it
end

-- Pair each action id with the event that follows it. We scan the text in
-- order: every registerAction("id" ... is followed (before the next one) by
-- an event = "X".
do
    local order = {}
    for id, rest in src:gmatch('registerAction%("([%w_]+)"(.-)%)') do
        local event = rest:match('event%s*=%s*"([%w_]+)"')
        actions[id] = event or false
        order[#order + 1] = id
    end
    h.assert_true(#order >= 4,
        "audit: at least the four known actions are registered (found " .. #order .. ")")
end


-- --- collect event handlers --------------------------------------------------
local handlers = {}   -- "Syncery<X>" event name -> true
for name in src:gmatch("function%s+Syncery:on(Syncery[%w]+)%s*%(") do
    handlers[name] = true
end


-- --- invariant 1: every registered action resolves to a handler --------------
local action_count, handler_count = 0, 0
for id, event in pairs(actions) do
    action_count = action_count + 1
    h.assert_true(type(event) == "string" and event ~= "",
        "action '" .. id .. "' declares an event")
    if type(event) == "string" then
        h.assert_true(handlers[event] == true,
            "action '" .. id .. "' (event " .. tostring(event) ..
            ") has a matching Syncery:on" .. tostring(event) .. " handler")
    end
end


-- --- invariant 2: every handler is reachable by some registered action -------
-- Build the set of events that ARE registered.
local registered_events = {}
for _id, event in pairs(actions) do
    if type(event) == "string" then registered_events[event] = true end
end
for event in pairs(handlers) do
    handler_count = handler_count + 1
    h.assert_true(registered_events[event] == true,
        "handler Syncery:on" .. event .. " is reachable by a registered dispatcher action " ..
        "(no menu-only action left unbindable)")
end


-- --- the two specific gaps that prompted this work ---------------------------
h.assert_true(actions["syncery_rescan"] == "SynceryRescanAll",
    "Phase 12.3 gap closed: rescan-all is a bindable action")
h.assert_true(actions["syncery_show_status"] == "SynceryShowStatus",
    "Phase 14.5 gap closed: show-status is a bindable action")


-- --- counts line up ----------------------------------------------------------
h.assert_equal(action_count, handler_count,
    "audit: exactly as many registered actions as handlers (" ..
    action_count .. " vs " .. handler_count .. ")")
