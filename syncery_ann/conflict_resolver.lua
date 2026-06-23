-- =============================================================================
-- syncery_ann/conflict_resolver.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- Syncthing creates conflict files when it detects that two devices
-- modified the same file at the same time (or without seeing each
-- other's changes).  Those files are named like:
--
--     foo.epub.syncery-annotations.sync-conflict-20241117-180000-PHN.json
--
-- Without resolution, the user would see those files pile up next to
-- the real annotations file, and the actual content would be lost
-- (the "winning" version is essentially picked at random).
--
-- This module finds those conflict files, merges them into the main
-- annotations file, and deletes them.  Resolution is automatic and
-- non-destructive: every annotation, every metadata change, every
-- render setting from every conflict file participates in the merge,
-- and newer entries beat older entries by `datetime_updated`.
--
-- A READ-ONLY variant, `merged_view`, returns the same merge WITHOUT
-- writing or deleting anything — the annotation browser uses it to show
-- the newest of each annotation across a conflict-split file, while the
-- actual resolution still happens on the next sync via `resolve_all`.
--
--
-- WHY 2-WAY MERGE (NOT 3-WAY) FOR CONFLICTS
--
-- The 3-way merge in merge.lua needs a "last-sync" view as the common
-- ancestor.  But for conflict files, we don't have that.  The conflict
-- file represents "what the OTHER device wanted the shared file to
-- look like", and the main file represents "what landed in shared
-- first".  There's no third side here.
--
-- Pairwise newer-wins is the right policy: each annotation has its
-- own datetime_updated, so we can directly compare two versions of
-- the same key and pick the newer.  No deletion-detection logic
-- needed because each side independently carries any deletions as
-- explicit tombstones (alive vs deleted is just another property
-- we pick the newer of).
--
--
-- WHAT WE MERGE
--
-- All three sections of the state file:
--   * annotations    — per-key, newer datetime_updated wins
--   * metadata       — per-field via MetadataBridge.merge: status by the
--                      lifecycle lattice (status_lattice.lua, clock-free);
--                      every other field's both-present conflict by the
--                      date -> device-id tiebreak shared with the 3-way merge
--   * render_settings — whole block, newer datetime_updated wins
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

local JsonStore  = require("syncery_ann/json_store")
local Paths      = require("syncery_ann/paths")
local Merge      = require("syncery_ann/merge")
local MetadataBridge = require("syncery_ann/metadata_bridge")
local RenderSettingsBridge = require("syncery_ann/render_settings_bridge")
local lfs        = require("libs/libkoreader-lfs")
local logger     = require("logger")

local ConflictResolver = {}


-- ----------------------------------------------------------------------------
-- The Syncthing naming convention for conflict files.
--
-- The default form is `<stem>.sync-conflict-<date>-<time>-<id>.<ext>`,
-- but some versions / configurations use `~` as the separator instead
-- of `.`.  The pattern below matches both.
-- ----------------------------------------------------------------------------

local CONFLICT_INFIX_PATTERN = "[.~]sync%-conflict%-%d+%-%d+%-.+"


-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------


--- Path-based core: find conflict-file siblings of a GIVEN annotations file
--- path (the directory + stem of `main_path`), independent of any book_path /
--- storage-mode derivation.
---
--- The annotation browser passes the SCANNED annotations_path directly here:
--- re-deriving the path from book_path is unreliable for a book stored in a
--- different KOReader metadata mode than the current one (the read-path fix
--- lesson), so the conflicts of the real file must be looked up beside the
--- real file.
---
--- @param main_path string|nil Absolute path to the canonical annotations file.
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


--- Find all conflict files for a given book's shared annotations file.
---
--- Returns a list of full paths to conflict files (zero-length list
--- when there are none).  The list is sorted by filename for
--- determinism — useful when the user wants to see "what conflicts
--- did you resolve" in a log.
---
--- @param book_path string Absolute path to the book.
--- @return table List of conflict-file paths.
function ConflictResolver.find_conflict_files(book_path)
    return ConflictResolver._conflict_files_for(
        Paths.shared_annotations_path(book_path))
end


--- READ-ONLY merged view of a book's annotations file + its Syncthing conflict
--- copies, for DISPLAY (the annotation browser).
---
--- Reads the canonical file at `main_path` and every `.sync-conflict-*`
--- sibling, folds them with the SAME pairwise newer-wins merge `resolve_all`
--- uses, and returns the merged state — so the browser shows "the newest of
--- each annotation" across files a Syncthing conflict has split.
---
--- Unlike `resolve_all`, this writes NOTHING and deletes NOTHING: it is a
--- read-only PREVIEW of what resolution would produce (resolution itself
--- happens on the next sync of the book, via `resolve_all`).  With no conflict
--- files it returns just the normalized canonical state — identical to a plain
--- `load_shared_from_path` read, so the zero-conflict (common) case is
--- unchanged.  Takes the annotations FILE path (not book_path) for cross-mode
--- correctness; nil/unreadable degrade to an empty-but-well-formed state.
---
--- @param main_path string|nil Absolute path to the canonical annotations file.
--- @return table merged   The merged state (annotations / metadata / render_settings).
--- @return number n       How many `.sync-conflict-*` copies were discovered and
---                        folded in (0 when none) -- lets a caller flag a book
---                        whose annotations were reconciled from a sync conflict.
function ConflictResolver.merged_view(main_path)
    if not main_path then return ConflictResolver._empty_state(), 0 end

    local merged = JsonStore.read(main_path)
    if not merged then merged = ConflictResolver._empty_state() end
    ConflictResolver._normalize_state(merged)

    local conflict_files = ConflictResolver._conflict_files_for(main_path)
    for _, conflict_path in ipairs(conflict_files) do
        local conflict_state = JsonStore.read(conflict_path)
        if conflict_state then
            ConflictResolver._normalize_state(conflict_state)
            merged = ConflictResolver._pairwise_merge_states(merged, conflict_state)
        end
    end

    return merged, #conflict_files
end


--- Find, merge, and delete all conflict files for a given annotations FILE.
---
--- Path-based core of `resolve_all`.  Operates directly on the canonical
--- annotations file (not a book_path), so a caller that already holds the
--- exact file the browser read -- e.g. the annotation browser's "Resolve
--- conflict" action -- resolves THAT file, staying correct across metadata
--- modes (re-deriving the path from a book_path could miss a book stored
--- under a different mode).
---
--- Returns three values:
---   * how many conflict files were processed
---   * how many of those merged cleanly (the rest had unparseable
---     content but were still removed, because keeping a malformed
---     file around forever doesn't help anyone)
---   * an error message, or nil on success
---
--- The merged main file is saved atomically.  Conflict files are
--- deleted only after a successful save.  If the save fails, the
--- conflict files remain -- the next call will try again.
---
--- @param main_path string|nil Absolute path to the canonical annotations file.
--- @return number Count of conflict files seen.
--- @return number Count of conflict files merged successfully.
--- @return string|nil Error message, or nil.
function ConflictResolver.resolve_all_at_path(main_path)
    if not main_path then return 0, 0, nil end

    local conflicts = ConflictResolver._conflict_files_for(main_path)
    if #conflicts == 0 then
        return 0, 0, nil
    end

    -- Load the main file (or an empty state if it doesn't exist yet).
    local merged_state, diag = JsonStore.read(main_path)
    if not merged_state then
        if diag ~= "not_found" and diag ~= "empty" then
            logger.warn("Syncery conflict_resolver: main file unreadable ("
                .. tostring(diag) .. "), starting from empty state for merge")
        end
        merged_state = ConflictResolver._empty_state()
    end
    ConflictResolver._normalize_state(merged_state)

    local merged_successfully = 0
    for _, conflict_path in ipairs(conflicts) do
        local conflict_state, c_diag = JsonStore.read(conflict_path)
        if conflict_state then
            ConflictResolver._normalize_state(conflict_state)
            merged_state = ConflictResolver._pairwise_merge_states(
                merged_state, conflict_state)
            merged_successfully = merged_successfully + 1
            logger.info("Syncery conflict_resolver: merged " .. conflict_path)
        else
            logger.warn("Syncery conflict_resolver: skipped unreadable conflict "
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
        "Syncery conflict_resolver: resolved %d conflict file(s) at %s",
        #conflicts, main_path))
    return #conflicts, merged_successfully, nil
end


--- Find, merge, and delete all conflict files for a book.
---
--- Thin wrapper over `resolve_all_at_path`: derives the canonical annotations
--- file path from `book_path` and delegates.  Used by the sync path, which
--- works from a book_path.
---
--- @param book_path string Absolute path to the book.
--- @return number Count of conflict files seen.
--- @return number Count of conflict files merged successfully.
--- @return string|nil Error message, or nil.
function ConflictResolver.resolve_all(book_path)
    local main_path = Paths.shared_annotations_path(book_path)
    if not main_path then return 0, 0, nil end
    return ConflictResolver.resolve_all_at_path(main_path)
end


--- Merge two complete state tables (no last-sync — pairwise newer wins).
---
--- Exposed as a public helper because the sync orchestrator may want
--- to merge two state files without going through the conflict-file
--- machinery (for example, when copying state between hash mode and
--- SDR mode).
---
--- @param state_a table The first state.
--- @param state_b table The second state.
--- @return table The merged state.
function ConflictResolver.merge_two_states(state_a, state_b)
    state_a = state_a or ConflictResolver._empty_state()
    state_b = state_b or ConflictResolver._empty_state()
    ConflictResolver._normalize_state(state_a)
    ConflictResolver._normalize_state(state_b)
    return ConflictResolver._pairwise_merge_states(state_a, state_b)
end


-- ----------------------------------------------------------------------------
-- Internal: the actual merge logic
-- ----------------------------------------------------------------------------


--- Combine two state tables key-by-key, picking newer per key.
---
--- All three sections (annotations, metadata, render_settings) get
--- their own appropriate merge strategy:
---   * annotations    → per-key, newer datetime_updated wins
---   * metadata       → per-field via metadata_bridge.merge
---   * render_settings → whole-block, newer datetime_updated wins
function ConflictResolver._pairwise_merge_states(state_a, state_b)
    local merged = ConflictResolver._empty_state()

    -- schema_version: take the higher one (loud-fail if we ever bump
    -- the schema in a way that older files can't read, but for now
    -- they're all v1).
    merged.schema_version = math.max(
        state_a.schema_version or 1, state_b.schema_version or 1)

    -- Annotations: per-key, pick newer datetime_updated.
    merged.annotations = ConflictResolver._merge_annotation_maps(
        state_a.annotations, state_b.annotations)

    -- Metadata: field-by-field merge (handled by the bridge module
    -- so the same logic is shared with normal sync).
    merged.metadata = MetadataBridge.merge(
        state_a.metadata, state_b.metadata)

    -- Render settings: per-field, newer datetime_updated wins — the same
    -- centralized merge the orchestrator and cloud use (no divergence).
    merged.render_settings = RenderSettingsBridge.merge(
        state_a.render_settings, state_b.render_settings)

    return merged
end


--- Merge two annotation maps, picking the newer version of each key.
---
--- Identical to merge._pick_newer_of_two semantics, but done inline
--- so we don't depend on a `_`-prefixed internal function from another
--- module.  Same tie-break rule: equal timestamps prefer the
--- tombstone (deletion happens-after creation by causality).
function ConflictResolver._merge_annotation_maps(map_a, map_b)
    map_a = map_a or {}
    map_b = map_b or {}
    local merged = {}

    for key, entry in pairs(map_a) do
        merged[key] = entry
    end
    for key, entry_b in pairs(map_b) do
        local entry_a = merged[key]
        if entry_a == nil then
            merged[key] = entry_b
        else
            merged[key] = ConflictResolver._pick_newer_annotation(entry_a, entry_b)
        end
    end
    return merged
end


function ConflictResolver._pick_newer_annotation(entry_a, entry_b)
    local ts_a = (entry_a and (entry_a.datetime_updated or entry_a.datetime)) or ""
    local ts_b = (entry_b and (entry_b.datetime_updated or entry_b.datetime)) or ""

    if ts_a == ts_b then
        -- Tombstones win ties (deletion happens-after creation).
        local a_tomb = entry_a and entry_a.deleted == true
        local b_tomb = entry_b and entry_b.deleted == true
        if a_tomb and not b_tomb then return entry_a end
        if b_tomb and not a_tomb then return entry_b end
        -- Both same kind, same datetime: device-id tiebreak so
        -- _pick_newer_annotation(a,b) == _pick_newer_annotation(b,a).  Conflict
        -- resolution walks sidecar conflict files whose argument order is not a
        -- stable local-vs-remote, so the old `return entry_b` could keep
        -- different entries on different devices.  Mirrors the annotation merge
        -- (_pick_newer_of_two) and MetadataBridge._metadata_tiebreak.
        local id_a = (entry_a and entry_a.device_id) or ""
        local id_b = (entry_b and entry_b.device_id) or ""
        if id_a ~= id_b then
            return (id_a > id_b) and entry_a or entry_b
        end
        return entry_b -- same device_id => identical entry, order irrelevant
    end

    if ts_a > ts_b then return entry_a end
    return entry_b
end


-- ----------------------------------------------------------------------------
-- Internal: state shape helpers
-- ----------------------------------------------------------------------------


function ConflictResolver._empty_state()
    return {
        schema_version  = 1,
        annotations     = {},
        metadata        = {},
        render_settings = {},
    }
end


--- In-place: make sure a state table has all three sub-sections.
---
--- Conflict files written by older Syncery versions might be missing
--- entire sections.  Treating them as empty preserves data on the
--- other side rather than crashing.
function ConflictResolver._normalize_state(state)
    if type(state.annotations) ~= "table" then state.annotations = {} end
    if type(state.metadata) ~= "table" then state.metadata = {} end
    if type(state.render_settings) ~= "table" then state.render_settings = {} end
end


--- Escape Lua-pattern magic characters in a literal string.
---
--- Filenames legitimately contain dots, dashes, brackets, etc.  We
--- need to neutralize all of them before splicing into a pattern.
function ConflictResolver._escape_lua_pattern(literal)
    return (literal:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
end


return ConflictResolver
