-- =============================================================================
-- syncery_debuglog.lua — Verbose sync logging (menu toggle, default OFF)
-- =============================================================================
--
-- WHAT THIS FILE IS
--
-- main.lua (and syncery_ann/render_settings_bridge.lua) contain a small,
-- STABLE set of guard call-sites of the form:
--
--     if _G.SYNCERY_DEBUG_LOG then
--         _G.SYNCERY_DEBUG_LOG.some_event(...)
--     end
--
-- Those call-sites are NOT meant to change again -- this module is loaded
-- UNCONDITIONALLY (main.lua requires it once, at the top), so
-- `_G.SYNCERY_DEBUG_LOG` is always a populated table and every guard above
-- always takes its branch. All the actual logging logic -- what to print,
-- how to format it, which events to expand next -- lives HERE instead, so
-- future debugging iterations only touch this one file.
--
-- ENABLED/DISABLED is a SEPARATE axis from "is this module loaded": the
-- "Verbose sync logging" menu toggle (Advanced, under "Copy diagnostic
-- info", default OFF) calls M.set_enabled(bool). Every function actually
-- exposed on `_G.SYNCERY_DEBUG_LOG` is a thin wrapper (built once, in a
-- loop, over the `impl` table below) that checks the enabled flag FIRST
-- and returns immediately if it is off -- so a disabled guard costs one
-- upvalue read and a branch, not a real logging call.
--
-- This file ALSO monkey-patches syncery_ann/mtime_gate.lua's MtimeGate.run
-- directly (by requiring the SAME cached module table main.lua already
-- uses and overwriting the .run field on it) -- so mtime_gate.lua itself
-- never needs to be touched for this instrumentation either. The wrap
-- itself is installed unconditionally (once); the LOGGING inside it is
-- what respects the enabled flag, exactly like every other event below.
--
-- Every enabled event logs via logger.info with a "Syncery[DEBUG]:"
-- prefix (so it is easy to grep out of crash.log, exactly as before) AND
-- appends the same line to debug.txt in the Syncery settings folder --
-- a dedicated, ISOLATED artifact a user can grab and share without
-- needing to extract Syncery's lines out of the full crash.log. debug.txt
-- is capped at DEBUG_FILE_MAX_LINES lines (oldest dropped first); the cap
-- is enforced cheaply (a size check on every append, the expensive
-- read-trim-rewrite only when that size crosses a rough threshold), not
-- by counting lines on every single write.
-- =============================================================================

local logger = require("logger")

local M = {}

local enabled = false

function M.set_enabled(v)
    enabled = (v == true)
end

function M.is_enabled()
    return enabled
end


-- ----------------------------------------------------------------------------
-- debug.txt: dedicated, capped, rotating log file.
-- ----------------------------------------------------------------------------

local DEBUG_FILE_MAX_LINES  = 1000
-- Approximate trigger size, not an exact line-count guarantee (a cheap
-- size check on every append is fine; counting real lines on every
-- append would not be). Syncery[DEBUG] lines range from quite short
-- ("on_reconciled_fired", ~40 bytes) to longer ones with several
-- key=value fields (~150+ bytes); 80KB sits comfortably under
-- DEBUG_FILE_MAX_LINES worth of bytes even for a short-line-heavy
-- session, so the file stays in the right ballpark without needing to
-- track an exact running line count.
local DEBUG_FILE_TRIGGER_BYTES = 80 * 1024

local function debug_file_path()
    -- Lazy require: syncery_util pulls in datastorage, which this module
    -- should not need at load time if debug logging is never enabled.
    local ok, Util = pcall(require, "syncery_util")
    if not ok or not Util or not Util.state_dir then return nil end
    local ok2, dir = pcall(Util.state_dir)
    if not ok2 or not dir then return nil end
    return dir .. "debug.txt"
end

--- Trim debug.txt down to its last DEBUG_FILE_MAX_LINES lines. Only called
--- when the file has already crossed DEBUG_FILE_TRIGGER_BYTES, so this
--- expensive read-everything-rewrite path is rare, not per-line.
local function trim_debug_file(path)
    local f = io.open(path, "rb")
    if not f then return end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return end

    local lines = {}
    for line in content:gmatch("([^\n]*)\n?") do
        lines[#lines + 1] = line
    end
    -- gmatch on a trailing-newline string leaves one empty trailing
    -- capture; drop it so the count reflects real lines.
    if lines[#lines] == "" then lines[#lines] = nil end

    if #lines <= DEBUG_FILE_MAX_LINES then return end

    local keep_from = #lines - DEBUG_FILE_MAX_LINES + 1
    local out = io.open(path, "wb")
    if not out then return end
    for i = keep_from, #lines do
        out:write(lines[i], "\n")
    end
    out:close()
end

--- Append one line to debug.txt, rotating (rarely, cheaply gated) if the
--- file has grown past the trigger size. Best-effort: any failure here
--- (disk full, path unavailable) is silently swallowed -- a debug
--- convenience must never be able to break the app it is instrumenting.
local function append_to_debug_file(line)
    local path = debug_file_path()
    if not path then return end
    local ok = pcall(function()
        local f = io.open(path, "ab")
        if not f then return end
        f:write(line, "\n")
        f:close()

        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs then
            local size = lfs.attributes(path, "size")
            if size and size > DEBUG_FILE_TRIGGER_BYTES then
                trim_debug_file(path)
            end
        end
    end)
    if not ok then
        -- Swallowed deliberately -- see docstring above.
    end
end

--- Every impl.xxx function below calls emit(msg) exactly where it used to
--- call logger.info(msg) directly -- same single-formatted-string shape,
--- now ALSO appended to debug.txt.
local function emit(msg)
    logger.info(msg)
    append_to_debug_file(msg)
end

local function fmt(v)
    if v == nil then return "nil" end
    if type(v) == "table" then
        local parts = {}
        for k, val in pairs(v) do
            parts[#parts + 1] = tostring(k) .. "=" .. tostring(val)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v)
end

local impl = {}

-- ----------------------------------------------------------------------------
-- Session tally: a lightweight counter set accumulated as the hooks below
-- fire, dumped as ONE consolidated summary at teardown (session_end) instead
-- of requiring a human to manually count scattered log lines to answer
-- "how often, and what actually changed, this session". Reset after each
-- dump so counts never bleed across book-open sessions.
-- ----------------------------------------------------------------------------
local tally = {}
local function bump(key, n)
    tally[key] = (tally[key] or 0) + (n or 1)
end

--- Dump the accumulated tally as one consolidated summary line and reset it.
--- Called from syncery_lifecycle/init.lua's teardown() on any DESTROYING
--- teardown (book close / app quit) -- the natural end of a session.
function impl.session_end()
    local parts = {}
    local keys = {}
    for k in pairs(tally) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        parts[#parts + 1] = k .. "=" .. tostring(tally[k])
    end
    emit("Syncery[DEBUG] session_end summary: "
        .. (#parts > 0 and table.concat(parts, " ") or "(no cloud/sync activity this session)"))
    tally = {}
end

--- render_settings_bridge.lua: per-field decision inside apply_from_remote.
function impl.render_field(
        key, had_cached_entry, current, remote_value, values_equal, remote_ts, from_live_state)
    emit(string.format(
        "Syncery[DEBUG] render_field key=%s had_cached_entry=%s current=%s from_live_state=%s remote=%s values_equal=%s remote_ts=%s",
        tostring(key), tostring(had_cached_entry), fmt(current), tostring(from_live_state),
        fmt(remote_value), tostring(values_equal), tostring(remote_ts)))
end

--- main.lua checkRemote: result of JumpPolicy.pick_jump_target.
function impl.jump_target(file, fresh, best, best_device_id, session_baseline)
    local fresh_count = 0
    if type(fresh) == "table" then
        for _ in pairs(fresh) do fresh_count = fresh_count + 1 end
    end
    emit(string.format(
        "Syncery[DEBUG] jump_target file=%s fresh_count=%d best_device_id=%s best=%s session_baseline=%s",
        tostring(file), fresh_count, tostring(best_device_id), fmt(best), tostring(session_baseline)))
end

--- main.lua checkRemote: should_prompt / _jumpChangesPage results.
function impl.checkRemote_step(step, file, best_device_id, page_delta, result)
    emit(string.format(
        "Syncery[DEBUG] checkRemote_step step=%s file=%s best_device_id=%s page_delta=%s result=%s",
        tostring(step), tostring(file), tostring(best_device_id), tostring(page_delta), tostring(result)))
end

--- main.lua _maybeOfferReload: entry snapshot before the early-return gates.
function impl.maybe_offer_reload(ann_count, render, has_ann, has_reload_doc, reload_prompt_on)
    emit(string.format(
        "Syncery[DEBUG] maybe_offer_reload ann_count=%s render=%s has_ann=%s has_reload_doc=%s reload_prompt_on=%s",
        tostring(ann_count), tostring(render), tostring(has_ann),
        tostring(has_reload_doc), tostring(reload_prompt_on)))
end

--- main.lua _maybeOfferReload: the ACTUAL moment ActionBar.show fires for
--- the annotation/font-layout reload toast (only reached if none of the
--- early-return gates above fired).
function impl.reload_toast_shown(text)
    bump("reload_toast_shown_count")
    emit(string.format("Syncery[DEBUG] reload_toast_shown text=%q", tostring(text)))
end

--- main.lua onReconciled (the do_cloud_upload merge-callback hook): fires
--- the moment a cloud pull has landed and merged into the shared file.
function impl.on_reconciled_fired()
    bump("on_reconciled_fired_count")
    emit("Syncery[DEBUG] on_reconciled_fired")
end

--- main.lua post_pull_check: still blocked (is_saving / syncing / an
--- active sync box), retrying.
function impl.post_pull_check_retry(tries, is_saving, sync_state, active_sync_box)
    emit(string.format(
        "Syncery[DEBUG] post_pull_check_retry tries=%d is_saving=%s sync_state=%s active_sync_box=%s",
        tries, tostring(is_saving), tostring(sync_state), tostring(active_sync_box)))
end

--- main.lua post_pull_check: gates cleared, proceeding to checkRemote().
function impl.post_pull_check_proceeding(tries)
    emit(string.format("Syncery[DEBUG] post_pull_check_proceeding tries=%d -> checkRemote()", tries))
end

--- main.lua _syncBookViaOrchestrator: the orchestrator's FULL merge result
--- -- this is what feeds _pending_ann_reload / _pending_render_reload.
function impl.orchestrator_result(file, trigger, result)
    bump("orchestrator_runs")
    if type(result) == "table" then
        if type(result.annotations_pulled) == "number" and result.annotations_pulled > 0 then
            bump("annotations_pulled_total", result.annotations_pulled)
        end
        if type(result.annotations_pushed) == "number" and result.annotations_pushed > 0 then
            bump("annotations_pushed_total", result.annotations_pushed)
        end
        if result.render_applied then bump("render_applied_count") end
        if result.ok == false then bump("orchestrator_errors") end
    end
    if type(result) ~= "table" then
        emit(string.format(
            "Syncery[DEBUG] orchestrator_result file=%s trigger=%s result=%s",
            tostring(file), tostring(trigger), tostring(result)))
        return
    end
    emit(string.format(
        "Syncery[DEBUG] orchestrator_result file=%s trigger=%s ok=%s error=%s "
        .. "annotations_pulled=%s annotations_pushed=%s render_applied=%s "
        .. "conflicts_merged=%s tombstones_compacted=%s annotations_after=%s",
        tostring(file), tostring(trigger), tostring(result.ok), tostring(result.error),
        tostring(result.annotations_pulled), tostring(result.annotations_pushed),
        tostring(result.render_applied), tostring(result.conflicts_merged),
        tostring(result.tombstones_compacted), tostring(result.annotations_after)))
end

--- main.lua checkRemote ── 3a: was a reload-handoff slot present this tick?
function impl.reload_handoff_check(file, handoff)
    if handoff == nil then
        emit(string.format("Syncery[DEBUG] reload_handoff_check file=%s handoff=none", tostring(file)))
        return
    end
    emit(string.format(
        "Syncery[DEBUG] reload_handoff_check file=%s handoff_device_id=%s",
        tostring(file), tostring(handoff.device_id)))
end

--- main.lua checkRemote: result of _promptJump, for BOTH the handoff path
--- (path="handoff") and the normal pick_jump_target path (path="normal").
--- `shown` true means a jump bar/dialog was actually raised.
function impl.jump_shown(file, path, device_id, shown)
    bump(shown and "jump_shown_true" or "jump_shown_false")
    emit(string.format(
        "Syncery[DEBUG] jump_shown file=%s path=%s device_id=%s shown=%s",
        tostring(file), tostring(path), tostring(device_id), tostring(shown)))
end

--- main.lua checkRemote: the toggle gate deciding whether MtimeGate.run
--- (and therefore _syncBookViaOrchestrator) is even reached this tick.
function impl.mtime_gate_toggle_check(file, sync_annotations, sync_metadata, sync_render_settings)
    emit(string.format(
        "Syncery[DEBUG] mtime_gate_toggle_check file=%s sync_annotations=%s sync_metadata=%s sync_render_settings=%s gate_open=%s",
        tostring(file), tostring(sync_annotations), tostring(sync_metadata), tostring(sync_render_settings),
        tostring(sync_annotations or sync_metadata or sync_render_settings)))
end

-- ----------------------------------------------------------------------------
-- Cloud push/pull/bidirectional-sync layer (plugin_sync.lua do_cloud_upload,
-- cloud/sync_service_adapter.lua's merge callbacks, teardown.lua's
-- close-time push, and the various scheduling call-sites in main.lua).
-- ----------------------------------------------------------------------------

--- plugin_sync.lua do_cloud_upload: entry, before the reachability gate.
function impl.do_cloud_upload_entry(file, force_sync)
    bump("do_cloud_upload_calls")
    emit(string.format(
        "Syncery[DEBUG] do_cloud_upload_entry file=%s force_sync=%s",
        tostring(file), tostring(force_sync)))
end

--- plugin_sync.lua do_cloud_upload: per-kind (progress/annotations) decision
--- -- did Fix 4's push-content-cache recognize this as already-sent
--- (cache_hit=true, will be skipped) or does it need to go out?
function impl.do_cloud_upload_entry_decision(file, kind, is_real_content, use_skip_cache, cache_hit)
    bump("push_" .. tostring(kind) .. "_" .. (cache_hit and "skipped_cache_hit" or "included"))
    emit(string.format(
        "Syncery[DEBUG] do_cloud_upload_entry_decision file=%s kind=%s is_real_content=%s use_skip_cache=%s cache_hit=%s -> %s",
        tostring(file), tostring(kind), tostring(is_real_content), tostring(use_skip_cache),
        tostring(cache_hit), cache_hit and "SKIP" or "INCLUDE"))
end

--- plugin_sync.lua do_cloud_upload: the final entries-count decision --
--- entry_count==0 means the whole dispatch (push_cloud_files/cloud_sync)
--- is skipped entirely this call.
function impl.do_cloud_upload_dispatch_decision(file, entry_count, force_sync)
    bump(entry_count == 0 and "do_cloud_upload_skipped_empty" or "do_cloud_upload_dispatched")
    emit(string.format(
        "Syncery[DEBUG] do_cloud_upload_dispatch_decision file=%s entry_count=%d force_sync=%s -> %s",
        tostring(file), entry_count, tostring(force_sync),
        entry_count == 0 and "SKIP DISPATCH (nothing to push/pull)" or "DISPATCH"))
end

--- plugin_sync.lua do_cloud_upload: the ACTUAL push_cloud_files call, with
--- which kinds are riding in this dispatch.
function impl.push_cloud_files_call(file, kinds_pushed)
    emit(string.format(
        "Syncery[DEBUG] push_cloud_files_call file=%s kinds=%s",
        tostring(file), table.concat(kinds_pushed or {}, ",")))
end

--- plugin_sync.lua do_cloud_upload: Fix 4's push-content-cache write after
--- a successful dispatch (the hash THIS device will compare against next
--- time it considers pushing this book again).
function impl.push_cache_written(file, cache_dirty, progress_hash, annotations_hash)
    emit(string.format(
        "Syncery[DEBUG] push_cache_written file=%s cache_dirty=%s progress_hash=%s annotations_hash=%s",
        tostring(file), tostring(cache_dirty), tostring(progress_hash), tostring(annotations_hash)))
end

--- main.lua _doCloudUpload: the return value of do_cloud_upload for THIS
--- specific call-site (scheduled open-moment pull, resume pull, etc.) --
--- "dispatched" / "skipped" / "deferred" / nil (skipped for an internal
--- reason with no explicit tag).
function impl.do_cloud_upload_result(file, result)
    emit(string.format(
        "Syncery[DEBUG] do_cloud_upload_result file=%s result=%s",
        tostring(file), tostring(result)))
end


--- Cloud reachability gate snapshot: records why an upload was allowed/deferred.
function impl.cloud_reachability_gate(result, network_mgr_ok, link_connected, verdict, verdict_age, ttl, probing, cached_host, cached_ip, cached_port)
    emit(string.format(
        "Syncery[DEBUG] cloud_reachability_gate result=%s network_mgr_ok=%s link_connected=%s verdict=%s verdict_age=%s ttl=%s probing=%s cached_host=%s cached_ip=%s cached_port=%s",
        tostring(result), tostring(network_mgr_ok), tostring(link_connected), tostring(verdict),
        tostring(verdict_age), tostring(ttl), tostring(probing), tostring(cached_host),
        tostring(cached_ip), tostring(cached_port)))
end

--- Non-blocking TCP probe lifecycle and result.
function impl.cloud_reachability_probe(event, cached_host, cached_ip, cached_port, probing, verdict, detail)
    emit(string.format(
        "Syncery[DEBUG] cloud_reachability_probe event=%s host=%s ip=%s port=%s probing=%s verdict=%s detail=%s",
        tostring(event), tostring(cached_host), tostring(cached_ip), tostring(cached_port),
        tostring(probing), tostring(verdict), tostring(detail)))
end

--- Summarize a progress-shape ({entries=...}) or annotation-envelope-shape
--- ({annotations=..., metadata=..., render_settings=...}) state table for
--- logging: counts per top-level section, without dumping full content.
local function summarize_state(t)
    if type(t) ~= "table" then return tostring(t) end
    local parts = {}
    for _, section in ipairs({"entries", "annotations", "metadata", "render_settings"}) do
        if t[section] ~= nil then
            local n = 0
            if type(t[section]) == "table" then
                for _ in pairs(t[section]) do n = n + 1 end
            end
            parts[#parts + 1] = section .. "=" .. n
        end
    end
    if #parts == 0 then return "{}" end
    return "{" .. table.concat(parts, " ") .. "}"
end

--- sync_service_adapter.lua make_progress/annotation_sync_callback: state
--- snapshot right after the 3-way merge, before either write. kind is
--- "progress" or "annotations".
function impl.merge_callback_state(kind, local_file, local_state, anc_state, income_state, merged)
    emit(string.format(
        "Syncery[DEBUG] merge_callback_state kind=%s local_file=%s local=%s ancestor=%s income=%s merged=%s",
        tostring(kind), tostring(local_file), summarize_state(local_state),
        summarize_state(anc_state), summarize_state(income_state), summarize_state(merged)))
end

--- sync_service_adapter.lua make_progress/annotation_sync_callback: the
--- write results for local_file and canonical_path. wreason/creason come
--- straight from JsonStore.write's second return value -- "unchanged"
--- means THAT file's bytes already matched and the write was skipped
--- (mtime NOT bumped); anything else (nil, or an error tag on failure
--- paths not reached here since those abort earlier) means it wrote.
function impl.merge_callback_write(kind, local_file, canonical_path, wreason, creason)
    local canonical_changed = creason ~= "unchanged" and creason ~= "no_canonical_path"
    bump("canonical_" .. tostring(kind) .. "_" .. (canonical_changed and "CHANGED" or "unchanged"))
    emit(string.format(
        "Syncery[DEBUG] merge_callback_write kind=%s local_file=%s wrote_local=%s canonical_path=%s wrote_canonical=%s",
        tostring(kind), tostring(local_file), tostring(wreason ~= "unchanged"),
        tostring(canonical_path), tostring(canonical_changed)))
end

--- main.lua onReaderReady's scheduled "_open_cloud_pull" callback actually
--- firing (2.5s after open), for whichever book is current at that moment.
function impl.scheduled_open_cloud_pull_fired(file)
    bump("scheduled_open_cloud_pull_fired_count")
    emit(string.format("Syncery[DEBUG] scheduled_open_cloud_pull_fired file=%s", tostring(file)))
end

--- plugin_sync.lua schedule_cloud_upload: a debounced cloud upload got
--- (re)armed for this book, delay seconds out (autosave-triggered, during
--- active reading -- distinct from the one-shot open-moment pull).
function impl.cloud_upload_scheduled(file, delay)
    bump("cloud_upload_scheduled_count")
    emit(string.format(
        "Syncery[DEBUG] cloud_upload_scheduled file=%s delay=%s", tostring(file), tostring(delay)))
end

--- main.lua _save: the toggle gate deciding whether THIS save cycle even
--- attempts _syncBookViaOrchestrator (annotations/metadata/render path;
--- progress has its own separate path).
function impl.save_orchestrator_gate(file, trigger, sync_annotations, sync_metadata, sync_render_settings)
    emit(string.format(
        "Syncery[DEBUG] save_orchestrator_gate file=%s trigger=%s sync_annotations=%s sync_metadata=%s sync_render_settings=%s gate_open=%s",
        tostring(file), tostring(trigger), tostring(sync_annotations), tostring(sync_metadata),
        tostring(sync_render_settings), tostring(sync_annotations or sync_metadata or sync_render_settings)))
end

--- syncery_lifecycle/teardown.lua Teardown.flush Step 3: the close/suspend
--- time PluginSync.pushOpenedBooks call, bounded to this one book.
function impl.teardown_push_opened_books(file, trigger)
    emit(string.format(
        "Syncery[DEBUG] teardown_push_opened_books file=%s trigger=%s", tostring(file), tostring(trigger)))
end

-- ----------------------------------------------------------------------------
-- Sync Now button flow: .opened worklist, manifest generation/upload/
-- download, prefetch-candidate scan, and the Phase 1 (push) / Phase 2
-- (manifest-diff pull) split, all in plugin_sync.lua's pushOpenedBooks and
-- sync_all. Note: syncery_transports/cloud/list.lua's generateManifest/
-- uploadManifest/downloadManifest already have their own logger.info calls
-- covering start/ok/failed for each -- no separate hook needed there.
-- ----------------------------------------------------------------------------

--- pushOpenedBooks: the .opened worklist as read at entry.
function impl.opened_file_read(path, opened_count, only_book)
    emit(string.format(
        "Syncery[DEBUG] opened_file_read path=%s opened_count=%d only_book=%s",
        tostring(path), opened_count, tostring(only_book)))
end

--- pushOpenedBooks: per-book push attempt outcome (Fix 1's
--- consecutive-failure-delta check for "did dispatched actually fail").
function impl.push_opened_books_book_result(
        book, i, total, ok, status, failures_before, failures_after, push_actually_failed)
    emit(string.format(
        "Syncery[DEBUG] push_opened_books_book_result book=%s %d/%d ok=%s status=%s "
        .. "failures_before=%s failures_after=%s push_actually_failed=%s",
        tostring(book), i, total, tostring(ok), tostring(status),
        tostring(failures_before), tostring(failures_after), tostring(push_actually_failed)))
end

--- pushOpenedBooks: final tally + .opened rewrite.
function impl.push_opened_books_done(succeeded_count, failed_count, remaining_count)
    emit(string.format(
        "Syncery[DEBUG] push_opened_books_done succeeded=%d failed=%d remaining_in_opened=%d",
        succeeded_count, failed_count, remaining_count))
end

--- sync_all: entry -- did THIS call actually start, or was Sync Now already
--- running (re-entrancy guard)?
function impl.sync_all_entry(started, skip_reason)
    bump(started and "sync_all_started" or "sync_all_skipped")
    emit(string.format(
        "Syncery[DEBUG] sync_all_entry started=%s skip_reason=%s",
        tostring(started), tostring(skip_reason)))
end

--- sync_all: Phase 1 (push) done -- which book_ids were just pushed, so
--- Phase 2's manifest-diff loop knows to exclude them (Fix 2).
function impl.sync_all_phase1_done(just_pushed_file_count, just_pushed_book_ids)
    emit(string.format(
        "Syncery[DEBUG] sync_all_phase1_done just_pushed_files=%d just_pushed_book_ids=%s",
        just_pushed_file_count, table.concat(just_pushed_book_ids or {}, ",")))
end

--- sync_all: manifest generated for THIS device (mode is "cloud_storage_plus"
--- or "fallback") -- and whether the upload was skipped because the cache
--- (.manifest_cache) already matched (nothing changed locally since last
--- Sync Now).
function impl.manifest_generated(mode, file_count, files_hash, cached_hash, skip_upload)
    emit(string.format(
        "Syncery[DEBUG] manifest_generated mode=%s file_count=%d files_hash=%s cached_hash=%s skip_upload=%s",
        tostring(mode), file_count, tostring(files_hash), tostring(cached_hash), tostring(skip_upload)))
end

--- sync_all (Cloud Storage+): the cloud directory listing result that
--- feeds both the prefetch-candidate scan and the peer-manifest discovery.
function impl.list_folder_result(ok, entry_count)
    emit(string.format(
        "Syncery[DEBUG] list_folder_result ok=%s entry_count=%d", tostring(ok), entry_count))
end

--- sync_all: how many never-opened-on-this-device books were found as
--- prefetch candidates this pass.
function impl.prefetch_candidates_found(count)
    emit(string.format("Syncery[DEBUG] prefetch_candidates_found count=%d", count))
end

-- apply_staged_prefetch: entry guards. safe_id/file_type_synced both being
-- true is required for the migration to even attempt anything -- if either
-- is false, the function bails out immediately and the prefetch-staged
-- files are NEVER moved, remaining in cloud_staging/prefetch/ forever
-- (which is exactly what would make a Booklist/Progress Browser/Annotation
-- Browser row never disappear).
function impl.apply_staged_prefetch_entry(book_id, book_file, safe_id, file_type_synced)
    emit(string.format(
        "Syncery[DEBUG] apply_staged_prefetch_entry book_id=%s book_file=%s safe_id=%s file_type_synced=%s",
        tostring(book_id), tostring(book_file), tostring(safe_id), tostring(file_type_synced)))
end

-- apply_staged_prefetch: per-kind (progress/annotations) decision. The move
-- only happens when sync_enabled=true, dst_path is non-nil, dst does NOT
-- already exist, and src DOES exist. dst_exists=true means the migration
-- is silently skipped for THIS kind on THIS call (canonical already has
-- something there) -- src stays in prefetch/ untouched in that case, which
-- would also explain a persistent stale row if this keeps happening on
-- every open.
function impl.apply_staged_prefetch_kind_check(book_id, kind, sync_enabled, has_dst_path, dst_exists, src_exists)
    emit(string.format(
        "Syncery[DEBUG] apply_staged_prefetch_kind_check book_id=%s kind=%s sync_enabled=%s has_dst_path=%s dst_exists=%s src_exists=%s",
        tostring(book_id), tostring(kind), tostring(sync_enabled),
        tostring(has_dst_path), tostring(dst_exists), tostring(src_exists)))
end

-- apply_staged_prefetch: final outcome for this call. Both false means
-- nothing was migrated this time -- if the prefetch files are STILL in
-- cloud_staging/prefetch/ after this consistently (check
-- apply_staged_prefetch_kind_check's src_exists on the NEXT open of the
-- same book), that is the confirmed root cause of a row that never clears.
function impl.apply_staged_prefetch_result(book_id, applied_progress, applied_annotations)
    emit(string.format(
        "Syncery[DEBUG] apply_staged_prefetch_result book_id=%s applied_progress=%s applied_annotations=%s",
        tostring(book_id), tostring(applied_progress), tostring(applied_annotations)))
end

--- sync_all: per-candidate, per-kind staleness check -- does the staged
--- prefetch copy's size already match the listing's reported size (skip),
--- or does it need a fresh download (stale)?
function impl.prefetch_staleness_check(book_id, kind, staged_size, entry_filesize, stale)
    emit(string.format(
        "Syncery[DEBUG] prefetch_staleness_check book_id=%s kind=%s staged_size=%s entry_filesize=%s stale=%s",
        tostring(book_id), tostring(kind), tostring(staged_size), tostring(entry_filesize), tostring(stale)))
end

--- sync_all: the actual prefetch download+validate outcome for a stale
--- candidate.
function impl.prefetch_download_result(book_id, kind, ok_dl, err_dl)
    emit(string.format(
        "Syncery[DEBUG] prefetch_download_result book_id=%s kind=%s ok=%s err=%s",
        tostring(book_id), tostring(kind), tostring(ok_dl), tostring(err_dl)))
end

--- sync_all: per-peer downloadManifest outcome (Phase 2's peer-discovery
--- loop) -- did we get a manifest back, and how many files does it list?
function impl.download_manifest_result(device_id, got_manifest, file_count)
    emit(string.format(
        "Syncery[DEBUG] download_manifest_result device_id=%s got_manifest=%s file_count=%d",
        tostring(device_id), tostring(got_manifest), file_count))
end

--- sync_all: per-book manifest-hash-diff decision -- "changed" means it
--- goes into this pass's sync_changed dispatch; "excluded_just_pushed" is
--- Fix 2's dedup; "unchanged" means the hashes already matched.
function impl.manifest_diff_book(book_id, my_hash, remote_hash, decision)
    emit(string.format(
        "Syncery[DEBUG] manifest_diff_book book_id=%s my_hash=%s remote_hash=%s decision=%s",
        tostring(book_id), tostring(my_hash), tostring(remote_hash), tostring(decision)))
end

--- sync_all: Phase 2 summary right before dispatching (or skipping) the
--- changed-books sync loop.
function impl.sync_all_phase2_summary(total_changed)
    emit(string.format("Syncery[DEBUG] sync_all_phase2_summary total_changed=%d", total_changed))
end

--- sync_all / sync_changed / _sync_fallback: per-book forced (force_sync=
--- true) do_cloud_upload dispatch outcome for a book the manifest diff
--- flagged as changed.
function impl.sync_changed_book_result(book_id, book_path, i, total, ok, result)
    emit(string.format(
        "Syncery[DEBUG] sync_changed_book_result book_id=%s path=%s %d/%d ok=%s result=%s",
        tostring(book_id), tostring(book_path), i, total, tostring(ok), tostring(result)))
end

-- ----------------------------------------------------------------------------
-- App/device lifecycle transitions (syncery_lifecycle/init.lua): suspend,
-- resume (with its online/offline reconnect-poll branching), power-off,
-- quit, and the single teardown() entry point all four funnel through.
-- Answers "how often, and why" for cloud activity tied to the DEVICE's
-- lifecycle rather than a single book's open/close.
-- ----------------------------------------------------------------------------

--- Generic lifecycle transition marker -- event is one of "on_suspend",
--- "on_resume", "on_power_off", "on_quit". detail carries event-specific
--- context (e.g. on_resume's tries_left) as a string, or nil.
function impl.lifecycle_event(event, detail)
    bump("lifecycle_" .. tostring(event))
    emit(string.format(
        "Syncery[DEBUG] lifecycle_event event=%s detail=%s", tostring(event), tostring(detail)))
end

--- on_resume, online branch: is a cloud pull expected, and is the resume
--- jump-prompt fallback on the short (RESUME_RECHECK_GRACE) or long
--- (RESUME_RECHECK_PULL_FALLBACK) schedule?
function impl.resume_online_branch(pull_expected, pull_prompt)
    bump("resume_online")
    emit(string.format(
        "Syncery[DEBUG] resume_online_branch pull_expected=%s pull_prompt=%s",
        tostring(pull_expected), tostring(pull_prompt)))
end

--- on_resume, offline branch: still polling for reconnect (tries_left > 0)
--- or giving up (tries_left <= 0, no further re-check this wake).
function impl.resume_offline_branch(tries_left)
    bump("resume_offline_poll")
    emit(string.format(
        "Syncery[DEBUG] resume_offline_branch tries_left=%d %s",
        tries_left, tries_left <= 0 and "(giving up this wake)" or "(will re-probe)"))
end

--- syncery_lifecycle/init.lua Lifecycle:teardown -- the SINGLE call-site all
--- four transitions (close/suspend/power_off/quit) funnel through, with the
--- opts flags that distinguish them (destroying / suspend).
function impl.teardown_entry(destroying, suspend)
    emit(string.format(
        "Syncery[DEBUG] teardown_entry destroying=%s suspend=%s", tostring(destroying), tostring(suspend)))
end

-- ----------------------------------------------------------------------------
-- Page-turning / autosave debounce (main.lua onPageUpdate/onPosUpdate ->
-- scheduleAutoSave -> syncery_lifecycle/init.lua schedule_auto_save). Page
-- turns themselves are silent-tallied ONLY (no per-turn log line -- a fast
-- reader can generate dozens a minute; the interesting question is whether
-- turning pages actually RESULTS in an autosave attempt, not each turn).
-- ----------------------------------------------------------------------------

--- main.lua onPageUpdate/onPosUpdate: silent tally only, kind is "page" or
--- "pos". No logger.info per call -- see session_end for the accumulated
--- count instead.
function impl.page_turn_tally(kind)
    bump("page_turn_" .. tostring(kind))
end

--- schedule_auto_save: did this page-turn's debounce (re)arm the autosave
--- timer, or was it blocked outright (destroyed / blocking_autosave /
--- inside the post-jump blocking_autosave_until window)?
function impl.autosave_scheduled(blocked, destroyed, blocking_autosave, blocking_autosave_until)
    bump(blocked and "autosave_schedule_blocked" or "autosave_schedule_armed")
    emit(string.format(
        "Syncery[DEBUG] autosave_scheduled blocked=%s destroyed=%s blocking_autosave=%s blocking_autosave_until=%s",
        tostring(blocked), tostring(destroyed), tostring(blocking_autosave), tostring(blocking_autosave_until)))
end

--- schedule_auto_save's debounced timer actually firing: fire_ok means it
--- proceeded to plugin:_autoSave(true); false means a state transition
--- (sync_state left idle, or blocking_autosave (re)armed) between the
--- timer's arm and its fire suppressed it after all.
function impl.autosave_fired(fire_ok, sync_state, blocking_autosave)
    bump(fire_ok and "autosave_fired_true" or "autosave_fired_blocked_at_fire")
    emit(string.format(
        "Syncery[DEBUG] autosave_fired fire_ok=%s sync_state=%s blocking_autosave=%s",
        tostring(fire_ok), tostring(sync_state), tostring(blocking_autosave)))
end

-- ----------------------------------------------------------------------------
-- Build the PUBLIC, always-populated _G.SYNCERY_DEBUG_LOG table: one thin
-- wrapper per impl function, generated in a single loop so the
-- enabled-check lives in exactly one place rather than being repeated at
-- the top of every impl function above. A disabled call costs one
-- upvalue read and a branch; nothing past that runs.
-- ----------------------------------------------------------------------------
_G.SYNCERY_DEBUG_LOG = {}
for name, fn in pairs(impl) do
    _G.SYNCERY_DEBUG_LOG[name] = function(...)
        if enabled then return fn(...) end
    end
end


-- ----------------------------------------------------------------------------
-- Monkey-patch MtimeGate.run in place (mtime_gate.lua itself is untouched).
-- Installed UNCONDITIONALLY, once, regardless of the enabled flag's value
-- at load time (it can be toggled on later without a restart) -- but
-- original_run always runs either way; only the bump/emit logging below
-- respects the enabled flag, exactly like every impl function above.
-- ----------------------------------------------------------------------------
local ok, MtimeGate = pcall(require, "syncery_ann/mtime_gate")
if ok and MtimeGate and type(MtimeGate.run) == "function" and not MtimeGate._syncery_debug_wrapped then
    local original_run = MtimeGate.run
    MtimeGate.run = function(current_mtime, cache, do_sync, read_mtime)
        local new_cache, did_sync = original_run(current_mtime, cache, do_sync, read_mtime)
        if enabled then
            local should = MtimeGate.should_sync(current_mtime, cache)
            bump(did_sync and "mtime_gate_did_sync" or "mtime_gate_skip")
            emit(string.format(
                "Syncery[DEBUG] MtimeGate.run current_mtime=%s cache_before=%s should_sync=%s did_sync=%s cache_after=%s",
                tostring(current_mtime), tostring(cache), tostring(should),
                tostring(did_sync), tostring(new_cache)))
        end
        return new_cache, did_sync
    end
    MtimeGate._syncery_debug_wrapped = true
end


return M
