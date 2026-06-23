-- syncery_update.lua — update the Syncery plugin itself from GitHub.
--
-- Fetches the plugin's own latest GitHub release, shows the release notes,
-- downloads the release archive, unpacks it in place over the plugin directory,
-- and offers to restart KOReader to load the new code.
--
-- No bundled CA store: the download uses KOReader's LuaSocket first and falls
-- back to system `curl`, which validates TLS against the OS trust store and
-- follows GitHub's CDN redirects (`-L`) — the approach bookshelf uses, and the
-- reason no `cacert.pem` is shipped.  Temp files live under DataStorage's
-- settings dir, never `/tmp` (Android has no `/tmp`).
--
-- In-place unpack preserves files NOT in the archive; a file a future version
-- deletes lingers as a harmless orphan until a reinstall (KOReader loads only
-- main.lua plus the modules it requires).
--
-- Pure helpers (version / asset / markdown) take no I/O and are unit-tested
-- directly.  KOReader / UI / JSON modules are required LAZILY inside the I/O
-- functions, so the module loads — and its pure helpers run — under the
-- bare-luajit spec harness, which has no KOReader stubs at require time.

local M = {}

-- REPO: the GitHub "owner/repo" the update checks — releases live here.
local REPO          = "d0nizam/syncery.koplugin"
local API_LATEST    = "https://api.github.com/repos/" .. REPO .. "/releases/latest"
local RELEASES_PAGE = "https://github.com/" .. REPO .. "/releases"
local USER_AGENT    = "KOReader-Syncery"
local MIN_ZIP_SIZE  = 4096   -- a real plugin zip is far larger; an error body is tiny.

-- The installed plugin always lives at plugins/syncery.koplugin — the folder
-- name is fixed regardless of which repo the release came from.  Resolved
-- lazily so the module needs no DataStorage at load time.
local function plugin_path()
    return require("datastorage"):getDataDir() .. "/plugins/syncery.koplugin"
end

-- Android has no /tmp; downloads land under the settings dir instead.
local function cache_dir()
    return require("datastorage"):getSettingsDir() .. "/syncery_cache"
end

---------------------------------------------------------------------------
-- Pure helpers (no UI, no network, no KOReader requires) — unit-tested.
---------------------------------------------------------------------------

-- Read the installed plugin version from _meta.lua.  Path is injectable so the
-- spec can point at a fixture; production reads the live plugin _meta.lua.
function M.getInstalledVersion(meta_path)
    meta_path = meta_path or (plugin_path() .. "/_meta.lua")
    local ok, meta = pcall(dofile, meta_path)
    if ok and type(meta) == "table" and meta.version then
        return meta.version
    end
    return "unknown"
end

-- "v1.2.3" / "1.2.3" -> { 1, 2, 3 }.  Non-numeric components become 0.
function M.parseVersion(v)
    local parts = {}
    for part in tostring(v):gsub("^v", ""):gmatch("([^.]+)") do
        parts[#parts + 1] = tonumber(part) or 0
    end
    return parts
end

-- True iff candidate is strictly newer than installed (component-wise semver).
function M.isNewer(candidate, installed)
    local a, b = M.parseVersion(candidate), M.parseVersion(installed)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x > y then return true end
        if x < y then return false end
    end
    return false
end

-- Pick the download URL for a release.  Prefer a `.zip` asset (Syncery's release
-- zip from `make build`); fall back to the source zipball.  BOTH wrap the files
-- in a top-level `syncery.koplugin/` folder, so both unpack WITH root-stripping
-- (so the wrapper collapses onto the existing plugin dir).  Returns
-- (url, strip_root=true) or (nil, nil).
function M.selectAsset(release)
    for _, asset in ipairs(release.assets or {}) do
        if (asset.name or ""):match("%.zip$") and asset.browser_download_url then
            return asset.browser_download_url, true
        end
    end
    if release.zipball_url then
        return release.zipball_url, true
    end
    return nil, nil
end

-- Strip the markdown most likely to appear in GitHub release notes so the
-- plain-text viewer reads cleanly.
function M.stripMarkdown(text)
    text = tostring(text or "")
    text = text:gsub("#+%s*", "")
    text = text:gsub("%*%*(.-)%*%*", "%1")
    text = text:gsub("%*(.-)%*", "%1")
    text = text:gsub("`(.-)`", "%1")
    return text
end

---------------------------------------------------------------------------
-- I/O + UI (KOReader / JSON modules required lazily).
---------------------------------------------------------------------------

-- Fetch and JSON-decode a GitHub API URL.  LuaSocket first; curl fallback
-- (system CA, follows redirects) — no bundled cacert.
local function httpGetJSON(url)
    local rj_ok, rapidjson = pcall(require, "rapidjson")
    local JSON = rj_ok and rapidjson or require("json")

    local ok_require, http, ltn12, socket, socketutil = pcall(function()
        return require("socket/http"), require("ltn12"),
               require("socket"), require("socketutil")
    end)
    if ok_require then
        local body = {}
        local ok_req, code = pcall(function()
            socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
            local c = socket.skip(1, http.request({
                url = url,
                method = "GET",
                headers = {
                    ["User-Agent"] = USER_AGENT,
                    ["Accept"]     = "application/vnd.github+json",
                },
                sink = ltn12.sink.table(body),
                redirect = true,
            }))
            socketutil:reset_timeout()
            return c
        end)
        if ok_req and code == 200 then
            local ok, data = pcall(JSON.decode, table.concat(body))
            if ok then return data end
        end
        pcall(function() socketutil:reset_timeout() end)
    end
    -- Fallback: curl (available on Android, desktop).
    local handle = io.popen(string.format(
        "curl -sL -H 'User-Agent: %s' -H 'Accept: application/vnd.github+json' %q",
        USER_AGENT, url))
    if handle then
        local body = handle:read("*a")
        handle:close()
        if body and body ~= "" then
            local ok, data = pcall(JSON.decode, body)
            if ok then return data end
        end
    end
    return nil
end

-- Download `url` to `dest`.  LuaSocket first; curl fallback.  The curl `-f` flag
-- makes it exit non-zero on HTTP errors (e.g. 404) so an error body never gets
-- written and mistaken for a zip; `-L` follows GitHub's CDN redirects.
local function downloadFile(url, dest)
    local ok_require, http, ltn12, socket, socketutil = pcall(function()
        return require("socket/http"), require("ltn12"),
               require("socket"), require("socketutil")
    end)
    if ok_require then
        local f = io.open(dest, "wb")
        if f then
            local ok_dl, code = pcall(function()
                socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
                local c = socket.skip(1, http.request({
                    url = url,
                    method = "GET",
                    headers = { ["User-Agent"] = USER_AGENT },
                    sink = ltn12.sink.file(f),   -- ltn12 closes the file
                    redirect = true,
                }))
                socketutil:reset_timeout()
                return c
            end)
            if not ok_dl then pcall(function() socketutil:reset_timeout() end) end
            if ok_dl and code == 200 then return true end
        end
    end
    pcall(os.remove, dest)
    local ret = os.execute(string.format("curl -sfL -o %q %q", dest, url))
    if ret == 0 or ret == true then return true end
    pcall(os.remove, dest)
    return false
end

local function fileSize(path)
    local lfs = require("libs/libkoreader-lfs")
    local attr = lfs.attributes(path)
    return (attr and attr.size) or 0
end

-- Crude zip sniff: a real archive starts with the "PK" local-file signature.
local function isZip(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local sig = f:read(2)
    f:close()
    return sig == "PK"
end

local function offerReleasesPage(message)
    local ConfirmBox  = require("ui/widget/confirmbox")
    local InfoMessage = require("ui/widget/infomessage")
    local UIManager   = require("ui/uimanager")
    local Device      = require("device")
    local _ = require("syncery_i18n").translate
    if Device:canOpenLink() then
        UIManager:show(ConfirmBox:new{
            text        = message .. "\n\n" .. _("Open the releases page in a browser?"),
            ok_text     = _("Open"),
            ok_callback = function() Device:openLink(RELEASES_PAGE) end,
        })
    else
        UIManager:show(InfoMessage:new{ text = message, timeout = 3 })
    end
end

local function upToDate(installed)
    local InfoMessage = require("ui/widget/infomessage")
    local UIManager   = require("ui/uimanager")
    local T = require("ffi/util").template
    local _ = require("syncery_i18n").translate
    UIManager:show(InfoMessage:new{
        text = T(_("Syncery is up to date.\n\nInstalled version: %1"), installed),
    })
end

-- Download `zip_url`, unpack it over the plugin directory, then offer a restart.
-- `strip_root` comes from M.selectAsset (true for Syncery's wrapped archive).
function M.install(zip_url, strip_root, new_version)
    local ConfirmBox  = require("ui/widget/confirmbox")
    local InfoMessage = require("ui/widget/infomessage")
    local UIManager   = require("ui/uimanager")
    local Device      = require("device")
    local lfs         = require("libs/libkoreader-lfs")
    local logger      = require("logger")
    local T = require("ffi/util").template
    local _ = require("syncery_i18n").translate

    UIManager:show(InfoMessage:new{ text = _("Downloading update…"), timeout = 1 })
    UIManager:scheduleIn(0.1, function()
        local dir = cache_dir()
        if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
        local zip_path = dir .. "/syncery_update.zip"
        pcall(os.remove, zip_path)

        if not downloadFile(zip_url, zip_path) then
            pcall(os.remove, zip_path)
            logger.warn("[Syncery] plugin update download failed")
            offerReleasesPage(_("Update failed."))
            return
        end

        if fileSize(zip_path) < MIN_ZIP_SIZE or not isZip(zip_path) then
            pcall(os.remove, zip_path)
            offerReleasesPage(_("The downloaded file does not look like a plugin archive."))
            return
        end

        -- Device:unpackArchive removes the archive on success; remove it on the
        -- failure path too.
        local ok, err = Device:unpackArchive(zip_path, plugin_path(), strip_root)
        pcall(os.remove, zip_path)
        if not ok then
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = T(_("Installation failed: %1"), tostring(err)),
            })
            return
        end

        -- Same restart prompt as the settings-reset flow: restartKOReader()
        -- quits with code 85, which the launch wrapper relaunches on every
        -- device (askForRestart only describes on platforms without a handler).
        UIManager:show(ConfirmBox:new{
            text        = T(_("Syncery updated to %1.\n\nRestart KOReader now to load it?"), new_version),
            ok_text     = _("Restart"),
            cancel_text = _("Later"),
            ok_callback = function() UIManager:restartKOReader() end,
        })
    end)
end

-- Entry point: check GitHub for a newer release and, if found, show the notes
-- with an "Update & restart" action.  Brings Wi-Fi up per the user's prefs.
function M.check()
    local InfoMessage = require("ui/widget/infomessage")
    local UIManager   = require("ui/uimanager")
    local NetworkMgr  = require("ui/network/manager")
    local T = require("ffi/util").template
    local _ = require("syncery_i18n").translate

    NetworkMgr:runWhenOnline(function()
        UIManager:show(InfoMessage:new{ text = _("Checking for plugin updates…"), timeout = 1 })
        UIManager:scheduleIn(0.1, function()
            local installed = M.getInstalledVersion()
            local release = httpGetJSON(API_LATEST)
            if type(release) ~= "table" or not release.tag_name then
                offerReleasesPage(_("Could not check for updates."))
                return
            end
            -- releases/latest already excludes drafts/prereleases; guard anyway.
            if release.draft or release.prerelease
               or not M.isNewer(release.tag_name, installed) then
                upToDate(installed)
                return
            end

            local zip_url, strip_root = M.selectAsset(release)
            if not zip_url then
                offerReleasesPage(_("This release has no downloadable archive."))
                return
            end

            local latest = release.tag_name
            local notes  = M.stripMarkdown(release.body)
            local TextViewer = require("ui/widget/textviewer")
            local viewer
            viewer = TextViewer:new{
                title = _("Plugin update available"),
                text  = T(_("Installed: %1\nLatest: %2"), installed, latest)
                        .. "\n\n" .. notes,
                buttons_table = {{
                    {
                        text     = _("Later"),
                        callback = function() UIManager:close(viewer) end,
                    },
                    {
                        text     = _("Update & restart"),
                        callback = function()
                            UIManager:close(viewer)
                            M.install(zip_url, strip_root, latest)
                        end,
                    },
                }},
                add_default_buttons = false,
            }
            UIManager:show(viewer)
        end)
    end)
end

return M
