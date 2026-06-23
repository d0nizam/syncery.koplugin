-- =============================================================================
-- syncery_transports/stignore.lua
-- =============================================================================
--
-- A NON-INVASIVE writer for Syncthing's `.stignore` file.
--
-- WHY THIS EXISTS
--
-- Syncery's conflict files (`*syncery-*sync-conflict-*`) should not replicate
-- across devices — the local conflict_resolver merges and removes them on each
-- sync, so the copies spreading first is pure noise.  The OLD way to suppress
-- them was a REST call (`set_folder_ignore` → POST /rest/db/ignores) fired at
-- startup.  That call is SYNCHRONOUS (socket.http), so against an unreachable
-- daemon it blocked the UI thread for ~4-10s on every launch — the "white
-- screen" lag.
--
-- Syncthing ALSO reads ignore patterns from a `.stignore` FILE at the synced
-- folder root (https://docs.syncthing.net/users/ignoring.html).  Writing that
-- file is a LOCAL filesystem operation: no network, so it can NEVER block, and
-- it works even when the daemon is down (the daemon reads it on its next scan).
-- The file is durable — it survives daemon AND device restarts — where the REST
-- call had to be repeated every launch.
--
-- This module is therefore the suppression mechanism on the startup/scan path.
-- The REST `register_syncery_ignore_patterns` still exists for the explicit
-- "Conflict-file integration" button (user-initiated, network expected there).
--
-- DESIGN PROPERTIES (all covered by stignore_spec):
--   • NEVER touches the network → never blocks.
--   • Writes ONLY when the folder root path is known (from the picked
--     Syncthing folder).  When the
--     path is unknown it returns "no_path" and does nothing — no block, no error.
--   • Idempotent: the pattern is appended at most once.
--   • Merge-safe: only APPENDS our line; never rewrites or drops the user's
--     existing patterns or `#include` directives.
--   • Fail-soft: an unwritable folder (read-only mount) returns "unwritable"
--     instead of raising.
--
-- =============================================================================


local Stignore = {}


-- The Syncery ignore patterns written to `.stignore`.  bridge.lua's REST
-- registrar references this SAME list (single source — they cannot drift).
--   1. Syncery's own conflict copies — always; both storage modes.  The
--      `syncery-` infix is the safety anchor (never matches user/KOReader
--      files).
--   2/3. KOReader's SDR sidecars whose mergeable content Syncery already
--      syncs via its JSON, so replicating the sidecars is redundant + the
--      source of metadata conflicts: `metadata.<ext>.lua` and
--      `custom_metadata.lua` (each + its `.old` backup, covered by the
--      trailing `*`).  Safe because Syncery rewrites both sidecars locally
--      on apply (annotations/progress/metadata fields → doc_settings →
--      KOReader flush; custom_props → flushCustomMetadata).  In hash mode
--      there is no `.sdr` in the synced tree, so these simply match nothing.
--   4. KOReader's own annotation-sync export `<book>.annotations.lua` (+ its
--      `.old` backup) — present in stable 2026.03+ (readerannotation.lua
--      onExportAnnotations / importAnnotations).  Its annotation content is
--      exactly what Syncery already syncs via its JSON, so replicating it lets
--      KOReader's parallel import (a position+datetime merge with its OWN
--      deletion model) compete with Syncery's tombstone merge across opens —
--      resurrecting tombstoned items / flapping deletions.  Safe to suppress:
--      Syncery applies annotations locally on every device anyway.  Filename-
--      keyed so it matches at any depth (incl. a redirected
--      `annotations_export_folder`); no-op where that folder isn't synced.
-- The `.stignore` glob (Syncthing daemon) matching every Syncery conflict
-- COPY's LITERAL name in BOTH storage modes (the `syncery-` infix is the
-- safety anchor).  This stays SPECIFIC: it must match the conflict copy but
-- NOT the primary `<book>.syncery-annotations.json` — broadening it would make
-- the daemon stop replicating the primaries and Syncery would never sync.
local CONFLICT_PATTERN = "*syncery-*sync-conflict-*"
Stignore.CONFLICT_PATTERN = CONFLICT_PATTERN

-- The KOSyncthing+ conflict-scanner glob (IgnoreRegistry, v1.1.6+).  The
-- scanner DE-MANGLES a conflict copy to its ORIGINAL basename before testing
-- this glob, so it must match the original name (`<book>.syncery-annotations.json`),
-- NOT the conflict form — a glob containing `sync-conflict-` can never match a
-- de-mangled name.  `*syncery-*` matches every Syncery sidecar by the same
-- `syncery-` anchor; on pre-1.1.6 KOSyncthing+ (no de-mangling) it still matches
-- the conflict copy directly, so it is correct on every version and needs no
-- gate.  Deliberately DIFFERENT from CONFLICT_PATTERN: the daemon matches the
-- literal copy, the scanner matches the de-mangled original — unifying the two
-- would break one side (see syncery_transports/README.md).
local CONFLICT_SCANNER_PATTERN = "*syncery-*"
Stignore.CONFLICT_SCANNER_PATTERN = CONFLICT_SCANNER_PATTERN

local PATTERNS = {
    CONFLICT_PATTERN,
    "metadata.*.lua*",
    "custom_metadata.lua*",
    "*.annotations.lua*",
}
Stignore.PATTERNS = PATTERNS


--- Resolve a Syncthing folder_id to its root path via the stored folder.
--- `folder` is the single record stored in settings: { folder_id|id, path }.
--- Returns the path string, or nil when the id doesn't match / has no path.
---@param folder_id string
---@param folder table|nil
---@return string|nil
function Stignore.root_for(folder_id, folder)
    if type(folder_id) ~= "string" or folder_id == "" then return nil end
    if type(folder) ~= "table" then return nil end
    -- Accept both the current `folder_id` key and the legacy `id` key
    -- (older stored records used `id`).
    local fid = folder.folder_id or folder.id
    if fid == folder_id and type(folder.path) == "string" and folder.path ~= "" then
        return folder.path
    end
    return nil
end


--- Ensure `.stignore` at `root` contains our pattern.  Never blocks (local
--- file I/O only), never throws.  `io_open` is injectable for tests; defaults
--- to the real `io.open`.
---@param root string|nil          absolute path to the Syncthing folder root
---@param io_open function|nil     defaults to io.open
---@return string status           "no_path" | "already_present" | "written" | "unwritable"
function Stignore.ensure_at_root(root, io_open)
    io_open = io_open or io.open
    if type(root) ~= "string" or root == "" then return "no_path" end

    -- .stignore lives at the folder ROOT (Syncthing ignores it elsewhere).
    local path = root:gsub("[/\\]+$", "") .. "/.stignore"

    -- Read existing content (the file may not exist yet).
    local existing = ""
    local rf = io_open(path, "r")
    if rf then
        existing = rf:read("*a") or ""
        rf:close()
    end

    -- Collect the patterns not yet present.  Plain-text find on the literal
    -- pattern line (the `*` are literals here, matched verbatim).  Also
    -- migrates an older `.stignore` that has only SOME of our patterns: the
    -- missing ones are appended, the present ones left untouched.
    local missing = {}
    for _, p in ipairs(PATTERNS) do
        if not existing:find(p, 1, true) then
            missing[#missing + 1] = p
        end
    end
    if #missing == 0 then
        return "already_present"
    end

    -- Append-only merge: we never rewrite the file, so the user's own
    -- patterns and `#include` directives are preserved untouched.  Open in
    -- append mode; a read-only folder makes this fail soft.
    local wf = io_open(path, "a")
    if not wf then
        return "unwritable"
    end
    -- Keep our patterns on their own lines even if the file lacked a
    -- trailing NL.
    if #existing > 0 and existing:sub(-1) ~= "\n" then
        wf:write("\n")
    end
    for _, p in ipairs(missing) do
        wf:write(p .. "\n")
    end
    wf:close()
    return "written"
end


--- Integration entry point: ensure `.stignore` for the folder identified by
--- `folder_id`, resolving its root via `get_folders` (a thunk returning the
--- settings folders list).  Never blocks, never throws.
---@param folder_id string|nil
---@param get_folder function|nil    returns the single folder record (or nil)
---@param io_open function|nil       defaults to io.open (injectable for tests)
---@return string status
function Stignore.ensure_for_folder(folder_id, get_folder, io_open)
    local folder = get_folder and get_folder() or nil
    local root = Stignore.root_for(folder_id, folder)
    return Stignore.ensure_at_root(root, io_open)
end


return Stignore
