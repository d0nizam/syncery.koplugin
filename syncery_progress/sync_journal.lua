-- =============================================================================
-- syncery_progress/sync_journal.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- A device-local, append-only, bounded record of annotation-merge
-- events.  Every time the annotation orchestrator finishes a merge it
-- produces a rich result object (annotations pulled/pushed, tombstones
-- compacted, conflicts merged, the dominant device).  Until now all of
-- that went to the logger and vanished.  This module persists it.
--
-- WHY IT EXISTS
--
-- The whole motivation for the Syncery rewrite was "random deletions
-- and resurrected annotations".  The merge engine is now correct — but
-- a correct model the user cannot SEE does not close the trust gap: a
-- fixed model and a real bug feel identical from the reader's chair.
-- The journal makes "my annotation disappeared" diagnosable instead of
-- mysterious: filter the journal by book_id and the answer is there —
-- "a tombstone from PHONE won at 14:02" (correct, explainable) or
-- "merge ran, touched nothing" (the bug is elsewhere).
--
-- DESIGN CONSTRAINTS:
--
--   * DEVICE-LOCAL, NOT SYNCED.  The journal records what THIS device
--     observed during merge.  It lives under Syncery's private state
--     directory (the same place last-sync ancestors live) — somewhere
--     Syncthing never replicates.  A synced journal would itself
--     become a sync-conflict surface, which is self-defeating.
--
--   * APPEND-MODE, NOT TMP-THEN-RENAME.  Each entry is one JSON object
--     on one line (NDJSON / JSON-lines).  A new entry is appended with
--     `io.open(path, "a")`.  This is Android-safe BY CONSTRUCTION: it
--     never calls `os.rename`, so it sidesteps the FUSE/SAF rename
--     failure entirely.  The
--     self-trim (below) rewrites with a plain truncating `io.open(
--     path, "w")` — also no `os.rename`, also Android-safe.  There is
--     deliberately NO atomic-write path in this module.
--
--   * BOUNDED / SELF-TRIMMING.  Append-only without a bound is a
--     slow-growing liability on a heavily-used book.  `append` trims
--     to a ring of the last MAX_ENTRIES entries IN THE SAME OPERATION:
--     it appends the new line, then — if the file now exceeds the
--     bound — rewrites it keeping only the newest MAX_ENTRIES lines.
--     The common case (under the bound) does only the cheap append.
--
--   * SCHEMA-VERSIONED.  The payoff is "diagnosable months later", so
--     the entry format is a long-lived contract.  Every entry carries
--     its own `schema_version` (per-line, not a file header — a
--     pure-append writer can't maintain a header), plus a flat,
--     explicit shape the eventual UI can read stably.
--
-- THE FAILED / NO-OP QUESTION:
--
--   Should a merge that failed, was skipped, or changed nothing also
--   journal an entry?
--   DECISION: YES.  `record_merge` journals EVERY merge the
--   orchestrator runs, tagged with an `outcome` of "merged" / "noop" /
--   "skipped" / "failed".  The reasoning:  a journal that records only
--   successful non-trivial merges cannot answer "did a merge even run
--   for this book?" — and absence-of-entry is only a meaningful signal
--   when non-events are normally present.  "Merge ran, touched
--   nothing" IS the diagnostic for "the bug is not in the merge".
--   Consequence: the ring
--   bound counts non-events too, so on a quiet device the ring still
--   rotates; MAX_ENTRIES is sized generously to keep a useful window.
--
-- SCOPE: a kind-tagged sync-event journal.
--
--   Records, in one `kind`-tagged ring, annotation merges
--   (kind="annotation", record_merge), progress syncs and jumps
--   (kind="progress", record_progress / record_jump), status-conflict
--   resolutions (kind="status", record_status_resolve), and first-install
--   bulk-ingest backfills (kind="bulk", record_bulk) -- so the diagnostic
--   can answer "what synced for this book and when?" across every path.
--
--   Progress merges fire on EVERY autosave, so a naive log would flood
--   the ring with low-information entries.  record_progress drops two
--   classes at its write site: a PURE noop (nothing pushed, no conflict,
--   no skip, no error), and a routine POSITION PUSH that is not itself an
--   event -- either a steady-state autosave (the ~720/hr flood) or a
--   jump's follow-up push (record_jump already wrote the canonical
--   "jumped" line, so the push is redundant).  record_merge drops the
--   same non-event class on the annotation side: its back-sync runs
--   unconditionally on close (teardown Step 2, for the wipe failsafe), so
--   a PURE noop and an empty-skip (skipped_reason "empty" -- a sync section
--   off, or the book has no data) are dropped too, otherwise EVERY close
--   would write a line and evict the meaningful entries.  Conflicts, skips,
--   and errors land even under an autosave or jump; a wipe_failsafe (or any
--   non-"empty") skip lands; manual / close / suspend always land.  Only a
--   meaningful sync EVENT lands.  A v3 entry (no `kind`) reads back as
--   "annotation".
--
-- UI IS A LATER PASS.  This module is the WRITER + schema + the
-- device-local file.  Surfacing the journal is a separate pass and a
-- natural extension of `syncery_ui/status_panel.lua` — "per-book sync
-- history" is the same surface as the panel's "per-book pending
-- retries".  `read_all` is provided for that future consumer (and for
-- this module's own spec).
--
-- =============================================================================

local Paths  = require("syncery_progress/paths")
local logger = require("logger")

local SyncJournal = {}


-- ----------------------------------------------------------------------------
-- Constants
-- ----------------------------------------------------------------------------


--- Entry-format version.  Bumped only when the flat entry shape below
--- changes in a way the eventual UI would need to know about.  Stamped
--- on every entry (per-line) so a reader can handle a mixed-version
--- file after an upgrade.
SyncJournal.SCHEMA_VERSION = 4


--- Ring-buffer bound.  After an append leaves the file longer than
--- this, the oldest entries are dropped so exactly MAX_ENTRIES remain.
--- Sized for a useful diagnostic window given that no-op merges are
--- journalled too (see the header).  ~300 flat JSON objects is on the
--- order of tens of KB — negligible on every device we target.
SyncJournal.MAX_ENTRIES = 300


-- ----------------------------------------------------------------------------
-- JSON
--
-- Match the rest of the codebase: rapidjson in KOReader, cjson in the
-- test harness.  Both encode flat tables compactly (no embedded
-- newlines), which is what the one-object-per-line format requires.
-- ----------------------------------------------------------------------------


local function load_json()
    local ok_rj, rj = pcall(require, "rapidjson")
    if ok_rj then return rj end
    local ok_cj, cj = pcall(require, "cjson")
    if ok_cj then return cj end
    return nil
end


-- ----------------------------------------------------------------------------
-- Path resolution
-- ----------------------------------------------------------------------------


--- Resolve the journal file path.
---
--- `opts.path` overrides (the seam the spec uses to point at a temp
--- file).  Otherwise the device-local path from progress paths.lua.
local function resolve_path(opts)
    if opts and opts.path then return opts.path end
    return Paths.sync_journal_path()
end


-- ----------------------------------------------------------------------------
-- Internal: count / read / trim
-- ----------------------------------------------------------------------------


--- Read every raw line of the journal file (no JSON decoding).
--- Returns a list of strings; empty list when the file is absent.
local function read_lines(path)
    local lines = {}
    local f = io.open(path, "r")
    if not f then return lines end
    for line in f:lines() do
        if line ~= "" then
            table.insert(lines, line)
        end
    end
    f:close()
    return lines
end


--- Trim the file in place to at most MAX_ENTRIES lines.
---
--- Only ever called right after an append, and only when the line
--- count exceeds the bound — so this rewrite is the uncommon path.
--- The rewrite uses a plain truncating `io.open(path, "w")`: NOT
--- tmp-then-`os.rename`, so it carries no Android FUSE/SAF rename
--- hazard.  Worst case if the device dies
--- mid-rewrite is a truncated diagnostic file — never user data.
local function trim_if_needed(path, max_entries)
    local lines = read_lines(path)
    if #lines <= max_entries then return end

    local keep_from = #lines - max_entries + 1
    local f, err = io.open(path, "w")
    if not f then
        logger.warn("Syncery sync_journal: trim rewrite failed to open "
            .. tostring(path) .. ": " .. tostring(err))
        return
    end
    for i = keep_from, #lines do
        f:write(lines[i], "\n")
    end
    f:close()
end


-- ----------------------------------------------------------------------------
-- Public: append
-- ----------------------------------------------------------------------------


--- Append one already-built entry table to the journal, then trim.
---
--- The entry is stamped with `schema_version` here (callers don't
--- supply it) and encoded to a single compact JSON line.  Append uses
--- `io.open(path, "a")` — no rename, Android-safe by construction.
--- Bounding happens in the SAME call: `trim_if_needed` runs straight
--- after, so the file is never left over the ring bound.
---
--- Best-effort: every failure path logs and returns false rather than
--- raising — a diagnostic tool must never be able to break the save
--- pipeline it observes.
---
--- @param entry table A flat entry table (see record_merge for shape).
--- @param opts  table|nil { path = string }  — `path` overrides the
---                          device-local default (used by the spec).
--- @return boolean true on a successful append.
function SyncJournal.append(entry, opts)
    if type(entry) ~= "table" then
        logger.warn("Syncery sync_journal: append called with non-table entry")
        return false
    end

    local json = load_json()
    if not json then
        logger.warn("Syncery sync_journal: no JSON library available; "
            .. "skipping journal append")
        return false
    end

    local path = resolve_path(opts)
    if not path then
        logger.warn("Syncery sync_journal: could not resolve journal path")
        return false
    end

    -- Stamp the schema version here so callers never have to.
    entry.schema_version = SyncJournal.SCHEMA_VERSION

    local ok_enc, encoded = pcall(json.encode, entry)
    if not ok_enc or type(encoded) ~= "string" then
        logger.warn("Syncery sync_journal: entry encode failed: "
            .. tostring(encoded))
        return false
    end

    -- Defensive: a newline inside the encoded object would corrupt the
    -- one-object-per-line format.  A flat table of strings/numbers
    -- never produces one, but guard anyway rather than trust input.
    if encoded:find("\n", 1, true) then
        encoded = encoded:gsub("[\r\n]", " ")
    end

    -- THE APPEND.  "a" mode — no os.rename, Android-safe by construction.
    local f, err = io.open(path, "a")
    if not f then
        logger.warn("Syncery sync_journal: could not open journal for append ("
            .. tostring(path) .. "): " .. tostring(err))
        return false
    end
    f:write(encoded, "\n")
    f:close()

    -- THE TRIM — same operation as the append, per the bounded-by-
    -- construction design constraint.
    trim_if_needed(path, opts and opts.max_entries or SyncJournal.MAX_ENTRIES)

    return true
end


-- ----------------------------------------------------------------------------
-- Public: record_merge — build an entry from an orchestrator result
-- ----------------------------------------------------------------------------


--- Classify a merge result into one of the four `outcome` values.
---
---   "failed"  — the orchestrator reported an error.
---   "skipped" — a failsafe (e.g. the wipe failsafe) declined to merge.
---   "noop"    — the merge ran cleanly but changed nothing at all.
---   "merged"  — the merge ran cleanly and moved data.
local function classify_outcome(result, ann_merged, tombstones, conflicts)
    if result.error and not result.ok then return "failed" end
    if result.skipped then return "skipped" end
    if ann_merged == 0 and tombstones == 0 and conflicts == 0 then
        return "noop"
    end
    return "merged"
end


--- Build a journal entry from an ANNOTATION orchestrator result object
--- and append it.
---
--- The result object is the one returned by
--- `syncery_ann/sync_orchestrator.lua`'s `sync_book`; its shape mirrors
--- that module's result contract:
---
---   result.annotations_pulled    new-from-remote count
---   result.annotations_pushed    new-from-local count
---   result.annotations_before    alive annotation count BEFORE the merge
---   result.annotations_after     alive annotation count AFTER the merge
---   result.tombstones_compacted  tombstones aged to minimal form
---   result.conflicts_merged      Syncthing conflict files folded in
---   result.ok / .error / .skipped / .skipped_reason   outcome signals
---
--- `opts.trigger` (string|nil) records WHAT started this sync (e.g.
--- "close", "suspend", "save", "autosave", "manual", "remote_check",
--- "wipe_override"), so the journal shows the cause over time, not just
--- the effect.  May be nil (older entries / a spec that omits it).
---
--- NOTE on `winning_device`: this records the device that RAN the sync,
--- taken from the LIVE current device via opts.writer_device_id/label
--- (the caller passes them).  Earlier this was read from
--- `merged_state.device_id` (the merge-level dominant device), but the
--- shared file is now written device-agnostic -- no top-level "who last
--- wrote" stamp, to avoid Syncthing churn -- so merged_state carries no
--- writer id.  The journal is device-local, so "who ran it"
--- is exactly this device; per-annotation attribution lives on each
--- annotation's own `device_id` instead.
---
--- @param book_id   string  The book's content id (stable across devices).
--- @param result    table   An annotation orchestrator result.
--- @param transport string  The transport context driving this sync
---                           ("syncthing" / "cloud" / "local").
--- @param opts      table|nil { path, clock, writer_device_id,
---                            writer_device_label }.  `clock` returns
---                            epoch seconds, defaults to os.time;
---                            `path` overrides the journal file (spec
---                            seam); `writer_device_id`/`_label` are the
---                            live device that ran the sync, recorded as
---                            `winning_device`/`_label` for display.
--- @return boolean true on a successful append.
-- A count worth a line: nil when zero, so a zero-valued count is OMITTED
-- from the entry (a nil key never JSON-encodes), keeping a LOGGED line
-- short -- e.g. a push-only merge omits its zero pulled / conflicts /
-- tombstones.  (A pure noop is not logged at all; see record_merge's
-- non-event drop.)  Shared by record_merge and record_progress.
local function nz(n)
    n = tonumber(n) or 0
    if n > 0 then return n end
    return nil
end


function SyncJournal.record_merge(book_id, result, transport, opts)
    if type(result) ~= "table" then
        logger.warn("Syncery sync_journal: record_merge called with no result")
        return false
    end
    opts = opts or {}

    local clock = opts.clock or os.time

    local ann_merged = (tonumber(result.annotations_pulled) or 0)
                     + (tonumber(result.annotations_pushed) or 0)
    local tombstones = tonumber(result.tombstones_compacted) or 0
    local conflicts  = tonumber(result.conflicts_merged) or 0

    -- v3: record only fields with signal.  Zero-valued counts are OMITTED
    -- (nz, module-level), keeping a LOGGED line short -- e.g. a push-only
    -- merge omits its zero pulled / conflicts / tombstones; the single
    -- reader (diagnostic recent_merges_lines) already defaults an absent
    -- count to 0.  (A pure noop is dropped entirely by the guard below.)
    -- Two fields were dropped as pure redundancy:
    -- annotations_merged (== pulled + pushed) and winning_device_label
    -- (always THIS device for the device-local annotation journal, and
    -- never displayed).  The opaque winning_device id was never stored.
    -- Drop non-events (symmetric with record_progress's noop-skip): a pure
    -- noop (synced, nothing changed) and an empty-skip (nothing to sync --
    -- a sync section is off, or the book has no data) are steady-state, not
    -- events.  The annotation back-sync runs unconditionally on close
    -- (teardown Step 2, for the wipe failsafe), so logging these would write
    -- a line on EVERY close and evict the meaningful entries -- real merges,
    -- conflicts, wipe-failsafe skips, failures -- from the 300-ring faster
    -- (the noise eats the debugging signal).  A wipe_failsafe (or any
    -- non-"empty") skip IS a real protective event and still lands; so do
    -- merges, conflicts, and failures.  An unexpected-empty read bug would
    -- surface elsewhere anyway (the THIS BOOK alive count diverging, the
    -- cross-device absence), not only on this line.  This does not contradict
    -- the empty->skipped label decision: that fixed the LABEL when
    -- logged, not whether to log.
    local outcome = classify_outcome(result, ann_merged, tombstones, conflicts)
    if outcome == "noop" then return false end
    if outcome == "skipped" and result.skipped_reason == "empty" then
        return false
    end

    local entry = {
        -- schema_version is stamped by append().
        timestamp          = clock(),           -- numeric epoch seconds
        kind               = "annotation",      -- v4; readers default a missing kind to this
        book_id            = book_id or "unknown",
        outcome            = outcome,
        trigger            = opts.trigger,       -- what started this; may be nil
        transport          = transport or "local",
        annotations_pulled = nz(result.annotations_pulled),
        annotations_pushed = nz(result.annotations_pushed),
        conflicts_resolved = nz(conflicts),
        tombstones_applied = nz(tombstones),
        skipped_reason     = result.skipped_reason,  -- may be nil
        error              = result.error,       -- failure reason; may be nil
    }

    -- Alive count is a before->after PAIR or nothing: the reader prints
    -- "X->Y alive", so a half-present pair would read "5->?".  Record both
    -- only when the book actually has/had annotations.
    local before = tonumber(result.annotations_before)
    local after  = tonumber(result.annotations_after)
    if (before and before > 0) or (after and after > 0) then
        entry.annotations_before = before or 0
        entry.annotations_after  = after  or 0
    end

    return SyncJournal.append(entry, opts)
end


-- ----------------------------------------------------------------------------
-- Public: record_progress — a progress sync event (kind="progress")
-- ----------------------------------------------------------------------------


--- Record a PROGRESS sync event (a position push and/or a Syncthing
--- conflict resolution) under kind="progress".
---
--- Unlike annotation merges, progress merges fire on EVERY autosave, so a
--- naive log would flood the 300-entry ring.  The anti-flood rule lives
--- here, at the write site: a PURE noop — nothing pushed, no conflict
--- resolved, not skipped, no error — is dropped (returns false, no line).
--- Only a meaningful outcome lands.  "Position changed" is carried by
--- `result.position_pushed`, NOT by `local_revision`, which
--- is stamped on every push_local run regardless of actual movement.
---
--- @param book_id string
--- @param result table  progress sync_book result (position_pushed,
---                      conflicts_merged, local_revision, ok, skipped,
---                      skipped_reason, error)
--- @param transport string|nil
--- @param opts table|nil { trigger, writer_device_label, max_entries, clock }
--- @return boolean|nil  append result, or false when skipped/invalid
function SyncJournal.record_progress(book_id, result, transport, opts)
    if type(result) ~= "table" then
        logger.warn("Syncery sync_journal: record_progress called with no result")
        return false
    end
    opts = opts or {}

    local clock     = opts.clock or os.time
    local conflicts = tonumber(result.conflicts_merged) or 0

    -- Anti-flood: drop a pure noop before building anything.
    local pure_noop = (not result.position_pushed)
                      and conflicts == 0
                      and (not result.skipped)
                      and (not result.error)
    if pure_noop then return false end

    -- Event filter: a routine position push that is not itself an event is
    -- dropped.  Two triggers qualify: "autosave" (steady-state reading
    -- progress -- the ~720/hr flood) and "jump" (the jump's follow-up save;
    -- record_jump already wrote the canonical "jumped" line, so the push is
    -- a redundant mechanical consequence).  A conflict, skip, or error still
    -- lands even under these triggers (those are problems worth a line);
    -- manual / close / suspend always land.
    local routine_push = (opts.trigger == "autosave" or opts.trigger == "jump")
                         and conflicts == 0
                         and (not result.skipped)
                         and (not result.error)
    if routine_push then return false end

    -- Pure noop already filtered, so the outcome is failed / skipped /
    -- merged (a real push and/or conflict resolution).
    local outcome
    if result.error and not result.ok then
        outcome = "failed"
    elseif result.skipped then
        outcome = "skipped"
    else
        outcome = "merged"
    end

    local entry = {
        -- schema_version is stamped by append().
        timestamp          = clock(),           -- numeric epoch seconds
        kind               = "progress",
        book_id            = book_id or "unknown",
        outcome            = outcome,
        trigger            = opts.trigger,       -- what started this; may be nil
        transport          = transport or "local",
        -- Presence means we pushed a NEW position; absent on a conflict-only
        -- or skipped/failed line (a stored `false` would just be noise).
        position_pushed    = result.position_pushed or nil,
        conflicts_resolved = nz(conflicts),
        -- The revision we stamped, meaningful only when we actually pushed.
        revision           = (result.position_pushed and result.local_revision) or nil,
        skipped_reason     = result.skipped_reason,  -- may be nil
        error              = result.error,           -- failure reason; may be nil
    }

    return SyncJournal.append(entry, opts)
end


-- ----------------------------------------------------------------------------
-- Public: record_jump — an adopted-remote-position jump (kind="progress")
-- ----------------------------------------------------------------------------


--- Record a JUMP event: this device adopted another device's reading
--- position.  This is a discrete navigation action, not a sync_book
--- result, so it takes no result object and is never noop-skipped -- a
--- jump always happened and is always worth a line.  kind="progress",
--- outcome="jumped".
---
--- This is the CANONICAL record of a jump.  The position-push that the
--- jump's follow-up save performs is dropped by record_progress's event
--- filter (trigger="jump"), so a jump produces exactly one line, not a
--- "jumped" line plus a redundant "merged" line.
---
--- @param book_id string
--- @param opts table|nil { winning_device_label, transport, max_entries,
---                        writer_device_label, clock }
--- @return boolean|nil  append result
function SyncJournal.record_jump(book_id, opts)
    opts = opts or {}
    local clock = opts.clock or os.time

    local entry = {
        -- schema_version is stamped by append().
        timestamp            = clock(),          -- numeric epoch seconds
        kind                 = "progress",
        book_id              = book_id or "unknown",
        outcome              = "jumped",
        transport            = opts.transport or "local",
        -- The device whose position we adopted; may be nil if unknown.
        winning_device_label = opts.winning_device_label,
    }

    return SyncJournal.append(entry, opts)
end


-- ----------------------------------------------------------------------------
-- Public: record_status_resolve — a reading-status conflict resolution
-- ----------------------------------------------------------------------------


--- Record a status-conflict RESOLUTION: the user picked one terminal
--- reading status (complete / abandoned) to dominate a genuine cross-device
--- conflict, written at generation+1.  kind="status", outcome="merged".
--- Like a jump this is a discrete
--- user action, not a sync_book result, so it takes no result and is never
--- noop-skipped.
---
--- @param book_id string
--- @param status_from string  the conflict, e.g. "abandoned-vs-complete"
--- @param status_to string    the chosen winning value
--- @param opts table|nil { transport, max_entries, writer_device_label, clock }
--- @return boolean|nil  append result
function SyncJournal.record_status_resolve(book_id, status_from, status_to, opts)
    opts = opts or {}
    local clock = opts.clock or os.time

    local entry = {
        -- schema_version is stamped by append().
        timestamp   = clock(),
        kind        = "status",
        book_id     = book_id or "unknown",
        outcome     = "merged",
        transport   = opts.transport or "local",
        status_from = status_from,
        status_to   = status_to,
    }

    return SyncJournal.append(entry, opts)
end


-- ----------------------------------------------------------------------------
-- Public: record_bulk — a first-install bulk-ingest backfill (per book)
-- ----------------------------------------------------------------------------


--- Record a BULK-INGEST backfill of one book: a fresh install adopting an
--- existing book's annotations (and metadata + render) into the shared file
--- for the first time.  One line PER backfilled book (the journal is
--- per-book by design; "which book was backfilled when" is the value).
--- kind="bulk", outcome="merged".  Discrete action, no result, no
--- noop-skip.
---
--- @param book_id string
--- @param opts table|nil { ingested, transport, max_entries,
---                        writer_device_label, clock }
--- @return boolean|nil  append result
function SyncJournal.record_bulk(book_id, opts)
    opts = opts or {}
    local clock = opts.clock or os.time

    local entry = {
        -- schema_version is stamped by append().
        timestamp = clock(),
        kind      = "bulk",
        book_id   = book_id or "unknown",
        outcome   = "merged",
        transport = opts.transport or "local",
        ingested  = opts.ingested,   -- count of annotations backfilled, may be nil
    }

    return SyncJournal.append(entry, opts)
end


-- ----------------------------------------------------------------------------
-- Public: read_all — decode the journal (for the future UI + the spec)
-- ----------------------------------------------------------------------------


--- Read and JSON-decode every entry in the journal, oldest first.
---
--- Malformed lines (a half-written entry from a device that died
--- mid-append, say) are skipped rather than fatal — a diagnostic tool
--- that crashes on its own slightly-damaged file is worse than useless.
---
--- This is the read seam the eventual status_panel "per-book sync
--- history" UI will use; it is not called by the save pipeline.
---
--- @param opts table|nil { path = string }
--- @return table List of decoded entry tables (possibly empty).
function SyncJournal.read_all(opts)
    local json = load_json()
    if not json then return {} end

    local path = resolve_path(opts)
    if not path then return {} end

    local entries = {}
    for _, line in ipairs(read_lines(path)) do
        local ok, decoded = pcall(json.decode, line)
        if ok and type(decoded) == "table" then
            table.insert(entries, decoded)
        end
    end
    return entries
end


--- Delete the journal file outright.  Provided for tests and for a
--- possible future "clear sync history" maintenance action; not used
--- by the save pipeline.
---
--- @param opts table|nil { path = string }
function SyncJournal.clear(opts)
    local path = resolve_path(opts)
    if path then os.remove(path) end
end


return SyncJournal
