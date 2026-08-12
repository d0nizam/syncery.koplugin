-- Spec for syncery_db_sync_unify -- the PURE Tier 2 decision core.
package.path = "./?.lua;" .. package.path
local Unify = require("syncery_db_sync_unify")
local h = require("spec.test_helpers")

local WD  = { type = "webdav",  url = "https://dav.example/remote" }
local WD2 = { type = "webdav",  url = "https://other.example/remote" }
local DBX = {
    type = "dropbox", name = "Dropbox", address = "app-key:app-secret",
    url = "/Apps/x", password = "persistent-refresh-token",
}
local FTP = { type = "ftp",     address = "ftp://h/x" }

local function shallow_copy(source)
    local copy = {}
    for k, v in pairs(source) do copy[k] = v end
    return copy
end

-- no usable target -> skip / no_target
do
    local d = Unify.decide(nil, WD)
    h.assert_equal(d.action, "skip",      "nil target -> skip")
    h.assert_equal(d.reason, "no_target", "  reason no_target")
    h.assert_equal(Unify.decide({}, WD).reason, "no_target",
        "table without url/address -> no_target")
    h.assert_equal(Unify.decide({ type = "webdav" }, WD).reason, "no_target",
        "type but no destination -> no_target")
end

-- A legacy-poisoned Syncery target cannot repair siblings: its refresh token
-- has already been overwritten, so copying it would merely spread the poison.
do
    local poisoned_target = shallow_copy(DBX)
    poisoned_target.username = true
    poisoned_target.password = "expired-access-token"
    local d = Unify.decide(poisoned_target, nil)
    h.assert_equal(d.action, "skip", "poisoned Dropbox target -> skip")
    h.assert_equal(d.reason, "poisoned_target", "  reason poisoned_target")
end

-- ftp target -> skip / ftp_unsupported
do
    local f = Unify.decide(FTP, nil)
    h.assert_equal(f.action, "skip",            "ftp target -> skip")
    h.assert_equal(f.reason, "ftp_unsupported", "  reason ftp_unsupported")
end

-- Dropbox consumes the sibling descriptor in place.  The next decision must
-- restore a pristine refresh-token copy without deleting the same server's
-- three-way-merge ancestor.
do
    local consumed = shallow_copy(DBX)
    consumed.username = true
    consumed.password = "short-lived-access-token"
    local d = Unify.decide(DBX, consumed)
    h.assert_equal(d.action, "write", "consumed Dropbox credentials -> refresh")
    h.assert_equal(d.reason, "credential_refresh", "  reason credential_refresh")
    h.assert_equal(d.drop_sync, false, "  same destination keeps .sync")
    h.assert_true(Unify.poisoned_dropbox(consumed), "  consumed descriptor detected")
    h.assert_true(not Unify.poisoned_dropbox(DBX), "  pristine descriptor not poisoned")

    -- Model two consecutive KOReader syncs: after each in-place access-token
    -- mutation, applying the decision restores the persistent refresh token.
    local current = shallow_copy(consumed)
    for round = 1, 2 do
        local decision = Unify.decide(DBX, current)
        h.assert_equal(decision.action, "write", "  round " .. round .. " repairs before sync")
        current = shallow_copy(DBX)
        h.assert_equal(current.password, "persistent-refresh-token",
            "  round " .. round .. " restores refresh token")
        h.assert_equal(current.username, nil,
            "  round " .. round .. " clears runtime marker")
        current.username = true
        current.password = "access-token-" .. round
    end
end

-- plugin already points at the target -> skip / already
do
    local s = Unify.decide(WD, { type = "webdav", url = "https://dav.example/remote" })
    h.assert_equal(s.action, "skip",    "same server -> skip")
    h.assert_equal(s.reason, "already", "  reason already")
end

-- fresh plugin (no current server) -> write, NO `.sync` drop
do
    local w = Unify.decide(WD, nil)
    h.assert_equal(w.action, "write", "fresh plugin -> write")
    h.assert_equal(w.drop_sync, false, "  no stale .sync to drop")
end

-- different current server (same type) -> write + drop `.sync`
do
    local w = Unify.decide(WD, WD2)
    h.assert_equal(w.action, "write", "different url -> write")
    h.assert_equal(w.drop_sync, true, "  drop the stale .sync")
end

-- different TYPE (webdav target, dropbox current) -> write + drop
do
    local w = Unify.decide(WD, DBX)
    h.assert_equal(w.action, "write", "type change -> write")
    h.assert_true(w.drop_sync,        "  drop the stale .sync")
end

-- same_server helper directly
do
    h.assert_true(Unify.same_server(WD, { type = "webdav", url = "https://dav.example/remote" }),
        "same_server: identical")
    h.assert_true(not Unify.same_server(WD, WD2),  "same_server: different url")
    h.assert_true(not Unify.same_server(WD, nil),  "same_server: nil")
    h.assert_true(not Unify.same_server(WD, DBX),  "same_server: different type")
end

-- main.lua is too coupled to KOReader UI classes for this pure suite to load,
-- so lock the integration invariant statically: every built-in DB-sync trigger
-- enters the same helper, and that helper unifies before dispatching events.
do
    local file = io.open("main.lua", "r") or io.open("../main.lua", "r")
    h.assert_true(file ~= nil, "wiring audit: main.lua is readable")
    local source = file:read("*a")
    file:close()

    local body = source:match("function Syncery:_runDbSync%b()%s*(.-)%s*end") or ""
    local prepare_at = body:find("self:_unifyDbSyncConfig()", 1, true)
    local dispatch_at = body:find("return DbSync.run", 1, true)
    h.assert_true(prepare_at ~= nil and dispatch_at ~= nil and prepare_at < dispatch_at,
        "wiring audit: DB config is repaired before event dispatch")
    h.assert_true(source:find("inst:_runDbSync(active_ui)", 1, true) ~= nil,
        "wiring audit: periodic tick uses the shared entry point")
    h.assert_true(source:find("pcall(self._runDbSync, self, self.ui)", 1, true) ~= nil,
        "wiring audit: manual Sync now uses the shared entry point")
end

print("syncery_db_sync_unify_spec: all assertions passed")
