-- =============================================================================
-- syncery_progress/conflict_resolver.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- Syncthing creates conflict files when it detects that two devices
-- modified the same file at the same time (or without seeing each
-- other's changes).  For our progress file, those look like:
--
--     foo.epub.syncery-progress.sync-conflict-20241117-180000-PHN.json
--
-- Without resolution, the user would see those files pile up next to
-- the real progress file, and one device's progress would essentially
-- get lost (the "winning" version is picked by Syncthing's own rules,
-- typically not the newest).
--
-- This module finds those conflict files, merges them into the main
-- progress file, and deletes them.  Resolution is automatic and
-- non-destructive: every entry from every conflict file participates
-- in the merge, with `(revision, timestamp)` newest-wins.
--
--
-- WHY 2-WAY MERGE (NOT 3-WAY) FOR CONFLICTS
--
-- The 3-way merge in merge.lua needs a "last-sync" view as the common
-- ancestor.  For conflict files we don't have that — the conflict
-- file represents "what the OTHER device wanted the shared file to
-- look like", with no shared ancestor.
--
-- Pairwise newer-wins is the right policy: each entry carries its
-- own `(revision, timestamp)`, so we can directly compare two
-- versions of the same device_id and pick the newer.  No deletion
-- logic needed because progress entries don't have tombstones in
-- the new design.
--
--
-- ATOMIC WRITES
--
-- All writes go through json_store, which uses tmp-file-then-rename.
-- Conflict files are only deleted AFTER the merged main file has
-- been written successfully.  If anything fails midway, the conflict
-- files remain on disk and will be retried on the next call.
--
-- =============================================================================

local JsonStore = require("syncery_ann/json_store")
local Paths     = require("syncery_progress/paths")
local StateStore = require("syncery_progress/state_store")
local lfs       = require("libs/libkoreader-lfs")
local logger    = require("logger")

local ConflictResolver = {}


-- ----------------------------------------------------------------------------
-- Syncthing names conflict files `<stem>.sync-conflict-<date>-<time>-<id>.<ext>`.
-- Some versions use `~` as the separator instead of `.`.  Match both.
-- ----------------------------------------------------------------------------

local CONFLICT_INFIX_PATTERN = "[.~]sync%-conflict%-%d+%-%d+%-.+"


-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------


--- Find all conflict files for a given book's shared progress file.
---
--- Returns a list of full paths (zero-length when there are none),
--- sorted by filename for determinism.
---
--- @param book_path string Absolute path to the book.
--- @return table List of conflict-file paths.
--- Find conflict files for an EXPLICIT shared-progress FILE path (no
--- derivation).  The Progress Browser carries each book's real
--- progress_path and reads it directly; `find_conflict_files` below derives
--- the path from book_path and delegates here.
---
--- @param main_path string|nil Absolute path to the canonical progress file.
--- @return table Sorted list of conflict-file paths (empty when none / nil).
function ConflictResolver._conflict_files_for(main_path)
    if not main_path then return {} end

    local directory     = main_path:match("^(.*)/[^/]+$") or "."
    local main_filename = main_path:match("([^/]+)$") or ""

    -- The "stem" is the filename without its `.json` extension.
    local stem = main_filename:match("^(.+)%.json$") or main_filename
    local stem_escaped = ConflictResolver._escape_lua_pattern(stem)

    local conflict_pattern = "^" .. stem_escaped .. CONFLICT_INFIX_PATTERN .. "%.json$"

    local conflicts = {}
    local ok, iter_or_err, state, init = pcall(lfs.dir, directory)
    if not ok then return {} end

    for entry in iter_or_err, state, init do
        if entry ~= "." and entry ~= ".." and entry ~= main_filename
                and entry:match(conflict_pattern) then
            table.insert(conflicts, directory .. "/" .. entry)
        end
    end

    table.sort(conflicts)
    return conflicts
end


--- Find all conflict files for a given book's shared progress file.
--- Derives the file path from book_path + storage mode, then delegates.
---
--- @param book_path string Absolute path to the book.
--- @return table List of conflict-file paths.
function ConflictResolver.find_conflict_files(book_path)
    return ConflictResolver._conflict_files_for(
        Paths.shared_progress_path(book_path))
end


--- READ-ONLY merged view of a book's shared progress file + its Syncthing
--- conflict copies, for DISPLAY (the Progress Browser).
---
--- Reads the canonical file at `main_path` and every `.sync-conflict-*`
--- sibling, folds them with the SAME pairwise newer-wins merge `resolve_all`
--- uses (`merge_two_states`), and returns the merged state -- so the dashboard
--- shows "the newest position per device" across files a Syncthing conflict
--- has split.
---
--- Unlike `resolve_all`, this writes NOTHING and deletes NOTHING: a read-only
--- PREVIEW of what resolution would produce (resolution itself happens on the
--- next sync of the book, via `resolve_all`).  With no conflict files it
--- returns just the normalized canonical state -- identical to a plain
--- `StateStore.load_shared_from_path` read, so the zero-conflict (common, and
--- cloud-always) case is unchanged.  Takes the progress FILE path (not
--- book_path) for cross-mode correctness; nil/unreadable degrade to an
--- empty-but-well-formed state.
---
--- @param main_path string|nil Absolute path to the canonical progress file.
--- @return table  merged The merged state (with an `entries` sub-map).
--- @return number n      How many `.sync-conflict-*` copies were folded in
---                       (0 when none) -- lets a caller flag a conflicted book.
function ConflictResolver.merged_view(main_path)
    if not main_path then return ConflictResolver._empty_state(), 0 end

    local merged = JsonStore.read(main_path)
    if not merged then merged = ConflictResolver._empty_state() end
    ConflictResolver._normalize_state(merged)

    local conflict_files = ConflictResolver._conflict_files_for(main_path)
    for _, conflict_path in ipairs(conflict_files) do
        local conflict_state = JsonStore.read(conflict_path)
        if conflict_state then
            -- merge_two_states normalizes both inputs internally.
            merged = ConflictResolver.merge_two_states(merged, conflict_state)
        end
    end

    return merged, #conflict_files
end


--- Find, merge, and delete all conflict files for an EXPLICIT shared-progress
--- FILE path (the WRITE twin of `merged_view`).  Used by the Progress Browser,
--- which carries each book's real `progress_path` and operates on it directly,
--- sidestepping any book_path -> path derivation.
---
--- Returns three values:
---   * how many conflict files were processed
---   * how many of those merged cleanly (the rest had unparseable
---     content but were still removed)
---   * an error message, or nil on success
---
--- The merged main file is saved atomically.  Conflict files are deleted only
--- after a successful save.  If the save fails, the conflict files remain --
--- the next call will try again.
---
--- @param main_path string|nil Absolute path to the canonical progress file.
--- @return number Count of conflict files seen.
--- @return number Count of conflict files merged successfully.
--- @return string|nil Error message, or nil.
function ConflictResolver.resolve_all_at_path(main_path)
    if not main_path then return 0, 0, "no_main_path" end

    local conflicts = ConflictResolver._conflict_files_for(main_path)
    if #conflicts == 0 then
        return 0, 0, nil
    end

    -- Load the main file (or an empty state if it doesn't exist yet).
    -- We route through StateStore so the loaded body is normalized to
    -- the canonical `{ entries = ... }` shape before merge.
    local main_loaded, _ = JsonStore.read(main_path)
    local merged_state
    if main_loaded then
        merged_state = StateStore._validate_and_repair(main_loaded)
    else
        merged_state = ConflictResolver._empty_state()
    end

    local merged_successfully = 0
    for _, conflict_path in ipairs(conflicts) do
        local conflict_loaded, c_diag = JsonStore.read(conflict_path)
        if conflict_loaded then
            local conflict_state =
                StateStore._validate_and_repair(conflict_loaded)
            merged_state = ConflictResolver.merge_two_states(
                merged_state, conflict_state)
            merged_successfully = merged_successfully + 1
            logger.info("Syncery progress conflict_resolver: merged "
                .. conflict_path)
        else
            logger.warn("Syncery progress conflict_resolver: skipped unreadable conflict "
                .. tostring(conflict_path) .. " (" .. tostring(c_diag) .. ")")
        end
    end

    local ok, save_diag = JsonStore.write(main_path, merged_state)
    if not ok then
        return #conflicts, 0, "save_failed:" .. tostring(save_diag)
    end

    -- Save succeeded; safe to delete the conflict files now.
    for _, conflict_path in ipairs(conflicts) do
        os.remove(conflict_path)
    end

    logger.info(string.format(
        "Syncery progress conflict_resolver: resolved %d conflict file(s) at %s",
        #conflicts, main_path))
    return #conflicts, merged_successfully, nil
end


--- Find, merge, and delete all conflict files for a given book.  Derives the
--- shared-progress file path from book_path + storage mode, then delegates to
--- `resolve_all_at_path`.  A nil/unresolvable path is a no-op (0, 0, nil) --
--- matching the original behaviour, where the empty conflict list short-circuits
--- before any error could be raised.
---
--- @param book_path string Absolute path to the book.
--- @return number Count of conflict files seen.
--- @return number Count of conflict files merged successfully.
--- @return string|nil Error message, or nil.
function ConflictResolver.resolve_all(book_path)
    local main_path = Paths.shared_progress_path(book_path)
    if not main_path then return 0, 0, nil end
    return ConflictResolver.resolve_all_at_path(main_path)
end


--- Merge two complete state tables pairwise (no last-sync ancestor).
---
--- Exposed publicly so the sync orchestrator can use the same merge
--- logic for other "two state files, no ancestor" cases (for example,
--- when copying state between hash mode and SDR mode).
---
--- The entries are merged per device_id by `(revision, timestamp)`
--- newer-wins.  Top-level metadata (`device_id` / `device_label` —
--- who last wrote the file) is attributed to whichever side has the
--- newest entry.
---
--- @param state_a table The first state.
--- @param state_b table The second state.
--- @return table The merged state.
function ConflictResolver.merge_two_states(state_a, state_b)
    state_a = state_a or ConflictResolver._empty_state()
    state_b = state_b or ConflictResolver._empty_state()
    ConflictResolver._normalize_state(state_a)
    ConflictResolver._normalize_state(state_b)

    local merged = ConflictResolver._empty_state()

    merged.schema_version = math.max(
        state_a.schema_version or 1, state_b.schema_version or 1)

    merged.entries = ConflictResolver._merge_entry_maps(
        state_a.entries, state_b.entries)

    return merged
end


-- ----------------------------------------------------------------------------
-- Internal: per-key merge
-- ----------------------------------------------------------------------------


--- Combine two `entries` maps, picking the newer per device_id.
function ConflictResolver._merge_entry_maps(map_a, map_b)
    map_a = map_a or {}
    map_b = map_b or {}
    local merged = {}

    for device_id, entry in pairs(map_a) do
        merged[device_id] = entry
    end
    for device_id, entry_b in pairs(map_b) do
        local entry_a = merged[device_id]
        if entry_a == nil then
            merged[device_id] = entry_b
        else
            merged[device_id] = ConflictResolver._pick_newer_entry(entry_a, entry_b)
        end
    end

    return merged
end


--- Pairwise newer-wins for two entries: max (revision, timestamp).
function ConflictResolver._pick_newer_entry(entry_a, entry_b)
    local rev_a = tonumber(entry_a and entry_a.revision) or 0
    local rev_b = tonumber(entry_b and entry_b.revision) or 0
    if rev_a ~= rev_b then
        return (rev_a > rev_b) and entry_a or entry_b
    end

    local ts_a = tonumber(entry_a and entry_a.timestamp) or 0
    local ts_b = tonumber(entry_b and entry_b.timestamp) or 0
    if ts_a ~= ts_b then
        return (ts_a > ts_b) and entry_a or entry_b
    end

    -- True tie.  Deterministic fallback: prefer entry_b ("incoming"
    -- side wins).  This is the same tie-breaking shape as the
    -- annotation conflict_resolver.
    return entry_b
end


-- ----------------------------------------------------------------------------
-- Internal: shape helpers
-- ----------------------------------------------------------------------------


function ConflictResolver._empty_state()
    return {
        schema_version = 1,
        entries        = {},
    }
end


function ConflictResolver._normalize_state(state)
    if type(state.entries) ~= "table" then state.entries = {} end
end


function ConflictResolver._escape_lua_pattern(literal)
    return (literal:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
end


return ConflictResolver
