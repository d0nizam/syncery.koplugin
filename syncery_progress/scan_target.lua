-- syncery_progress/scan_target.lua
--
-- Maps a book's shared-progress path to the Syncthing scan target: the
-- folder id the file lives in, plus the sub-directory within that folder
-- (so the daemon can scan a narrow path instead of the whole folder).
--
-- This logic was extracted VERBATIM from main.lua's `_getScanTarget` so it
-- is unit-testable: main.lua requires the KOReader UI and is only
-- loadfile-checked in the suite, which left this (replication-critical)
-- path-math untested.  main.lua now reads the config from Settings and
-- delegates the computation here; behaviour is unchanged.

local M = {}

-- Treat every non-alphanumeric char as a literal in a Lua pattern.  Verbatim
-- copy of `syncery_util.escape_pattern`, inlined so this module has no
-- requires and stays directly testable.
local function escape_pattern(s) return (s:gsub("([^%w])", "%%%1")) end

-- Single-folder match: if `cfg.folder` is set and `book_file` lives under its
-- `path`, return that folder's id and root (with a trailing slash).  Falls back
-- to `cfg.folder_id` (the default) with a nil root otherwise.  `folder.folder_id`
-- or `folder.id` are both accepted as the id key.
local function resolve_folder_for(book_file, cfg)
    if not cfg or not book_file then
        return (cfg and cfg.folder_id) or "default", nil
    end
    local folder = cfg.folder
    if type(folder) == "table" and type(folder.path) == "string" and folder.path ~= "" then
        local fid = folder.folder_id or folder.id
        local norm = book_file:gsub("\\", "/")
        local fp = folder.path:gsub("\\", "/")
        if fp:sub(-1) ~= "/" then fp = fp .. "/" end
        if fid and norm:sub(1, #fp) == fp then
            return fid, fp
        end
    end
    return cfg.folder_id or "default", nil
end

-- Compute `(folder_id, sub_dir)` for a book's `sync_path` under the configured
-- folder in `cfg` ({ folder_id, folder }).  `sub_dir` is the directory of
-- `sync_path` RELATIVE to the matched folder root, computed per `storage_mode`
-- ("hash" vs everything else / "sdr"); nil when the path isn't under a
-- configured root.
function M.compute(sync_path, cfg, storage_mode)
    if not sync_path then
        return cfg.folder_id or "default", nil
    end

    local folder_id, matched_root = resolve_folder_for(sync_path, cfg)
    if not folder_id then
        return cfg.folder_id or "default", nil
    end

    local sub_dir = nil
    if matched_root then
        local norm_root = matched_root:gsub("\\", "/")
        if norm_root:sub(-1) ~= "/" then norm_root = norm_root .. "/" end
        local norm_sync = sync_path:gsub("\\", "/")

        if storage_mode == "hash" then
            local dir = norm_sync:match("^(.*[/\\])[^/\\]+$")
            if dir then
                local ndir = dir:gsub("\\", "/")
                if ndir:sub(1, #norm_root) == norm_root then
                    sub_dir = ndir:sub(#norm_root + 1)
                    sub_dir = sub_dir:gsub("/+$", "")
                end
            end
        else
            if norm_sync:sub(1, #norm_root) == norm_root then
                sub_dir = norm_sync:match("^" .. escape_pattern(norm_root) .. "(.*)[/\\][^/\\]+$")
                if sub_dir then
                    sub_dir = sub_dir:gsub("/+$", "")
                end
            end
        end
    end

    return folder_id, sub_dir
end

-- True when the Syncthing side has a folder to sync (so callers may push a
-- scan).  The KOSyncthing+ provider self-discovers folders live -- they are not
-- mirrored into Settings -- so it is always considered configured.  Otherwise
-- a folder counts as configured if EITHER a `folder` record with a path is
-- stored OR a real `folder_id` is set ("" / "default" are the not-yet-chosen
-- sentinels).  The two-pronged check avoids regressing a manual setup that set
-- a folder_id without picking a folder.
function M.is_folder_configured(has_kosyncthing, folder_id, folder)
    if has_kosyncthing then return true end
    if type(folder) == "table" and type(folder.path) == "string" and folder.path ~= "" then
        return true
    end
    return type(folder_id) == "string" and folder_id ~= "" and folder_id ~= "default"
end

return M
