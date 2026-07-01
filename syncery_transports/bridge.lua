-- =============================================================================
-- syncery_transports/bridge.lua
-- =============================================================================
--
-- The bridge between main.lua and the transport orchestrator.
--
-- WHY THIS FILE EXISTS
--
-- The orchestrator's API is uniform: `orch:push_book(file, opts)`
-- with opts containing payloads each transport extracts what it needs
-- from.  But main.lua's per-transport call sites today are anything
-- but uniform:
--
--   _doTriggerScan(state)         → asks Syncthing for a scan of one folder
--   _scheduleCloudUpload(state)   → debounces, then builds {kind, book_id,
--                                          content} for each of 2 files
--
-- Each call site has its own debouncing rules, its own payload
-- assembly, its own state-object expectations.  We cannot just
-- s/_doTriggerScan(state)/orch:push_book/g — payloads disagree.
--
-- The bridge translates: it exposes convenience methods
-- (`push_syncthing_scan`, `push_cloud_files`)
-- whose call shapes match the EXISTING main.lua callsites.  Each
-- builds the right opts and calls into the orchestrator.
--
-- This is deliberately a step DOWN in abstraction from the orchestrator:
-- it presents push/pull functions whose call shapes match main.lua's
-- callsites, so each site builds the right opts and calls into the
-- orchestrator without duplicating payload-assembly logic.
--
--
-- DEPENDENCIES INJECTABLE (test-friendly)
--
-- new() takes the orchestrator as a constructor arg.  No globals,
-- no `_G.Syncery._orchestrator`.  Tests build the bridge with a fake
-- orchestrator and observe what was forwarded.
--
-- =============================================================================


local Log = require("syncery_transports/log")
local log = Log.tag("bridge")
local Stignore = require("syncery_transports/stignore")


local Bridge = {}
Bridge.__index = Bridge


--- Build a new Bridge.
---@param opts table  { orchestrator = required, doc_id_fn = optional }
function Bridge.new(opts)
    opts = opts or {}
    assert(type(opts.orchestrator) == "table",
        "Bridge.new: opts.orchestrator (table) required")

    local self = setmetatable({}, Bridge)
    self._orch = opts.orchestrator
    -- doc_id_fn is the function that turns (book_file, doc_settings)
    -- into a stable per-content hash.  In production this is
    -- AnnPaths._book_content_id (same
    -- partial-MD5 result).  We inject so tests can pass a fake.
    self._doc_id_fn = opts.doc_id_fn or function() return nil end
    return self
end


-- ----------------------------------------------------------------------------
-- Syncthing scan trigger.
--
-- Old call:
--     Syncthing.triggerScan(local_cfg, sub_dir, actual_sync_path, cb)
--
-- New call:
--     bridge:push_syncthing_scan(book_file, { sub = sub_dir })
--
-- The cb argument is gone — the orchestrator handles retries and
-- status updates.  Callers that need to know about completion can
-- subscribe to the orchestrator's on_status_change.  Old callers
-- that pass cb just to log are dropped on the floor; no info lost
-- (orchestrator logs the same outcome under its own tag).
-- ----------------------------------------------------------------------------


--- Trigger a Syncthing scan for the given book.
---@param book_file string
---@param opts table|nil   { sub = "<relative path within folder>",
---                          force = bool — bypass debounce/backoff (terminal
---                          close-push scan: last chance before shutdown) }
function Bridge:push_syncthing_scan(book_file, opts)
    opts = opts or {}
    -- Only Syncthing reads `sub`; Cloud ignores it.  We still send
    -- `payload = nil` so Cloud's "missing content" gate fires normally.
    -- But — and this is the key insight — we do NOT pass the cloud
    -- payload here either.  The orchestrator calls push() on every
    -- transport; Cloud will respond with REJECTED, which
    -- classifies as permanent → no retry → no log spam.
    --
    -- That's fine semantically (a Syncthing scan IS only addressed
    -- to Syncthing) but produces a small amount of bookkeeping for
    -- the non-Syncthing transports.  Acceptable.
    -- A forced scan must force ONLY Syncthing: push_book fans out to every
    -- transport, and forcing this nil-payload call onto Cloud would REJECT and
    -- clobber a just-sent cloud upload's status.  Scope force to the syncthing tid.
    local caller = opts.force and { force = { syncthing = true } } or nil
    self._orch:push_book(book_file, { sub = opts.sub }, caller)
end


-- ----------------------------------------------------------------------------
-- Cloud file upload(s).
--
-- Old call:
--     Cloud.uploadJsonAs(local_path, cloud_name, on_done)
--     -- called once per file (progress + annotations), with cloud_name
--     -- built locally as "syncery-<kind>-<book_id>.json"
--
-- New call:
--     bridge:push_cloud_files(book_file, {
--         { kind = "progress",    content = '{"page":42,...}' },
--         { kind = "annotations", content = '[{...},...]' },
--     })
--
-- The bridge derives book_id from doc_id_fn,
-- the staging+naming happens inside the Cloud transport.  Callers
-- don't see filenames.
-- ----------------------------------------------------------------------------


--- Push one or more cloud files for the given book.
---@param book_file string
---@param entries table[]   list of { kind = "progress"|"annotations", content = string }
---@param doc_settings table|nil  KOReader doc_settings for book_id derivation
function Bridge:push_cloud_files(book_file, entries, doc_settings)
    if type(entries) ~= "table" or #entries == 0 then return end
    local book_id = self._doc_id_fn(book_file, doc_settings)
    if not book_id or book_id == "" then
        log.warn("cloud push for %s: no book_id derivable, skipping", book_file)
        return
    end

    -- Cloud transport expects ONE payload per push_book call (the
    -- orchestrator's per-(transport, book) state is keyed by book, NOT
    -- by kind).  So we make one push_book call per entry.
    --
    -- Both entries are DISTINCT cloud files (progress vs annotations →
    -- different staging file → different cloud object) for the same
    -- book, but the orchestrator's debounce shares one slot per book.
    -- Every push (incl. a forced one) stamps `last_attempt_at`, so once
    -- ANY cloud push has happened, a NON-forced entry pushed within
    -- `debounce_seconds` (cloud: 60) is rejected as "debounced".  The
    -- old `force = (i > 1)` therefore left the FIRST entry (progress)
    -- exposed: any upload within 60 s of a prior push — a close right
    -- after an autosave-scheduled upload, or a second manual sync —
    -- dropped progress while annotations (forced) always went, so
    -- progress reached the cloud only intermittently.
    --
    -- Fix: force BOTH.  These are two distinct files that must each be
    -- staged on every cloud upload; the per-book debounce cannot tell
    -- them apart, so it is the wrong throttle here.  `force` means
    -- "bypass debounce" (the documented "Sync Now" hatch), which both
    -- kinds qualify for.  Upload RATE is already bounded upstream:
    -- `schedule_cloud_upload` debounces the autosave path by 60 s,
    -- manual "Sync now" is gated by `save_now_cooldown`, and close
    -- fires once — so forcing both does not slam the provider.
    for _, entry in ipairs(entries) do
        self._orch:push_book(book_file,
            {
                payload = {
                    kind    = entry.kind,
                    book_id = book_id,
                    content = entry.content,
                },
            },
            { force = true })
    end
end


-- ----------------------------------------------------------------------------
-- Read-side accessor.  main.lua's status panel reads the orchestrator
-- through here instead of holding a reference to it directly.
-- ----------------------------------------------------------------------------


--- Return the orchestrator's status table.  See Orchestrator:get_status().
function Bridge:get_status()
    return self._orch:get_status()
end


--- Per-book pending state for one transport.  See
--- Orchestrator:peek_transport_books().  Used by the status
--- panel to list per-book retries for the transport the user
--- long-pressed.  Passthrough — the bridge owns the orchestrator
--- reference so the panel doesn't have to.
function Bridge:peek_transport_books(transport_id)
    return self._orch:peek_transport_books(transport_id)
end


-- ----------------------------------------------------------------------------
-- Syncthing-specific helpers.
--
-- These are NOT part of the uniform push/pull interface.  They exist
-- because main.lua's `_setupKOSyncthingPlusIntegration` has two side-tasks
-- that don't fit "push a payload":
--
--   • At startup, register Syncery's conflict-file patterns so the
--     daemon (via setFolderIgnore) treats them as out-of-scope.
--   • Expose a "Sync Now" trigger that runs an immediate full-scan
--     cycle (KOSyncthing+'s quickSync).
--
-- Both are best-effort: if the transport isn't available or the
-- capability isn't supported, the bridge no-ops (or returns nil + a
-- short error) without raising.  Callers don't need to know whether
-- the daemon is up or the user has the KOSyncthing+ plugin installed.
-- ----------------------------------------------------------------------------


--- Syncery's own conflict-file patterns, pushed to the Syncthing daemon's
--- folder ignore list so conflict COPIES don't replicate across devices.
--- (Syncery's own conflict resolver still merges and removes them locally;
--- this just stops the copies from spreading before that happens.)
---
--- A SINGLE pattern covers every Syncery conflict file in BOTH storage
--- modes, because every Syncery data file now carries the unique
--- `syncery-` infix in its name:
---   * SDR : `<book>.syncery-progress.json`, `<book>.syncery-annotations.json`
---           (and the retired pre-9.4 `.syncery-annotations.v2.json`)
---   * hash: `syncery-progress.json`, `syncery-annotations.json`
---           (the hash files carry the `syncery-` prefix precisely so a
---           name-based pattern can tell them apart from any other
---           plugin's files).
---
--- `*syncery-*sync-conflict-*` matches all of the above and nothing else:
--- KOReader's own sidecar conflicts are `*.lua.sync-conflict-*.lua` (no
--- `syncery-`), and a foreign `progress.json` conflict has no `syncery-`
--- infix either. The `syncery-` infix is the safety anchor — it is what
--- makes a single name-based pattern safe without path anchoring (which
--- the daemon ignore list could express, but KOSyncthing+'s `find -name`
--- conflict scanner could not).
--- Beyond the conflict pattern above, the list also ignores KOReader's SDR
--- sidecars whose mergeable content Syncery already syncs via its JSON
--- (`metadata.<ext>.lua` + `custom_metadata.lua`, each with its `.old`
--- backup) — replicating them is redundant and is the source of the metadata
--- sync-conflict copies.  This is safe because Syncery rewrites both sidecars
--- locally on apply, so each device reconstructs them from the JSON.  In hash
--- mode there is no `.sdr` in the synced tree, so those patterns match
--- nothing.  See stignore.lua's PATTERNS for the per-pattern rationale.
---
-- Single source of truth: the whole ignore list lives in `Stignore.PATTERNS`
-- (the same literals the `.stignore` file writer uses).  The REST registrar
-- and the file writer therefore can never drift apart.
local SYNCERY_IGNORE_PATTERNS = Stignore.PATTERNS

-- Syncery's identity in KOSyncthing+'s IgnoreRegistry — must match the plugin
-- folder name (the `syncery.koplugin` directory; KOReader derives the plugin
-- name from the directory, not from _meta.lua).  The registry keys ignore
-- patterns by plugin id, so a stable id keeps registration idempotent.
local SYNCERY_PLUGIN_ID = "syncery"


--- List the active Syncthing transport's folders, live, as
--- {folder_id, path, label} records — the folder picker's source.
--- Best-effort: no syncthing transport (or it's unavailable) →
--- (nil, "not_available").  Otherwise delegate to the transport's
--- list_folders, passing its (folders|nil, err|nil) callback through
--- unchanged.
function Bridge:list_folders(callback)
    local t = self._orch:find_transport("syncthing")
    if not t or not t.is_available() then
        callback(nil, "not_available"); return
    end
    t.list_folders(callback)
end


--- Forward a provider-aware connectivity probe to the Syncthing transport
--- (see transport.test_connection): pings system/version through the active
--- provider's client (KOSyncthing+ apiCall / config.xml URL), bypassing the
--- manual key.  callback(ok, code|nil, diag).
function Bridge:test_connection(callback)
    local t = self._orch:find_transport("syncthing")
    if not t or not t.is_available() then
        callback(false, nil, "not_available"); return
    end
    t.test_connection(callback)
end


--- Tell the Syncthing daemon to ignore Syncery's conflict files for
--- its current folder.  Best-effort: gated on the Syncthing transport
--- being available and advertising IGNORE_PATTERNS.  Returns true if
--- the call was dispatched, false otherwise.
---
--- The actual REST call is async (set_folder_ignore takes a callback);
--- we wire the callback to a debug log and don't block.  Callers don't
--- get told whether the daemon accepted the patterns — that surfaces
--- in the next push attempt's diagnostic, not here.
function Bridge:register_syncery_ignore_patterns()
    local t = self._orch:find_transport("syncthing")
    if not t then
        log.dbg("register_syncery_ignore_patterns: no syncthing transport")
        return false
    end
    if not t.is_available() then
        log.dbg("register_syncery_ignore_patterns: syncthing not available")
        return false
    end
    if not t.supports("ignore_patterns") then
        log.dbg("register_syncery_ignore_patterns: IGNORE_PATTERNS not supported")
        return false
    end

    local folder_id = t.get_folder_id()
    if type(folder_id) ~= "string" or folder_id == "" then
        log.dbg("register_syncery_ignore_patterns: no folder_id available")
        return false
    end

    -- set_folder_ignore replaces the entire ignore list, which would
    -- clobber the user's own patterns if they set any.  Read first,
    -- merge, then write.  We dedupe by exact-string equality — the
    -- patterns we contribute are unique strings unlikely to collide
    -- with user entries, and exact dedupe is enough to keep our calls
    -- idempotent across multiple startups.
    t.get_folder_ignore(folder_id, function(get_ok, _get_err, existing)
        if not get_ok then
            log.dbg("register_syncery_ignore_patterns: get_folder_ignore failed; "
                  .. "writing only our patterns")
            existing = {}
        end
        existing = existing or {}

        local seen = {}
        local merged = {}
        for _, p in ipairs(existing) do
            if type(p) == "string" and not seen[p] then
                seen[p] = true
                table.insert(merged, p)
            end
        end
        for _, p in ipairs(SYNCERY_IGNORE_PATTERNS) do
            if not seen[p] then
                seen[p] = true
                table.insert(merged, p)
            end
        end

        t.set_folder_ignore(folder_id, merged, function(set_ok, set_err)
            if set_ok then
                log.dbg("registered %d ignore patterns with folder %s",
                    #merged, folder_id)
            else
                log.dbg("set_folder_ignore failed: %s", tostring(set_err))
            end
        end)
    end)

    return true
end


--- Exclude Syncery's own conflict files from KOSyncthing+'s conflict
--- SCANNER (the Conflicts badge/menu).  Best-effort, gated on the Syncthing
--- transport being available and advertising CONFLICT_IGNORE_REGISTRY (only
--- the KOSyncthing+ provider does).  Returns true if the registration call
--- succeeded, false otherwise.
---
--- This is the SCANNER half of conflict suppression — the counterpart to
--- `register_syncery_ignore_patterns` (the DAEMON half, `.stignore`).
--- `.stignore` stops conflict COPIES from replicating; this stops the
--- still-present local `.sync-conflict-*` file from being counted/listed.
--- Unlike the REST `.stignore` path, `IgnoreRegistry:register` is an
--- in-process call (no network), so it is safe to run at startup without
--- the network blocking that the synchronous REST register would incur.
function Bridge:register_conflict_menu_ignore()
    local t = self._orch:find_transport("syncthing")
    if not t then
        log.dbg("register_conflict_menu_ignore: no syncthing transport")
        return false
    end
    if not t.is_available() then
        log.dbg("register_conflict_menu_ignore: syncthing not available")
        return false
    end
    if not t.supports("conflict_ignore_registry") then
        log.dbg("register_conflict_menu_ignore: CONFLICT_IGNORE_REGISTRY not supported")
        return false
    end

    -- The KOSyncthing+ scanner de-mangles a conflict copy to its original
    -- name before matching, so we register the ORIGINAL-name glob
    -- (CONFLICT_SCANNER_PATTERN), NOT the `.stignore` literal-copy glob.
    local ok, err = t.register_conflict_scanner_ignore(
        SYNCERY_PLUGIN_ID, Stignore.CONFLICT_SCANNER_PATTERN)
    if not ok then
        log.dbg("register_conflict_menu_ignore: %s", tostring(err))
        return false
    end
    return true
end


--- Trigger a one-shot Quick Sync via the Syncthing transport's
--- KOSyncthing+-only path.  Returns true if the underlying call returned ok,
--- nil + a short error string otherwise.  No-op (returns nil + "not
--- available") when the transport is absent, unavailable, or
--- doesn't advertise QUICK_SYNC.
---
--- Wired to the "Sync Now" menu item; lands on KOSyncthing+'s
--- `control.quickSync()` when that provider is active.
function Bridge:request_quick_sync()
    local t = self._orch:find_transport("syncthing")
    if not t then
        return nil, "no syncthing transport"
    end
    if not t.is_available() then
        return nil, "syncthing not available"
    end
    if not t.supports("quick_sync") then
        return nil, "quick_sync not supported by current provider"
    end
    return t.quick_sync_all()
end


-- ----------------------------------------------------------------------------
-- Daemon process control — passthroughs to the Syncthing
-- transport's KOSyncthing+-only DAEMON_CONTROL surface.
--
-- These are the bridge half of the transport-control surface.
-- Each is gated the same way `request_quick_sync` is: the Syncthing
-- transport must exist, be available, and advertise the optional
-- capability.  Manual-config Syncthing (REST-only) and Cloud
-- never advertise `daemon_control`, so the gate keeps them no-ops and
-- the status panel hides the control for them.
-- ----------------------------------------------------------------------------


--- Resolve the Syncthing transport iff it can do daemon control.
--- Returns the transport, or nil + a short reason.
function Bridge:_daemon_control_transport()
    local t = self._orch:find_transport("syncthing")
    if not t then
        return nil, "no syncthing transport"
    end
    if not t.is_available() then
        return nil, "syncthing not available"
    end
    if not t.supports("daemon_control") then
        return nil, "daemon_control not supported by current provider"
    end
    return t
end


--- Does the Syncthing transport advertise the optional
--- `daemon_control` capability right now?  This is the cheap
--- yes/no the status panel uses to decide whether to render the
--- daemon button — distinct from `is_daemon_running`, which can
--- return nil for two different reasons (no capability vs.
--- capability present but state-read failed).
function Bridge:supports_daemon_control()
    local t = self:_daemon_control_transport()
    return t ~= nil
end


--- Is the Syncthing daemon process currently running?  Returns
--- true/false from the transport, or nil when daemon control is
--- unavailable (transport absent / unavailable / capability not
--- advertised, or the KOSyncthing+ API could not be read).
function Bridge:is_daemon_running()
    local t = self:_daemon_control_transport()
    if not t then return nil end
    return t.is_daemon_running()
end


--- Start the Syncthing daemon process.  `callback(ok, err)` fires
--- exactly once.  When daemon control is unavailable the callback
--- fires synchronously with (false, reason) — never a silent no-op.
function Bridge:start_daemon(callback)
    callback = type(callback) == "function" and callback or function() end
    local t, reason = self:_daemon_control_transport()
    if not t then callback(false, reason); return end
    t.start_daemon(callback)
end


--- Stop the Syncthing daemon process.  Same contract as start_daemon.
function Bridge:stop_daemon(callback)
    callback = type(callback) == "function" and callback or function() end
    local t, reason = self:_daemon_control_transport()
    if not t then callback(false, reason); return end
    t.stop_daemon(callback)
end


-- ----------------------------------------------------------------------------
-- Periodic sync — passthroughs to the Syncthing transport's
-- KOSyncthing+-only PERIODIC_SYNC surface.  Gated exactly like daemon control: the
-- transport must exist, be available, and advertise `periodic_sync`.  Manual
-- (REST-only) Syncthing and Cloud never advertise it, so these stay
-- no-ops and the status panel hides the periodic-sync row for them.
-- ----------------------------------------------------------------------------


--- Resolve the Syncthing transport iff it can do periodic sync.
--- Returns the transport, or nil + a short reason.
function Bridge:_periodic_sync_transport()
    local t = self._orch:find_transport("syncthing")
    if not t then
        return nil, "no syncthing transport"
    end
    if not t.is_available() then
        return nil, "syncthing not available"
    end
    if not t.supports("periodic_sync") then
        return nil, "periodic_sync not supported by current provider"
    end
    return t
end


--- Does the Syncthing transport advertise `periodic_sync` right now?  The
--- cheap yes/no the status panel uses to decide whether to render the
--- periodic-sync row at all.
function Bridge:supports_periodic_sync()
    local t = self:_periodic_sync_transport()
    return t ~= nil
end


--- Periodic-sync state, or nil when unavailable.  Shape:
--- { enabled = bool, interval_minutes = number, next_at = number|nil }.
function Bridge:get_periodic_sync_state()
    local t = self:_periodic_sync_transport()
    if not t then return nil end
    return t.get_periodic_sync_state()
end


--- Enable/disable periodic sync.  Returns the transport's (ok) / (nil, err),
--- or (nil, reason) when periodic sync is unavailable.
function Bridge:set_periodic_sync_enabled(enabled)
    local t, reason = self:_periodic_sync_transport()
    if not t then return nil, reason end
    return t.set_periodic_sync_enabled(enabled)
end


--- Set the periodic-sync interval in minutes.  Same return contract.
function Bridge:set_periodic_sync_interval(minutes)
    local t, reason = self:_periodic_sync_transport()
    if not t then return nil, reason end
    return t.set_periodic_sync_interval(minutes)
end


--- Trigger a periodic sync now (does not shift the schedule).  Same contract.
function Bridge:run_periodic_sync_now()
    local t, reason = self:_periodic_sync_transport()
    if not t then return nil, reason end
    return t.run_periodic_sync_now()
end


--- Shutdown — proxies through.  main.lua's teardown calls this.
function Bridge:shutdown()
    self._orch:shutdown()
end


return Bridge
