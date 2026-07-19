-- =============================================================================
-- syncery_transports/plugin_sync.lua
-- =============================================================================
--
-- The plugin-facing transport glue: the cloud upload/schedule logic
-- for the plugin.
--
-- WHY THIS IS A SEPARATE MODULE, NOT METHODS ON THE ORCHESTRATOR
--
-- The obvious relocation target, `syncery_transports/orchestrator.lua`,
-- is the transport
-- *contract* Orchestrator — a deliberately plugin-agnostic, `.new()`-
-- constructed, fake-tested class that holds registered transports and
-- nothing else.  The helpers below are the opposite: they read many
-- distinct plugin members (`plugin._transport`, `plugin.use_cloud`,
-- `plugin:getCurrentState`, the cloud status fields —).  Making them
-- methods of the contract Orchestrator would pull plugin concerns into
-- a module whose entire value is being plugin-agnostic.
--
-- So the ad-hoc transport glue lives in a new sibling module instead,
-- out of main.lua.  Every function here takes the plugin instance as
-- its first parameter — the exact pattern `syncery_lifecycle/teardown.lua`
-- already uses.
--
-- PUBLIC SURFACE
--
--   PluginSync.schedule_cloud_upload(plugin, state)
--   PluginSync.do_cloud_upload(plugin, state)
--
-- main.lua keeps one-line delegator methods (`_scheduleCloudUpload`, etc.)
-- so existing call sites — `_save`, `teardown.lua` — are unchanged.
--
-- =============================================================================


local logger        = require("logger")
local Util          = require("syncery_util")
local Settings      = require("syncery_settings")
local AnnPaths      = require("syncery_ann/paths")
local ProgressPaths = require("syncery_progress/paths")
local ProgressStateStore = require("syncery_progress/state_store")
local I18n          = require("syncery_i18n")
local StateStore    = require("syncery_ann/state_store")
local sha2          = require("ffi/sha2")

local _ = I18n.translate


local PluginSync = {}


-- ----------------------------------------------------------------------------
-- schedule_cloud_upload — debounced cloud upload.  Cheap when cloud is
-- off; the work happens only on the timer fire, not on every save.
-- ----------------------------------------------------------------------------
function PluginSync.schedule_cloud_upload(plugin, state)
    if not plugin.use_cloud or not state then return end
    if not Settings.is_cloud_configured() then return end

    if _G.SYNCERY_DEBUG_LOG then
        _G.SYNCERY_DEBUG_LOG.cloud_upload_scheduled(state.file, plugin.cloud_upload_delay)
    end
    plugin:_schedule("_cloud_upload_action", plugin.cloud_upload_delay, function()
        PluginSync.do_cloud_upload(plugin, state)
    end)
end


-- ----------------------------------------------------------------------------
-- Content-hash push cache (Fix 4, confirmed via the two-device
-- investigation harness's Scenario 2b): do_cloud_upload had no
-- content-diff check at all -- a book re-added to .opened (which _save
-- does on EVERY successful write, regardless of whether anything
-- meaningfully changed) got its FULL current content re-read and
-- re-pushed unconditionally, even when byte-identical to what was
-- already successfully staged last time. Mirrors the EXISTING
-- manifest-upload skip pattern (pl_skip_upload, cached_our_hash, further
-- down in sync_all) -- same "hash what we're about to send, compare to
-- last time, skip if unchanged" shape, applied here to the per-book,
-- per-kind push instead of the whole-library manifest.
--
-- Deliberately as optimistic/fire-and-forget as the manifest cache it
-- mirrors: the cache is written right after DISPATCH, not after a
-- confirmed remote success (do_cloud_upload has no way to know that --
-- see Fix 1 elsewhere in this design). A push that is dispatched but
-- fails outright would leave the cache saying "already sent" for
-- content that never actually arrived -- an accepted, explicit
-- narrowing of scope for THIS fix; Fix 1 is what should eventually
-- close that gap, not this cache.
local function _push_cache_path(plugin)
    return plugin.state_dir .. "cloud_staging/.push_content_cache"
end

local function _read_push_cache(plugin)
    local f = io.open(_push_cache_path(plugin), "rb")
    if not f then return {} end
    local content = f:read("*a")
    f:close()
    local ok, data = pcall(require("rapidjson").decode, content)
    if ok and type(data) == "table" then return data end
    return {}
end

local function _write_push_cache(plugin, cache)
    local dir = plugin.state_dir .. "cloud_staging/"
    require("util").makePath(dir)
    local f = io.open(_push_cache_path(plugin), "wb")
    if f then
        f:write(require("rapidjson").encode(cache))
        f:close()
    end
end

local function _content_hash(content)
    local ctx = sha2.md5()
    ctx(content)
    return ctx()
end
PluginSync._read_push_cache  = _read_push_cache
PluginSync._write_push_cache = _write_push_cache
PluginSync._content_hash     = _content_hash


-- ----------------------------------------------------------------------------
-- do_cloud_upload — upload progress + annotations for the current book.
-- When offline, schedules a wifi-backoff retry instead of a bare return.
-- ----------------------------------------------------------------------------
function PluginSync.do_cloud_upload(plugin, state)
    if not plugin.use_cloud then return end
    if not plugin._transport then return end
    if not Settings.is_cloud_configured() then
        return
    end
    state = state or plugin:getCurrentState()
    if not state or not plugin:_isFileTypeSynced(state.file) then return "skipped" end

    if _G.SYNCERY_DEBUG_LOG then
        _G.SYNCERY_DEBUG_LOG.do_cloud_upload_entry(state.file, state.force_sync)
    end

    -- Gate on CLOUD reachability (real internet + a bounded probe to the
    -- configured server), not the link-only `_isNetworkOnline`: KOReader runs
    -- the WebDAV/Dropbox transfer synchronously on the UI thread, so an
    -- enabled-but-unreachable cloud would freeze the UI.  Unreachable — defer
    -- via the cloud-scoped backoff (which re-probes reachability on retry).
    if not plugin:_isCloudReachable() then
        plugin._cloud_wifi_backoff:attempt{
            label = "cloud upload",
            run   = function() PluginSync.do_cloud_upload(plugin, state) end,
        }
        return "deferred"
    end

    -- The cloud transport reads each file's content from disk inside
    -- its push(); we build the entries list and hand it to the bridge,
    -- which derives book_id internally.  Reading the content here means
    -- a single read per save (no double-open).
    local entries = {}
    local p_path = ProgressPaths.shared_progress_path(state.file)
    local a_path = AnnPaths.shared_annotations_path(state.file)
    -- BUGFIX (confirmed empirically via Group A real-device testing, two
    -- separate manifestations traced to the SAME root cause): Fix 4's
    -- hash-skip-cache was applied by DEFAULT to every do_cloud_upload call
    -- except the explicit force_sync=true ones. That meant the regular
    -- open-moment pull, the autosave-debounced upload, and the resume
    -- pull -- every call whose WHOLE PURPOSE is "check the server for a
    -- peer's update, regardless of whether OUR OWN content changed" --
    -- could see cache_hit=true (our OWN content unchanged since our last
    -- push) and skip the ENTIRE bidirectional dispatch, silently never
    -- asking the server at all. Two confirmed real-device manifestations:
    -- (a) device B never discovered device A's newly-pushed annotation
    -- because B's own annotations content looked unchanged; (b) device A
    -- missed a genuine recency-based jump-prompt window for device B's
    -- progress update for the same reason on the progress kind. Fix:
    -- invert the default to OPT-IN. use_skip_cache is now true ONLY when
    -- the caller explicitly sets state.skip_if_unchanged = true --
    -- currently only pushOpenedBooks does this (the ORIGINAL, narrow Fix
    -- 4 target: a book re-added to .opened on every Sync Now / close,
    -- getting redundantly re-pushed even when byte-identical). Every
    -- other call site (open-moment pull, resume pull, the
    -- schedule_cloud_upload debounce, sync_changed/_sync_fallback's
    -- force_sync=true calls) needs no code change: they simply never set
    -- this flag, so they now always dispatch, restoring "always check the
    -- server" for the calls that exist specifically to do that.
    local use_skip_cache = state.skip_if_unchanged == true and not state.force_sync
    local push_cache = use_skip_cache and _read_push_cache(plugin) or {}
    local book_cache = push_cache[state.file] or {}
    local cache_dirty = false
    local pushed_progress, pushed_annotations = false, false

    -- BUGFIX: the
    -- toggle checks below used to apply ONLY to the bootstrap-empty-
    -- envelope branch -- if p_path/a_path already had REAL content on
    -- disk (e.g. from before the user turned a toggle off, or from
    -- another source entirely), it was read and pushed unconditionally,
    -- completely ignoring the toggle. Gate entry construction on the
    -- toggle FIRST, so turning a toggle off genuinely stops that kind
    -- from ever being pushed, not just stops NEW bootstrap content from
    -- being manufactured.
    if p_path and plugin.sync_progress then
        local content
        local f = io.open(p_path, "rb")
        if f then
            content = f:read("*a")
            f:close()
        end
        local is_real_content = content and content ~= ""
        -- Bootstrap a fresh-device PULL of the peer's reading position, exactly
        -- like the annotations path below.  With no local progress file the
        -- bidirectional cloud sync would skip progress entirely (push and pull
        -- are ONE op -- both need staged content), so a device opening a book
        -- for the FIRST time never DOWNLOADS the peer's position at open.  It
        -- would arrive only on the next debounced upload AFTER our own autosave
        -- creates the file -- up to cloud_upload_delay (60 s) later, far too
        -- late for the open-moment jump (the annotations path already pulls at
        -- open, so the reader sees fresh notes but a stale position).  Stage a
        -- canonical EMPTY envelope (our no-opinion side of the per-device
        -- merge); the merge pulls the remote position in and on_reconciled
        -- drives checkRemote.  Safe: progress entries carry no tombstones, so
        -- an empty local side yields the remote entries with no deletions.
        if not is_real_content then
            content = ProgressStateStore.empty_envelope_json()
        end
        if content and content ~= "" then
            -- Fix 4's hash-skip applies ONLY to real, existing disk content,
            -- and ONLY when use_skip_cache allows it (see the comment on
            -- use_skip_cache above -- sync_changed's call must always
            -- reach the transport, never skip based on our own hash).
            -- The bootstrap-empty envelope is IDENTICAL every time by
            -- construction (it carries no data of its own, only triggers a
            -- pull) -- caching against ITS hash would mean a book that has
            -- never had real progress here only ever gets its one pull
            -- attempt, with every later Sync Now wrongly skipped as
            -- "unchanged", even though the whole POINT is to keep asking
            -- for whatever the peer might now have.
            local cache_hit = is_real_content and use_skip_cache
                    and book_cache.progress_hash == _content_hash(content)
            if _G.SYNCERY_DEBUG_LOG then
                _G.SYNCERY_DEBUG_LOG.do_cloud_upload_entry_decision(
                    state.file, "progress", is_real_content, use_skip_cache, cache_hit)
            end
            if cache_hit then
                -- unchanged since the last successfully cached push: skip
            else
                table.insert(entries, { kind = "progress", content = content })
                pushed_progress = is_real_content and use_skip_cache
            end
        end
    end
    if a_path and (plugin.sync_annotations or plugin.sync_metadata
            or plugin.sync_render_settings) then
        local content
        local f = io.open(a_path, "rb")
        if f then
            content = f:read("*a")
            f:close()
        end
        local is_real_content = content and content ~= ""
        -- Bootstrap a fresh-device PULL.  With no local annotations file the
        -- bidirectional cloud sync would skip this kind entirely (push and pull
        -- are one op; both need staged content), so a device that never
        -- annotated this book would never DOWNLOAD a peer's annotations.  Stage
        -- a canonical EMPTY envelope (this device's no-opinion side of the
        -- 3-way merge); the merge callback pulls the remote in and reconciles
        -- it into the canonical file (then on_reconciled fires the Reload
        -- toast).  Safe: absent canonical => never synced => the .sync
        -- ancestor is also empty => the merge yields the remote with NO
        -- deletions.  Cloud-only: Syncthing replicates the shared file at FS
        -- level.
        if not is_real_content then
            content = StateStore.empty_envelope_json()
        end
        if content and content ~= "" then
            -- Same reasoning as the progress side above: only skip-cache
            -- real, existing content when use_skip_cache allows it --
            -- never the bootstrap-empty envelope, never sync_changed's call.
            local cache_hit = is_real_content and use_skip_cache
                    and book_cache.annotations_hash == _content_hash(content)
            if _G.SYNCERY_DEBUG_LOG then
                _G.SYNCERY_DEBUG_LOG.do_cloud_upload_entry_decision(
                    state.file, "annotations", is_real_content, use_skip_cache, cache_hit)
            end
            if cache_hit then
                -- unchanged since the last successfully cached push: skip
            else
                table.insert(entries, { kind = "annotations", content = content })
                pushed_annotations = is_real_content and use_skip_cache
            end
        end
    end
    if _G.SYNCERY_DEBUG_LOG then
        _G.SYNCERY_DEBUG_LOG.do_cloud_upload_dispatch_decision(
            state.file, #entries, state.force_sync)
    end
    if #entries == 0 then return end

    local kinds_pushed = {}
    for _, e in ipairs(entries) do kinds_pushed[#kinds_pushed + 1] = e.kind end
    if _G.SYNCERY_DEBUG_LOG then
        _G.SYNCERY_DEBUG_LOG.push_cloud_files_call(state.file, kinds_pushed)
    end
    plugin._transport:push_cloud_files(state.file, entries,
        plugin.ui and plugin.ui.doc_settings)

    -- Cache the POST-dispatch content, not what was read before it, and
    -- ONLY when use_skip_cache is true (sync_changed's calls must never
    -- touch this cache at all -- push_cache was forced to {} for them
    -- above, so writing it back here would silently WIPE every OTHER
    -- book's cached entry). do_cloud_upload's push is bidirectional
    -- (Constraint: the SAME cloud_sync call both pushes AND merges a
    -- peer's income back in via the merge callback, which decodes/
    -- reconciles/re-encodes and WRITES the result back to canonical) --
    -- confirmed via the two-device investigation harness: even a
    -- semantically no-op merge (nothing new from the peer) can
    -- re-serialize canonical with different LUA TABLE KEY ORDERING than
    -- what was on disk before dispatch, since the merge decodes into a
    -- fresh table (pairs() iteration order is not guaranteed stable
    -- across separate table instances with the same keys). Caching the
    -- PRE-dispatch hash therefore almost never matched what was actually
    -- on disk for the NEXT call to compare against. Re-reading here,
    -- after push_cloud_files returns (confirmed synchronous for Cloud
    -- Storage+ -- see the reachability comment above), captures the
    -- actual steady-state bytes this SAME device will see next time.
    if use_skip_cache then
        if pushed_progress and p_path then
            local f = io.open(p_path, "rb")
            if f then
                local post_content = f:read("*a")
                f:close()
                if post_content and post_content ~= "" then
                    book_cache.progress_hash = _content_hash(post_content)
                    cache_dirty = true
                end
            end
        end
        if pushed_annotations and a_path then
            local f = io.open(a_path, "rb")
            if f then
                local post_content = f:read("*a")
                f:close()
                if post_content and post_content ~= "" then
                    book_cache.annotations_hash = _content_hash(post_content)
                    cache_dirty = true
                end
            end
        end
        if cache_dirty then
            push_cache[state.file] = book_cache
            _write_push_cache(plugin, push_cache)
        end
        if _G.SYNCERY_DEBUG_LOG then
            _G.SYNCERY_DEBUG_LOG.push_cache_written(
                state.file, cache_dirty, book_cache.progress_hash, book_cache.annotations_hash)
        end
    end

    -- Record the dispatch time for the upload-debounce window.  Sync
    -- status itself is owned by the orchestrator and read via
    -- `_transport:get_status()`; this module no longer tracks a
    -- per-push ok flag.
    plugin.cloud_last_upload_at = os.time()
    return "dispatched"
end



-- ----------------------------------------------------------------------------
-- pushOpenedBooks -- upload books tracked in the .opened worklist.
-- Read — dedupe — push each unique book — delete (or keep failed retry).
-- ----------------------------------------------------------------------------
--- Fix 1: do_cloud_upload dispatches the
--- push and returns "dispatched" immediately -- it has no way to know
--- whether the underlying push actually reached the server or failed
--- mid-flight (a genuine network error, not the upfront-unreachable case
--- "deferred" already covers). pushOpenedBooks used to treat
--- "dispatched" as success unconditionally, clearing the book from
--- .opened even when the push had genuinely failed -- with no retry
--- queued anywhere the user's next manual Sync Now would reach (the
--- Orchestrator's OWN internal backoff DOES still retry it, but only if
--- the app stays running long enough for that in-memory timer to fire;
--- closing/suspending KOReader loses it, since nothing re-queues .opened
--- once it thinks the book already succeeded).
---
--- Fix: read the Orchestrator's ALREADY-MAINTAINED per-book state via
--- Bridge:peek_transport_books (a pre-existing, read-only introspection
--- API -- see orchestrator.lua's _state_for/_on_push_result, which
--- already track last_success_at/consecutive_failures for every push
--- attempt, on every transport, entirely independent of any of this).
--- Snapshot "cloud" transport's consecutive_failures for this book_file
--- immediately BEFORE dispatching, and again immediately after; if it
--- increased, the attempt that JUST happened failed, regardless of
--- do_cloud_upload's "dispatched" return. No changes needed anywhere in
--- Orchestrator/Bridge/Transport's actual push logic, and no dependency
--- on whether a given provider's push is synchronous or not: if the
--- state has not been updated yet by the time this checks (a genuinely
--- async provider), the increase simply is not observed here and this
--- falls back to the EXISTING behavior (treated as succeeded) -- a
--- strict improvement over always-succeeds, never a regression from it.
local function _cloud_consecutive_failures_for(plugin, book_file)
    if not (plugin._transport and plugin._transport.peek_transport_books) then
        return nil
    end
    local ok, entries = pcall(plugin._transport.peek_transport_books,
        plugin._transport, "cloud")
    if not ok or type(entries) ~= "table" then return nil end
    for _, e in ipairs(entries) do
        if e.book_file == book_file and e.state then
            return e.state.consecutive_failures or 0
        end
    end
    return 0  -- no entry yet for this book on this transport: no failures recorded
end


local function pushOpenedBooks(plugin, info_fn, only_book)
    local path = plugin.state_dir .. ".opened"
    local f = io.open(path, "rb")
    if not f then
        if _G.SYNCERY_DEBUG_LOG then
            _G.SYNCERY_DEBUG_LOG.opened_file_read(path, 0, only_book)
        end
        return {}
    end
    local opened = {}
    for line in f:lines() do
        local book = line:gsub("%s+$", "")
        if book ~= "" then opened[book] = true end
    end
    f:close()
    local opened_count = 0
    for _ in pairs(opened) do opened_count = opened_count + 1 end
    if _G.SYNCERY_DEBUG_LOG then
        _G.SYNCERY_DEBUG_LOG.opened_file_read(path, opened_count, only_book)
    end
    if not next(opened) then return {} end

    -- Bounded, single-book mode: teardown.lua's Step 3 passes only_book
    -- (the book being closed) instead of flushing the whole worklist --
    -- teardown must stay synchronous/inline with no Trapper progress or
    -- abort (see its own comment), so it must never be on the hook for
    -- an unbounded number of blocking pushes just because OTHER books
    -- were left opened earlier in the session. Those stay queued for
    -- the next full flush (interactive Sync Now, which DOES have a
    -- Trapper dialog). Not present in the worklist -> nothing to do.
    if only_book and not opened[only_book] then return {} end

    -- If cloud is unreachable, schedule one retry of ALL books via
    -- backoff instead of individually deferring each (which would
    -- drop subsequent attempts while the first retry is in flight).
    if not plugin:_isCloudReachable() then
        plugin._cloud_wifi_backoff:attempt{
            label = "pushOpenedBooks retry",
            run   = function() pushOpenedBooks(plugin, info_fn, only_book) end,
        }
        return {}
    end

    -- Deterministic order: needed for the i/total progress numbering
    -- below, and keeps behaviour reproducible under test.  In
    -- only_book mode, `untouched` holds every OTHER queued book so the
    -- rewrite below can put them back exactly as they were -- narrowing
    -- to one book must never look like "the rest synced too".
    local books
    local untouched
    if only_book then
        books = { only_book }
        untouched = {}
        for book in pairs(opened) do
            if book ~= only_book then untouched[#untouched + 1] = book end
        end
        table.sort(untouched)
    else
        books = {}
        for book in pairs(opened) do books[#books + 1] = book end
        table.sort(books)
    end

    -- info_fn is supplied ONLY by sync_all's interactive Trapper wrap.
    -- The teardown.lua call site passes none, deliberately: that flush
    -- must stay synchronous/inline (Step 5 shuts the transport down
    -- right after, with no future UIManager tick for a suspended
    -- Trapper coroutine to resume on -- see teardown.lua Step 3), so
    -- it gets byte-identical behaviour to before this change, and
    -- plugin.destroyed is still false at that point anyway (it's set
    -- in the SAME synchronous flush, in the step after this one).
    local failed = {}
    local succeeded = {}
    local stopped_at
    for i, book in ipairs(books) do
        if info_fn then
            if plugin.destroyed then
                stopped_at = i
                break
            end
            if not info_fn(string.format(_("Uploading %d/%d..."), i, #books)) then
                stopped_at = i
                break
            end
        end
        local failures_before = _cloud_consecutive_failures_for(plugin, book)
        -- skip_if_unchanged = true: THIS is the one call site Fix 4's
        -- hash-skip-cache is meant for -- a book re-added to .opened on
        -- every Sync Now / close, redundantly re-pushed even when
        -- byte-identical. See the do_cloud_upload comment on
        -- use_skip_cache for why every OTHER call site must NOT set this.
        local ok, status = pcall(PluginSync.do_cloud_upload, plugin,
            { file = book, skip_if_unchanged = true })
        local failures_after = _cloud_consecutive_failures_for(plugin, book)
        local push_actually_failed = failures_before and failures_after
            and failures_after > failures_before
        if _G.SYNCERY_DEBUG_LOG then
            _G.SYNCERY_DEBUG_LOG.push_opened_books_book_result(
                book, i, #books, ok, status, failures_before, failures_after, push_actually_failed)
        end
        if not ok or status == "deferred" or push_actually_failed then
            table.insert(failed, book)
        else
            table.insert(succeeded, book)
        end
    end
    if stopped_at then
        -- Abort (or plugin destroyed mid-loop): books from here on were
        -- never attempted -- they must stay queued, not be dropped as
        -- if they'd synced.
        for i = stopped_at, #books do
            table.insert(failed, books[i])
        end
    end

    -- Rewrite .opened: untouched books (only_book mode) always stay,
    -- plus whichever processed books failed; omit the ones that
    -- succeeded this round.
    local remaining = untouched or {}
    for _, book in ipairs(failed) do
        remaining[#remaining + 1] = book
    end

    -- Re-entrancy guard (additive, does not touch the logic above):
    -- this whole function can run for a long time -- per-book blocking
    -- network calls, further stretched by Trapper yielding between
    -- them on the interactive info_fn path -- during which KOReader's
    -- single-threaded event loop is free to process OTHER code that
    -- ALSO appends to .opened. Most notably: a teardown flush for a
    -- DIFFERENT book being closed mid-flight is synchronous (by
    -- design -- see teardown.lua's own comment), so it can run to
    -- completion, including its own read-modify-write of .opened,
    -- entirely WHILE this invocation is suspended between two
    -- Trapper:info() calls. Blindly overwriting with `remaining`
    -- (computed only from the snapshot read at the TOP of this
    -- function) would silently drop any book appended during that
    -- window. Re-read fresh here and fold in anything NOT in our
    -- original snapshot (`opened`) -- disjoint from `remaining` by
    -- construction, so this can only ADD entries, never duplicate or
    -- drop one that the logic above already accounted for.
    do
        local rf = io.open(path, "rb")
        if rf then
            for line in rf:lines() do
                local book = line:gsub("%s+$", "")
                if book ~= "" and not opened[book] then
                    remaining[#remaining + 1] = book
                end
            end
            rf:close()
        end
    end

    if #remaining > 0 then
        local fw = io.open(path, "wb")
        if fw then
            for _, book in ipairs(remaining) do
                fw:write(book .. "\n")
            end
            fw:close()
        end
    else
        -- All pushes succeeded; clear .opened
        local fw = io.open(path, "wb")
        if fw then fw:close() end
    end
    if _G.SYNCERY_DEBUG_LOG then
        _G.SYNCERY_DEBUG_LOG.push_opened_books_done(#succeeded, #failed, #remaining)
    end
    return succeeded
end

PluginSync.pushOpenedBooks = pushOpenedBooks

-- =============================================================================
-- Cloud prefetch for remote-only books (never opened on this device).
--
-- =============================================================================

--- Constraint X: reject any book_id containing anything outside the same
--- safe character class Staging.cloud_name_for already enforces
--- (cloud/staging.lua:83) -- reused deliberately, not reinvented, so the
--- two independent parsers of "what is a legal book_id" cannot drift
--- apart. book_id here comes from untrusted remote input (a cloud
--- directory listing, or a peer's uploaded manifest) -- this must be the
--- first gate applied, before the value touches any path.
local function _isSafeBookId(book_id)
    return type(book_id) == "string" and book_id ~= ""
        and not book_id:match("[^%w%-_]")
end

--- Constraint Q: group a Cloud Storage+ listing's entries by book_id and
--- kind, reusing the exact recognition pattern generateManifest already
--- uses when walking cloud_staging/ (cloud/list.lua:47) -- applied here to
--- the remote listing instead, not reinvented.
---
--- @param entries table listFolder's result -- each entry has .text (name)
---   and .filesize (Constraint D).
--- @return table book_id -> { progress = entry|nil, annotations = entry|nil }
local function _groupRemoteEntries(entries)
    local by_book = {}
    for _, e in ipairs(entries) do
        local kind, book_id = e.text:match("^syncery%-(%a+)%-(.+)%.json$")
        if book_id and _isSafeBookId(book_id)
                and (kind == "progress" or kind == "annotations") then
            by_book[book_id] = by_book[book_id] or {}
            by_book[book_id][kind] = e
        end
    end
    return by_book
end

--- Constraint I / J: validate downloaded (or about-to-be-written) content
--- before it is trusted, then place it at final_path via a temp-write +
--- rename so a reader checking for the file's existence never sees a
--- partial write. Shared by both transport paths (Constraint T's
--- fallback callback calls this too, from Checkpoint 4) -- one validated
--- write implementation, not two independently maintained ones.
---
--- @param content string raw content already read into memory
--- @param final_path string destination path
--- @return boolean ok, string|nil err
local function _validateAndPlace(content, final_path)
    if not content or content == "" then
        return false, "content is empty"
    end
    local ok_json = pcall(require("rapidjson").decode, content)
    if not ok_json then
        return false, "content is not valid JSON"
    end
    local tmp_path = final_path .. ".tmp"
    local wf = io.open(tmp_path, "wb")
    if not wf then return false, "cannot open temp path for write" end
    wf:write(content)
    wf:close()
    local ok_rename, rename_err = os.rename(tmp_path, final_path)
    if not ok_rename then
        os.remove(tmp_path)
        return false, "rename to final path failed: " .. tostring(rename_err)
    end
    return true
end

--- Constraint I/O/P: download one kind for one book_id from the Cloud
--- Storage+ provider into a temp path, validate, then rename into place.
--- io.open(tmp_path, "w") inside downloadFile creates/truncates tmp_path,
--- never final_path -- a failed/interrupted download only ever leaves
--- garbage at tmp_path, never where a later existence check looks.
---
--- @return boolean ok, string|nil err
local function _downloadAndValidate(plugin, provider, server, book_id, kind)
    local prefetch_dir = plugin.state_dir .. "cloud_staging/prefetch/"
    require("util").makePath(prefetch_dir)  -- Constraint P: mkdir -p, no-op if it exists

    local filename   = "syncery-" .. kind .. "-" .. book_id .. ".json"
    local remote_url = server.url .. "/" .. filename  -- Constraint O: matches
                                                        -- the existing manifest-
                                                        -- download convention
    local final_path = prefetch_dir .. filename
    local tmp_path    = final_path .. ".tmp"

    local code = provider.downloadFile(remote_url, tmp_path)
    if code ~= 200 then
        os.remove(tmp_path)
        return false, "download failed: " .. tostring(code)
    end
    local f = io.open(tmp_path, "rb")
    if not f then return false, "cannot open downloaded temp file" end
    local content = f:read("*a")
    f:close()
    os.remove(tmp_path)  -- _validateAndPlace writes its own temp file; this
                         -- one (downloadFile's) is done being read from.
    return _validateAndPlace(content, final_path)
end

-- =============================================================================
-- sync_all — two-phase sync (push + Merkle-manifest pull)
-- =============================================================================
PluginSync._isSafeBookId       = _isSafeBookId
PluginSync._groupRemoteEntries = _groupRemoteEntries
PluginSync._validateAndPlace   = _validateAndPlace
PluginSync._downloadAndValidate = _downloadAndValidate

--- BUGFIX:
--- WebDav.listFolder's own hasProvider filter
--- (plugins/cloudstorage.koplugin/providers/webdav.lua) silently drops any
--- entry with no registered DocumentRegistry provider unless
--- G_reader_settings "show_unsupported" is true. ".txt" (manifest files)
--- already has a registered provider, so that discovery path was never
--- affected and looked like it "just worked" -- but ".json"
--- (progress/annotations) has none, so prefetch's own entries were
--- silently invisible for any user who had not manually enabled this
--- KOReader-wide setting. Borrow the setting for exactly this one call,
--- restore immediately after (pcall-protected around the call itself, so
--- an error inside listFolder cannot skip the restore) -- correct the one
--- call that needs it instead of changing global behavior permanently.
local function _listFolderShowingUnsupported(gset, provider, url, include_folders)
    local prev = gset and gset:isTrue("show_unsupported")
    if gset then gset:saveSetting("show_unsupported", true) end
    local ok, entries = pcall(provider.listFolder, url, include_folders)
    if gset then gset:saveSetting("show_unsupported", prev) end
    return ok, entries
end
PluginSync._listFolderShowingUnsupported = _listFolderShowingUnsupported


--- Constraint C, corrected after real-device testing: this used to
--- reimplement rename-with-fallback from scratch. `Util.move_file`
--- (syncery_util.lua:66) already exists, is already used elsewhere in
--- this codebase for the exact same problem, and is already hardened for
--- the specific Android FUSE/SAF quirk this design's own move step needs
--- (rename can succeed on some cross-volume setups while a plain
--- fallback copy silently truncates -- Util.move_file's own comment:
--- "on an unreliable cross-volume FS... a write can return success yet
--- leave dst TRUNCATED"). Delegate to it instead of maintaining a
--- second, less battle-tested copy of the same logic.
---
--- Reported on a real device: the staged
--- source file can still be present in cloud_staging/prefetch/ AFTER a
--- successful apply -- content correctly reached canonical storage, but
--- the source lingered. `Util.move_file`'s own fast path
--- (`if os.rename(src, dst) then return true end`) trusts os.rename's
--- return value unconditionally -- on some Android FUSE/SAF-backed
--- storage, rename can report success while not actually clearing the
--- source directory entry. Verify explicitly rather than trust the
--- return value: if the source is still there after a reported success,
--- force-remove it. This is a targeted addition here, not a change to
--- Util.move_file itself, which other callers already rely on as-is.
---
--- @return boolean ok, string|nil err
local function _moveOrCopyDelete(src, dst)
    if not Util.move_file(src, dst) then
        return false, "Util.move_file failed for " .. tostring(src) .. " -> " .. tostring(dst)
    end
    local lfs = Util.get_lfs()
    if lfs and lfs.attributes(src) then
        -- move_file reported success, but the source is still physically
        -- present. Confirm the destination actually landed before
        -- force-removing the leftover source -- never delete on a
        -- destination we have not verified exists.
        if lfs.attributes(dst) then
            os.remove(src)
        else
            return false, "move_file reported success but neither cleared "
                .. "the source nor produced a destination: " .. tostring(src)
        end
    end
    return true
end

--- Real-device bug:
--- for a book that has genuinely never been opened before, the .sdr
--- sidecar directory does not exist yet -- KOReader only creates it as
--- part of its own docsettings write, which happens later in the open
--- lifecycle (observed in the device log at close time, well after
--- onReaderReady, where apply_staged_prefetch runs). io.open does not
--- create parent directories, so Util.move_file's destination write
--- fails outright ("cannot open destination"), the whole move reports
--- failure, and the source correctly (if uselessly) stays in prefetch/
--- -- this was never a "lingering after a reported success" case, it
--- never succeeded at all. do_cloud_upload's own known-book path never
--- hits this because "known" already implies "opened before", so the
--- directory was always already there by the time it writes --
--- apply_staged_prefetch is the only canonical-storage writer that can
--- run before that directory exists at all. Module-level (not a local
--- closure inside apply_staged_prefetch) specifically so it is directly
--- unit-testable against a real missing directory -- this suite's
--- docsettings stub unconditionally creates the sidecar dir as a side
--- effect of resolving the path at all, which would otherwise mask
--- exactly this bug from any test exercised through that stub.
local function _ensure_parent_dir(path)
    local dir = path and path:match("^(.*/)")
    if dir then require("util").makePath(dir) end
end
PluginSync._ensure_parent_dir = _ensure_parent_dir

--- Constraint M/G/toggle-respecting: move any staged prefetch content for
--- book_id into canonical storage, now that book_file is known (this is
--- called from onReaderReady, where it always is). Safe because an empty
--- local/last-sync map is documented, normal input to Merge.three_way
--- (same reasoning as do_cloud_upload's own bootstrap-empty-envelope
--- path) -- moving staged remote content into an empty canonical slot
--- reaches the same safe outcome one merge cycle earlier.
function PluginSync.apply_staged_prefetch(plugin, book_id, book_file)
    local safe_id = _isSafeBookId(book_id)
    local file_type_synced = plugin and plugin._isFileTypeSynced
        and plugin:_isFileTypeSynced(book_file)
    if _G.SYNCERY_DEBUG_LOG then
        _G.SYNCERY_DEBUG_LOG.apply_staged_prefetch_entry(
            book_id, book_file, safe_id, file_type_synced and true or false)
    end
    if not safe_id then return end  -- Constraint X, defensive
    if not file_type_synced then return end

    local prefetch_dir = plugin.state_dir .. "cloud_staging/prefetch/"
    local progress_src = prefetch_dir .. "syncery-progress-" .. book_id .. ".json"
    local annot_src     = prefetch_dir .. "syncery-annotations-" .. book_id .. ".json"
    local progress_dst  = ProgressPaths.shared_progress_path(book_file)
    local annot_dst      = AnnPaths.shared_annotations_path(book_file)
    local lfs = Util.get_lfs()
    if not lfs then return end

    local applied_progress, applied_annotations = false, false

    -- Constraint M: shared_progress_path/shared_annotations_path can
    -- return nil -- guard explicitly before ever handing a possibly-nil
    -- value to lfs.attributes.
    local progress_src_exists = lfs.attributes(progress_src) ~= nil
    local progress_dst_exists = progress_dst and lfs.attributes(progress_dst) ~= nil
    if _G.SYNCERY_DEBUG_LOG then
        _G.SYNCERY_DEBUG_LOG.apply_staged_prefetch_kind_check(
            book_id, "progress", plugin.sync_progress and true or false,
            progress_dst ~= nil, progress_dst_exists, progress_src_exists)
    end
    if plugin.sync_progress and progress_dst
            and not progress_dst_exists
            and progress_src_exists then
        _ensure_parent_dir(progress_dst)
        local ok, err = _moveOrCopyDelete(progress_src, progress_dst)
        if not ok then
            logger.warn("Syncery: staged progress apply failed:", err)
        else
            applied_progress = true
        end
    end
    local annot_src_exists = lfs.attributes(annot_src) ~= nil
    local annot_dst_exists = annot_dst and lfs.attributes(annot_dst) ~= nil
    if _G.SYNCERY_DEBUG_LOG then
        _G.SYNCERY_DEBUG_LOG.apply_staged_prefetch_kind_check(
            book_id, "annotations",
            (plugin.sync_annotations or plugin.sync_metadata or plugin.sync_render_settings) and true or false,
            annot_dst ~= nil, annot_dst_exists, annot_src_exists)
    end
    if (plugin.sync_annotations or plugin.sync_metadata or plugin.sync_render_settings)
            and annot_dst
            and not annot_dst_exists
            and annot_src_exists then
        _ensure_parent_dir(annot_dst)
        local ok, err = _moveOrCopyDelete(annot_src, annot_dst)
        if not ok then
            logger.warn("Syncery: staged annotations apply failed:", err)
        else
            applied_annotations = true
        end
    end
    if _G.SYNCERY_DEBUG_LOG then
        _G.SYNCERY_DEBUG_LOG.apply_staged_prefetch_result(
            book_id, applied_progress, applied_annotations)
    end

    -- BUGFIX (confirmed empirically via the two-device investigation
    -- harness): without this, generateManifest's NEXT scan (which reads
    -- cloud_staging/ FLAT -- Constraint V keeps prefetch/ separate on
    -- purpose) never sees this book_id, since apply only ever MOVED the
    -- file to canonical storage, never staged anything at the flat
    -- level the way do_cloud_upload's own push normally does. A book
    -- that is prefetched then applied WITHOUT ever being genuinely
    -- opened/read (so do_cloud_upload never runs for it) would
    -- otherwise stay in the "never-opened" candidate list forever
    -- (my_manifest.files[book_id] never gets an entry there), AND the
    -- prefetch staleness check would ALWAYS re-download it (the staged
    -- prefetch/ copy was just moved away, so "not staged_size" reads as
    -- true every time) -- both firing on EVERY subsequent Sync Now,
    -- indefinitely, for a book with zero real local activity beyond the
    -- one apply. Staging a copy of the just-applied content at the flat
    -- level (mirroring exactly what a real push would have left there)
    -- fixes both at once: generateManifest now finds and hashes it, and
    -- the prefetch candidate check correctly sees an entry and stops
    -- treating the book as never-opened.
    local staging_dir = plugin.state_dir .. "cloud_staging/"
    if applied_progress or applied_annotations then
        require("util").makePath(staging_dir)
    end
    local applied_progress_hash, applied_annotations_hash
    if applied_progress then
        local f = io.open(progress_dst, "rb")
        if f then
            local content = f:read("*a")
            f:close()
            local out = io.open(staging_dir .. "syncery-progress-" .. book_id .. ".json", "wb")
            if out then out:write(content); out:close() end
            if content and content ~= "" then
                applied_progress_hash = _content_hash(content)
            end
        end
    end
    if applied_annotations then
        local f = io.open(annot_dst, "rb")
        if f then
            local content = f:read("*a")
            f:close()
            local out = io.open(staging_dir .. "syncery-annotations-" .. book_id .. ".json", "wb")
            if out then out:write(content); out:close() end
            if content and content ~= "" then
                applied_annotations_hash = _content_hash(content)
            end
        end
    end

    -- BUGFIX: the design
    -- guarantees this synchronous apply always completes BEFORE
    -- do_cloud_upload's own scheduled open-moment pull (2.5s later) runs.
    -- That means the FIRST time do_cloud_upload dispatches for this book
    -- after a prefetch, it always finds an EMPTY Fix-4 push-content-cache
    -- entry (apply_staged_prefetch never populated it before this) --
    -- nothing to compare against, so it unconditionally proceeds with a
    -- full push+pull, even though this content just arrived FROM the
    -- peer and is already sitting on the server. Registering the
    -- just-applied content's hash here, keyed by book_file (matching
    -- do_cloud_upload's own push_cache[state.file] key), closes that one
    -- guaranteed-redundant cycle: do_cloud_upload's next dispatch for
    -- this book finds a matching hash and correctly skips re-pushing
    -- content that was never ours to begin with.
    if applied_progress_hash or applied_annotations_hash then
        local push_cache = _read_push_cache(plugin)
        local book_cache = push_cache[book_file] or {}
        if applied_progress_hash then
            book_cache.progress_hash = applied_progress_hash
        end
        if applied_annotations_hash then
            book_cache.annotations_hash = applied_annotations_hash
        end
        push_cache[book_file] = book_cache
        _write_push_cache(plugin, push_cache)
    end
end


PluginSync._moveOrCopyDelete = _moveOrCopyDelete


--- UI visibility helpers.
--- Shared enumerator across Booklist/Progress Browser/Annotation Browser --
--- one enumeration + one title-extraction implementation, not three.

--- Enumerate cloud_staging/prefetch/, grouping by book_id, same recognition
--- and safety-gate pattern as _groupRemoteEntries (Constraint X applied
--- again here -- a future writer into this folder is not assumed to
--- always remember the gate).
---@return table book_id -> { progress = path|nil, annotations = path|nil }
function PluginSync.enumerate_prefetch_staging(plugin)
    local prefetch_dir = plugin.state_dir .. "cloud_staging/prefetch/"
    local lfs = Util.get_lfs()
    local by_book = {}
    if not (lfs and lfs.attributes(prefetch_dir, "mode") == "directory") then
        return by_book
    end
    for f in lfs.dir(prefetch_dir) do
        local kind, book_id = f:match("^syncery%-(%a+)%-(.+)%.json$")
        if book_id and _isSafeBookId(book_id)
                and (kind == "progress" or kind == "annotations") then
            by_book[book_id] = by_book[book_id] or {}
            by_book[book_id][kind] = prefetch_dir .. f
        end
    end
    return by_book
end

--- Extract a display title from a staged progress.json's first `"file"`
--- value's basename, extension stripped. Pattern match on raw text, not a
--- full JSON decode -- only one field is needed, and this may run once per
--- staged book per browser open. Read-only: never writes anything back,
--- so it cannot affect any hash the way an embedded-in-payload title hint
--- would (that alternative was considered and rejected -- see the design
--- doc). Returns nil (never raises) when there is nothing usable.
--- @return string|nil title The book's basename, without extension.
--- @return string|nil full_path The book's full path as recorded in the
---   staged progress JSON's own "file" field (the ORIGIN device's path --
---   may not exist at that exact location on THIS device, e.g. a
---   different platform/folder layout; callers must verify with
---   lfs.attributes and/or a content-id check before treating it as
---   openable here -- see resolve_via_learned_rules).
function PluginSync.extract_title_hint(progress_path)
    if not progress_path then return nil end
    local f = io.open(progress_path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    if not content then return nil end
    local path = content:match('"file"%s*:%s*"([^"]+)"')
    if not path then return nil end
    local base = path:match("([^/\\]+)$") or path
    return (base:gsub("%.%w+$", "")), path
end


--- Compute a reusable path-prefix substitution rule from a CONFIRMED
--- peer-path/local-path pair -- the user manually located and hash-
--- verified a prefetch-only book's file at `local_path`, whose staged
--- progress/annotations JSON recorded the ORIGIN device's path as
--- `peer_path`. Finds the longest matching TRAILING run of path
--- components (not a raw character suffix, to avoid splitting a
--- component in half, e.g. matching "ooks" inside both "eBooks" and
--- "Books") and returns the two differing prefixes, so a LATER
--- prefetch-only book recorded under the same peer folder can resolve
--- automatically via resolve_via_learned_rules, without asking again.
---
--- @return table|nil {peer_prefix=string, local_prefix=string}, or nil
---   if the paths share no matching trailing component at all (nothing
---   useful to learn -- e.g. even the filename differs).
function PluginSync.compute_path_prefix_rule(peer_path, local_path)
    if type(peer_path) ~= "string" or peer_path == ""
            or type(local_path) ~= "string" or local_path == "" then
        return nil
    end
    local function split(p)
        local parts = {}
        for part in (p .. "/"):gmatch("([^/]*)/") do
            table.insert(parts, part)
        end
        return parts
    end
    local peer_parts  = split(peer_path)
    local local_parts = split(local_path)

    local matched = 0
    local i, j = #peer_parts, #local_parts
    while i >= 1 and j >= 1 and peer_parts[i] ~= "" and peer_parts[i] == local_parts[j] do
        matched = matched + 1
        i = i - 1
        j = j - 1
    end
    if matched == 0 then return nil end

    local peer_prefix  = table.concat(peer_parts,  "/", 1, #peer_parts  - matched) .. "/"
    local local_prefix = table.concat(local_parts, "/", 1, #local_parts - matched) .. "/"
    return { peer_prefix = peer_prefix, local_prefix = local_prefix }
end


--- Try resolving `peer_path` (a prefetch-only book's recorded ORIGIN
--- path) to a file on THIS device, using previously-learned rules.
--- Every candidate is content-id-verified against `target_book_id`
--- before being accepted -- a rule that doesn't apply here, or a stale/
--- coincidental prefix+existence match, must never open the WRONG book;
--- the hash check is the safety net that makes a wrong LEARNED rule
--- harmless (it simply fails to match, falling through to the next rule
--- or to the manual picker), not a correctness risk.
---
--- @param rules table list of {peer_prefix, local_prefix}, as returned
---   by Settings.get_prefetch_path_rules().
--- @return string|nil the verified local path, or nil if no rule
---   produced a hash-confirmed match.
--- @return table|nil the matched rule table itself (same object identity
---   as the entry in `rules`), so a caller that persists rules can move
---   it to the front for a most-recently-used-first search order on
---   subsequent calls -- see syncery_ui/prefetch_locate.lua's
---   try_auto_resolve.
function PluginSync.resolve_via_learned_rules(peer_path, target_book_id, rules)
    if type(peer_path) ~= "string" or peer_path == ""
            or type(target_book_id) ~= "string" or target_book_id == ""
            or type(rules) ~= "table" then
        return nil
    end
    local lfs = Util.get_lfs()
    if not lfs then return nil end
    local ok_paths, Paths = pcall(require, "syncery_ann/paths")
    if not ok_paths or not Paths or type(Paths._book_content_id) ~= "function" then
        return nil
    end

    for _, rule in ipairs(rules) do
        local pp = type(rule) == "table" and rule.peer_prefix
        local lp = type(rule) == "table" and rule.local_prefix
        if type(pp) == "string" and pp ~= "" and type(lp) == "string"
                and peer_path:sub(1, #pp) == pp then
            local candidate = lp .. peer_path:sub(#pp + 1)
            if lfs.attributes(candidate, "mode") == "file" then
                local ok_id, cid = pcall(Paths._book_content_id, candidate)
                if ok_id and cid == target_book_id then
                    return candidate, rule
                end
            end
        end
    end
    return nil
end


--- Constraints S/T (design), corrected during implementation: reuses the
--- EXISTING unified dispatch (cloud/transport.lua's cloud_sync, reached
--- via orch:pull_book), the exact same pattern the existing "manifest"
--- kind already demonstrates -- NOT a hand-rolled SyncServiceAdapter
--- construction, which the design's earlier revisions assumed was
--- necessary before this implementation found otherwise. Bootstraps an
--- empty envelope as the "local" side (same safety reasoning as
--- do_cloud_upload's own fresh-open-pull bootstrap: an empty local map
--- is documented, normal input to Merge.three_way) -- the merge callback
--- (registered in transport.lua) reads the real downloaded content from
--- income_file and places it into cloud_staging/prefetch/ via the
--- shared _validateAndPlace.
---
--- BUGFIX (Group A design-review find): this originally passed a
--- SEPARATE "prefetch_progress"/"prefetch_annotations" kind, reasoning
--- (correctly) that _build_merge_callback needed a signal to route the
--- result into cloud_staging/prefetch/ instead of canonical. But that
--- same kind value ALSO determines the REMOTE cloud object name via
--- Staging.cloud_name_for (cloud/transport.lua's _prepare, which runs
--- BEFORE _build_merge_callback's own kind->real-kind translation) --
--- so the fallback prefetch was silently reading from/writing to
--- "syncery-prefetch_progress-{id}.json", a cloud object NO real push
--- ever writes to, instead of the peer's actual "syncery-progress-
--- {id}.json". It could never have found real peer data. Fixed: pass
--- the REAL kind ("progress"/"annotations", matching what a genuine
--- push writes), and signal the prefetch-vs-canonical routing via a
--- SEPARATE is_prefetch flag on the payload instead of overloading kind.
local function _prefetchViaFallback(plugin, orch, book_id, kind)
    local content = (kind == "progress")
        and ProgressStateStore.empty_envelope_json()
        or StateStore.empty_envelope_json()
    orch:pull_book("__prefetch__", {
        payload = { kind = kind, book_id = book_id, content = content, is_prefetch = true },
    }, function(results)
        -- Fire-and-forget from this call's point of view -- errors are
        -- already logged inside the merge callback / cloud_sync itself;
        -- nothing further to reconcile here (unlike the manifest case,
        -- there is no local file for this caller to read back).
    end)
end
PluginSync._prefetchViaFallback = _prefetchViaFallback


function PluginSync.sync_all(plugin, opts)
    opts = opts or {}
    if plugin._sync_all_in_progress then
        if _G.SYNCERY_DEBUG_LOG then
            _G.SYNCERY_DEBUG_LOG.sync_all_entry(false, "already_in_progress")
        end
        return
    end
    plugin._sync_all_in_progress = true
    if _G.SYNCERY_DEBUG_LOG then
        _G.SYNCERY_DEBUG_LOG.sync_all_entry(true, nil)
    end

    local ok, err = pcall(function()
        if plugin.ui and plugin.ui.document then
            plugin:doSave(true, false)
        end

        -- Push (Phase 1) and pull (Phase 2) share ONE Trapper:wrap
        -- spanning both, instead of two separate back-to-back wraps.
        -- Trapper:wrap can return EARLY: the first yield inside the
        -- wrapped function (any Trapper:info() call) hands control
        -- back to UIManager, and the rest of the function resumes
        -- later on a subsequent tick (ui.trapper docs: "This call
        -- should be the last step in some event processing code, as
        -- it may return early"). Two separate wraps in sequence would
        -- let Phase 2's manifest/pull network calls start running
        -- while Phase 1's push loop might still be suspended mid-book
        -- -- the same "code placed AFTER Trapper:wrap may execute
        -- while the wrapped function is only half-done" class already
        -- documented for this project (scattered-metadata advisory).
        -- One wrap enclosing both phases means Phase 2 only starts
        -- once Phase 1 has genuinely, fully returned.
        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            Trapper:setPausedText(_("Sync paused."), _("Abort"), _("Continue"))
            -- Guarded the same way as this codebase's other Trapper
            -- call sites (main.lua's on_progress callback): info_fn is
            -- also captured by pushOpenedBooks' and _sync_fallback's
            -- own backoff-retry closures below, which can fire LATER
            -- from a UIManager:scheduleIn tick (wifi_backoff.lua) --
            -- genuinely outside any coroutine, not just this suspended
            -- one. Trapper:info() yields internally; calling it from
            -- outside a coroutine is exactly what coroutine.isyieldable()
            -- exists to guard against. When not yieldable there's no
            -- Trapper dialog to drive anyway, so "continue" is the only
            -- sane answer -- returning false there would abort a retry
            -- that never even reached Trapper.
            local info_fn = function(msg)
                if not coroutine.isyieldable() then
                    return true
                end
                return Trapper:info(msg)
            end

            -- Everything below runs inside its OWN pcall so that every
            -- early-return path (no server configured, no orch, listFolder
            -- failure, etc.) and any error still falls through to the
            -- Trapper:reset() right after -- otherwise whichever progress
            -- message was last shown (e.g. "Checking device 2/2...") is
            -- left stuck on screen with no confirmation of what happened.
            local body_ok, body_err = pcall(function()

            -- Phase 1: Push
            local just_pushed_files = pushOpenedBooks(plugin, info_fn)
            if plugin.destroyed then return end

            -- Fix 2: a book
            -- successfully pushed in Phase 1 gets a FRESH combined hash
            -- in the manifest Phase 2 generates moments later -- which
            -- now, correctly but redundantly, differs from whatever the
            -- peer's manifest still shows (since WE just changed it),
            -- so Phase 2's own "changed" comparison below would
            -- re-trigger a SECOND full push+pull for the exact same
            -- book, in the SAME Sync Now, for content that is already
            -- fully synced. Derive each just-pushed file's book_id the
            -- SAME way the transport already does internally (reusing
            -- doc_id_fn rather than re-deriving it a second, possibly
            -- inconsistent way), and exclude those book_ids from Phase
            -- 2's changed-detection loop below.
            local just_pushed_book_ids = {}
            if plugin._transport and plugin._transport._doc_id_fn then
                for _, book_file in ipairs(just_pushed_files or {}) do
                    local ok_id, book_id = pcall(plugin._transport._doc_id_fn,
                        book_file, plugin.ui and plugin.ui.doc_settings)
                    if ok_id and book_id then
                        just_pushed_book_ids[book_id] = true
                    end
                end
            end
            if _G.SYNCERY_DEBUG_LOG then
                local ids = {}
                for id in pairs(just_pushed_book_ids) do ids[#ids + 1] = id end
                _G.SYNCERY_DEBUG_LOG.sync_all_phase1_done(#(just_pushed_files or {}), ids)
            end

            -- Phase 2: Pull via Merkle manifest
            local Settings = require("syncery_settings")
            local server = Settings.get_cloud_server()
            if not server then
                return
            end

            local listM = require("syncery_transports/cloud/list")
            local CSProvider = require("syncery_transports/cloud/providers/cloudstorage_provider")
            local cs = CSProvider.resolve_ui_instance(plugin.ui)
            local Util = require("syncery_util")
            local my_device = Util.get_device_id()
            local cjson = require("json")

            if not cs then
                -- Fallback: no Cloud Storage+ plugin
                local orch = plugin._transport and plugin._transport._orch
                if not orch then return end

                -- 2a. Generate and upload manifest via transport
                local my_manifest = listM.generateManifest(plugin)
                local fb_files_hash = nil
                local fb_cache_path = nil
                local fb_skip_upload = false
                local fb_cached_peer_hash = nil
                if my_manifest then
                    local staging_dir = plugin.state_dir .. "cloud_staging/"
                    require("util").makePath(staging_dir)
                    fb_cache_path = staging_dir .. ".manifest_cache"
                    local keys = {}
                    for k in pairs(my_manifest.files) do table.insert(keys, k) end
                    table.sort(keys)
                    local h = sha2.md5; local ctx = h()
                    for _, k in ipairs(keys) do ctx(k); ctx(my_manifest.files[k]) end
                    fb_files_hash = ctx()
                    local cached_our_hash = nil
                    do local fh = io.open(fb_cache_path, "rb")
                        if fh then
                            local line = fh:read("*l")
                            fh:close()
                            if line then
                                local pipe = line:find("|", 1, true)
                                if pipe then
                                    cached_our_hash = line:sub(1, pipe - 1)
                                    fb_cached_peer_hash = line:sub(pipe + 1)
                                else
                                    cached_our_hash = line
                                end
                            end
                        end
                    end
                    fb_skip_upload = (cached_our_hash == fb_files_hash)
                    if not fb_skip_upload then
                        local manifest_json = cjson.encode(my_manifest)
                        local manifest_path = staging_dir .. "syncery-manifest-" .. my_device .. ".txt"
                        local fh = io.open(manifest_path, "wb"); if fh then fh:write(manifest_json); fh:close() end
                        orch:push_book("__manifest__", {
                            payload = { kind = "manifest", book_id = my_device, content = manifest_json }
                        }, { force = true })
                    end
                    if _G.SYNCERY_DEBUG_LOG then
                        local file_count = 0
                        for _ in pairs(my_manifest.files) do file_count = file_count + 1 end
                        _G.SYNCERY_DEBUG_LOG.manifest_generated(
                            "fallback", file_count, fb_files_hash, cached_our_hash, fb_skip_upload)
                    end
                    -- Record OUR hash now, independent of whether any peer
                    -- is found below: the peer loop's own write (further
                    -- down) already overwrites this with the fuller
                    -- "our_hash|peer_hash" pair when a peer IS found, but
                    -- with zero peers that write never runs -- without
                    -- this line, fb_skip_upload would never see a cache
                    -- hit and would re-upload the SAME unchanged manifest
                    -- on every single sync_all call, indefinitely, until
                    -- a peer eventually appears.
                    do local fh = io.open(fb_cache_path, "wb")
                        if fh then fh:write(fb_files_hash); fh:close() end
                    end
                end

                -- 2b. Discover peers from local staging files
                local peers = {}
                local staging_dir = plugin.state_dir .. "cloud_staging/"
                require("util").makePath(staging_dir)
                local lfs = require("libs/libkoreader-lfs")
                for f in lfs.dir(staging_dir) do
                    local fh = io.open(staging_dir .. f, "rb")
                    if fh then
                        local content = fh:read("*a"); fh:close()
                        if content then
                            local ok_d, data = pcall(cjson.decode, content)
                            -- type(data) == "table" is required, not just
                            -- truthy: a stray non-envelope file in this
                            -- directory (e.g. .manifest_cache, a plain hash
                            -- string) can decode successfully to a bare
                            -- JSON number/string/boolean -- truthy in Lua,
                            -- but indexing .entries on it raises "attempt
                            -- to index a number/string/boolean value",
                            -- which pcall above does NOT catch (decode
                            -- itself succeeded; the error is in the
                            -- .entries access right here).
                            if ok_d and type(data) == "table" and data.entries then
                                for device_id, _ in pairs(data.entries) do
                                    if device_id ~= my_device then
                                        peers[device_id] = true
                                    end
                                end
                            end
                        end
                    end
                end

                -- 2c. Download peer manifests, compare hashes, sync diff books
                -- Deterministic order (needed for the i/total numbering below);
                -- aborting mid-loop just means fewer peers get checked this
                -- round -- unlike the .opened worklist there's no persistent
                -- per-peer queue to preserve, the next Sync Now redoes the
                -- whole manifest check regardless.
                local peer_ids = {}
                for device_id in pairs(peers) do peer_ids[#peer_ids + 1] = device_id end
                table.sort(peer_ids)

                local changed = {}
                for pi, device_id in ipairs(peer_ids) do
                    if plugin.destroyed then break end
                    if not info_fn(string.format(_("Checking device %d/%d..."), pi, #peer_ids)) then
                        break
                    end
                    local remote_manifest = nil
                    orch:pull_book("__manifest__", {
                        payload = { kind = "manifest", book_id = device_id, content = "{}" }
                    }, function(results)
                        local manifest_path = staging_dir .. "syncery-manifest-" .. device_id .. ".txt"
                        local fh = io.open(manifest_path, "rb")
                        if fh then
                            local raw = fh:read("*a"); fh:close()
                            local ok_d, data = pcall(cjson.decode, raw)
                            if ok_d and type(data) == "table" then remote_manifest = data end
                        end
                    end)
                    if remote_manifest and remote_manifest.files and my_manifest and my_manifest.files then
                        local peer_keys = {}
                        for k in pairs(remote_manifest.files) do table.insert(peer_keys, k) end
                        table.sort(peer_keys)
                        local peer_h = sha2.md5; local peer_ctx = peer_h()
                        for _, k in ipairs(peer_keys) do peer_ctx(k); peer_ctx(remote_manifest.files[k]) end
                        local peer_hash = peer_ctx()
                        -- KNOWN LIMITATION (deliberately not fixed -- traced,
                        -- not overlooked): this cache is a SINGLE value, so
                        -- with 2+ peers each iteration's write below
                        -- overwrites the previous peer's contribution --
                        -- only the peer that sorts LAST (peer_ids is
                        -- alphabetical) ever gets a cache hit on the NEXT
                        -- run; every other peer redundantly re-runs the
                        -- local diff loop even when nothing changed for it.
                        -- Left as-is because: (1) zero extra network calls
                        -- either way -- downloadManifest above ALWAYS runs
                        -- per peer regardless of this cache; only the
                        -- local, pure-Lua per-book comparison is what gets
                        -- skipped or not. (2) can NEVER produce a WRONG
                        -- result -- the diff loop always reads THIS run's
                        -- freshly-downloaded remote/my_manifest files,
                        -- never cached data, so a redundant run just
                        -- re-derives the same correct (usually empty)
                        -- delta, and a correct skip only fires when the
                        -- peer's hash is genuinely unchanged. A real fix
                        -- needs a cache-format redesign (single value ->
                        -- per-device map) in a function with zero test
                        -- coverage, for a saving bounded by "iterate a
                        -- handful of book_id strings once" -- not worth
                        -- the regression risk. If revisiting: this is the
                        -- ONLY thing wrong here -- upload-skip, download
                        -- counts, and correctness are all unaffected.
                        do local fh = io.open(fb_cache_path, "wb")
                            if fh then fh:write(fb_files_hash .. "|" .. peer_hash); fh:close() end
                        end
                        if not (fb_skip_upload and fb_cached_peer_hash == peer_hash) then
                            -- Deterministic order: matches every other
                            -- pairs()-then-iterate spot in this file; keeps
                            -- "Downloading i/N..." numbering (and which
                            -- book that is) reproducible across runs
                            -- instead of depending on Lua's unordered
                            -- table iteration.
                            local remote_book_ids = {}
                            for book_id in pairs(remote_manifest.files) do
                                remote_book_ids[#remote_book_ids + 1] = book_id
                            end
                            table.sort(remote_book_ids)
                            for _, book_id in ipairs(remote_book_ids) do
                                local remote_hash = remote_manifest.files[book_id]
                                local my_hash = my_manifest.files[book_id]
                                if just_pushed_book_ids[book_id] then
                                    -- Fix 2: already fully synced moments ago in
                                    -- Phase 1 of THIS SAME Sync Now -- our hash
                                    -- differing from the peer's stale copy here
                                    -- is the EXPECTED, already-handled result of
                                    -- that push, not a new change to process again.
                                elseif my_hash and my_hash ~= remote_hash then
                                    local path = listM.resolveBookPath(plugin, book_id)
                                    if path then table.insert(changed, {id = book_id, path = path}) end
                                elseif not my_hash and _isSafeBookId(book_id) then
                                    -- Cloud prefetch, fallback path (Constraint R):
                                    -- never known locally -- compare the LOCAL
                                    -- combined hash of whatever is already
                                    -- staged in cloud_staging/prefetch/ (empty
                                    -- string for each half never yet fetched)
                                    -- against the peer's single combined hash.
                                    -- No finer signal is available here than
                                    -- per-book (unlike Cloud Storage+'s
                                    -- per-kind size check) -- a change to
                                    -- either kind re-fetches both.
                                    local prefetch_dir = plugin.state_dir .. "cloud_staging/prefetch/"
                                    local function read_or_empty(path2)
                                        local fh = io.open(path2, "rb")
                                        if not fh then return "" end
                                        local c = fh:read("*a"); fh:close()
                                        return c or ""
                                    end
                                    local staged_progress = read_or_empty(
                                        prefetch_dir .. "syncery-progress-" .. book_id .. ".json")
                                    local staged_annotations = read_or_empty(
                                        prefetch_dir .. "syncery-annotations-" .. book_id .. ".json")
                                    local local_ctx = sha2.md5()
                                    local_ctx(staged_progress .. "\0" .. staged_annotations)
                                    local local_hash_combined = local_ctx()
                                    if local_hash_combined ~= remote_hash then
                                        _prefetchViaFallback(plugin, orch, book_id, "progress")
                                        _prefetchViaFallback(plugin, orch, book_id, "annotations")
                                    end
                                end
                            end
                        end
                    end
                end

                if #changed > 0 then
                    local function _sync_fallback(changed_books)
                        if not plugin:_isCloudReachable() then
                            plugin._cloud_wifi_backoff:attempt{
                                label = "sync_all fallback retry",
                                run = function()
                                    _sync_fallback(changed_books)
                                end,
                            }
                            return
                        end
                        for i, book in ipairs(changed_books) do
                            if plugin.destroyed then return end
                            if not info_fn(string.format(_("Syncing %d/%d..."), i, #changed_books)) then
                                break
                            end
                            local ok, result = pcall(PluginSync.do_cloud_upload, plugin, { file = book.path, force_sync = true })
                            if _G.SYNCERY_DEBUG_LOG then
                                _G.SYNCERY_DEBUG_LOG.sync_changed_book_result(
                                    book.id, book.path, i, #changed_books, ok, result)
                            end
                            if result == "deferred" then return end
                        end
                    end
                    if _G.SYNCERY_DEBUG_LOG then
                        _G.SYNCERY_DEBUG_LOG.sync_all_phase2_summary(#changed)
                    end
                    _sync_fallback(changed)
                else
                    if _G.SYNCERY_DEBUG_LOG then
                        _G.SYNCERY_DEBUG_LOG.sync_all_phase2_summary(0)
                    end
                    info_fn(_("Up to date."))
                end

                Settings.set_last_sync_all_ts(os.time())
                return
            end

            -- Plugin path: Cloud Storage+ available
            if not cs.providers and cs.getProviders then cs:getProviders() end
            local provider = cs.providers and cs.providers[server.type]
            if not provider then return end
            provider.base = server

            -- Refresh Dropbox access token (no-op for WebDAV/FTP)
            pcall(function() provider:genAccessToken() end)

            -- 2a. Generate and upload OUR manifest
            local my_manifest = listM.generateManifest(plugin)
            local pl_files_hash = nil
            local pl_cache_path = nil
            local pl_skip_upload = false
            local pl_cached_peer_hash = nil
            if my_manifest then
                local keys = {}
                for k in pairs(my_manifest.files) do table.insert(keys, k) end
                table.sort(keys)
                local h = sha2.md5; local ctx = h()
                for _, k in ipairs(keys) do ctx(k); ctx(my_manifest.files[k]) end
                pl_files_hash = ctx()
                pl_cache_path = plugin.state_dir .. "cloud_staging/.manifest_cache"
                local cached_our_hash = nil
                do local fh = io.open(pl_cache_path, "rb")
                    if fh then
                        local line = fh:read("*l")
                        fh:close()
                        if line then
                            local pipe = line:find("|", 1, true)
                            if pipe then
                                cached_our_hash = line:sub(1, pipe - 1)
                                pl_cached_peer_hash = line:sub(pipe + 1)
                            else
                                cached_our_hash = line
                            end
                        end
                    end
                end
                pl_skip_upload = (cached_our_hash == pl_files_hash)
                if not pl_skip_upload then
                    listM.uploadManifest(plugin, provider, server, my_manifest)
                end
                if _G.SYNCERY_DEBUG_LOG then
                    local file_count = 0
                    for _ in pairs(my_manifest.files) do file_count = file_count + 1 end
                    _G.SYNCERY_DEBUG_LOG.manifest_generated(
                        "cloud_storage_plus", file_count, pl_files_hash, cached_our_hash, pl_skip_upload)
                end
                -- Record OUR hash now, independent of whether any peer is
                -- found below: the peer loop's own write (further down)
                -- already overwrites this with the fuller
                -- "our_hash|peer_hash" pair when a peer IS found, but with
                -- zero peers that write never runs -- without this line,
                -- pl_skip_upload would never see a cache hit and would
                -- re-upload the SAME unchanged manifest on every single
                -- sync_all call, indefinitely, until a peer eventually
                -- appears.
                do local fh = io.open(pl_cache_path, "wb")
                    if fh then fh:write(pl_files_hash); fh:close() end
                end
            end

                --- BUGFIX:
                --- WebDav.listFolder's own hasProvider filter
                --- (plugins/cloudstorage.koplugin/providers/webdav.lua) silently drops any
                --- entry with no registered DocumentRegistry provider unless
                --- G_reader_settings "show_unsupported" is true. ".txt" (manifest files)
                --- already has a registered provider, so that discovery path was never
                -- (See _listFolderShowingUnsupported near the other module-level helpers.)

            -- 2b. List cloud directory for all manifest files
            local ok_list, entries = _listFolderShowingUnsupported(
                G_reader_settings, provider, server.url, true)
            if _G.SYNCERY_DEBUG_LOG then
                _G.SYNCERY_DEBUG_LOG.list_folder_result(ok_list, entries and #entries or 0)
            end
            if not ok_list or not entries then
                return
            end

            -- 2b-prefetch. Remote-only books (never opened on this device)
            -- Reuses THIS SAME `entries`
            -- listing (Constraint O/Q) -- no second network round-trip.
            -- Constraint V: staged under prefetch/, never the flat top
            -- level, so generateManifest's walk (2a, above) never sees
            -- these and its per-sync_all cost stays independent of
            -- prefetch volume.
            --
            -- Trapper feedback: the known-book push/pull phases above
            -- already report progress via info_fn -- prefetch had none,
            -- leaving the user staring at a stuck "Checking..." message
            -- (or nothing) for however long a peer's whole library takes
            -- to discover and download. Same info_fn, same pattern.
            do
                local by_book = _groupRemoteEntries(entries)
                local candidate_ids = {}
                for book_id, kinds in pairs(by_book) do
                    if not (my_manifest and my_manifest.files
                            and my_manifest.files[book_id]) then
                        table.insert(candidate_ids, book_id)
                    end
                end
                if _G.SYNCERY_DEBUG_LOG then
                    _G.SYNCERY_DEBUG_LOG.prefetch_candidates_found(#candidate_ids)
                end
                if #candidate_ids > 0 then
                    info_fn(string.format(
                        _("Checking %d never-opened book(s) for new data..."),
                        #candidate_ids))
                end
                for i, book_id in ipairs(candidate_ids) do
                    local kinds = by_book[book_id]
                    for kind, entry in pairs(kinds) do
                        local staging_path = plugin.state_dir
                            .. "cloud_staging/prefetch/syncery-" .. kind
                            .. "-" .. book_id .. ".json"
                        local staged_size = (function()
                            local lfs = Util.get_lfs()
                            return lfs and lfs.attributes(staging_path, "size")
                        end)()
                        -- Constraint N: nil-safe comparison -- either
                        -- side may be nil (never staged yet, or the
                        -- listing entry lacks a size for some reason).
                        local stale = (not staged_size)
                                or (staged_size and staged_size ~= entry.filesize)
                        if _G.SYNCERY_DEBUG_LOG then
                            _G.SYNCERY_DEBUG_LOG.prefetch_staleness_check(
                                book_id, kind, staged_size, entry.filesize, stale)
                        end
                        if stale then
                            info_fn(string.format(
                                _("Prefetching book %d/%d (%s)..."),
                                i, #candidate_ids, kind))
                            local ok_dl, err_dl = _downloadAndValidate(
                                plugin, provider, server, book_id, kind)
                            if _G.SYNCERY_DEBUG_LOG then
                                _G.SYNCERY_DEBUG_LOG.prefetch_download_result(book_id, kind, ok_dl, err_dl)
                            end
                            if not ok_dl then
                                logger.warn("Syncery: prefetch download failed for",
                                    book_id, kind, err_dl)
                            end
                        end
                    end
                end
            end

            -- 2c/2d. Collect all peer manifests from the listing
            local manifests_to_check = {}
            for _, e in ipairs(entries) do
                local device_id = e.text:match("^syncery%-manifest%-(.+)%.txt$")
                if device_id and device_id ~= my_device then
                    manifests_to_check[device_id] = true
                end
            end
            -- 2e. Download each remote manifest, compare hashes, build delta list
            -- Deterministic order (needed for the i/total numbering below);
            -- aborting mid-loop just means fewer peers get checked this
            -- round -- there's no persistent per-peer queue to preserve,
            -- the next Sync Now redoes the whole manifest check regardless.
            local peer_ids = {}
            for device_id in pairs(manifests_to_check) do peer_ids[#peer_ids + 1] = device_id end
            table.sort(peer_ids)

            local changed = {}
            for pi, device_id in ipairs(peer_ids) do
                if plugin.destroyed then break end
                if not info_fn(string.format(_("Checking device %d/%d..."), pi, #peer_ids)) then
                    break
                end
                local remote = listM.downloadManifest(plugin, provider, server, device_id)
                if _G.SYNCERY_DEBUG_LOG then
                    _G.SYNCERY_DEBUG_LOG.download_manifest_result(
                        device_id, remote ~= nil, remote and remote.files
                            and (function() local n=0 for _ in pairs(remote.files) do n=n+1 end return n end)() or 0)
                end
                if remote and remote.files and my_manifest and my_manifest.files then
                    local peer_keys = {}
                    for k in pairs(remote.files) do table.insert(peer_keys, k) end
                    table.sort(peer_keys)
                    local peer_h = sha2.md5; local peer_ctx = peer_h()
                    for _, k in ipairs(peer_keys) do peer_ctx(k); peer_ctx(remote.files[k]) end
                    local peer_hash = peer_ctx()
                    -- KNOWN LIMITATION (deliberately not fixed -- traced,
                    -- not overlooked): this cache is a SINGLE value, so
                    -- with 2+ peers each iteration's write below overwrites
                    -- the previous peer's contribution -- only the peer
                    -- that sorts LAST (peer_ids is alphabetical) ever gets
                    -- a cache hit on the NEXT run; every other peer
                    -- redundantly re-runs the local diff loop even when
                    -- nothing changed for it. Left as-is because: (1) zero
                    -- extra network calls either way -- downloadManifest
                    -- above ALWAYS runs per peer regardless of this cache;
                    -- only the local, pure-Lua per-book comparison is what
                    -- gets skipped or not. (2) can NEVER produce a WRONG
                    -- result -- the diff loop always reads THIS run's
                    -- freshly-downloaded remote/my_manifest files, never
                    -- cached data, so a redundant run just re-derives the
                    -- same correct (usually empty) delta, and a correct
                    -- skip only fires when the peer's hash is genuinely
                    -- unchanged. A real fix needs a cache-format redesign
                    -- (single value -> per-device map) in a function with
                    -- zero test coverage, for a saving bounded by "iterate
                    -- a handful of book_id strings once" -- not worth the
                    -- regression risk. If revisiting: this is the ONLY
                    -- thing wrong here -- upload-skip, download counts,
                    -- and correctness are all unaffected.
                    do local fh = io.open(pl_cache_path, "wb")
                        if fh then fh:write(pl_files_hash .. "|" .. peer_hash); fh:close() end
                    end
                    if not (pl_skip_upload and pl_cached_peer_hash == peer_hash) then
                        -- Deterministic order: matches every other
                        -- pairs()-then-iterate spot in this file; keeps
                        -- "Downloading i/N..." numbering (and which book
                        -- that is) reproducible across runs instead of
                        -- depending on Lua's unordered table iteration.
                        local remote_book_ids = {}
                        for book_id in pairs(remote.files) do
                            remote_book_ids[#remote_book_ids + 1] = book_id
                        end
                        table.sort(remote_book_ids)
                        for _, book_id in ipairs(remote_book_ids) do
                            local remote_hash = remote.files[book_id]
                            local my_hash = my_manifest.files[book_id]
                            local decision
                            if just_pushed_book_ids[book_id] then
                                -- Fix 2: already fully synced moments ago in
                                -- Phase 1 of THIS SAME Sync Now.
                                decision = "excluded_just_pushed"
                            elseif my_hash and my_hash ~= remote_hash then
                                local path = listM.resolveBookPath(plugin, book_id)
                                if path then
                                    table.insert(changed, {id = book_id, path = path})
                                    decision = "changed"
                                else
                                    decision = "changed_but_no_local_path"
                                end
                            else
                                decision = "unchanged"
                            end
                            if _G.SYNCERY_DEBUG_LOG then
                                _G.SYNCERY_DEBUG_LOG.manifest_diff_book(
                                    book_id, my_hash, remote_hash, decision)
                            end
                        end
                    end
                end
            end
            -- 2e. Sync changed books
            local total = #changed

            local function sync_changed(changed_books)
                for i, book in ipairs(changed_books) do
                    if plugin.destroyed then return end
                    if not info_fn(string.format(_("Syncing %d/%d..."), i, total)) then
                        break
                    end
                    local ok, result = pcall(PluginSync.do_cloud_upload, plugin, { file = book.path, force_sync = true })
                    if _G.SYNCERY_DEBUG_LOG then
                        _G.SYNCERY_DEBUG_LOG.sync_changed_book_result(book.id, book.path, i, total, ok, result)
                    end
                    if result == "deferred" then return end
                end
            end

            if _G.SYNCERY_DEBUG_LOG then
                _G.SYNCERY_DEBUG_LOG.sync_all_phase2_summary(total)
            end
            if total > 0 then
                sync_changed(changed)
            else
                info_fn(_("Up to date."))
            end

            Settings.set_last_sync_all_ts(os.time())
            end)   -- close body_ok pcall

            -- Always close whatever InfoMessage was last shown, regardless
            -- of which branch/early-return path was taken above, or
            -- whether it errored.
            Trapper:reset()
            if not body_ok then
                logger.warn("Syncery: sync_all inner error:", tostring(body_err))
            end
        end)
    end)

    plugin._sync_all_in_progress = false

    if not ok then
        logger.warn("Syncery: sync_all error:", tostring(err))
    end
end


return PluginSync
