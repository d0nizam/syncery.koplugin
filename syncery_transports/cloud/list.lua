-- =============================================================================
-- syncery_transports/cloud/list.lua
-- =============================================================================
--
-- Cloud manifest functions for V4 Merkle-manifest sync.
-- Provides resolveBookPath, generateManifest, uploadManifest, and
-- downloadManifest.

local M = {}

local logger = require("logger")

local function safe_device_id(device_id)
    return type(device_id) == "string"
        and device_id:match("^%w[%w_-]*$") ~= nil
end

--- Walk cloud_staging/, collect progress + annotations content per book,
--- hash the combined content, and return a manifest table.
function M.generateManifest(plugin)
    logger.info("Syncery: generateManifest started")
    local staging = plugin.state_dir .. "cloud_staging/"
    local lfs = require("libs/libkoreader-lfs")
    local sha2 = require("ffi/sha2")
    local SyncUtil = require("syncery_util")

    -- Bail early if staging directory does not exist
    local staging_attr = lfs.attributes(staging, "mode")
    local staging_files = 0
    if staging_attr == "directory" then
        for _ in lfs.dir(staging) do staging_files = staging_files + 1 end
    end
    logger.info("Syncery: generateManifest staging dir=" .. tostring(staging_attr or "missing") .. " files=" .. tostring(staging_files))
    if not staging_attr then
        return {
            device_id = SyncUtil.get_device_id(),
            ts = os.time(),
            files = {},
        }
    end

    -- Clean up temp files from previous crash
    for f in lfs.dir(staging) do
        if f:match("^syncery%-manifest%-") then
            os.remove(staging .. f)
        end
    end

    -- Step 1: Collect all staging file contents per book
    local book_files = {}
    for f in lfs.dir(staging) do
        local kind, book_id = f:match("^syncery%-(%a+)%-(.+)%.json$")
        if book_id and (kind == "progress" or kind == "annotations") then
            local fh = io.open(staging .. f, "rb")
            if fh then
                local content = fh:read("*a")
                fh:close()
                if content then
                    if not book_files[book_id] then
                        book_files[book_id] = {}
                    end
                    book_files[book_id][kind] = content
                end
            end
        end
    end

    -- Step 2: Hash combined (progress .. annotations) per book
    local files = {}
    for book_id, kinds in pairs(book_files) do
        local progress = kinds.progress or ""
        local annotations = kinds.annotations or ""
        local combined = progress .. "\0" .. annotations
        local h = sha2.md5
        local ctx = h()
        ctx(combined)
        local hash = ctx()
        logger.info("Syncery: generateManifest book_id=" .. tostring(book_id) .. " hash=" .. hash)
        files[book_id] = hash
    end

    return {
        device_id = SyncUtil.get_device_id(),
        ts = os.time(),
        files = files,
    }
end
function M.uploadManifest(plugin, cloud_io, manifest)
    if type(manifest) ~= "table" or not safe_device_id(manifest.device_id) then
        return false, "invalid_device_id"
    end
    logger.info("Syncery: uploadManifest for device " .. tostring(manifest.device_id))
    local staging = plugin.state_dir .. "cloud_staging/"
    local temp_path = staging .. "syncery-manifest-" .. manifest.device_id .. ".txt"
    require("util").makePath(staging)

    local cjson = require("json")
    local json_str = cjson.encode(manifest)

    local fh, err = io.open(temp_path, "wb")
    if not fh then
        logger.warn("Syncery: cannot write manifest temp file:", err)
        return false, "cannot_write_manifest"
    end
    fh:write(json_str)
    fh:close()

    local ok_call, uploaded, upload_err = pcall(function()
        return cloud_io:upload_cloud_file(temp_path)
    end)
    os.remove(temp_path)
    if not ok_call or not uploaded then
        local reason = ok_call and upload_err or uploaded
        logger.warn("Syncery: manifest upload failed:", tostring(reason))
        return false, reason or "upload_failed"
    end
    logger.info("Syncery: manifest upload ok")
    return true, nil
end

--- Download a remote device's manifest from the cloud.
function M.downloadManifest(plugin, cloud_io, device_id)
    logger.info("Syncery: downloadManifest for device " .. tostring(device_id))
    if not safe_device_id(device_id) then return nil end
    local staging = plugin.state_dir .. "cloud_staging/"
    local temp_path = staging .. "syncery-manifest-remote.txt"

    local remote_name = "syncery-manifest-" .. device_id .. ".txt"
    local ok_call, downloaded = pcall(function()
        return cloud_io:download_cloud_file(remote_name, temp_path)
    end)

    if not ok_call or not downloaded then
        os.remove(temp_path)
        return nil
    end

    local fh, err = io.open(temp_path, "rb")
    if not fh then
        os.remove(temp_path)
        return nil
    end

    local content = fh:read("*a")
    fh:close()
    os.remove(temp_path)

    if not content or content == "" then
        return nil
    end

    local cjson = require("json")
    local ok_d, manifest = pcall(cjson.decode, content)
    -- type(manifest) == "table" is required, not just ok_d: a truncated
    -- or unexpected response body can decode successfully to a bare
    -- JSON number/string/boolean (truthy in Lua), and the caller's
    -- `remote.files` access would then raise "attempt to index a
    -- number/string/boolean value" instead of failing gracefully here.
    if not ok_d or type(manifest) ~= "table" then
        logger.warn("Syncery: invalid remote manifest JSON")
        return nil
    end

    logger.info("Syncery: manifest downloaded ok for " .. tostring(device_id))
    return manifest
end

--- Resolve a book_id back to the local file path via the cloud staging file.
function M.resolveBookPath(plugin, book_id)
    local path = plugin.state_dir .. "cloud_staging/syncery-progress-"
        .. book_id .. ".json"
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a"); f:close()
    local ok, data = pcall(require("json").decode, content)
    -- type(data) == "table" is required, not just truthy: this file is
    -- expected to be a syncery-progress envelope, but a bare JSON
    -- number/string/boolean would otherwise pass "not data" and crash
    -- on the .entries access below instead of failing gracefully here.
    if not ok or type(data) ~= "table" then return nil end
    local my_device = require("syncery_util").get_device_id()
    local my_entry = data.entries and data.entries[my_device]
    if my_entry and my_entry.file then return my_entry.file end
    -- Deterministic fallback order: this is reached only for a bootstrapped
    -- (never-opened-locally) book whose OWN entry has no .file yet -- pick
    -- whichever OTHER device's path comes first, but by sorted device_id,
    -- not raw pairs() order (which Lua does not guarantee stable, so the
    -- same entries could otherwise resolve to a DIFFERENT peer's path on
    -- a different run if 2+ peers recorded different native paths).
    local device_ids = {}
    for device_id in pairs(data.entries or {}) do device_ids[#device_ids + 1] = device_id end
    table.sort(device_ids)
    for _, device_id in ipairs(device_ids) do
        local entry = data.entries[device_id]
        if entry.file then return entry.file end
    end
    return nil
end

return M
