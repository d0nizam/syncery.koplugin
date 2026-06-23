-- =============================================================================
-- syncery_transports/cloud/reachability.lua
-- =============================================================================
--
-- Is the configured cloud server actually reachable RIGHT NOW?
--
-- WHY THIS EXISTS
--
-- KOReader's cloud sync (`Cloud:sync` / `SyncService.sync`) runs the WebDAV/
-- Dropbox transfer SYNCHRONOUSLY on the UI thread (inside a `nextTick`),
-- bounded only by socketutil's per-op timeouts (FILE_BLOCK 15s / FILE_TOTAL
-- 60s, once for download and once for upload) and NOT bounded for DNS
-- resolution.  The gate in front of it checks only the LINK, not real
-- reachability: KOReader's `WebDav.run` uses `NetworkMgr:willRerunWhenConnected`
-- (== `isConnected`, "associated to wifi"), and Syncery's own
-- `_isNetworkOnline` is `NetworkMgr:isConnected` too.  So when the device is
-- associated but the cloud is unreachable -- no real internet (power outage,
-- captive portal, no route), or the WebDAV server itself down -- the link gate
-- passes and the synchronous transfer freezes the UI for up to ~2 minutes.
-- (Syncthing is immune: it talks to localhost, where a dead daemon refuses the
-- connection instantly, and its http_client sets tight timeouts.)
--
-- This module answers "reachable now?" in two cheap, bounded checks so the
-- caller can DEFER (via wifi_backoff) instead of dispatching a doomed,
-- UI-freezing transfer:
--
--   A. Real internet?  `is_online()` == `NetworkMgr:isOnline` ==
--      `canResolveHostnames` -- a real DNS probe, the SAME check KOReader's
--      Dropbox path already gates on (`willRerunWhenOnline`).  Catches the
--      "no internet" case on every platform, including Android.
--
--   B. THIS server reachable?  A bounded TCP connect-then-close to the
--      server's host:port.  Catches "internet up but the server is down".
--      Run only AFTER A, so general DNS is known to work -- which bounds B's
--      own host resolution: it cannot hang on DNS that A just proved working.
--
-- PURE + INJECTED (the http_client pattern)
--
-- All I/O is injected so the logic is unit-testable with no network:
--   opts.is_online      function() -> boolean                 (REQUIRED)
--   opts.resolve        function(host) -> ip|nil              (socket.dns.toip)
--   opts.connect        function(ip, port, timeout) -> boolean
--   opts.probe_timeout  number, seconds (default 2)
--
-- FAIL-OPEN where we genuinely cannot tell.  An unknown/unparseable server
-- type, or missing probe I/O, returns reachable=true: we will not BLOCK a
-- sync just because we could not build a probe.  A wrong "unreachable" would
-- strand a sync the user wants, and KOReader's own link gate is still in
-- front; a doomed transfer that slips through is bounded by socketutil.  The
-- production wiring also fails open when NetworkMgr is absent (desktop /
-- headless), exactly like `_isNetworkOnline`.
--
-- =============================================================================


local Reachability = {}


-- The Dropbox server object stores no host (server.address holds the app
-- key/token), so a probe targets the well-known content endpoint.  Dropbox
-- already gates on `isOnline` in KOReader, so B is mostly a consistency net
-- for it -- but probing it keeps every backend on the same path.
local DROPBOX_PROBE_HOST = "content.dropboxapi.com"
local DROPBOX_PROBE_PORT = 443

local DEFAULT_PROBE_TIMEOUT = 2


--- Derive the host:port to probe for a configured cloud server.
--- Returns nil when the server type is unknown or its address cannot be
--- parsed (the caller treats nil as "cannot probe" -> fail-open).
--- @param server table|nil   the syncery_cloud_server object
--- @return string|nil host
--- @return number|nil  port
function Reachability.host_port_for(server)
    if type(server) ~= "table" or type(server.type) ~= "string" then
        return nil
    end

    if server.type == "dropbox" then
        return DROPBOX_PROBE_HOST, DROPBOX_PROBE_PORT
    end

    if server.type == "webdav" then
        -- server.address is the base URL: http(s)://host[:port]/path
        local addr = server.address
        if type(addr) ~= "string" then return nil end
        -- IPv6 literals (http://[::1]:port/) don't parse with the host class
        -- below; fail-open rather than probe a garbage host.
        if addr:match("^https?://%[") then return nil end
        local scheme, host, port_str = addr:match("^(https?)://([^/:]+):?(%d*)")
        if not host or host == "" then return nil end
        local port = tonumber(port_str)
        if not port then port = (scheme == "https") and 443 or 80 end
        return host, port
    end

    if server.type == "ftp" then
        local addr = server.address
        if type(addr) ~= "string" then return nil end
        if addr:match("^ftp://%[") then return nil end
        local host, port_str = addr:match("^ftp://([^/:]+):?(%d*)")
        if not host or host == "" then
            -- Some FTP configs store a bare host with no scheme.
            host, port_str = addr:match("^([^/:]+):?(%d*)")
        end
        if not host or host == "" or host:sub(1, 1) == "[" then return nil end
        local port = tonumber(port_str) or 21
        return host, port
    end

    return nil   -- unknown type: fail-open
end


--- Is the configured cloud server reachable right now?
--- @param server table|nil
--- @param opts table  { is_online, resolve, connect, probe_timeout }
--- @return boolean
function Reachability.check(server, opts)
    opts = opts or {}
    local is_online = opts.is_online
    assert(type(is_online) == "function",
        "Reachability.check: is_online function required")

    -- A. Real internet?  No internet -> defer; never reach the blocking
    -- transfer.  Returning here BEFORE touching resolve/connect is what keeps
    -- B's own DNS bounded (it only runs once A proved DNS works).
    if not is_online() then
        return false
    end

    -- B. This specific server reachable?
    local host, port = Reachability.host_port_for(server)
    if not host then
        -- Cannot build a probe for this server type -> don't block
        -- (fail-open).  A already confirmed internet; KOReader's link gate is
        -- still ahead.
        return true
    end

    local resolve = opts.resolve
    local connect = opts.connect
    if type(resolve) ~= "function" or type(connect) ~= "function" then
        -- No probe I/O available (e.g. headless) -> fail-open after A.
        return true
    end

    local ip = resolve(host)         -- DNS works (A passed) -> fast
    if not ip then
        return false                 -- cannot resolve THIS host -> unreachable
    end

    local ok = connect(ip, port, opts.probe_timeout or DEFAULT_PROBE_TIMEOUT)
    return ok and true or false
end


Reachability.DEFAULT_PROBE_TIMEOUT = DEFAULT_PROBE_TIMEOUT
Reachability.DROPBOX_PROBE_HOST    = DROPBOX_PROBE_HOST
Reachability.DROPBOX_PROBE_PORT    = DROPBOX_PROBE_PORT


return Reachability
