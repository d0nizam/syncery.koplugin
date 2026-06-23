-- =============================================================================
-- syncery_progress/progress_bridge.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- It's the translator between KOReader's live reading position
-- (scattered across `ui.document`, `ui.rolling`, `ui.footer`, ...)
-- and Syncery's per-device entry shape.
--
-- One direction only: live → entry.  We do NOT apply a remote
-- entry back to KOReader from here — jumping the reader to a remote
-- position is a UI concern (it goes through a prompt that asks the
-- user "Stay here or jump?"), handled in main.lua.  The bridge's
-- job ends at producing a clean entry object.
--
--
-- THE ENTRY SHAPE
--
-- An entry is the per-device record stored under
-- `state.entries[device_id]`:
--
--   {
--     revision    = <int>,         -- stamped by Merge.upsert_local_entry
--     percent     = <0..1 float>,  -- how far through the book (0..1)
--     page        = <int>,         -- current page (1-indexed)
--     total_pages = <int>,         -- total pages in the document
--     xpath       = <string|nil>,  -- DOM xpointer (rolling docs only)
--     file        = <string>,      -- absolute path to the book file
--     label       = <string>,      -- friendly device name ("Phone")
--     timestamp   = <epoch sec>,   -- stamped by Merge.upsert_local_entry
--     device_id   = <string>,      -- stamped by Merge.upsert_local_entry
--     -- Legacy progress also carried `status`, `rating`, `collections`
--     -- here.  We carry those fields through verbatim if a remote
--     -- device wrote them (for backward compatibility with devices
--     -- still running the legacy plugin), but the NEW code does NOT
--     -- write them — those concerns belong to the annotation/metadata
--     -- bridge now.
--   }
--
--
-- DISPLAY FILTERING (the "stale device" question)
--
-- The legacy plugin had `_pruneStaleProgress` which DELETED entries
-- older than 90 days from the shared file.  That worked but created
-- a race: a device that came back online after 90 days could
-- resurrect itself in the file via Syncthing, and the freshly-pruning
-- device would prune it again, and the cycle would repeat.
--
-- The new approach: never structurally delete.  Instead, `filter_fresh_for_display`
-- returns a view-only filtered map for UI rendering (booklist panel,
-- jump prompt, "all positions" sheet).  The shared file keeps every
-- entry forever.  A future "Forget device X" UI action would be the
-- only way to structurally remove one.
--
-- =============================================================================

local logger = require("logger")

local ProgressBridge = {}


-- ----------------------------------------------------------------------------
-- Public API: live → entry
-- ----------------------------------------------------------------------------


--- Read the current reading position from KOReader's live state.
---
--- Pulls fields from `ui.document`, `ui.rolling` (rolling docs),
--- `ui.footer` (percent / page indicators), with the same fallback
--- chain the legacy `Syncery:getCurrentState` used.
---
--- The returned entry has NO revision and NO timestamp — those get
--- stamped by `Merge.upsert_local_entry` when the orchestrator
--- writes it.
---
--- Returns nil if there's no document open or the document has no
--- file path (KOReader sometimes has a half-initialized state right
--- after open).
---
--- @param ui table KOReader's ReaderUI for the currently-open book.
--- @param device_label string|nil Friendly device name to stamp on the entry.
--- @return table|nil The entry, or nil if there's nothing to read.
function ProgressBridge.read_from_live(ui, device_label)
    if not ui then return nil end

    local document = ui.document
    if not document or not document.file then return nil end

    local current_page, total_pages, xpath, percent =
        ProgressBridge._read_position_fields(ui)

    -- Fill percent from footer if we still don't have one.
    if not percent then
        percent = ProgressBridge._derive_percent_from_pages(current_page, total_pages)
    end

    return {
        file        = document.file,
        page        = current_page or 1,
        total_pages = total_pages or 0,
        xpath       = xpath,
        percent     = percent or 0,
        label       = device_label,
        is_rolling  = ui.rolling ~= nil,
    }
end


-- ----------------------------------------------------------------------------
-- Public API: view filtering
-- ----------------------------------------------------------------------------


--- Filter a state map down to "fresh enough to show in UI".
---
--- Entries older than `freshness_days` (by their timestamp field)
--- are omitted.  The original map is NOT modified.
---
--- This is a VIEW filter only — call it on the way to displaying
--- the booklist panel or jump prompt.  Never on the way to disk.
---
--- @param entries_map table A { [device_id] = entry } map.
--- @param freshness_days number How many days old is "still fresh".
--- @param now_epoch_seconds number|nil Override "now"; defaults to os.time().
--- @return table A new map containing only fresh entries.
function ProgressBridge.filter_fresh_for_display(entries_map, freshness_days, now_epoch_seconds)
    if type(entries_map) ~= "table" then return {} end
    freshness_days   = freshness_days   or 90
    now_epoch_seconds = now_epoch_seconds or os.time()

    local cutoff = now_epoch_seconds - (freshness_days * 86400)
    local fresh  = {}

    for device_id, entry in pairs(entries_map) do
        if type(entry) == "table" then
            local entry_ts = tonumber(entry.timestamp) or 0
            if entry_ts >= cutoff then
                fresh[device_id] = entry
            end
        end
    end

    return fresh
end


--- Strip fields the new progress engine doesn't write itself.
---
--- When we write our entry, we don't write `status`, `rating`,
--- `collections`, `summary`, etc. — those belong to the annotation/
--- metadata bridge.  But OTHER devices' entries (especially from
--- devices still running the legacy plugin) may have those fields
--- in the file.
---
--- This helper is used only when building OUR OWN local entry, to
--- make sure we don't accidentally splat stale metadata over fresh
--- writes from the metadata bridge.
---
--- @param entry table The entry to clean.
--- @return table A new entry with the metadata fields removed.
function ProgressBridge.strip_metadata_fields(entry)
    if type(entry) ~= "table" then return {} end
    local cleaned = {}
    for k, v in pairs(entry) do
        if k ~= "status" and k ~= "rating" and k ~= "collections"
                and k ~= "summary" and k ~= "custom_metadata"
                and k ~= "handmade_toc" then
            cleaned[k] = v
        end
    end
    return cleaned
end


-- ----------------------------------------------------------------------------
-- Internal: live-state readers
-- ----------------------------------------------------------------------------


--- Extract (page, total_pages, xpath, percent) from a live ReaderUI.
---
--- Tries several KOReader APIs in order, mirroring what the legacy
--- `getCurrentState` did:
---   * `ui.rolling.current_page` / `xpointer` (rolling docs)
---   * `document:getCurrentPage()` / `getPageCount()` / `getXPointer()` (fallback)
---   * `ui.footer` for percent + override page/total
function ProgressBridge._read_position_fields(ui)
    local document = ui.document
    local page, total, xpath, percent

    if ui.paging then
        page  = ProgressBridge._safe_int_call(document.getCurrentPage, document)
        total = ProgressBridge._safe_int_call(document.getPageCount,   document)
    elseif ui.rolling then
        page  = tonumber(ui.rolling.current_page)
        -- ReaderRolling exposes no total_pages field; the page count comes from
        -- the document, same as the paging branch.  The footer fallback below
        -- still applies if this is unavailable.
        total = ProgressBridge._safe_int_call(document.getPageCount, document)

        if type(ui.rolling.xpointer) == "string"
                and ui.rolling.xpointer ~= "" then
            xpath = ui.rolling.xpointer
        else
            local x = ProgressBridge._safe_string_call(document.getXPointer, document)
            if x and x ~= "" then xpath = x end
        end
    else
        -- Some document types report neither rolling nor paging right
        -- after open.  Fall back to the generic page-count APIs.
        page  = ProgressBridge._safe_int_call(document.getCurrentPage, document)
        total = ProgressBridge._safe_int_call(document.getPageCount,   document)
    end

    local footer = ui.footer or (ui.view and ui.view.footer)
    if footer then
        if type(footer.percent_finished) == "number" then
            percent = footer.percent_finished
        end
        if not page and footer.pageno then
            page = tonumber(footer.pageno)
        end
        if not total and footer.pages then
            total = tonumber(footer.pages)
        end
    end

    return page, total, xpath, percent
end


--- If we still don't have a percent after asking the footer, derive
--- one from page/total.  Same formula KOReader uses: (page-1)/total.
function ProgressBridge._derive_percent_from_pages(page, total)
    if not page or not total or total <= 0 then return 0 end
    return (page - 1) / total
end


--- pcall wrapper for callable_or_nil(...) that returns an int or nil.
---
--- KOReader's document methods occasionally throw on partially-loaded
--- documents.  We swallow errors and return nil, leaving the field
--- to be filled in by the next source in the fallback chain.
function ProgressBridge._safe_int_call(method_or_nil, self_obj)
    if type(method_or_nil) ~= "function" then return nil end
    local ok, value = pcall(method_or_nil, self_obj)
    if ok and type(value) == "number" and value > 0 then
        return value
    end
    return nil
end


function ProgressBridge._safe_string_call(method_or_nil, self_obj)
    if type(method_or_nil) ~= "function" then return nil end
    local ok, value = pcall(method_or_nil, self_obj)
    if ok and type(value) == "string" then
        return value
    end
    return nil
end


--- Build the arguments for a "GotoXPointer" resume jump.
---
--- Returns the target xpointer twice: once as the navigation target, once
--- as `marker_xp`.  KOReader's ReaderRolling:onGotoXPointer(xp, marker_xp)
--- jumps to `xp` and, when `marker_xp` is given, flashes its followed-link
--- marker — a thin tick in the left margin at that line — for ~1s
--- (G_reader_settings "followed_link_marker", default 1).
---
--- We deliberately mark the SAME position we jump to (the last-read
--- position), so the marker simply helps the eye find the resumed line
--- after the page has been re-laid-out on a device with different font,
--- margins, or screen size.  We never anchor anywhere other than the
--- last-read position, so the jump itself can never skip unread text;
--- the marker is purely a visual aid layered on top.
---
--- @param xpointer string The resume (last-read) xpointer.
--- @return string, string The navigation target and the marker xpointer.
function ProgressBridge.gotoxpointer_args(xpointer)
    return xpointer, xpointer
end


--- True iff `xpath` is a non-empty xpointer that RESOLVES in `document`.
---
--- The resume-jump path broadcasts GotoXPointer, which makes KOReader call
--- _gotoXPointer(xp) and set self.xpointer = xp WITHOUT validating it
--- (readerrolling.lua:onGotoXPointer).  A remote xpointer captured on another
--- device may not exist in the copy opened here -- a different edition/file, or
--- the same file paginated differently by another crengine version.  Feeding
--- such a dead anchor in leaves it as self.xpointer, and the next page turn
--- crashes getPageFromXPointer (it raises on input it cannot resolve).  The
--- jump path gates on this and falls back to page/percent when it is false.
---
--- The C++ call is pcall-wrapped (NOT type-checked) so a missing method or a
--- malformed, network-sourced xpointer degrades to "not resolvable" rather
--- than raising.
---
--- @param document table|nil The live (currently open) document object.
--- @param xpath string|nil The remote resume xpointer.
--- @return boolean
function ProgressBridge.xpointer_resolves(document, xpath)
    if type(xpath) ~= "string" or xpath == "" then return false end
    if not document then return false end
    local ok, in_doc = pcall(document.isXPointerInDocument, document, xpath)
    return (ok and in_doc) and true or false
end


return ProgressBridge
