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
-- The transport does not talk to SyncService directly and does not own cloud
-- credentials. It consumes a CloudSession, which resolves the provider and
-- owns the private executable server copy. There is ONE primary backend —
-- hius07's "Cloud storage+"
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
-- Production passes:
--   • session           — the one long-lived CloudSession for this stack.
-- Direct transport tests may still pass settings_reader/select_provider; the
-- constructor wraps them in a compatibility CloudSession.
--   • select_provider   — function(opts) → selection used by that compatibility
--                         session.
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
local CloudSession      = require("syncery_transports/cloud/session")
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


-- ----------------------------------------------------------------------------
-- Defaults.
-- ----------------------------------------------------------------------------


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
    local file_writer     = opts.file_writer     or default_file_writer
    local staging_dir_fn  = opts.staging_dir_fn  or default_staging_dir
    local ensure_dir      = opts.ensure_dir      or default_ensure_dir

    -- Production injects the one CloudSession built by the transport factory.
    -- The compatibility construction below keeps direct transport specs and
    -- third-party callers working while still routing every operation through
    -- a session.  Its settings adapter returns defensive copies.
    local session = opts.session
    if not session then
        local settings_reader = opts.settings_reader or function(key)
            return _G.G_reader_settings and _G.G_reader_settings:readSetting(key)
        end
        local settings_api = {
            get_cloud_enabled = function()
                return settings_reader("syncery_use_cloud") == true
            end,
            get_cloud_server = function()
                local server = settings_reader("syncery_cloud_server")
                if type(server) ~= "table" then return nil end
                local copy = {}
                for key, value in pairs(server) do copy[key] = value end
                return copy
            end,
            on_change = function() return function() end end,
        }
        session = CloudSession.new({
            settings_api = settings_api,
            select_provider = opts.select_provider,
            ui_cloudstorage_resolver = opts.ui_cloudstorage_resolver,
            sync_service = opts.sync_service,
            now = opts.now,
            global_settings = opts.global_settings,
        })
    end
    assert(type(session) == "table", "Cloud Transport requires a session")
    -- Optional hook fired when the cloud server RESPONDS to a sync (the merge
    -- callback running == the provider downloaded the remote object == the
    -- server is reachable).  Production wires this to
    -- CloudReachability:note_success, keeping the reachability verdict fresh
    -- and caching the server IP at a proven network-up moment.  nil in tests.
    local on_server_responded      = opts.on_server_responded
    local on_reconciled            = opts.on_reconciled

    local t = {}

    function t.id() return TRANSPORT_ID end
    function t.display_name() return "Cloud" end
    function t.is_eventually_consistent() return true end

    function t.is_available()
        return session:is_available()
    end

    --- Common preamble: extract payload, build the cloud name + staging
    --- path, and ensure the staging directory exists. Returns (path, kind)
    --- on success, or
    --- (nil, err_class).
    local function _prepare(opts_in)
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
        return path, kind
    end

    --- Build the kind-appropriate merge callback for SyncService. The
    --- callback merges the WHOLE canonical file (annotations envelope or
    --- progress state) using the SAME engine the Syncthing path uses, and
    --- reconciles the merged result back into the canonical on-disk file so a
    --- deferred/offline sync (F2) still lands. comparator is nil here: the
    --- cloud sync may run with no live document (book closed), and
    --- Merge.three_way treats nil as "no overlap pass" — identical to the
    --- closed-book Syncthing case.
    local function _build_merge_callback(kind, book_file, book_id, is_prefetch)
        -- BUGFIX: prefetch check MOVED
        -- FIRST and re-keyed on a SEPARATE is_prefetch flag, not a
        -- distinct "prefetch_progress"/"prefetch_annotations" kind. The
        -- old distinct-kind approach correctly signalled "route to
        -- cloud_staging/prefetch/, not canonical" to THIS function, but
        -- that same kind value was ALSO used earlier (_prepare, via
        -- Staging.cloud_name_for) to compute the REMOTE cloud object
        -- name -- which nothing ever re-translated back to "progress"/
        -- "annotations" for that purpose. The fallback prefetch was
        -- therefore reading from/writing to "syncery-prefetch_progress-
        -- {id}.json", a cloud object no genuine push ever writes to,
        -- instead of the peer's real "syncery-progress-{id}.json". kind
        -- is now ALWAYS the real remote kind; is_prefetch is the
        -- routing signal, carried on the payload instead of overloading
        -- the wire-visible kind value.
        if is_prefetch and (kind == "progress" or kind == "annotations") then
            -- Cloud prefetch fallback. Unlike the regular "annotations"/
            -- "progress" branches below, this deliberately does NOT
            -- touch canonical storage (no book_file/canonical_path
            -- involved at all) -- it reads income_file (the raw
            -- downloaded remote content) and places it into
            -- cloud_staging/prefetch/, reusing the SAME validated-write
            -- helper the Cloud Storage+ path uses
            -- (PluginSync._validateAndPlace), so there is one
            -- validated-write implementation, not two.
            -- BUGFIX (confirmed against the REAL frontend/apps/
            -- cloudstorage/syncservice.lua source, not assumption):
            -- SyncService.sync's own loop is
            --   local ok, cb_return = pcall(sync_cb, file_path, cached_file_path, income_file_path)
            --   if not ok or not cb_return then ... return end
            --   -- (falls through to) api:uploadFile(..., file_path, ...)
            -- Returning a truthy value from THIS callback is a direct
            -- instruction to SyncService: upload file_path's CURRENT
            -- on-disk content to the remote, right now. This callback
            -- never touches local_file (file_path) -- it is purely a
            -- read: consume income_file, place a copy under
            -- cloud_staging/prefetch/. If it returned true on success,
            -- SyncService would faithfully re-upload the UNCHANGED
            -- bootstrap-empty envelope staged before this sync began,
            -- silently overwriting the peer's real remote data with
            -- nothing. Fixed: this callback must ALWAYS return false --
            -- "please do not upload" -- regardless of whether the fetch
            -- itself succeeded. Success/failure of the fetch is
            -- observable to callers via the orchestrator's aggregated
            -- pull_book result, which is independent of this value (see
            -- Adapter:upload: its own callback(true, nil) fires
            -- unconditionally once svc.sync's synchronous dispatch does
            -- not raise, regardless of what THIS callback returns).
            return function(local_file, cached_file, income_file)
                if not (book_id and income_file) then return false end
                local f = io.open(income_file, "rb")
                if not f then return false end
                local content = f:read("*a")
                f:close()
                if not content or content == "" then return false end
                local PluginSync = require("syncery_transports/plugin_sync")
                local prefetch_dir = staging_dir_fn():gsub("/+$", "") .. "/prefetch/"
                local ok_mkpath = pcall(function()
                    require("util").makePath(prefetch_dir)
                end)
                if not ok_mkpath then return false end
                local final_path = prefetch_dir .. "syncery-" .. kind
                    .. "-" .. book_id .. ".json"
                PluginSync._validateAndPlace(content, final_path)
                return false
            end
        end
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
        elseif kind == "manifest" then
            return function(local_file, cached_file, income_file)
                local cjson = require("json")
                local function read_json(path)
                    local f = io.open(path, "rb")
                    if not f then return nil end
                    local raw = f:read("*a"); f:close()
                    local ok, data = pcall(cjson.decode, raw)
                    if not ok or not data then return nil end
                    return data
                end
                local function write_json(path, data)
                    local f = io.open(path, "wb")
                    if not f then return false end
                    local ok, encoded = pcall(cjson.encode, data)
                    if not ok then f:close(); return false end
                    f:write(encoded); f:close()
                    return true
                end
                local local_m = read_json(local_file)
                local remote_m = read_json(income_file)
                local merged = {}
                if local_m then
                    for k, v in pairs(local_m) do merged[k] = v end
                end
                if remote_m then
                    for k, v in pairs(remote_m) do merged[k] = v end
                end
                write_json(local_file, merged)
                return true
            end
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
        local available, availability_err = session:is_available()
        if not available then
            callback(false, availability_err or Interface.ERRORS.NOT_AVAILABLE, nil)
            return
        end

        local payload = sync_opts and sync_opts.payload
        if type(payload) ~= "table" or type(payload.content) ~= "string" then
            log.warn("cloud_sync %s missing payload.content", tostring(book_file))
            callback(false, Interface.ERRORS.REJECTED, nil); return
        end

        local path, kind_or_err = _prepare(sync_opts)
        if not path then callback(false, kind_or_err, nil); return end
        local kind = kind_or_err

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
        local merge_cb = _build_merge_callback(kind, book_file, payload.book_id, payload.is_prefetch)
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
        session:sync(path, merge_cb, function(ok, err)
            callback(ok, err, nil)
        end)
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
            local available, availability_err = session:is_available()
            if not available then
                callback(false, availability_err or Interface.ERRORS.NOT_AVAILABLE, nil)
                return
            end
            callback(true, nil, nil); return
        end
        cloud_sync(book_file, pull_opts, callback)
    end

    function t.status()
        return session:status()
    end

    -- Narrow optional capabilities consumed through Bridge.  They delegate
    -- operations only; the private session and its runtime never escape.
    function t.cloud_direct_available()
        return session:direct_file_io_available()
    end

    function t.cloud_list_folder(include_folders)
        return session:list_folder(include_folders)
    end

    function t.cloud_upload_file(local_path)
        return session:upload_file(local_path)
    end

    function t.cloud_download_file(remote_name, local_path)
        return session:download_file(remote_name, local_path)
    end

    function t.shutdown()
        session:shutdown()
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
