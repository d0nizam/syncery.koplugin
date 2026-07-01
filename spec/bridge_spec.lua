-- =============================================================================
-- spec/bridge_spec.lua
-- =============================================================================
--
-- Tests for syncery_transports/bridge.lua — the adapter between
-- main.lua's per-transport callsites and the uniform orchestrator API.
--
-- We don't use a real orchestrator here; a tiny fake that records
-- push_book calls is plenty.  This file's job is to verify the
-- TRANSLATION (call shape → opts shape), not to re-test the
-- orchestrator.
--
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_bridge_spec_" .. tostring(os.time()))

local Bridge = require("syncery_transports/bridge")
local Stignore = require("syncery_transports/stignore")


-- ----------------------------------------------------------------------------
-- Fake orchestrator: records every push_book call.
-- ----------------------------------------------------------------------------


local function make_fake_orch()
    local rec = {
        calls = {},
        shutdown_called = 0,
        status_value = {},
        -- transport_id → fake transport table.  Bridge calls
        -- _orch:find_transport(id); we hand the registered one back, or
        -- nil if nothing's been registered under that id.
        transports = {},
    }
    rec.orch = {
        push_book = function(_self, file, opts, caller_opts)
            table.insert(rec.calls, {
                file        = file,
                opts        = opts,
                caller_opts = caller_opts,
            })
        end,
        get_status     = function(_self) return rec.status_value end,
        shutdown       = function(_self) rec.shutdown_called = rec.shutdown_called + 1 end,
        find_transport = function(_self, id) return rec.transports[id] end,
    }
    return rec
end


-- ----------------------------------------------------------------------------
-- Constructor requires an orchestrator.
-- ----------------------------------------------------------------------------


do
    local ok = pcall(Bridge.new, {})
    h.assert_false(ok, "missing orchestrator rejected")

    local ok2 = pcall(Bridge.new, { orchestrator = "not a table" })
    h.assert_false(ok2, "non-table orchestrator rejected")

    local ok3 = pcall(Bridge.new, nil)
    h.assert_false(ok3, "nil opts rejected")
end


-- ----------------------------------------------------------------------------
-- push_syncthing_scan forwards with opts.sub.
-- ----------------------------------------------------------------------------


do
    local fake = make_fake_orch()
    local bridge = Bridge.new({ orchestrator = fake.orch })

    bridge:push_syncthing_scan("/books/x.epub", { sub = "subdir/x.epub" })

    h.assert_equal(#fake.calls, 1, "one push_book call")
    h.assert_equal(fake.calls[1].file, "/books/x.epub", "book file passed through")
    h.assert_equal(fake.calls[1].opts.sub, "subdir/x.epub",
        "sub forwarded to orchestrator opts")
end


-- ----------------------------------------------------------------------------
-- push_syncthing_scan with nil opts works (sub will be nil).
-- ----------------------------------------------------------------------------


do
    local fake = make_fake_orch()
    local bridge = Bridge.new({ orchestrator = fake.orch })

    bridge:push_syncthing_scan("/books/x.epub", nil)
    h.assert_equal(#fake.calls, 1,           "still called")
    h.assert_nil(fake.calls[1].opts.sub,      "sub is nil")
end


-- ----------------------------------------------------------------------------
-- K: a forced scan scopes force to the Syncthing tid ONLY — never a bare `true`
-- that would also force the nil-payload push onto Cloud (REJECTED, clobbering a
-- just-sent cloud upload's status).  No force requested -> no caller force.
-- ----------------------------------------------------------------------------


do
    local fake = make_fake_orch()
    local bridge = Bridge.new({ orchestrator = fake.orch })

    bridge:push_syncthing_scan("/books/x.epub", { sub = "s/x", force = true })

    local c = fake.calls[1].caller_opts
    h.assert_true(type(c) == "table" and type(c.force) == "table",
        "force forwarded as a tid-set, not a bare true")
    h.assert_true(c.force.syncthing == true, "syncthing tid forced")
    h.assert_nil(c.force.cloud, "cloud NOT forced (no REJECTED clobber)")
end


do
    local fake = make_fake_orch()
    local bridge = Bridge.new({ orchestrator = fake.orch })

    bridge:push_syncthing_scan("/books/x.epub", { sub = "s/x" })   -- no force

    local c = fake.calls[1].caller_opts
    h.assert_true(c == nil or c.force == nil,
        "no force requested -> no caller force (normal policy applies)")
end


-- ----------------------------------------------------------------------------
-- push_cloud_files: one push_book per entry; BOTH entries force-bypass
-- the per-book debounce (progress + annotations are distinct files that
-- must each upload on every push — the per-book debounce cannot tell
-- them apart, so forcing only the second left progress droppable).
-- ----------------------------------------------------------------------------


do
    local fake = make_fake_orch()
    local bridge = Bridge.new({
        orchestrator = fake.orch,
        doc_id_fn    = function() return "book-md5" end,
    })

    bridge:push_cloud_files("/x.epub", {
        { kind = "progress",    content = '{"p":42}' },
        { kind = "annotations", content = '[{"a":1}]' },
    })

    h.assert_equal(#fake.calls, 2, "two push_book calls (one per entry)")
    -- First entry (progress): MUST be forced now — otherwise the per-book
    -- debounce drops it whenever a cloud upload lands within 60 s of a
    -- prior push (close after autosave, second manual sync) while the
    -- forced annotations entry always goes.
    local first = fake.calls[1]
    h.assert_equal(first.opts.payload.kind,    "progress",        "1st entry kind")
    h.assert_equal(first.opts.payload.book_id, "book-md5",         "book_id forwarded")
    h.assert_equal(first.opts.payload.content, '{"p":42}',         "content forwarded")
    h.assert_true(first.caller_opts and first.caller_opts.force,
        "1st entry (progress): forced (bypasses per-book debounce so progress is never dropped)")

    -- Second entry (annotations): also forced.
    local second = fake.calls[2]
    h.assert_equal(second.opts.payload.kind, "annotations",        "2nd entry kind")
    h.assert_true(second.caller_opts and second.caller_opts.force,
        "2nd entry (annotations): forced (bypasses debounce so both files upload)")
end


-- ----------------------------------------------------------------------------
-- push_cloud_files: empty entries → no calls.
-- ----------------------------------------------------------------------------


do
    local fake = make_fake_orch()
    local bridge = Bridge.new({
        orchestrator = fake.orch,
        doc_id_fn    = function() return "x" end,
    })
    bridge:push_cloud_files("/x.epub", {})
    h.assert_equal(#fake.calls, 0, "empty list → no calls")

    bridge:push_cloud_files("/x.epub", nil)
    h.assert_equal(#fake.calls, 0, "nil list → no calls")
end


-- ----------------------------------------------------------------------------
-- push_cloud_files: no book_id → no push (loud-but-non-fatal).
-- ----------------------------------------------------------------------------


do
    local fake = make_fake_orch()
    local bridge = Bridge.new({
        orchestrator = fake.orch,
        doc_id_fn    = function() return nil end,
    })
    bridge:push_cloud_files("/x.epub", {
        { kind = "progress", content = "{}" },
    })
    h.assert_equal(#fake.calls, 0, "no book_id → no push")
end


-- ----------------------------------------------------------------------------
-- get_status / shutdown proxy through.
-- ----------------------------------------------------------------------------


do
    local fake = make_fake_orch()
    fake.status_value = { syncthing = { available = true } }
    local bridge = Bridge.new({ orchestrator = fake.orch })

    local s = bridge:get_status()
    h.assert_equal(s.syncthing.available, true, "status proxied through")

    bridge:shutdown()
    h.assert_equal(fake.shutdown_called, 1, "shutdown proxied through")

    -- Idempotent semantics live in the orchestrator, not the bridge.
    -- The bridge just proxies — calling it twice calls through twice.
    bridge:shutdown()
    h.assert_equal(fake.shutdown_called, 2, "second shutdown also proxied")
end


-- ----------------------------------------------------------------------------
-- Fake Syncthing transport for the helper tests.  Records every call so
-- assertions can inspect WHAT was forwarded; supports the capability
-- and folder-id surface the bridge depends on.
-- ----------------------------------------------------------------------------


local function make_fake_syncthing_transport(opts)
    opts = opts or {}
    local rec = {
        get_ignore_calls = {},   -- { folder_id, ... }
        set_ignore_calls = {},   -- { folder_id, patterns, ... }
        quick_sync_calls = 0,
        start_daemon_calls = 0,
        stop_daemon_calls  = 0,
        daemon_running     = opts.daemon_running == true,
        existing_patterns = opts.existing_patterns or {},
        -- Periodic sync (Phase 14.7) seeds + counters.
        periodic_enabled  = opts.periodic_enabled == true,
        periodic_interval = opts.periodic_interval or 0,
        set_periodic_enabled_calls  = 0,
        set_periodic_interval_calls = 0,
        run_periodic_now_calls      = 0,
        list_folders_calls          = 0,
        register_conflict_calls     = {},   -- { {plugin_id, pattern}, ... }
    }
    local t = {
        id           = function() return "syncthing" end,
        display_name = function() return "Syncthing" end,
        is_available = function() return opts.available ~= false end,
        is_eventually_consistent = function() return true end,
        push         = function(_, _, cb) cb(true, nil, nil) end,
        pull         = function(_, _, cb) cb(true, nil, nil) end,
        status       = function() return { available = opts.available ~= false } end,
        supports     = function(cap)
            -- The set of advertised capabilities is controlled by the
            -- test's caller: opts.capabilities is a map.  Default: no
            -- capabilities (so a bridge call gates off cleanly).
            if not opts.capabilities then return false end
            return opts.capabilities[cap] == true
        end,
        get_folder_id = function() return opts.folder_id end,
        list_folders = function(cb)
            rec.list_folders_calls = rec.list_folders_calls + 1
            if opts.list_folders_err then cb(nil, opts.list_folders_err)
            else cb(opts.folders or {}, nil) end
        end,
        get_folder_ignore = function(folder_id, cb)
            table.insert(rec.get_ignore_calls, folder_id)
            if opts.get_ignore_fails then
                cb(false, "unreachable", nil)
            else
                cb(true, nil, rec.existing_patterns)
            end
        end,
        set_folder_ignore = function(folder_id, patterns, cb)
            table.insert(rec.set_ignore_calls,
                { folder_id = folder_id, patterns = patterns })
            cb(true, nil, nil)
        end,
        quick_sync_all = function()
            rec.quick_sync_calls = rec.quick_sync_calls + 1
            if opts.quick_sync_returns_nil then
                return nil, opts.quick_sync_error or "fake-err"
            end
            return true
        end,
        -- Daemon control (Phase 11).  `opts.daemon_running` seeds the
        -- running state; start/stop flip it and record the call.
        is_daemon_running = function()
            if opts.capabilities and opts.capabilities.daemon_control then
                return rec.daemon_running
            end
            return nil
        end,
        start_daemon = function(cb)
            rec.start_daemon_calls = rec.start_daemon_calls + 1
            rec.daemon_running = true
            if cb then cb(true) end
        end,
        stop_daemon = function(cb)
            rec.stop_daemon_calls = rec.stop_daemon_calls + 1
            rec.daemon_running = false
            if cb then cb(true) end
        end,
        -- Periodic sync (Phase 14.7).  Gated on the periodic_sync capability;
        -- opts seeds the state, the setters record + mutate it.
        get_periodic_sync_state = function()
            if not (opts.capabilities and opts.capabilities.periodic_sync) then return nil end
            return {
                enabled          = rec.periodic_enabled,
                interval_minutes = rec.periodic_interval,
                next_at          = opts.periodic_next_at,
            }
        end,
        set_periodic_sync_enabled = function(enabled)
            rec.set_periodic_enabled_calls = rec.set_periodic_enabled_calls + 1
            if opts.periodic_set_fails then return nil, "kosyncthing-err" end
            rec.periodic_enabled = enabled and true or false
            return true
        end,
        set_periodic_sync_interval = function(minutes)
            rec.set_periodic_interval_calls = rec.set_periodic_interval_calls + 1
            if opts.periodic_set_fails then return nil, "kosyncthing-err" end
            rec.periodic_interval = minutes
            return true
        end,
        run_periodic_sync_now = function()
            rec.run_periodic_now_calls = rec.run_periodic_now_calls + 1
            if opts.periodic_set_fails then return nil, "kosyncthing-err" end
            return true
        end,
        -- Conflict-scanner ignore registry.  Records the (plugin_id, pattern)
        -- the bridge forwards; opts.register_conflict_returns_nil simulates a
        -- failed registration.
        register_conflict_scanner_ignore = function(plugin_id, pattern)
            table.insert(rec.register_conflict_calls,
                { plugin_id = plugin_id, pattern = pattern })
            if opts.register_conflict_returns_nil then
                return nil, opts.register_conflict_error or "fake-err"
            end
            return true
        end,
    }
    rec.transport = t
    return rec
end


-- ----------------------------------------------------------------------------
-- register_syncery_ignore_patterns: no transport → false, no-op.
-- ----------------------------------------------------------------------------


do
    local fake = make_fake_orch()
    -- No transports registered.
    local bridge = Bridge.new({ orchestrator = fake.orch })

    local ok = bridge:register_syncery_ignore_patterns()
    h.assert_false(ok, "no transport => returns false")
end


-- ----------------------------------------------------------------------------
-- register_syncery_ignore_patterns: transport unavailable → false.
-- ----------------------------------------------------------------------------


do
    local fake = make_fake_orch()
    local syn = make_fake_syncthing_transport({
        available = false,
        capabilities = { ignore_patterns = true },
        folder_id = "default",
    })
    fake.transports.syncthing = syn.transport
    local bridge = Bridge.new({ orchestrator = fake.orch })

    local ok = bridge:register_syncery_ignore_patterns()
    h.assert_false(ok, "unavailable transport => returns false")
    h.assert_equal(#syn.set_ignore_calls, 0, "no set call dispatched")
end


-- ----------------------------------------------------------------------------
-- register_syncery_ignore_patterns: capability missing → false.
-- ----------------------------------------------------------------------------


do
    local fake = make_fake_orch()
    local syn = make_fake_syncthing_transport({
        available = true,
        capabilities = {},   -- no IGNORE_PATTERNS
        folder_id = "default",
    })
    fake.transports.syncthing = syn.transport
    local bridge = Bridge.new({ orchestrator = fake.orch })

    local ok = bridge:register_syncery_ignore_patterns()
    h.assert_false(ok, "no IGNORE_PATTERNS capability => false")
    h.assert_equal(#syn.set_ignore_calls, 0, "no set call dispatched")
end


-- ----------------------------------------------------------------------------
-- register_syncery_ignore_patterns: no folder_id resolvable → false.
-- ----------------------------------------------------------------------------


do
    local fake = make_fake_orch()
    local syn = make_fake_syncthing_transport({
        available = true,
        capabilities = { ignore_patterns = true },
        folder_id = nil,
    })
    fake.transports.syncthing = syn.transport
    local bridge = Bridge.new({ orchestrator = fake.orch })

    local ok = bridge:register_syncery_ignore_patterns()
    h.assert_false(ok, "no folder_id => false")
end


-- ----------------------------------------------------------------------------
-- register_syncery_ignore_patterns: happy path.  set_folder_ignore is
-- called with the union of existing patterns + Syncery's three.
-- ----------------------------------------------------------------------------


do
    local fake = make_fake_orch()
    local syn = make_fake_syncthing_transport({
        available = true,
        capabilities = { ignore_patterns = true },
        folder_id = "books-folder",
        existing_patterns = { "Thumbs.db" },
    })
    fake.transports.syncthing = syn.transport
    local bridge = Bridge.new({ orchestrator = fake.orch })

    local ok = bridge:register_syncery_ignore_patterns()
    h.assert_true(ok, "dispatched successfully")
    h.assert_equal(#syn.get_ignore_calls, 1, "read existing patterns first")
    h.assert_equal(syn.get_ignore_calls[1], "books-folder",
        "queried the right folder")
    h.assert_equal(#syn.set_ignore_calls, 1, "wrote once")
    h.assert_equal(syn.set_ignore_calls[1].folder_id, "books-folder",
        "wrote to the right folder")

    local patterns = syn.set_ignore_calls[1].patterns
    -- Existing pattern preserved.
    local saw_thumbs = false
    for _, p in ipairs(patterns) do
        if p == "Thumbs.db" then saw_thumbs = true end
    end
    h.assert_true(saw_thumbs, "existing Thumbs.db pattern preserved")
    -- Piece 3 + Option 4: the REST registrar writes EXACTLY the centralized
    -- ignore list (Stignore.PATTERNS) — single source of truth, so the REST
    -- path and the `.stignore` file writer can never drift apart.
    for _, want in ipairs(Stignore.PATTERNS) do
        local found = false
        for _, p in ipairs(patterns) do
            if p == want then found = true; break end
        end
        h.assert_true(found, "REST registered centralized pattern: " .. want)
    end
    -- Syncery's own conflict pattern appears exactly once (not duplicated).
    local conflict_count = 0
    for _, p in ipairs(patterns) do
        if p:match("syncery%-") and p:match("sync%-conflict%-") then
            conflict_count = conflict_count + 1
        end
    end
    h.assert_equal(conflict_count, 1, "the syncery conflict pattern appears exactly once")
end


-- ----------------------------------------------------------------------------
-- register_conflict_menu_ignore: the SCANNER half (KOSyncthing+ IgnoreRegistry).
-- Gated on the syncthing transport being available + advertising
-- CONFLICT_IGNORE_REGISTRY; forwards Syncery's plugin id + the single
-- conflict pattern (Stignore.CONFLICT_PATTERN) to the transport.
-- ----------------------------------------------------------------------------


do
    -- No transport → false, no-op.
    local fake = make_fake_orch()
    local bridge = Bridge.new({ orchestrator = fake.orch })
    local ok = bridge:register_conflict_menu_ignore()
    h.assert_false(ok, "no transport => false")
end


do
    -- Transport unavailable → false, nothing forwarded.
    local fake = make_fake_orch()
    local syn = make_fake_syncthing_transport({
        available = false,
        capabilities = { conflict_ignore_registry = true },
    })
    fake.transports.syncthing = syn.transport
    local bridge = Bridge.new({ orchestrator = fake.orch })
    local ok = bridge:register_conflict_menu_ignore()
    h.assert_false(ok, "unavailable transport => false")
    h.assert_equal(#syn.register_conflict_calls, 0, "no registration dispatched")
end


do
    -- Capability missing → false, nothing forwarded.
    local fake = make_fake_orch()
    local syn = make_fake_syncthing_transport({
        available = true,
        capabilities = {},   -- no CONFLICT_IGNORE_REGISTRY
    })
    fake.transports.syncthing = syn.transport
    local bridge = Bridge.new({ orchestrator = fake.orch })
    local ok = bridge:register_conflict_menu_ignore()
    h.assert_false(ok, "no CONFLICT_IGNORE_REGISTRY capability => false")
    h.assert_equal(#syn.register_conflict_calls, 0, "no registration dispatched")
end


do
    -- Happy path: forwards Syncery's plugin id + the single conflict pattern.
    local fake = make_fake_orch()
    local syn = make_fake_syncthing_transport({
        available = true,
        capabilities = { conflict_ignore_registry = true },
    })
    fake.transports.syncthing = syn.transport
    local bridge = Bridge.new({ orchestrator = fake.orch })
    local ok = bridge:register_conflict_menu_ignore()
    h.assert_true(ok, "dispatched successfully")
    h.assert_equal(#syn.register_conflict_calls, 1, "registered once")
    h.assert_equal(syn.register_conflict_calls[1].plugin_id, "syncery",
        "forwarded the 'syncery' plugin id (matches the plugin directory name)")
    -- The bridge forwards the SCANNER glob (CONFLICT_SCANNER_PATTERN), which
    -- the KOSyncthing+ registry matches against the de-mangled ORIGINAL name —
    -- deliberately DIFFERENT from the `.stignore` literal-copy glob.
    h.assert_equal(syn.register_conflict_calls[1].pattern, Stignore.CONFLICT_SCANNER_PATTERN,
        "forwarded Stignore.CONFLICT_SCANNER_PATTERN")
    h.assert_equal(Stignore.CONFLICT_SCANNER_PATTERN, "*syncery-*",
        "scanner pattern is the broad original-name glob")
    h.assert_true(Stignore.CONFLICT_SCANNER_PATTERN ~= Stignore.CONFLICT_PATTERN,
        "scanner glob and .stignore glob are deliberately different (de-mangled vs literal)")
end


do
    -- Transport-side registration fails → bridge returns false (call was
    -- still attempted).
    local fake = make_fake_orch()
    local syn = make_fake_syncthing_transport({
        available = true,
        capabilities = { conflict_ignore_registry = true },
        register_conflict_returns_nil = true,
    })
    fake.transports.syncthing = syn.transport
    local bridge = Bridge.new({ orchestrator = fake.orch })
    local ok = bridge:register_conflict_menu_ignore()
    h.assert_false(ok, "registration failure => false")
    h.assert_equal(#syn.register_conflict_calls, 1, "attempted once")
end


-- ----------------------------------------------------------------------------
-- register_syncery_ignore_patterns: idempotent.  Calling twice
-- doesn't duplicate Syncery's patterns.
-- ----------------------------------------------------------------------------


do
    local fake = make_fake_orch()
    local syn = make_fake_syncthing_transport({
        available = true,
        capabilities = { ignore_patterns = true },
        folder_id = "books-folder",
        existing_patterns = {},
    })
    fake.transports.syncthing = syn.transport
    local bridge = Bridge.new({ orchestrator = fake.orch })

    bridge:register_syncery_ignore_patterns()
    -- Simulate the daemon persisting what we just wrote — the second
    -- call's read sees those patterns as the existing state.
    syn.existing_patterns = syn.set_ignore_calls[1].patterns
    bridge:register_syncery_ignore_patterns()

    -- The second set call's pattern list shouldn't be larger than the
    -- first's (any addition would be a duplicate of an existing entry).
    h.assert_equal(#syn.set_ignore_calls[2].patterns,
        #syn.set_ignore_calls[1].patterns,
        "idempotent: second call writes same-size list")
end


-- ----------------------------------------------------------------------------
-- register_syncery_ignore_patterns: get_folder_ignore failure → write
-- still proceeds with just our patterns (best-effort).
-- ----------------------------------------------------------------------------


do
    local fake = make_fake_orch()
    local syn = make_fake_syncthing_transport({
        available = true,
        capabilities = { ignore_patterns = true },
        folder_id = "books-folder",
        get_ignore_fails = true,
    })
    fake.transports.syncthing = syn.transport
    local bridge = Bridge.new({ orchestrator = fake.orch })

    bridge:register_syncery_ignore_patterns()
    h.assert_equal(#syn.set_ignore_calls, 1,
        "still dispatched a write despite the get failure")
    h.assert_equal(#syn.set_ignore_calls[1].patterns, #Stignore.PATTERNS,
        "wrote exactly Syncery's centralized pattern list (nothing to merge)")
end


-- ----------------------------------------------------------------------------
-- request_quick_sync: no transport → nil + error.
-- ----------------------------------------------------------------------------


do
    local fake = make_fake_orch()
    local bridge = Bridge.new({ orchestrator = fake.orch })

    local ok, err = bridge:request_quick_sync()
    h.assert_nil(ok, "no transport => nil")
    h.assert_true(tostring(err):match("no syncthing") ~= nil,
        "error explains the missing transport")
end


-- ----------------------------------------------------------------------------
-- request_quick_sync: capability absent → nil + error, no call dispatched.
-- ----------------------------------------------------------------------------


do
    local fake = make_fake_orch()
    local syn = make_fake_syncthing_transport({
        available = true,
        capabilities = {},   -- no QUICK_SYNC
        folder_id = "default",
    })
    fake.transports.syncthing = syn.transport
    local bridge = Bridge.new({ orchestrator = fake.orch })

    local ok, err = bridge:request_quick_sync()
    h.assert_nil(ok, "QUICK_SYNC not supported => nil")
    h.assert_true(tostring(err):match("not supported") ~= nil,
        "error explains")
    h.assert_equal(syn.quick_sync_calls, 0, "no call dispatched")
end


-- ----------------------------------------------------------------------------
-- request_quick_sync: happy path.
-- ----------------------------------------------------------------------------


do
    local fake = make_fake_orch()
    local syn = make_fake_syncthing_transport({
        available = true,
        capabilities = { quick_sync = true },
        folder_id = "default",
    })
    fake.transports.syncthing = syn.transport
    local bridge = Bridge.new({ orchestrator = fake.orch })

    local ok = bridge:request_quick_sync()
    h.assert_true(ok, "quick_sync dispatched")
    h.assert_equal(syn.quick_sync_calls, 1, "transport.quick_sync_all called once")
end


-- ----------------------------------------------------------------------------
-- request_quick_sync: transport returns nil + err → bridge surfaces it.
-- ----------------------------------------------------------------------------


do
    local fake = make_fake_orch()
    local syn = make_fake_syncthing_transport({
        available = true,
        capabilities = { quick_sync = true },
        folder_id = "default",
        quick_sync_returns_nil = true,
        quick_sync_error = "daemon offline",
    })
    fake.transports.syncthing = syn.transport
    local bridge = Bridge.new({ orchestrator = fake.orch })

    local ok, err = bridge:request_quick_sync()
    h.assert_nil(ok, "transport-side failure => nil")
    h.assert_true(tostring(err):match("daemon offline") ~= nil,
        "error propagated from transport")
end


-- ----------------------------------------------------------------------------
-- Daemon control (Phase 11): supports_daemon_control / is_daemon_running /
-- start_daemon / stop_daemon — passthroughs gated like request_quick_sync.
-- ----------------------------------------------------------------------------


-- No syncthing transport → every daemon-control call gates off cleanly.
do
    local fake = make_fake_orch()
    local bridge = Bridge.new({ orchestrator = fake.orch })

    h.assert_false(bridge:supports_daemon_control(),
        "no transport → supports_daemon_control false")
    h.assert_nil(bridge:is_daemon_running(),
        "no transport → is_daemon_running nil")

    local got_ok, got_err
    bridge:start_daemon(function(ok, err) got_ok = ok; got_err = err end)
    h.assert_false(got_ok, "no transport → start_daemon (false, ...)")
    h.assert_true(tostring(got_err):match("no syncthing transport") ~= nil,
        "start_daemon: reason names the missing transport")
end


-- Transport present but daemon_control capability absent → gates off.
do
    local fake = make_fake_orch()
    local syn = make_fake_syncthing_transport({
        available = true,
        capabilities = {},   -- no daemon_control
    })
    fake.transports.syncthing = syn.transport
    local bridge = Bridge.new({ orchestrator = fake.orch })

    h.assert_false(bridge:supports_daemon_control(),
        "capability absent → supports_daemon_control false")
    h.assert_nil(bridge:is_daemon_running(),
        "capability absent → is_daemon_running nil")

    local got_ok, got_err
    bridge:stop_daemon(function(ok, err) got_ok = ok; got_err = err end)
    h.assert_false(got_ok, "capability absent → stop_daemon (false, ...)")
    h.assert_true(tostring(got_err):match("not supported") ~= nil,
        "stop_daemon: reason explains the unsupported capability")
    h.assert_equal(syn.stop_daemon_calls, 0,
        "capability absent → transport.stop_daemon never reached")
end


-- Transport present but unavailable → gates off.
do
    local fake = make_fake_orch()
    local syn = make_fake_syncthing_transport({
        available = false,
        capabilities = { daemon_control = true },
    })
    fake.transports.syncthing = syn.transport
    local bridge = Bridge.new({ orchestrator = fake.orch })

    h.assert_false(bridge:supports_daemon_control(),
        "unavailable transport → supports_daemon_control false")

    local got_ok, got_err
    bridge:start_daemon(function(ok, err) got_ok = ok; got_err = err end)
    h.assert_false(got_ok, "unavailable → start_daemon (false, ...)")
    h.assert_true(tostring(got_err):match("not available") ~= nil,
        "start_daemon: reason explains the unavailable transport")
end


-- Happy path: capability present, daemon stopped → start flips it.
do
    local fake = make_fake_orch()
    local syn = make_fake_syncthing_transport({
        available = true,
        capabilities = { daemon_control = true },
        daemon_running = false,
    })
    fake.transports.syncthing = syn.transport
    local bridge = Bridge.new({ orchestrator = fake.orch })

    h.assert_true(bridge:supports_daemon_control(),
        "capability present + available → supports_daemon_control true")
    h.assert_false(bridge:is_daemon_running(),
        "daemon initially stopped")

    local started
    bridge:start_daemon(function(ok) started = ok end)
    h.assert_true(started, "start_daemon → (true)")
    h.assert_equal(syn.start_daemon_calls, 1,
        "transport.start_daemon dispatched once")
    h.assert_true(bridge:is_daemon_running(),
        "is_daemon_running reflects the started daemon")

    local stopped
    bridge:stop_daemon(function(ok) stopped = ok end)
    h.assert_true(stopped, "stop_daemon → (true)")
    h.assert_equal(syn.stop_daemon_calls, 1,
        "transport.stop_daemon dispatched once")
    h.assert_false(bridge:is_daemon_running(),
        "is_daemon_running reflects the stopped daemon")
end


-- start_daemon / stop_daemon tolerate a nil callback (fire-and-forget).
do
    local fake = make_fake_orch()
    local syn = make_fake_syncthing_transport({
        available = true,
        capabilities = { daemon_control = true },
        daemon_running = false,
    })
    fake.transports.syncthing = syn.transport
    local bridge = Bridge.new({ orchestrator = fake.orch })

    local ok = pcall(function() bridge:start_daemon(nil) end)
    h.assert_true(ok, "start_daemon with nil callback does not raise")
    h.assert_equal(syn.start_daemon_calls, 1,
        "nil-callback start still dispatched to the transport")
end


-- ----------------------------------------------------------------------------
-- Periodic sync (Phase 14.7): supports_periodic_sync / get_periodic_sync_state
-- / set_periodic_sync_enabled / set_periodic_sync_interval /
-- run_periodic_sync_now — passthroughs gated like daemon control.
-- ----------------------------------------------------------------------------


-- No transport at all → everything gates off cleanly.
do
    local fake = make_fake_orch()
    local bridge = Bridge.new({ orchestrator = fake.orch })
    h.assert_false(bridge:supports_periodic_sync(),
        "no transport → supports_periodic_sync false")
    h.assert_nil(bridge:get_periodic_sync_state(),
        "no transport → nil periodic state")
    local ok, err = bridge:set_periodic_sync_enabled(true)
    h.assert_nil(ok, "no transport → set_enabled returns nil")
    h.assert_true(err ~= nil, "no transport → set_enabled gives a reason")
end


-- Transport present but capability NOT advertised → gated off.
do
    local fake = make_fake_orch()
    local syn = make_fake_syncthing_transport({ available = true, capabilities = {} })
    fake.transports.syncthing = syn.transport
    local bridge = Bridge.new({ orchestrator = fake.orch })
    h.assert_false(bridge:supports_periodic_sync(),
        "capability absent → supports_periodic_sync false")
    h.assert_nil(bridge:get_periodic_sync_state(),
        "capability absent → nil periodic state")
    h.assert_equal(syn.set_periodic_enabled_calls, 0,
        "capability absent → setter not dispatched")
    local _ok = bridge:set_periodic_sync_interval(30)
    h.assert_equal(syn.set_periodic_interval_calls, 0,
        "capability absent → interval setter not dispatched either")
end


-- Capability advertised → state read + setters pass through and mutate.
do
    local fake = make_fake_orch()
    local syn = make_fake_syncthing_transport({
        available = true,
        capabilities = { periodic_sync = true },
        periodic_enabled = true,
        periodic_interval = 15,
        periodic_next_at = 1234567890,
    })
    fake.transports.syncthing = syn.transport
    local bridge = Bridge.new({ orchestrator = fake.orch })

    h.assert_true(bridge:supports_periodic_sync(),
        "capability present → supports_periodic_sync true")

    local st = bridge:get_periodic_sync_state()
    h.assert_true(st ~= nil, "state returned")
    h.assert_true(st.enabled, "state: enabled passed through")
    h.assert_equal(st.interval_minutes, 15, "state: interval passed through")
    h.assert_equal(st.next_at, 1234567890, "state: next_at passed through")

    h.assert_true(bridge:set_periodic_sync_enabled(false),
        "set_enabled returns ok")
    h.assert_equal(syn.set_periodic_enabled_calls, 1, "set_enabled dispatched once")
    h.assert_false(syn.periodic_enabled, "set_enabled mutated the state")

    h.assert_true(bridge:set_periodic_sync_interval(45),
        "set_interval returns ok")
    h.assert_equal(syn.periodic_interval, 45, "set_interval mutated the state")

    h.assert_true(bridge:run_periodic_sync_now(), "run_now returns ok")
    h.assert_equal(syn.run_periodic_now_calls, 1, "run_now dispatched once")
end


-- A KOSyncthing+-side failure surfaces as (nil, err), not a raise.
do
    local fake = make_fake_orch()
    local syn = make_fake_syncthing_transport({
        available = true,
        capabilities = { periodic_sync = true },
        periodic_set_fails = true,
    })
    fake.transports.syncthing = syn.transport
    local bridge = Bridge.new({ orchestrator = fake.orch })

    local ok, err = bridge:set_periodic_sync_enabled(true)
    h.assert_nil(ok, "KOSyncthing+ failure → nil")
    h.assert_true(err ~= nil, "KOSyncthing+ failure → error string")
end


-- ----------------------------------------------------------------------------
-- list_folders: forwards to the syncthing transport's enumeration.
--
--   • no syncthing transport      → (nil, "not_available"), no delegation
--   • transport present but down  → (nil, "not_available"), no delegation
--   • transport available         → delegates; folders passed through
--   • transport returns an error  → error passed through unchanged
-- ----------------------------------------------------------------------------


do
    local fake = make_fake_orch()
    local bridge = Bridge.new({ orchestrator = fake.orch })

    local got_folders, got_err
    bridge:list_folders(function(folders, err) got_folders, got_err = folders, err end)
    h.assert_nil(got_folders, "no transport → nil folders")
    h.assert_equal(got_err, "not_available", "no transport → not_available")
end


do
    local fake = make_fake_orch()
    local syn = make_fake_syncthing_transport({
        available = false,
        folders   = { { folder_id = "a", path = "/a", label = "A" } },
    })
    fake.transports.syncthing = syn.transport
    local bridge = Bridge.new({ orchestrator = fake.orch })

    local got_folders, got_err
    bridge:list_folders(function(folders, err) got_folders, got_err = folders, err end)
    h.assert_nil(got_folders, "unavailable transport → nil folders")
    h.assert_equal(got_err, "not_available", "unavailable transport → not_available")
    h.assert_equal(syn.list_folders_calls, 0, "unavailable → no delegation")
end


do
    local fake = make_fake_orch()
    local syn = make_fake_syncthing_transport({
        available = true,
        folders   = {
            { folder_id = "books", path = "/sd/books", label = "Books" },
            { folder_id = "docs",  path = "/sd/docs",  label = "Docs" },
        },
    })
    fake.transports.syncthing = syn.transport
    local bridge = Bridge.new({ orchestrator = fake.orch })

    local got_folders, got_err
    bridge:list_folders(function(folders, err) got_folders, got_err = folders, err end)
    h.assert_equal(syn.list_folders_calls, 1, "available → delegated once")
    h.assert_nil(got_err, "available → no error")
    h.assert_equal(#got_folders, 2, "available → both folders passed through")
    h.assert_equal(got_folders[1].label, "Books", "label passed through")
end


do
    local fake = make_fake_orch()
    local syn = make_fake_syncthing_transport({
        available        = true,
        list_folders_err = "no_folders",
    })
    fake.transports.syncthing = syn.transport
    local bridge = Bridge.new({ orchestrator = fake.orch })

    local got_folders, got_err
    bridge:list_folders(function(folders, err) got_folders, got_err = folders, err end)
    h.assert_nil(got_folders, "error → nil folders")
    h.assert_equal(got_err, "no_folders", "transport error passed through unchanged")
end
