-- =============================================================================
-- spec/cloud_session_spec.lua
-- =============================================================================
-- Regression tests for the Revision 5 CloudSession boundary.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_cloud_session_spec_" .. tostring(os.time()))

local Session = require("syncery_transports/cloud/session")
local Interface = require("syncery_transports/interface")

local function copy(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

local function fixture(overrides)
    overrides = overrides or {}
    local rec = {
        now = overrides.now or 1000,
        enabled = overrides.enabled ~= false,
        stored = overrides.stored or {
            type = "dropbox",
            name = "Personal",
            address = "APP_KEY:APP_SECRET",
            url = "/Syncery",
            password = "stored-refresh",
        },
        live = overrides.live or {
            type = "dropbox",
            name = "Personal",
            address = "APP_KEY:APP_SECRET",
            url = "/",
            password = "live-refresh",
        },
        sync_calls = {},
        oauth_refresh_count = 0,
        list_calls = {},
        upload_calls = {},
        download_calls = {},
        unsubscribe_count = 0,
    }

    rec.settings = {
        get_cloud_enabled = function() return rec.enabled end,
        -- Deliberately return the backing object itself. CloudSession must not
        -- rely on Settings' own defensive-copy guarantee for isolation.
        get_cloud_server = function() return rec.stored end,
        on_change = function(id, fn)
            rec.listener_id = id
            rec.listener = fn
            return function() rec.unsubscribe_count = rec.unsubscribe_count + 1 end
        end,
    }

    rec.raw = overrides.raw or {}
    rec.raw.genAccessToken = rec.raw.genAccessToken or function()
        local base = rec.raw.base
        if not base.username then
            rec.oauth_refresh_count = rec.oauth_refresh_count + 1
            base.password = "access-" .. tostring(rec.oauth_refresh_count)
            base.username = true
        end
        return true
    end
    rec.raw.listFolder = rec.raw.listFolder or function(url, include_folders)
        table.insert(rec.list_calls, {
            url = url,
            include_folders = include_folders,
            base = rec.raw.base,
        })
        return { { text = "syncery-manifest-peer.txt" } }
    end
    rec.raw.uploadFile = rec.raw.uploadFile or function(url, local_path, etag, overwrite)
        table.insert(rec.upload_calls, {
            url = url, local_path = local_path, etag = etag,
            overwrite = overwrite, base = rec.raw.base,
        })
        return overrides.upload_code or 200
    end
    rec.raw.downloadFile = rec.raw.downloadFile or function(url, local_path)
        table.insert(rec.download_calls, {
            url = url, local_path = local_path, base = rec.raw.base,
        })
        return overrides.download_code or 200
    end

    rec.adapter = {
        id = function() return overrides.backend_id or "cloudstorage" end,
        is_available = function() return overrides.backend_available ~= false end,
        syncable_providers = function()
            return overrides.syncable or { dropbox = true, webdav = true, ftp = true }
        end,
        sync = function(server, path, merge_cb, callback)
            table.insert(rec.sync_calls, {
                server = server,
                path = path,
                merge_cb = merge_cb,
            })
            if server.type == "dropbox" and not server.username then
                rec.oauth_refresh_count = rec.oauth_refresh_count + 1
                server.password = "access-" .. tostring(rec.oauth_refresh_count)
                server.username = true
            end
            callback(overrides.sync_ok ~= false, overrides.sync_err)
            if overrides.double_callback then callback(false, "late") end
        end,
    }

    rec.selection = {
        provider = rec.adapter,
        active_id = overrides.backend_id or "cloudstorage",
        fell_back = overrides.fell_back == true,
    }
    rec.ui = overrides.ui or {
        servers = { rec.live },
        providers = { [rec.stored.type] = rec.raw },
    }

    local global_value = overrides.show_unsupported
    rec.global_settings = {
        readSetting = function(_self, key)
            if key == "show_unsupported" then return global_value end
        end,
        saveSetting = function(_self, key, value)
            if key == "show_unsupported" then global_value = value end
        end,
        delSetting = function(_self, key)
            if key == "show_unsupported" then global_value = nil end
        end,
        current = function() return global_value end,
    }

    rec.session = Session.new({
        settings_api = rec.settings,
        select_provider = function() return rec.selection end,
        ui_cloudstorage_resolver = function() return rec.ui end,
        now = function() return rec.now end,
        global_settings = rec.global_settings,
    })
    return rec
end

-- A selected subfolder is an override, not part of the live-server match key.
do
    local f = fixture({ double_callback = true })
    h.assert_equal(f.listener_id, "cloud", "session subscribes to cloud settings")
    h.assert_true(f.session:is_available(),
        "stored /Syncery matches the live account rooted at /")

    local callbacks = 0
    f.session:sync("/tmp/progress.json", function() end, function(ok)
        callbacks = callbacks + 1
        h.assert_true(ok, "sync callback reports success")
    end)
    h.assert_equal(callbacks, 1, "provider callback is forwarded exactly once")
    h.assert_equal(#f.sync_calls, 1, "one provider sync dispatched")
    h.assert_equal(f.sync_calls[1].server.url, "/Syncery",
        "stored selected folder overrides live server root")
    h.assert_true(f.sync_calls[1].server ~= f.live,
        "provider receives a private runtime, not the live descriptor")
    h.assert_true(f.sync_calls[1].server ~= f.stored,
        "provider receives a private runtime, not the stored descriptor")
    h.assert_equal(f.live.password, "live-refresh",
        "provider mutation does not poison Cloud storage+ settings")
    h.assert_equal(f.stored.password, "stored-refresh",
        "provider mutation does not poison Syncery settings")

    f.session:sync("/tmp/annotations.json", nil, function() end)
    h.assert_true(f.sync_calls[1].server == f.sync_calls[2].server,
        "all per-book syncs reuse one private runtime")
    h.assert_equal(f.oauth_refresh_count, 1,
        "runtime reuse performs one OAuth refresh, not one per book")
end

-- Destination and live-source changes invalidate the private runtime.
do
    local f = fixture()
    f.session:sync("/tmp/a", nil, function() end)
    local first = f.sync_calls[1].server

    f.stored.url = "/Other"
    f.listener("cloud")
    f.session:sync("/tmp/b", nil, function() end)
    h.assert_true(first ~= f.sync_calls[2].server,
        "settings change invalidates the runtime")
    h.assert_equal(f.sync_calls[2].server.url, "/Other",
        "new selected folder is applied")

    local second = f.sync_calls[2].server
    f.live.password = "new-refresh-token"
    f.session:sync("/tmp/c", nil, function() end)
    h.assert_true(second ~= f.sync_calls[3].server,
        "live credential fingerprint change invalidates the runtime")
end

-- Dropbox runtimes are bounded; WebDAV runtimes are not time-expired.
do
    local f = fixture()
    f.session:sync("/tmp/a", nil, function() end)
    local first = f.sync_calls[1].server
    f.now = f.now + Session.DROPBOX_RUNTIME_TTL - 1
    f.session:sync("/tmp/b", nil, function() end)
    h.assert_true(first == f.sync_calls[2].server, "Dropbox runtime survives before TTL")
    f.now = f.now + 1
    f.session:sync("/tmp/c", nil, function() end)
    h.assert_true(first ~= f.sync_calls[3].server, "Dropbox runtime expires at TTL")
    h.assert_equal(f.oauth_refresh_count, 2, "TTL expiry causes one fresh OAuth exchange")

    local third = f.sync_calls[3].server
    f.now = 1
    f.session:sync("/tmp/d", nil, function() end)
    h.assert_true(third ~= f.sync_calls[4].server,
        "clock rollback invalidates a Dropbox runtime")
end

do
    local f = fixture({
        stored = { type = "webdav", name = "DAV", address = "https://dav", url = "/Syncery" },
        live = { type = "webdav", name = "DAV", address = "https://dav", url = "/" },
    })
    f.session:sync("/tmp/a", nil, function() end)
    local first = f.sync_calls[1].server
    f.now = f.now + Session.DROPBOX_RUNTIME_TTL * 10
    f.session:sync("/tmp/b", nil, function() end)
    h.assert_true(first == f.sync_calls[2].server, "WebDAV runtime has no OAuth TTL")
end

-- Matching is strict on routing identity and fail-closed on zero/multiple hits.
do
    local f = fixture()
    f.live.address = "OTHER_KEY:OTHER_SECRET"
    local ok, err = f.session:is_available()
    h.assert_false(ok, "address mismatch is stale, not guessed")
    h.assert_equal(err, Interface.ERRORS.NOT_CONFIGURED, "stale server is not_configured")
    h.assert_equal(f.session:status().state, "stale_server", "stale state is explicit")
end

do
    local f = fixture()
    f.ui.servers[2] = copy(f.live)
    h.assert_false(f.session:is_available(), "duplicate identity is ambiguous")
    h.assert_equal(f.session:status().state, "ambiguous_server",
        "ambiguous state is explicit")
end

-- The legacy fallback may use only pristine stored Dropbox credentials.
do
    local f = fixture({ backend_id = "syncservice", fell_back = true })
    f.stored.username = true
    h.assert_false(f.session:is_available(), "poisoned stored Dropbox fallback rejected")
    h.assert_equal(f.session:status().state, "poisoned_stored_fallback",
        "poisoned fallback has a dedicated state")
end

do
    local f = fixture({ backend_id = "syncservice", fell_back = true })
    f.session:sync("/tmp/fallback", nil, function() end)
    h.assert_equal(#f.sync_calls, 1, "pristine stored fallback dispatches")
    h.assert_true(f.sync_calls[1].server ~= f.stored,
        "fallback also receives a defensive runtime copy")
    h.assert_equal(f.stored.username, nil, "fallback mutation does not poison stored data")
    local first = f.sync_calls[1].server
    h.assert_false(f.session:direct_file_io_available(),
        "fallback correctly reports no direct file I/O")
    f.session:sync("/tmp/fallback-2", nil, function() end)
    h.assert_true(first == f.sync_calls[2].server,
        "capability probe does not discard a healthy fallback runtime")
    h.assert_equal(f.oauth_refresh_count, 1,
        "fallback capability probe does not trigger another OAuth exchange")
end

-- Direct file I/O brackets provider.base and the WebDAV visibility setting.
do
    local f = fixture({ show_unsupported = "original-value" })
    local sentinel_base = { sentinel = true }
    f.raw.base = sentinel_base
    local seen_setting
    f.raw.listFolder = function(url, include_folders)
        seen_setting = f.global_settings.current()
        table.insert(f.list_calls, { url = url, base = f.raw.base })
        return { { text = "syncery-progress-BOOK.json" } }
    end

    h.assert_true(f.session:direct_file_io_available(), "direct I/O capability detected")
    local entries = f.session:list_folder(true)
    h.assert_equal(#entries, 1, "direct listing returned")
    h.assert_equal(f.list_calls[1].url, "/Syncery", "listing uses selected folder")
    h.assert_true(f.list_calls[1].base ~= f.live and f.list_calls[1].base ~= f.stored,
        "provider.base points at the private runtime during the call")
    h.assert_equal(seen_setting, true, "show_unsupported is true during listing")
    h.assert_equal(f.global_settings.current(), "original-value",
        "show_unsupported exact original value is restored")
    h.assert_true(f.raw.base == sentinel_base, "provider.base is restored after listing")

    local ok_up = f.session:upload_file("/tmp/syncery-manifest-DEVICE.txt")
    h.assert_true(ok_up, "safe manifest upload succeeds")
    h.assert_equal(f.upload_calls[1].url, "/Syncery", "upload folder forwarded")
    h.assert_true(f.upload_calls[1].overwrite, "upload preserves overwrite semantics")
    h.assert_true(f.raw.base == sentinel_base, "provider.base restored after upload")

    local ok_down = f.session:download_file(
        "syncery-progress-BOOK.json", "/tmp/download.json")
    h.assert_true(ok_down, "safe progress download succeeds")
    h.assert_equal(f.download_calls[1].url, "/Syncery/syncery-progress-BOOK.json",
        "download URL joins the selected folder exactly once")
    h.assert_true(f.raw.base == sentinel_base, "provider.base restored after download")
    h.assert_equal(f.oauth_refresh_count, 1,
        "multiple direct Dropbox operations reuse one access token")

    h.assert_false(f.session:download_file("../secret", "/tmp/x"),
        "unsafe remote traversal is rejected")
    h.assert_false(f.session:upload_file("/tmp/random.txt"),
        "non-Syncery upload basename is rejected")
end

do
    local f = fixture({ show_unsupported = nil })
    local sentinel = {}
    f.raw.base = sentinel
    f.raw.listFolder = function() error("simulated provider failure") end
    local entries, err = f.session:list_folder(true)
    h.assert_nil(entries, "provider exception returns no listing")
    h.assert_equal(err, Interface.ERRORS.INTERNAL, "provider exception maps to internal")
    h.assert_true(f.raw.base == sentinel, "provider.base restored after exception")
    h.assert_nil(f.global_settings.current(),
        "missing show_unsupported key is deleted again after exception")
end

do
    local f = fixture({ upload_code = 401, download_code = 404 })
    local ok_up, err_up = f.session:upload_file("/tmp/syncery-manifest-D.txt")
    h.assert_false(ok_up, "401 upload fails")
    h.assert_equal(err_up, Interface.ERRORS.AUTH_FAILED, "401 maps to auth_failed")
    local ok_down, err_down = f.session:download_file(
        "syncery-manifest-D.txt", "/tmp/d")
    h.assert_false(ok_down, "404 download fails")
    h.assert_equal(err_down, Interface.ERRORS.REJECTED, "404 maps to rejected")
end

-- Status inspection is side-effect-free; shutdown clears runtime/listener.
do
    local f = fixture()
    local s = f.session:status()
    h.assert_equal(s.state, "ready", "status reports ready")
    h.assert_equal(#f.sync_calls, 0, "status does not dispatch sync")
    h.assert_equal(f.oauth_refresh_count, 0, "status does not mint an access token")
    f.session:shutdown()
    f.session:shutdown()
    h.assert_equal(f.unsubscribe_count, 1, "shutdown unsubscribes exactly once")
    h.assert_false(f.session:is_available(), "shutdown session is unavailable")
end
