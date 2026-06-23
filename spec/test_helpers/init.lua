-- =============================================================================
-- spec/test_helpers/init.lua
-- =============================================================================
--
-- A tiny test harness for running unit tests against the syncery_ann/
-- modules from a plain LuaJIT shell, without spinning up KOReader.
--
-- Most of the modules depend on a handful of KOReader globals and
-- libraries.  This helper stubs them out with minimal in-memory
-- implementations so the modules can be loaded and called.
--
-- USE FROM A TEST FILE:
--
--   local h = require("spec.test_helpers")
--   h.setup()                    -- install stubs
--   local Merge = require("syncery_ann/merge")
--   -- ... assertions ...
--
-- =============================================================================

local helpers = {}


-- ----------------------------------------------------------------------------
-- A tiny `expect`-style assertion helper.
--
-- Why not a full framework like busted: we don't want a third-party
-- dependency in the test runs.  The five primitives below cover
-- everything our tests need.
-- ----------------------------------------------------------------------------


--- Number of assertions made; reset by `reset_counters`.
helpers.assertions_made = 0
helpers.assertions_failed = 0


local function record(passed, message)
    helpers.assertions_made = helpers.assertions_made + 1
    if not passed then
        helpers.assertions_failed = helpers.assertions_failed + 1
        local info = debug.getinfo(3, "Sl")
        io.stderr:write(string.format("  FAIL  %s:%d  %s\n",
            (info and info.short_src) or "?",
            (info and info.currentline) or 0,
            message or ""))
    end
end


function helpers.assert_equal(actual, expected, label)
    record(actual == expected, string.format(
        "assert_equal (%s):  expected %s, got %s",
        label or "no label",
        tostring(expected), tostring(actual)))
end


function helpers.assert_true(value, label)
    record(value == true, string.format(
        "assert_true (%s):  got %s", label or "no label", tostring(value)))
end


function helpers.assert_false(value, label)
    -- "false" here means literally false or nil — anything not-truthy.
    record(not value, string.format(
        "assert_false (%s):  got %s", label or "no label", tostring(value)))
end


function helpers.assert_nil(value, label)
    record(value == nil, string.format(
        "assert_nil (%s):  got %s", label or "no label", tostring(value)))
end


--- Deep-equality (only enough nesting to cover state maps).
function helpers.assert_deep_equal(actual, expected, label)
    local function deep_equal(a, b)
        if a == b then return true end
        if type(a) ~= "table" or type(b) ~= "table" then return false end
        for k, v in pairs(a) do
            if not deep_equal(v, b[k]) then return false end
        end
        for k, v in pairs(b) do
            if not deep_equal(a[k], v) then return false end
        end
        return true
    end
    record(deep_equal(actual, expected), string.format(
        "assert_deep_equal (%s)", label or "no label"))
end


function helpers.reset_counters()
    helpers.assertions_made   = 0
    helpers.assertions_failed = 0
end


function helpers.report(name)
    if helpers.assertions_failed > 0 then
        io.stdout:write(string.format(
            "  FAIL  %s — %d/%d failed\n",
            name, helpers.assertions_failed, helpers.assertions_made))
        return false
    else
        io.stdout:write(string.format(
            "  OK    %s — %d assertion(s) passed\n",
            name, helpers.assertions_made))
        return true
    end
end


-- ----------------------------------------------------------------------------
-- KOReader stubs.
--
-- Modules under syncery_ann/ require:
--   * "logger"            — log functions; route to /dev/null
--   * "rapidjson"         — JSON encode/decode; minimal Lua impl below
--   * "libs/libkoreader-lfs" — lfs; use luafilesystem if available, else stub
--   * "datastorage"       — settings dir; stub returns /tmp dir
--   * "ffi/sha2"          — md5; stub returns deterministic hash
--   * "docsettings"       — sidecar paths; stub returns adjacent dir
--   * "util"              — partialMD5; stub uses basename hash
-- ----------------------------------------------------------------------------


local function null_logger()
    return setmetatable({}, { __index = function() return function() end end })
end


local function load_minimal_json()
    -- Use rapidjson if available; otherwise a very small subset of
    -- JSON that's enough for the state-store tests (no scientific
    -- numbers, no unicode escapes).
    local ok, rj = pcall(require, "rapidjson")
    if ok then return rj end

    -- Minimal fallback: lua-cjson would work too if installed.
    local cjson_ok, cjson = pcall(require, "cjson")
    if cjson_ok then
        return {
            encode = function(t) return cjson.encode(t) end,
            decode = function(s) return cjson.decode(s) end,
        }
    end

    error("test harness needs either rapidjson or cjson installed")
end


local function load_minimal_lfs()
    local ok, lfs = pcall(require, "lfs")
    if ok then return lfs end
    error("test harness needs luafilesystem installed")
end


local function stub_md5(s)
    -- Stable, deterministic, no actual MD5 — just enough for tests
    -- that need a "content hash"-shaped string.
    local n = 0
    for i = 1, #s do n = (n * 33 + s:byte(i)) % 0xFFFFFFFF end
    return string.format("%032x", n)
end


--- Install stubs into package.loaded.  Call this BEFORE require-ing
--- any syncery_ann module.
function helpers.setup(test_root)
    if package.config:sub(1,1) == "\\" then
        local tmp = (os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"):gsub("\\", "/")
        test_root = test_root and test_root:gsub("^/tmp/", tmp .. "/") or nil
    end
    test_root = test_root or "/tmp/syncery_test_" .. tostring(os.time())
    -- mkdir -p is intercepted by run_tests.lua on Windows; works natively on Linux.
    os.execute("mkdir -p '" .. test_root .. "' 2>/dev/null")
    helpers.test_root = test_root

    package.loaded["logger"]                = null_logger()
    package.loaded["rapidjson"]             = load_minimal_json()
    package.loaded["libs/libkoreader-lfs"]  = load_minimal_lfs()

    package.loaded["datastorage"] = {
        getSettingsDir = function() return test_root end,
    }

    package.loaded["ffi/sha2"] = { md5 = stub_md5 }

    package.loaded["docsettings"] = {
        open = function(_self, book_path)
            -- Pretend every book already has a partial_md5 in its
            -- doc_settings — we hash the path so two callers asking
            -- for the same book agree.
            local hash = stub_md5(book_path or "")
            return {
                readSetting = function(_self2, key)
                    if key == "partial_md5_checksum" then return hash end
                    return nil
                end,
            }
        end,
        getSidecarDir = function(_self, book_path)
            -- Mirror KOReader's "sidecar next to the book" semantics, but
            -- root it under THIS spec's unique test_root (created in
            -- helpers.setup, removed in teardown). That keeps per-book
            -- isolation, prevents cross-spec/run bleed, and — crucially —
            -- never writes into the plugin source tree. Specs use paths
            -- like "/b.epub" whose real adjacent dir would otherwise land
            -- a stray "b.epub.sdr" in cwd (the repo), which then got packaged.
            local base = (helpers.test_root or ((os.getenv("TMPDIR") or "/tmp")
                .. "/syncery_spec_sidecars")) .. "/sidecars"
            if package.config:sub(1,1) == "\\" then
                base = base:gsub("^/tmp/", (os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"):gsub("\\", "/") .. "/")
                -- On Windows, the book_path may contain the full test_root (a long
                -- Windows path). Strip it so the relative encoding stays short and
                -- never produces colon-containing directory names (e.g. C:__Users__).
                if helpers.test_root and book_path:find(helpers.test_root, 1, true) == 1 then
                    book_path = book_path:sub(#helpers.test_root + 1)
                end
            end
            local rel = book_path:gsub("^/+", ""):gsub("[/\\]", "__")
            local sidecar = base .. "/" .. rel .. ".sdr"
            os.execute("mkdir -p '" .. sidecar .. "' 2>/dev/null")
            return sidecar
        end,
    }

    package.loaded["util"] = {
        partialMD5 = function(path) return stub_md5(path or "") end,
        utf8charcount = function(s) return #s end,
        utf8sub       = function(s, a, b) return s:sub(a, b) end,
        -- Mirrors KOReader's util.makePath: "As mkdir -p. Unlike
        -- lfs.mkdir(), does not error if the directory already exists,
        -- and creates intermediate directories as needed." JsonStore.write
        -- calls this to ensure a sidecar dir exists before writing (the
        -- SDR-mode P1 fix). The real one is in frontend/util.lua; this
        -- stub gives the same observable behaviour for the suite.
        makePath = function(path)
            if not path or path == "" then return nil, "empty path" end
            if package.config:sub(1,1) == "\\" then
                path = path:gsub("^/tmp/", (os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"):gsub("\\", "/") .. "/")
            end
            os.execute("mkdir -p '" .. path .. "' 2>/dev/null")
            return true
        end,
    }

    -- ffi/util — only used for `gettime` by syncery_util, not by
    -- anything in syncery_ann.  Provide a stub anyway in case future
    -- code reaches for it.
    package.loaded["ffi/util"] = {
        gettime = function() return os.time() end,
    }

    return helpers
end


--- Clean up after a test: removes the test_root dir.
function helpers.teardown()
    if helpers.test_root then
        os.execute("rm -rf '" .. helpers.test_root .. "' 2>/dev/null")
    end
end


--- Build a fake transport that satisfies syncery_transports/interface.lua.
---
--- The fake is the dogfood for the contract spec — if the interface
--- file says "every transport must do X", the fake does X.  Real
--- transports written later are checked against the same scenarios.
---
--- Options:
---   id                     — string, default "fake"
---   display_name           — string, default "Fake Transport"
---   eventually_consistent  — bool,   default false
---   initial_available      — bool,   default true
---
--- The returned object has the seven required Transport methods plus
--- test-only helpers:
---   set_available(bool)
---   set_error_on_push(error_string_or_nil)
---   set_error_on_pull(error_string_or_nil)
---   peek_remote(book_file)             — read back what push stored
---   push_call_count(book_file)         — how many times push was called
function helpers.make_fake_transport(opts)
    opts = opts or {}
    local transport_id   = opts.id           or "fake"
    local display_name   = opts.display_name or "Fake Transport"
    local eventually     = opts.eventually_consistent and true or false
    local available      = opts.initial_available
    if available == nil then available = true end

    -- In-memory "remote".  push() writes here, pull() reads.  For an
    -- eventually-consistent fake we deliberately discard the write so
    -- the contract spec can assert "pull may legitimately return nil".
    local remote_store         = {}
    local push_calls           = {}   -- book_file → integer
    local injected_push_error  = nil
    local injected_pull_error  = nil

    local function record_push(book_file)
        push_calls[book_file] = (push_calls[book_file] or 0) + 1
    end

    local NOT_AVAILABLE = "not_available"

    local transport = {}

    function transport.id()                       return transport_id end
    function transport.display_name()             return display_name end
    function transport.is_available()             return available    end
    function transport.is_eventually_consistent() return eventually   end

    function transport.push(book_file, push_opts, callback)
        record_push(book_file)
        if not available then
            callback(false, NOT_AVAILABLE, nil); return
        end
        if injected_push_error then
            callback(false, injected_push_error, nil); return
        end
        -- Eventually-consistent fakes drop the payload to simulate
        -- "scan triggered but replication not yet observed".
        if not eventually then
            remote_store[book_file] = push_opts and push_opts.payload
        end
        callback(true, nil, nil)
    end

    function transport.pull(book_file, _pull_opts, callback)
        if not available then
            callback(false, NOT_AVAILABLE, nil); return
        end
        if injected_pull_error then
            callback(false, injected_pull_error, nil); return
        end
        callback(true, nil, remote_store[book_file])
    end

    function transport.status()
        return {
            display_name = display_name,
            available    = available,
            summary      = available and "ready" or "unavailable",
        }
    end

    -- ---- test-only helpers ----

    transport.set_available = function(value)
        available = value and true or false
    end
    transport.set_error_on_push = function(err) injected_push_error = err end
    transport.set_error_on_pull = function(err) injected_pull_error = err end
    transport.peek_remote       = function(book_file) return remote_store[book_file] end
    transport.push_call_count   = function(book_file) return push_calls[book_file] or 0 end

    return transport
end


--- Build a controllable fake clock.  Tests can advance time manually
--- instead of waiting wall-clock seconds.
---
---     local clock = h.make_fake_clock(1000)
---     clock.now()           -- 1000
---     clock.advance(30)
---     clock.now()           -- 1030
---
--- The returned table has:
---   now()             — return current fake time as a number
---   advance(seconds)  — move the clock forward by `seconds`
---   set(value)        — set the clock to an absolute value
---
--- Pass `clock.now` (the function, not the table) to Orchestrator.new
--- as the `clock` option.
function helpers.make_fake_clock(starting)
    local t = starting or 0
    return {
        now      = function() return t end,
        advance  = function(seconds) t = t + (seconds or 0) end,
        set      = function(value) t = value end,
    }
end


--- Build a controllable fake scheduler.  Used as the `scheduler` opt
--- for Orchestrator.new.  Captures every scheduleIn-style call into
--- an in-memory queue.  Tests then call `run_due(now)` to fire all
--- callbacks whose deadline has passed.
---
---     local clock = h.make_fake_clock(1000)
---     local sched = h.make_fake_scheduler(clock)
---     sched.schedule(30, function() ... end)
---     -- nothing fires yet
---     clock.advance(30)
---     sched.run_due()       -- the function above fires now
---
--- The returned table has:
---   schedule(delay_s, fn)   — pass this as the `scheduler` opt
---   run_due()               — fire any task whose deadline ≤ clock.now()
---   pending_count()         — how many tasks are still queued
---   run_all()               — fire EVERY queued task regardless of time
---                              (useful when a test doesn't care about
---                              clock progression and just wants
---                              continuation)
function helpers.make_fake_scheduler(clock)
    assert(type(clock) == "table" and type(clock.now) == "function",
        "make_fake_scheduler requires a fake clock (use make_fake_clock)")

    local queue = {}   -- list of { due_at, fn }

    local function schedule(delay, fn)
        table.insert(queue, { due_at = clock.now() + (delay or 0), fn = fn })
    end

    local function run_due()
        -- Iterate against a copy because a fired fn might enqueue more.
        local still_pending = {}
        local to_fire = {}
        for _, task in ipairs(queue) do
            if task.due_at <= clock.now() then
                table.insert(to_fire, task)
            else
                table.insert(still_pending, task)
            end
        end
        queue = still_pending
        for _, task in ipairs(to_fire) do task.fn() end
    end

    local function run_all()
        local q = queue
        queue = {}
        for _, task in ipairs(q) do task.fn() end
    end

    return {
        schedule       = schedule,
        run_due        = run_due,
        run_all        = run_all,
        pending_count  = function() return #queue end,
    }
end


--- Build a fake KOReader ReaderUI object for the doc_settings_bridge
--- tests.  The fake supports the small surface our code touches:
---   * doc_settings:readSetting(k) / saveSetting(k, v)
---   * paging  (bool)
---   * annotation / bookmark sub-objects with no-op event handlers
function helpers.make_fake_ui(opts)
    opts = opts or {}
    local settings_storage = opts.settings or {}
    return {
        paging = opts.paging or false,
        rolling = (not opts.paging) and { stub = true } or nil,
        handmade = opts.handmade,  -- optional live ReaderHandMade stub
        -- Optional live render state (the document's shared Configurable and
        -- the ReaderFont module), so render-bridge tests can assert the apply
        -- updates the in-memory state KOReader persists, not just doc_settings.
        document = opts.configurable and { configurable = opts.configurable } or nil,
        font = opts.font,
        doc_settings = {
            readSetting = function(_self, key) return settings_storage[key] end,
            saveSetting = function(_self, key, val) settings_storage[key] = val end,
        },
        annotation = {
            onAnnotationsModified = function() end,
        },
        bookmark = {
            onReadSettings = function() end,
        },
        _settings = settings_storage,  -- exposed for tests to inspect
    }
end


return helpers
