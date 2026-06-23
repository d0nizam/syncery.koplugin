-- =============================================================================
-- syncery_transports/cloud/providers/syncservice_provider.lua
-- =============================================================================
--
-- The "Cloud storage" (built-in) provider: KOReader's built-in
-- `apps/cloudstorage/syncservice` (provider id "syncservice").  This is
-- the long-standing path Syncery has always used; today it is the
-- FALLBACK behind the "Cloud storage+" plugin provider.  This file does
-- not change its behaviour, it only wraps it behind the provider
-- interface so the Cloud transport can treat it as one of several
-- selectable backends.
--
-- Backend dispatch is delegated to the existing SyncServiceAdapter,
-- which calls `SyncService.sync(server, path, merge_cb, is_silent)`.
-- The merge callbacks are built elsewhere (by the transport, via
-- SyncServiceAdapter.make_*_callback) and handed to `sync()` — this
-- provider never builds them, so the two providers cannot diverge on
-- merge semantics.
--
-- SYNCABLE PROVIDERS
--
-- The built-in SyncService accepts only Dropbox and WebDAV (it rejects
-- anything else, including FTP, with "Wrong server type" — the cloud
-- browser also lists FTP, but syncservice cannot sync it).  So this
-- provider's syncable set is exactly { dropbox, webdav }.
--
-- AVAILABILITY
--
-- Available iff `apps/cloudstorage/syncservice` can be require()d.  In
-- tests an explicit `sync_service` may be injected so the (not always
-- loadable) built-in module isn't pulled in.
--
-- =============================================================================


local Interface = require("syncery_transports/cloud/providers/interface")
local SyncServiceAdapter = require("syncery_transports/cloud/sync_service_adapter")
local TransportInterface  = require("syncery_transports/interface")
local QuietToast         = require("syncery_transports/cloud/quiet_toast")
local Log = require("syncery_transports/log")
local log = Log.tag("cloud.provider.syncservice")


local Provider = {}


local PROVIDER_ID = "syncservice"

-- Seconds to swallow SyncService's "Successfully synchronized." toast around a
-- sync (see quiet_toast.lua).  Matches the cloudstorage provider's window.
local QUIET_GRACE_S = 60

-- The provider types the built-in SyncService can actually sync.
local SYNCABLE = { dropbox = true, webdav = true }


--- Lazy resolver for the built-in SyncService module.  Mirrors the
--- adapter's own resolver: pcall(require) so a test/headless context
--- that can't load it doesn't crash at module load — is_available()
--- simply reports false there.
local _resolved = nil
local function resolve_sync_service(injected)
    if injected ~= nil then return injected end
    if _resolved ~= nil then return _resolved end
    local ok, svc = pcall(require, "apps/cloudstorage/syncservice")
    if ok and type(svc) == "table" and type(svc.sync) == "function" then
        _resolved = svc
        return svc
    end
    return nil
end


--- Construct the built-in "Cloud storage" (syncservice) provider.
---@param opts table|nil
---   .sync_service  — optional injected SyncService module (tests).  When
---                    omitted, resolved lazily via require.
---@return table provider
function Provider.new(opts)
    opts = opts or {}
    local injected = opts.sync_service

    local p = {}

    function p.id() return PROVIDER_ID end

    function p.display_name() return "Cloud storage (Dropbox / WebDAV)" end

    function p.is_available()
        return resolve_sync_service(injected) ~= nil
    end

    function p.syncable_providers()
        -- Return a fresh copy so callers can't mutate our table.
        return { dropbox = true, webdav = true }
    end

    --- Dispatch one bidirectional sync via the existing adapter.  The
    --- adapter already implements the exact-once callback + ERRORS
    --- contract; we forward server, staged file, merge callback, and
    --- the (possibly injected) sync_service straight through.
    function p.sync(server, staged_path, merge_cb, callback)
        local ok, adapter_or_err = pcall(function()
            return SyncServiceAdapter.new({
                server         = server,
                merge_callback = merge_cb,
                sync_service   = injected, -- nil → adapter's own lazy resolver
            })
        end)
        if not ok then
            log.warn("adapter construction raised: %s", tostring(adapter_or_err))
            callback(false, TransportInterface.ERRORS.INTERNAL); return
        end
        -- SyncService.sync also pops an always-on "Successfully
        -- synchronized." toast on success (is_silent gates only failures).
        -- Swallow just that one toast for the duration of the upload.
        QuietToast.suppress(QUIET_GRACE_S)
        adapter_or_err:upload(staged_path, function(up_ok, up_err)
            callback(up_ok, up_err)
        end)
    end

    local ok, problems = Interface.validate_implementation(p)
    if not ok then
        error("syncservice cloud provider is broken: " .. table.concat(problems, "; "))
    end

    return p
end


-- Expose constants for tests / introspection.
Provider.ID = PROVIDER_ID
Provider.SYNCABLE = SYNCABLE


return Provider
