-- =============================================================================
-- syncery_transports/cloud/transport.lua
-- =============================================================================
--
-- The Cloud transport.  Conforms to the contract in
-- syncery_transports/interface.lua.
--
-- WHAT THIS TRANSPORT DOES
--
-- For each push:
--   1. Build the canonical cloud-object name (via staging.lua).
--   2. Stage the payload to a unique-named local file.
--   3. Hand the staged file to the SELECTED CLOUD PROVIDER's sync().
--   4. The provider dispatches asynchronously to whatever cloud server
--      the user configured (Dropbox / WebDAV / FTP / …).
--
-- CLOUD PROVIDER LAYER
--
-- The transport does not talk to SyncService directly.  It consumes a
-- cloud PROVIDER (syncery_transports/cloud/providers/) resolved by
-- CloudProviders.select.  There is ONE backend — hius07's "Cloud storage+"
-- plugin (ui.cloudstorage:sync, the canonical SyncService since
-- koreader#9709) — with the built-in syncservice as an invisible automatic
-- fallback when the plugin is disabled (no user choice; see providers/init).
-- A provider abstracts ONLY the dispatch + the set of syncable server types;
-- the staging, the kind-aware merge callbacks, and the UI are unchanged.
-- The merge callbacks are still built by SyncServiceAdapter.make_* — they
-- are backend-independent (identical callback contract verified against
-- koreader/master), so both providers reuse them UNCHANGED.
--
-- Pull is the inverse: SyncService can give us the cloud's content
-- via the merge callback — we capture that into the staging file,
-- then read the bytes back into the orchestrator.
--
-- EVENTUALLY CONSISTENT
--
-- Like Syncthing, Cloud is eventually consistent: a successful push
-- means "we handed the bytes to SyncService", not "a peer has the
-- bytes".  The actual transfer happens in KOReader's background.
-- `is_eventually_consistent() == true` lets the UI know.
--
-- INJECTED DEPENDENCIES
--
-- Tests pass:
--   • settings_reader   — for the configured `server` object + provider id
--   • select_provider   — function(opts) → selection; defaults to the real
--                         CloudProviders.select.  Tests inject a fake to
--                         drive the transport against a fake provider.
--   • ui_cloudstorage_resolver — function() → ui.cloudstorage|nil; threaded
--                         to the selector so the cloudstorage backend can be
--                         reached (the "Cloud storage+" plugin).
--   • sync_service      — optional injected syncservice module (tests);
--                         threaded to the selector so the syncservice provider
--                         uses the fake instead of require()ing the real one.
--   • file_writer       — function(path, content) → ok, err (writes the staging file)
--   • staging_dir       — absolute path; default is <settings>/syncery/cloud_staging
--
-- All are optional in production; sensible defaults are wired in.
--
-- PAYLOAD CONTRACT
--
-- SyncService.sync is BIDIRECTIONAL in one call, so push and pull are the
-- same underlying operation (cloud_sync). The orchestrator passes
-- opts = { payload = { kind, book_id, content } }:
--   • kind     — "progress" or "annotations"
--   • book_id  — stable partial-MD5 hash
--   • content  — the canonical JSON bytes to sync (string)
-- Missing kind/book_id is REJECTED; missing content is REJECTED for push.
--
-- pull takes the same payload; with content it runs the bidirectional sync
-- (the merge callback pulls remote in and reconciles into the canonical
-- file). A content-less pull reports success-with-no-data rather than
-- staging an empty file that could touch the cloud copy. There is no
-- "read the staged file back" pull — it was unsound under the real model.
--
-- =============================================================================


local Interface         = require("syncery_transports/interface")
local Staging           = require("syncery_transports/cloud/staging")
local SyncServiceAdapter = require("syncery_transports/cloud/sync_service_adapter")
local CloudProviders    = require("syncery_transports/cloud/providers/init")
local StorageMode       = require("syncery_storage_mode")
local AnnPaths          = require("syncery_ann/paths")
local ProgressPaths     = require("syncery_progress/paths")
local Log               = require("syncery_transports/log")
local log               = Log.tag("transport:cloud")


local Transport = {}


-- ----------------------------------------------------------------------------
-- Constants.
-- ----------------------------------------------------------------------------


local TRANSPORT_ID  = "cloud"
-- COLLAPSED: same canonical key the checkbox + wizard write (was the
-- redundant `syncery_sync_via_cloud` mirror) so is_available() can't diverge.
local TOGGLE_KEY    = "syncery_use_cloud"
local KEY_SERVER    = "syncery_cloud_server"


-- ----------------------------------------------------------------------------
-- Defaults.
-- ----------------------------------------------------------------------------


local function default_settings_reader(key)
    if not _G.G_reader_settings then return nil end
    return _G.G_reader_settings:readSetting(key)
end


local function default_file_writer(path, content)
    local f, err = io.open(path, "wb")
    if not f then return false, tostring(err) end
    local ok_write, write_err = f:write(content or "")
    f:close()
    if not ok_write then return false, tostring(write_err) end
    return true
end


local function default_staging_dir()
    return StorageMode.get_hash_root() .. "/cloud_staging"
end


--- Default directory-ensure: mkdir -p via KOReader's util.makePath (the
--- house-style mkdir -p, already used by json_store / paths).
---
--- The previous default was a NO-OP that reported success without creating
--- the directory.  Nothing else creates the staging dir
--- (<hash_root>/cloud_staging) — get_hash_root() only returns the path,
--- default_file_writer is a bare io.open that does NOT create parents, and
--- init.lua constructs the transport without an ensure_dir — so every cloud
--- push failed its staging write with INTERNAL (mis-classified as transient
--- → retried forever).  The cloud_transport tests missed it by injecting a
--- working fake ensure_dir.  Honouring the contract (ensure the dir EXISTS,
--- not merely claim it does) at the default level fixes every callsite, not
--- just init.lua.
---
--- Lazy require: only PRODUCTION reaches this default (tests inject their
--- own ensure_dir), so `util` is resolved at call time, never at module
--- load — no headless load-order coupling.
---@param dir string  absolute directory path
---@return boolean    true when the directory exists afterwards
local function default_ensure_dir(dir)
    if type(dir) ~= "string" or dir == "" then return false end
    -- util.makePath is mkdir -p: a no-op when the dir already exists,
    -- creating intermediate components as needed.  Truthy on success.
    local ok = require("util").makePath(dir)
    return ok and true or false
end


-- ----------------------------------------------------------------------------
-- Constructor.
-- ----------------------------------------------------------------------------


function Transport.new(opts)
    opts = opts or {}
    local settings_reader = opts.settings_reader or default_settings_reader
    local file_writer     = opts.file_writer     or default_file_writer
    local staging_dir_fn  = opts.staging_dir_fn  or default_staging_dir
    local ensure_dir      = opts.ensure_dir      or default_ensure_dir

    -- Provider selection.  The transport consumes a
    -- cloud PROVIDER instead of a hard-coded SyncService adapter.  In
    -- production `select_provider` is the real CloudProviders.select, which
    -- resolves the "Cloud storage+" plugin as THE backend (with the built-in
    -- syncservice as an invisible fallback when the plugin is off — no user
    -- choice).  Tests inject a fake selector (or a fake sync_service threaded
    -- through the real selector) to drive the transport without touching the
    -- network or the real syncservice.
    local select_provider          = opts.select_provider or CloudProviders.select
    local ui_cloudstorage_resolver = opts.ui_cloudstorage_resolver
    local sync_service             = opts.sync_service  -- test injection (syncservice fallback)
    -- Optional hook fired when the cloud server RESPONDS to a sync (the merge
    -- callback running == the provider downloaded the remote object == the
    -- server is reachable).  Production wires this to
    -- CloudReachability:note_success, keeping the reachability verdict fresh
    -- and caching the server IP at a proven network-up moment.  nil in tests.
    local on_server_responded      = opts.on_server_responded
    local on_reconciled            = opts.on_reconciled

    --- Resolve the active provider + selection metadata for THIS call.
    --- Cheap: building a provider object is just closures, and each
    --- provider's is_available() is memoised/lazy.  Re-resolving per
    --- operation means enabling/disabling the "Cloud storage+" plugin takes
    --- effect without rebuilding the transport, and status() always reports
    --- the live active backend + fallback state.
    ---@return table selection { provider, active_id, fell_back }
    local function resolve_provider()
        return select_provider({
            ui_cloudstorage_resolver = ui_cloudstorage_resolver,
            sync_service             = sync_service,
        })
    end

    local t = {}

    function t.id() return TRANSPORT_ID end
    function t.display_name() return "Cloud" end
    function t.is_eventually_consistent() return true end

    -- Provider validation (F1): a cloud server is "syncable" only if the
    -- ACTIVE provider can actually sync its type.  Syncservice syncs only
    -- {dropbox, webdav} (it rejects FTP with "Wrong server type");
    -- cloudstorage adds ftp.  We ask the provider's syncable_providers()
    -- instead of a hard-coded list, so the "is this picked server
    -- syncable?" check follows the ACTIVE backend.  A picked-but-
    -- unsyncable server surfaces as NOT_CONFIGURED / the structured
    -- `unsupported_provider` status flag rather than a false ready state.
    local function server_is_syncable(server, provider)
        if type(server) ~= "table" or type(server.type) ~= "string" then
            return false
        end
        local syncable = provider.syncable_providers()
        return type(syncable) == "table" and syncable[server.type] == true
    end

    --- CANONICAL cloud state against an ALREADY-RESOLVED provider — the single
    --- source of truth every consumer switches on, so no one re-derives
    --- per-protocol/per-server nuances:
    ---   "disabled"    — master toggle off
    ---   "no_server"   — toggle on, no destination picked yet
    ---   "no_backend"  — server picked, but NO cloud backend can dispatch it
    ---                   (neither "Cloud storage+" nor the built-in syncservice
    ---                   is present) — the fix is to install/enable a backend,
    ---                   not to re-pick the destination
    ---   "unsupported" — a backend IS present but can't sync THIS server type
    ---                   (e.g. FTP on the built-in syncservice)
    ---   "ready"       — enabled, server picked, and a backend can sync it
    --- This is config/syncability only — NOT network reachability (a separate,
    --- async concern handled by the reachability layer).
    local function provider_state(provider)
        if not settings_reader(TOGGLE_KEY) then return "disabled" end
        local server = settings_reader(KEY_SERVER)
        if type(server) ~= "table" then return "no_server" end
        if not (provider and provider.is_available()) then return "no_backend" end
        if not server_is_syncable(server, provider) then return "unsupported" end
        return "ready"
    end

    --- Availability against an ALREADY-RESOLVED provider: ready iff state=="ready".
    local function is_available_with(provider)
        return provider_state(provider) == "ready"
    end

    function t.is_available()
        local sel = resolve_provider()
        return is_available_with(sel.provider)
    end

    --- Common preamble: extract payload, build the cloud name + staging
    --- path, ensure the staging directory exists, resolve the server.
    --- Takes the ALREADY-RESOLVED provider so the syncable check follows
    --- the active backend.  Returns (path, server, kind) on success, or
    --- (nil, err_class).
    local function _prepare(opts_in, provider)
        local payload = opts_in and opts_in.payload or opts_in
        if type(payload) ~= "table" then
            return nil, Interface.ERRORS.REJECTED
        end
        local kind    = payload.kind
        local book_id = payload.book_id
        local cloud_name = Staging.cloud_name_for(kind, book_id)
        if not cloud_name then
            log.warn("payload missing or malformed (kind=%s, book_id=%s)",
                tostring(kind), tostring(book_id))
            return nil, Interface.ERRORS.REJECTED
        end

        local staging_dir = staging_dir_fn()
        local ok = ensure_dir(staging_dir)
        if not ok then
            log.warn("staging dir unavailable: %s", tostring(staging_dir))
            return nil, Interface.ERRORS.INTERNAL
        end

        local path = Staging.staging_path_for(staging_dir, cloud_name)
        local server = settings_reader(KEY_SERVER)
        if not server_is_syncable(server, provider) then
            -- Either nothing picked, or a provider the active backend
            -- can't sync (e.g. FTP on syncservice). Both are "not configured
            -- for sync" (F1).
            return nil, Interface.ERRORS.NOT_CONFIGURED
        end
        return path, server, kind
    end

    --- Build the kind-appropriate merge callback for SyncService. The
    --- callback merges the WHOLE canonical file (annotations envelope or
    --- progress state) using the SAME engine the Syncthing path uses, and
    --- reconciles the merged result back into the canonical on-disk file so a
    --- deferred/offline sync (F2) still lands. comparator is nil here: the
    --- cloud sync may run with no live document (book closed), and
    --- Merge.three_way treats nil as "no overlap pass" — identical to the
    --- closed-book Syncthing case.
    local function _build_merge_callback(kind, book_file)
        if kind == "annotations" then
            return SyncServiceAdapter.make_annotation_sync_callback({
                canonical_path = AnnPaths.shared_annotations_path(book_file),
                on_reconciled  = on_reconciled,
            })
        elseif kind == "progress" then
            return SyncServiceAdapter.make_progress_sync_callback({
                canonical_path = ProgressPaths.shared_progress_path(book_file),
                on_reconciled  = on_reconciled,
            })
        end
        return nil
    end

    --- cloud_sync — the ONE bidirectional sync operation.
    ---
    --- A cloud provider's sync() is bidirectional in a single call
    --- (download remote -> merge callback -> upload merged), so there is
    --- no separate "push" vs "pull" transfer; both are this one sync. We:
    ---   1. resolve the active provider (the plugin, or its fallback);
    ---   2. stage the canonical content to a unique local file (so the
    ---      backend uploads THIS device's current state);
    ---   3. hand the staging file to the provider's sync() together with
    ---      the kind-aware merge callback, which reads/merges/writes that
    ---      file and reconciles the merged result into the canonical file
    ---      (F2);
    ---   4. report (ok, err) when the sync was dispatched (online: merged
    ---      now; offline: deferred — see F2). is_silent stays true inside
    ---      the provider.
    ---
    --- There is no standalone `pull` (stage-nothing -> upload -> read-back
    --- a file the backend only writes via the callback): that shape was
    --- unsound under the real model.
    local function cloud_sync(book_file, sync_opts, callback)
        -- Resolve the active provider ONCE and thread it through the
        -- availability check, the syncable check (_prepare), and dispatch,
        -- so all three agree on a single backend for this call.
        local sel = resolve_provider()
        local provider = sel.provider

        if not is_available_with(provider) then
            callback(false, Interface.ERRORS.NOT_AVAILABLE, nil); return
        end

        local payload = sync_opts and sync_opts.payload
        if type(payload) ~= "table" or type(payload.content) ~= "string" then
            log.warn("cloud_sync %s missing payload.content", tostring(book_file))
            callback(false, Interface.ERRORS.REJECTED, nil); return
        end

        local path, server_or_err, kind = _prepare(sync_opts, provider)
        if not path then callback(false, server_or_err, nil); return end
        local server = server_or_err

        -- 1) Stage this device's canonical content to disk. The backend
        -- uploads whatever the merge callback leaves here; staging the real
        -- content is what makes this an upload of OUR current state.
        local ok_write, write_err = file_writer(path, payload.content)
        if not ok_write then
            log.warn("staging write failed for %s: %s", path, tostring(write_err))
            callback(false, Interface.ERRORS.INTERNAL, nil); return
        end

        -- 2) Dispatch one bidirectional sync via the active provider, wired
        -- with the kind-aware merge callback (backend-independent; built by
        -- SyncServiceAdapter.make_*). Async from here (online: synchronous
        -- merge; offline: deferred rerun, F2). The provider's callback
        -- fires exactly once per its interface contract.
        local merge_cb = _build_merge_callback(kind, book_file)
        -- The merge callback runs only AFTER the provider downloaded the remote
        -- object (Cloud:sync invokes it with the income file) -- i.e. the server
        -- responded, so it is reachable.  Wrap it to signal that, then defer to
        -- the real merge UNCHANGED.  Only when there is both a callback to wrap
        -- and a hook to fire; the signal is pcall-isolated so a reachability
        -- bug can never break the merge.
        if merge_cb and on_server_responded then
            local _raw_merge_cb = merge_cb
            merge_cb = function(...)
                pcall(on_server_responded)
                return _raw_merge_cb(...)
            end
        end
        local ok_call, call_err = pcall(function()
            provider.sync(server, path, merge_cb, function(ok, err)
                callback(ok, err, nil)
            end)
        end)
        if not ok_call then
            log.warn("provider sync raised: %s", tostring(call_err))
            callback(false, Interface.ERRORS.INTERNAL, nil)
        end
    end

    -- push and pull both map onto the single bidirectional cloud_sync.
    -- The transport interface requires both; for a bidirectional provider
    -- they are the same operation. push carries content; pull is requested
    -- without content, but since the sync is bidirectional, a pull is served
    -- by syncing the current canonical content too (the merge callback pulls
    -- remote in and reconciles). Callers that truly have no local content to
    -- offer simply have an empty/again-current canonical file staged.
    function t.push(book_file, push_opts, callback)
        cloud_sync(book_file, push_opts, callback)
    end

    function t.pull(book_file, pull_opts, callback)
        -- A pull with no payload.content cannot run the bidirectional sync
        -- (we need SOMETHING to stage). In practice the orchestrator always
        -- pushes canonical content; a content-less pull reports
        -- success-with-no-data rather than fabricating an empty upload that
        -- could touch the cloud copy.
        local payload = (pull_opts and pull_opts.payload) or pull_opts
        if type(payload) ~= "table" or type(payload.content) ~= "string" then
            if not t.is_available() then
                callback(false, Interface.ERRORS.NOT_AVAILABLE, nil); return
            end
            callback(true, nil, nil); return
        end
        cloud_sync(book_file, pull_opts, callback)
    end

    function t.status()
        local sel      = resolve_provider()
        local provider = sel.provider
        local server   = settings_reader(KEY_SERVER)
        -- ONE canonical verdict; available / summary / the structured flags all
        -- derive from it, so no consumer re-combines toggle/server/backend/
        -- syncability itself.
        local state    = provider_state(provider)
        local summary  = ({
            disabled    = "disabled (toggle off)",
            no_server   = "not configured (cloud server not picked)",
            no_backend  = "no cloud backend available (enable \"Cloud storage+\")",
            unsupported = string.format(
                "provider not supported for sync (%s); use Dropbox or WebDAV",
                tostring(type(server) == "table" and server.type or "?")),
            ready       = "ready (uploads dispatched in background)",
        })[state]
        return {
            display_name        = "Cloud",
            -- THE canonical state; new consumers switch on this.
            state               = state,
            available           = state == "ready",
            summary             = summary,
            -- Back-compat structured flags, DERIVED from `state` so existing
            -- consumers keep working; prefer switching on `state` going forward.
            unsupported_provider = (state == "unsupported") or nil,
            backend_unavailable  = (state == "no_backend") or nil,
            provider_type       = (type(server) == "table") and server.type or nil,
            -- The active cloud backend id, and whether the "Cloud storage+"
            -- plugin was unavailable so we fell back to the built-in
            -- syncservice. Consumed by the status panel (fallback note only);
            -- only claimed when the fallback backend actually works, so the
            -- note can't contradict a no_backend verdict.
            cloud_provider      = sel.active_id,
            provider_fell_back  = (sel.fell_back and state ~= "no_backend")
                                  or nil,
        }
    end

    function t.supports(_capability)
        -- Cloud has no folder concept and no events.  All optional
        -- capabilities return false.
        return false
    end

    local ok, problems = Interface.validate_implementation(t)
    if not ok then
        error("Cloud Transport construction is broken: "
              .. table.concat(problems, "; "))
    end

    return t
end


-- Exposed for regression-locking the production default WITHOUT the full
-- transport (the staging-dir creation is load-bearing — see the function's
-- note).  Mirrors cloudstorage_provider.resolve_ui_instance.
Transport._default_ensure_dir = default_ensure_dir


return Transport
