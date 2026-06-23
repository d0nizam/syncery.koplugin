-- =============================================================================
-- spec/cloudstorage_provider_spec.lua
-- =============================================================================
--
-- Tests for the cloudstorage cloud provider
-- (syncery_transports/cloud/providers/cloudstorage_provider.lua) and its
-- registration in the selector.
--
-- The provider dispatches through `ui.cloudstorage:sync(...)`.  Since the
-- real "Cloud storage+" plugin isn't loadable here (and Risk 1 means we
-- can't run it on a device pre-emptively), the fake `ui.cloudstorage`
-- below FAITHFULLY MODELS the master Cloud:sync behaviour verified against
-- _cloudstorage_master/main.lua: the 412 re-download/re-merge/re-upload loop,
-- the per-type download-abort exceptions (dropbox 409, ftp 550), the
-- `upload or 412` (FTP returns nil on failure), and the
-- download -> merge_cb(file_path, cached, income) -> upload ordering with
-- income == path..".temp" and cached == path..".sync".  Modelling it
-- synchronously (no UIManager/nextTick) lets us assert deterministically.
--
-- KEY SEMANTIC under test: Cloud:sync is FIRE-AND-FORGET — it shows its
-- own toasts and never calls the caller back.  So the provider reports
-- (true, nil) = "dispatched" whenever the call returns without raising,
-- REGARDLESS of whether the modelled sync internally succeeded or aborted
-- — exactly like the syncservice provider.  Errors only arise when there is
-- no usable instance (NOT_AVAILABLE) or the call itself raises (INTERNAL).
--
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_cloudstorage_provider_spec_" .. tostring(os.time()))

local CloudStorageProvider = require("syncery_transports/cloud/providers/cloudstorage_provider")
local CloudProviders     = require("syncery_transports/cloud/providers")
local TransportInterface = require("syncery_transports/interface")
local Interface          = require("syncery_transports/cloud/providers/interface")


-- ----------------------------------------------------------------------------
-- A fake `ui.cloudstorage` that models master Cloud:sync (see header).
--
-- cfg:
--   download_results — list of {code, etag} returned by successive
--                      "downloadFile" passes (default {200,"etag"} forever)
--   upload_results   — list of upload codes (number) or nil (FTP fail)
--                      returned by successive "uploadFile" passes
--                      (default 200 forever)
--   server_type      — fallback type if server has none
--   raise_on_sync    — if true, :sync raises (to exercise INTERNAL mapping)
-- ----------------------------------------------------------------------------
local function make_fake_cloudstorage(cfg)
    cfg = cfg or {}
    local rec = {
        calls             = {},   -- recorded :sync invocations
        merge_invocations = {},   -- recorded sync_cb(file_path, cached, income)
        download_results  = cfg.download_results,
        upload_results    = cfg.upload_results,
        server_type       = cfg.server_type or "dropbox",
        raise_on_sync     = cfg.raise_on_sync,
        outcome           = nil,  -- "success" | "fail" | "download_abort" | "merge_abort"
    }

    function rec:sync(server, file_path, sync_cb, is_silent, pre_cb)
        table.insert(rec.calls, {
            server      = server,
            file_path   = file_path,
            has_sync_cb = type(sync_cb) == "function",
            is_silent   = is_silent,
            has_pre_cb  = (pre_cb ~= nil),
        })
        if rec.raise_on_sync then error("cloudstorage sync boom") end
        if pre_cb then pre_cb() end

        -- Faithful synchronous model of master Cloud:sync.
        local income = file_path .. ".temp"
        local cached = file_path .. ".sync"
        local st     = (server and server.type) or rec.server_type
        local etag
        local code   = 412
        local dl_i, ul_i = 0, 0
        local guard = 0
        rec.outcome = nil

        while code == 412 do
            guard = guard + 1
            if guard > 20 then
                error("fake cloudstorage: 412 loop did not converge (test bug)")
            end
            dl_i = dl_i + 1
            local dl = rec.download_results and rec.download_results[dl_i] or { 200, "etag" }
            code, etag = dl[1], dl[2]
            if code ~= 200 and code ~= 404
                and not (st == "dropbox" and code == 409)
                and not (st == "ftp" and code == 550)
            then
                rec.outcome = "download_abort"
                return
            end
            local ok, cb_return = pcall(sync_cb, file_path, cached, income)
            table.insert(rec.merge_invocations,
                { file_path = file_path, cached = cached, income = income,
                  ok = ok, cb_return = cb_return })
            if not ok or not cb_return then
                rec.outcome = "merge_abort"
                return
            end
            ul_i = ul_i + 1
            -- Default upload succeeds (200); an explicit `false` entry models
            -- an FTP upload returning nil on failure (Lua can't store a nil
            -- hole in a list, so `false` is the FTP-fail sentinel).
            local ul
            if rec.upload_results == nil then
                ul = 200
            else
                ul = rec.upload_results[ul_i]
                if ul == false then ul = nil end
            end
            code = ul or 412   -- master: `provider.uploadFile(...) or 412`
        end

        if type(code) == "number" and code >= 200 and code < 300 then
            rec.outcome = "success"
        else
            rec.outcome = "fail"
        end
    end

    return rec
end


local function resolver_for(obj)
    return function() return obj end
end


-- ----------------------------------------------------------------------------
-- Identity + interface conformance + syncable set (ftp included).
-- ----------------------------------------------------------------------------

do
    local p = CloudStorageProvider.new({ ui_cloudstorage_resolver = resolver_for({ sync = function() end }) })

    local ok = Interface.validate_implementation(p)
    h.assert_true(ok, "cloudstorage provider satisfies the provider interface")

    h.assert_equal(p.id(), "cloudstorage", "cloudstorage id")
    h.assert_true(type(p.display_name()) == "string" and p.display_name() ~= "",
        "cloudstorage has a display name")

    local sp = p.syncable_providers()
    h.assert_true(sp.dropbox == true, "dropbox syncable on cloudstorage")
    h.assert_true(sp.webdav == true, "webdav syncable on cloudstorage")
    h.assert_true(sp.ftp == true,     "FTP IS syncable on cloudstorage (unlike syncservice)")

    -- Returned set is a fresh copy.
    sp.ftp = nil
    local sp2 = p.syncable_providers()
    h.assert_true(sp2.ftp == true, "syncable set is a fresh copy each call")
end


-- ----------------------------------------------------------------------------
-- is_available: needs an instance exposing :sync.
-- ----------------------------------------------------------------------------

do
    local avail = CloudStorageProvider.new({
        ui_cloudstorage_resolver = resolver_for(make_fake_cloudstorage()),
    })
    h.assert_true(avail.is_available(), "available when resolver yields an object with :sync")

    local no_ui = CloudStorageProvider.new({ ui_cloudstorage_resolver = resolver_for(nil) })
    h.assert_false(no_ui.is_available(), "unavailable when resolver yields nil")

    local no_sync = CloudStorageProvider.new({ ui_cloudstorage_resolver = resolver_for({}) })
    h.assert_false(no_sync.is_available(), "unavailable when object lacks a :sync method")

    -- Regression: a fork may wrap :sync as a CALLABLE TABLE (obj:sync(...)
    -- works, but type(obj.sync) == "table").  The old `type(...) == "function"`
    -- gate wrongly reported the backend unavailable → the whole sync fell back
    -- to the Dropbox/WebDAV-only SyncService (no FTP).
    local callable_sync = CloudStorageProvider.new({
        ui_cloudstorage_resolver = resolver_for({
            sync = setmetatable({}, { __call = function() end }),
        }),
    })
    h.assert_true(callable_sync.is_available(),
        "available when :sync is a callable table (not just a plain function)")

    local bad_sync = CloudStorageProvider.new({
        ui_cloudstorage_resolver = resolver_for({ sync = "not callable" }),
    })
    h.assert_false(bad_sync.is_available(),
        "a non-callable truthy :sync is NOT treated as available")

    -- No resolver injected at all → safe default (unavailable).
    local bare = CloudStorageProvider.new({})
    h.assert_false(bare.is_available(), "unavailable with no resolver (safe default)")
end


-- ----------------------------------------------------------------------------
-- Dispatch: forwards (server, staged_path, merge_cb, is_silent=true) to the
-- live instance, the merge callback is invoked with master's 3 paths, and the
-- provider reports (true, nil) = dispatched, exactly once.
-- ----------------------------------------------------------------------------

do
    local fake = make_fake_cloudstorage()  -- default download 200 / upload 200 → success
    local p = CloudStorageProvider.new({ ui_cloudstorage_resolver = resolver_for(fake) })

    local merged = false
    local merge_cb = function(_fp, _cached, _income) merged = true; return true end

    local cb_calls, got_ok, got_err = 0, nil, nil
    p.sync({ type = "dropbox", url = "/books" }, "/tmp/staged.json", merge_cb,
        function(ok, err) cb_calls = cb_calls + 1; got_ok, got_err = ok, err end)

    h.assert_equal(cb_calls, 1, "provider callback fires exactly once")
    h.assert_true(got_ok, "clean dispatch reports ok")
    h.assert_nil(got_err, "no error on dispatch")

    h.assert_equal(#fake.calls, 1, "exactly one ui.cloudstorage:sync call")
    h.assert_equal(fake.calls[1].file_path, "/tmp/staged.json",
        "staged path forwarded to cloudstorage")
    h.assert_equal(fake.calls[1].server.type, "dropbox", "server forwarded")
    h.assert_true(fake.calls[1].has_sync_cb, "merge callback forwarded")
    h.assert_true(fake.calls[1].is_silent, "is_silent passed as true")

    -- Merge callback invoked with master's exact path triple.
    h.assert_true(merged, "merge callback was invoked")
    h.assert_equal(#fake.merge_invocations, 1, "merge invoked once on a single-pass sync")
    h.assert_equal(fake.merge_invocations[1].income, "/tmp/staged.json.temp",
        "income path is staged_path .. .temp (master)")
    h.assert_equal(fake.merge_invocations[1].cached, "/tmp/staged.json.sync",
        "cached path is staged_path .. .sync (master)")
    h.assert_equal(fake.outcome, "success", "modelled sync reached success")
end


-- ----------------------------------------------------------------------------
-- Error mapping: no instance → NOT_AVAILABLE; raising call → INTERNAL.
-- Both fire the callback exactly once.
-- ----------------------------------------------------------------------------

do
    local p = CloudStorageProvider.new({ ui_cloudstorage_resolver = resolver_for(nil) })
    local cb_calls, got_ok, got_err = 0, nil, nil
    p.sync({ type = "dropbox" }, "/tmp/x.json", function() return true end,
        function(ok, err) cb_calls = cb_calls + 1; got_ok, got_err = ok, err end)
    h.assert_equal(cb_calls, 1, "NOT_AVAILABLE path fires callback once")
    h.assert_false(got_ok, "no instance → not ok")
    h.assert_equal(got_err, TransportInterface.ERRORS.NOT_AVAILABLE,
        "no instance maps to NOT_AVAILABLE")
end

do
    local fake = make_fake_cloudstorage({ raise_on_sync = true })
    local p = CloudStorageProvider.new({ ui_cloudstorage_resolver = resolver_for(fake) })
    local cb_calls, got_ok, got_err = 0, nil, nil
    p.sync({ type = "dropbox" }, "/tmp/x.json", function() return true end,
        function(ok, err) cb_calls = cb_calls + 1; got_ok, got_err = ok, err end)
    h.assert_equal(cb_calls, 1, "INTERNAL path fires callback once")
    h.assert_false(got_ok, "raising sync → not ok")
    h.assert_equal(got_err, TransportInterface.ERRORS.INTERNAL,
        "a raising :sync maps to INTERNAL")
end


-- ----------------------------------------------------------------------------
-- Fire-and-forget: even when the modelled sync ABORTS internally (download
-- error or merge refusal), the provider still reports (true, nil) = dispatched,
-- because Cloud:sync never calls back — it only shows a toast.  This mirrors
-- the syncservice provider's "we handed it off" semantics.
-- ----------------------------------------------------------------------------

do
    -- Download error (500): master aborts before merge; provider still dispatched.
    local fake = make_fake_cloudstorage({ download_results = { { 500, nil } } })
    local p = CloudStorageProvider.new({ ui_cloudstorage_resolver = resolver_for(fake) })
    local got_ok, got_err
    p.sync({ type = "dropbox", url = "/b" }, "/tmp/s.json", function() return true end,
        function(ok, err) got_ok, got_err = ok, err end)
    h.assert_true(got_ok, "download-abort still reports dispatched (fire-and-forget)")
    h.assert_nil(got_err, "no error surfaced for an internal abort")
    h.assert_equal(fake.outcome, "download_abort", "model aborted on bad download code")
    h.assert_equal(#fake.merge_invocations, 0, "merge NOT invoked after a download abort")
end

do
    -- Merge refusal (callback returns false): master aborts the upload; provider
    -- still reports dispatched.
    local fake = make_fake_cloudstorage()
    local p = CloudStorageProvider.new({ ui_cloudstorage_resolver = resolver_for(fake) })
    local got_ok
    p.sync({ type = "dropbox", url = "/b" }, "/tmp/s.json",
        function() return false end,  -- refuse
        function(ok) got_ok = ok end)
    h.assert_true(got_ok, "merge-abort still reports dispatched (fire-and-forget)")
    h.assert_equal(fake.outcome, "merge_abort", "model aborted on merge refusal")
end


-- ----------------------------------------------------------------------------
-- Model fidelity to master (locks the fake == verified Cloud:sync, Risk 1
-- Level B). These exercise the model itself; they document the exact syncservice
-- behaviour Syncery relies on so a regression in the model is caught.
-- ----------------------------------------------------------------------------

do
    -- 412 conflict → re-download, re-merge, re-upload until non-412.
    local fake = make_fake_cloudstorage({
        download_results = { { 200, "e1" }, { 200, "e2" } },
        upload_results   = { 412, 200 },   -- first upload conflicts, second wins
    })
    local p = CloudStorageProvider.new({ ui_cloudstorage_resolver = resolver_for(fake) })
    local merges = 0
    p.sync({ type = "dropbox", url = "/b" }, "/tmp/s.json",
        function() merges = merges + 1; return true end, function() end)
    h.assert_equal(merges, 2, "412 loop re-invokes the merge callback (idempotent re-run)")
    h.assert_equal(fake.outcome, "success", "412 loop converges to success")
end

do
    -- FTP 550 on download is NOT an abort (it is the FTP 'first sync' case) —
    -- proceed to merge, then upload.
    local fake = make_fake_cloudstorage({
        server_type      = "ftp",
        download_results = { { 550, nil } },
        upload_results   = { 200 },
    })
    local p = CloudStorageProvider.new({ ui_cloudstorage_resolver = resolver_for(fake) })
    local merged = false
    p.sync({ type = "ftp", url = "ftp://h/b" }, "/tmp/s.json",
        function() merged = true; return true end, function() end)
    h.assert_true(merged, "ftp 550 download proceeds to merge (not an abort)")
    h.assert_equal(fake.outcome, "success", "ftp path reaches success")
end

do
    -- FTP upload returns nil on failure → master's `or 412` retries the loop.
    local fake = make_fake_cloudstorage({
        server_type      = "ftp",
        download_results = { { 200, "e1" }, { 200, "e2" } },
        upload_results   = { false, 200 },   -- first upload fails (nil), retry succeeds
    })
    local p = CloudStorageProvider.new({ ui_cloudstorage_resolver = resolver_for(fake) })
    local merges = 0
    p.sync({ type = "ftp", url = "ftp://h/b" }, "/tmp/s.json",
        function() merges = merges + 1; return true end, function() end)
    h.assert_equal(merges, 2, "nil upload (FTP fail) → 412 retry re-merges")
    h.assert_equal(fake.outcome, "success", "FTP nil-then-ok upload converges")
end


-- ----------------------------------------------------------------------------
-- Selector: "cloudstorage" (the "Cloud storage+" plugin) is THE backend; it is
-- built + selected when available (the resolver yields a usable instance), and
-- falls back to the invisible syncservice floor when the resolver yields
-- nothing.  There is no setting / requested_id.
-- ----------------------------------------------------------------------------

do
    -- Plugin present + available → selected, no fallback.
    local sel = CloudProviders.select({
        ui_cloudstorage_resolver = resolver_for(make_fake_cloudstorage()),
    })
    h.assert_equal(sel.active_id, "cloudstorage", "cloudstorage selected when available")
    h.assert_false(sel.fell_back, "no fallback when cloudstorage is available")
    h.assert_true(sel.provider ~= nil and sel.provider.id() == "cloudstorage",
        "selector returns the cloudstorage provider instance")
    -- And it advertises ftp as syncable.
    h.assert_true(sel.provider.syncable_providers().ftp == true,
        "selected cloudstorage advertises ftp syncable")
end

do
    -- cloudstorage requested but NOT available (resolver yields nil) → fall back
    -- to syncservice WITH the flag set.  syncservice uses an injected fake service so
    -- the (unloadable) real syncservice isn't pulled in and syncservice is
    -- available as the floor.
    local fake_svc = { sync = function() end }
    local sel = CloudProviders.select({
        ui_cloudstorage_resolver = resolver_for(nil),  -- plugin unavailable
        sync_service             = fake_svc,
    })
    h.assert_equal(sel.active_id, "syncservice", "fell back to syncservice when the plugin is unavailable")
    h.assert_true(sel.fell_back, "fell_back flag set")
    h.assert_true(sel.provider ~= nil and sel.provider.id() == "syncservice",
        "fallback returns a usable syncservice provider")
end


-- ----------------------------------------------------------------------------
-- resolve_ui_instance: the pure ReaderUI → backend-instance resolver (the BODY
-- of main.lua's ui_cloudstorage_resolver closure, extracted so the one-liner
-- is regression-locked).  The plugin registers as ui.cloudstorage
-- (ReaderUI:registerModule by plugin name; verified vs koreader/master).
-- ----------------------------------------------------------------------------

do
    local inst = { sync = function() end }
    h.assert_true(CloudStorageProvider.resolve_ui_instance({ cloudstorage = inst }) == inst,
        "resolve_ui_instance: returns ui.cloudstorage when the plugin is present")
    h.assert_nil(CloudStorageProvider.resolve_ui_instance({}),
        "resolve_ui_instance: nil when ui has no .cloudstorage (plugin not loaded)")
    h.assert_nil(CloudStorageProvider.resolve_ui_instance(nil),
        "resolve_ui_instance: nil-safe when the ui itself is absent")
end
