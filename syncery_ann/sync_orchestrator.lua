-- =============================================================================
-- syncery_ann/sync_orchestrator.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- This is the top-level conductor of the annotation subsystem.  Every
-- other module in `syncery_ann/` is a building block; this is the one
-- that calls them in the right order to produce a complete sync.
--
-- One public function (`sync_book`) does the whole thing:
--
--   1. Resolve any Syncthing conflict files so we work with a single
--      coherent "remote" view.
--   2. Read three views: LOCAL (KOReader's doc_settings), REMOTE (the
--      shared JSON), LAST-SYNC (this device's private ancestor file).
--   3. Refuse to sync if local is empty and remote is full — the
--      "wipe failsafe" that prevents a fresh-open device from
--      destroying everyone else's annotations.
--   4. Run the 3-way merge on annotations, the field-by-field merge
--      on metadata, and the whole-block merge on render settings.
--   5. Garbage-collect tombstones older than the configured TTL.
--   6. Push the merged state BACK into KOReader (so the user sees the
--      latest annotations from all devices) AND out to the shared file
--      (so other devices see this device's contributions).
--   7. Save the merged state as the new last-sync ancestor for next
--      time.
--
-- All errors are collected into a result table rather than thrown.
-- The caller can decide what to do with them (log, surface to UI,
-- silently retry).
--
--
-- WHY ONE BIG FUNCTION (NOT SEVEN SMALL ENDPOINTS)
--
-- The phases are tightly ordered and share a lot of intermediate
-- state (the merged map gets used three times: for KOReader, for the
-- shared file, for last-sync).  Splitting them would mean either
-- passing a huge context object between calls or duplicating the
-- read steps.  Both worse than the long-but-linear orchestrator.
--
-- For testing, the orchestrator takes its dependencies as injected
-- "providers" so a test can hand it a fake KOReader, fake disk
-- modules, fake clock.  See `sync_book_with_providers` at the bottom.
--
--
-- ATOMICITY
--
-- There is no transactional guarantee that all three writes (shared
-- JSON, last-sync JSON, KOReader doc_settings) happen together.  If
-- the device dies between writes, we may end up with the shared file
-- updated but last-sync stale — which means the next sync will treat
-- some already-merged remote annotations as "new from remote" again.
-- That's safe (idempotent merge gives the same result), just slightly
-- wasteful.  We never end up with DATA LOSS from a partial sync — at
-- worst we redo work.
--
-- =============================================================================

local DocSettingsBridge   = require("syncery_ann/doc_settings_bridge")
local MetadataBridge      = require("syncery_ann/metadata_bridge")
local RenderSettingsBridge = require("syncery_ann/render_settings_bridge")
local StateStore          = require("syncery_ann/state_store")
local Merge               = require("syncery_ann/merge")
local Tombstones          = require("syncery_ann/tombstones")
local ConflictResolver    = require("syncery_ann/conflict_resolver")
local TimeFormat          = require("syncery_ann/time_format")
local logger              = require("logger")

local SyncOrchestrator = {}


-- ----------------------------------------------------------------------------
-- Result-building helpers
-- ----------------------------------------------------------------------------


--- Create a fresh result table for a sync attempt.
---
--- All fields start neutral; the orchestrator fills them in as it
--- progresses.  If a phase fails the orchestrator stops and returns
--- the partial result — callers can read `result.error` to see what
--- went wrong.
local function new_result()
    return {
        ok                  = false,
        error               = nil,
        skipped             = false,
        skipped_reason      = nil,

        -- Conflict-resolution stats.
        conflicts_found     = 0,
        conflicts_merged    = 0,

        -- Annotation stats.
        annotations_before  = 0,
        annotations_after   = 0,
        tombstones_compacted = 0,
        annotations_pulled  = 0,   -- new from remote
        annotations_pushed  = 0,   -- new from local

        -- Metadata stats.
        metadata_applied    = {},  -- map of field-name -> true

        -- Render-settings stats.
        render_applied      = false,

        -- The merged state (for callers that want to inspect it).
        merged_state        = nil,
    }
end


-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------


--- Run a full sync for one book.
---
--- The `options` table controls behavior:
---
---   * device_id           (string, required)
---   * device_label        (string|nil)
---   * toggles             (table)  per-section enable flags
---     {
---       annotations        = bool (master),
---       highlights         = bool,
---       notes              = bool,
---       bookmarks          = bool,
---       metadata           = bool (master),
---       status             = bool,
---       rating             = bool,
---       collections        = bool,
---       summary            = bool,
---       custom             = bool,
---       handmade           = bool,
---       render_settings    = bool (default false),
---     }
---   * adapt_highlight_style (bool)  strip color/drawer on write to KOReader
---   * tombstone_ttl_days   (number)  default 30
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
---   { state_store, doc_settings_bridge, metadata_bridge,
---     render_settings_bridge, conflict_resolver, time_format,
---     merge, tombstones }
---
--- A nil providers table (or any missing field) falls back to the
--- real modules.  This is the seam used by unit tests.
function SyncOrchestrator.sync_book_with_providers(ui, book_file, options, providers)
    options   = options or {}
    providers = providers or {}

    local Deps = {
        state_store            = providers.state_store            or StateStore,
        doc_settings_bridge    = providers.doc_settings_bridge    or DocSettingsBridge,
        metadata_bridge        = providers.metadata_bridge        or MetadataBridge,
        render_settings_bridge = providers.render_settings_bridge or RenderSettingsBridge,
        conflict_resolver      = providers.conflict_resolver      or ConflictResolver,
        time_format            = providers.time_format            or TimeFormat,
        merge                  = providers.merge                  or Merge,
        tombstones             = providers.tombstones             or Tombstones,
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

    local toggles = options.toggles or {}

    -- ── 1. Resolve Syncthing conflict files (if any) ────────────────
    local n_seen, n_merged, conflict_err = Deps.conflict_resolver.resolve_all(book_file)
    result.conflicts_found  = n_seen
    result.conflicts_merged = n_merged
    if conflict_err then
        -- Don't abort — the main file may still be usable, we just
        -- weren't able to fold in the conflict.  Log and continue.
        logger.warn("Syncery orchestrator: conflict resolution issue: " .. conflict_err)
    end

    -- ── 2. Load the three views ─────────────────────────────────────
    local remote_state    = Deps.state_store.load_shared(book_file)
    local last_sync_state = Deps.state_store.load_last_sync(book_file)

    -- last_sync is loaded BEFORE the local view so the status field can classify
    -- its generation against the last-synced ancestor.
    local local_state = SyncOrchestrator._build_local_state(
        ui, book_file, options, toggles, Deps,
        last_sync_state and last_sync_state.metadata)

    result.annotations_before = SyncOrchestrator._count_alive(local_state.annotations)


    -- ── 4. Merge the three sections ─────────────────────────────────
    local annotations_enabled =
        SyncOrchestrator._annotations_enabled(toggles)

    -- Per-type filtering: keys whose type has its sub-toggle off are kept OUT
    -- of the merge entirely (never in the prepped local or ancestor), so the
    -- deletion detector cannot tombstone them; remote's own such entries still
    -- flow in via three_way's remote-only adoption (the shared file preserves
    -- them).  The device's OWN out-of-scope entries are re-overlaid onto the
    -- delivery map (below the merge) so they survive locally.  out_keys is empty
    -- in the annotations-off branch, leaving that path byte-for-byte unchanged.
    local disabled_types = SyncOrchestrator._disabled_types(toggles)
    local out_keys = {}

    local merged_annotations
    if annotations_enabled then
        out_keys = Deps.merge._out_scope_keys(
            local_state.annotations,
            last_sync_state.annotations,
            remote_state.annotations,
            disabled_types)

        merged_annotations = Deps.merge.three_way(
            SyncOrchestrator._without_keys(local_state.annotations, out_keys),
            SyncOrchestrator._without_keys(last_sync_state.annotations, out_keys),
            remote_state.annotations)

        -- Adapted-style de-leak.  When this device restyles foreign
        -- highlights for display (adapt_highlight_style), its sidecar holds
        -- the adapt output (color=nil, drawer=device default).  An EDIT to
        -- such an annotation makes the local side win the merge, so that
        -- display artifact would be pushed into the shared file, overwriting
        -- the author's original style for everyone.  Restore the original
        -- (from the remote) for fields that still match the adapt output; a
        -- deliberate user restyle differs and is kept.  Gated on the LOCAL
        -- adapt flag and LOCAL device default -- only the local sidecar is
        -- ever adapted, and the shared (remote) always holds the original.
        Deps.merge._strip_adapted_style_leak(
            merged_annotations,
            remote_state.annotations,
            {
                adapt_highlight_style = options.adapt_highlight_style,
                local_device_id       = options.device_id,
                default_drawer        =
                    DocSettingsBridge._device_default_drawer(ui),
            })
    else
        -- Annotation sync off: keep whatever the remote file had, so
        -- other devices' annotations are still preserved in the JSON
        -- (we just won't push our own or apply theirs).
        merged_annotations = SyncOrchestrator._shallow_copy_map(
            remote_state.annotations)
    end

    -- Count what came in from each side BEFORE we GC tombstones (which
    -- could mask "new from remote" entries that were already dead).  The pulled
    -- count excludes out_keys: remote's disabled-type entries ride in the shared
    -- file but are never delivered to this device, so they are not "pulled".
    -- (out_keys is empty unless per-type filtering dropped some.)
    result.annotations_pulled = SyncOrchestrator._count_added_vs(
        merged_annotations, local_state.annotations, out_keys)
    result.annotations_pushed = SyncOrchestrator._count_added_vs(
        merged_annotations, remote_state.annotations)

    -- ── 5. Compact old tombstones ───────────────────────────────────
    -- Tombstones older than the TTL get stripped to their minimal form
    -- (deleted + datetime_updated + device id/label).  The marker is
    -- NEVER dropped — see syncery_ann/tombstones.lua for the rationale.
    local ttl = options.tombstone_ttl_days or 30
    local gc_map, n_compacted = Deps.tombstones.collect_garbage(merged_annotations, ttl)
    merged_annotations = gc_map
    result.tombstones_compacted = n_compacted

    -- ── 6. Merge metadata and render settings ───────────────────────
    -- Metadata uses a 3-way merge against the last-synced ancestor
    -- (last_sync_state.metadata, written at the end of every sync below) so
    -- the winner is decided by WHO changed a field, not by collect order.
    -- last_sync_state.metadata is {} on the first sync -> three_way treats
    -- an absent ancestor field as "both sides are new" and falls to its
    -- deterministic tiebreak.
    local merged_metadata = Deps.metadata_bridge.three_way(
        local_state.metadata, remote_state.metadata, last_sync_state.metadata)

    local merged_render = Deps.render_settings_bridge.merge(
        local_state.render_settings, remote_state.render_settings)

    -- ── 7. NOT applied in-session ───────────────────────────────────
    -- Merged annotations are deliberately NOT applied to the live document
    -- mid-session.  Do NOT re-add an in-session apply: writing doc_settings
    -- mid-session (a) gets clobbered by KOReader's own onSaveSettings at
    -- close (so it never reaches the next open anyway), (b) broadcasts
    -- AnnotationsModified -> re-enters checkRemote -> a double merge every
    -- tick, and (c) for paging books writes a suffix key KOReader never
    -- reads as primary (PDF-staleness).  Delivery happens at close instead:
    -- the merged map is written to the base "annotations" key in
    -- Syncery:onSaveSettings, so KOReader's next-open onReadSettings loads
    -- it into the live list.  The live list is never mutated mid-session.

    local _meta_changed, applied_fields = Deps.metadata_bridge.apply_from_remote(
        ui, book_file, merged_metadata,
        SyncOrchestrator._compose_metadata_toggles(toggles))
    result.metadata_applied = applied_fields

    if toggles.render_settings then
        result.render_applied = Deps.render_settings_bridge.apply_from_remote(
            ui, merged_render,
            SyncOrchestrator._compose_render_toggles(toggles))
    end

    -- ── 8. Persist the merged state ─────────────────────────────────
    local final_state = {
        schema_version  = 1,
        annotations     = merged_annotations,
        metadata        = merged_metadata,
        render_settings = merged_render or {},
    }

    -- Nothing to persist: a merge that produced no annotations, no metadata
    -- and no render settings would otherwise write an empty
    -- syncery-annotations.json -- the first save of a fresh book with
    -- annotations on but none made yet, or a book whose only enabled master
    -- is annotations with every sub-toggle off.  A merged-empty state implies
    -- the remote was empty too (the merge keeps remote keys verbatim, so a
    -- non-empty remote could never reduce to empty), so there is no existing
    -- file being preserved -- skipping the write simply leaves no file, the
    -- correct representation of "no synced data".  This is the
    -- CALLER-INDEPENDENT gate: the _save / checkRemote master-toggle gates
    -- upstream are a cheap early-out, not the guarantee -- master-annotations
    -- ON with all sub-toggles OFF passes them yet lands here.  last_sync is
    -- skipped too: an empty ancestor is its own correct next-merge baseline.
    if SyncOrchestrator._is_empty_state(final_state) then
        result.ok             = true
        -- Self-describe via the standard skip convention so the journal
        -- classifies this as `skipped` with reason `empty` -- distinct
        -- from a genuine zero-movement noop, which otherwise looks
        -- identical in the log.
        result.skipped        = true
        result.skipped_reason = "empty"
        return result
    end

    local saved_shared = Deps.state_store.save_shared(book_file, final_state)
    if not saved_shared then
        result.error = "save_shared_failed"
        return result
    end

    -- last-sync = the ancestor view for the NEXT 3-way merge.  Its
    -- annotations are FILTERED (S3): un-materialized remote pulls are kept
    -- OUT of the ancestor so the next merge does not synthesize a phantom
    -- deletion for an annotation that has not yet reached this device's live
    -- list.  metadata/render_settings are not keyed-deletion-detected, so
    -- they stay as written.  See _materialized_last_sync_annotations.
    local last_sync_state = {
        schema_version  = 1,
        annotations     = SyncOrchestrator._materialized_last_sync_annotations(
                              merged_annotations, local_state.annotations),
        metadata        = merged_metadata,
        render_settings = merged_render or {},
    }
    local saved_last_sync = Deps.state_store.save_last_sync(book_file, last_sync_state)
    if not saved_last_sync then
        -- Not fatal: the shared file is written, the next sync will
        -- just have a stale last-sync.  Log and proceed.
        logger.warn("Syncery orchestrator: failed to save last-sync file")
    end

    result.annotations_after = SyncOrchestrator._count_alive(merged_annotations)

    -- Delivery map: what THIS device writes back to its own doc_settings.  It is
    -- the merged map MINUS the out-of-scope keys (remote's disabled-type entries
    -- stay in the shared file but are not applied here) PLUS this device's own
    -- out-of-scope entries (so e.g. a bookmarks-off device keeps its bookmarks
    -- locally).  When out_keys is empty this IS merged_annotations, so the
    -- annotations-off and all-types-on paths deliver exactly as before.  The
    -- teardown stashes this; the shared file already holds the full merged map.
    local delivery_annotations = merged_annotations
    if next(out_keys) ~= nil then
        delivery_annotations = {}
        for key, entry in pairs(merged_annotations) do
            if not out_keys[key] then delivery_annotations[key] = entry end
        end
        for key in pairs(out_keys) do
            local own = local_state.annotations[key]
            if own then delivery_annotations[key] = own end
        end
    end

    result.delivery_annotations = delivery_annotations
    result.merged_state      = final_state
    result.ok                = true
    return result
end


--- Compute what local_state would look like, without actually syncing.
---
--- Exposed so callers can inspect "what would we push?" without
--- triggering any I/O beyond reading KOReader's doc_settings.  Used
--- e.g. by the status badge to show a count of pending changes.
---
--- @param ui table The ReaderUI.
--- @param book_file string Absolute path to the book.
--- @param options table The sync options (see sync_book).
--- @return table {annotations, metadata, render_settings}.
function SyncOrchestrator.preview_local_state(ui, book_file, options)
    options = options or {}
    local toggles = options.toggles or {}
    return SyncOrchestrator._build_local_state(ui, book_file, options, toggles, {
        doc_settings_bridge    = DocSettingsBridge,
        metadata_bridge        = MetadataBridge,
        render_settings_bridge = RenderSettingsBridge,
    })
end


-- ----------------------------------------------------------------------------
-- Internal: build the LOCAL view from KOReader's live state
-- ----------------------------------------------------------------------------


function SyncOrchestrator._build_local_state(ui, book_file, options, toggles, Deps, ancestor_md)
    local annotations = {}
    local metadata    = {}
    local render      = {}

    if SyncOrchestrator._annotations_enabled(toggles) then
        annotations = Deps.doc_settings_bridge.read_annotations_as_map(ui)
        annotations = SyncOrchestrator._stamp_local_annotations(
            annotations, options.device_id, options.device_label)
    end

    if toggles.metadata ~= false then
        metadata = Deps.metadata_bridge.read_from_ui(
            ui, book_file,
            SyncOrchestrator._compose_metadata_toggles(toggles),
            options.device_id, options.device_label, ancestor_md)
    end

    if toggles.render_settings then
        render = Deps.render_settings_bridge.read_from_ui(
            ui, SyncOrchestrator._compose_render_toggles(toggles)) or {}
    end

    return {
        annotations     = annotations,
        metadata        = metadata,
        render_settings = render,
    }
end


--- Stamp each annotation with this device's identity.
---
--- We do this on the local map so that when an annotation pushes to
--- remote for the first time, it carries this device's id/label —
--- enabling the "see who made this highlight" UI later.  Annotations
--- that already have a non-empty device_id are left alone (they came
--- from some prior session or another device).
---
--- We don't touch datetime_updated here.  KOReader's own annotation
--- code sets it when the user creates/edits.  If KOReader didn't set
--- one, the bridge module assigns the empty string, which loses any
--- merge — that's the correct behavior for unknown-age entries.
function SyncOrchestrator._stamp_local_annotations(map, device_id, device_label)
    if not device_id then return map end
    for _, ann in pairs(map) do
        if not ann.device_id or ann.device_id == "" then
            ann.device_id    = device_id
            ann.device_label = device_label or ann.device_label
        end
    end
    return map
end


-- ----------------------------------------------------------------------------
-- Internal: misc helpers
-- ----------------------------------------------------------------------------


--- Whether annotation sync is on (any of the three sub-toggles).
---
--- The toggle set is `sync_annotations` (master), `sync_highlights`,
--- `sync_notes`, `sync_bookmarks`.  Master OFF means nothing syncs;
--- otherwise, at least one of the three needs to be on to make
--- annotation sync meaningful.
function SyncOrchestrator._annotations_enabled(toggles)
    if toggles.annotations == false then return false end

    -- If all three sub-toggles are explicitly false, treat as off.
    local any_sub_on = false
    for _, name in ipairs({"highlights", "notes", "bookmarks"}) do
        if toggles[name] ~= false then any_sub_on = true; break end
    end
    return any_sub_on
end


--- The set of annotation types whose sub-toggle is explicitly off.  Mirrors the
--- `== false` test in _annotations_enabled (a nil/absent toggle means ON).  Only
--- meaningful when _annotations_enabled is true (master on + >=1 sub on).
--- @return table set keyed by type name, e.g. { bookmark = true }
function SyncOrchestrator._disabled_types(toggles)
    local disabled = {}
    if toggles.highlights == false then disabled.highlight = true end
    if toggles.notes      == false then disabled.note      = true end
    if toggles.bookmarks  == false then disabled.bookmark  = true end
    return disabled
end


--- Return a copy of `map` without the keys in `keys`.  When `keys` is empty the
--- input is returned BY REFERENCE (no-op fast path) -- three_way never mutates
--- its inputs, so sharing is safe.
function SyncOrchestrator._without_keys(map, keys)
    if not map or next(keys) == nil then return map end
    local out = {}
    for k, v in pairs(map) do
        if not keys[k] then out[k] = v end
    end
    return out
end


--- True when a merged envelope has nothing worth persisting: no annotations,
--- no metadata, no render settings.  Used to skip the shared-file write
--- entirely (see sync_book step 8).  A map counts as empty when it is nil or
--- has no keys; tombstones are real keys, so a delete-everything merge still
--- writes (to propagate the tombstones) -- only a genuinely keyless state is
--- empty.
function SyncOrchestrator._is_empty_state(state)
    local function empty(t) return t == nil or next(t) == nil end
    return empty(state.annotations)
        and empty(state.metadata)
        and empty(state.render_settings)
end


--- "Would syncing now wipe a non-empty remote?"
---
--- Checks three signals: this device has zero alive annotations, the
--- remote file has at least one, AND last-sync is empty (this device has
--- never synced this book).  That combination is a fresh open of a book on
--- a new device, before sync populated doc_settings -- an ADOPT, not a wipe:
--- the 3-way merge adopts (never wipes) when last-sync is empty, and the
--- un-materialized pull is kept out of the ancestor so no phantom deletion
--- follows.  So this returns false (not a wipe) for that case; it reports a
--- wipe only for a genuine empty-over-full overwrite.


function SyncOrchestrator._count_alive(map)
    local n = 0
    for _, ann in pairs(map or {}) do
        if ann and not ann.deleted then n = n + 1 end
    end
    return n
end


--- Build the annotation map to write into the LAST-SYNC ancestor, filtered
--- so that an un-materialized remote pull never enters the ancestor.
---
--- WHY THIS EXISTS (the phantom-tombstone window):
--- The last-sync file is the ancestor the next 3-way merge diffs against.
--- `merge._detect_local_deletions` iterates the ancestor: a key present in
--- the ancestor but ABSENT from the live local list is read as "the user
--- deleted it" and tombstoned.  That is correct for a key the user actually
--- had locally.  But a freshly PULLED annotation (adopted into `merged` from
--- the remote, yet never materialized into this device's live list -- it
--- only reaches the live list at the NEXT book open, via the close-time
--- delivery) is NOT in the local read.  If we wrote the full merged map into
--- the ancestor, the very next merge would see "ancestor has it, local does
--- not" and synthesize a PHANTOM deletion of an annotation the user never
--- touched.
---
--- The fix: a live (non-deleted) entry enters the ancestor only if its key
--- was in THIS merge's local read (i.e. it is materialized on this device).
--- Tombstones ALWAYS enter the ancestor -- a deletion must stay known so it
--- is not resurrected.  Un-materialized pulls are excluded; the next merge
--- then sees them as remote-only (adopt again, alive), never as a deletion.
---
--- This does NOT break real deletion detection: a key the user genuinely had
--- locally WAS in the local read, so it is kept in the ancestor; when the
--- user later deletes it, its absence is correctly read as a deletion.
---
--- @param merged table The merged annotation map (alive entries + tombstones).
--- @param local_annotations table The local read this merge diffed against.
--- @return table The filtered map to persist as the last-sync ancestor.
function SyncOrchestrator._materialized_last_sync_annotations(merged, local_annotations)
    local_annotations = local_annotations or {}
    local filtered = {}
    for key, entry in pairs(merged or {}) do
        if entry then
            if entry.deleted then
                -- Tombstones always stay in the ancestor (never resurrect).
                filtered[key] = entry
            elseif local_annotations[key] ~= nil then
                -- Key is present in the live list -> legitimate ancestor entry.
                -- Record the MATERIALIZED (live) value, NOT the merged value:
                -- when a remote EDIT won the pick, merged != live (S1 keeps the
                -- live list untouched in-session; delivery is at close / G).
                -- Writing merged here would desync the ancestor from what the
                -- device actually has, and the next merge's
                -- _preserve_local_note_edits would read the stale live note as a
                -- fresh local edit (ancestor.note != local.note) and re-assert
                -- it with a bumped timestamp -> bidirectional ping-pong, the
                -- remote edit regresses. The ancestor must equal the live state.
                filtered[key] = local_annotations[key]
            end
            -- else: live but un-materialized pull -> excluded (no phantom).
        end
    end
    return filtered
end


--- Translate the orchestrator's flat toggles table into the shape
--- the metadata bridge expects (with `master` etc).  Centralized here
--- so both read_from_ui and apply_from_remote call sites stay in sync.
function SyncOrchestrator._compose_metadata_toggles(toggles)
    toggles = toggles or {}
    return {
        master      = toggles.metadata    ~= false,
        status      = toggles.status      ~= false,
        rating      = toggles.rating      ~= false,
        collections = toggles.collections ~= false,
        summary     = toggles.summary     ~= false,
        custom      = toggles.custom      ~= false,
        handmade    = toggles.handmade    ~= false,
    }
end


--- Translate the orchestrator's flat toggles into the render bridge's
--- shape.  Render settings are opt-in per field (default off), so every
--- flag requires an explicit `== true` — unlike metadata, which defaults
--- on.  Centralized so read_from_ui and apply_from_remote agree.
function SyncOrchestrator._compose_render_toggles(toggles)
    toggles = toggles or {}
    return {
        master       = toggles.render_settings == true,
        font_face    = toggles.font_face       == true,
        font_size    = toggles.font_size       == true,
        line_spacing = toggles.line_spacing    == true,
        font_weight  = toggles.font_weight     == true,
        margins      = toggles.margins         == true,
    }
end


function SyncOrchestrator._count_total(map)
    local n = 0
    for _ in pairs(map or {}) do n = n + 1 end
    return n
end


--- Count keys in `after` that weren't (or differ from) in `before`.
---
--- Used to report "we pulled in N new annotations" and "we pushed N
--- new annotations".  An annotation counts as "added" if the before
--- map didn't have its key at all OR the before entry had an older
--- datetime_updated.
function SyncOrchestrator._count_added_vs(after, before, exclude)
    local count = 0
    for key, after_entry in pairs(after or {}) do
        -- A tombstone is a DELETION, not a new annotation.  Skip it: the
        -- merged map keeps tombstones, but the local sidecar never stores
        -- them (KOReader has no tombstone concept; `_prepare_for_doc_settings`
        -- strips `deleted`), so an un-skipped tombstone is absent from
        -- `before` and would count as "new" on EVERY sync forever -- firing
        -- the "N new annotations from another device" reload affordance
        -- perpetually after a cross-device deletion.  `pulled`/`pushed` mean
        -- new annotations moved (see the result-field comments); deletions are
        -- not that.
        --
        -- `exclude` (optional) drops keys that ride in the merged map but are
        -- not delivered to this device -- remote's disabled-type entries under
        -- per-type filtering.  Counting against (merged - exclude) equals
        -- counting against the delivered map.
        if not (exclude and exclude[key])
                and after_entry and not after_entry.deleted then
            local before_entry = (before or {})[key]
            if not before_entry then
                count = count + 1
            else
                local after_ts  = after_entry.datetime_updated  or after_entry.datetime  or ""
                local before_ts = before_entry.datetime_updated or before_entry.datetime or ""
                if after_ts > before_ts then
                    count = count + 1
                end
            end
        end
    end
    return count
end


function SyncOrchestrator._shallow_copy_map(map)
    local copy = {}
    for k, v in pairs(map or {}) do copy[k] = v end
    return copy
end


return SyncOrchestrator
