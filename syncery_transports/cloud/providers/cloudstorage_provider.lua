-- =============================================================================
-- syncery_transports/cloud/providers/cloudstorage_provider.lua
-- =============================================================================
--
-- The "Cloud storage+" provider: hius07's "Cloud storage+" plugin
-- (plugins/cloudstorage.koplugin, provider id "cloudstorage"), reached as
-- a method on the live plugin instance — `ui.cloudstorage:sync(...)`.
-- This is the modular successor to the built-in syncservice; the KOReader
-- maintainer hius07 has announced (koreader#15330) that the old "Cloud
-- storage" app — and plausibly the syncservice the built-in provider
-- depends on — will be removed, with "Cloud storage+" as the replacement.
-- This provider is the DEFAULT backend; "Cloud storage" (syncservice) is
-- the fallback when this plugin isn't present.
--
-- WHY ui.cloudstorage:sync IS SAFE TO CALL
--
-- `Cloud:sync` is a PUBLIC companion API: KOReader's own statistics and
-- vocabulary builder plugins already call it on the live instance
-- (statistics uses self.ui.cloudstorage:sync / :getServerNameType).  It
-- is not a private hook.  Syncery's transport layer has no `self.ui`, so
-- the live instance is reached through an INJECTED resolver (clean DI,
-- like the existing doc_id_fn / on_status_change), never a global grab.
--
-- DISPATCH SEMANTICS (verified against plugins/cloudstorage.koplugin/main.lua Cloud:sync)
--
--   ui.cloudstorage:sync(server, file_path, sync_cb, is_silent[, pre_cb])
--
-- is bidirectional in one call and FIRE-AND-FORGET from the caller's
-- view: it runs the transfer asynchronously (provider.run +
-- UIManager:nextTick) and shows its own success/failure toasts — it does
-- NOT report completion back to the caller.  (`pre_cb`, when given, runs
-- BEFORE the work — it is a pre-callback, not a completion callback.)  So
-- this provider mirrors the built-in provider's "dispatched" semantics:
-- the callback reports that the sync was HANDED OFF (true) — online it
-- merges now, offline it defers — exactly like the existing adapter.
--
-- THE MERGE CALLBACK IS IDENTICAL TO SYNCSERVICE
--
-- Cloud:sync invokes sync_cb(file_path, cached_file_path, income_file_path)
-- — byte-for-byte the same 3-path contract the built-in uses (income ==
-- file_path..".temp", cached == file_path..".sync").  So the kind-aware
-- merge callbacks the transport builds (via SyncServiceAdapter.make_*)
-- are reused UNCHANGED; this provider only abstracts the dispatch.
--
-- SYNCABLE PROVIDERS
--
-- this provider is provider-agnostic and — unlike the built-in syncservice — its
-- FTP provider implements upload/download (Ftp.uploadFile ignores etag,
-- so FTP has no optimistic locking; that is an accepted, mitigated risk,
-- see PHASE19 notes).  So the syncable set is { dropbox, webdav, ftp }.
--
-- AVAILABILITY
--
-- Available iff the injected resolver returns an object exposing a `sync`
-- method (the live "Cloud storage+" plugin instance).  When the plugin
-- isn't installed / not loaded, the resolver returns nil and this
-- provider reports unavailable — the selector then falls back to the
-- built-in and flags it so the UI can tell the user.
--
-- =============================================================================


local Interface          = require("syncery_transports/cloud/providers/interface")
local TransportInterface  = require("syncery_transports/interface")
local QuietToast         = require("syncery_transports/cloud/quiet_toast")
local Log = require("syncery_transports/log")
local log = Log.tag("cloud.provider.cloudstorage")


local Provider = {}


local PROVIDER_ID = "cloudstorage"

-- Seconds to swallow the backend's "Successfully synchronized." toast around a
-- sync (the toast fires when the upload completes).  Generous so a slow
-- network still lands inside the window; see quiet_toast.lua.
local QUIET_GRACE_S = 60

-- The provider types this provider can sync.  Adds ftp over the built-in.
local SYNCABLE = { dropbox = true, webdav = true, ftp = true }


-- A KOReader plugin method may be a plain function OR a callable table (some
-- forks wrap methods, e.g. for logging) — `obj:method()` works for both, but
-- `type(obj.method) == "function"` rejects the callable-table form and would
-- wrongly report the "Cloud storage+" backend as unavailable (falling the
-- whole sync back to the Dropbox/WebDAV-only SyncService).  Test callability.
local function is_callable(x)
    if type(x) == "function" then return true end
    if type(x) ~= "table" then return false end
    local mt = getmetatable(x)
    return mt ~= nil and mt.__call ~= nil
end


--- Construct the "Cloud storage+" (cloudstorage) provider.
---@param opts table|nil
---   .ui_cloudstorage_resolver  function() → ui.cloudstorage|nil
---       Returns the live "Cloud storage+" plugin instance (the thing
---       exposing :sync), or nil when it isn't available.  In production
---       this closes over the plugin's self.ui; tests inject a fake.
---@return table provider
function Provider.new(opts)
    opts = opts or {}
    local resolver = opts.ui_cloudstorage_resolver
                     or function() return nil end

    local p = {}

    function p.id() return PROVIDER_ID end

    function p.display_name() return "Cloud storage+ (Dropbox / WebDAV / FTP)" end

    --- Cheap: just calls the resolver and shape-checks the result.  No
    --- blocking I/O (the resolver is a closure over self.ui).
    function p.is_available()
        local ui_cs = resolver()
        return type(ui_cs) == "table" and is_callable(ui_cs.sync)
    end

    function p.syncable_providers()
        -- Fresh copy so callers can't mutate our set.
        return { dropbox = true, webdav = true, ftp = true }
    end

    --- Dispatch one bidirectional sync via the live "Cloud storage+"
    --- instance.  We pass is_silent=true (per-save syncs must not spam
    --- toasts) and forward the kind-aware merge callback UNCHANGED.  The
    --- call is fire-and-forget (Cloud:sync runs async and reports nothing
    --- back), so a clean dispatch is reported as (true, nil) — mirroring
    --- the built-in provider.  Errors map to the transport-level ERRORS:
    ---   • resolver yields no usable instance → NOT_AVAILABLE
    ---   • the call itself raises             → INTERNAL
    --- The callback fires EXACTLY ONCE in every branch.
    function p.sync(server, staged_path, merge_cb, callback)
        local ui_cs = resolver()
        if type(ui_cs) ~= "table" or not is_callable(ui_cs.sync) then
            log.warn("cloudstorage unavailable: resolver returned no :sync")
            callback(false, TransportInterface.ERRORS.NOT_AVAILABLE); return
        end

        local ok, call_err = pcall(function()
            -- Cloud:sync pops an always-on "Successfully synchronized." toast
            -- on success (it bypasses the maskable Notification:notify, and
            -- is_silent gates only failures).  Swallow just that one toast for
            -- the duration of the sync; merge_cb is forwarded UNCHANGED.
            QuietToast.suppress(QUIET_GRACE_S)
            -- Method call (colon): Cloud:sync is an instance method.
            -- Signature: (server, file_path, sync_cb, is_silent[, pre_cb]).
            ui_cs:sync(server, staged_path, merge_cb, true)
        end)
        if not ok then
            log.warn("cloudstorage sync raised: %s", tostring(call_err))
            callback(false, TransportInterface.ERRORS.INTERNAL); return
        end
        callback(true, nil)
    end

    local ok, problems = Interface.validate_implementation(p)
    if not ok then
        error("cloudstorage cloud provider is broken: " .. table.concat(problems, "; "))
    end

    return p
end


-- Expose constants for tests / introspection.
Provider.ID = PROVIDER_ID
Provider.SYNCABLE = SYNCABLE


--- Resolve the live "Cloud storage+" backend instance from a ReaderUI.
--- The plugin registers itself as `ui.cloudstorage` — KOReader's
--- ReaderUI:registerModule(plugin.name, instance) sets `ui[name]`, and the
--- cloudstorage.koplugin has name="cloudstorage" (verified against
--- koreader/master readerui.lua + pluginloader BUILTIN_PLUGINS).  Returns the
--- instance (a table exposing :sync) or nil when the plugin isn't loaded /
--- there's no ui.  Pure + nil-safe: this is the BODY of main.lua's
--- ui_cloudstorage_resolver closure, extracted so the one-liner can be
--- regression-locked without the full UI (main.lua itself isn't unit-loadable).
function Provider.resolve_ui_instance(ui)
    return ui and ui.cloudstorage or nil
end


return Provider
