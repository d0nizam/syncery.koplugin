-- =============================================================================
-- spec/cloud_list_spec.lua
-- =============================================================================
-- Manifest helpers use only the Cloud I/O facade and always clean temp files.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_cloud_list_spec_" .. tostring(os.time()))

local json = require("rapidjson")
package.loaded["json"] = json
local List = require("syncery_transports/cloud/list")

local root = "/tmp/syncery_cloud_list_files_" .. tostring(os.time()) .. "/"
os.execute("rm -rf " .. root)
require("util").makePath(root .. "cloud_staging/")
local plugin = { state_dir = root }

do
    local seen
    local cloud_io = {
        upload_cloud_file = function(_self, path)
            local f = io.open(path, "rb")
            seen = f and f:read("*a") or nil
            if f then f:close() end
            return true
        end,
    }
    local ok = List.uploadManifest(plugin, cloud_io, {
        device_id = "DEVICE_A",
        ts = 123,
        files = { BOOK = "hash" },
    })
    h.assert_true(ok, "manifest upload delegates through the facade")
    local decoded = json.decode(seen)
    h.assert_equal(decoded.device_id, "DEVICE_A", "uploaded manifest content encoded")
    h.assert_true(io.open(root .. "cloud_staging/syncery-manifest-DEVICE_A.txt") == nil,
        "upload temp file is removed after success")
end

do
    local cloud_io = {
        upload_cloud_file = function() error("simulated upload failure") end,
    }
    local ok = List.uploadManifest(plugin, cloud_io, {
        device_id = "DEVICE_B", ts = 1, files = {},
    })
    h.assert_false(ok, "facade upload exception is contained")
    h.assert_true(io.open(root .. "cloud_staging/syncery-manifest-DEVICE_B.txt") == nil,
        "upload temp file is removed after exception")
end

do
    local called = false
    local cloud_io = {
        upload_cloud_file = function() called = true; return true end,
    }
    local ok = List.uploadManifest(plugin, cloud_io, {
        device_id = "../../escape", ts = 1, files = {},
    })
    h.assert_false(ok, "unsafe device id is rejected before a temp path is built")
    h.assert_false(called, "unsafe device id never reaches cloud I/O")
end

do
    local seen_name
    local cloud_io = {
        download_cloud_file = function(_self, remote_name, local_path)
            seen_name = remote_name
            local f = io.open(local_path, "wb")
            f:write('{"device_id":"PEER","files":{"BOOK":"peer-hash"}}')
            f:close()
            return true
        end,
    }
    local manifest = List.downloadManifest(plugin, cloud_io, "PEER")
    h.assert_equal(seen_name, "syncery-manifest-PEER.txt",
        "download passes only a safe remote basename")
    h.assert_equal(manifest.files.BOOK, "peer-hash", "downloaded manifest decoded")
    h.assert_true(io.open(root .. "cloud_staging/syncery-manifest-remote.txt") == nil,
        "download temp file is removed after success")
end

do
    local cloud_io = {
        download_cloud_file = function(_self, _remote_name, local_path)
            local f = io.open(local_path, "wb")
            f:write("not-json")
            f:close()
            return true
        end,
    }
    h.assert_nil(List.downloadManifest(plugin, cloud_io, "PEER2"),
        "invalid downloaded manifest is rejected")
    h.assert_true(io.open(root .. "cloud_staging/syncery-manifest-remote.txt") == nil,
        "download temp file is removed after invalid JSON")
end

os.execute("rm -rf " .. root)
