-- =============================================================================
-- syncery_transports/cloud/sync_service_adapter.lua
-- =============================================================================
--
-- Adapts KOReader's `apps/cloudstorage/syncservice` to Syncery's
-- transport layer, and builds the 3-way merge CALLBACK that
-- SyncService invokes during a sync.
--
-- WHAT SYNCSERVICE ACTUALLY IS  (verified against koreader/master,
-- frontend/apps/cloudstorage/syncservice.lua)
--
--   SyncService.sync(server, file_path, sync_cb, is_silent)
--
-- is a BIDIRECTIONAL, single-call sync over a cloud provider (Dropbox
-- or WebDAV today). In one call it:
--   1. downloads the remote copy of basename(file_path) into
--      `file_path .. ".temp"`  (the INCOME file == remote state);
--   2. invokes  sync_cb(file_path, cached_file_path, income_file_path)
--      where cached == `file_path .. ".sync"` is what THIS device
--      uploaded last time (the merge ANCESTOR / base);
--   3. if the callback raises OR returns falsy -> ABORTS (no upload);
--   4. otherwise uploads whatever the callback left in `file_path`,
--      then copies file_path -> cached_file_path (advances the ancestor).
--
-- So the callback is a 3-WAY-MERGE-OVER-FILE-PATHS function. It must
-- read the three files, merge, WRITE the merged result back into
-- `file_path`, and return a truthy bool. SyncService never writes the
-- downloaded bytes into `file_path` itself — that is the callback's job.
--
-- IMPORTANT BEHAVIOURS we design around:
--   * F1: SyncService only accepts server.type in {dropbox, webdav}; it
--     rejects anything else with "Wrong server type". The cloud browser
--     ALSO allows FTP, so a valid-for-browsing FTP server cannot sync.
--     We stay provider-agnostic in code (future S3 etc. pass through),
--     but the caller must validate server.type before relying on sync.
--   * F2: When offline, SyncService.sync returns IMMEDIATELY without
--     calling the callback (it schedules a rerun via NetworkMgr). So the
--     merge may happen later, asynchronously. The callback therefore
--     reconciles into the canonical on-disk file ITSELF (not only via a
--     post-sync read-back), so a deferred run still lands its result.
--   * F3: On an HTTP 412 (If-Match/etag conflict) SyncService re-downloads
--     income and re-invokes the callback in a loop, MUTATING file_path in
--     place each pass while the ancestor (.sync) stays fixed. The callback
--     must therefore be safe to re-run on an already-merged local file.
--     Merge.three_way is idempotent (tombstones + newer-wins), so this
--     converges — proven by the re-run unit test.
--
-- ENGINE REUSE
--
-- The cloud "annotations" synced unit is the WHOLE canonical envelope
-- (annotations + metadata + render_settings), because plugin_sync stages
-- the raw shared_annotations_path file. To keep the Cloud and Syncthing
-- transports SEMANTICALLY IDENTICAL on the same file, the callback reuses
-- the exact same pure merge functions the Syncthing orchestrator uses:
--   * annotations     -> Merge.three_way(local, ancestor, income, cmp)
--   * metadata         -> MetadataBridge.three_way(local, income, ancestor)
--   * render_settings  -> RenderSettingsBridge.merge(local, income)  (per-field)
-- and reassembles an envelope identical in shape to the orchestrator's
-- `final_state` (carrying identities from the LOCAL envelope).
--
-- DEPENDENCY INJECTION
--
-- The constructor takes `sync_service` so tests can pass a fake. In
-- production we resolve KOReader's real one lazily on first use. The
-- callback factory takes its merge functions / json store / comparator /
-- reconcile hook as injectable opts so it is pure-ish and headless-testable.
--
-- =============================================================================


local Interface = require("syncery_transports/interface")
local Log       = require("syncery_transports/log")
local log       = Log.tag("cloud.sync_service")

local JsonStore     = require("syncery_ann/json_store")
local Merge         = require("syncery_ann/merge")
local MetadataBridge = require("syncery_ann/metadata_bridge")
local ProgressMerge = require("syncery_progress/merge")
local ProgressStateStore = require("syncery_progress/state_store")


local Adapter = {}
Adapter.__index = Adapter


-- ----------------------------------------------------------------------------
-- Default sync_service resolver (lazy — not always loadable in tests).
-- ----------------------------------------------------------------------------


local _resolved = nil

local function default_sync_service()
    if _resolved then return _resolved end
    local ok, svc = pcall(require, "apps/cloudstorage/syncservice")
    if not ok or not svc then
        error("SyncService unavailable; pass sync_service explicitly")
    end
    _resolved = svc
    return _resolved
end


-- Lazy resolver for the render-settings picker: render_settings_bridge is
-- required only when the production default is actually needed, so the module
-- is not pulled in for tests that inject their own picker.
local function default_render_pick(block_a, block_b)
    -- Render merge is centralized in RenderSettingsBridge.merge (per-field),
    -- the single source of truth shared with the Syncthing orchestrator and
    -- the conflict resolver, so the three transports cannot diverge.
    local RenderSettingsBridge = require("syncery_ann/render_settings_bridge")
    return RenderSettingsBridge.merge(block_a, block_b)
end


-- ----------------------------------------------------------------------------
-- Envelope helpers.
-- ----------------------------------------------------------------------------


-- Mirror state_store._build_empty_state(): the shape our own reader
-- (StateStore.load_shared -> _validate_and_repair) accepts.
local function empty_envelope()
    return {
        schema_version  = 1,
        annotations     = {},
        metadata        = {},
        render_settings = {},
    }
end


-- Is `t` shaped like one of our annotation envelopes? We are lenient:
-- an empty object is a valid (empty) envelope; missing sections default
-- to empty; but if a section IS present it must be a table, and every
-- annotation entry must be a table (our merge iterates entries as
-- tables). A valid-JSON-but-wrong-shape body (e.g. a foreign file or an
-- error object) fails this and is treated as corrupt -> abort, never
-- clobber. We validate against OUR shape, not any foreign schema.
local function is_valid_envelope(t)
    if type(t) ~= "table" then return false end
    if t.annotations ~= nil then
        if type(t.annotations) ~= "table" then return false end
        for _k, v in pairs(t.annotations) do
            if type(v) ~= "table" then return false end
        end
    end
    if t.metadata ~= nil and type(t.metadata) ~= "table" then return false end
    if t.render_settings ~= nil and type(t.render_settings) ~= "table" then return false end
    return true
end


-- Progress equivalents. The progress canonical file is a ONE-section
-- envelope: { schema_version, device_id, device_label, entries }, where
-- entries is { [device_id] = { revision, percent, page, timestamp, ... } }.
-- (See syncery_progress/state_store.lua — progress has a single concern,
-- the position-per-device map, NOT the three annotation sections.)
local function empty_progress_state()
    return {
        schema_version = 1,
        entries        = {},
    }
end


-- Is `t` shaped like one of our progress state files? Lenient like the
-- envelope check: an empty object is valid (empty) state; a missing
-- `entries` defaults to empty; but if present it must be a table whose
-- values are tables (entries our merge iterates as tables). A foreign
-- body / error object fails this -> treated as corrupt -> abort.
--
-- A body with no `entries` key passes here (the `entries == nil` branch):
-- we validate our OWN shape leniently and let `normalize` map an
-- unrecognized body to empty state.  We do NOT validate foreign schemas.
local function is_valid_progress_state(t)
    if type(t) ~= "table" then return false end
    if t.entries ~= nil then
        if type(t.entries) ~= "table" then return false end
        for _k, v in pairs(t.entries) do
            if type(v) ~= "table" then return false end
        end
    end
    return true
end


-- Raw byte read used ONLY to classify a parse failure as a clean
-- "first sync / 404" body vs a genuine corrupt/server-error body. This
-- is error classification, not JSON I/O — structured reads go through
-- JsonStore.
local function looks_like_clean_404(income_file)
    local f = io.open(income_file, "rb")
    if not f then
        -- No file at all == clean first sync (SyncService usually creates
        -- one, but be defensive).
        return true
    end
    local content = f:read(2048) or ""
    f:close()
    local lower = content:lower()
    if lower:find("404", 1, true)
        or lower:find("not found", 1, true)
        or lower:find("notfound", 1, true)
        or lower:find("could not be located", 1, true)
        or lower:find("path/not_found", 1, true) then   -- Dropbox: path not found
        return true
    end
    return false
end


-- Sentinel meaning "abort the sync — do not clobber".
local INCOME_ABORT = {}


-- Resolve a downloaded income (remote) file into a state table, or
-- INCOME_ABORT. Parameterised so both subsystems share the same
-- clean-404-vs-corrupt logic with their own shape validator / empty builder:
--   * valid JSON, valid shape                -> that table
--   * missing / empty                        -> empty (clean first sync)
--   * unparseable but looks like a 404 body  -> empty (clean first sync)
--   * valid JSON but wrong shape, or a real
--     corrupt / server-error body            -> INCOME_ABORT
local function classify_income(income_file, json_store, is_valid, make_empty)
    local data, diag = json_store.read(income_file)
    if diag == "ok" then
        if is_valid(data) then return data end
        return INCOME_ABORT          -- valid JSON, foreign shape -> corrupt
    end
    if diag == "no_path" or diag == "not_found" or diag == "empty" then
        return make_empty()           -- clean first sync
    end
    -- invalid_json / read_error: sniff for a 404-ish body.
    if looks_like_clean_404(income_file) then
        return make_empty()
    end
    return INCOME_ABORT
end


-- ----------------------------------------------------------------------------
-- Annotation merge callback factory.
--
-- Returns a `function(local_file, cached_file, income_file) -> bool` that
-- SyncService.sync can call. The returned callback:
--   1. reads local (our current state) + cached (.sync ancestor) + income
--      (remote) as ENVELOPES;
--   2. ABORTS (returns false) on a corrupt/unreadable local OR ancestor
--      (broken JSON) — never clobbers. A MISSING ancestor is a normal
--      first sync (empty), distinct from a corrupt one;
--   3. resolves income: clean first-sync/404 -> empty remote; corrupt /
--      server-error -> abort;
--   4. merges all three envelope sections with the SAME functions the
--      Syncthing path uses, reassembling identities from the LOCAL
--      envelope;
--   5. writes the merged envelope back into local_file (atomic) — this is
--      what SyncService uploads;
--   6. reconciles the SAME merged envelope into the canonical on-disk file
--      (F2: inside the callback, so a deferred/offline run still lands).
--      If the canonical write fails, returns false so SyncService does NOT
--      upload and does NOT advance the ancestor — preventing a divergence
--      that a later 3-way merge would misread as local deletions;
--   7. invokes the optional live-UI reconcile hook (18.9.7) best-effort;
--   8. returns true.
--
-- Re-run safe (F3): reads all three files fresh on every call and relies
-- on Merge.three_way idempotency.
--
-- opts:
--   canonical_path  string|nil  Where the canonical on-disk envelope lives
--                               (shared_annotations_path). When set, step 6
--                               reconciles into it. nil skips reconcile
--                               (used by pure merge unit tests).
--   comparator      function|nil Position comparator for the overlap pass.
--                               nil (closed book / deferred) -> no overlap
--                               pass (Merge.three_way handles nil).
--   force           boolean      Reserved for the fresh-device deletion-
--                               propagation override (18.8 / 18.9.6). Threaded
--                               now, OFF by default; does NOT change merge
--                               behaviour yet (the wipe failsafe lands 18.9.6).
--   on_reconciled   function|nil Called with the merged envelope after a
--                               successful persist — the live doc_settings
--                               refresh hook (18.9.7). Best-effort (pcall).
--   json_store      table        Defaults to JsonStore.
--   merge_three_way function     Defaults to Merge.three_way.
--   metadata_merge  function     Defaults to MetadataBridge.three_way (3-way
--                               against the .sync ancestor, same as annotations).
--   render_pick     function     Defaults to default_render_pick (-> RenderSettingsBridge.merge).
-- ----------------------------------------------------------------------------


function Adapter.make_annotation_sync_callback(opts)
    opts = opts or {}
    local json_store      = opts.json_store      or JsonStore
    local merge_three_way = opts.merge_three_way or Merge.three_way
    local metadata_merge  = opts.metadata_merge  or MetadataBridge.three_way
    local render_pick     = opts.render_pick     or default_render_pick
    local comparator      = opts.comparator
    local canonical_path  = opts.canonical_path
    local on_reconciled   = opts.on_reconciled
    local _force          = opts.force and true or false   -- reserved (18.9.6)

    return function(local_file, cached_file, income_file)
        -- 1/2. LOCAL (our current state) — corrupt => abort; missing/empty
        -- => empty envelope (nothing to contribute).
        local local_env, ldiag = json_store.read(local_file)
        if ldiag == "invalid_json" or ldiag == "read_error" then
            log.warn("cloud merge: local unreadable (%s) — aborting", tostring(ldiag))
            return false
        end
        local_env = local_env or empty_envelope()

        -- ANCESTOR (.sync) — corrupt => abort; MISSING => first sync (empty),
        -- which is a normal, safe state, distinct from corruption.
        local anc_env, adiag = json_store.read(cached_file)
        if adiag == "invalid_json" or adiag == "read_error" then
            log.warn("cloud merge: ancestor unreadable (%s) — aborting", tostring(adiag))
            return false
        end
        anc_env = anc_env or empty_envelope()

        -- 3. INCOME (remote) — clean 404/first-sync => empty; corrupt => abort.
        local income_env = classify_income(
            income_file, json_store, is_valid_envelope, empty_envelope)
        if income_env == INCOME_ABORT then
            log.warn("cloud merge: income corrupt/server-error — aborting")
            return false
        end

        -- 4. Merge all three envelope sections (identical to Syncthing:
        -- annotations AND metadata are 3-way against the .sync ancestor;
        -- render is whole-block newer-wins).
        local merged = {
            schema_version  = local_env.schema_version or 1,
            device_id       = local_env.device_id,
            device_label    = local_env.device_label,
            annotations     = merge_three_way(
                local_env.annotations or {},
                anc_env.annotations or {},
                income_env.annotations or {},
                comparator),
            metadata        = metadata_merge(
                local_env.metadata or {},
                income_env.metadata or {},
                anc_env.metadata or {}),
            render_settings = render_pick(
                local_env.render_settings or {},
                income_env.render_settings or {}) or {},
        }

        -- 5. Write merged back into local_file (what SyncService uploads).
        local wok = json_store.write(local_file, merged)
        if not wok then
            log.warn("cloud merge: failed to write merged local — aborting")
            return false
        end

        -- 6. Reconcile into the canonical on-disk file (F2). If this fails,
        -- abort: we must NOT let SyncService advance the ancestor while the
        -- canonical file lags, or the next 3-way merge would read the lag as
        -- local deletions and wipe the just-merged content.
        if canonical_path then
            local cok = json_store.write(canonical_path, merged)
            if not cok then
                log.warn("cloud merge: canonical reconcile write failed — aborting")
                return false
            end
        end

        -- 7. Live-UI refresh hook (18.9.7) — best-effort, never fatal.
        if type(on_reconciled) == "function" then
            pcall(on_reconciled, merged)
        end

        return true
    end
end


-- ----------------------------------------------------------------------------
-- Progress merge callback factory.
--
-- The progress analogue of make_annotation_sync_callback. Returns the same
-- `(local_file, cached_file, income_file) -> bool` shape SyncService.sync
-- invokes. SAME guard discipline, SAME re-run safety (F3), SAME canonical
-- reconcile (F2) and SAME canonical-failure-aborts rule as annotations.
--
-- The DIFFERENCES from annotations:
--   * The progress canonical file is a ONE-section envelope (entries only),
--     not the three-section annotation envelope.
--   * The merge is syncery_progress/merge.three_way(local, ancestor, remote)
--     — a 3-WAY merge by (revision, timestamp) newer-wins, the EXACT function
--     the progress Syncthing orchestrator uses (sync_orchestrator.lua:246).
--     This keeps Cloud and Syncthing convergent on the same progress file.
--     We do NOT use ConflictResolver.merge_two_states: that is for resolving
--     Syncthing `.sync-conflict-*` files (resolve_all), which has no cloud
--     analogue (SyncService produces no conflict files). Progress has no
--     deletions/tombstones, so the ancestor is not used for deletion
--     detection — but it IS passed (it participates as a floor in the rare
--     both-sides-older-than-ancestor case), exactly as Syncthing does. We do
--     NOT collapse this to a 2-way merge: that would diverge from Syncthing
--     in that edge case (the transport-convergence rule).
--   * There is NO live-state entry generation and NO wipe failsafe here. The
--     wipe failsafe (_would_wipe_own_progress) compares a PROPOSED entry read
--     from the live document against remote; in a cloud sync (which may run
--     deferred, with the book closed — F2) there is no live document to read.
--     The fresh-device / wipe protection is wired at 18.9.6, not here.
--
-- opts: same shape as the annotation factory, minus metadata_merge/render_pick:
--   canonical_path   string|nil  Where the canonical progress.json lives.
--   force            boolean      Reserved for 18.9.6 (allow_wipe analogue);
--                                 OFF by default; no behaviour change yet.
--   on_reconciled    function|nil Live-UI refresh hook (18.9.7), best-effort.
--   json_store       table        Defaults to JsonStore.
--   merge_three_way  function     Defaults to ProgressMerge.three_way.
-- ----------------------------------------------------------------------------


function Adapter.make_progress_sync_callback(opts)
    opts = opts or {}
    local json_store      = opts.json_store      or JsonStore
    local merge_three_way = opts.merge_three_way or ProgressMerge.three_way
    -- Normalise each side before merge so every body reaching three_way is in
    -- the canonical { entries = {...} } shape.  `normalize` is idempotent on a
    -- new-shape body and maps anything without an `entries` wrapper to empty
    -- state.  Reuses the progress subsystem's OWN normaliser.
    local normalize       = opts.normalize       or ProgressStateStore.normalize
    local canonical_path  = opts.canonical_path
    local on_reconciled   = opts.on_reconciled
    local _force          = opts.force and true or false   -- reserved (18.9.6)

    return function(local_file, cached_file, income_file)
        -- 1/2. LOCAL — corrupt => abort; missing/empty => empty state.
        local local_state, ldiag = json_store.read(local_file)
        if ldiag == "invalid_json" or ldiag == "read_error" then
            log.warn("cloud progress merge: local unreadable (%s) — aborting", tostring(ldiag))
            return false
        end
        local_state = normalize(local_state or empty_progress_state())

        -- ANCESTOR (.sync) — corrupt => abort; MISSING => first sync (empty).
        local anc_state, adiag = json_store.read(cached_file)
        if adiag == "invalid_json" or adiag == "read_error" then
            log.warn("cloud progress merge: ancestor unreadable (%s) — aborting", tostring(adiag))
            return false
        end
        anc_state = normalize(anc_state or empty_progress_state())

        -- 3. INCOME (remote) — clean 404/first-sync => empty; corrupt => abort.
        -- classify_income validates our shape leniently (a body with no
        -- `entries` wrapper is accepted, then normalized to empty state).
        local income_state = classify_income(
            income_file, json_store, is_valid_progress_state, empty_progress_state)
        if income_state == INCOME_ABORT then
            log.warn("cloud progress merge: income corrupt/server-error — aborting")
            return false
        end
        income_state = normalize(income_state)

        -- 4. 3-way merge of the entries maps (identical to Syncthing).
        local merged = {
            schema_version = local_state.schema_version or 1,
            device_id      = local_state.device_id,
            device_label   = local_state.device_label,
            entries        = merge_three_way(
                local_state.entries or {},
                anc_state.entries or {},
                income_state.entries or {}),
        }

        -- 5. Write merged back into local_file (what SyncService uploads).
        local wok = json_store.write(local_file, merged)
        if not wok then
            log.warn("cloud progress merge: failed to write merged local — aborting")
            return false
        end

        -- 6. Reconcile into the canonical on-disk file (F2). Abort on failure
        -- so SyncService does NOT advance the ancestor while canonical lags.
        if canonical_path then
            local cok = json_store.write(canonical_path, merged)
            if not cok then
                log.warn("cloud progress merge: canonical reconcile write failed — aborting")
                return false
            end
        end

        -- 7. Live-UI refresh hook (18.9.7) — best-effort, never fatal.
        if type(on_reconciled) == "function" then
            pcall(on_reconciled, merged)
        end

        return true
    end
end


-- Safe default callback: if the adapter is used without a real merge
-- callback wired in, ABORT rather than clobber. SyncService treats a
-- falsy return as "do not upload". This makes the cloud transport
-- safe-but-inert until the real callback is wired (18.9.3).
local function safe_abort_callback()
    return false
end


-- ----------------------------------------------------------------------------
-- Constructor.
-- ----------------------------------------------------------------------------


--- Build an adapter.
---
--- Required opts:
---   server — the server object the cloud picker produced.  Opaque to
---            us; passed through to SyncService (provider-agnostic).
---
--- Optional opts:
---   sync_service   — module with `.sync(server, path, merge_cb, is_silent)`.
---                    Default is KOReader's bundled module, lazy-loaded.
---   merge_callback — the 3-path callback `(local_file, cached_file,
---                    income_file) -> bool` that SyncService invokes.
---                    Build it with Adapter.make_annotation_sync_callback.
---                    Default is a safe-abort callback (never clobbers).
function Adapter.new(opts)
    opts = opts or {}
    assert(opts.server ~= nil, "Adapter.new: server is required")
    local svc = opts.sync_service or default_sync_service
    local merge_cb = opts.merge_callback or safe_abort_callback

    local self = setmetatable({}, Adapter)
    self._server         = opts.server
    self._sync_service   = svc
    self._merge_callback = merge_cb
    return self
end


-- ----------------------------------------------------------------------------
-- upload — hand `local_path` to SyncService for a bidirectional sync.
--
-- Calls back with (true, nil) when the call was dispatched without
-- raising, or (false, err_class) on a synchronous failure. The actual
-- merge+upload happens inside SyncService.sync (synchronously when
-- online; deferred when offline — see F2). is_silent=true keeps the
-- per-save path from spamming system toasts.
-- ----------------------------------------------------------------------------


function Adapter:upload(local_path, callback)
    if type(local_path) ~= "string" or local_path == "" then
        callback(false, Interface.ERRORS.REJECTED); return
    end

    local svc = self._sync_service
    if type(svc) == "function" then
        local ok, resolved = pcall(svc)
        if not ok or type(resolved) ~= "table" or type(resolved.sync) ~= "function" then
            log.warn("SyncService resolver failed: %s", tostring(resolved))
            callback(false, Interface.ERRORS.NOT_AVAILABLE); return
        end
        svc = resolved
    end

    if type(svc) ~= "table" or type(svc.sync) ~= "function" then
        callback(false, Interface.ERRORS.NOT_AVAILABLE); return
    end

    local ok, call_err = pcall(svc.sync,
        self._server, local_path, self._merge_callback, true)
    if not ok then
        log.warn("SyncService.sync raised: %s", tostring(call_err))
        callback(false, Interface.ERRORS.INTERNAL); return
    end
    callback(true, nil)
end


-- ----------------------------------------------------------------------------
-- Test-only exports.
--
-- These internal helpers back the merge callbacks; exposing them under an
-- underscore namespace lets specs cover them DIRECTLY (the test-only export
-- convention used across the codebase). In particular this lets the
-- empty-section JSON round-trip boundary and the shared classify_income
-- parameterisation be tested without going through a full sync. Not part of
-- the public API; do not call from production code.
-- ----------------------------------------------------------------------------
Adapter._empty_envelope          = empty_envelope
Adapter._is_valid_envelope       = is_valid_envelope
Adapter._empty_progress_state    = empty_progress_state
Adapter._is_valid_progress_state = is_valid_progress_state
Adapter._classify_income         = classify_income
Adapter._INCOME_ABORT            = INCOME_ABORT


return Adapter
