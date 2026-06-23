-- =============================================================================
-- spec/syncthing_kosyncthing_plus_provider_spec.lua
-- =============================================================================
--
-- Tests for syncery_transports/syncthing/providers/kosyncthing_plus_provider.lua.
--
-- The provider takes injectable `api_resolver` (default looks up the
-- real `_G.KOSyncthingPlusAPI` global) and `settings_reader`.  These
-- tests pass fakes; no real KOSyncthing+ plugin needed.
--
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_kosyncthing_plus_provider_spec_" .. tostring(os.time()))

local KOSyncthingPlusProvider = require("syncery_transports/syncthing/providers/kosyncthing_plus_provider")
local Interface    = require("syncery_transports/interface")


-- ----------------------------------------------------------------------------
-- Helper: build a fake KOSyncthing+ API table.  Caller passes opts to enable
-- bits of the surface; everything not enabled is absent (which is
-- exactly what older plugin versions look like).
-- ----------------------------------------------------------------------------


local function make_fake_kosyncthing(opts)
    opts = opts or {}
    local api = { apiCall = opts.api_call or function() return {} end }

    if opts.with_folders then
        api.info = api.info or {}
        api.info.getFolders = function() return {
            { id = "books-abc", label = "My Books", path = "/data/books", paused = true },
            { id = "docs-xyz",  label = "Docs",      path = "/data/docs", state = "error" },
        } end
    end
    if opts.with_events then
        api.onStatusChange  = function(_cb) end
        api.offStatusChange = function(_cb) end
    end
    if opts.with_ignore_registry then
        api.IgnoreRegistry = { register = function() return true end }
    end
    if opts.with_conflicts_detailed then
        api.info = api.info or {}
        api.info.getConflictsDetailed = function() return {} end
    end
    if opts.with_periodic_sync then
        api.status = api.status or {}
        api.status.isPeriodicSyncEnabled  = function() return true end
        api.status.getPeriodicSyncInterval = function() return 30 end
        api.status.getNextPeriodicSyncAt  = function() return 1700000000 end
        api.control = api.control or {}
        api.control.setPeriodicSyncEnabled  = function() return true end
        api.control.setPeriodicSyncInterval = function() return true end
        api.control.runPeriodicSyncNow      = function() return true end
    end
    if opts.with_quick_sync then
        api.control = api.control or {}
        -- The published signature is quickSync(on_complete).
        -- Companions pass nil; we record the arg so the assertion in the
        -- transport spec can check it.
        api._quick_sync_calls = {}
        api.control.quickSync = function(touchmenu)
            table.insert(api._quick_sync_calls, { touchmenu = touchmenu })
            return true
        end
    end
    return api
end


local function reader(t)
    return function(k) return t[k] end
end


-- ----------------------------------------------------------------------------
-- id() returns the stable string.
-- ----------------------------------------------------------------------------


do
    local p = KOSyncthingPlusProvider.new({
        api_resolver    = function() return nil end,
        settings_reader = reader({}),
    })
    h.assert_equal(p.id(), "kosyncthing_plus", "id is 'kosyncthing_plus'")
end


-- ----------------------------------------------------------------------------
-- KOSyncthing+ not installed → get_config returns nil.
-- ----------------------------------------------------------------------------


do
    local p = KOSyncthingPlusProvider.new({
        api_resolver    = function() return nil end,
        settings_reader = reader({}),
    })
    h.assert_nil(p.get_config(), "no KOSyncthing+ API → no config")
end


-- ----------------------------------------------------------------------------
-- KOSyncthing+ present but missing apiCall → get_config returns nil.
-- ----------------------------------------------------------------------------


do
    local p = KOSyncthingPlusProvider.new({
        api_resolver    = function() return { version = "1.0" } end,  -- no apiCall
        settings_reader = reader({}),
    })
    h.assert_nil(p.get_config(), "KOSyncthing+ without apiCall → no config")
end


-- ----------------------------------------------------------------------------
-- KOSyncthing+ present with apiCall → get_config returns a table with
-- rest_client and folder_id; NOT url/api_key.
-- ----------------------------------------------------------------------------


do
    local kosyncthing = make_fake_kosyncthing({ with_folders = true })
    local p = KOSyncthingPlusProvider.new({
        api_resolver    = function() return kosyncthing end,
        settings_reader = reader({}),
    })
    local cfg = p.get_config()

    h.assert_equal(type(cfg), "table",          "config is a table")
    h.assert_true(cfg.rest_client ~= nil,        "rest_client present")
    h.assert_nil(cfg.url,                        "no url in KOSyncthing+ config")
    h.assert_nil(cfg.api_key,                    "no api_key in KOSyncthing+ config")
    h.assert_nil(cfg.folder_id,
        "two folders + no pick -> folder_id nil (picker chooses; no folders[1] guess)")
    h.assert_equal(#cfg.folders, 2,              "folders list populated")
    h.assert_equal(cfg.folders[1].label, "My Books",
        "discovered folder carries the label (for the unified picker)")
    h.assert_equal(cfg.folders[1].state, "paused",
        "discovered folder surfaces paused (f.paused -> state) for the picker")
    h.assert_equal(cfg.folders[2].state, "error",
        "discovered folder surfaces the live state string")
    h.assert_equal(cfg.kosyncthing_plus_api, kosyncthing,           "kosyncthing_plus_api exposed to transport")
end


-- ----------------------------------------------------------------------------
-- Folder discovery: explicit user setting wins over auto-discovery.
-- ----------------------------------------------------------------------------


do
    local kosyncthing = make_fake_kosyncthing({ with_folders = true })
    local p = KOSyncthingPlusProvider.new({
        api_resolver    = function() return kosyncthing end,
        settings_reader = reader({
            syncery_syncthing_folder_id = "user-chosen-id",
        }),
    })
    local cfg = p.get_config()
    h.assert_equal(cfg.folder_id, "user-chosen-id",
        "explicit user-set folder_id wins")
end


-- ----------------------------------------------------------------------------
-- Folder discovery: no info.getFolders + no user setting -> nil (picker chooses).
-- ----------------------------------------------------------------------------


do
    local kosyncthing = make_fake_kosyncthing({})  -- no folders
    local p = KOSyncthingPlusProvider.new({
        api_resolver    = function() return kosyncthing end,
        settings_reader = reader({}),
    })
    local cfg = p.get_config()
    h.assert_nil(cfg.folder_id, "no setting + no plugin folders -> folder_id nil")
    h.assert_nil(cfg.folders, "no folders list")
end


-- ----------------------------------------------------------------------------
-- Folder discovery: exactly ONE folder + no user setting -> adopt it
-- (unambiguous; only the multi-folder case is left to the picker).
-- ----------------------------------------------------------------------------


do
    local kosyncthing = {
        apiCall = function() return {} end,
        info = { getFolders = function() return {
            { id = "only-one", label = "Books", path = "/data/books" },
        } end },
    }
    local p = KOSyncthingPlusProvider.new({
        api_resolver    = function() return kosyncthing end,
        settings_reader = reader({}),
    })
    local cfg = p.get_config()
    h.assert_equal(cfg.folder_id, "only-one",
        "exactly one folder + no pick -> auto-adopt it")
    h.assert_equal(#cfg.folders, 1, "single-folder list still surfaced for the picker")
end


-- ----------------------------------------------------------------------------
-- supports() — capabilities follow what the KOSyncthing+ API exposes.
-- ----------------------------------------------------------------------------


do
    -- Minimal API: no extra capabilities advertised.
    local kosyncthing = make_fake_kosyncthing({})
    local p = KOSyncthingPlusProvider.new({
        api_resolver    = function() return kosyncthing end,
        settings_reader = reader({}),
    })
    h.assert_false(p.supports(Interface.CAPABILITIES.IGNORE_PATTERNS),
        "minimal API: no ignore_patterns (no IgnoreRegistry, no setFolderIgnore)")
    h.assert_false(p.supports(Interface.CAPABILITIES.EVENT_SUBSCRIPTION),
        "minimal API: no events")
    h.assert_false(p.supports(Interface.CAPABILITIES.CONFLICTS_DETAILED),
        "minimal API: no conflicts_detailed")
    h.assert_false(p.supports(Interface.CAPABILITIES.PERIODIC_SYNC),
        "minimal API: no periodic_sync")
    h.assert_false(p.supports(Interface.CAPABILITIES.QUICK_SYNC),
        "minimal API: no quick_sync")
    h.assert_false(p.supports(Interface.CAPABILITIES.CONFLICT_IGNORE_REGISTRY),
        "minimal API: no conflict_ignore_registry (no IgnoreRegistry)")
end


do
    -- Full-surface API: every capability we know about.
    local kosyncthing = make_fake_kosyncthing({
        with_events            = true,
        with_ignore_registry   = true,
        with_conflicts_detailed = true,
        with_periodic_sync     = true,
        with_quick_sync        = true,
    })
    local p = KOSyncthingPlusProvider.new({
        api_resolver    = function() return kosyncthing end,
        settings_reader = reader({}),
    })
    h.assert_true(p.supports(Interface.CAPABILITIES.IGNORE_PATTERNS),
        "full API: ignore_patterns")
    h.assert_true(p.supports(Interface.CAPABILITIES.EVENT_SUBSCRIPTION),
        "full API: events")
    h.assert_true(p.supports(Interface.CAPABILITIES.CONFLICTS_DETAILED),
        "full API: conflicts_detailed")
    h.assert_true(p.supports(Interface.CAPABILITIES.PERIODIC_SYNC),
        "full API: periodic_sync")
    h.assert_true(p.supports(Interface.CAPABILITIES.QUICK_SYNC),
        "full API: quick_sync")
    h.assert_true(p.supports(Interface.CAPABILITIES.CONFLICT_IGNORE_REGISTRY),
        "full API: conflict_ignore_registry")
end


do
    -- IgnoreRegistry present as a table but WITHOUT a callable register:
    -- IGNORE_PATTERNS stays true (table presence alone satisfies the
    -- .stignore OR-path), but CONFLICT_IGNORE_REGISTRY is false — the two
    -- capabilities are distinct and the scanner one is strict about the
    -- method being callable.
    local kosyncthing = make_fake_kosyncthing({})
    kosyncthing.IgnoreRegistry = {}  -- table, no register method
    local p = KOSyncthingPlusProvider.new({
        api_resolver    = function() return kosyncthing end,
        settings_reader = reader({}),
    })
    h.assert_true(p.supports(Interface.CAPABILITIES.IGNORE_PATTERNS),
        "IgnoreRegistry table (no register): ignore_patterns still true")
    h.assert_false(p.supports(Interface.CAPABILITIES.CONFLICT_IGNORE_REGISTRY),
        "IgnoreRegistry table without callable register: no conflict_ignore_registry")
end


-- ----------------------------------------------------------------------------
-- QUICK_SYNC: present iff api.control.quickSync exists as a function.
-- Periodic_sync infrastructure does NOT imply quick_sync — they're
-- separate capabilities even though both are about "make sync happen
-- soon".
-- ----------------------------------------------------------------------------


do
    -- Periodic sync present, quick_sync absent.
    local kosyncthing = make_fake_kosyncthing({ with_periodic_sync = true })
    local p = KOSyncthingPlusProvider.new({
        api_resolver    = function() return kosyncthing end,
        settings_reader = reader({}),
    })
    h.assert_true(p.supports(Interface.CAPABILITIES.PERIODIC_SYNC),
        "periodic sync present")
    h.assert_false(p.supports(Interface.CAPABILITIES.QUICK_SYNC),
        "but quick_sync absent without explicit quickSync function")
end


do
    -- Wrong type for quickSync (not a function) → not supported.
    local kosyncthing = make_fake_kosyncthing({})
    kosyncthing.control = kosyncthing.control or {}
    kosyncthing.control.quickSync = "not a function"
    local p = KOSyncthingPlusProvider.new({
        api_resolver    = function() return kosyncthing end,
        settings_reader = reader({}),
    })
    h.assert_false(p.supports(Interface.CAPABILITIES.QUICK_SYNC),
        "non-function quickSync rejected")
end


-- ----------------------------------------------------------------------------
-- Capabilities are re-checked on every call (KOSyncthing+ installed/uninstalled
-- at runtime is handled gracefully).
-- ----------------------------------------------------------------------------


do
    local current_kosyncthing = make_fake_kosyncthing({ with_events = true })
    local p = KOSyncthingPlusProvider.new({
        api_resolver    = function() return current_kosyncthing end,
        settings_reader = reader({}),
    })
    h.assert_true(p.supports(Interface.CAPABILITIES.EVENT_SUBSCRIPTION),
        "initially: events supported")

    -- KOSyncthing+ "uninstalled" mid-session.
    current_kosyncthing = nil
    h.assert_false(p.supports(Interface.CAPABILITIES.EVENT_SUBSCRIPTION),
        "after disappearance: capability drops to false (no stale cache)")
end


-- ----------------------------------------------------------------------------
-- The default api_resolver actually reads from _G.KOSyncthingPlusAPI.
-- This is the only test that touches the global; we set and unset it
-- in a single block to avoid polluting other specs.
-- ----------------------------------------------------------------------------


do
    rawset(_G, "KOSyncthingPlusAPI", { apiCall = function() return {} end })
    local p = KOSyncthingPlusProvider.new({ settings_reader = reader({}) })   -- no api_resolver
    h.assert_true(p.get_config() ~= nil,
        "default resolver picks up _G.KOSyncthingPlusAPI when present")
    rawset(_G, "KOSyncthingPlusAPI", nil)
    -- Re-construct (otherwise our prior provider holds a stale reference
    -- — though in fact it re-resolves on each call, this is documented
    -- in the provider source).
    h.assert_nil(p.get_config(), "and reflects removal on the next call")
end
