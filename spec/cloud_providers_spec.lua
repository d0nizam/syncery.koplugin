-- =============================================================================
-- spec/cloud_providers_spec.lua
-- =============================================================================
--
-- Tests for the cloud provider layer:
--   * syncery_transports/cloud/providers/interface.lua   (contract validator)
--   * syncery_transports/cloud/providers/syncservice_provider.lua
--   * syncery_transports/cloud/providers/init.lua         (selector)
--
-- cloudstorage_provider is tested separately (cloudstorage_provider_spec).
--
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_cloud_providers_spec_" .. tostring(os.time()))

local Interface          = require("syncery_transports/cloud/providers/interface")
local SyncServiceProvider = require("syncery_transports/cloud/providers/syncservice_provider")
local CloudProviders     = require("syncery_transports/cloud/providers")
local TransportInterface = require("syncery_transports/interface")


-- A fake syncservice module: records the single .sync call so we can
-- assert the provider dispatched correctly without touching the network
-- or the real (not-loadable-here) syncservice module.
local function make_fake_service()
    local rec = { calls = {} }
    rec.module = {
        sync = function(server, path, merge_cb, suppress)
            table.insert(rec.calls, {
                server       = server,
                path         = path,
                has_merge_cb = type(merge_cb) == "function",
                suppress     = suppress,
            })
        end,
    }
    return rec
end


-- ----------------------------------------------------------------------------
-- Interface.validate_implementation
-- ----------------------------------------------------------------------------

do
    -- A complete provider passes.
    local good = {
        id = function() return "x" end,
        display_name = function() return "X" end,
        is_available = function() return true end,
        syncable_providers = function() return {} end,
        sync = function() end,
    }
    local ok = Interface.validate_implementation(good)
    h.assert_true(ok, "complete provider validates")

    -- Missing one method fails and names it.
    local bad = {
        id = function() return "x" end,
        display_name = function() return "X" end,
        is_available = function() return true end,
        -- syncable_providers missing
        sync = function() end,
    }
    local ok2, problems = Interface.validate_implementation(bad)
    h.assert_false(ok2, "incomplete provider fails validation")
    h.assert_true(type(problems) == "table" and #problems >= 1,
        "problems list is non-empty")
    local mentions = false
    for _, p in ipairs(problems) do
        if p:match("syncable_providers") then mentions = true end
    end
    h.assert_true(mentions, "the missing method is named in problems")

    -- Non-table fails cleanly.
    local ok3 = Interface.validate_implementation("not a table")
    h.assert_false(ok3, "non-table fails validation")
end


-- ----------------------------------------------------------------------------
-- SyncServiceProvider: identity + availability + syncable set
-- ----------------------------------------------------------------------------

do
    local fake = make_fake_service()
    local p = SyncServiceProvider.new({ sync_service = fake.module })

    h.assert_equal(p.id(), "syncservice", "syncservice id")
    h.assert_true(type(p.display_name()) == "string" and p.display_name() ~= "",
        "syncservice has a display name")
    h.assert_true(p.is_available(), "available when sync_service injected")

    local sp = p.syncable_providers()
    h.assert_true(sp.dropbox == true, "dropbox is syncable on syncservice")
    h.assert_true(sp.webdav == true, "webdav is syncable on syncservice")
    h.assert_nil(sp.ftp, "FTP is NOT syncable on syncservice")

    -- Returned set is a copy: mutating it must not affect later calls.
    sp.dropbox = nil
    local sp2 = p.syncable_providers()
    h.assert_true(sp2.dropbox == true, "syncable set is a fresh copy each call")
end

do
    -- Without an injected service AND with the real module unloadable
    -- (the spec harness has no apps/cloudstorage/syncservice), the
    -- provider reports unavailable rather than crashing.
    local p = SyncServiceProvider.new({})
    h.assert_false(p.is_available(),
        "unavailable when neither injected nor requireable")
end


-- ----------------------------------------------------------------------------
-- SyncServiceProvider.sync: dispatches through the adapter to SyncService
-- ----------------------------------------------------------------------------

do
    local fake = make_fake_service()
    local p = SyncServiceProvider.new({ sync_service = fake.module })

    local got_ok, got_err
    p.sync(
        { type = "dropbox", url = "/books" },
        "/tmp/staged_envelope.json",
        function() return true end, -- merge_cb (not invoked by the fake)
        function(ok, err) got_ok, got_err = ok, err end
    )

    h.assert_true(got_ok, "sync dispatched ok")
    h.assert_nil(got_err, "no error on successful dispatch")
    h.assert_equal(#fake.calls, 1, "exactly one SyncService.sync call")
    h.assert_equal(fake.calls[1].path, "/tmp/staged_envelope.json",
        "staged path forwarded to the service")
    h.assert_equal(fake.calls[1].server.type, "dropbox",
        "server forwarded to the service")
    h.assert_true(fake.calls[1].has_merge_cb, "merge callback forwarded")
    h.assert_true(fake.calls[1].suppress, "is_silent passed as true")
end


-- ----------------------------------------------------------------------------
-- Selector: there is ONE backend — the "Cloud storage+" plugin, reached via
-- the ui_cloudstorage_resolver.  syncservice survives ONLY as an invisible
-- fallback used when the plugin is unavailable.  No setting, no user choice,
-- no requested_id.
-- ----------------------------------------------------------------------------

do
    -- Exposed ids for introspection.
    h.assert_equal(CloudProviders.PRIMARY_ID, "cloudstorage", "primary id is cloudstorage")
    h.assert_equal(CloudProviders.FALLBACK_ID, "syncservice", "fallback id is syncservice")
end

do
    -- Plugin present (resolver yields a ui.cloudstorage exposing :sync) →
    -- cloudstorage is the active backend, no fallback.
    local sel = CloudProviders.select({
        ui_cloudstorage_resolver = function() return { sync = function() end } end,
    })
    h.assert_equal(sel.active_id, "cloudstorage", "cloudstorage active when the plugin is present")
    h.assert_false(sel.fell_back, "no fallback when the plugin is available")
    h.assert_true(sel.provider ~= nil and sel.provider.id() == "cloudstorage",
        "selector returns the cloudstorage provider instance")
    h.assert_nil(sel.requested_id, "no requested_id (there is no user choice)")
end

do
    -- Plugin absent (no resolver) → invisible fallback to the built-in
    -- syncservice, fell_back flagged.  A fake service makes the floor
    -- available in the headless harness.
    local fake = make_fake_service()
    local sel = CloudProviders.select({
        sync_service = fake.module,
    })
    h.assert_equal(sel.active_id, "syncservice", "falls back to syncservice when the plugin is absent")
    h.assert_true(sel.fell_back, "fell_back set on the invisible syncservice fallback")
    h.assert_true(sel.provider ~= nil and sel.provider.id() == "syncservice",
        "selector returns the syncservice floor provider")
end

do
    -- A resolver that yields nil (plugin disabled at runtime) is treated the
    -- same as absent → syncservice fallback.
    local fake = make_fake_service()
    local sel = CloudProviders.select({
        ui_cloudstorage_resolver = function() return nil end,
        sync_service             = fake.module,
    })
    h.assert_equal(sel.active_id, "syncservice", "resolver->nil also falls back to syncservice")
    h.assert_true(sel.fell_back, "fell_back set when the resolver yields nil")
end

do
    -- REGRESSION GUARD: the plugin is PREFERRED whenever available.  If the
    -- selector ever returned the syncservice fallback while the plugin
    -- resolves, these assertions fail (they catch the break "return the
    -- fallback unconditionally").
    local fake = make_fake_service()
    local sel = CloudProviders.select({
        ui_cloudstorage_resolver = function() return { sync = function() end } end,
        sync_service             = fake.module,  -- present, but must NOT be chosen
    })
    h.assert_equal(sel.active_id, "cloudstorage",
        "plugin wins over the available fallback (no spurious fall-back)")
    h.assert_false(sel.fell_back, "fell_back stays false when the plugin is available")
end
