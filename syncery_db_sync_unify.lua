-- syncery_db_sync_unify.lua
--
-- PURE decision core for Tier 2 (unified cloud config).  Given Syncery's target
-- cloud-server descriptor and a sibling plugin's CURRENT server descriptor,
-- decide what to do to that plugin's server field.  No I/O, no side effects --
-- the caller (main.lua) performs the actual field mutation and `.sync` removal.
--
-- A descriptor is a KOReader cloudstorage server table (the picker's output);
-- its routing identity is { type, url, address } -- the same fields
-- Settings.describe_cloud_server / is_cloud_configured key off.  FTP cannot
-- drive this DB sync (it has no upload method -- design §8), so an FTP target is
-- refused rather than written uselessly.
--
-- decide(target, current) ->
--   { action = "skip",  reason = "no_target" }        -- Syncery has no usable cloud server
--   { action = "skip",  reason = "ftp_unsupported" }  -- target is FTP (cannot sync)
--   { action = "skip",  reason = "already" }          -- plugin already points at target
--   { action = "write", drop_sync = <bool> }          -- write target; drop `.sync` iff a
--                                                       --   DIFFERENT server was there before

local Unify = {}

-- Two descriptors route to the same server iff type/url/address all match.
local function same_server(a, b)
    if a == nil or b == nil then return false end
    return a.type == b.type and a.url == b.url and a.address == b.address
end
Unify.same_server = same_server

-- A target is usable iff it is a table with a destination (url or address).
-- Mirrors Settings.is_cloud_configured's url-or-address test.
local function target_configured(t)
    return type(t) == "table" and (t.url ~= nil or t.address ~= nil)
end

function Unify.decide(target, current)
    if not target_configured(target) then
        return { action = "skip", reason = "no_target" }
    end
    if target.type == "ftp" then
        return { action = "skip", reason = "ftp_unsupported" }
    end
    if same_server(target, current) then
        return { action = "skip", reason = "already" }
    end
    -- Different (or absent) current server -> write.  Drop the stale `.sync`
    -- ONLY when a DIFFERENT server was there before (current ~= nil); a plugin
    -- with no prior server has no `.sync` ancestor to clear.
    return { action = "write", drop_sync = current ~= nil }
end

return Unify
