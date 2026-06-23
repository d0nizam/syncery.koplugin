-- =============================================================================
-- syncery_transports/syncthing/local_url.lua
-- =============================================================================
--
-- Builds the base URL of the Syncthing daemon that backs this device.
--
-- The host is ALWAYS 127.0.0.1: Syncery writes its progress files to the local
-- filesystem, so the daemon that replicates them runs on the SAME device --
-- loopback is the only meaningful target.  (Binding the GUI to 0.0.0.0 still
-- includes loopback, so 127.0.0.1 keeps working there too.)
--
-- The scheme is "http" by default; "https" is auto-detected by the connection
-- test (BasicSync serves the GUI over https) and persisted in Settings.
--
-- The port defaults to 8384 (Syncthing's GUI default) and is overridable in the
-- Advanced settings; values outside 1024-65535 fall back to the default so a
-- corrupt/missing persisted value never yields a malformed URL.
--
-- Pure + dependency-free so both Settings (real backend) and the manual
-- provider (injected settings_reader) can build the same URL, and so the logic
-- is directly unit-testable.
-- =============================================================================

local M = {}

local DEFAULT_PORT = 8384

function M.build(scheme, port)
    local s = (scheme == "https") and "https" or "http"
    local p = tonumber(port)
    if type(p) ~= "number" or p ~= p or p < 1024 or p > 65535 then
        p = DEFAULT_PORT
    end
    return string.format("%s://127.0.0.1:%d", s, math.floor(p))
end

return M
