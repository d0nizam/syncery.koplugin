-- =============================================================================
-- syncery_transports/cloud/providers/init.lua
-- =============================================================================
--
-- The cloud sync backend resolver.
--
-- There is exactly ONE cloud sync mechanism in KOReader: SyncService — the
-- 3-way merge (download remote `.temp` -> merge callback -> upload, guarded
-- by an If-Match etag).  Since koreader#9709 that mechanism lives INSIDE the
-- "Cloud storage+" plugin as `ui.cloudstorage:sync`, and that is the
-- canonical path every feature uses today (the statistics and vocabbuilder
-- plugins sync their databases through the very same call).  Its former
-- standalone home, `apps/cloudstorage/syncservice`, is no longer require()d
-- by anything in mainline and is slated for removal together with the old
-- built-in "Cloud storage" app (koreader#15330).
--
-- Syncery therefore uses the plugin (`cloudstorage`, reached via the injected
-- ui_cloudstorage_resolver) as THE backend.  There is NO user-facing choice:
-- the plugin is built in and loaded by default.  `syncservice` survives ONLY
-- as an INVISIBLE, automatic last-resort fallback for the rare case where the
-- user has DISABLED the plugin — Dropbox/WebDAV still sync, FTP does not.
--
-- ►► REMOVING syncservice LATER (when koreader#15330 lands and
--    apps/cloudstorage/syncservice is gone):
--      1. delete the marked REMOVABLE block inside M.select below,
--      2. delete the SyncServiceProvider require (also marked) just below,
--      3. delete syncservice_provider.lua + sync_service_adapter.lua
--         (+ their specs).
--    Nothing else references syncservice — this file is the single seam.
--    After step 1 the (already-present) final `return` makes select() yield
--    the plugin unconditionally; if the plugin is then off, the transport's
--    dispatch reports NOT_AVAILABLE (graceful), no fallback.
--
-- USAGE
--
--     local CloudProviders = require("syncery_transports/cloud/providers/init")
--     local sel = CloudProviders.select({
--         ui_cloudstorage_resolver = function() return ui and ui.cloudstorage end,
--     })
--     -- sel.provider   : the active provider (always non-nil)
--     -- sel.active_id  : "cloudstorage" normally; "syncservice" on fallback
--     -- sel.fell_back  : true only when the plugin was unavailable and we
--     --                  dropped to the built-in syncservice fallback
--
-- =============================================================================


local CloudStorageProvider = require("syncery_transports/cloud/providers/cloudstorage_provider")
-- ►► REMOVABLE WITH koreader#15330 (see header): the built-in syncservice
--    fallback provider.  Delete this require with the marked block in
--    M.select and the syncservice_provider.lua + sync_service_adapter.lua
--    files.
local SyncServiceProvider = require("syncery_transports/cloud/providers/syncservice_provider")
local Log = require("syncery_transports/log")
local log = Log.tag("cloud.providers")


local M = {}


-- PRIMARY is the only advertised backend (the "Cloud storage+" plugin).
-- FALLBACK is the always-available floor we drop to ONLY when the plugin is
-- disabled (it just needs a `require`, never a live UI module).
local PRIMARY_ID  = "cloudstorage"
local FALLBACK_ID = "syncservice"  -- ►► REMOVABLE with the fallback block


--- Resolve the active cloud backend.  Cheap: building a provider object is
--- just closures, and each provider's is_available() is lazy.  Re-resolving
--- per operation means enabling/disabling the plugin takes effect without
--- rebuilding the transport, and status() always reports the live backend.
---@param opts table
---   .ui_cloudstorage_resolver  function() → ui.cloudstorage|nil  (the plugin)
---   .sync_service              optional injected syncservice module (tests;
---                              consumed by the fallback only)
---@return table selection  { provider, active_id, fell_back }
function M.select(opts)
    opts = opts or {}

    -- THE backend: hius07's "Cloud storage+" plugin, reached as
    -- `ui.cloudstorage:sync` (the canonical SyncService since koreader#9709).
    local primary = CloudStorageProvider.new({
        ui_cloudstorage_resolver = opts.ui_cloudstorage_resolver,
    })

    -- ►►►►►► REMOVABLE BLOCK — invisible built-in fallback (koreader#15330) ►►►►►►
    -- The plugin is built in and loaded by default, so this fires only when
    -- the user has DISABLED it.  We then fall back, automatically and without
    -- any UI choice, to KOReader's built-in syncservice so Dropbox/WebDAV
    -- destinations still sync (FTP cannot — syncservice has no FTP).  When
    -- apps/cloudstorage/syncservice is removed upstream, delete this whole
    -- `if` block (and the require above); select() then returns the primary
    -- unconditionally and dispatch reports NOT_AVAILABLE if the plugin is off.
    if not primary.is_available() then
        local fallback = SyncServiceProvider.new({ sync_service = opts.sync_service })
        log.dbg("\"Cloud storage+\" plugin unavailable; using built-in syncservice fallback")
        return {
            provider  = fallback,
            active_id = fallback and fallback.id() or FALLBACK_ID,
            fell_back = true,
        }
    end
    -- ►►►►►► END REMOVABLE BLOCK ►►►►►►

    return { provider = primary, active_id = primary.id(), fell_back = false }
end


-- Expose ids for tests / introspection.
M.PRIMARY_ID  = PRIMARY_ID
M.FALLBACK_ID = FALLBACK_ID  -- ►► REMOVABLE with the fallback block


return M
