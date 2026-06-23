-- =============================================================================
-- syncery_progress/sync_orchestrator.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- This is the top-level conductor of the progress subsystem.  Every
-- other module in `syncery_progress/` is a building block; this is
-- the one that calls them in the right order to produce a complete
-- sync.
--
-- One public function (`sync_book`) does the whole thing:
--
--   1. Resolve any Syncthing conflict files so we work with a single
--      coherent "remote" view of the progress file.
--   2. Read three views:
--        - LOCAL  : KOReader's live reading position (from the bridge).
--        - REMOTE : the shared JSON file (other devices' entries +
--                   our own from the last save).
--        - LAST-SYNC: this device's private ancestor file.
--   3. Refuse to sync if the local entry would be a "wipe" of our
--      previously-saved progress (the failsafe — see below).
--   4. Stamp our local entry with a fresh (revision, timestamp).
--   5. Run the 3-way merge against remote + last-sync; produce the
--      merged map.
--   6. Save the merged state to BOTH the shared file (other devices
--      see this device's contribution) AND the last-sync file
--      (so next sync has the right ancestor).
--
-- All errors are collected into a result table rather than thrown.
-- The caller decides what to do with them (log, surface to UI,
-- silently retry).
--
--
-- THE WIPE FAILSAFE
--
-- KOReader's live state isn't always reliable right after book open:
-- the document can report `page = 1, percent = 0` for a fraction of
-- a second before its real state loads.  If we sync during that
-- window, we'd push a "you're at the start of the book" entry over
-- a real "you're 60% through" entry, then propagate that to other
-- devices via Syncthing — losing the user's progress everywhere.
--
-- The failsafe:
--
--   If our PROPOSED local entry has percent=0 AND page<=1, AND
--   the existing remote entry for our device_id has a higher
--   percent or page, refuse the save.  The next sync attempt
--   (a few seconds later, after KOReader finishes loading) will
--   have the correct state and succeed.
--
-- This is the progress analogue of the annotation subsystem's
-- "local empty, remote full" failsafe.  `allow_wipe = true` overrides
-- (used by deliberate "reset progress" UI actions).
--
--
-- WHY ONE BIG FUNCTION (NOT SEVEN SMALL ENDPOINTS)
--
-- Same reasoning as in syncery_ann/sync_orchestrator.lua: the phases
-- are tightly ordered and share intermediate state.  Splitting them
-- would mean either passing a huge context object between calls or
-- duplicating read steps.
--
-- For testing, the orchestrator takes its dependencies as injected
-- "providers" so a test can hand it a fake KOReader, fake disk
-- modules, fake clock.  See `sync_book_with_providers` below.
--
--
-- ATOMICITY
--
-- No transactional guarantee across the two writes (shared, last-sync).
-- If the device dies between writes, we may end up with the shared
-- file updated but last-sync stale — which means the next sync will
-- treat the entry as "new from remote" and produce the same merge
-- result again.  Idempotent.  No data loss from a partial sync.
--
-- =============================================================================

local ProgressBridge    = require("syncery_progress/progress_bridge")
local StateStore        = require("syncery_progress/state_store")
local Merge             = require("syncery_progress/merge")
local ConflictResolver  = require("syncery_progress/conflict_resolver")
local logger            = require("logger")

local SyncOrchestrator = {}


-- ----------------------------------------------------------------------------
-- Result-building helper
-- ----------------------------------------------------------------------------


--- Create a fresh result table for a sync attempt.
---
--- All fields start neutral; the orchestrator fills them in as it
--- progresses.  If a phase fails the orchestrator stops and returns
--- the partial result — callers can read `result.error` to see what
--- went wrong, and `result.skipped` / `result.skipped_reason` to see
--- if the failsafe triggered.
local function new_result()
    return {
        ok                = false,
        error             = nil,
        skipped           = false,
        skipped_reason    = nil,

        -- Conflict-resolution stats.
        conflicts_found   = 0,
        conflicts_merged  = 0,

        -- What we ended up with.
        local_revision    = 0,     -- revision we stamped on our entry
        position_pushed   = false, -- did THIS sync write a NEW local position?
        merged_entry_count = 0,    -- how many device_ids are in the file now
        merged_state      = nil,
    }
end


-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------


--- Run a full progress sync for one book.
---
--- The `options` table:
---
---   * device_id           (string, required)
---   * device_label        (string|nil)  friendly name for this device
---   * sync_progress       (bool|nil)    master toggle; default true.
---                                       When false, we still resolve
---                                       conflicts and read remote (so
---                                       the file stays consistent),
---                                       but we don't push our entry.
---   * allow_wipe          (bool|nil)    override the wipe failsafe
---
--- @param ui table KOReader's ReaderUI for the currently-open book.
--- @param book_file string Absolute path to the book.
--- @param options table The options shown above.
--- @return table Result; see new_result() for the shape.
function SyncOrchestrator.sync_book(ui, book_file, options)
    return SyncOrchestrator.sync_book_with_providers(ui, book_file, options, nil)
end


--- Same as sync_book, but accepts injected providers for testing.
---
--- The `providers` table can override any of the dependency modules:
---   { state_store, progress_bridge, conflict_resolver, merge, clock }
---
--- A nil providers table (or any missing field) falls back to the
--- real modules.  The `clock` provider is a function returning the
--- current epoch seconds (defaults to os.time).
function SyncOrchestrator.sync_book_with_providers(ui, book_file, options, providers)
    options   = options or {}
    providers = providers or {}

    local Deps = {
        state_store       = providers.state_store       or StateStore,
        progress_bridge   = providers.progress_bridge   or ProgressBridge,
        conflict_resolver = providers.conflict_resolver or ConflictResolver,
        merge             = providers.merge             or Merge,
        clock             = providers.clock             or os.time,
    }

    local result = new_result()

    -- ── 0. Pre-flight checks ────────────────────────────────────────
    if not ui then
        result.error = "no_ui"
        return result
    end
    if not book_file or book_file == "" then
        result.error = "no_book_file"
        return result
    end
    if not options.device_id or options.device_id == "" then
        result.error = "no_device_id"
        return result
    end

    -- Master toggle: when off, we DO still process conflicts and
    -- normalize the file, but we don't push our entry.  Reading the
    -- file is harmless and keeps remote views consistent.
    local push_local = options.sync_progress ~= false

    -- ── 1. Resolve Syncthing conflict files (if any) ────────────────
    local n_seen, n_merged, conflict_err =
        Deps.conflict_resolver.resolve_all(book_file)
    result.conflicts_found  = n_seen
    result.conflicts_merged = n_merged
    if conflict_err then
        -- Not fatal — the main file may still be usable, we just
        -- weren't able to fold in the conflict.  Log and continue.
        logger.warn("Syncery progress orchestrator: conflict resolution issue: "
            .. conflict_err)
    end

    -- ── 2. Load the three views ─────────────────────────────────────
    local remote_state    = Deps.state_store.load_shared(book_file)
    local last_sync_state = Deps.state_store.load_last_sync(book_file)

    local proposed_local_entry = nil
    if push_local then
        proposed_local_entry = Deps.progress_bridge.read_from_live(
            ui, options.device_label)
        if proposed_local_entry then
            proposed_local_entry =
                Deps.progress_bridge.strip_metadata_fields(proposed_local_entry)
        end
    end

    -- ── 3. Wipe failsafe ────────────────────────────────────────────
    if push_local and proposed_local_entry and not options.allow_wipe then
        local existing_remote_entry = remote_state.entries[options.device_id]
        if SyncOrchestrator._would_wipe_own_progress(
                proposed_local_entry, existing_remote_entry) then
            result.skipped        = true
            result.skipped_reason = "wipe_failsafe"
            logger.info("Syncery progress orchestrator: sync skipped — "
                .. "live state looks like an unloaded document "
                .. "(percent=0, page<=1) while remote has real progress")
            return result
        end
    end

    -- ── 4. Build the local map: start from what remote has, then
    --       upsert our own entry on top (so other devices' cached
    --       entries don't get lost from our local view between syncs).
    --       This is the LOCAL view that goes into 3-way merge.
    -- ────────────────────────────────────────────────────────────────
    local local_map = SyncOrchestrator._shallow_copy_map(remote_state.entries)
    if push_local and proposed_local_entry then
        -- Capture our revision as remote currently sees it, BEFORE the upsert
        -- reassigns local_map.  upsert is idempotent: re-asserting the same
        -- position returns the map untouched (no bump); only an actual move
        -- (or a first write) stamps revision+1.  A strictly higher post-
        -- revision is therefore the honest "we wrote a NEW position" signal --
        -- "position changed" is NOT "wrote something".  Mirrors
        -- upsert's own previous_revision computation.
        local prev_entry = local_map[options.device_id]
        local prev_rev   = 0
        if prev_entry and type(prev_entry.revision) == "number" then
            prev_rev = prev_entry.revision
        end
        local_map = Deps.merge.upsert_local_entry(
            local_map,
            options.device_id,
            proposed_local_entry,
            Deps.clock())
        local stamped_entry = local_map[options.device_id]
        if stamped_entry then
            result.local_revision  = stamped_entry.revision or 0
            result.position_pushed = (stamped_entry.revision or 0) > prev_rev
        end
    end

    -- ── 5. The 3-way merge ──────────────────────────────────────────
    local merged_entries = Deps.merge.three_way(
        local_map,
        last_sync_state.entries,
        remote_state.entries)

    -- ── 6. Persist the merged state ─────────────────────────────────
    local final_state = {
        schema_version = 1,
        entries        = merged_entries,
    }

    local saved_shared = Deps.state_store.save_shared(book_file, final_state)
    if not saved_shared then
        result.error = "save_shared_failed"
        return result
    end

    -- last-sync = exact copy of what we just wrote to shared.  Next
    -- time we sync, this is the ancestor view for the 3-way merge.
    local saved_last_sync = Deps.state_store.save_last_sync(
        book_file, final_state)
    if not saved_last_sync then
        -- Not fatal: the shared file is written, the next sync will
        -- just have a stale last-sync.  Log and proceed.
        logger.warn("Syncery progress orchestrator: failed to save last-sync file")
    end

    result.merged_entry_count = SyncOrchestrator._count_keys(merged_entries)
    result.merged_state       = final_state
    result.ok                 = true
    return result
end


--- Compute what the local-side entry WOULD be, without actually syncing.
---
--- Exposed so callers can inspect "what would we push?" without
--- triggering any I/O beyond reading KOReader's live state.  Useful
--- for status badges and pre-flight UI.
---
--- @param ui table The ReaderUI.
--- @param options table The sync options (only device_label is read here).
--- @return table|nil The proposed entry, or nil if there's nothing to read.
function SyncOrchestrator.preview_local_entry(ui, options)
    options = options or {}
    local proposed = ProgressBridge.read_from_live(ui, options.device_label)
    if proposed then
        proposed = ProgressBridge.strip_metadata_fields(proposed)
    end
    return proposed
end


-- ----------------------------------------------------------------------------
-- Internal helpers
-- ----------------------------------------------------------------------------


--- "Would saving this entry destroy our previously-saved progress?"
---
--- The rule: if the proposed entry has percent=0 AND page<=1 (the
--- shape KOReader produces for a not-yet-loaded document), AND the
--- existing remote entry for this device_id has higher percent or
--- page, refuse.  This is the moral equivalent of the "fresh open
--- of a new device" failsafe in the annotations orchestrator.
function SyncOrchestrator._would_wipe_own_progress(
        proposed_local, existing_remote)
    if not existing_remote then return false end

    local proposed_percent = tonumber(proposed_local.percent) or 0
    local proposed_page    = tonumber(proposed_local.page)    or 0
    if proposed_percent > 0.001 or proposed_page > 1 then
        return false
    end

    local remote_percent = tonumber(existing_remote.percent) or 0
    local remote_page    = tonumber(existing_remote.page)    or 0
    if remote_percent > 0.001 or remote_page > 1 then
        return true
    end

    return false
end


function SyncOrchestrator._shallow_copy_map(map)
    local copy = {}
    for k, v in pairs(map or {}) do copy[k] = v end
    return copy
end


function SyncOrchestrator._count_keys(map)
    local n = 0
    for _ in pairs(map or {}) do n = n + 1 end
    return n
end


return SyncOrchestrator
