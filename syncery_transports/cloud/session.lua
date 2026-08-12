-- =============================================================================
-- syncery_transports/cloud/session.lua
-- =============================================================================
--
-- The single owner of executable cloud configuration in Syncery.
--
-- Persisted Syncery settings and Cloud storage+'s live `servers` entries are
-- immutable sources.  Only the private runtime copy created here may be handed
-- to a KOReader provider.  Dropbox is therefore free to replace its refresh
-- token with a short-lived access token without poisoning either settings
-- store.  The runtime is reused for a bounded period so Sync All does not
-- refresh OAuth once per book.
--
-- Callers receive operations and sanitized status only.  No public method
-- returns a server descriptor, raw provider, or `provider.base`.
--
-- THREE SERVER SHAPES EXIST HERE; KEEP THEM DISTINCT:
--
--   stored       defensive copy of Syncery's selected destination;
--   source       pristine credentials from Cloud storage+ (or safe fallback);
--   runtime      private mutable copy passed to the KOReader provider.
--
-- `stored.url` is the folder the user selected for Syncery.  `source.url` is
-- the server's browsing start folder and may legitimately differ.  Credentials
-- come from `source`; the effective destination folder comes from `stored`.
-- Only `runtime` may be mutated, cached, or contain a Dropbox access token.
-- =============================================================================

local Interface      = require("syncery_transports/interface")
local Settings       = require("syncery_settings")
local CloudProviders = require("syncery_transports/cloud/providers/init")
local Log            = require("syncery_transports/log")
local log            = Log.tag("cloud.session")

local Session = {}
Session.__index = Session

local PRIMARY_ID = CloudProviders.PRIMARY_ID or "cloudstorage"
-- Dropbox documents four-hour access tokens.  Rebuild one hour early so a
-- long Sync All does not begin near the expiry boundary.  This is a runtime
-- lifetime, not a persisted credential expiry timestamp.
local DROPBOX_RUNTIME_TTL = 3 * 60 * 60

local unpack_values = table.unpack or unpack

local function pack_values(...)
    return { n = select("#", ...), ... }
end

local function is_callable(value)
    if type(value) == "function" then return true end
    if type(value) ~= "table" then return false end
    local mt = getmetatable(value)
    return mt ~= nil and mt.__call ~= nil
end

local function shallow_copy(value)
    if type(value) ~= "table" then return nil end
    local copy = {}
    for key, item in pairs(value) do copy[key] = item end
    return copy
end

local function shallow_equal(left, right)
    if left == right then return true end
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    for key, value in pairs(left) do
        if type(value) ~= type(right[key]) or value ~= right[key] then
            return false
        end
    end
    for key, value in pairs(right) do
        if type(value) ~= type(left[key]) or value ~= left[key] then
            return false
        end
    end
    return true
end

-- Credential-source identity deliberately excludes `url`: the Cloud storage+
-- picker copies credentials from a configured server but returns the currently
-- selected subfolder as `stored.url`.  Requiring equal URLs would reject the
-- common `/` server + `/Syncery` destination.  `address` still detects endpoint
-- or Dropbox app/account changes, and duplicate matches fail closed below.
local function same_server(left, right)
    return type(left) == "table" and type(right) == "table"
        and left.type == right.type
        and left.name == right.name
        and left.address == right.address
end

-- Prefer the picker-selected folder.  The source URL is only a compatibility
-- fallback for older descriptors that did not persist an explicit selection.
local function effective_folder(stored, source)
    if stored.url ~= nil then return stored.url end
    return source and source.url or nil
end

-- This snapshot answers “would the operation still go to the same place?”
-- It keeps only the routing fields needed for private cache invalidation.
-- `address` may contain Dropbox app credentials, so this snapshot must remain
-- session-private and must never be logged, persisted, or exposed to callers.
local function destination_snapshot(stored, folder)
    return {
        type = stored.type,
        name = stored.name,
        address = stored.address,
        url = folder,
    }
end

-- A non-empty Dropbox address means password is a refresh token and address is
-- APP_KEY:APP_SECRET.  Once KOReader sets username=true, password has become a
-- short-lived access token and the record is runtime state, not a source.
local function is_refresh_token_dropbox(source)
    return type(source) == "table"
        and source.type == "dropbox"
        and type(source.address) == "string"
        and source.address ~= ""
        and source.username ~= true
end

local function state_error(state)
    if state == "no_backend" or state == "direct_io_unavailable"
            or state == "unsupported" then
        return Interface.ERRORS.NOT_AVAILABLE
    end
    if state == "internal" then return Interface.ERRORS.INTERNAL end
    return Interface.ERRORS.NOT_CONFIGURED
end

local function status_summary(state, provider_type)
    local summaries = {
        disabled = "disabled (toggle off)",
        no_server = "not configured (cloud server not picked)",
        no_backend = "no cloud backend available (enable \"Cloud storage+\")",
        ambiguous_server = "cloud destination is ambiguous (duplicate server entries)",
        stale_server = "cloud destination no longer matches Cloud storage+",
        poisoned_stored_fallback = "cloud credentials must be selected again",
        ready = "ready (uploads dispatched in background)",
        internal = "cloud session unavailable (internal error)",
    }
    if state == "unsupported" then
        return string.format("provider not supported for sync (%s); use Dropbox or WebDAV",
            tostring(provider_type or "?"))
    end
    return summaries[state] or "cloud not available"
end

-- Direct I/O is restricted to Syncery-owned filenames.  Besides defining the
-- capability boundary, this prevents a compromised manifest/device id from
-- turning the cloud facade into arbitrary remote path access.
local function safe_remote_name(name)
    if type(name) ~= "string" or name == "" then return false end
    if name:find("[/\\%z]") or name:find("..", 1, true) then return false end
    if name:match("^syncery%-manifest%-%w[%w_-]*%.txt$") then return true end
    if name:match("^syncery%-progress%-%w[%w_-]*%.json$") then return true end
    if name:match("^syncery%-annotations%-%w[%w_-]*%.json$") then return true end
    return false
end

local function basename(path)
    if type(path) ~= "string" then return nil end
    return path:match("([^/\\]+)$")
end

local function join_remote(folder, name)
    folder = type(folder) == "string" and folder or ""
    if folder == "" or folder == "/" then return "/" .. name end
    return folder:gsub("/+$", "") .. "/" .. name
end

local function map_status_code(code)
    code = tonumber(code)
    if code and code >= 200 and code < 300 then return true, nil end
    if code == 401 or code == 403 then
        return false, Interface.ERRORS.AUTH_FAILED
    end
    if code and code >= 400 and code < 500 then
        return false, Interface.ERRORS.REJECTED
    end
    return false, Interface.ERRORS.UNREACHABLE
end

function Session.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Session)
    self._settings = opts.settings_api or Settings
    self._select_provider = opts.select_provider or CloudProviders.select
    self._ui_cloudstorage_resolver = opts.ui_cloudstorage_resolver
        or function() return nil end
    self._sync_service = opts.sync_service
    self._now = opts.now or os.time
    self._global_settings = opts.global_settings
    self._runtime = nil
    self._shutdown = false

    -- Settings already provide one canonical `cloud` change notification.
    -- Subscribe once here so menu, migration and programmatic changes all drop
    -- the same private runtime without additional invalidation plumbing.
    local on_change = self._settings and self._settings.on_change
    if is_callable(on_change) then
        local ok, unsubscribe = pcall(on_change, "cloud", function()
            self:_drop_runtime("settings_changed")
        end)
        if ok and is_callable(unsubscribe) then self._unsubscribe = unsubscribe end
    end
    return self
end

function Session:_drop_runtime(reason)
    if self._runtime then
        log.dbg("discarding private runtime (%s)", tostring(reason or "changed"))
    end
    self._runtime = nil
end

function Session:_failure(state, stored, backend_id, fell_back, preserve_runtime)
    -- Most failures invalidate cached execution state.  The sole preserving
    -- case is “direct I/O unavailable” on a valid fallback backend: ordinary
    -- per-book sync can still reuse that runtime.
    if not preserve_runtime then self:_drop_runtime(state) end
    return nil, state_error(state), {
        state = state,
        provider_type = type(stored) == "table" and stored.type or nil,
        backend_id = backend_id,
        fell_back = fell_back and true or false,
    }
end

function Session:_live_cloudstorage()
    local ok, ui = pcall(self._ui_cloudstorage_resolver)
    if not ok or type(ui) ~= "table" then return nil end
    return ui
end

function Session:_resolve_live(stored)
    local ui = self:_live_cloudstorage()
    if not ui then return nil, nil, "no_backend" end

    if type(ui.servers) ~= "table" and is_callable(ui.loadSettings) then
        pcall(function() ui:loadSettings() end)
    end
    if type(ui.servers) ~= "table" then return nil, nil, "stale_server" end

    -- Do not select the first partial match.  Zero matches means the selected
    -- server was removed/edited; multiple matches make credential selection
    -- ambiguous.  Both conditions fail before any provider sees credentials.
    local source, count = nil, 0
    for _, candidate in ipairs(ui.servers) do
        if same_server(stored, candidate) then
            source = candidate
            count = count + 1
        end
    end
    if count == 0 then return nil, nil, "stale_server" end
    if count ~= 1 then return nil, nil, "ambiguous_server" end

    if type(ui.providers) ~= "table" and is_callable(ui.getProviders) then
        pcall(function() ui:getProviders() end)
    end
    local raw_provider = type(ui.providers) == "table"
        and ui.providers[stored.type] or nil
    if type(raw_provider) ~= "table" then
        return nil, nil, "unsupported"
    end
    return source, raw_provider, nil
end

function Session:_resolve_fallback(stored)
    -- The fallback has no independent pristine server registry.  Therefore a
    -- Dropbox record already marked as runtime cannot be recovered safely; its
    -- password may be an expired bearer token.  WebDAV and legacy long-lived
    -- Dropbox tokens are still safe to copy into a private runtime.
    if stored.type == "dropbox" and stored.username == true then
        return nil, "poisoned_stored_fallback"
    end
    return stored, nil
end

function Session:_runtime_expired(source, now)
    -- TTL applies only when a refresh-token Dropbox source can mint a new
    -- access token.  WebDAV, FTP and long-lived Dropbox tokens have no session
    -- refresh cycle here.  Clock rollback also invalidates defensively.
    if not self._runtime or not is_refresh_token_dropbox(source) then return false end
    local created = tonumber(self._runtime.created_at)
    if not created or now < created then return true end
    return now - created >= DROPBOX_RUNTIME_TTL
end

-- Inspect current configuration without creating a credential runtime.
-- This is intentionally side-effect-light so status/menu polling never causes
-- OAuth traffic.  The method performs five gates in order: feature setting,
-- stored selection, backend, provider support, then credential source.
function Session:_inspect(require_direct_io)
    if self._shutdown then
        return self:_failure("no_backend", nil, nil, false)
    end

    local settings = self._settings
    local enabled = false
    if settings and is_callable(settings.get_cloud_enabled) then
        local ok_enabled, value = pcall(settings.get_cloud_enabled)
        if not ok_enabled then return self:_failure("internal", nil, nil, false) end
        enabled = value == true
    end
    if not enabled then return self:_failure("disabled", nil, nil, false) end

    local stored
    if settings and is_callable(settings.get_cloud_server) then
        local ok_stored, value = pcall(settings.get_cloud_server)
        if not ok_stored then return self:_failure("internal", nil, nil, false) end
        stored = value
    end
    if type(stored) ~= "table" or type(stored.type) ~= "string" then
        return self:_failure("no_server", stored, nil, false)
    end

    local ok_select, selection = pcall(self._select_provider, {
        ui_cloudstorage_resolver = self._ui_cloudstorage_resolver,
        sync_service = self._sync_service,
    })
    selection = ok_select and type(selection) == "table" and selection or nil
    local adapter = selection and selection.provider or nil
    if type(adapter) ~= "table" or not is_callable(adapter.id)
            or not is_callable(adapter.is_available)
            or not is_callable(adapter.syncable_providers)
            or not is_callable(adapter.sync) then
        return self:_failure("no_backend", stored, nil,
            selection and selection.fell_back)
    end

    local ok_id, backend_id = pcall(adapter.id)
    local ok_available, available = pcall(adapter.is_available)
    if not ok_id or type(backend_id) ~= "string"
            or not ok_available or not available then
        return self:_failure("no_backend", stored,
            ok_id and backend_id or nil, selection.fell_back)
    end

    local ok_syncable, syncable = pcall(adapter.syncable_providers)
    if not ok_syncable or type(syncable) ~= "table"
            or syncable[stored.type] ~= true then
        return self:_failure("unsupported", stored, backend_id,
            selection.fell_back)
    end

    local source, raw_provider, source_state
    if backend_id == PRIMARY_ID then
        source, raw_provider, source_state = self:_resolve_live(stored)
    else
        source, source_state = self:_resolve_fallback(stored)
    end
    if not source then
        return self:_failure(source_state or "no_backend", stored, backend_id,
            selection.fell_back)
    end

    local folder = effective_folder(stored, source)
    if type(folder) ~= "string" then
        return self:_failure("no_server", stored, backend_id,
            selection.fell_back)
    end

    if require_direct_io and backend_id ~= PRIMARY_ID then
        return self:_failure("direct_io_unavailable", stored, backend_id,
            selection.fell_back, true)
    end

    local destination = destination_snapshot(stored, folder)
    local ok_now, now_value = pcall(self._now)
    local now = ok_now and tonumber(now_value) or 0
    -- Reuse is legal only while all three identities agree:
    --   backend       which adapter executes the operation;
    --   destination   account/endpoint plus selected Syncery folder;
    --   source        the full pristine descriptor, including credentials.
    -- Comparing the full source catches an edited refresh token even when the
    -- routing fields remain unchanged.  Dropbox additionally has a TTL.
    if self._runtime and (
            self._runtime.backend_id ~= backend_id
            or not shallow_equal(self._runtime.destination, destination)
            or not shallow_equal(self._runtime.source, source)
            or self:_runtime_expired(source, now)) then
        self:_drop_runtime("identity_or_ttl_changed")
    end

    return {
        adapter = adapter,
        backend_id = backend_id,
        fell_back = selection.fell_back and true or false,
        provider_type = stored.type,
        source = source,
        raw_provider = raw_provider,
        folder = folder,
        destination = destination,
        now = now,
        state = "ready",
    }, nil, nil
end

function Session:_acquire(require_direct_io)
    local info, err, failure = self:_inspect(require_direct_io)
    if not info then return nil, err, failure end
    if not self._runtime then
        -- The one legal transition from immutable configuration to executable
        -- state.  Copy credentials from the pristine source, then override only
        -- the destination folder selected by Syncery.  KOReader may mutate this
        -- table freely; no settings object aliases it.
        local runtime = shallow_copy(info.source)
        runtime.url = info.folder
        self._runtime = {
            backend_id = info.backend_id,
            destination = shallow_copy(info.destination),
            source = shallow_copy(info.source),
            server = runtime,
            created_at = info.now,
        }
        log.dbg("created private runtime for backend %s", info.backend_id)
    end

    -- Handles are private call-scoped capabilities.  Raw provider access is
    -- attached only for the synchronous direct-I/O path and is never returned
    -- by a public Session method.
    local handle = {
        adapter = info.adapter,
        runtime = self._runtime.server,
    }
    if require_direct_io then handle.raw_provider = info.raw_provider end
    return handle, nil, nil
end

-- Availability and status inspect configuration only.  They must not acquire
-- a runtime or refresh Dropbox merely because a menu is being rendered.
function Session:is_available()
    local info, err = self:_inspect(false)
    return info ~= nil, err
end

function Session:status()
    local info, _, failure = self:_inspect(false)
    local meta = info or failure or { state = "no_backend" }
    local state = meta.state or "ready"
    return {
        display_name = "Cloud",
        state = state,
        available = state == "ready",
        summary = status_summary(state, meta.provider_type),
        unsupported_provider = state == "unsupported" and true or nil,
        backend_unavailable = state == "no_backend" and true or nil,
        provider_type = meta.provider_type,
        cloud_provider = meta.backend_id,
        provider_fell_back = meta.fell_back and state ~= "no_backend" and true or nil,
    }
end

function Session:sync(staged_path, merge_cb, callback)
    callback = is_callable(callback) and callback or function() end
    local handle, err = self:_acquire(false)
    if not handle then callback(false, err); return end

    local finished = false
    local function finish(ok, provider_err)
        if finished then return end
        finished = true
        callback(ok, provider_err)
    end
    -- The provider adapter may dispatch work via UIManager:nextTick.  Unlike
    -- `_with_direct`, this path cannot restore provider-global state here: the
    -- eventual callback still needs the runtime.  Ownership remains bounded by
    -- the session/adapter contract and the runtime never aliases persistence.
    local ok, raised = pcall(handle.adapter.sync, handle.runtime, staged_path,
        merge_cb, finish)
    if not ok then
        log.warn("cloud sync dispatch raised: %s", tostring(raised))
        finish(false, Interface.ERRORS.INTERNAL)
    end
end

local function has_direct_methods(provider)
    return type(provider) == "table"
        and is_callable(provider.listFolder)
        and is_callable(provider.uploadFile)
        and is_callable(provider.downloadFile)
end

function Session:direct_file_io_available()
    local info, err = self:_inspect(true)
    if not info then return false, err end
    if not has_direct_methods(info.raw_provider) then
        return false, Interface.ERRORS.NOT_AVAILABLE
    end
    if info.provider_type == "dropbox"
            and not is_callable(info.raw_provider.genAccessToken) then
        return false, Interface.ERRORS.NOT_AVAILABLE
    end
    return true, nil
end

function Session:_with_direct(method_name, operation)
    local handle, err = self:_acquire(true)
    if not handle then return nil, err end
    local provider = handle.raw_provider
    if type(provider) ~= "table" or not is_callable(provider[method_name]) then
        return nil, Interface.ERRORS.NOT_AVAILABLE
    end

    -- Raw Cloud storage+ provider methods are synchronous and read their server
    -- through the module-global `provider.base`.  Bracket that global for the
    -- smallest possible interval and restore it after success, mapped failure,
    -- or Lua exception.  This is safe here precisely because no nextTick work
    -- escapes `operation`.
    local previous = provider.base
    provider.base = handle.runtime
    local result = pack_values(pcall(function()
        -- Direct calls bypass provider.run(), so Dropbox token generation must
        -- happen explicitly.  The mutation lands only in the private runtime
        -- and subsequent manifest/prefetch calls reuse the generated token.
        if handle.runtime.type == "dropbox" then
            if not is_callable(provider.genAccessToken) then
                return nil, Interface.ERRORS.NOT_AVAILABLE
            end
            local ok_refresh, refreshed = pcall(provider.genAccessToken)
            if not ok_refresh or refreshed ~= true then
                return nil, Interface.ERRORS.AUTH_FAILED
            end
        end
        return operation(provider, handle.runtime)
    end))
    provider.base = previous

    if not result[1] then
        log.warn("direct cloud operation raised")
        return nil, Interface.ERRORS.INTERNAL
    end
    return unpack_values(result, 2, result.n)
end

function Session:_with_show_unsupported(operation)
    local settings = self._global_settings or _G.G_reader_settings
    if type(settings) ~= "table" or not is_callable(settings.readSetting)
            or not is_callable(settings.saveSetting) then
        return operation()
    end

    -- KOReader providers consult this global setting while listing.  Preserve
    -- all three prior states (true, false, absent), including on exceptions, so
    -- Syncery never changes the user's Cloud storage+ browsing preference.
    local previous = settings:readSetting("show_unsupported")
    settings:saveSetting("show_unsupported", true)
    local result = pack_values(pcall(operation))
    if previous == nil and is_callable(settings.delSetting) then
        settings:delSetting("show_unsupported")
    else
        settings:saveSetting("show_unsupported", previous)
    end
    if not result[1] then error(result[2]) end
    return unpack_values(result, 2, result.n)
end

function Session:list_folder(include_folders)
    return self:_with_direct("listFolder", function(provider, runtime)
        local entries = self:_with_show_unsupported(function()
            return provider.listFolder(runtime.url, include_folders and true or false)
        end)
        if type(entries) ~= "table" then
            return nil, Interface.ERRORS.UNREACHABLE
        end
        return entries, nil
    end)
end

function Session:upload_file(local_path)
    -- Upload derives the remote name from a local staging filename, then the
    -- provider joins it with runtime.url.  Only allow the Syncery namespace.
    local name = basename(local_path)
    if not safe_remote_name(name) then
        return false, Interface.ERRORS.REJECTED
    end
    local ok, err = self:_with_direct("uploadFile", function(provider, runtime)
        local code = provider.uploadFile(runtime.url, local_path, nil, true)
        return map_status_code(code)
    end)
    if ok == nil then return false, err end
    return ok, err
end

function Session:download_file(remote_name, local_path)
    -- The caller chooses a local temp path, but remote lookup remains confined
    -- to the validated Syncery filename under the selected runtime folder.
    if not safe_remote_name(remote_name) or type(local_path) ~= "string"
            or local_path == "" then
        return false, Interface.ERRORS.REJECTED
    end
    local ok, err = self:_with_direct("downloadFile", function(provider, runtime)
        local code = provider.downloadFile(join_remote(runtime.url, remote_name),
            local_path)
        return map_status_code(code)
    end)
    if ok == nil then return false, err end
    return ok, err
end

function Session:shutdown()
    -- Reader/FileManager teardown may call shutdown more than once.  Drop the
    -- bearer token immediately and detach the settings listener exactly once.
    if self._shutdown then return end
    self._shutdown = true
    self:_drop_runtime("shutdown")
    if is_callable(self._unsubscribe) then pcall(self._unsubscribe) end
    self._unsubscribe = nil
end

Session.DROPBOX_RUNTIME_TTL = DROPBOX_RUNTIME_TTL

return Session
