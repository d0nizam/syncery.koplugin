-- =============================================================================
-- spec/reachability_spec.lua
-- =============================================================================
--
-- Tests for syncery_transports/cloud/reachability.lua.
--
-- The module's whole value is that it answers "reachable now?" with cheap,
-- bounded, INJECTED I/O, so the cloud-upload path can defer instead of
-- dispatching a UI-freezing synchronous transfer.  These tests drive it with
-- pure stubs (no socket, no NetworkMgr) and assert:
--   * host:port extraction per server type (webdav / dropbox / ftp / junk);
--   * the A-before-B ordering -- when offline, resolve/connect are NEVER
--     touched (this is what bounds B's DNS: it only runs once A proves DNS);
--   * fail-open where we cannot build a probe;
--   * the probe timeout is threaded through to connect.
--
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_reachability_spec_" .. tostring(os.time()))

local Reachability = require("syncery_transports/cloud/reachability")


-- ----------------------------------------------------------------------------
-- host_port_for
-- ----------------------------------------------------------------------------

do
    -- WebDAV: https defaults to 443.
    local host, port = Reachability.host_port_for(
        { type = "webdav", address = "https://example.com/dav" })
    h.assert_equal(host, "example.com", "webdav https host")
    h.assert_equal(port, 443, "webdav https default port")

    -- WebDAV: http defaults to 80.
    host, port = Reachability.host_port_for(
        { type = "webdav", address = "http://example.com/remote.php/dav" })
    h.assert_equal(host, "example.com", "webdav http host")
    h.assert_equal(port, 80, "webdav http default port")

    -- WebDAV: explicit port wins over scheme default.
    host, port = Reachability.host_port_for(
        { type = "webdav", address = "https://nas.local:8443/dav/files" })
    h.assert_equal(host, "nas.local", "webdav explicit-port host")
    h.assert_equal(port, 8443, "webdav explicit port")

    -- WebDAV: IPv4 literal with port.
    host, port = Reachability.host_port_for(
        { type = "webdav", address = "http://192.168.1.5:8080/dav" })
    h.assert_equal(host, "192.168.1.5", "webdav ip-literal host")
    h.assert_equal(port, 8080, "webdav ip-literal port")

    -- Dropbox: fixed well-known endpoint regardless of the address field.
    host, port = Reachability.host_port_for(
        { type = "dropbox", address = "some-app-token", url = "/books" })
    h.assert_equal(host, Reachability.DROPBOX_PROBE_HOST, "dropbox fixed host")
    h.assert_equal(port, 443, "dropbox fixed port")

    -- FTP: scheme form, default port 21.
    host, port = Reachability.host_port_for(
        { type = "ftp", address = "ftp://ftp.example.com/pub" })
    h.assert_equal(host, "ftp.example.com", "ftp host")
    h.assert_equal(port, 21, "ftp default port")

    -- FTP: explicit port.
    host, port = Reachability.host_port_for(
        { type = "ftp", address = "ftp://ftp.example.com:2121/pub" })
    h.assert_equal(port, 2121, "ftp explicit port")

    -- FTP: bare host, no scheme.
    host, port = Reachability.host_port_for(
        { type = "ftp", address = "ftp.example.com" })
    h.assert_equal(host, "ftp.example.com", "ftp bare host")
    h.assert_equal(port, 21, "ftp bare-host default port")
end

do
    -- Fail-open shapes -> nil (caller will not block on these).
    h.assert_nil(Reachability.host_port_for(nil), "nil server -> nil")
    h.assert_nil(Reachability.host_port_for({}), "no type -> nil")
    h.assert_nil(Reachability.host_port_for({ type = "mega" }), "unknown type -> nil")
    h.assert_nil(Reachability.host_port_for({ type = "webdav" }),
        "webdav missing address -> nil")
    h.assert_nil(Reachability.host_port_for({ type = "webdav", address = 42 }),
        "webdav non-string address -> nil")
    h.assert_nil(Reachability.host_port_for({ type = "webdav", address = "not-a-url" }),
        "webdav unparseable address -> nil")
    h.assert_nil(Reachability.host_port_for(
        { type = "webdav", address = "https://[::1]:8443/dav" }),
        "webdav IPv6 literal -> nil (fail-open)")
end


-- ----------------------------------------------------------------------------
-- check -- A-before-B ordering is the load-bearing property
-- ----------------------------------------------------------------------------

-- A spy that records whether it was called and the args it saw.
local function make_spy(return_value)
    local rec = { called = false, args = nil }
    rec.fn = function(...)
        rec.called = true
        rec.args = { ... }
        return return_value
    end
    return rec
end

local WEBDAV = { type = "webdav", address = "https://example.com/dav" }

do
    -- A fails (offline): result is false AND neither resolve nor connect runs.
    -- This is what keeps B's DNS bounded -- it never fires when A says offline.
    local resolve = make_spy("1.2.3.4")
    local connect = make_spy(true)
    local reachable = Reachability.check(WEBDAV, {
        is_online = function() return false end,
        resolve   = resolve.fn,
        connect   = connect.fn,
    })
    h.assert_false(reachable, "offline -> not reachable")
    h.assert_false(resolve.called, "offline -> resolve NOT called")
    h.assert_false(connect.called, "offline -> connect NOT called")
end

do
    -- A passes, server type has no probe (unknown) -> fail-open (true),
    -- without touching resolve/connect.
    local resolve = make_spy("1.2.3.4")
    local connect = make_spy(true)
    local reachable = Reachability.check({ type = "mega" }, {
        is_online = function() return true end,
        resolve   = resolve.fn,
        connect   = connect.fn,
    })
    h.assert_true(reachable, "online + unprobeable type -> fail-open true")
    h.assert_false(resolve.called, "fail-open -> resolve NOT called")
end

do
    -- A passes, DNS resolves, TCP connect succeeds -> reachable.
    local resolve = make_spy("93.184.216.34")
    local connect = make_spy(true)
    local reachable = Reachability.check(WEBDAV, {
        is_online     = function() return true end,
        resolve       = resolve.fn,
        connect       = connect.fn,
        probe_timeout = 2,
    })
    h.assert_true(reachable, "online + resolves + connects -> reachable")
    h.assert_true(resolve.called, "online -> resolve called")
    h.assert_equal(resolve.args[1], "example.com", "resolve got the webdav host")
    h.assert_true(connect.called, "resolves -> connect called")
    h.assert_equal(connect.args[1], "93.184.216.34", "connect got the resolved ip")
    h.assert_equal(connect.args[2], 443, "connect got the webdav https port")
    h.assert_equal(connect.args[3], 2, "connect got the probe timeout")
end

do
    -- A passes, host does NOT resolve -> unreachable, connect not attempted.
    local resolve = make_spy(nil)
    local connect = make_spy(true)
    local reachable = Reachability.check(WEBDAV, {
        is_online = function() return true end,
        resolve   = resolve.fn,
        connect   = connect.fn,
    })
    h.assert_false(reachable, "online + DNS miss -> not reachable")
    h.assert_true(resolve.called, "DNS miss -> resolve called")
    h.assert_false(connect.called, "DNS miss -> connect NOT called")
end

do
    -- A passes, resolves, but TCP connect fails (server down) -> unreachable.
    local resolve = make_spy("93.184.216.34")
    local connect = make_spy(false)
    local reachable = Reachability.check(WEBDAV, {
        is_online = function() return true end,
        resolve   = resolve.fn,
        connect   = connect.fn,
    })
    h.assert_false(reachable, "online + connect-refused -> not reachable")
    h.assert_true(connect.called, "connect attempted")
end

do
    -- Default probe timeout is applied when the caller omits one.
    local seen_timeout
    local reachable = Reachability.check(WEBDAV, {
        is_online = function() return true end,
        resolve   = function() return "1.1.1.1" end,
        connect   = function(_ip, _port, timeout) seen_timeout = timeout; return true end,
    })
    h.assert_true(reachable, "default-timeout path reachable")
    h.assert_equal(seen_timeout, Reachability.DEFAULT_PROBE_TIMEOUT,
        "omitted timeout -> module default (2s)")
end

do
    -- Missing probe I/O (no resolve/connect) -> fail-open after A.
    local reachable = Reachability.check(WEBDAV, {
        is_online = function() return true end,
    })
    h.assert_true(reachable, "online + no probe I/O -> fail-open true")
end

do
    -- is_online is required -- a caller that forgets it is a loud error.
    local ok = pcall(Reachability.check, WEBDAV, {})
    h.assert_false(ok, "check requires is_online")
end


h.report("reachability_spec")
