-- =============================================================================
-- syncery_storage_mode.lua
-- =============================================================================
--
-- The single source of truth for Syncery's storage mode.
--
-- Storage mode is a plugin-wide concept: "sdr" means JSON files live
-- next to the book inside KOReader's `.sdr` sidecar directory; "hash"
-- means they live under Syncery's own state root, keyed by the book's
-- partial-MD5 hash.  Choosing one or the other is a per-installation
-- decision, not a per-subsystem decision: the annotations and progress
-- subsystems either both use sidecars or both use the hash root.
--
-- WHY THIS MODULE EXISTS
--
-- Previously both `syncery_ann/paths.lua` and `syncery_progress/paths.lua`
-- kept their own module-level `current_storage_mode` variable.  Both
-- were always set together by main.lua at every transition point (three
-- places).  The "independence" was implementation accident, not intent —
-- the comment in `syncery_progress/paths.lua` admits it:
--
--     "We keep our own copy of the value rather than reading from
--      AnnPaths.get_storage_mode() on every call. […]  main.lua
--      sets both with adjacent calls."
--
-- That's a coordination bug pretending to be a feature.  The first
-- time someone forgets to update one of the three call sites in
-- main.lua, the two subsystems drift and the user's annotations end
-- up in `.sdr/` while their progress ends up under the hash root —
-- a corruption that only manifests on the next sync, far from where
-- the bug was introduced.
--
-- Centralizing the value here means:
--   • One setter.  Setting it is one call, not two.
--   • One getter.  Subsystems read from the same place — drift becomes
--     impossible by construction.
--   • Listeners.  Subsystems that need to react to mode changes
--     (cache invalidation, etc.) register a callback once.
--
-- This module is the same architectural pattern as the transport
-- orchestrator, applied at a smaller scale: centralized policy
-- (the mode value lives here), decentralized execution (each paths
-- module still builds its own paths, just from a shared input).
--
--
-- BACKWARD COMPATIBILITY
--
-- `syncery_ann/paths.lua` and `syncery_progress/paths.lua` both still
-- export `set_storage_mode(mode)` and `get_storage_mode()` — they
-- delegate here.  Callers (main.lua, tests) keep working without
-- changes.  We could remove those wrappers eventually, but not now.
--
-- =============================================================================


local StorageMode = {}


-- ----------------------------------------------------------------------------
-- Module-level state.  This IS module-level state, which is normally
-- a red flag in the rest of the codebase — but storage mode is a
-- process-wide singleton (one KOReader process = one storage mode),
-- so a module-level value is the honest shape.  Tests reset it via
-- `set` like any caller would.
-- ----------------------------------------------------------------------------


local current_mode      = "sdr"
local listeners         = {}


-- ----------------------------------------------------------------------------
-- Hash-root default.
--
-- When the user hasn't chosen a custom hash root, this is the answer:
-- KOReader's settings directory + "/syncery".  Resolving lazily (not
-- at module load) means tests don't
-- need DataStorage on the require path, and a user setting that maps
-- to "use default" reliably round-trips to the current default rather
-- than to the value at module-load time.
-- ----------------------------------------------------------------------------


local function default_hash_root()
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok or not DataStorage or type(DataStorage.getSettingsDir) ~= "function" then
        -- Test/headless environment: fall back to a relative path.
        return "./syncery"
    end
    return DataStorage:getSettingsDir() .. "/syncery"
end


-- ----------------------------------------------------------------------------
-- API.
-- ----------------------------------------------------------------------------


--- Valid modes.  Anything else falls back to "sdr" with no error —
--- matches the behaviour of the previous paths.lua functions, so we
--- don't regress on input handling that callers may have come to
--- depend on.
local VALID = { sdr = true, hash = true }


--- Read the currently active mode.
---@return "sdr"|"hash"
function StorageMode.get()
    return current_mode
end


--- Set the mode.  Invalid input falls back to "sdr".  Fires all
--- registered listeners with the new value if the mode actually
--- changed (no-change calls do NOT fire listeners — that's a deliberate
--- choice; subsystems can trust that being called means something
--- actually shifted).
---
---@param mode string  expected "sdr" or "hash"
function StorageMode.set(mode)
    local new_mode = VALID[mode] and mode or "sdr"
    if new_mode == current_mode then return end
    current_mode = new_mode
    for _, fn in ipairs(listeners) do
        -- pcall: a broken listener cannot prevent others from running
        -- or prevent the setter from completing.  This is the same
        -- "no listener can break the system" stance the orchestrator
        -- takes with its own callbacks.
        pcall(fn, new_mode)
    end
end


--- Register a listener.  Returns an unsubscribe function — callers
--- with a lifecycle (test setUp/tearDown, transient subsystems) should
--- save it and call it on teardown, otherwise the listener pile grows
--- across test runs.
---
---@param fn function(new_mode: string)
---@return function unsubscribe
function StorageMode.on_change(fn)
    assert(type(fn) == "function",
        "StorageMode.on_change: listener must be a function")
    table.insert(listeners, fn)
    return function()
        for i, candidate in ipairs(listeners) do
            if candidate == fn then table.remove(listeners, i); return end
        end
    end
end


--- Test helper: clear all registered listeners.  Production never
--- calls this — there is no "reset listeners" use case at runtime.
--- Tests call it between cases so listener accumulation from previous
--- cases doesn't pollute the next.
function StorageMode._reset_for_tests()
    listeners = {}
end


-- ----------------------------------------------------------------------------
-- Hash root directory.
--
-- This is the directory that hash-mode storage uses as its root —
-- per-book hash subdirectories live under it (`<hash_root>/synceryhash/<id>/`).
-- It is ALSO the root of the "last-sync" tree (which exists in both
-- modes; last-sync is always private and device-local).
--
-- The hash root is FIXED at `<koreader_settings>/syncery`. It used to be
-- user-relocatable (set_hash_root) so the files could live under a
-- Syncthing-watched path for cross-device hash sync. That option was
-- removed: relocating the root was the single source of an entire class
-- of path bugs (writers/readers/erasers drifting between the moved root
-- and the default), and it bought nothing that the simpler approach
-- doesn't give — to sync hash-mode data across devices, point Syncthing
-- at the `synceryhash/` subdirectory (`<koreader_settings>/syncery/synceryhash/`)
-- directly. `synceryhash/` already contains exactly the replicable per-book
-- files and nothing else; `last_sync/` is a sibling, so it stays private
-- and out of the sync automatically. Fixing the root means
-- `get_hash_root()` is always the default, so every path resolves the
-- same way everywhere — no drift possible.
-- ----------------------------------------------------------------------------


--- Get the hash-root directory (the place per-book hash subdirectories
--- live).  Always the default `<settings>/syncery` — the root is not
--- user-relocatable (see the note above).
---@return string  absolute path, no trailing slash
function StorageMode.get_hash_root()
    return default_hash_root()
end


return StorageMode
