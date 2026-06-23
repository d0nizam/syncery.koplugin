-- =============================================================================
-- syncery_progress/state_store.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- It loads and saves the structured state for a book's reading
-- progress — the "syncery-progress.json" file (shared between devices) and
-- its private "progress.last-sync.json" companion.
--
-- Other modules in the progress subsystem call into this one to read
-- and write state.  This is the only place that knows about the
-- shape of the on-disk JSON.
--
--
-- THE FILE LAYOUT
--
-- The shared file ("syncery-progress.json" in hash mode) looks like:
--
--   {
--     "schema_version": 1,
--     "entries": {
--        "<device_a_id>": { revision, percent, page, total_pages,
--                           xpath, timestamp, label, file, ... },
--        "<device_b_id>": { ... },
--        ...
--     }
--   }
--
-- There is intentionally NO top-level device_id/device_label here.  The
-- "who last wrote" stamp is omitted so identical content from two
-- devices yields byte-identical files (no Syncthing churn) -- see
-- save_shared.  Per-device provenance lives inside each entry (`label`).
--
-- The last-sync file has the same shape, but represents "what was
-- in the shared file at the last successful sync" — and it lives in
-- Syncery's private state directory, never visible to Syncthing.
--
--
-- WHY ONE SECTION (`entries`), NOT THREE
--
-- Annotations had three sections (annotations / metadata /
-- render_settings) because three independently-evolving concerns
-- share the same on-disk file.  Progress has just one concern: the
-- reading-position-per-device map.  Keeping the wrapper structure
-- (`{ schema_version, entries }`) lets us add fields later without
-- another schema version bump.
--
-- =============================================================================

local JsonStore = require("syncery_ann/json_store")
local Paths     = require("syncery_progress/paths")
local logger    = require("logger")

local StateStore = {}

local CURRENT_SCHEMA_VERSION = 1


-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------


--- Load the shared state file for a book (the one that syncs).
---
--- Always returns a valid state table.  If the file doesn't exist,
--- can't be read, or has bad JSON, an empty-but-well-formed state
--- is returned so callers don't need to nil-check.
---
--- @param book_path string Absolute path to the book file.
--- @return table The state table (with an `entries` sub-map).
--- @return string A diagnostic code from json_store.read.
function StateStore.load_shared(book_path)
    -- Derive the read path from book_path + current storage mode, then
    -- delegate.  Callers that ALREADY know the exact shared file (e.g. the
    -- Progress Browser, which carries each book's scanned progress_path)
    -- should call load_shared_from_path directly: re-deriving from book_path
    -- is unreliable for a book stored in a DIFFERENT KOReader metadata mode
    -- than the current one, or with no book_path at all (content-hash
    -- storage records none) -- the reconstructed path then misses the real
    -- file.
    return StateStore.load_shared_from_path(
        Paths.shared_progress_path_for_read(book_path))
end

--- Load shared progress state from an EXPLICIT file path (no derivation).
--- Same empty-on-failure contract as load_shared.
---
--- @param file_path string|nil Absolute path to the shared progress file.
--- @return table The state table (with an `entries` sub-map).
--- @return string A diagnostic code from json_store.read.
function StateStore.load_shared_from_path(file_path)
    if not file_path then
        return StateStore._build_empty_state(), "no_path"
    end

    local loaded, diag = JsonStore.read(file_path)

    if loaded then
        return StateStore._validate_and_repair(loaded), diag
    end

    -- Diagnostic codes we treat as "this is fine, return empty":
    --   not_found, empty
    -- All others should be logged but still return empty so the
    -- caller can proceed (better to give the user a fresh start
    -- than to crash on a bad file).
    if diag ~= "not_found" and diag ~= "empty" then
        logger.warn("Syncery progress state_store: failed to load shared file "
            .. tostring(file_path) .. " — " .. tostring(diag))
    end
    return StateStore._build_empty_state(), diag
end


--- Load the last-sync state file (the 3-way merge ancestor).
---
--- Like `load_shared`, but reads from the private last-sync location.
--- Returns an empty state when no last-sync exists yet — that's the
--- normal case on the very first sync of a book on this device.
---
--- @param book_path string Absolute path to the book file.
--- @return table The state table.
--- @return string A diagnostic code.
function StateStore.load_last_sync(book_path)
    local file_path = Paths.last_sync_progress_path(book_path)
    if not file_path then
        return StateStore._build_empty_state(), "no_path"
    end

    local loaded, diag = JsonStore.read(file_path)

    if loaded then
        return StateStore._validate_and_repair(loaded), diag
    end
    return StateStore._build_empty_state(), diag
end


--- Save the shared state file (overwriting whatever was there).
---
--- Writes are atomic — either the new state is fully written, or the
--- previous file is left untouched.
---
--- The state table is stamped with the current schema version.  The
--- top-level "who last wrote" device stamp is intentionally NOT
--- recorded (mirroring save_last_sync): stamping it would make two
--- devices that hold identical content emit byte-different files --
--- Syncthing churn.  Per-device provenance is kept inside the entries
--- map (each entry's `label`), so nothing displayed depends on it.
---
--- @param book_path string Absolute path to the book file.
--- @param state_table table The state to save (must have `entries`).
--- @return boolean True on success, false otherwise.
function StateStore.save_shared(book_path, state_table)
    local file_path = Paths.shared_progress_path(book_path)
    if not file_path then return false end

    -- Write the shared file device-agnostic ON PURPOSE: the top-level
    -- "who last wrote" stamp is intentionally NOT recorded.  Stamping it
    -- would make two devices that hold identical content emit byte-
    -- different files (each writes its own id) -- Syncthing churn and
    -- spurious sync-conflict copies.  Pass nil/nil, MIRRORING
    -- save_last_sync, so the shared file and its last-sync companion go
    -- through the same device-agnostic path and identical content yields
    -- identical bytes.  Per-device provenance is preserved inside the
    -- entries map: each entry keeps its owner's `label` (the status
    -- panel reads entry.label), so nothing displayed depends on this
    -- top-level stamp.
    state_table = StateStore._normalize_for_save(state_table, nil, nil)
    local ok, _ = JsonStore.write(file_path, state_table)
    return ok
end


--- Save the last-sync state file.
---
--- This file is private to the current device.  It captures "what
--- the shared state looked like the last time we successfully
--- synced" for use as the 3-way merge ancestor.
---
--- @param book_path string Absolute path to the book file.
--- @param state_table table The state to save.
--- @return boolean True on success.
function StateStore.save_last_sync(book_path, state_table)
    local file_path = Paths.last_sync_progress_path(book_path)
    if not file_path then return false end

    state_table = StateStore._normalize_for_save(state_table, nil, nil)
    local ok, _ = JsonStore.write(file_path, state_table)
    return ok
end


-- ----------------------------------------------------------------------------
-- Schema helpers
-- ----------------------------------------------------------------------------


--- Build an empty-but-well-formed state table.
---
--- `entries` is an empty table (not nil) so callers can iterate
--- with pairs() without nil-checking.
function StateStore._build_empty_state()
    return {
        schema_version = CURRENT_SCHEMA_VERSION,
        device_id      = nil,
        device_label   = nil,
        entries        = {},
    }
end


--- Normalize a freshly-decoded JSON table into the new shape.
---
--- Public so callers that load progress JSON via their own path (for
--- example `syncery_booklist`, which scans many files outside the
--- active book's storage-mode plumbing) can route their reads through
--- the same shape detection without reaching into private API.
---
--- A top-level `entries` map is the only shape the save path writes:
--- ensure schema_version is present and return it.  Any other input is
--- unrecognized (no producer makes it) and yields an empty state.
---
--- @param loaded_state table A table that came from JSON decode.
--- @return table A state guaranteed to have `entries`.
function StateStore.normalize(loaded_state)
    if not loaded_state then
        return StateStore._build_empty_state()
    end

    -- New shape: already has `entries`.
    if type(loaded_state.entries) == "table" then
        loaded_state.schema_version = loaded_state.schema_version
                                   or CURRENT_SCHEMA_VERSION
        return loaded_state
    end

    -- No `entries` wrapper: unrecognized (the save path only ever writes
    -- the wrapper).  Return an empty state rather than guess.
    return StateStore._build_empty_state()
end


-- Backward-compatible alias.  Internal callers used `_validate_and_repair`
-- before this function was promoted to the public API; keep the alias so
-- nothing downstream breaks.  New code should call `normalize` directly.
StateStore._validate_and_repair = StateStore.normalize


--- Stamp device + schema info onto a state table before writing.
function StateStore._normalize_for_save(state_table, device_id, device_label)
    state_table.schema_version = CURRENT_SCHEMA_VERSION
    if device_id    then state_table.device_id    = device_id end
    if device_label then state_table.device_label = device_label end

    state_table.entries = state_table.entries or {}
    if type(state_table.entries) ~= "table" then
        state_table.entries = {}
    end
    return state_table
end


--- Collect the OTHER devices present in a per-device entries map.
---
--- A book read on several devices stores one progress entry per device under
--- `.entries`, each carrying that device's `label`.  This returns the devices
--- OTHER than `local_id`, so a caller (e.g. the migration report) can tell the
--- user which of their other devices also hold Syncery data — without scanning
--- anything extra, since the entries are already loaded.
---
--- @param entries table|nil  A normalized `.entries` map ({ [device_id] = entry }).
--- @param local_id string|nil  This device's id; its own entry is excluded.
--- @return table  { [device_id] = display_name } for every device other than
---   `local_id`.  display_name is the entry's `label` when present and
---   non-empty, else the device_id itself (so each foreign device stays
---   uniquely identifiable, and two unlabelled devices never collapse to one).
---   Empty table when there are no foreign devices.
function StateStore.collect_foreign_devices(entries, local_id)
    local out = {}
    if type(entries) ~= "table" then
        return out
    end
    for id, entry in pairs(entries) do
        if type(id) == "string" and id ~= local_id and type(entry) == "table" then
            local label = entry.label
            if type(label) ~= "string" or label == "" then
                label = id
            end
            out[id] = label
        end
    end
    return out
end


return StateStore
