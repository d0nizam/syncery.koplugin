-- =============================================================================
-- syncery_ann/metadata_bridge.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- It reads and writes the book-level metadata that lives outside the
-- annotation list: reading status, rating, collections, the user's
-- summary note, custom (title/author/etc.) overrides, and a handmade
-- table of contents.
--
-- All of this gets packed into the `metadata` section of our
-- annotations JSON, where other devices can pick it up.
--
--
-- WHY FIELD-BY-FIELD MERGE
--
-- For annotations the merge unit is a single annotation (keyed by
-- position).  For render settings, the merge unit is the whole block.
-- Metadata sits in between: each field changes independently, and a
-- user often touches several fields in one session (e.g. mark a book
-- "finished", give it a 5-star rating, add it to "Read in 2024").
--
-- If we merged metadata as a whole block, finishing a book on one
-- device while another device was simultaneously rating it would
-- cause one of the two changes to be lost.  So we track a separate
-- timestamp PER FIELD.  Each field is "owned" by whichever device
-- touched it last.
--
--
-- THE SHAPE OF THE METADATA SECTION
--
-- Each field is stored as `{ value = X, datetime_updated = "YYYY-..." }`.
-- Example:
--
--   metadata = {
--     status       = { value = "reading", datetime_updated = "2024-11-17 18:01:00",
--                      device_id = "phone", device_label = "Phone" },
--     rating       = { value = 4,         datetime_updated = "..." },
--     collections  = { value = {"Fav", "Sci-fi"}, datetime_updated = "..." },
--     summary_note = { value = "great so far", datetime_updated = "..." },
--     custom       = { value = { title=..., authors=..., ... }, datetime_updated = "..." },
--     handmade_toc = { value = [...], datetime_updated = "..." },
--   }
--
-- Fields with no data are simply absent from the map.  Old metadata
-- files written by an earlier schema (with no per-field timestamps)
-- are tolerated — we treat their fields as having an empty timestamp,
-- which loses every merge against a properly-timestamped peer.
--
--
-- CHANGE DETECTION (who edited what)
--
-- KOReader doesn't notify us when the user changes their rating or adds a
-- book to a collection.  Rather than guess from timestamps, the merge decides
-- WHO changed each field by comparing this device's value and the remote
-- value against a common ANCESTOR (the last-synced metadata, persisted by the
-- orchestrator).  See metadata_bridge.three_way.  A field's
-- datetime_updated is only a tiebreaker for genuine concurrent edits of
-- rating/note/collections/custom;
-- for those a conflict falls to a deterministic device-id tiebreak (never to
-- collect order).  STATUS is the exception: it does NOT use datetime at all --
-- it has lifecycle structure (new < reading < {complete, abandoned}), so it is
-- merged by syncery_ann/status_lattice.lua (a clock-free lattice + generation
-- model).
--
--
-- THE TOGGLES OBJECT
--
-- The user controls each field independently via menu toggles
-- (`sync_status`, `sync_rating`, `sync_collections`,
-- `sync_custom_metadata`, `sync_handmade_toc`, plus a master
-- `sync_metadata` switch).  Callers pass a `toggles` table to filter
-- which fields are read and written.  See `make_toggles_from_plugin`
-- for converting a Syncery plugin instance into this shape.
--
-- =============================================================================

local logger = require("logger")
local StatusLattice = require("syncery_ann/status_lattice")

local MetadataBridge = {}


-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------


--- Build a toggles table from a Syncery plugin instance.
---
--- A convenience so callers don't have to spell out the six bool
--- mappings every time.  Pass `nil` to get a table with everything
--- enabled (useful for tests).
---
--- @param plugin table|nil The Syncery plugin instance.
--- @return table A toggles map.
function MetadataBridge.make_toggles_from_plugin(plugin)
    if not plugin then
        return {
            master      = true,
            status      = true,
            rating      = true,
            collections = true,
            custom      = true,
            handmade    = true,
            summary     = true,
        }
    end

    return {
        master      = plugin.sync_metadata        ~= false,
        status      = plugin.sync_status          ~= false,
        rating      = plugin.sync_rating          ~= false,
        collections = plugin.sync_collections     ~= false,
        custom      = plugin.sync_custom_metadata ~= false,
        handmade    = plugin.sync_handmade_toc    ~= false,
        summary     = plugin.sync_summary         ~= false,
    }
end


--- Read this device's metadata as a metadata-section table.
---
--- For every enabled field, looks at the current value in KOReader,
--- compares against the cached "last seen" snapshot, and if anything
--- changed, bumps the field's `datetime_updated` to "now".  The cached
--- snapshot is updated as a side effect so the next call sees no
--- change.
---
--- Fields with no value (rating not set, no collections, etc.) are
--- omitted entirely so they don't accidentally overwrite remote
--- metadata that DOES have a value.
---
--- @param ui table The ReaderUI.
--- @param book_file string Path to the book (needed for collections lookup).
--- @param toggles table Which fields to include (from make_toggles_from_plugin).
--- @param device_id string|nil Stamp on bumped fields.
--- @param device_label string|nil Stamp on bumped fields.
--- @return table The metadata section.
function MetadataBridge.read_from_ui(ui, book_file, toggles, device_id, device_label, ancestor_md)
    if not ui or not ui.doc_settings then return {} end
    toggles = toggles or MetadataBridge.make_toggles_from_plugin(nil)
    if not toggles.master then return {} end

    local metadata = {}

    -- datetime_updated is consulted ONLY to break a genuine concurrent conflict
    -- in the 3-way merge (metadata_bridge.three_way), and only for
    -- rating/note/collections/custom -- each carries "" so such a conflict falls
    -- straight to the device-id tiebreak, not to collect order (the very thing
    -- that made the old 2-way merge order by collect order).
    --
    -- STATUS is different: it is merged by the lifecycle lattice
    -- (status_lattice.lua), not by datetime.  Its local contribution is a
    -- { generation, candidates } entry whose generation is classified against
    -- the last-synced ancestor's status (a forward move carries the generation;
    -- a reopen/sideways move bumps it -> dominates).  ancestor_md is the
    -- last-synced metadata section (nil on the first sync -> generation 0).

    if toggles.status then
        local se = StatusLattice.local_entry(
            ancestor_md and ancestor_md.status,
            MetadataBridge._read_status(ui),
            device_id, device_label)
        if se then metadata.status = se end
    end

    if toggles.rating then
        MetadataBridge._bridge_field_read(
            metadata, "rating",
            MetadataBridge._read_rating(ui),
            "", device_id, device_label)
    end

    if toggles.summary then
        MetadataBridge._bridge_field_read(
            metadata, "summary_note",
            MetadataBridge._read_summary_note(ui),
            "", device_id, device_label)
    end

    if toggles.collections then
        MetadataBridge._bridge_field_read(
            metadata, "collections",
            MetadataBridge._read_collections(book_file),
            "", device_id, device_label)
    end

    if toggles.custom then
        MetadataBridge._bridge_field_read(
            metadata, "custom",
            MetadataBridge._read_custom(ui),
            "", device_id, device_label)
    end

    -- handmade_toc is intentionally NOT read here: it is receive-only on
    -- the sync channel.  Sending a handmade TOC is always an explicit
    -- manual action ("Push this book's handmade TOC"), never auto-synced,
    -- because it is a large hand-built artifact that an LWW auto-overwrite
    -- could silently destroy.  Incoming TOCs are applied via
    -- _apply_handmade_toc (gated by sync_handmade_toc / toggles.handmade).

    return metadata
end


--- Apply a remote metadata section to KOReader's local state.
---
--- Per field: if the remote `datetime_updated` is strictly newer than
--- our cached "last applied" timestamp AND the remote value differs
--- from what we have locally, write the remote value.  Then update
--- the cached snapshot so the next read won't mistake the adoption
--- for a local edit.
---
--- @param ui table The ReaderUI.
--- @param book_file string Path to the book.
--- @param remote_metadata table The metadata section from the shared JSON.
--- @param toggles table Which fields are enabled.
--- @return boolean True if any field was changed locally.
--- @return table Map of which fields were applied (for logging).
function MetadataBridge.apply_from_remote(ui, book_file, merged_metadata, toggles)
    if not ui or not ui.doc_settings then return false, {} end
    if type(merged_metadata) ~= "table" then return false, {} end
    toggles = toggles or MetadataBridge.make_toggles_from_plugin(nil)
    if not toggles.master then return false, {} end

    local any_change = false
    local applied = {}

    -- The 3-way merge has already decided each field's final value; apply just
    -- makes KOReader match it.  We adopt a field only when the merged value
    -- actually differs from THIS device's current value (read via the same
    -- _read_* helpers the collect uses), so a field this device itself won is
    -- a no-op and never re-reports a spurious change.  This is also why apply
    -- does not consult a timestamp -- whose value wins is the merge's job,
    -- not apply's.  handmade_toc is receive-only (never collected, so there is
    -- no "current" to compare); its apply self-checks and no-ops when the live
    -- TOC already matches.
    -- Status is merged by the lattice: a resolved value is applied; a still-
    -- unresolved conflict (complete vs abandoned) is NOT applied -- it is left
    -- for the user to resolve, and each device keeps its own value meanwhile.
    -- (_apply_status itself no-ops when the live value already matches.)  The
    -- other fields go through the generic value-gated loop below.
    if toggles.status then
        local resolved = StatusLattice.resolved_value(merged_metadata.status)
        if resolved ~= nil
           and MetadataBridge._apply_status(ui, book_file, resolved) then
            any_change = true
            applied.status = true
        end
    end

    local handlers = {
        rating = {
            enabled = toggles.rating,
            read    = function(u, _bf) return MetadataBridge._read_rating(u) end,
            apply   = MetadataBridge._apply_rating,
        },
        summary_note = {
            enabled = toggles.summary,
            read    = function(u, _bf) return MetadataBridge._read_summary_note(u) end,
            apply   = MetadataBridge._apply_summary_note,
        },
        collections = {
            enabled = toggles.collections,
            read    = function(_u, bf) return MetadataBridge._read_collections(bf) end,
            apply   = MetadataBridge._apply_collections,
        },
        custom = {
            enabled = toggles.custom,
            read    = function(u, _bf) return MetadataBridge._read_custom(u) end,
            apply   = MetadataBridge._apply_custom,
        },
        handmade_toc = {
            enabled = toggles.handmade and not ui.paging,
            read    = nil,   -- receive-only: no collected current to compare
            apply   = MetadataBridge._apply_handmade_toc,
        },
    }

    for field_name, handler in pairs(handlers) do
        if handler.enabled then
            local entry = merged_metadata[field_name]
            if type(entry) == "table" and entry.value ~= nil then
                local do_apply
                if handler.read then
                    local current = handler.read(ui, book_file)
                    do_apply = MetadataBridge._fingerprint_value(current)
                               ~= MetadataBridge._fingerprint_value(entry.value)
                else
                    do_apply = true
                end

                if do_apply then
                    local changed = handler.apply(ui, book_file, entry.value)
                    if changed then
                        any_change = true
                        applied[field_name] = true
                    end
                end
            end
        end
    end

    if next(applied) then
        local applied_names = {}
        for k in pairs(applied) do table.insert(applied_names, k) end
        logger.info("Syncery metadata bridge: applied remote fields: "
            .. table.concat(applied_names, ", "))
    end
    return any_change, applied
end


--- Merge two metadata-section tables for a CONFLICT reconcile (no ancestor).
---
--- Used by the conflict resolver to combine the main file with a Syncthing
--- conflict file: two already-pushed copies with no meaningful common
--- ancestor (see this module's conflict_resolver.lua sibling header).  A field
--- present on only one side is kept; when both sides carry a field it is a
--- conflict, resolved by the SAME principled tiebreak the 3-way merge uses
--- (newer datetime_updated -> deliberate end-state status precedence ->
--- device-id), so a same-day status conflict can't pick "reading" over
--- "complete" by argument order.  (Sync time -- local-vs-remote and the cloud
--- transport -- uses three_way against the ancestor, not this.)
---
--- @param a table|nil First metadata section.
--- @param b table|nil Second metadata section.
--- @return table Merged metadata section.
function MetadataBridge.merge(a, b)
    a = a or {}
    b = b or {}
    local merged = {}

    local all_field_names = {}
    for k in pairs(a) do all_field_names[k] = true end
    for k in pairs(b) do all_field_names[k] = true end

    for field_name in pairs(all_field_names) do
        local entry_a = a[field_name]
        local entry_b = b[field_name]

        if field_name == "status" then
            -- Status is merged by the lattice (status_lattice.lua) -- the same
            -- clock-free 2-way merge three_way uses; it handles a side being
            -- absent itself.
            local sm = StatusLattice.merge(entry_a, entry_b)
            if sm ~= nil then merged.status = sm end
        elseif not entry_a then
            merged[field_name] = entry_b
        elseif not entry_b then
            merged[field_name] = entry_a
        else
            -- Both sides carry this field and there is no ancestor to say who
            -- changed it, so every both-present field is a conflict: resolve
            -- with the same tiebreak three_way uses (newer date -> device-id)
            -- instead of a bare argument-order tie.
            merged[field_name] = MetadataBridge._metadata_tiebreak(
                field_name, entry_a, entry_b)
        end
    end

    return merged
end


--- Fingerprint of a metadata entry's value, or nil if the entry is absent or
--- valueless.  Used so 3-way comparisons are by VALUE -- set/table-valued
--- fields (collections, custom) compare order-independently via
--- _fingerprint_value, not by table identity.
function MetadataBridge._entry_fingerprint(entry)
    if type(entry) ~= "table" or entry.value == nil then return nil end
    return MetadataBridge._fingerprint_value(entry.value)
end


--- Resolve a genuine concurrent conflict on a NON-STATUS field: both sides
--- moved the field off the ancestor, to different values.  Deterministic and
--- SYMMETRIC so every device converges on the same winner regardless of which
--- side is "local" -- no flip-flop:
---   1. newer change time wins (datetime_updated);
---   2. still tied -> higher device_id.
--- Status does NOT use this path: it has lifecycle structure and is merged by
--- status_lattice.lua (a clock-free lattice + generation model).
--- `field_name` is kept for the field-contextual signature shared with
--- the 3-way caller.
--- @return table The winning entry.
function MetadataBridge._metadata_tiebreak(field_name, entry_l, entry_r)
    local dl = (type(entry_l) == "table" and entry_l.datetime_updated) or ""
    local dr = (type(entry_r) == "table" and entry_r.datetime_updated) or ""
    if dl ~= dr then
        return (dl > dr) and entry_l or entry_r
    end

    local il = (type(entry_l) == "table" and entry_l.device_id) or ""
    local ir = (type(entry_r) == "table" and entry_r.device_id) or ""
    if il ~= ir then
        return (il > ir) and entry_l or entry_r
    end
    return entry_l
end


--- 3-way resolve a single field against the ancestor.  entry_* are metadata
--- entries ({value, datetime_updated, device_id, ...}) or nil (absent on that
--- side).  Comparison is by value fingerprint.  Returns the winning entry, or
--- nil if the field should be omitted.
---
--- Absent semantics: an absent local field
--- is "no opinion", NOT a deletion -- it adopts the remote value rather than
--- wiping it.  A clear is therefore not propagated in v1.
function MetadataBridge._three_way_field(field_name, entry_l, entry_r, entry_a)
    local fl = MetadataBridge._entry_fingerprint(entry_l)
    local fr = MetadataBridge._entry_fingerprint(entry_r)
    local fa = MetadataBridge._entry_fingerprint(entry_a)

    if fl == nil and fr == nil then return nil end  -- absent on both -> omit
    if fl == nil then return entry_r end            -- local no-opinion -> remote
    if fr == nil then return entry_l end            -- remote absent     -> local
    if fl == fr then return entry_l end             -- agree
    if fl == fa then return entry_r end             -- only remote changed
    if fr == fa then return entry_l end             -- only local changed
    return MetadataBridge._metadata_tiebreak(field_name, entry_l, entry_r)  -- conflict
end


--- 3-way merge of two metadata sections against a common ancestor.
---
--- For each field, compares local and remote against the ancestor to decide
--- WHO changed, rather than guessing by timestamp as the old 2-way merge did:
--- if only one side moved off the ancestor, that side wins with no timestamp
--- consulted -- so collect order, clock skew and time zone are irrelevant to
--- non-conflicting changes.  Timestamps/precedence break only genuine
--- concurrent conflicts.
---
--- @param local_md    table|nil This device's metadata section.
--- @param remote_md   table|nil The shared (remote) metadata section.
--- @param ancestor_md table|nil The last-synced ancestor metadata section.
--- @return table The merged metadata section.
function MetadataBridge.three_way(local_md, remote_md, ancestor_md)
    local_md    = local_md    or {}
    remote_md   = remote_md   or {}
    ancestor_md = ancestor_md or {}

    local field_names = {}
    for k in pairs(local_md)    do field_names[k] = true end
    for k in pairs(remote_md)   do field_names[k] = true end
    for k in pairs(ancestor_md) do field_names[k] = true end

    local merged = {}
    for field_name in pairs(field_names) do
        local resolved
        if field_name == "status" then
            -- Status has lifecycle structure, so it is merged by the lattice
            -- (status_lattice.lua) -- a clock-free 2-way merge.  The ancestor is
            -- NOT consulted here: the generation already encodes "who moved
            -- last", classified at collect time (read_from_ui).
            resolved = StatusLattice.merge(local_md.status, remote_md.status)
        else
            resolved = MetadataBridge._three_way_field(
                field_name,
                local_md[field_name], remote_md[field_name], ancestor_md[field_name])
        end
        if resolved ~= nil then
            merged[field_name] = resolved
        end
    end
    return merged
end

-- ----------------------------------------------------------------------------
-- Internal: the read/write side for each individual field
-- ----------------------------------------------------------------------------


--- Common code for "read a single field, bump timestamp if changed".
---
--- Pulled out into one helper so each field-specific function only
--- has to know "what's the current value here?" — not the bookkeeping.
---
--- Mutates `cached_state.fields[field_name]` on a detected local edit.
function MetadataBridge._bridge_field_read(metadata, field_name, current_value,
                                          datetime_updated, device_id, device_label)
    if current_value == nil then
        -- Don't emit an entry; the absence will not overwrite remote.
        return
    end

    metadata[field_name] = {
        value            = current_value,
        datetime_updated = datetime_updated or "",
        device_id        = device_id,
        device_label     = device_label,
    }
end


--- Make a string fingerprint of a value, suitable for change detection.
---
--- Numbers and strings are converted directly.  Tables get a flat
--- sorted-key representation so order changes in collections (which
--- KOReader returns from a hash table) don't show as edits.
function MetadataBridge._fingerprint_value(value)
    if value == nil then return nil end
    if type(value) ~= "table" then
        return tostring(value)
    end

    -- For lists (collections is one), sort then concatenate.
    local list_view = {}
    local is_list = true
    for k, v in pairs(value) do
        if type(k) == "number" then
            table.insert(list_view, tostring(v))
        else
            is_list = false
            break
        end
    end

    if is_list then
        table.sort(list_view)
        return "LIST\0" .. table.concat(list_view, "\0")
    end

    -- For maps, sort keys and emit "key=value" pairs.
    local pairs_view = {}
    for k, v in pairs(value) do
        table.insert(pairs_view,
            tostring(k) .. "=" .. MetadataBridge._fingerprint_value(v))
    end
    table.sort(pairs_view)
    return "MAP\0" .. table.concat(pairs_view, "\0")
end


-- ── Field: status ───────────────────────────────────────────────────────────


function MetadataBridge._read_status(ui)
    local summary = ui.doc_settings:readSetting("summary") or {}
    local status = summary.status
    if status == nil or status == "" then return nil end
    return status
end


--- Mirror KOReader's own per-mutation cache update (readerstatus.markBook
--- calls BookList.setBookInfoCacheProperty) so the FileManager/History badge
--- reflects a synced status/rating change immediately, instead of staying
--- stale until the book is reopened and its BookList cache is rebuilt from the
--- sidecar.  Best-effort and guarded: BookList is a UI module absent from the
--- headless suite (require fails -> no-op), and this cache is a display
--- convenience, never the source of truth (the sidecar is).  Only status and
--- rating live in this cache; collections use ReadCollection (refreshed by
--- _apply_collections directly) and are not cached here.
function MetadataBridge._update_booklist_cache(book_file, prop_name, prop_value)
    if not book_file or book_file == "" then return end
    local ok, BookList = pcall(require, "ui/widget/booklist")
    if not ok or type(BookList) ~= "table" then return end
    if type(BookList.setBookInfoCacheProperty) ~= "function" then return end
    pcall(BookList.setBookInfoCacheProperty, book_file, prop_name, prop_value)
end


function MetadataBridge._apply_status(ui, book_file, remote_value)
    if remote_value == nil or remote_value == "" then return false end
    local summary = ui.doc_settings:readSetting("summary") or {}
    if summary.status == remote_value then return false end
    summary.status = remote_value
    ui.doc_settings:saveSetting("summary", summary)
    MetadataBridge._update_booklist_cache(book_file, "status", remote_value)
    return true
end


-- ── Field: rating ───────────────────────────────────────────────────────────


function MetadataBridge._read_rating(ui)
    local summary = ui.doc_settings:readSetting("summary") or {}
    if summary.rating == nil then return nil end
    return tonumber(summary.rating)
end


function MetadataBridge._apply_rating(ui, book_file, remote_value)
    if remote_value == nil then return false end
    local summary = ui.doc_settings:readSetting("summary") or {}
    if summary.rating == remote_value then return false end
    summary.rating = remote_value
    ui.doc_settings:saveSetting("summary", summary)
    MetadataBridge._update_booklist_cache(book_file, "rating", remote_value)
    return true
end


-- ── Field: summary note ─────────────────────────────────────────────────────


function MetadataBridge._read_summary_note(ui)
    local summary = ui.doc_settings:readSetting("summary") or {}
    local note = summary.note
    if note == nil or note == "" then return nil end
    return note
end


function MetadataBridge._apply_summary_note(ui, _book_file, remote_value)
    local summary = ui.doc_settings:readSetting("summary") or {}
    if summary.note == remote_value then return false end
    summary.note = remote_value
    ui.doc_settings:saveSetting("summary", summary)
    return true
end


-- ── Field: collections ──────────────────────────────────────────────────────


function MetadataBridge._read_collections(book_file)
    if not book_file or book_file == "" then return nil end

    local ok, ReadCollection = pcall(require, "readcollection")
    if not ok or not ReadCollection then return nil end
    if not ReadCollection.getCollectionsWithFile then return nil end

    local ok2, colls = pcall(
        ReadCollection.getCollectionsWithFile, ReadCollection, book_file)
    if not ok2 or type(colls) ~= "table" then return nil end

    local names = {}
    for name in pairs(colls) do
        table.insert(names, name)
    end
    if #names == 0 then return nil end
    table.sort(names) -- determinism for the fingerprint
    return names
end


function MetadataBridge._apply_collections(_ui, book_file, remote_value)
    if type(remote_value) ~= "table" then return false end
    if not book_file or book_file == "" then return false end

    local ok, ReadCollection = pcall(require, "readcollection")
    if not ok or not ReadCollection then return false end
    if not ReadCollection.addRemoveItemMultiple then return false end

    local desired = {}
    for _, name in ipairs(remote_value) do
        if type(name) == "string" and name ~= "" then
            desired[name] = true
        end
    end

    local ok_apply = pcall(
        ReadCollection.addRemoveItemMultiple, ReadCollection, book_file, desired)
    if not ok_apply then return false end

    -- addRemoveItemMultiple only mutates ReadCollection's in-memory model.
    -- KOReader persists a collection edit via the collection-UI's close handler
    -- (FileManagerCollection), which we don't go through, and ReadCollection has
    -- no flush-on-exit -- so without this the synced membership is lost on the
    -- next restart.  write() (no arg) rewrites all collections from the in-memory
    -- model, the same persistence KOReader itself uses.
    if type(ReadCollection.write) == "function" then
        pcall(ReadCollection.write, ReadCollection)
    end

    -- pcall-success is NOT proof the membership changed: addRemoveItemMultiple
    -- returns nothing and silently no-ops when, e.g., the book_file no longer
    -- resolves to a collection entry.  Verify against the model.
    -- getCollectionsWithFile resolves the file the SAME (realpath) way, so the
    -- post-apply membership is authoritative.  If the read API is unavailable,
    -- fall back to pcall-success (can't do better; no regression on old cores).
    if type(ReadCollection.getCollectionsWithFile) ~= "function" then
        return ok_apply
    end
    local ok_read, colls = pcall(
        ReadCollection.getCollectionsWithFile, ReadCollection, book_file)
    if not ok_read or type(colls) ~= "table" then
        return ok_apply
    end
    -- Report success only when membership now matches `desired` exactly.  A
    -- desired collection that doesn't exist locally can't be joined, so this
    -- reports not-fully-applied and the next sync re-attempts (idempotent).
    for name in pairs(desired) do
        if not colls[name] then return false end
    end
    for name in pairs(colls) do
        if not desired[name] then return false end
    end
    return true
end


-- ── Field: custom_metadata ──────────────────────────────────────────────────


--- Load KOReader's user-edited book properties (`custom_props`).
---
--- KOReader stores user edits to title/authors/series/language NOT in the
--- main doc_settings (there is no "custom_metadata" key), but in a SEPARATE
--- sidecar file `custom_metadata.lua` under the key `custom_props`.  This
--- mirrors KOReader's own read path (FileManagerBookInfo): resolve the file
--- via the live DocSettings instance, open it, read `custom_props`.
---
--- Returns nil when the book has no custom metadata file (the common case)
--- or when anything is unavailable.  Isolated as a seam so tests can stub
--- the DocSettings file access without touching disk.
---
--- @param ui table The ReaderUI instance (ui.doc_settings is a DocSettings).
--- @return table|nil The custom_props table, or nil.
function MetadataBridge._load_custom_props(ui)
    if not ui or not ui.doc_settings then return nil end
    if type(ui.doc_settings.getCustomMetadataFile) ~= "function" then return nil end

    local ok_path, path = pcall(ui.doc_settings.getCustomMetadataFile, ui.doc_settings)
    if not ok_path or not path then return nil end  -- false = no custom file

    local ok_mod, DocSettings = pcall(require, "docsettings")
    if not ok_mod or type(DocSettings) ~= "table"
            or type(DocSettings.openSettingsFile) ~= "function" then
        return nil
    end

    local ok_open, custom = pcall(DocSettings.openSettingsFile, path)
    if not ok_open or type(custom) ~= "table"
            or type(custom.readSetting) ~= "function" then
        return nil
    end

    local ok_read, props = pcall(custom.readSetting, custom, "custom_props")
    if not ok_read or type(props) ~= "table" then return nil end
    return props
end


function MetadataBridge._read_custom(ui)
    -- User edits live in KOReader's separate custom_metadata.lua file under
    -- `custom_props` — NOT in a doc_settings "custom_metadata" key (which
    -- KOReader never writes).
    local cm = MetadataBridge._load_custom_props(ui)
    if type(cm) ~= "table" then return nil end
    -- Only emit if at least one user-editable field is set.
    if not (cm.title or cm.authors or cm.series or cm.language
            or cm.keywords or cm.description) then
        return nil
    end
    return {
        title        = cm.title,
        authors      = cm.authors,
        series       = cm.series,
        series_index = cm.series_index,
        language     = cm.language,
        keywords     = cm.keywords,
        description  = cm.description,
    }
end


--- Persist user-edited book properties (`custom_props`) to KOReader's
--- separate `custom_metadata.lua` sidecar — the real location KOReader reads.
---
--- Mirrors the low-level part of FileManagerBookInfo:setCustomMetadata: open
--- (or create) the custom sidecar via DocSettings, merge the given fields into
--- `custom_props`, and flush via `flushCustomMetadata` (which computes the
--- sidecar path from the document and writes).  When creating a NEW file we
--- also back up the original `doc_props` (as KOReader does) so the user can
--- later reset a customized field to its original value.  We deliberately do
--- NOT regenerate `display_title` (a FileManager-list cosmetic that KOReader
--- regenerates on next open via extendProps) and we do not touch the UI.
---
--- Isolated as a seam so tests can stub the DocSettings file access.
---
--- @param ui table The ReaderUI instance (ui.doc_settings is a DocSettings).
--- @param fields table Map of custom fields to set (title/authors/...).
--- @return boolean True if anything was written.
function MetadataBridge._write_custom_props(ui, fields)
    if not ui or not ui.doc_settings then return false end
    if type(ui.doc_settings.getCustomMetadataFile) ~= "function" then return false end

    local ok_mod, DocSettings = pcall(require, "docsettings")
    if not ok_mod or type(DocSettings) ~= "table"
            or type(DocSettings.openSettingsFile) ~= "function" then
        return false
    end

    local ok_path, path = pcall(ui.doc_settings.getCustomMetadataFile, ui.doc_settings)
    if not ok_path then return false end

    local custom, is_new
    if path then
        local ok_open, c = pcall(DocSettings.openSettingsFile, path)
        if not ok_open or type(c) ~= "table" then return false end
        custom = c
    else
        -- No custom file yet: create a fresh one (book without custom metadata).
        local ok_open, c = pcall(DocSettings.openSettingsFile)
        if not ok_open or type(c) ~= "table" then return false end
        custom = c
        is_new = true
    end

    if type(custom.readSetting) ~= "function"
            or type(custom.saveSetting) ~= "function"
            or type(custom.flushCustomMetadata) ~= "function" then
        return false
    end

    -- When creating a new custom file, back up the original doc_props (as
    -- KOReader's setCustomMetadata does) so a later reset can restore them.
    if is_new and type(ui.doc_settings.readSetting) == "function" then
        local ok_dp, doc_props = pcall(ui.doc_settings.readSetting, ui.doc_settings, "doc_props")
        if ok_dp and type(doc_props) == "table" then
            pcall(custom.saveSetting, custom, "doc_props", doc_props)
        end
    end

    local custom_props = custom:readSetting("custom_props") or {}
    local changed = false
    for k, v in pairs(fields) do
        if v ~= nil and v ~= "" and custom_props[k] ~= v then
            custom_props[k] = v
            changed = true
        end
    end
    if not changed then return false end

    custom:saveSetting("custom_props", custom_props)

    -- flushCustomMetadata computes the sidecar path from the document path.
    local doc_path = ui.doc_settings.data and ui.doc_settings.data.doc_path
    local ok_flush = pcall(custom.flushCustomMetadata, custom, doc_path)

    -- If we just CREATED custom_metadata.lua, the open book's doc_settings still
    -- has a stale "no custom file" path cache (getCustomMetadataFile() returned
    -- and cached false before the create), so _load_custom_props -- and
    -- KOReader's own instance reads -- would miss the new file until reopen, and
    -- the apply value-gate (_read_custom -> nil) would re-apply every sync.
    -- Reset that cache, mirroring KOReader's setCustomMetadata.
    if is_new and type(ui.doc_settings.getCustomMetadataFile) == "function" then
        pcall(ui.doc_settings.getCustomMetadataFile, ui.doc_settings, true)
    end

    return ok_flush == true or ok_flush == nil
end


--- After a custom-metadata change, mirror KOReader so it shows without a
--- reopen: update the OPEN document's in-memory doc_props (the reader reads
--- title/author from there) and evict the coverbrowser's BookInfoManager cache
--- (broadcast InvalidateMetadataCache) so the FileManager re-reads
--- custom_metadata.lua when next shown -- extendProps reads that file fresh on
--- re-extract, so eviction alone is sufficient there.  Guarded: doc_props /
--- UIManager may be absent (headless suite).  We deliberately do NOT broadcast
--- the per-field BookMetadataChanged: it only drives the live footer/statistics
--- (the reader, not the FileManager, is on screen during a sync), the
--- FileManager is covered by the eviction, and a per-field broadcast adds
--- complexity for a marginal mid-session gain.
function MetadataBridge._refresh_custom_display(ui, book_file, fields)
    if type(ui) == "table" and type(ui.doc_props) == "table"
            and type(fields) == "table" then
        for k, v in pairs(fields) do
            if v ~= nil and v ~= "" then ui.doc_props[k] = v end
        end
        if fields.title ~= nil and fields.title ~= "" then
            ui.doc_props.display_title = fields.title
        end
    end

    if book_file and book_file ~= "" then
        local ok_event, Event     = pcall(require, "ui/event")
        local ok_uim,   UIManager = pcall(require, "ui/uimanager")
        if ok_event and ok_uim and Event and UIManager then
            pcall(function()
                UIManager:broadcastEvent(
                    Event:new("InvalidateMetadataCache", book_file))
            end)
        end
    end
end


function MetadataBridge._apply_custom(ui, book_file, remote_value)
    if type(remote_value) ~= "table" then return false end
    -- Only sync the user-editable fields; write them to KOReader's real
    -- custom_props location (NOT a doc_settings "custom_metadata" key).
    -- These are exactly KOReader's BookInfo.props custom-editable text fields.
    local fields = {
        title        = remote_value.title,
        authors      = remote_value.authors,
        series       = remote_value.series,
        series_index = remote_value.series_index,
        language     = remote_value.language,
        keywords     = remote_value.keywords,
        description  = remote_value.description,
    }
    local changed = MetadataBridge._write_custom_props(ui, fields)
    if changed then
        MetadataBridge._refresh_custom_display(ui, book_file, fields)
    end
    return changed
end


-- ── Field: handmade_toc ─────────────────────────────────────────────────────


-- Note: there is no _read_handmade_toc reader on the sync-read path.
-- Outgoing TOCs are read live (ui.handmade.toc) only by the explicit
-- manual push (Syncery:pushHandmadeToc); the sync channel itself is
-- receive-only for this field.  See the comment in read_from_ui.


-- Content fingerprint for a handmade-TOC list, used by the apply echo
-- guard.  MetadataBridge._fingerprint_value can't be used here: it
-- stringifies list elements with tostring(), which for a list of TABLES
-- (TOC entries are {title, xpointer/page, depth}) yields table addresses,
-- so two structurally-identical TOCs would never compare equal.  This
-- walks the entry fields and is order-sensitive (TOC order is meaningful,
-- unlike collections).
local function toc_fingerprint(toc)
    if type(toc) ~= "table" then return nil end
    local parts = {}
    for i = 1, #toc do
        local e = toc[i]
        if type(e) == "table" then
            parts[i] = table.concat({
                tostring(e.title    or ""),
                tostring(e.xpointer or ""),
                tostring(e.page     or ""),
                tostring(e.depth    or ""),
            }, "\31")
        else
            parts[i] = tostring(e)
        end
    end
    return table.concat(parts, "\30")
end


function MetadataBridge._apply_handmade_toc(ui, _book_file, remote_value)
    -- Remote must be a non-empty list of TOC entries.  KOReader stores a
    -- handmade TOC as the LIST itself under the "handmade_toc" doc-setting
    -- (NOT wrapped in a .toc field, and NOT under a bare "handmade" key);
    -- each entry carries an .xpointer on reflowable documents.
    if type(remote_value) ~= "table" or #remote_value == 0 then return false end

    -- Echo / already-synced guard: if the live document already has this
    -- exact TOC (our own manual push coming back on the next pull, or a
    -- value adopted earlier), do nothing — no write, no rebuild, and the
    -- local enable state is preserved.
    local handmade = ui.handmade
    if handmade and type(handmade.toc) == "table" then
        if toc_fingerprint(handmade.toc) == toc_fingerprint(remote_value) then
            return false
        end
    end

    -- Persist to the keys KOReader actually reads on the next open:
    -- the TOC list + the enable flag that gates rendering.
    ui.doc_settings:saveSetting("handmade_toc", remote_value)
    ui.doc_settings:saveSetting("handmade_toc_enabled", true)

    -- Update the live module so the change is visible this session and the
    -- next onSaveSettings persists handmade_toc from a fresh in-memory
    -- self.toc (not a stale empty one).  setupToc() re-plugs
    -- document.getToc to return the new list and fires UpdateToc, which
    -- ReaderToc:onUpdateToc handles to rebuild the displayed TOC.
    if handmade then
        handmade.toc = remote_value
        handmade.toc_enabled = true
        if type(handmade.setupToc) == "function" then
            pcall(function() handmade:setupToc() end)
            return true
        end
    end

    -- Fallback (no live module / no setupToc): broadcast the rebuild event
    -- so an already-open TOC view refreshes from the persisted setting.
    local ok_event, Event = pcall(require, "ui/event")
    local ok_uim,   UIManager = pcall(require, "ui/uimanager")
    if ok_event and ok_uim and Event and UIManager then
        pcall(function()
            UIManager:broadcastEvent(Event:new("UpdateToc"))
        end)
    end
    return true
end


return MetadataBridge
