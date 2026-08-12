-- =============================================================================
-- spec/cloud_fallback_cross_device_spec.lua
-- =============================================================================
--
-- END-TO-END, two-"device" test of the FALLBACK cloud path (built-in
-- SyncService, no Cloud Storage+ plugin) -- specifically the cross-device
-- prefetch scenario (_prefetchViaFallback). This is the test that would
-- have caught BOTH real bugs found via Group A real-device testing on
-- 2026-07-16, months before a real device ever ran it:
--
--   1. The fallback prefetch used a SEPARATE "prefetch_progress"/
--      "prefetch_annotations" kind, which Staging.cloud_name_for turned
--      into the WRONG remote object name ("syncery-prefetch_progress-
--      {id}.json") -- a cloud object no genuine push ever writes to. The
--      fallback prefetch could never have found a real peer's data.
--
--   2. The prefetch merge callback returned `true` on a successful
--      fetch+place, which -- per the REAL frontend/apps/cloudstorage/
--      syncservice.lua contract (`if not ok or not cb_return then ...
--      return end` else `api:uploadFile(..., file_path, ...)`) -- is a
--      direct instruction to re-upload the UNCHANGED bootstrap-empty
--      local file, silently overwriting the peer's real remote data.
--
-- Prior test coverage (cloud_transport_spec.lua) exercised
-- _build_merge_callback's prefetch branch in ISOLATION, with a fake
-- provider.sync that didn't faithfully mirror the real upload-on-truthy-
-- return contract, and never simulated a SECOND device's real push --
-- so neither bug surfaced there. THIS spec builds a FAITHFUL fake
-- SyncService (mirroring frontend/apps/cloudstorage/syncservice.lua's
-- own control flow precisely) shared between two independently-rooted
-- "devices", and drives the REAL production call chain end to end:
-- Bridge/do_cloud_upload-shaped push for device A, _prefetchViaFallback
-- for device B.
--
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_cloud_fallback_cross_device_spec_" .. tostring(os.time()))

local Transport           = require("syncery_transports/cloud/transport")
local SyncServiceProvider = require("syncery_transports/cloud/providers/syncservice_provider")
local PluginSync          = require("syncery_transports/plugin_sync")
local cjson                = require("rapidjson")

local TEST_BOOK_ID = "ABCDEF0123456789ABCDEF0123456789"
local SERVER = { type = "webdav", kind = "webdav", url = "/Syncery" }


-- ----------------------------------------------------------------------------
-- A FAITHFUL fake SyncService: mirrors frontend/apps/cloudstorage/
-- syncservice.lua's SyncService.sync control flow precisely (traced
-- directly against that source, not assumed) --
--
--   local ok, cb_return = pcall(sync_cb, file_path, cached_file_path, income_file_path)
--   if not ok or not cb_return then ... return end
--   -- (falls through to) api:uploadFile(..., file_path, ...)
--
-- -- so a merge callback that returns falsy genuinely does NOT upload,
-- and one that returns truthy genuinely DOES upload file_path's then-
-- current on-disk content. shared_remote is an in-memory table keyed by
-- basename, standing in for the actual cloud objects two real devices
-- would read/write through their own WebDAV/Dropbox account.
-- ----------------------------------------------------------------------------
local function make_faithful_fake_sync_service(shared_remote)
    return {
        sync = function(server, file_path, sync_cb, is_silent)
            local file_name = file_path:match("([^/]+)$")
            local income_file_path = file_path .. ".temp"
            local cached_file_path = file_path .. ".sync"

            local remote_content = shared_remote[file_name]
            if remote_content ~= nil then
                local f = io.open(income_file_path, "wb")
                f:write(remote_content); f:close()
            else
                os.remove(income_file_path)  -- nothing there yet (404-equivalent)
            end

            local ok, cb_return = pcall(sync_cb, file_path, cached_file_path, income_file_path)
            os.remove(income_file_path)
            if not ok or not cb_return then
                return  -- NO upload -- matches the real contract exactly
            end

            local f = io.open(file_path, "rb")
            if f then
                local content = f:read("*a"); f:close()
                shared_remote[file_name] = content
            end
        end,
    }
end


--- Build a Transport instance for one "device": its own local staging
--- root, pointed at a SHARED fake SyncService (standing in for one
--- real cloud account both devices sync through).
local function make_device_transport(local_root, shared_svc)
    require("util").makePath(local_root)
    return Transport.new({
        settings_reader = function(key)
            if key == "syncery_use_cloud" then return true end
            if key == "syncery_cloud_server" then return SERVER end
            return nil
        end,
        select_provider = function()
            return {
                provider  = SyncServiceProvider.new({ sync_service = shared_svc }),
                active_id = "syncservice",
                fell_back = false,
            }
        end,
        file_writer    = function(path, content)
            local f = io.open(path, "wb")
            if not f then return false, "open failed" end
            f:write(content); f:close()
            return true
        end,
        file_reader    = function(path)
            local f = io.open(path, "rb")
            if not f then return nil end
            local c = f:read("*a"); f:close()
            return c
        end,
        ensure_dir     = function(dir)
            require("util").makePath(dir)
            return true
        end,
        staging_dir_fn = function() return local_root end,
    })
end


--- Minimal fake Cloud I/O facade: drives a SINGLE transport with the same
--- semantic prefetch payload Bridge produces in production.
local function make_fake_cloud_io(transport)
    return {
        pull_cloud_prefetch = function(_self, book_id, kind, content)
            transport.pull("__prefetch__", {
                payload = {
                    kind = kind,
                    book_id = book_id,
                    content = content,
                    is_prefetch = true,
                },
            }, function() end)
        end,
    }
end


-- ----------------------------------------------------------------------------
-- THE test: device A pushes real progress; device B, which has never
-- opened this book, prefetches it via the fallback path.
-- ----------------------------------------------------------------------------

do
    local shared_remote = {}
    local shared_svc = make_faithful_fake_sync_service(shared_remote)

    local root_a = "/tmp/syncery_fallback_xdev_a_" .. tostring(os.time())
    local root_b = "/tmp/syncery_fallback_xdev_b_" .. tostring(os.time())
    local device_a = make_device_transport(root_a, shared_svc)
    local device_b = make_device_transport(root_b, shared_svc)

    -- ── Device A: a REAL push of its own progress for this book ──────
    local a_content = '{"schema_version":1,"device_id":"DEVICEA","entries":{"DEVICEA":{"percent":0.42,"page":137}}}'
    local a_ok
    device_a.push("/fake/path/to/book.epub", {
        payload = { kind = "progress", book_id = TEST_BOOK_ID, content = a_content },
    }, function(ok) a_ok = ok end)
    h.assert_true(a_ok, "device A's push dispatches successfully")

    local remote_after_a = shared_remote["syncery-progress-" .. TEST_BOOK_ID .. ".json"]
    h.assert_true(remote_after_a ~= nil,
        "device A's push landed SOMETHING on the shared remote")
    local decoded_after_a = cjson.decode(remote_after_a)
    h.assert_true(decoded_after_a.entries and decoded_after_a.entries.DEVICEA
        and decoded_after_a.entries.DEVICEA.percent == 0.42,
        "the remote object contains device A's REAL percent (0.42), "
        .. "confirming the push went to the correct cloud object")

    -- ── Device B: never opened this book, prefetches it ───────────────
    local fake_cloud_io_b = make_fake_cloud_io(device_b)
    PluginSync._prefetchViaFallback({ state_dir = root_b .. "/" }, fake_cloud_io_b,
        TEST_BOOK_ID, "progress")

    -- BUGFIX 1 (wrong remote object name): device B's prefetch must have
    -- found device A's REAL data, not an empty/missing object.
    local prefetched_path = root_b .. "/prefetch/syncery-progress-" .. TEST_BOOK_ID .. ".json"
    local pf = io.open(prefetched_path, "rb")
    h.assert_true(pf ~= nil,
        "device B's prefetch produced a local file under cloud_staging/prefetch/")
    if pf then
        local prefetched_content = pf:read("*a")
        pf:close()
        local decoded_prefetch = cjson.decode(prefetched_content)
        h.assert_true(decoded_prefetch.entries and decoded_prefetch.entries.DEVICEA
            and decoded_prefetch.entries.DEVICEA.percent == 0.42,
            "BUGFIX (wrong remote object name): device B's prefetch retrieved "
            .. "device A's REAL percent (0.42) -- proving it read from the "
            .. "SAME cloud object device A's real push wrote to, not a "
            .. "separate 'syncery-prefetch_progress-*' object no real push "
            .. "ever touches")
    end

    -- BUGFIX 2 (destructive re-upload): the shared remote must be
    -- UNCHANGED after device B's prefetch -- still device A's real data,
    -- not overwritten with device B's empty bootstrap envelope.
    local remote_after_b_prefetch = shared_remote["syncery-progress-" .. TEST_BOOK_ID .. ".json"]
    h.assert_true(remote_after_b_prefetch ~= nil,
        "the remote object still exists after device B's prefetch")
    local decoded_after_b = cjson.decode(remote_after_b_prefetch)
    h.assert_true(decoded_after_b.entries and decoded_after_b.entries.DEVICEA
        and decoded_after_b.entries.DEVICEA.percent == 0.42,
        "BUGFIX (destructive re-upload): the remote object STILL contains "
        .. "device A's real percent (0.42) after device B's prefetch -- "
        .. "proving the prefetch did NOT re-upload its own unchanged "
        .. "bootstrap-empty envelope and silently wipe device A's real data")

    os.execute("rm -rf " .. root_a .. " " .. root_b)
end


-- ----------------------------------------------------------------------------
-- Same scenario, annotations kind: the two branches (kind ==
-- "progress"/"annotations") in _build_merge_callback's prefetch check
-- are symmetric in the production code, but worth covering both
-- explicitly rather than assuming the pattern holds identically.
-- ----------------------------------------------------------------------------

do
    local shared_remote = {}
    local shared_svc = make_faithful_fake_sync_service(shared_remote)

    local root_a = "/tmp/syncery_fallback_xdev_a2_" .. tostring(os.time())
    local root_b = "/tmp/syncery_fallback_xdev_b2_" .. tostring(os.time())
    local device_a = make_device_transport(root_a, shared_svc)
    local device_b = make_device_transport(root_b, shared_svc)

    local a_content = '{"schema_version":1,"annotations":{"k1":{"text":"device A note","datetime_updated":"2026-01-01 00:00:00"}},"metadata":{},"render_settings":{}}'
    local a_ok
    device_a.push("/fake/path/to/book2.epub", {
        payload = { kind = "annotations", book_id = TEST_BOOK_ID, content = a_content },
    }, function(ok) a_ok = ok end)
    h.assert_true(a_ok, "device A's annotations push dispatches successfully")

    local fake_cloud_io_b = make_fake_cloud_io(device_b)
    PluginSync._prefetchViaFallback({ state_dir = root_b .. "/" }, fake_cloud_io_b,
        TEST_BOOK_ID, "annotations")

    local prefetched_path = root_b .. "/prefetch/syncery-annotations-" .. TEST_BOOK_ID .. ".json"
    local pf = io.open(prefetched_path, "rb")
    h.assert_true(pf ~= nil, "device B's annotations prefetch produced a local file")
    if pf then
        local prefetched_content = pf:read("*a")
        pf:close()
        local decoded = cjson.decode(prefetched_content)
        h.assert_true(decoded.annotations and decoded.annotations.k1
            and decoded.annotations.k1.text == "device A note",
            "device B's annotations prefetch retrieved device A's real note text")
    end

    local remote_after = shared_remote["syncery-annotations-" .. TEST_BOOK_ID .. ".json"]
    local decoded_after = cjson.decode(remote_after)
    h.assert_true(decoded_after.annotations and decoded_after.annotations.k1
        and decoded_after.annotations.k1.text == "device A note",
        "the remote annotations object still contains device A's real note "
        .. "after device B's prefetch -- not wiped by a re-upload")

    os.execute("rm -rf " .. root_a .. " " .. root_b)
end


h.teardown()
