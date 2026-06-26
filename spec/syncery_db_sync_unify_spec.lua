-- Spec for syncery_db_sync_unify -- the PURE Tier 2 decision core.
package.path = "./?.lua;" .. package.path
local Unify = require("syncery_db_sync_unify")
local h = require("spec.test_helpers")

local WD  = { type = "webdav",  url = "https://dav.example/remote" }
local WD2 = { type = "webdav",  url = "https://other.example/remote" }
local DBX = { type = "dropbox", address = "/Apps/x" }
local FTP = { type = "ftp",     address = "ftp://h/x" }

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

-- ftp target -> skip / ftp_unsupported
do
    local f = Unify.decide(FTP, nil)
    h.assert_equal(f.action, "skip",            "ftp target -> skip")
    h.assert_equal(f.reason, "ftp_unsupported", "  reason ftp_unsupported")
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

print("syncery_db_sync_unify_spec: all assertions passed")
