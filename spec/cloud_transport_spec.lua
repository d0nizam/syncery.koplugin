-- =============================================================================
-- spec/cloud_transport_spec.lua
-- =============================================================================
--
-- Integration tests for the Cloud transport.  Injects fakes for the
-- adapter factory, the file writer/reader, the staging dir resolver,
-- and the dir-ensure hook.  No real filesystem, no real SyncService.
--
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_cloud_transport_spec_" .. tostring(os.time()))

local Transport = require("syncery_transports/cloud/transport")
local Interface = require("syncery_transports/interface")


-- ----------------------------------------------------------------------------
-- Helpers.
-- ----------------------------------------------------------------------------


local function settings_for(t)
    return function(key) return t[key] end
end


local function make_fake_fs()
    local rec = {
        files       = {},   -- path → content (last write wins)
        writes      = {},   -- list of {path, content}
        reads       = {},   -- list of paths read
        ensured     = {},   -- list of dirs that ensure_dir was called on
        write_ok    = true,
        read_returns = nil, -- if set, file_reader returns this regardless
    }
    function rec.writer(path, content)
        if not rec.write_ok then return false, "disk full" end
        rec.files[path] = content
        table.insert(rec.writes, { path = path, content = content })
        return true
    end
    function rec.reader(path)
        table.insert(rec.reads, path)
        if rec.read_returns ~= nil then return rec.read_returns end
        return rec.files[path]
    end
    function rec.ensure_dir(dir)
        table.insert(rec.ensured, dir)
        return true
    end
    return rec
end


-- A fake cloud PROVIDER + a selector that returns it.  After the Step 2
-- refactor the transport consumes a provider (not a SyncService adapter):
-- it calls provider.syncable_providers() for the syncable check and
-- provider.sync(server, staged_path, merge_cb, cb) to dispatch.  This
-- fake records each sync() call so we can assert the transport drove the
-- provider correctly, without touching the network, the real
-- syncservice, or re-testing the syncservice provider (covered in
-- cloud_providers_spec).
local function make_fake_provider(cfg)
    cfg = cfg or {}
    local rec = {
        syncs       = {},   -- recorded provider.sync() calls
        default_ok  = (cfg.ok ~= false),
        default_err = cfg.err,
        syncable    = cfg.syncable or { dropbox = true, webdav = true },
        active_id   = cfg.active_id or "syncservice",
        fell_back   = cfg.fell_back or false,
    }
    rec.provider = {
        id           = function() return rec.active_id end,
        display_name = function() return "Fake provider" end,
        is_available = function() return true end,
        syncable_providers = function()
            -- Fresh copy so the transport can't mutate our set.
            local c = {}
            for k, v in pairs(rec.syncable) do c[k] = v end
            return c
        end,
        sync = function(server, staged_path, merge_cb, callback)
            table.insert(rec.syncs, {
                path         = staged_path,
                server_kind  = server and server.kind,
                server_type  = server and server.type,
                has_merge_cb = type(merge_cb) == "function",
            })
            callback(rec.default_ok, rec.default_err)
        end,
    }
    -- A selector matching CloudProviders.select's shape.
    rec.selector = function(_opts)
        return {
            provider     = rec.provider,
            active_id    = rec.active_id,
            fell_back    = rec.fell_back,
        }
    end
    return rec
end


local function valid_settings()
    return {
        syncery_use_cloud  = true,
        -- Real syncservice server objects carry `type` (verified 18.10: dropbox
        -- is {name,password,address,url,type}). The transport's provider
        -- validation (F1) keys off `type`.
        syncery_cloud_server    = { type = "dropbox", kind = "dropbox" },
    }
end


-- ----------------------------------------------------------------------------
-- Conformance.
-- ----------------------------------------------------------------------------


do
    local t = Transport.new({
        settings_reader = settings_for(valid_settings()),
        select_provider = make_fake_provider().selector,
    })
    local ok, problems = Interface.validate_implementation(t)
    h.assert_true(ok,                          "cloud transport satisfies interface")
    h.assert_equal(#problems, 0,               "no validation problems")
end


-- ----------------------------------------------------------------------------
-- Identity + eventually-consistent flag.
-- ----------------------------------------------------------------------------


do
    local t = Transport.new({
        settings_reader = settings_for(valid_settings()),
        select_provider = make_fake_provider().selector,
    })
    h.assert_equal(t.id(), "cloud",                       "stable id")
    h.assert_equal(t.display_name(), "Cloud",             "display name")
    h.assert_true(t.is_eventually_consistent(),
        "cloud is eventually consistent (SyncService dispatches async)")
end


-- ----------------------------------------------------------------------------
-- is_available: toggle + server picker.
-- ----------------------------------------------------------------------------


do
    local t = Transport.new({ settings_reader = settings_for({}) })
    h.assert_false(t.is_available(), "no settings → unavailable")
end


do
    local t = Transport.new({
        settings_reader = settings_for({ syncery_use_cloud = true }),
    })
    h.assert_false(t.is_available(), "toggle without server → unavailable")
end


do
    local t = Transport.new({
        settings_reader = settings_for(valid_settings()),
        select_provider = make_fake_provider().selector,
    })
    h.assert_true(t.is_available(), "all conditions met → available")
end


do
    -- COLLAPSE GUARD: is_available() reads the canonical `syncery_use_cloud`
    -- key, NOT the old `syncery_sync_via_cloud` mirror.  Wizard-divergence
    -- state: use_=false (user picked another transport), a stale sync_via_=true
    -- lingers, the server is still configured.  Available MUST follow use_=false;
    -- reading sync_via_=true resurrects the bug (label "ready" while unchecked).
    local t = Transport.new({
        settings_reader = settings_for({
            syncery_use_cloud      = false,
            syncery_sync_via_cloud = true,   -- stale mirror, must be IGNORED
            syncery_cloud_server   = { type = "dropbox", kind = "dropbox" },
        }),
    })
    h.assert_false(t.is_available(),
        "is_available follows use_cloud=false, ignoring a stale sync_via_cloud=true (collapse)")
end


-- ----------------------------------------------------------------------------
-- Canonical state enum: ONE verdict in status(), every other field derives
-- from it.  disabled | no_server | no_backend | unsupported | ready.
-- ----------------------------------------------------------------------------


do  -- disabled
    local t = Transport.new({ settings_reader = settings_for({}),
        select_provider = make_fake_provider().selector })
    h.assert_equal(t.status().state, "disabled", "state: toggle off -> disabled")
end

do  -- no_server
    local t = Transport.new({ settings_reader = settings_for({ syncery_use_cloud = true }),
        select_provider = make_fake_provider().selector })
    h.assert_equal(t.status().state, "no_server", "state: no destination -> no_server")
end

do  -- no_backend: server picked, provider reports unavailable
    local t = Transport.new({ settings_reader = settings_for(valid_settings()),
        select_provider = function()
            return { provider = {
                id                 = function() return "syncservice" end,
                is_available       = function() return false end,
                syncable_providers = function() return { dropbox = true, webdav = true } end,
            }, active_id = "syncservice", fell_back = true }
        end })
    local s = t.status()
    h.assert_equal(s.state, "no_backend", "state: server picked, no backend -> no_backend")
    h.assert_true(s.backend_unavailable == true, "no_backend derives backend_unavailable")
    h.assert_nil(s.unsupported_provider, "no_backend suppresses unsupported (precedence)")
    h.assert_false(s.available, "no_backend derives available=false")
end

do  -- unsupported: ftp, available provider that can't sync ftp
    local t = Transport.new({ settings_reader = settings_for({
        syncery_use_cloud = true, syncery_cloud_server = { type = "ftp", kind = "ftp" } }),
        select_provider = make_fake_provider().selector })
    local s = t.status()
    h.assert_equal(s.state, "unsupported", "state: ftp on syncservice -> unsupported")
    h.assert_true(s.unsupported_provider == true, "unsupported derives its flag")
    h.assert_nil(s.backend_unavailable, "unsupported is not backend_unavailable")
end

do  -- ready
    local t = Transport.new({ settings_reader = settings_for(valid_settings()),
        select_provider = make_fake_provider().selector })
    local s = t.status()
    h.assert_equal(s.state, "ready", "state: all good -> ready")
    h.assert_true(s.available, "ready derives available=true")
end


-- ----------------------------------------------------------------------------
-- push happy path: stages to disk, dispatches through adapter.
-- ----------------------------------------------------------------------------


do
    local fs        = make_fake_fs()
    local prov      = make_fake_provider()
    local t = Transport.new({
        settings_reader = settings_for(valid_settings()),
        select_provider = prov.selector,
        file_writer     = fs.writer,
        file_reader     = fs.reader,
        ensure_dir      = fs.ensure_dir,
        staging_dir_fn  = function() return "/data/staging" end,
    })

    local got_ok
    t.push("/books/x.epub", {
        payload = {
            kind    = "progress",
            book_id = "abc123",
            content = '{"page":42}',
        },
    }, function(ok) got_ok = ok end)

    h.assert_true(got_ok,                                "push ok")
    h.assert_equal(#fs.writes, 1,                         "one staged write")
    h.assert_equal(fs.writes[1].path,
        "/data/staging/syncery-progress-abc123.json",
        "staged at the canonical path")
    h.assert_equal(fs.writes[1].content, '{"page":42}',    "content was staged")
    h.assert_equal(#prov.syncs, 1,                        "one sync dispatched")
    h.assert_equal(prov.syncs[1].path,
        "/data/staging/syncery-progress-abc123.json",
        "provider received the staged path")
    h.assert_equal(prov.syncs[1].server_kind, "dropbox",
        "server passed through to the provider")
    h.assert_true(prov.syncs[1].has_merge_cb,
        "kind-aware merge callback forwarded to the provider")
end


-- ----------------------------------------------------------------------------
-- push rejects malformed payloads.
-- ----------------------------------------------------------------------------


do
    local fs = make_fake_fs()
    local prov = make_fake_provider()
    local t = Transport.new({
        settings_reader = settings_for(valid_settings()),
        select_provider = prov.selector,
        file_writer     = fs.writer,
        ensure_dir      = fs.ensure_dir,
        staging_dir_fn  = function() return "/staging" end,
    })

    -- No payload at all.
    local got_err
    t.push("/x", {}, function(_ok, err) got_err = err end)
    h.assert_equal(got_err, Interface.ERRORS.REJECTED, "missing payload rejected")

    -- Payload missing content.
    t.push("/x", { payload = { kind = "progress", book_id = "a" }},
        function(_ok, err) got_err = err end)
    h.assert_equal(got_err, Interface.ERRORS.REJECTED, "missing content rejected")

    -- Payload with unknown kind.
    t.push("/x", { payload = { kind = "garbage", book_id = "a", content = "{}" }},
        function(_ok, err) got_err = err end)
    h.assert_equal(got_err, Interface.ERRORS.REJECTED, "unknown kind rejected")

    -- Payload with malformed book_id.
    t.push("/x", { payload = { kind = "progress", book_id = "a/b", content = "{}" }},
        function(_ok, err) got_err = err end)
    h.assert_equal(got_err, Interface.ERRORS.REJECTED, "malformed book_id rejected")

    h.assert_equal(#fs.writes, 0,        "no writes attempted on rejected payloads")
    h.assert_equal(#prov.syncs, 0,        "no syncs dispatched")
end


-- ----------------------------------------------------------------------------
-- push: write failure → INTERNAL.
-- ----------------------------------------------------------------------------


do
    local fs = make_fake_fs()
    fs.write_ok = false
    local prov = make_fake_provider()
    local t = Transport.new({
        settings_reader = settings_for(valid_settings()),
        select_provider = prov.selector,
        file_writer     = fs.writer,
        ensure_dir      = fs.ensure_dir,
        staging_dir_fn  = function() return "/staging" end,
    })

    local got_err
    t.push("/x", { payload = { kind = "progress", book_id = "a", content = "{}" }},
        function(_ok, err) got_err = err end)
    h.assert_equal(got_err, Interface.ERRORS.INTERNAL, "write fail → INTERNAL")
    h.assert_equal(#prov.syncs, 0, "no sync after failed stage")
end


-- ----------------------------------------------------------------------------
-- push: provider failure propagates.
-- ----------------------------------------------------------------------------


do
    local fs = make_fake_fs()
    local prov = make_fake_provider({ ok = false, err = Interface.ERRORS.UNREACHABLE })
    local t = Transport.new({
        settings_reader = settings_for(valid_settings()),
        select_provider = prov.selector,
        file_writer     = fs.writer,
        ensure_dir      = fs.ensure_dir,
        staging_dir_fn  = function() return "/staging" end,
    })

    local got_err
    t.push("/x", { payload = { kind = "progress", book_id = "a", content = "{}" }},
        function(_ok, err) got_err = err end)
    h.assert_equal(got_err, Interface.ERRORS.UNREACHABLE,
        "provider error propagates")
end


-- ----------------------------------------------------------------------------
-- pull WITH content: SyncService.sync is bidirectional, so a pull that
-- carries the device's canonical content runs the SAME single sync as push —
-- it stages the content and dispatches one upload (the merge callback pulls
-- remote in and reconciles). The old "stage nothing, read back the staged
-- file" model was broken and is gone (PROJECT_PLAN.md 18.12.12).
-- ----------------------------------------------------------------------------


do
    local fs        = make_fake_fs()
    local prov      = make_fake_provider()
    local t = Transport.new({
        settings_reader = settings_for(valid_settings()),
        select_provider = prov.selector,
        file_writer     = fs.writer,
        ensure_dir      = fs.ensure_dir,
        staging_dir_fn  = function() return "/staging" end,
    })

    local got_ok
    t.pull("/x", {
        payload = { kind = "annotations", book_id = "abc", content = '{"annotations":{}}' },
    }, function(ok) got_ok = ok end)

    h.assert_true(got_ok,                         "pull-with-content runs the bidirectional sync")
    h.assert_equal(#fs.writes, 1,                  "pull staged the canonical content")
    h.assert_equal(fs.writes[1].path,
        "/staging/syncery-annotations-abc.json",   "staged at the canonical path")
    h.assert_equal(#prov.syncs, 1,                 "one sync dispatched via the provider")
    h.assert_true(prov.syncs[1].has_merge_cb,
        "merge callback wired into the provider for the sync")
end


-- ----------------------------------------------------------------------------
-- pull WITHOUT content: nothing to stage for the bidirectional sync, so we
-- report success-with-no-data rather than fabricating an empty upload that
-- could touch the cloud copy.
-- ----------------------------------------------------------------------------


do
    local fs = make_fake_fs()
    local prov = make_fake_provider()
    local t = Transport.new({
        settings_reader = settings_for(valid_settings()),
        select_provider = prov.selector,
        file_writer     = fs.writer,
        ensure_dir      = fs.ensure_dir,
        staging_dir_fn  = function() return "/staging" end,
    })

    local got_ok, got_err, got_payload
    t.pull("/x", { payload = { kind = "progress", book_id = "a" }},
        function(ok, err, payload) got_ok, got_err, got_payload = ok, err, payload end)

    h.assert_true(got_ok,    "content-less pull reports success")
    h.assert_nil(got_err,    "no error")
    h.assert_nil(got_payload, "no payload (caller branches on nil)")
    h.assert_equal(#fs.writes, 0,        "content-less pull stages nothing")
    h.assert_equal(#prov.syncs, 0, "content-less pull dispatches no sync (no empty-over-cloud)")
end


-- ----------------------------------------------------------------------------
-- Trigger-order / no-stale-sync (PROJECT_PLAN.md 18.12.12): cloud_sync must
-- stage exactly the content it is handed on THIS call, never a cached/earlier
-- value. The orchestrator reads the canonical file AFTER the save flush and
-- passes that content here; this pins that a later call with new content
-- stages the NEW content (so we sync what was written, not what was there).
-- ----------------------------------------------------------------------------


do
    local fs        = make_fake_fs()
    local prov      = make_fake_provider()
    local t = Transport.new({
        settings_reader = settings_for(valid_settings()),
        select_provider = prov.selector,
        file_writer     = fs.writer,
        ensure_dir      = fs.ensure_dir,
        staging_dir_fn  = function() return "/staging" end,
    })

    t.push("/books/x.epub",
        { payload = { kind = "progress", book_id = "abc", content = '{"page":10}' } },
        function() end)
    t.push("/books/x.epub",
        { payload = { kind = "progress", book_id = "abc", content = '{"page":20}' } },
        function() end)

    h.assert_equal(#fs.writes, 2,                       "two syncs, two stagings")
    h.assert_equal(fs.writes[1].content, '{"page":10}', "first sync staged first content")
    h.assert_equal(fs.writes[2].content, '{"page":20}', "second sync staged the NEW content (no stale)")
    -- The staging path is stable per (kind, book_id); last write wins on disk.
    h.assert_equal(fs.files["/staging/syncery-progress-abc.json"], '{"page":20}',
        "staged file holds the latest content, not the earlier one")
end


do
    local t = Transport.new({ settings_reader = settings_for({}) })
    local s = t.status()
    h.assert_equal(s.display_name, "Cloud",         "display name")
    h.assert_false(s.available,                      "unavailable")
    h.assert_true(s.summary:match("disabled") ~= nil, "disabled summary")
end


do
    local t = Transport.new({
        settings_reader = settings_for(valid_settings()),
        select_provider = make_fake_provider().selector,
    })
    h.assert_true(t.status().available, "available when toggled + server set")
    for _, cap in pairs(Interface.CAPABILITIES) do
        h.assert_false(t.supports(cap),
            "no support for " .. cap)
    end
end


-- ----------------------------------------------------------------------------
-- F1: provider validation. SyncService.sync accepts only dropbox & webdav;
-- the cloud browser also allows FTP. A picked-but-unsyncable provider must be
-- reported as unavailable with a clear reason — not a false "ready".
-- ----------------------------------------------------------------------------


do
    -- webdav is syncable.
    local t = Transport.new({
        settings_reader = settings_for({
            syncery_use_cloud = true,
            syncery_cloud_server   = { type = "webdav", kind = "webdav" },
        }),
        select_provider = make_fake_provider().selector,
    })
    h.assert_true(t.is_available(), "webdav provider is syncable")
end

do
    -- ftp is browsable but NOT syncable -> unavailable + clear status.  Inject an
    -- AVAILABLE provider (syncable = dropbox/webdav, no ftp) so state resolves to
    -- "unsupported", not "no_backend".
    local t = Transport.new({
        settings_reader = settings_for({
            syncery_use_cloud = true,
            syncery_cloud_server   = { type = "ftp", kind = "ftp" },
        }),
        select_provider = make_fake_provider().selector,
    })
    h.assert_false(t.is_available(), "ftp provider is NOT syncable -> unavailable")
    local s = t.status()
    h.assert_false(s.available, "ftp: status unavailable")
    h.assert_true(s.summary:match("not supported") ~= nil,
        "ftp: status explains provider not supported for sync")
    -- Structured flag for UI consumers (so they don't parse the summary).
    h.assert_true(s.unsupported_provider == true,
        "ftp: structured unsupported_provider flag set")
    h.assert_equal(s.provider_type, "ftp", "ftp: provider_type exposed")
end

do
    -- A picked, SYNCABLE provider must NOT set the unsupported flag.
    local t = Transport.new({ settings_reader = settings_for(valid_settings()) })
    local s = t.status()
    h.assert_nil(s.unsupported_provider, "dropbox: no unsupported_provider flag")
end

do
    -- No server picked: unavailable, but NOT flagged as unsupported (it's a
    -- different state — nothing picked vs picked-but-wrong).
    local t = Transport.new({
        settings_reader = settings_for({ syncery_use_cloud = true }),
    })
    local s = t.status()
    h.assert_false(s.available, "no server: unavailable")
    h.assert_nil(s.unsupported_provider,
        "no server: NOT flagged unsupported (distinct from picked-but-wrong)")
    h.assert_true(s.summary:match("not picked") ~= nil or s.summary:match("not configured") ~= nil,
        "no server: summary says not configured/picked")
end

do
    -- A server object with no `type` field is treated as unsyncable.
    local t = Transport.new({
        settings_reader = settings_for({
            syncery_use_cloud = true,
            syncery_cloud_server   = { kind = "dropbox" },  -- no .type
        }),
    })
    h.assert_false(t.is_available(), "server without .type -> not syncable")
end

do
    -- A push to a server type the active provider can't sync is rejected
    -- before staging. The fake provider's syncable set is {dropbox, webdav}
    -- (the syncservice default), so a picked FTP server is unsyncable here.
    local fs = make_fake_fs()
    local prov = make_fake_provider()  -- syncable = { dropbox, webdav }
    local t = Transport.new({
        settings_reader = settings_for({
            syncery_use_cloud = true,
            syncery_cloud_server   = { type = "ftp" },
        }),
        select_provider = prov.selector,
        file_writer     = fs.writer,
        ensure_dir      = fs.ensure_dir,
        staging_dir_fn  = function() return "/staging" end,
    })
    local got_err
    t.push("/x", { payload = { kind = "progress", book_id = "a", content = "{}" }},
        function(_ok, err) got_err = err end)
    h.assert_equal(got_err, Interface.ERRORS.NOT_AVAILABLE,
        "push to unsyncable provider -> NOT_AVAILABLE, no staging")
    h.assert_equal(#fs.writes, 0, "no staging write for unsyncable provider")
    h.assert_equal(#prov.syncs, 0, "no dispatch to an unsyncable provider")
end


-- ----------------------------------------------------------------------------
-- Phase 19 Step 2: status() surfaces the ACTIVE cloud backend + fallback.
-- The transport reads these from the provider selection so the UI (a later
-- step) can show which backend is live and whether the user's chosen backend
-- was unavailable. Behaviour is otherwise identical to 4.6.0 (default
-- syncservice); these fields are additive and nil-safe.
-- ----------------------------------------------------------------------------


do
    -- Selector reports syncservice active, no fallback.
    local prov = make_fake_provider({ active_id = "syncservice", fell_back = false })
    local t = Transport.new({
        settings_reader = settings_for(valid_settings()),
        select_provider = prov.selector,
    })
    local s = t.status()
    h.assert_equal(s.cloud_provider, "syncservice", "status exposes active backend id")
    h.assert_nil(s.provider_fell_back, "no fallback flag when backend is the requested one")
end


do
    -- Selector reports a fallback to syncservice (e.g. cloudstorage requested but
    -- unavailable). The transport must surface fell_back so the UI can warn.
    local prov = make_fake_provider({ active_id = "syncservice", fell_back = true })
    local t = Transport.new({
        settings_reader = settings_for(valid_settings()),
        select_provider = prov.selector,
    })
    local s = t.status()
    h.assert_equal(s.cloud_provider, "syncservice", "fallback: active backend id is syncservice")
    h.assert_true(s.provider_fell_back == true, "fallback: provider_fell_back flag set")
end


-- ----------------------------------------------------------------------------
-- Phase 19 Step 4 fallback scenario, end-to-end via the REAL selector:
-- a plain-KOReader user (no "Cloud storage+" plugin → ui_cloudstorage_resolver
-- yields nil) picks "cloudstorage" for an FTP server. The real CloudProviders
-- selector falls back to syncservice (which CANNOT sync FTP), so status() must
-- surface BOTH provider_fell_back AND unsupported_provider, and report
-- unavailable. This is the exact failure mode the menu's "(unavailable — using
-- Cloud storage)" annotation warns about; locking it with the real selector (not a
-- fake) proves the chain transport → selector → providers end-to-end.
-- ----------------------------------------------------------------------------


do
    local t = Transport.new({
        settings_reader = settings_for({
            syncery_use_cloud = true,
            syncery_cloud_server   = { type = "ftp" },
        }),
        ui_cloudstorage_resolver = function() return nil end,  -- cloudstorage absent
        -- no select_provider → uses the real CloudProviders.select
        -- no sync_service → syncservice's real require fails in-harness, but the
        --   selector's fallback returns the syncservice provider regardless.
    })
    local s = t.status()
    h.assert_false(s.available, "ftp + cloudstorage-absent: transport unavailable")
    h.assert_equal(s.cloud_provider, "syncservice", "fell back to the syncservice backend")
    -- The fallback note is only claimed when the fallback backend actually
    -- works: here the syncservice can't load either (state=no_backend), so
    -- provider_fell_back must NOT tell the status panel "using built-in
    -- cloud sync" alongside the no-backend verdict.
    h.assert_nil(s.provider_fell_back,
        "fell_back suppressed when the fallback backend itself is unusable")
    -- With the canonical state, "no backend available" takes precedence over
    -- "unsupported": in-harness the syncservice fallback can't load, so there is
    -- no working backend at all -> state=no_backend (backend_unavailable), which
    -- is the more actionable verdict (install/enable a backend) than "ftp
    -- unsupported".  (In production, with syncservice present, the same ftp server
    -- would resolve to state=unsupported.)
    h.assert_equal(s.state, "no_backend",
        "no working backend in-harness → state=no_backend (precedes unsupported)")
    h.assert_true(s.backend_unavailable == true, "backend_unavailable flag set")
    h.assert_nil(s.unsupported_provider,
        "unsupported suppressed when there is no backend at all")
end


-- ----------------------------------------------------------------------------
-- The PRODUCTION default ensure_dir actually creates the directory.
--
-- Regression lock for the staging-dir bug: init.lua constructs the transport
-- WITHOUT an ensure_dir, so the default runs in production.  The old default
-- was a no-op that returned true without creating the dir, so the staging
-- write (a bare io.open that does not create parents) failed with INTERNAL
-- on every cloud push.  This proves the default makes the directory exist.
-- ----------------------------------------------------------------------------

do
    local base = "/tmp/syncery_default_ensure_dir_" .. tostring(os.time())
    local dir  = base .. "/cloud_staging"
    os.execute("rm -rf '" .. base .. "'")

    local ok = Transport._default_ensure_dir(dir)
    h.assert_true(ok, "default ensure_dir reports success")

    -- Verify the directory truly exists by writing a file INTO it (portable,
    -- no lfs dependency).  Under the no-op default this io.open fails because
    -- the parent dir was never created.
    local probe = dir .. "/probe"
    local f = io.open(probe, "w")
    h.assert_true(f ~= nil,
        "default ensure_dir actually created the directory (a file opens inside it)")
    if f then f:close() end

    -- Idempotent: a second call on the existing dir still succeeds (mkdir -p).
    h.assert_true(Transport._default_ensure_dir(dir),
        "default ensure_dir is idempotent on an existing directory")

    -- Empty / nil paths are rejected, not silently "succeeded".
    h.assert_false(Transport._default_ensure_dir(""),  "empty path rejected")
    h.assert_false(Transport._default_ensure_dir(nil), "nil path rejected")

    os.execute("rm -rf '" .. base .. "'")
end


-- ----------------------------------------------------------------------------
-- on_server_responded: the merge callback running (the provider DOWNLOADED the
-- remote object == the server is reachable) fires the hook; a bare dispatch
-- does NOT.  This is how the cloud-reachability verdict learns the server is
-- up without a synchronous probe; see CloudReachability.note_success.
-- ----------------------------------------------------------------------------
do
    local responded = 0
    local fp = make_fake_provider()
    -- Override sync to INVOKE the (wrapped) merge callback, simulating a
    -- download+merge.  The real merge is pcall-isolated here so the test does
    -- not depend on any on-disk canonical file.
    fp.provider.sync = function(_server, _path, merge_cb, callback)
        pcall(merge_cb, "/tmp/ctspec_lf", "/tmp/ctspec_cf", "/tmp/ctspec_if")
        callback(true, nil)
    end
    local t = Transport.new({
        settings_reader     = settings_for(valid_settings()),
        select_provider     = fp.selector,
        on_server_responded = function() responded = responded + 1 end,
    })
    t.push("/x", { payload = { kind = "progress", book_id = "a", content = "{}" } },
        function() end)
    h.assert_equal(responded, 1,
        "on_server_responded fires exactly once when the merge callback runs")

    -- It must NOT fire on dispatch alone (the default fake sync calls callback
    -- but never merge_cb): a clean dispatch is not proof of reachability.
    local responded2 = 0
    local fp2 = make_fake_provider()
    local t2 = Transport.new({
        settings_reader     = settings_for(valid_settings()),
        select_provider     = fp2.selector,
        on_server_responded = function() responded2 = responded2 + 1 end,
    })
    t2.push("/x", { payload = { kind = "progress", book_id = "a", content = "{}" } },
        function() end)
    h.assert_equal(responded2, 0,
        "on_server_responded does NOT fire on dispatch alone (merge_cb never ran)")
end
