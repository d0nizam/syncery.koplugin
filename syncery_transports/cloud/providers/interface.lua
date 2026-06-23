-- =============================================================================
-- syncery_transports/cloud/providers/interface.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- Defines the contract every CLOUD PROVIDER must follow.  A cloud
-- provider is the thing that actually carries out a bidirectional cloud
-- sync on behalf of the Cloud transport.  Today there are two:
--
--   • cloudstorage — hius07's "Cloud storage+" plugin, reached as a method
--                 on the live plugin instance (ui.cloudstorage:sync);
--                 adds FTP and is provider-agnostic.  THE DEFAULT.
--   • syncservice — KOReader's built-in `apps/cloudstorage/syncservice`
--                 ("Cloud storage"; Dropbox + WebDAV).  THE FALLBACK.
--
-- WHY A PROVIDER LAYER (and why it mirrors the Syncthing one)
--
-- The Syncthing transport already has a provider abstraction
-- (syncthing/providers/{kosyncthing_plus,manual}): one transport, several
-- selectable backends behind one interface.  Cloud was monolithic —
-- the transport called SyncServiceAdapter directly.  This file is the
-- seam that lets the Cloud transport pick a backend WITHOUT the
-- transport, the staging code, the merge callbacks, or the UI having to
-- change when the backend changes.
--
-- This matters concretely because the KOReader maintainer hius07 has
-- announced (koreader/koreader#15330) that the built-in "Cloud storage"
-- app — and with it, plausibly, the `syncservice.lua` the syncservice
-- provider requires — is going to be removed "some day", possibly as
-- soon as the next release, in favour of the "Cloud storage+" plugin.
-- Syncery therefore uses `cloudstorage` (the plugin) as THE backend, with
-- `syncservice` ("Cloud storage") kept only as an invisible fallback —
-- behind one clearly-marked removable block in providers/init.lua, no
-- refactor of the transport, callbacks, staging, or UI.  The provider
-- layer is the insurance that keeps syncservice's removal (koreader#15330)
-- a small deletion instead of a rewrite.
--
-- IMPORTANT DIFFERENCE FROM THE SYNCTHING PROVIDER LAYER
--
-- Syncthing providers do DISCOVERY: each inspects the environment and
-- reports whether it can supply a working config; the chain returns the
-- first that can.  Cloud is different — the *server config* (which
-- Dropbox/WebDAV/FTP server) is the SAME regardless of backend; what
-- differs is (a) WHICH sync mechanism is invoked and (b) WHICH provider
-- types that mechanism can actually sync.  So the cloud provider layer
-- is an EXPLICIT user choice (a setting), not auto-discovery, and the
-- interface centres on `sync()` + `syncable_providers()`, not
-- `get_config()`.
--
-- THE CALLBACK CONTRACT IS IDENTICAL ACROSS BACKENDS
--
-- Verified against koreader/master: both invoke the merge callback as
--   sync_cb(file_path, cached_file_path, income_file_path)
-- and the only call-site difference is syncservice's modular
--   SyncService.sync(server, path, cb, is_silent)
-- vs cloudstorage's instance method
--   ui.cloudstorage:sync(server, path, cb, is_silent[, pre_cb]).
-- Because the contract is identical, the kind-aware merge callbacks
-- (annotations / progress) built by SyncServiceAdapter are reused
-- UNCHANGED by both providers — a provider only abstracts the dispatch.
--
-- =============================================================================
--
-- THE INTERFACE
--
-- A cloud provider is a plain Lua table with the following functions.
--
--
--   id() → string
--     Stable, machine-friendly id.  Never user-facing.  Used as the
--     active_id reported in the selection result and as the log prefix.
--     Should stay stable across versions.
--     Examples: "cloudstorage", "syncservice".
--
--
--   display_name() → string
--     Human-readable name, kept for the interface contract and used for
--     diagnostics/logs.  Not shown in a picker (there is one backend) and
--     no longer rendered in the status panel.  May be translated.  Examples:
--       "Cloud storage+ (Dropbox / WebDAV / FTP)"
--       "Cloud storage (Dropbox / WebDAV)"
--
--
--   is_available() → bool
--     True if this provider's backend is reachable right now:
--       • cloudstorage — the injected ui.cloudstorage resolver returns an
--                     object exposing a `sync` method.
--       • syncservice — `apps/cloudstorage/syncservice` require()s ok.
--     MUST be cheap — no blocking I/O.  The transport calls it as part
--     of its own is_available, which the router and every menu redraw
--     hit frequently.
--
--
--   syncable_providers() → table  (set: { [type] = true, ... })
--     The set of cloud server `type` strings this provider can actually
--     sync.  The transport consults this instead of a hard-coded list,
--     so the "is this picked server syncable?" check follows the chosen
--     provider:
--       • cloudstorage → { dropbox = true, webdav = true, ftp = true }
--       • syncservice → { dropbox = true, webdav = true }
--     A server whose type is NOT in this set surfaces via the
--     transport's status() as "picked but not syncable on this
--     provider" — the same structured flag the UI already reads.
--
--
--   sync(server, staged_path, merge_cb, callback)
--     Dispatch ONE bidirectional cloud sync.
--       server       — the cloud server config table (type, url, creds…).
--       staged_path  — absolute path to the file this device has staged
--                      (the bytes to upload); the merge_cb reads/merges/
--                      writes this path and the backend uploads it.
--       merge_cb      — the kind-aware 3-way merge callback
--                      (sync_cb(file_path, cached, income)); identical
--                      shape for every backend.
--       callback      — function(ok: bool, err: string|nil).  MUST fire
--                      exactly once.  `err`, when present, MUST be one of
--                      Interface.ERRORS (the transport-level interface's
--                      error strings).
--     For eventually-consistent / deferred-offline behaviour the backend
--     may complete the merge later (NetworkMgr rerun); the callback
--     reports that the sync was DISPATCHED, mirroring the existing
--     adapter's semantics.
--
-- =============================================================================


local Interface = {}


--- Methods every cloud provider MUST implement.  Order is canonical
--- for stable validator error messages.
Interface.REQUIRED_METHODS = {
    "id",
    "display_name",
    "is_available",
    "syncable_providers",
    "sync",
}


--- Validate that `provider` implements the contract.  Returns
--- (true) on success or (false, problems[]) listing every missing or
--- wrong-typed method.  The provider chain runs this at selection time
--- so a broken provider fails with a readable error instead of blowing
--- up on first sync.
---@param provider table
---@return boolean ok
---@return table|nil problems
function Interface.validate_implementation(provider)
    local problems = {}
    if type(provider) ~= "table" then
        return false, { "provider is not a table" }
    end
    for _, name in ipairs(Interface.REQUIRED_METHODS) do
        if type(provider[name]) ~= "function" then
            table.insert(problems,
                string.format("missing or non-function method: %s", name))
        end
    end
    if #problems > 0 then return false, problems end
    return true
end


return Interface
