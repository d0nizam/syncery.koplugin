-- =============================================================================
-- spec/syncthing_transport_spec.lua
-- =============================================================================
--
-- Tests for syncery_transports/syncthing/transport.lua.
--
-- The transport has three injectable dependencies (settings_reader,
-- http_client_factory, provider_discover) so these tests touch
-- neither G_reader_settings nor the network nor the real provider
-- chain.  Every test builds a fresh transport with explicit fakes.
--
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_syncthing_transport_spec_" .. tostring(os.time()))

local Transport = require("syncery_transports/syncthing/transport")
local Interface = require("syncery_transports/interface")


-- ----------------------------------------------------------------------------
-- Helpers: build a fake HttpClient + provider for injection.
-- ----------------------------------------------------------------------------


--- Build a fake http_client_factory that records every request and
--- replies according to a script.  Returns:
---   { factory      = function(config) → fake_client,
---     calls        = list of {url, method},  -- populated as requests come in
---     set_response = function(method, path_pattern, ok, err, body) ... }
local function make_fake_http_factory()
    local recorder = { calls = {} }
    local default_response = { ok = true, err = nil, body = "" }

    function recorder.factory(config)
        local client = {}
        function client:get(path, cb)
            table.insert(recorder.calls,
                { method = "GET", url = config.url .. path })
            cb(default_response.ok, default_response.err, default_response.body)
        end
        function client:post(path, cb)
            table.insert(recorder.calls,
                { method = "POST", url = config.url .. path })
            cb(default_response.ok, default_response.err, default_response.body)
        end
        return client
    end

    function recorder.set_response(ok, err, body)
        default_response = { ok = ok, err = err, body = body }
    end

    return recorder
end


--- Build a stub provider chain that returns a fixed provider.
local function fixed_provider(cfg)
    return function(_opts)
        if not cfg then return nil end
        return {
            id          = function() return "stub" end,
            get_config  = function() return cfg end,
            supports    = function(_) return false end,
        }
    end
end


-- ----------------------------------------------------------------------------
-- Conformance: the constructed transport satisfies Interface.
-- ----------------------------------------------------------------------------


do
    local t = Transport.new({
        settings_reader     = function() return true end,
        http_client_factory = make_fake_http_factory().factory,
        provider_discover   = fixed_provider({
            url = "http://x", api_key = "k", folder_id = "default",
        }),
    })
    local ok, problems = Interface.validate_implementation(t)
    h.assert_true(ok, "transport satisfies interface")
    h.assert_equal(#problems, 0, "no validation problems")
end


-- ----------------------------------------------------------------------------
-- Identity and immutable properties.
-- ----------------------------------------------------------------------------


do
    local t = Transport.new({
        settings_reader   = function() return true end,
        provider_discover = fixed_provider({
            url = "http://x", api_key = "k", folder_id = "default",
        }),
    })
    h.assert_equal(t.id(), "syncthing",                  "id is stable")
    h.assert_equal(t.display_name(), "Syncthing",        "display name")
    h.assert_true(t.is_eventually_consistent(),
        "Syncthing IS eventually consistent (scan triggers, replication async)")
end


-- ----------------------------------------------------------------------------
-- is_available: requires both the toggle AND a working provider.
-- ----------------------------------------------------------------------------


do
    -- Toggle off, provider would work: unavailable.
    local t = Transport.new({
        settings_reader   = function(k)
            if k == "syncery_use_syncthing" then return false end
        end,
        provider_discover = fixed_provider({
            url = "http://x", api_key = "k", folder_id = "default",
        }),
    })
    h.assert_false(t.is_available(), "toggle off → unavailable")
end


do
    -- Toggle on, no provider: unavailable.
    local t = Transport.new({
        settings_reader   = function() return true end,
        provider_discover = fixed_provider(nil),   -- no provider
    })
    h.assert_false(t.is_available(), "no provider → unavailable")
end


do
    -- Toggle on, provider works: available.
    local t = Transport.new({
        settings_reader = function(k)
            if k == "syncery_use_syncthing" then return true end
        end,
        provider_discover = fixed_provider({
            url = "http://x", api_key = "k", folder_id = "default",
        }),
    })
    h.assert_true(t.is_available(), "both conditions met → available")
end


do
    -- COLLAPSE GUARD: is_available() reads the canonical `syncery_use_syncthing`
    -- key, NOT the old `syncery_sync_via_syncthing` mirror.  Model the wizard-
    -- divergence state: the user picked another transport so use_=false, but a
    -- stale sync_via_=true lingers (the menu used to write it).  Available MUST
    -- follow use_=false; reading sync_via_=true resurrects the bug (label
    -- "ready" / pushes while the checkbox is off).
    local t = Transport.new({
        settings_reader = function(k)
            if k == "syncery_use_syncthing"      then return false end
            if k == "syncery_sync_via_syncthing" then return true  end  -- stale mirror, must be IGNORED
        end,
        provider_discover = fixed_provider({
            url = "http://x", api_key = "k", folder_id = "default",
        }),
    })
    h.assert_false(t.is_available(),
        "is_available follows use_syncthing=false, ignoring a stale sync_via_syncthing=true (collapse)")
end


-- ----------------------------------------------------------------------------
-- push: NOT_AVAILABLE error when transport isn't ready.
-- ----------------------------------------------------------------------------


do
    local t = Transport.new({
        settings_reader   = function() return false end,
        provider_discover = fixed_provider(nil),
    })

    local got_ok, got_err
    t.push("/books/x.epub", {}, function(ok, err) got_ok, got_err = ok, err end)
    h.assert_false(got_ok,                          "push refused")
    h.assert_equal(got_err, Interface.ERRORS.NOT_AVAILABLE, "err = NOT_AVAILABLE")
end


-- ----------------------------------------------------------------------------
-- push: builds the correct scan URL.
-- ----------------------------------------------------------------------------


do
    local recorder = make_fake_http_factory()
    local t = Transport.new({
        settings_reader     = function() return true end,
        http_client_factory = recorder.factory,
        provider_discover   = fixed_provider({
            url = "http://127.0.0.1:8384",
            api_key = "k",
            folder_id = "books-7y3xz",
        }),
    })

    local got_ok
    t.push("/some/book.epub", {}, function(ok) got_ok = ok end)

    h.assert_true(got_ok,                                 "push succeeded")
    h.assert_equal(#recorder.calls, 1,                    "one HTTP call")
    h.assert_equal(recorder.calls[1].method, "POST",      "via POST")
    h.assert_equal(recorder.calls[1].url,
        "http://127.0.0.1:8384/rest/db/scan?folder=books-7y3xz",
        "URL is /rest/db/scan with folder= param")
end


-- ----------------------------------------------------------------------------
-- push: respects opts.sub for targeted scan.
-- ----------------------------------------------------------------------------


do
    local recorder = make_fake_http_factory()
    local t = Transport.new({
        settings_reader     = function() return true end,
        http_client_factory = recorder.factory,
        provider_discover   = fixed_provider({
            url = "http://x:8384", api_key = "k", folder_id = "default",
        }),
    })

    t.push("/books/Library/Foo.epub", { sub = "Library/Foo.epub" }, function() end)

    h.assert_equal(recorder.calls[1].url,
        "http://x:8384/rest/db/scan?folder=default&sub=Library/Foo.epub",
        "sub appended; slashes preserved")
end


-- ----------------------------------------------------------------------------
-- push: opts.sub with Windows backslashes is normalized.
-- The legacy code did this; matching the behaviour.
-- ----------------------------------------------------------------------------


do
    local recorder = make_fake_http_factory()
    local t = Transport.new({
        settings_reader     = function() return true end,
        http_client_factory = recorder.factory,
        provider_discover   = fixed_provider({
            url = "http://x", api_key = "k", folder_id = "default",
        }),
    })
    t.push("/books/Library/Foo.epub", { sub = "Library\\Foo.epub" }, function() end)
    h.assert_true(recorder.calls[1].url:match("sub=Library/Foo%.epub") ~= nil,
        "backslashes normalized to forward slashes in sub")
end


-- ----------------------------------------------------------------------------
-- push: spaces in sub are encoded per-segment.
-- ----------------------------------------------------------------------------


do
    local recorder = make_fake_http_factory()
    local t = Transport.new({
        settings_reader     = function() return true end,
        http_client_factory = recorder.factory,
        provider_discover   = fixed_provider({
            url = "http://x", api_key = "k", folder_id = "default",
        }),
    })
    t.push("/x", { sub = "Hello World/file name.epub" }, function() end)
    h.assert_true(recorder.calls[1].url:match("Hello%%20World/file%%20name") ~= nil,
        "spaces encoded as %20, slashes preserved")
end


-- ----------------------------------------------------------------------------
-- push: an HTTP error propagates with the right class.
-- ----------------------------------------------------------------------------


do
    local recorder = make_fake_http_factory()
    recorder.set_response(false, Interface.ERRORS.AUTH_FAILED, "")
    local t = Transport.new({
        settings_reader     = function() return true end,
        http_client_factory = recorder.factory,
        provider_discover   = fixed_provider({
            url = "http://x", api_key = "wrong", folder_id = "default",
        }),
    })

    local got_ok, got_err
    t.push("/book.epub", {}, function(ok, err) got_ok, got_err = ok, err end)
    h.assert_false(got_ok,                            "push failed")
    h.assert_equal(got_err, Interface.ERRORS.AUTH_FAILED, "auth_failed propagates")
end


-- ----------------------------------------------------------------------------
-- push: an HTTP factory that throws is contained → INTERNAL.
-- ----------------------------------------------------------------------------


do
    local crashing_factory = function() error("connection-pool dead") end
    local t = Transport.new({
        settings_reader     = function() return true end,
        http_client_factory = crashing_factory,
        provider_discover   = fixed_provider({
            url = "http://x", api_key = "k", folder_id = "default",
        }),
    })

    local got_ok, got_err
    local call_ok = pcall(function()
        t.push("/book.epub", {}, function(ok, err) got_ok, got_err = ok, err end)
    end)
    h.assert_true(call_ok,                              "throw contained")
    h.assert_false(got_ok,                              "failure reported")
    h.assert_equal(got_err, Interface.ERRORS.INTERNAL,   "err = INTERNAL")
end


-- ----------------------------------------------------------------------------
-- pull: no-op success.  Documented Syncthing semantic.
-- ----------------------------------------------------------------------------


do
    local recorder = make_fake_http_factory()
    local t = Transport.new({
        settings_reader     = function() return true end,
        http_client_factory = recorder.factory,
        provider_discover   = fixed_provider({
            url = "http://x", api_key = "k", folder_id = "default",
        }),
    })

    local got_ok, got_err, got_payload
    t.pull("/book.epub", {}, function(ok, err, payload)
        got_ok, got_err, got_payload = ok, err, payload
    end)

    h.assert_true(got_ok,         "pull reports success")
    h.assert_nil(got_err,         "no error")
    h.assert_nil(got_payload,     "no payload (eventually consistent)")
    h.assert_equal(#recorder.calls, 0, "no HTTP call made by pull")
end


-- ----------------------------------------------------------------------------
-- status: reflects toggle / config state.
-- ----------------------------------------------------------------------------


do
    local t = Transport.new({
        settings_reader   = function() return false end,
        provider_discover = fixed_provider(nil),
    })
    local s = t.status()
    h.assert_equal(s.display_name, "Syncthing",           "display name")
    h.assert_false(s.available,                            "unavailable")
    h.assert_true(s.summary:match("disabled") ~= nil,      "summary mentions disabled")
end


do
    local t = Transport.new({
        settings_reader   = function(k)
            if k == "syncery_use_syncthing" then return true end
        end,
        provider_discover = fixed_provider(nil),
    })
    local s = t.status()
    h.assert_false(s.available, "toggle on but no provider → unavailable")
    h.assert_true(s.summary:match("not configured") ~= nil,
        "summary mentions configuration")
end


do
    local t = Transport.new({
        settings_reader   = function() return true end,
        provider_discover = fixed_provider({
            url = "http://x", api_key = "k", folder_id = "default",
        }),
    })
    local s = t.status()
    h.assert_true(s.available,                          "available")
    h.assert_true(s.summary:match("ready") ~= nil,       "summary says ready")
end


-- ----------------------------------------------------------------------------
-- supports(): chunk 3 reports false for every documented capability.
-- (Chunk 4 will change this once kosyncthing_plus_provider and http_client's
-- universal capabilities land.)
-- ----------------------------------------------------------------------------


do
    -- Post-chunk-4: IGNORE_PATTERNS is now a UNIVERSAL capability,
    -- available whenever the transport is available (i.e. has a
    -- working provider).  Other bonus capabilities are still
    -- provider-supplied — chunk 4's kosyncthing_plus_provider adds them; the
    -- stub fixed_provider used in this spec does NOT.
    local t = Transport.new({
        settings_reader   = function() return true end,
        provider_discover = fixed_provider({
            url = "http://x", api_key = "k", folder_id = "default",
        }),
    })
    h.assert_true(t.supports(Interface.CAPABILITIES.IGNORE_PATTERNS),
        "ignore_patterns is universal once the transport is available")
    h.assert_false(t.supports(Interface.CAPABILITIES.EVENT_SUBSCRIPTION),
        "no events without KOSyncthing+ provider")
    h.assert_false(t.supports(Interface.CAPABILITIES.CONFLICTS_DETAILED),
        "no detailed conflicts without KOSyncthing+ provider")
    h.assert_false(t.supports(Interface.CAPABILITIES.PERIODIC_SYNC),
        "no periodic_sync without KOSyncthing+ provider")
    h.assert_false(t.supports(Interface.CAPABILITIES.QUICK_SYNC),
        "no quick_sync without KOSyncthing+ provider")
end


do
    -- And the inverse: when the transport is NOT available, even
    -- ignore_patterns is gated off (no point pretending we can do
    -- something when we have no daemon to talk to).
    local t = Transport.new({
        settings_reader   = function() return false end,
        provider_discover = fixed_provider(nil),
    })
    h.assert_false(t.supports(Interface.CAPABILITIES.IGNORE_PATTERNS),
        "ignore_patterns gated off when transport unavailable")
end


-- ----------------------------------------------------------------------------
-- Integration with the orchestrator: the real Syncthing transport
-- plugs into the orchestrator and behaves correctly under push_book.
-- (Smoke test: this is what production will actually do.)
-- ----------------------------------------------------------------------------


do
    local Orchestrator = require("syncery_transports/orchestrator")

    local recorder = make_fake_http_factory()
    local syncthing = Transport.new({
        settings_reader     = function() return true end,
        http_client_factory = recorder.factory,
        provider_discover   = fixed_provider({
            url = "http://x", api_key = "k", folder_id = "default",
        }),
    })

    local clock = h.make_fake_clock(1000)
    local sched = h.make_fake_scheduler(clock)
    local orch  = Orchestrator.new({
        transports    = { syncthing },
        clock         = clock.now,
        scheduler     = sched.schedule,
        policy_config = { syncthing = { debounce_seconds = 0, retry_schedule = { 1 } } },
    })

    orch:push_book("/books/x.epub", { sub = "x.epub" })

    h.assert_equal(#recorder.calls, 1,
        "orchestrator → transport.push → one HTTP call")
    h.assert_true(recorder.calls[1].url:match("sub=x%.epub") ~= nil,
        "opts.sub flowed through orchestrator to URL")
end


-- ----------------------------------------------------------------------------
-- Integration: an HTTP failure triggers the orchestrator's retry path.
-- ----------------------------------------------------------------------------


do
    local Orchestrator = require("syncery_transports/orchestrator")
    local Policy       = require("syncery_transports/policy")

    local recorder = make_fake_http_factory()
    recorder.set_response(false, Interface.ERRORS.UNREACHABLE, "")

    local syncthing = Transport.new({
        settings_reader     = function() return true end,
        http_client_factory = recorder.factory,
        provider_discover   = fixed_provider({
            url = "http://x", api_key = "k", folder_id = "default",
        }),
    })

    local clock = h.make_fake_clock(1000)
    local sched = h.make_fake_scheduler(clock)
    local orch  = Orchestrator.new({
        transports    = { syncthing },
        clock         = clock.now,
        scheduler     = sched.schedule,
        policy_config = { syncthing = { debounce_seconds = 0, retry_schedule = { 5, 15 } } },
    })

    orch:push_book("/books/x.epub", {})
    h.assert_equal(#recorder.calls, 1, "first attempt fired")

    local state = orch:peek_state("syncthing", "/books/x.epub")
    h.assert_equal(state.last_error_class, Policy.CLASS_TRANSIENT,
        "UNREACHABLE classified as transient")
    h.assert_true(state.pending_retry_at ~= nil, "retry scheduled")

    -- Advance to the retry slot; the second HTTP call fires.
    clock.advance(5)
    sched.run_due()
    h.assert_equal(#recorder.calls, 2, "second attempt fired after schedule[1]")
end


-- ============================================================================
-- Chunk 4: capability methods.
--
-- These exercise the universal IGNORE_PATTERNS surface
-- (get_folder_ignore / set_folder_ignore) and the KOSyncthing+-only periodic
-- sync surface.  Both groups are advertised via supports(); the
-- contract spec doesn't enforce them on every transport.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Helper: build a transport whose http_client_factory uses a fake
-- client whose get/post_json record their calls and reply with a
-- configurable response.  More expressive than the make_fake_http_factory
-- defined earlier in this file.
-- ----------------------------------------------------------------------------


local function make_capability_factory()
    local rec = { calls = {}, get_response = '{"ignore":["*.json"]}',
                  post_response_ok = true, post_response_err = nil }
    function rec.factory(config)
        local client = {}
        function client:get(path, cb)
            table.insert(rec.calls, { method = "GET", path = path,
                                      url = (config.url or "") .. path })
            cb(true, nil, rec.get_response)
        end
        function client:post(path, cb)
            table.insert(rec.calls, { method = "POST", path = path })
            cb(true, nil, "")
        end
        function client:post_json(path, body, cb)
            table.insert(rec.calls, { method = "POST_JSON", path = path, body = body })
            cb(rec.post_response_ok, rec.post_response_err, nil)
        end
        return client
    end
    return rec
end


-- ----------------------------------------------------------------------------
-- get_folder_ignore happy path: builds the right URL, decodes
-- response, returns the ignore array.
-- ----------------------------------------------------------------------------


do
    local rec = make_capability_factory()
    rec.get_response = '{"ignore":["*.tmp","build/*"],"expanded":["*.tmp"]}'
    local t = Transport.new({
        settings_reader     = function() return true end,
        http_client_factory = rec.factory,
        provider_discover   = fixed_provider({
            url = "http://x:8384", api_key = "k", folder_id = "default",
        }),
    })

    local got_ok, got_err, got_patterns
    t.get_folder_ignore("my-folder-id", function(ok, err, patterns)
        got_ok, got_err, got_patterns = ok, err, patterns
    end)

    h.assert_true(got_ok,                       "get_folder_ignore ok")
    h.assert_nil(got_err,                       "no error")
    h.assert_equal(type(got_patterns), "table",  "got a table")
    h.assert_equal(#got_patterns, 2,             "two patterns")
    h.assert_equal(got_patterns[1], "*.tmp",     "first pattern")
    h.assert_equal(rec.calls[1].path,
        "/rest/db/ignores?folder=my-folder-id",
        "URL built with folder query param")
end


-- ----------------------------------------------------------------------------
-- get_folder_ignore: REJECTED for missing/empty folder_id.
-- ----------------------------------------------------------------------------


do
    local rec = make_capability_factory()
    local t = Transport.new({
        settings_reader     = function() return true end,
        http_client_factory = rec.factory,
        provider_discover   = fixed_provider({
            url = "http://x", api_key = "k", folder_id = "default",
        }),
    })

    local got_err
    t.get_folder_ignore("", function(_ok, err) got_err = err end)
    h.assert_equal(got_err, Interface.ERRORS.REJECTED, "empty folder_id rejected")

    t.get_folder_ignore(nil, function(_ok, err) got_err = err end)
    h.assert_equal(got_err, Interface.ERRORS.REJECTED, "nil folder_id rejected")
end


-- ----------------------------------------------------------------------------
-- get_folder_ignore: NOT_AVAILABLE when transport is off.
-- ----------------------------------------------------------------------------


do
    local t = Transport.new({
        settings_reader   = function() return false end,
        provider_discover = fixed_provider(nil),
    })
    local got_err
    t.get_folder_ignore("f", function(_ok, err) got_err = err end)
    h.assert_equal(got_err, Interface.ERRORS.NOT_AVAILABLE, "off → NOT_AVAILABLE")
end


-- ----------------------------------------------------------------------------
-- set_folder_ignore happy path: POST_JSON with the right body shape.
-- ----------------------------------------------------------------------------


do
    local rec = make_capability_factory()
    local t = Transport.new({
        settings_reader     = function() return true end,
        http_client_factory = rec.factory,
        provider_discover   = fixed_provider({
            url = "http://x", api_key = "k", folder_id = "default",
        }),
    })

    local got_ok
    t.set_folder_ignore("books", { "*.tmp", "node_modules/" }, function(ok)
        got_ok = ok
    end)

    h.assert_true(got_ok, "set ok")
    h.assert_equal(rec.calls[1].method, "POST_JSON",  "uses post_json")
    h.assert_equal(rec.calls[1].path,
        "/rest/db/ignores?folder=books",
        "URL has folder query param")
    h.assert_equal(type(rec.calls[1].body), "table",  "body is a table")
    h.assert_equal(#rec.calls[1].body.ignore, 2,       "ignore list size")
    h.assert_equal(rec.calls[1].body.ignore[1], "*.tmp", "first pattern")
end


-- ----------------------------------------------------------------------------
-- set_folder_ignore: non-table patterns rejected.
-- ----------------------------------------------------------------------------


do
    local rec = make_capability_factory()
    local t = Transport.new({
        settings_reader     = function() return true end,
        http_client_factory = rec.factory,
        provider_discover   = fixed_provider({
            url = "http://x", api_key = "k", folder_id = "default",
        }),
    })
    local got_err
    t.set_folder_ignore("f", "not a table", function(_ok, err) got_err = err end)
    h.assert_equal(got_err, Interface.ERRORS.REJECTED, "non-table patterns rejected")

    t.set_folder_ignore("f", { "ok", 42, "ok" }, function(_ok, err) got_err = err end)
    h.assert_equal(got_err, Interface.ERRORS.REJECTED,
        "non-string entries rejected")
end


-- ----------------------------------------------------------------------------
-- Periodic sync: get_periodic_sync_state returns the values from the
-- KOSyncthing+ API (and nil when that provider isn't backing this transport).
-- ----------------------------------------------------------------------------


do
    -- No KOSyncthing+ API in fixed_provider's config; supports(PERIODIC_SYNC) = false.
    local t = Transport.new({
        settings_reader   = function() return true end,
        provider_discover = fixed_provider({
            url = "http://x", api_key = "k", folder_id = "default",
        }),
    })
    h.assert_nil(t.get_periodic_sync_state(),
        "no KOSyncthing+ API → nil periodic state")
end


do
    -- Synthesize a KOSyncthing+-style provider that supports PERIODIC_SYNC.
    local fake_kosyncthing_plus_api = {
        status = {
            isPeriodicSyncEnabled  = function() return true end,
            getPeriodicSyncInterval = function() return 45 end,
            getNextPeriodicSyncAt  = function() return 1700000000 end,
        },
        control = {
            setPeriodicSyncEnabled  = function(_e) return true end,
            setPeriodicSyncInterval = function(_m) return true end,
            runPeriodicSyncNow      = function() return true end,
        },
    }
    local kosyncthing_like_provider = {
        id         = function() return "kosyncthing-stub" end,
        get_config = function() return {
            rest_client = { get = function() end, post = function() end,
                            post_json = function() end },
            folder_id   = "default",
            kosyncthing_plus_api    = fake_kosyncthing_plus_api,
        } end,
        supports = function(cap)
            return cap == Interface.CAPABILITIES.PERIODIC_SYNC
                or cap == Interface.CAPABILITIES.EVENT_SUBSCRIPTION
        end,
    }
    local t = Transport.new({
        settings_reader   = function() return true end,
        provider_discover = function() return kosyncthing_like_provider end,
        http_client_factory = function(config) return config.rest_client end,
    })

    h.assert_true(t.supports(Interface.CAPABILITIES.PERIODIC_SYNC),
        "PERIODIC_SYNC advertised from provider")

    local state = t.get_periodic_sync_state()
    h.assert_equal(type(state), "table",          "got a state table")
    h.assert_true(state.enabled,                   "enabled = true")
    h.assert_equal(state.interval_minutes, 45,     "interval reflected")
    h.assert_equal(state.next_at, 1700000000,      "next_at reflected")

    -- Control calls.
    local ok = t.set_periodic_sync_enabled(true)
    h.assert_true(ok, "set_enabled returned true")

    local ok2 = t.set_periodic_sync_interval(60)
    h.assert_true(ok2, "set_interval returned true")

    local ok3 = t.run_periodic_sync_now()
    h.assert_true(ok3, "run_now returned true")
end


-- ----------------------------------------------------------------------------
-- Periodic sync control: returns nil + message when unsupported.
-- ----------------------------------------------------------------------------


do
    local t = Transport.new({
        settings_reader   = function() return true end,
        provider_discover = fixed_provider({
            url = "http://x", api_key = "k", folder_id = "default",
        }),
    })

    local ok, err = t.set_periodic_sync_enabled(true)
    h.assert_nil(ok,                                "unsupported → nil")
    h.assert_true(tostring(err):match("not supported") ~= nil,
        "error message explains the unsupported state")
end


-- ----------------------------------------------------------------------------
-- quick_sync_all: delegates to KOSyncthing+'s control.quickSync(nil) when
-- supported, and returns nil + "not supported" otherwise.  Synchronous
-- — no callback shape — because the plugin's quickSync is synchronous
-- and we're a thin wrapper.
-- ----------------------------------------------------------------------------


do
    -- No KOSyncthing+ provider — quick_sync_all returns nil with an
    -- explanation, does not raise.
    local t = Transport.new({
        settings_reader   = function() return true end,
        provider_discover = fixed_provider({
            url = "http://x", api_key = "k", folder_id = "default",
        }),
    })
    local ok, err = t.quick_sync_all()
    h.assert_nil(ok,                                "unsupported → nil")
    h.assert_true(tostring(err):match("not supported") ~= nil,
        "error message explains the unsupported state")
end


do
    -- KOSyncthing+-style provider that supports QUICK_SYNC.  The fake records
    -- every call so we can assert quick_sync_all passes nil for the
    -- touchmenu_instance arg.
    local quick_sync_calls = {}
    local fake_kosyncthing_plus_api = {
        control = {
            quickSync = function(touchmenu)
                table.insert(quick_sync_calls, { touchmenu = touchmenu })
                return true
            end,
        },
    }
    local kosyncthing_like_provider = {
        id         = function() return "kosyncthing-stub" end,
        get_config = function() return {
            rest_client = { get = function() end, post = function() end,
                            post_json = function() end },
            folder_id   = "default",
            kosyncthing_plus_api    = fake_kosyncthing_plus_api,
        } end,
        supports = function(cap)
            return cap == Interface.CAPABILITIES.QUICK_SYNC
        end,
    }
    local t = Transport.new({
        settings_reader   = function() return true end,
        provider_discover = function() return kosyncthing_like_provider end,
        http_client_factory = function(config) return config.rest_client end,
    })

    h.assert_true(t.supports(Interface.CAPABILITIES.QUICK_SYNC),
        "QUICK_SYNC advertised by stubbed provider")

    local ok = t.quick_sync_all()
    h.assert_true(ok, "quick_sync_all returned true")
    h.assert_equal(#quick_sync_calls, 1, "KOSyncthing+ control.quickSync called once")
    h.assert_nil(quick_sync_calls[1].touchmenu,
        "called with nil touchmenu (we have no menu chain)")
end


do
    -- The provider claims support but the KOSyncthing+ API itself is missing
    -- control.quickSync (caller fabricated `supports`).  We should
    -- gracefully return nil + error rather than crashing on a nil call.
    local kosyncthing_like_provider = {
        id         = function() return "kosyncthing-stub-broken" end,
        get_config = function() return {
            rest_client = { get = function() end, post = function() end,
                            post_json = function() end },
            folder_id   = "default",
            kosyncthing_plus_api    = { control = {} },  -- no quickSync method
        } end,
        supports = function(cap)
            return cap == Interface.CAPABILITIES.QUICK_SYNC
        end,
    }
    local t = Transport.new({
        settings_reader   = function() return true end,
        provider_discover = function() return kosyncthing_like_provider end,
        http_client_factory = function(config) return config.rest_client end,
    })

    local ok, err = t.quick_sync_all()
    h.assert_nil(ok, "missing quickSync → nil")
    h.assert_true(tostring(err):match("not available") ~= nil
                  or tostring(err):match("not supported") ~= nil,
        "explanation returned")
end


do
    -- The plugin's quickSync raises mid-call — we catch via pcall and
    -- return nil + the error message instead of letting the throw
    -- propagate into menu code.
    local fake_kosyncthing_plus_api = {
        control = {
            quickSync = function() error("daemon offline") end,
        },
    }
    local kosyncthing_like_provider = {
        id         = function() return "kosyncthing-stub-raiser" end,
        get_config = function() return {
            rest_client = { get = function() end, post = function() end,
                            post_json = function() end },
            folder_id   = "default",
            kosyncthing_plus_api    = fake_kosyncthing_plus_api,
        } end,
        supports = function(cap)
            return cap == Interface.CAPABILITIES.QUICK_SYNC
        end,
    }
    local t = Transport.new({
        settings_reader   = function() return true end,
        provider_discover = function() return kosyncthing_like_provider end,
        http_client_factory = function(config) return config.rest_client end,
    })

    local ok, err = t.quick_sync_all()
    h.assert_nil(ok, "raise in quickSync surfaces as nil result")
    h.assert_true(tostring(err):match("daemon offline") ~= nil,
        "error message propagated")
end


-- ----------------------------------------------------------------------------
-- register_conflict_scanner_ignore: calls KOSyncthing+'s
-- IgnoreRegistry:register(plugin_id, pattern) when supported, returns
-- nil + reason otherwise.  In-process (no REST), synchronous wrapper.
-- ----------------------------------------------------------------------------


do
    -- Not supported by the provider — no-op, returns nil + "not supported".
    local t = Transport.new({
        settings_reader   = function() return true end,
        provider_discover = fixed_provider({
            url = "http://x", api_key = "k", folder_id = "default",
        }),
    })
    local ok, err = t.register_conflict_scanner_ignore("syncery", "*syncery-*sync-conflict-*")
    h.assert_nil(ok, "unsupported → nil")
    h.assert_true(tostring(err):match("not supported") ~= nil,
        "error explains the unsupported state")
end


do
    -- Supported: the registry's register is called once, via colon syntax
    -- (self == the IgnoreRegistry table), with our plugin_id and pattern.
    local register_calls = {}
    local registry = {}
    registry.register = function(self, plugin_id, pattern)
        table.insert(register_calls, { self = self, plugin_id = plugin_id, pattern = pattern })
        return true
    end
    local fake_kosyncthing_plus_api = { IgnoreRegistry = registry }
    local kosyncthing_like_provider = {
        id         = function() return "kosyncthing-stub" end,
        get_config = function() return {
            rest_client = { get = function() end, post = function() end,
                            post_json = function() end },
            folder_id   = "default",
            kosyncthing_plus_api = fake_kosyncthing_plus_api,
        } end,
        supports = function(cap)
            return cap == Interface.CAPABILITIES.CONFLICT_IGNORE_REGISTRY
        end,
    }
    local t = Transport.new({
        settings_reader   = function() return true end,
        provider_discover = function() return kosyncthing_like_provider end,
        http_client_factory = function(config) return config.rest_client end,
    })

    h.assert_true(t.supports(Interface.CAPABILITIES.CONFLICT_IGNORE_REGISTRY),
        "CONFLICT_IGNORE_REGISTRY advertised by stubbed provider")

    local ok = t.register_conflict_scanner_ignore("syncery", "*syncery-*sync-conflict-*")
    h.assert_true(ok, "register_conflict_scanner_ignore returned true")
    h.assert_equal(#register_calls, 1, "IgnoreRegistry.register called once")
    h.assert_equal(register_calls[1].self, registry,
        "colon call: self is the IgnoreRegistry table")
    h.assert_equal(register_calls[1].plugin_id, "syncery", "plugin_id passed through")
    h.assert_equal(register_calls[1].pattern, "*syncery-*sync-conflict-*",
        "pattern passed through")
end


do
    -- Bad args (empty plugin_id / pattern) — guarded, returns nil + reason,
    -- does not touch the API.
    local registry_touched = false
    local fake_kosyncthing_plus_api = {
        IgnoreRegistry = { register = function() registry_touched = true end },
    }
    local kosyncthing_like_provider = {
        id         = function() return "kosyncthing-stub" end,
        get_config = function() return {
            rest_client = { get = function() end, post = function() end,
                            post_json = function() end },
            kosyncthing_plus_api = fake_kosyncthing_plus_api,
        } end,
        supports = function(cap)
            return cap == Interface.CAPABILITIES.CONFLICT_IGNORE_REGISTRY
        end,
    }
    local t = Transport.new({
        settings_reader   = function() return true end,
        provider_discover = function() return kosyncthing_like_provider end,
        http_client_factory = function(config) return config.rest_client end,
    })
    local ok, err = t.register_conflict_scanner_ignore("", "*x*")
    h.assert_nil(ok, "empty plugin_id → nil")
    h.assert_true(tostring(err):match("required") ~= nil, "explains the arg requirement")
    h.assert_false(registry_touched, "API not called on bad args")
end


do
    -- Provider claims support but the API lacks IgnoreRegistry.register —
    -- graceful nil + error, no crash.
    local kosyncthing_like_provider = {
        id         = function() return "kosyncthing-stub-broken" end,
        get_config = function() return {
            rest_client = { get = function() end, post = function() end,
                            post_json = function() end },
            kosyncthing_plus_api = { IgnoreRegistry = {} },  -- no register method
        } end,
        supports = function(cap)
            return cap == Interface.CAPABILITIES.CONFLICT_IGNORE_REGISTRY
        end,
    }
    local t = Transport.new({
        settings_reader   = function() return true end,
        provider_discover = function() return kosyncthing_like_provider end,
        http_client_factory = function(config) return config.rest_client end,
    })
    local ok, err = t.register_conflict_scanner_ignore("syncery", "*x*")
    h.assert_nil(ok, "missing register → nil")
    h.assert_true(tostring(err):match("not available") ~= nil
                  or tostring(err):match("not supported") ~= nil,
        "explanation returned")
end


do
    -- register raises mid-call — caught via pcall, returned as nil + message.
    local fake_kosyncthing_plus_api = {
        IgnoreRegistry = { register = function() error("registry boom") end },
    }
    local kosyncthing_like_provider = {
        id         = function() return "kosyncthing-stub-raiser" end,
        get_config = function() return {
            rest_client = { get = function() end, post = function() end,
                            post_json = function() end },
            kosyncthing_plus_api = fake_kosyncthing_plus_api,
        } end,
        supports = function(cap)
            return cap == Interface.CAPABILITIES.CONFLICT_IGNORE_REGISTRY
        end,
    }
    local t = Transport.new({
        settings_reader   = function() return true end,
        provider_discover = function() return kosyncthing_like_provider end,
        http_client_factory = function(config) return config.rest_client end,
    })
    local ok, err = t.register_conflict_scanner_ignore("syncery", "*x*")
    h.assert_nil(ok, "raise surfaces as nil result")
    h.assert_true(tostring(err):match("registry boom") ~= nil, "error message propagated")
end


-- ----------------------------------------------------------------------------
-- Daemon control (Phase 11): is_daemon_running / start_daemon / stop_daemon.
--
-- Mirrors the quick_sync_all block above — unsupported, supported,
-- missing-method, and raising-call cases — but for the callback-shaped
-- start/stop surface.  The plugin's control.start/stop take a no-arg
-- completion callback; our wrapper maps "callback fired" → (true).
-- ----------------------------------------------------------------------------


do
    -- No KOSyncthing+ provider — daemon control short-circuits cleanly.
    local t = Transport.new({
        settings_reader   = function() return true end,
        provider_discover = fixed_provider({
            url = "http://x", api_key = "k", folder_id = "default",
        }),
    })
    h.assert_false(t.supports(Interface.CAPABILITIES.DAEMON_CONTROL),
        "no daemon_control without KOSyncthing+ provider")
    h.assert_nil(t.is_daemon_running(),
        "is_daemon_running → nil when unsupported")

    local got_ok, got_err
    t.start_daemon(function(ok, err) got_ok = ok; got_err = err end)
    h.assert_false(got_ok, "start_daemon → (false, ...) when unsupported")
    h.assert_true(tostring(got_err):match("not supported") ~= nil,
        "start_daemon: error explains the unsupported state")

    got_ok, got_err = nil, nil
    t.stop_daemon(function(ok, err) got_ok = ok; got_err = err end)
    h.assert_false(got_ok, "stop_daemon → (false, ...) when unsupported")
end


do
    -- KOSyncthing+-style provider that supports DAEMON_CONTROL.  The fakes
    -- record calls and fire the no-arg completion callback so the
    -- wrapper's "callback fired → (true)" mapping is exercised.
    local start_calls, stop_calls, running_state = 0, 0, false
    local fake_kosyncthing_plus_api = {
        status = {
            isRunning = function() return running_state end,
        },
        control = {
            start = function(cb) start_calls = start_calls + 1
                                 running_state = true
                                 if cb then cb() end end,
            stop  = function(cb) stop_calls = stop_calls + 1
                                 running_state = false
                                 if cb then cb() end end,
        },
    }
    local kosyncthing_like_provider = {
        id         = function() return "kosyncthing-stub-daemon" end,
        get_config = function() return {
            rest_client = { get = function() end, post = function() end,
                            post_json = function() end },
            folder_id   = "default",
            kosyncthing_plus_api    = fake_kosyncthing_plus_api,
        } end,
        supports = function(cap)
            return cap == Interface.CAPABILITIES.DAEMON_CONTROL
        end,
    }
    local t = Transport.new({
        settings_reader   = function() return true end,
        provider_discover = function() return kosyncthing_like_provider end,
        http_client_factory = function(config) return config.rest_client end,
    })

    h.assert_true(t.supports(Interface.CAPABILITIES.DAEMON_CONTROL),
        "DAEMON_CONTROL advertised from provider")

    -- isRunning reflects the KOSyncthing+ status.
    h.assert_false(t.is_daemon_running(), "daemon initially reported stopped")

    -- start_daemon fires the completion callback with (true).
    local started
    t.start_daemon(function(ok) started = ok end)
    h.assert_true(started, "start_daemon → (true) on completion")
    h.assert_equal(start_calls, 1, "KOSyncthing+ control.start invoked once")
    h.assert_true(t.is_daemon_running(), "daemon now reported running")

    -- stop_daemon likewise.
    local stopped
    t.stop_daemon(function(ok) stopped = ok end)
    h.assert_true(stopped, "stop_daemon → (true) on completion")
    h.assert_equal(stop_calls, 1, "KOSyncthing+ control.stop invoked once")
    h.assert_false(t.is_daemon_running(), "daemon reported stopped again")
end


do
    -- Provider claims support but the KOSyncthing+ API is missing the actual
    -- control.start method — graceful (false, err), no crash.
    local kosyncthing_like_provider = {
        id         = function() return "kosyncthing-stub-broken-daemon" end,
        get_config = function() return {
            rest_client = { get = function() end, post = function() end,
                            post_json = function() end },
            folder_id   = "default",
            kosyncthing_plus_api    = { control = {}, status = {
                isRunning = function() return false end } },
        } end,
        supports = function(cap)
            return cap == Interface.CAPABILITIES.DAEMON_CONTROL
        end,
    }
    local t = Transport.new({
        settings_reader   = function() return true end,
        provider_discover = function() return kosyncthing_like_provider end,
        http_client_factory = function(config) return config.rest_client end,
    })

    local got_ok, got_err
    t.start_daemon(function(ok, err) got_ok = ok; got_err = err end)
    h.assert_false(got_ok, "missing control.start → (false, ...)")
    h.assert_true(tostring(got_err):match("not available") ~= nil,
        "missing-method error explains the unavailable API")
end


do
    -- The plugin's control.start raises mid-call — caught, surfaced as
    -- (false, "internal"), never propagated into menu code.
    local fake_kosyncthing_plus_api = {
        status  = { isRunning = function() return false end },
        control = { start = function() error("launch failed") end,
                    stop  = function(cb) if cb then cb() end end },
    }
    local kosyncthing_like_provider = {
        id         = function() return "kosyncthing-stub-daemon-raiser" end,
        get_config = function() return {
            rest_client = { get = function() end, post = function() end,
                            post_json = function() end },
            folder_id   = "default",
            kosyncthing_plus_api    = fake_kosyncthing_plus_api,
        } end,
        supports = function(cap)
            return cap == Interface.CAPABILITIES.DAEMON_CONTROL
        end,
    }
    local t = Transport.new({
        settings_reader   = function() return true end,
        provider_discover = function() return kosyncthing_like_provider end,
        http_client_factory = function(config) return config.rest_client end,
    })

    local got_ok, got_err
    t.start_daemon(function(ok, err) got_ok = ok; got_err = err end)
    h.assert_false(got_ok, "raise in control.start surfaces as (false, ...)")
    h.assert_true(tostring(got_err):match("internal") ~= nil,
        "raised-call error classified as internal")
end


do
    -- The completion callback must fire exactly once even if the plugin
    -- invokes its callback more than once (SafeCallback.once guard).
    local fire_count = 0
    local fake_kosyncthing_plus_api = {
        status  = { isRunning = function() return false end },
        control = {
            start = function(cb) if cb then cb(); cb(); cb() end end,
            stop  = function(cb) if cb then cb() end end,
        },
    }
    local kosyncthing_like_provider = {
        id         = function() return "kosyncthing-stub-daemon-double" end,
        get_config = function() return {
            rest_client = { get = function() end, post = function() end,
                            post_json = function() end },
            folder_id   = "default",
            kosyncthing_plus_api    = fake_kosyncthing_plus_api,
        } end,
        supports = function(cap)
            return cap == Interface.CAPABILITIES.DAEMON_CONTROL
        end,
    }
    local t = Transport.new({
        settings_reader   = function() return true end,
        provider_discover = function() return kosyncthing_like_provider end,
        http_client_factory = function(config) return config.rest_client end,
    })

    t.start_daemon(function() fire_count = fire_count + 1 end)
    h.assert_equal(fire_count, 1,
        "start_daemon callback fires exactly once despite a triple plugin callback")
end


-- ----------------------------------------------------------------------------
-- list_folders (folder picker): enumerate the active provider's folders.
--
--   • KOSyncthing+ provider — get_config already enumerated folders live via the
--     plugin's native info.getFolders(); list_folders hands them straight back
--     (labels preserved), with no HTTP call.
--   • manual provider — a live REST fetch through FolderDiscovery, since the
--     stored config.folders may be stale.
--   • no provider     — (nil, "not_available").
-- ----------------------------------------------------------------------------


do
    -- KOSyncthing+ provider: returns the live, labeled list from config.folders.
    local kosyncthing_like_provider = {
        id         = function() return "kosyncthing-stub-folders" end,
        get_config = function() return {
            rest_client = { get = function() end, post = function() end,
                            post_json = function() end },
            folder_id   = "books-7y3xz",
            folders     = {
                { folder_id = "books-7y3xz", path = "/sd/books", label = "My Books" },
                { folder_id = "docs-aa11",   path = "/sd/docs",  label = "Docs" },
            },
            kosyncthing_plus_api    = { info = { getFolders = function() end } },
        } end,
        supports = function(_) return false end,
    }
    local recorder = make_fake_http_factory()
    local t = Transport.new({
        settings_reader     = function() return true end,
        provider_discover   = function() return kosyncthing_like_provider end,
        http_client_factory = recorder.factory,
    })

    local got_folders, got_err
    t.list_folders(function(folders, err) got_folders, got_err = folders, err end)

    h.assert_nil(got_err,                          "KOSyncthing+ list_folders: no error")
    h.assert_equal(#got_folders, 2,                "KOSyncthing+ list_folders: two folders")
    h.assert_equal(got_folders[1].folder_id, "books-7y3xz",
        "KOSyncthing+ list_folders: folder_id preserved")
    h.assert_equal(got_folders[1].label, "My Books",
        "KOSyncthing+ list_folders: label preserved")
    h.assert_equal(#recorder.calls, 0,
        "KOSyncthing+ list_folders: no HTTP call (uses the plugin's native enumeration)")
end


do
    -- Manual provider: fetches over REST via FolderDiscovery and returns
    -- parsed {folder_id, path, label} records.
    local recorder = make_fake_http_factory()
    recorder.set_response(true, nil,
        '[{"id":"lib-9","label":"Library","path":"/home/me/lib"}]')
    local t = Transport.new({
        settings_reader     = function() return true end,
        provider_discover   = fixed_provider({
            url = "http://127.0.0.1:8384", api_key = "k", folder_id = "default",
        }),
        http_client_factory = recorder.factory,
    })

    local got_folders, got_err
    t.list_folders(function(folders, err) got_folders, got_err = folders, err end)

    h.assert_nil(got_err,                          "manual list_folders: no error")
    h.assert_equal(#got_folders, 1,                "manual list_folders: one folder")
    h.assert_equal(got_folders[1].folder_id, "lib-9",
        "manual list_folders: folder_id parsed from REST")
    h.assert_equal(got_folders[1].label, "Library",
        "manual list_folders: label parsed from REST")
    h.assert_true(#recorder.calls >= 1,
        "manual list_folders: at least one HTTP GET issued")
    h.assert_equal(recorder.calls[1].method, "GET",
        "manual list_folders: enumeration is a GET")
end


do
    -- No provider at all: reports not_available cleanly, no crash.
    local t = Transport.new({
        settings_reader   = function() return true end,
        provider_discover = fixed_provider(nil),
    })

    local got_folders, got_err
    t.list_folders(function(folders, err) got_folders, got_err = folders, err end)

    h.assert_nil(got_folders,                      "no provider: nil folders")
    h.assert_equal(got_err, "not_available",       "no provider: not_available")
end


-- ----------------------------------------------------------------------------
-- test_connection (provider-aware connectivity probe): ping system/version
-- through the active provider's client — KOSyncthing+'s apiCall rest_client or
-- the generic HttpClient for a URL+key provider — never the manual key.  The
-- menu routes here only when an automatic provider supplies the key, which is
-- exactly the case the manual-only probe got wrong (row enabled, ping said
-- "no API key").
-- ----------------------------------------------------------------------------


do
    -- KOSyncthing+ provider: get_config yields a rest_client (the apiCall
    -- proxy).  test_connection must ping THROUGH it and report ok — no manual
    -- key, no URL.  The default http_factory hands back config.rest_client.
    local pinged = {}
    local rest_client = {
        get  = function(_self, path, cb) pinged[#pinged + 1] = path; cb(true, nil, "{}") end,
        post = function() end,
    }
    local t = Transport.new({
        settings_reader   = function() return "on" end,
        provider_discover = fixed_provider({
            rest_client = rest_client,
            folder_id   = "books",
            folders     = { { folder_id = "books", path = "/b", label = "B" } },
            kosyncthing_plus_api = {},
        }),
    })
    local got
    t.test_connection(function(ok, _code, diag) got = { ok = ok, diag = diag } end)
    h.assert_true(got ~= nil and got.ok == true,
        "test_connection: KOSyncthing+ rest_client path reports ok (apiCall used, not manual key)")
    h.assert_equal(got.diag, "ok", "test_connection: KOSyncthing+ diag is ok")
    h.assert_equal(pinged[1], "/rest/system/version",
        "test_connection: pings system/version through the active provider's client")
end


do
    -- URL+key provider (config.xml / manual): pings via the HttpClient the
    -- factory builds; a clean success reports ok at the provider URL.
    local recorder = make_fake_http_factory()
    recorder.set_response(true, nil, "{}")
    local t = Transport.new({
        settings_reader     = function() return "on" end,
        http_client_factory = recorder.factory,
        provider_discover   = fixed_provider({
            url = "http://127.0.0.1:8384", api_key = "k", folder_id = "f",
        }),
    })
    local got
    t.test_connection(function(ok, _c, diag) got = { ok = ok, diag = diag } end)
    h.assert_true(got.ok == true and got.diag == "ok",
        "test_connection: URL+key success reports ok")
    h.assert_equal(recorder.calls[#recorder.calls].url,
        "http://127.0.0.1:8384/rest/system/version",
        "test_connection: URL+key pings system/version at the provider URL")
end


do
    -- A no-response failure surfaces as unreachable (not a crash).
    local recorder = make_fake_http_factory()
    recorder.set_response(false, "unreachable", "")
    local t = Transport.new({
        settings_reader     = function() return "on" end,
        http_client_factory = recorder.factory,
        provider_discover   = fixed_provider({
            url = "http://127.0.0.1:8384", api_key = "k", folder_id = "f",
        }),
    })
    local got
    t.test_connection(function(ok, _c, diag) got = { ok = ok, diag = diag } end)
    h.assert_false(got.ok, "test_connection: unreachable -> not ok")
    h.assert_equal(got.diag, "unreachable", "test_connection: unreachable diag")
end


do
    -- No provider at all: not_available, no crash.
    local t = Transport.new({
        settings_reader   = function() return "on" end,
        provider_discover = fixed_provider(nil),
    })
    local got
    t.test_connection(function(ok, _c, diag) got = { ok = ok, diag = diag } end)
    h.assert_false(got.ok, "test_connection: no provider -> not ok")
    h.assert_equal(got.diag, "not_available", "test_connection: no provider -> not_available")
end
