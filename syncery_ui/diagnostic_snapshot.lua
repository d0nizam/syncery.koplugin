-- syncery_ui/diagnostic_snapshot.lua
-- =============================================================================
-- PURE diagnostic-snapshot formatter.
--
-- Turns a gathered `data` table (produced by Syncery:_copyDiagnosticInfo in
-- main.lua, which reads the live accessors) into the troubleshooting snapshot:
--
--     DiagnosticSnapshot.build(data) -> {
--         full       = <string>,   -- everything; goes to clipboard + TextViewer
--         essentials = <string>,   -- header + system + transports + faults,
--                                  -- small enough to QR-encode for a phone
--         faults     = { <string>, ... },  -- intent-independent breakage only
--     }
--
-- DESIGN -- two rules this module exists to enforce:
--
--   1. Configuration is reported as a NEUTRAL FACT, never as a problem.
--      A sync toggle being off, a book being excluded, conflict copies
--      being present -- these are user choices or harmless artefacts.  The
--      plugin cannot know the user's intent, so flagging them with a warning
--      would be a false positive that makes the whole report look unreliable
--      (one misplaced warning discredits the real ones).  Only the human, who
--      knows the intent, diagnoses; we present the facts cleanly next to the
--      complaint.
--
--   2. The warning glyph / the Faults line is reserved STRICTLY for
--      intent-independent breakage (a corrupt store, storage I/O errors, a
--      missing .stignore in SDR mode).  None of those are gathered yet, so
--      the fault set is always empty and the line reads "none detected".
--      The render logic for a non-empty set is built and unit-tested here
--      so it is ready the moment detection lands.
--
-- This module has NO widget/UI requires and calls no os.time/os.date, so it
-- is deterministic and runs in the headless suite.  Every wall-clock value
-- (the header date, activity timestamps) is pre-formatted to a string by the
-- gatherer and passed in; the one numeric epoch we carry (a journal entry's
-- timestamp) is rendered through an injected `format_ts` so even that stays
-- out of this module.  This module only lays text out and redacts.
-- =============================================================================

local DiagnosticSnapshot = {}

-- Status glyphs and separators, as byte escapes so the source is encoding-safe
-- regardless of how it is edited.  ✓  ⚠  ·  —
local OK_MARK   = "\xE2\x9C\x93"
local WARN_MARK = "\xE2\x9A\xA0"
local DOT       = "\xC2\xB7"
local DASH      = "\xE2\x80\x94"

-- ---------------------------------------------------------------------------
-- Small formatting helpers
-- ---------------------------------------------------------------------------

local function on_off(v) return v and "on"  or "off" end
local function yes_no(v) return v and "yes" or "no"  end

-- First 7 chars of an id, or a clear placeholder.  Never emit the full id:
-- a content/device id in a publicly-pasted report is needless exposure.
local function short_id(id)
    if type(id) == "string" and id ~= "" then return id:sub(1, 7) end
    return "not cached"
end

-- Strip the directory: a book path becomes its filename.  Full paths can
-- carry the user's account name; the basename is enough to identify a book.
local function base_name(path)
    if type(path) ~= "string" or path == "" then return "?" end
    return path:match("([^/]+)$") or path
end

local function percent(p)
    if type(p) ~= "number" then return "?" end
    return string.format("%d%%", math.floor(p * 100 + 0.5))
end

-- key-value row, aligned for a monospaced text viewer.
local function kv(k, v)
    return string.format("  %-13s%s", k, tostring(v))
end

-- One section block: a leading blank line, the title, then the body lines.
local function section(title, body)
    local out = { "", title }
    for _, l in ipairs(body) do out[#out + 1] = l end
    return table.concat(out, "\n")
end

-- The Faults line.  Empty set -> a positive confirmation; non-empty -> the
-- list, each item intent-independent breakage.  Its own function so both
-- renderings stay unit-tested.
local function faults_line(faults)
    if #faults == 0 then return "Faults: " .. OK_MARK .. " none detected" end
    return "Faults: " .. WARN_MARK .. " " .. table.concat(faults, " " .. DOT .. " ")
end

-- Derive the intent-independent breakage list from the gathered integrity
-- facts (the gatherer does the I/O and reports plain booleans; the decision
-- of what counts as a FAULT lives here, pure and testable).
--
-- CRITICAL: each fault fires ONLY on an explicit `== false` -- never on nil.
-- A nil means "not checked / unknown" (store_decode_ok is nil when no book is
-- open; stignore_present is nil outside SDR or when the folder root can't be
-- resolved), and flagging an unknown would be precisely the false positive the
-- whole design forbids.  Only a confirmed-broken fact raises a fault; anything
-- unknown stays silent.
local function compute_faults(integrity)
    local faults = {}
    if integrity.store_exists and integrity.store_decode_ok == false then
        faults[#faults + 1] =
            "this book's annotation store is unreadable (corrupt JSON)"
    end
    if integrity.stignore_applicable and integrity.stignore_present == false then
        faults[#faults + 1] =
            "Syncthing .stignore missing -- sidecar conflict suppression inactive"
    end
    return faults
end

-- ---------------------------------------------------------------------------
-- Section builders (each returns a list of body lines)
-- ---------------------------------------------------------------------------

local function system_lines(meta, storage)
    return {
        kv("Plugin",   meta.plugin_version or "?"),
        kv("KOReader",  meta.koreader_version or "?"),
        kv("Platform",  meta.platform or "?"),
        kv("Device",   (meta.device_label or "?")
                       .. " (" .. short_id(meta.device_id) .. ")"),
        kv("Storage",  (storage.mode or "?")
                       .. (storage.root
                           and ("  " .. DOT .. "  " .. base_name(storage.root))
                           or "")),
    }
end

-- The annotations row: "off", or "on (highlights, notes, bookmarks)".  Like the
-- metadata row, sub-types are listed only when the master is on.  Bookmarks are
-- page-only annotations synced through the SAME annotation path, so there is no
-- standalone bookmark sync -- they are one of the three sub-types here.  When
-- the master is on but every sub-type is off, _annotations_enabled is false (it
-- needs the master AND at least one sub-type), so NOTHING actually syncs: report
-- "off (no types)" rather than a misleading "on".
local function annotations_value(t)
    if not t.annotations then return "off" end
    local subs = {}
    if t.highlights then subs[#subs + 1] = "highlights" end
    if t.notes      then subs[#subs + 1] = "notes"      end
    if t.bookmarks  then subs[#subs + 1] = "bookmarks"  end
    if #subs == 0 then return "off (no types)" end
    return "on (" .. table.concat(subs, ", ") .. ")"
end

-- The metadata row: "off", or "on", or "on (status, rating, ...)".  Sub-items
-- are listed only when the metadata master is on -- otherwise they are moot.
local function metadata_value(t)
    if not t.metadata then return "off" end
    local subs = {}
    if t.status          then subs[#subs + 1] = "status"       end
    if t.rating          then subs[#subs + 1] = "rating"       end
    if t.collections     then subs[#subs + 1] = "collections"  end
    if t.custom_metadata then subs[#subs + 1] = "custom-title" end
    if t.handmade_toc    then subs[#subs + 1] = "toc"          end
    if #subs == 0 then return "on" end
    return "on (" .. table.concat(subs, ", ") .. ")"
end

local function whats_synced_lines(t)
    local lines = {
        kv("Progress",    on_off(t.progress)),
        kv("Annotations", annotations_value(t)),
        kv("Metadata",    metadata_value(t)),
        kv("Render",      on_off(t.render)),
        kv("Tombstone",   tostring(t.tombstone_ttl_days or "?") .. "d"),
    }
    if t.conflict_strategy then
        lines[#lines + 1] = kv("Conflict", t.conflict_strategy)
    end
    return lines
end

local function transport_lines(transports)
    local tids = {}
    for tid in pairs(transports) do tids[#tids + 1] = tid end
    table.sort(tids)                              -- deterministic output

    if #tids == 0 then return { "  (no transports)" } end

    local lines = {}
    for _, tid in ipairs(tids) do
        local t = transports[tid] or {}
        local parts = { on_off(t.enabled), "avail " .. yes_no(t.available) }
        if t.summary and t.summary ~= "" then
            parts[#parts + 1] = t.summary
        end
        if t.last_error_class then
            parts[#parts + 1] = "last error: " .. t.last_error_class
        end
        if t.pending_retry then
            parts[#parts + 1] = "retry pending"
        end
        lines[#lines + 1] = string.format("  %-11s%s",
            (t.name or tid), table.concat(parts, "  " .. DOT .. "  "))
    end
    return lines
end

local function this_book_lines(tb)
    return {
        kv("File",        base_name(tb.file)),
        kv("Id",          short_id(tb.id)),
        kv("Excluded",    yes_no(tb.excluded)),
        kv("Annotations", tostring(tb.annotations or 0)),
        kv("Progress",    percent(tb.percent)),
        kv("Shared rec",  yes_no(tb.shared_record)),
        kv("Last merge",  tb.last_merge or DASH),
    }
end

-- Journal: an outcome ratio over the recorded merges, then the not-OK ones
-- (skipped/failed) with their reason -- that is where a real problem shows.
local function recent_merges_lines(journal, format_ts)
    if #journal == 0 then return { "  (no syncs recorded)" } end

    local counts = { merged = 0, noop = 0, skipped = 0, failed = 0, jumped = 0 }
    for _, e in ipairs(journal) do
        if counts[e.outcome] ~= nil then counts[e.outcome] = counts[e.outcome] + 1 end
    end

    local sep = "  " .. DOT .. "  "
    -- Count line: the total, then every outcome with a NON-ZERO count.  A
    -- healthy log stays compact ("12: 12 merged"); problems (skipped /
    -- failed) surface only when they exist, so they stand out instead of
    -- hiding among permanent zeros.  Ordered for stable output; the shown
    -- counts sum to the total because every current outcome is in the table.
    local parts = {}
    for _, k in ipairs({ "merged", "noop", "skipped", "failed", "jumped" }) do
        if counts[k] > 0 then parts[#parts + 1] = counts[k] .. " " .. k end
    end
    local lines = {
        string.format("  last %d: %s", #journal,
            #parts > 0 and table.concat(parts, sep) or "no classified outcomes"),
    }

    -- The newest entry in full: what just happened, with its trigger, the
    -- pull/push direction, and the alive count before->after.  Newest is
    -- appended last in the file.
    local latest = journal[#journal]
    if latest then
        -- Prefix: when (readable -- only if a formatter was injected; this
        -- module stays os.date-free for determinism), the event kind, and
        -- which book (7-char).  v3 entries have no kind -> "annotation".
        local when  = format_ts and format_ts(latest.timestamp)
        local kind  = latest.kind or "annotation"
        local stamp = (when and (when .. "  " .. DOT .. "  ") or "")
                      .. "[" .. kind .. "]  " .. DOT .. "  "
                      .. short_id(latest.book_id) .. "  " .. DOT .. "  "

        -- The body is kind-specific: a status resolution shows what won, a
        -- jump shows the adopted device, a bulk backfill shows the ingested
        -- count, and an annotation/progress merge shows its trigger + alive
        -- movement + (for a progress push) the pushed revision.  A noop adds
        -- nothing, so its line stays "<when> . <book> . noop via <trigger>".
        local body = latest.outcome
        if latest.status_to then
            body = body .. " " ..
                   (latest.status_from and (latest.status_from .. " -> ") or "-> ") ..
                   latest.status_to
        elseif latest.outcome == "jumped" then
            if latest.winning_device_label then
                body = body .. " via " .. latest.winning_device_label
            end
        elseif latest.ingested ~= nil then
            body = body .. string.format(" (%d ingested)", latest.ingested)
        else
            if latest.trigger then body = body .. " via " .. latest.trigger end
            local pulled = tonumber(latest.annotations_pulled) or 0
            local pushed = tonumber(latest.annotations_pushed) or 0
            if pulled > 0 or pushed > 0 then
                body = body .. string.format(", pulled %d / pushed %d", pulled, pushed)
            end
            if latest.annotations_before ~= nil or latest.annotations_after ~= nil then
                body = body .. string.format(", %s->%s alive",
                    tostring(latest.annotations_before or "?"),
                    tostring(latest.annotations_after or "?"))
            end
            if latest.revision then
                body = body .. string.format(", rev %d", latest.revision)
            end
        end
        lines[#lines + 1] = "  latest: " .. stamp .. body
    end

    -- The most recent not-OK entries (skipped/failed) with trigger + reason,
    -- capped so a flood can't bloat the report.  Failed entries carry
    -- `error` (not skipped_reason), so fall back to it.
    local shown = 0
    for i = #journal, 1, -1 do
        local e = journal[i]
        if e.outcome == "skipped" or e.outcome == "failed" then
            local why    = e.skipped_reason or e.error
            local reason = why and (": " .. why) or ""
            local trig   = e.trigger and (" [" .. e.trigger .. "]") or ""
            lines[#lines + 1] = string.format("  ! %-9s %s%s%s",
                short_id(e.book_id), e.outcome, trig, reason)
            shown = shown + 1
            if shown >= 8 then break end
        end
    end
    return lines
end

local function recent_activity_lines(activity)
    if #activity == 0 then return { "  (none)" } end
    local lines = {}
    local n = math.min(#activity, 5)
    for i = 1, n do
        local a = activity[i]
        local detail = (a.detail and a.detail ~= "")
                       and ("  " .. DASH .. "  " .. a.detail) or ""
        lines[#lines + 1] = string.format("  %s  %s%s",
            a.when or "?", a.kind or "?", detail)
    end
    return lines
end

-- Storage & integrity facts, reported NEUTRALLY (the warning glyph for any
-- real breakage lives on the Faults line, not here -- this section just states
-- what was found).  Each field distinguishes nil ("not checked") from a
-- definite value, so an unknown reads as "n/a" rather than a scary default.
local function storage_integrity_lines(integrity)
    local lines = {}

    -- Store status.  Book-scoped: store_exists is nil when no book is open.
    local store_val
    if integrity.store_exists == nil then
        store_val = "n/a (no book open)"
    elseif integrity.store_exists == false then
        store_val = "none yet"
    elseif integrity.store_decode_ok == false then
        store_val = "UNREADABLE (corrupt JSON)"
    else
        store_val = "ok"
    end
    lines[#lines + 1] = kv("Store", store_val)

    -- Conflict copies near this book.  Neutral: they self-clean on next open.
    if integrity.conflict_count ~= nil then
        lines[#lines + 1] = kv("Conflicts",
            tostring(integrity.conflict_count) .. " copies")
    end

    -- Tombstones: deletions recorded in this book's synced store.  A permanent
    -- marker (compacted after the TTL, never removed), so a count of 0 vs N is
    -- itself the signal -- it confirms whether deletions were captured for sync.
    -- Neutral: tombstones are how deletions propagate, not a problem.
    if integrity.tombstone_count ~= nil then
        lines[#lines + 1] = kv("Tombstones",
            tostring(integrity.tombstone_count) .. " recorded")
    end

    -- .stignore: only applicable in SDR mode with a configured Syncthing folder.
    local stignore_val
    if not integrity.stignore_applicable then
        stignore_val = "n/a"
    elseif integrity.stignore_present == true then
        stignore_val = "present"
    elseif integrity.stignore_present == false then
        stignore_val = "MISSING"
    else
        stignore_val = "unknown"
    end
    lines[#lines + 1] = kv(".stignore", stignore_val)

    return lines
end

-- ---------------------------------------------------------------------------
-- Public: build
-- ---------------------------------------------------------------------------

function DiagnosticSnapshot.build(data)
    data = data or {}
    local meta    = data.meta    or {}
    local storage = data.storage or {}
    local toggles = data.toggles or {}
    local integrity = data.integrity or {}

    -- Faults are DERIVED from the gathered integrity facts (see compute_faults),
    -- not passed in -- so the only way a fault can appear is a confirmed-broken
    -- fact.  Empty in the common healthy case.
    local faults = compute_faults(integrity)

    local header = "Syncery " .. (meta.plugin_version or "?")
                   .. "  " .. DOT .. "  " .. (meta.date_str or "?")
    local fline  = faults_line(faults)

    local sys_block    = section("SYSTEM",          system_lines(meta, storage))
    local synced_block = section("WHAT'S SYNCED",   whats_synced_lines(toggles))
    local trans_block  = section("TRANSPORTS",      transport_lines(data.transports or {}))
    local merges_block = section("RECENT SYNCS",   recent_merges_lines(data.journal or {}, data.format_ts))
    local act_block    = section("RECENT ACTIVITY", recent_activity_lines(data.activity or {}))
    local footer       = "(IDs truncated " .. DOT .. " no credentials included)"

    -- full: everything, in triage order.  THIS BOOK only when one is open.
    local full_parts = { header, fline, sys_block, synced_block, trans_block }
    if data.this_book then
        full_parts[#full_parts + 1] = section("THIS BOOK", this_book_lines(data.this_book))
    end
    full_parts[#full_parts + 1] =
        section("STORAGE & INTEGRITY", storage_integrity_lines(integrity))
    full_parts[#full_parts + 1] = merges_block
    full_parts[#full_parts + 1] = act_block
    local full = table.concat(full_parts, "\n") .. "\n\n" .. footer

    -- essentials: just enough to triage and to fit a scannable QR code --
    -- "is it set up, is the pipe up, is anything broken".
    local essentials = table.concat({ header, fline, sys_block, trans_block }, "\n")
                       .. "\n\n" .. footer

    return { full = full, essentials = essentials, faults = faults }
end

-- Count the deletions (tombstones) recorded in a decoded shared-store table.
-- A tombstone is an annotation entry marked `deleted = true`.  Exposed so the
-- gatherer (which does the I/O to decode the store) can keep this bit of
-- logic tested.  Defensive: a nil or shapeless store yields 0, never an error.
function DiagnosticSnapshot.count_tombstones(store_data)
    local n = 0
    local anns = type(store_data) == "table" and store_data.annotations
    if type(anns) == "table" then
        for _key, ann in pairs(anns) do
            if type(ann) == "table" and ann.deleted == true then n = n + 1 end
        end
    end
    return n
end

return DiagnosticSnapshot
