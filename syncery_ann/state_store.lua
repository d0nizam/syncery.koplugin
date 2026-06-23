-- =============================================================================
-- syncery_ann/state_store.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- It loads and saves the structured state for a book — the
-- "syncery-annotations.json" file (which actually holds three sections:
-- annotations, book-level metadata, and render settings) and its
-- private "annotations.last-sync.json" companion.
--
-- Other modules in the annotation subsystem call into this one to
-- read and write state.  This is the only place that knows about the
-- shape of the on-disk JSON.  If we ever change the schema, this
-- file is where the migration happens.
--
--
-- THE FILE LAYOUT
--
-- The shared file ("syncery-annotations.json" in hash mode) looks like:
--
--   {
--     "schema_version": 1,
--     "device_id":      "the device that last wrote",
--     "device_label":   "Phone",
--     "annotations":      { <key> -> <annotation>, ... },
--     "metadata":         { status, rating, collections, ... },
--     "render_settings":  { "copt_font_size": {value, datetime_updated}, ... }
--   }
--
-- The last-sync file has the same shape, but it represents what was
-- in the shared file at the time of the last successful sync — and
-- it lives in Syncery's private state directory, never visible to
-- Syncthing or cloud sync.
--
--
-- WHY THREE SECTIONS, NOT THREE FILES
--
-- Annotations, metadata, and render_settings all change at human
-- speed (when you highlight something, when you change a rating).
-- Putting them in one file means one disk write per save instead of
-- three.  Each section has its own datetime_updated for merge
-- purposes, so they remain conceptually independent — just sharing
-- a physical file.
--
-- =============================================================================

local JsonStore = require("syncery_ann/json_store")
local Paths     = require("syncery_ann/paths")
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
--- @return table The state table (annotations / metadata / render_settings).
--- @return string A diagnostic code from json_store.read.
function StateStore.load_shared(book_path)
    -- Derive the read path from book_path + current storage mode, then
    -- delegate.  Callers that ALREADY know the exact shared file (e.g. the
    -- annotation browser, which carries each book's scanned annotations_path)
    -- should call load_shared_from_path directly: re-deriving from book_path
    -- is unreliable for a book stored in a DIFFERENT KOReader metadata mode
    -- than the current one, or recorded with a foreign-device / extension-less
    -- path -- the reconstructed sidecar path then misses the real file.
    return StateStore.load_shared_from_path(
        Paths.shared_annotations_path_for_read(book_path))
end

--- Load shared state from an EXPLICIT file path (no derivation).  Same
--- empty-on-failure contract as load_shared.
---
--- @param file_path string|nil Absolute path to the shared annotations file.
--- @return table The state table (annotations / metadata / render_settings).
--- @return string A diagnostic code from json_store.read.
function StateStore.load_shared_from_path(file_path)
    if not file_path then
        return StateStore._build_empty_state(), "no_path"
    end

    local loaded, diag = JsonStore.read(file_path)

    if loaded then
        return StateStore._validate_and_repair(loaded), diag
    end

    -- Diagnostic codes we treat as "this is fine, return empty state":
    --   not_found, empty
    -- All others should be logged but still return empty (we'd rather
    -- give the user a fresh start than refuse to load).
    if diag ~= "not_found" and diag ~= "empty" then
        logger.warn("Syncery state_store: failed to load shared file "
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
    local file_path = Paths.last_sync_annotations_path(book_path)
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
--- Syncthing churn.  Provenance lives in per-annotation `device_id`
--- (winner-based) and the device-local sync journal, so nothing
--- displayed depends on this top-level stamp.
---
--- @param book_path string Absolute path to the book file.
--- @param state_table table The state to save.
--- @return boolean True on success, false otherwise.
function StateStore.save_shared(book_path, state_table)
    local file_path = Paths.shared_annotations_path(book_path)
    if not file_path then return false end

    -- Write the shared file device-agnostic ON PURPOSE: the top-level
    -- "who last wrote" stamp is intentionally NOT recorded.  Stamping it
    -- would make two devices that hold identical content emit byte-
    -- different files (each writes its own id) -- Syncthing churn and
    -- spurious sync-conflict copies.  Pass nil/nil, MIRRORING
    -- save_last_sync, so identical content yields identical bytes.
    -- Provenance is preserved elsewhere: per-annotation `device_id`
    -- (winner-based, survives the merge) attributes each annotation, and
    -- the device-local sync journal records which device RAN each sync
    -- (sourced from the live device, not this file -- see
    -- sync_journal.record_merge).
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
    local file_path = Paths.last_sync_annotations_path(book_path)
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
--- All sub-sections are empty tables (not nil), which lets callers
--- iterate over them with pairs() without nil-checking.
function StateStore._build_empty_state()
    return {
        schema_version  = CURRENT_SCHEMA_VERSION,
        device_id       = nil,
        device_label    = nil,
        annotations     = {},
        metadata        = {},
        render_settings = {},
    }
end


--- Make sure a loaded state has all expected sub-sections.
---
--- A file written by an older version of Syncery might be missing the
--- metadata or render_settings sections; add empty sections where needed
--- so callers always see schema_version + the three section tables.
---
--- @param loaded_state table A table that came from JSON decode.
--- @return table A state guaranteed to have schema_version + 3 sections.
function StateStore._validate_and_repair(loaded_state)
    -- schema_version
    loaded_state.schema_version = loaded_state.schema_version or CURRENT_SCHEMA_VERSION

    -- annotations: must be a map.  Reset a non-table to an empty map.
    if type(loaded_state.annotations) ~= "table" then
        loaded_state.annotations = {}
    end

    loaded_state.metadata        = loaded_state.metadata        or {}
    loaded_state.render_settings = loaded_state.render_settings or {}

    if type(loaded_state.metadata)        ~= "table" then loaded_state.metadata        = {} end
    if type(loaded_state.render_settings) ~= "table" then loaded_state.render_settings = {} end

    return loaded_state
end


--- Stamp device + schema info onto a state table before writing.
function StateStore._normalize_for_save(state_table, device_id, device_label)
    state_table.schema_version  = CURRENT_SCHEMA_VERSION
    if device_id    then state_table.device_id    = device_id end
    if device_label then state_table.device_label = device_label end

    state_table.annotations     = state_table.annotations     or {}
    state_table.metadata        = state_table.metadata        or {}
    state_table.render_settings = state_table.render_settings or {}
    return state_table
end


return StateStore
