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
--   { action = "skip",  reason = "poisoned_target" }  -- Syncery's Dropbox source is not reusable
--   { action = "skip",  reason = "already" }          -- plugin already points at target
--   { action = "write", drop_sync = <bool>, reason? } -- write target; drop `.sync` iff a
--                                                       --   DIFFERENT destination was there before

local Unify = {}

-- Two descriptors route to the same server iff type/url/address all match.
local function same_server(a, b)
    if a == nil or b == nil then return false end
    return a.type == b.type and a.url == b.url and a.address == b.address
end
Unify.same_server = same_server

-- KOReader's Dropbox provider turns a persistent picker descriptor into a
-- short-lived runtime descriptor in-place: username=true marks that password
-- now contains an access token rather than the refresh token.  Statistics and
-- Vocabulary Builder keep their descriptor by reference, so that mutation can
-- otherwise be flushed to settings and fail after the access token expires.
local function poisoned_dropbox(t)
    return type(t) == "table" and t.type == "dropbox" and t.username == true
end
Unify.poisoned_dropbox = poisoned_dropbox

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
    -- Never propagate a legacy-poisoned Syncery descriptor.  Revision 5 keeps
    -- the source pristine going forward, but an installation already affected
    -- by the old mutation must be re-picked once to recover its refresh token.
    if poisoned_dropbox(target) then
        return { action = "skip", reason = "poisoned_target" }
    end
    if same_server(target, current) then
        -- Same destination, but the sibling plugin's copy was consumed by
        -- KOReader's Dropbox provider.  Replace it with Syncery's pristine
        -- refresh-token descriptor before the next DB sync.  Keep `.sync`: the
        -- merge ancestor still belongs to this exact destination.
        if poisoned_dropbox(current) then
            return { action = "write", drop_sync = false, reason = "credential_refresh" }
        end
        return { action = "skip", reason = "already" }
    end
    -- Different (or absent) current server -> write.  Drop the stale `.sync`
    -- ONLY when a DIFFERENT server was there before (current ~= nil); a plugin
    -- with no prior server has no `.sync` ancestor to clear.
    return { action = "write", drop_sync = current ~= nil }
end

return Unify
