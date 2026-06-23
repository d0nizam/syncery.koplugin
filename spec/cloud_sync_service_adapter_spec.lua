-- =============================================================================
-- spec/cloud_sync_service_adapter_spec.lua
-- =============================================================================
--
-- Tests for syncery_transports/cloud/sync_service_adapter.lua.
--
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_cloud_adapter_spec_" .. tostring(os.time()))

local Adapter   = require("syncery_transports/cloud/sync_service_adapter")
local Interface = require("syncery_transports/interface")


-- Helper: build a fake sync_service module.
local function make_fake_service()
    local rec = { calls = {} }
    rec.module = {
        sync = function(server, path, merge_cb, suppress)
            table.insert(rec.calls, {
                server = server, path = path,
                has_merge_cb = type(merge_cb) == "function",
                suppress = suppress,
            })
        end,
    }
    return rec
end


-- ----------------------------------------------------------------------------
-- Constructor: server required.
-- ----------------------------------------------------------------------------


do
    local ok = pcall(Adapter.new, {})
    h.assert_false(ok, "missing server rejected")

    local ok2 = pcall(Adapter.new, nil)
    h.assert_false(ok2, "nil opts rejected")
end


-- ----------------------------------------------------------------------------
-- upload happy path.
-- ----------------------------------------------------------------------------


do
    local rec = make_fake_service()
    local adapter = Adapter.new({
        server       = { kind = "dropbox", token = "x" },
        sync_service = rec.module,
    })

    local got_ok, got_err
    adapter:upload("/staging/syncery-progress-abc.json",
        function(ok, err) got_ok, got_err = ok, err end)

    h.assert_true(got_ok,                                    "upload ok")
    h.assert_nil(got_err,                                    "no err")
    h.assert_equal(#rec.calls, 1,                             "one service call")
    h.assert_equal(rec.calls[1].path,
        "/staging/syncery-progress-abc.json",                 "path passed through")
    h.assert_equal(rec.calls[1].server.kind, "dropbox",       "server passed through")
    h.assert_true(rec.calls[1].has_merge_cb,                  "merge_cb passed")
    h.assert_true(rec.calls[1].suppress,                      "notification suppressed")
end


-- ----------------------------------------------------------------------------
-- upload: empty path rejected.
-- ----------------------------------------------------------------------------


do
    local rec = make_fake_service()
    local adapter = Adapter.new({ server = {}, sync_service = rec.module })

    local got_err
    adapter:upload("", function(_ok, err) got_err = err end)
    h.assert_equal(got_err, Interface.ERRORS.REJECTED,  "empty path rejected")

    adapter:upload(nil, function(_ok, err) got_err = err end)
    h.assert_equal(got_err, Interface.ERRORS.REJECTED,  "nil path rejected")

    h.assert_equal(#rec.calls, 0, "no service calls made")
end


-- ----------------------------------------------------------------------------
-- upload: sync_service that raises → INTERNAL.
-- ----------------------------------------------------------------------------


do
    local crashing = { sync = function() error("nope") end }
    local adapter = Adapter.new({ server = {}, sync_service = crashing })
    local got_ok, got_err
    adapter:upload("/x.json", function(ok, err) got_ok, got_err = ok, err end)
    h.assert_false(got_ok,                              "failed")
    h.assert_equal(got_err, Interface.ERRORS.INTERNAL,   "INTERNAL on raise")
end


-- ----------------------------------------------------------------------------
-- upload: sync_service missing the `sync` function → NOT_AVAILABLE.
-- ----------------------------------------------------------------------------


do
    local broken = { } -- no sync field
    local adapter = Adapter.new({ server = {}, sync_service = broken })
    local got_err
    adapter:upload("/x.json", function(_ok, err) got_err = err end)
    h.assert_equal(got_err, Interface.ERRORS.NOT_AVAILABLE,
        "missing sync function → NOT_AVAILABLE")
end


-- ----------------------------------------------------------------------------
-- upload: sync_service as a resolver function (lazy load shape) works
-- when the resolver returns a valid module.
-- ----------------------------------------------------------------------------


do
    local rec = make_fake_service()
    local resolved = false
    local adapter = Adapter.new({
        server       = {},
        sync_service = function() resolved = true; return rec.module end,
    })

    local got_ok
    adapter:upload("/x.json", function(ok) got_ok = ok end)
    h.assert_true(resolved,                  "resolver was called")
    h.assert_true(got_ok,                    "upload ok via lazy resolver")
    h.assert_equal(#rec.calls, 1,             "service was called")
end


-- ----------------------------------------------------------------------------
-- The merge callback is passed through to SyncService and invoked with
-- the REAL 3-path contract: (file_path, cached_file_path, income_file_path).
-- (The old code modelled a content-based callback `merge_cb(content)`; that
-- contract does not exist — see PROJECT_PLAN.md 18.0/18.12.)
-- ----------------------------------------------------------------------------


do
    local seen = nil
    local custom_cb = function(local_file, cached_file, income_file)
        seen = { local_file, cached_file, income_file }
        return true
    end

    local fake_service = {
        sync = function(_s, file_path, merge_cb, _sup)
            -- SyncService invokes the callback with three FILE PATHS.
            merge_cb(file_path, file_path .. ".sync", file_path .. ".temp")
        end,
    }
    local adapter = Adapter.new({
        server         = {},
        sync_service   = fake_service,
        merge_callback = custom_cb,
    })
    adapter:upload("/staging/x.json", function() end)

    h.assert_true(seen ~= nil,                       "3-path callback invoked")
    h.assert_equal(seen[1], "/staging/x.json",       "arg1 = local file_path")
    h.assert_equal(seen[2], "/staging/x.json.sync",  "arg2 = cached/ancestor path")
    h.assert_equal(seen[3], "/staging/x.json.temp",  "arg3 = income/remote path")
end


-- ----------------------------------------------------------------------------
-- Default merge callback is SAFE: with no callback wired, it aborts
-- (returns false) so SyncService never uploads — never clobbers.
-- ----------------------------------------------------------------------------


do
    local returned = nil
    local fake_service = {
        sync = function(_s, file_path, merge_cb, _sup)
            returned = merge_cb(file_path, file_path .. ".sync", file_path .. ".temp")
        end,
    }
    local adapter = Adapter.new({ server = {}, sync_service = fake_service })
    adapter:upload("/staging/x.json", function() end)
    h.assert_false(returned, "default callback aborts (false) — safe, no clobber")
end
