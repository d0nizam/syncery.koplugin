-- =============================================================================
-- syncery_ann/render_settings_bridge.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- It reads and writes the per-book rendering preferences — font face,
-- font size, line spacing, font weight, page margins — between KOReader's
-- doc_settings and Syncery's `render_settings` section of the annotations
-- JSON.
--
-- This whole module is opt-in AND per-field.  By default NOTHING is
-- synced: the master toggle (`sync_render_settings`) is off, and even
-- when it is on, each individual field has its own sub-toggle that is
-- also off by default.  Render settings are device-specific by nature
-- (a font size or margin comfortable on a phone is wrong on a large
-- e-reader), so the user opts in to exactly the fields they want.
--
--
-- THE REAL KOReader KEYS
--
-- KOReader stores the reflowable render settings through the Configurable
-- mechanism under a "copt_" prefix (Configurable:saveSettings writes
-- `prefix..key`, prefix "copt_").  The font FACE is the exception: it is
-- owned by ReaderFont and stored as a top-level "font_face" key.  So the
-- actual doc_settings keys are:
--
--   * font_face              — ReaderFont, top-level "font_face" (string)
--   * font_size              — "copt_font_size"
--   * line_spacing           — "copt_line_spacing"
--   * font_weight            — "copt_font_base_weight"
--   * margins                — "copt_h_page_margins" + "copt_t_page_margin"
--                              + "copt_b_page_margin" (three keys, grouped
--                              under one toggle)
--
--
-- PER-FIELD MERGE (changed from whole-block)
--
-- Each synced render key is its own merge unit, carried in the JSON as
--   { "<key>": { value = ..., datetime_updated = "..." }, ... }
-- with NO top-level block timestamp.  merge() picks the newer entry per
-- key (newer datetime_updated wins; an exact-timestamp tie is broken on the
-- canonical VALUE fingerprint, a device-independent / commutative rule),
-- preserving a key present on only one side — identical in shape and
-- semantics to MetadataBridge.merge.  This lets render fields from different
-- devices ACCUMULATE: change font size on one device and margins on another,
-- and both survive (the old whole-block merge kept only the newest device's
-- block, dropping the other's changes).
--
-- The merge function is the SINGLE source of render-merge truth, called
-- by all three paths (the Syncthing orchestrator, the cloud adapter, and
-- the sidecar conflict resolver) — mirroring how MetadataBridge.merge is
-- shared, so the three paths cannot diverge.
--
--
-- BYTE-IDENTITY
--
-- The per-field shape is exactly what MetadataBridge already uses inside
-- the same canonical envelope, which is byte-identical across devices
-- (json_store sort_keys + no device stamp + a pure merge).  Two devices
-- that converge to the same logical render state serialize to identical
-- bytes because: (a) the merge is COMMUTATIVE (per-field newer-wins, and an
-- exact-timestamp tie is broken on the value fingerprint, not on argument
-- order) so merge(local,remote) and merge(remote,local) reach the SAME
-- entries on both devices; (b) the per-field change detection fingerprints
-- each value, so the SAME value never earns a spurious new timestamp on one
-- device.  (A bare ">=" / argument-order tie-break failed (a): each device
-- passes its own block first, so on a same-second concurrent edit each kept
-- its own value and the shared file never converged -- Syncthing churn.)
--
--
-- WHEN IT TAKES EFFECT
--
-- apply_from_remote writes the values into doc_settings; KOReader picks
-- them up on the NEXT open of the book (ReaderFont / the crengine
-- Configurable load their settings at load time).  We do NOT live
-- re-render — the merge structure never reaches KOReader; apply unwraps
-- each entry's `.value` and writes the plain value KOReader expects.
--
--
-- ROLLING DOCS ONLY
--
-- Render settings on paging documents (PDF, DJVU, CBZ) don't translate
-- meaningfully — a margin in crengine units is meaningless on a fixed
-- page.  We skip paging docs entirely.
--
-- =============================================================================

local TimeFormat = require("syncery_ann/time_format")
local logger     = require("logger")

local RenderSettingsBridge = {}


-- ----------------------------------------------------------------------------
-- The fields we sync.
--
-- Each entry maps a logical field (with its own user-facing sub-toggle)
-- to the actual doc_settings key(s) KOReader stores it under.  Margins
-- is one logical field that groups three crengine margin keys, so a
-- single "sync margins" choice carries the whole margin set.  The synced
-- JSON block is keyed by these REAL doc_settings keys.
-- ----------------------------------------------------------------------------

local FIELD_SPEC = {
    { toggle = "font_face",    keys = { "font_face" } },
    { toggle = "font_size",    keys = { "copt_font_size" } },
    { toggle = "line_spacing", keys = { "copt_line_spacing" } },
    { toggle = "font_weight",  keys = { "copt_font_base_weight" } },
    { toggle = "margins",      keys = { "copt_h_page_margins",
                                        "copt_t_page_margin",
                                        "copt_b_page_margin" } },
}


--- Where in doc_settings we cache per-field "what we last saw + when".
--- Shape: { fields = { [key] = { value = <fingerprint>, datetime_updated } } }.
local STATE_KEY = "syncery_render_state"


-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------


--- Build the per-field toggle map from the plugin's settings flags.
---
--- Every flag is opt-in (defaults to off), so we require an explicit
--- `== true`.  A nil plugin (test/defensive fallback) yields a fully-off
--- map, so nothing syncs unless a caller passes real toggles.
---
--- @param plugin table|nil The Syncery plugin instance.
--- @return table A toggles map { master, font_face, font_size, ... }.
function RenderSettingsBridge.make_toggles_from_plugin(plugin)
    if not plugin then
        return {
            master = false, font_face = false, font_size = false,
            line_spacing = false, font_weight = false, margins = false,
        }
    end
    return {
        master       = plugin.sync_render_settings == true,
        font_face    = plugin.sync_font_face       == true,
        font_size    = plugin.sync_font_size       == true,
        line_spacing = plugin.sync_line_spacing    == true,
        font_weight  = plugin.sync_font_weight     == true,
        margins      = plugin.sync_margins         == true,
    }
end


--- Read the current render settings from KOReader as a syncable block.
---
--- Returns a per-field-keyed table:
---   { copt_font_size = { value = 22, datetime_updated = "..." },
---     font_face       = { value = "Bitter", datetime_updated = "..." }, ... }
---
--- Each field's `datetime_updated` is freshly bumped if THAT field has
--- changed since this device last looked at it (fingerprint compare);
--- otherwise it carries forward the cached timestamp.  No top-level
--- timestamp — every field carries its own.
---
--- Returns nil for paging documents, when the master toggle is off, or
--- when no enabled field has a value on this device.
---
--- @param ui table KOReader's ReaderUI.
--- @param toggles table|nil Which fields to sync (from make_toggles_from_plugin).
--- @return table|nil The render-settings block, or nil if not applicable.
function RenderSettingsBridge.read_from_ui(ui, toggles)
    if not RenderSettingsBridge._is_supported_doc(ui) then
        return nil
    end
    toggles = toggles or RenderSettingsBridge.make_toggles_from_plugin(nil)
    if not toggles.master then
        return nil
    end

    local cached_state = ui.doc_settings:readSetting(STATE_KEY) or {}
    cached_state.fields = cached_state.fields or {}

    local block = {}
    local any_field = false
    local dirty = false

    for _, spec in ipairs(FIELD_SPEC) do
        if toggles[spec.toggle] then
            for _, key in ipairs(spec.keys) do
                local v = ui.doc_settings:readSetting(key)
                if v ~= nil then
                    any_field = true
                    local fp     = RenderSettingsBridge._fingerprint_value(v)
                    local cached = cached_state.fields[key]
                    local datetime
                    if not cached or cached.value ~= fp then
                        -- First seen, or this field changed: bump ITS timestamp.
                        datetime = TimeFormat.now()
                        cached_state.fields[key] = {
                            value            = fp,
                            datetime_updated = datetime,
                        }
                        dirty = true
                    else
                        datetime = cached.datetime_updated or ""
                    end
                    block[key] = { value = v, datetime_updated = datetime }
                end
            end
        end
    end

    if not any_field then
        return nil
    end
    if dirty then
        ui.doc_settings:saveSetting(STATE_KEY, cached_state)
    end
    return block
end


--- Merge two render blocks, per field, newer datetime_updated wins.
---
--- The SINGLE source of render-merge truth: the orchestrator, the cloud
--- adapter, and the sidecar conflict resolver all call this, so the
--- three paths cannot diverge.  Identical in shape/semantics to
--- MetadataBridge.merge: a field present on only one side is preserved;
--- on both sides the newer datetime_updated wins, ">=" tie-break.
---
--- @param block_a table|nil
--- @param block_b table|nil
--- @return table The merged per-field block.
function RenderSettingsBridge.merge(block_a, block_b)
    block_a = block_a or {}
    block_b = block_b or {}
    local merged = {}

    local all_keys = {}
    for k in pairs(block_a) do all_keys[k] = true end
    for k in pairs(block_b) do all_keys[k] = true end

    for key in pairs(all_keys) do
        local entry_a = block_a[key]
        local entry_b = block_b[key]
        if not entry_a then
            merged[key] = entry_b
        elseif not entry_b then
            merged[key] = entry_a
        else
            local ts_a = (type(entry_a) == "table" and entry_a.datetime_updated) or ""
            local ts_b = (type(entry_b) == "table" and entry_b.datetime_updated) or ""
            if ts_a > ts_b then
                merged[key] = entry_a
            elseif ts_b > ts_a then
                merged[key] = entry_b
            else
                -- Exact-timestamp tie: break it on a device-INDEPENDENT property
                -- so merge(a,b) == merge(b,a) and both devices converge on the
                -- same winner.  The old ">=" favoured argument A, but merge() is
                -- called as merge(local, remote) on each device, so each kept its
                -- OWN value -> the shared file never converged (Syncthing churn /
                -- conflict copies).  Render entries carry no device_id, so compare
                -- the canonical value fingerprint (commutative, total).  Mirrors
                -- MetadataBridge's device-id tiebreak and StatusLattice's origin
                -- selection -- one convergence rule across every merge unit.
                local fa = RenderSettingsBridge._fingerprint_value(
                    (type(entry_a) == "table" and entry_a.value) or entry_a) or ""
                local fb = RenderSettingsBridge._fingerprint_value(
                    (type(entry_b) == "table" and entry_b.value) or entry_b) or ""
                if fa <= fb then merged[key] = entry_a else merged[key] = entry_b end
            end
        end
    end

    return merged
end


--- Apply a remote render block to KOReader's doc_settings, per field.
---
--- A field is applied only if its remote entry is strictly newer than
--- what this device's cached state last saw for that key (the echo /
--- stale guard), and only if its sub-toggle is on.  Each entry's
--- `.value` is UNWRAPPED and the plain value is written to doc_settings
--- (KOReader never sees the per-field wrapper).  Each written value is also
--- mirrored into the live module state (see _update_live_state) so KOReader's
--- onSaveSettings does not clobber it before the next open; the change takes
--- effect on the next open of the book (no live re-render, by design).
---
--- After writing a render key to doc_settings, mirror the value into the
--- live in-memory state that KOReader's onSaveSettings will persist on
--- close/flush/suspend -- otherwise that save writes the unchanged live
--- state back over our doc_settings write before the next open, and the
--- synced setting silently vanishes.
---
--- Two owners:
---   * `font_face` is held by ReaderFont (ui.font.font_face) and written
---     back by ReaderFont:onSaveSettings.
---   * every `copt_<name>` key is held in the document's shared Configurable
---     (ui.document.configurable[<name>]) and written back by
---     ReaderConfig:onSaveSettings.
--- Guarded throughout: the live modules may be absent (e.g. the book is
--- not the open document, or in the headless suite).  We deliberately do
--- NOT re-render here -- the design applies render changes on next open,
--- not live; this only keeps the persisted value from being clobbered.
---
--- @param ui table The ReaderUI.
--- @param key string The doc_settings key just written ("font_face" or "copt_*").
--- @param value any The value just written.
function RenderSettingsBridge._update_live_state(ui, key, value)
    if type(ui) ~= "table" then return end

    if key == "font_face" then
        if type(ui.font) == "table" then
            ui.font.font_face = value
        end
        return
    end

    local cfg_key = key:match("^copt_(.+)$")
    if cfg_key and type(ui.document) == "table"
            and type(ui.document.configurable) == "table" then
        ui.document.configurable[cfg_key] = value
    end
end



--- @param ui table The ReaderUI.
--- @param remote_block table|nil The per-field render block from remote.
--- @param toggles table|nil Which fields to sync (from make_toggles_from_plugin).
--- @return boolean True if any value was actually written.
function RenderSettingsBridge.apply_from_remote(ui, remote_block, toggles)
    if not RenderSettingsBridge._is_supported_doc(ui) then
        return false
    end
    if type(remote_block) ~= "table" then
        return false
    end
    toggles = toggles or RenderSettingsBridge.make_toggles_from_plugin(nil)
    if not toggles.master then
        return false
    end

    local cached_state = ui.doc_settings:readSetting(STATE_KEY) or {}
    cached_state.fields = cached_state.fields or {}

    local any_change = false
    local dirty = false

    for _, spec in ipairs(FIELD_SPEC) do
        if toggles[spec.toggle] then
            for _, key in ipairs(spec.keys) do
                local remote_entry = remote_block[key]
                if RenderSettingsBridge._remote_entry_is_newer(
                        remote_entry, cached_state.fields[key]) then
                    local current = ui.doc_settings:readSetting(key)
                    if not RenderSettingsBridge._values_equal(current, remote_entry.value) then
                        ui.doc_settings:saveSetting(key, remote_entry.value)
                        -- doc_settings alone is not enough: while the book is
                        -- open, KOReader's ReaderConfig/ReaderFont onSaveSettings
                        -- write their LIVE state back to doc_settings on
                        -- close/flush/suspend, clobbering this write before the
                        -- next open.  Update that live state too so the save
                        -- stays consistent and the value survives to next open.
                        RenderSettingsBridge._update_live_state(ui, key, remote_entry.value)
                        any_change = true
                    end
                    -- Snapshot what we just adopted (even if the value
                    -- matched), so the cached timestamp advances and the
                    -- next read doesn't re-bump it.
                    cached_state.fields[key] = {
                        value            = RenderSettingsBridge._fingerprint_value(remote_entry.value),
                        datetime_updated = remote_entry.datetime_updated,
                    }
                    dirty = true
                end
            end
        end
    end

    if dirty then
        ui.doc_settings:saveSetting(STATE_KEY, cached_state)
    end
    if any_change then
        logger.info("Syncery render bridge: applied remote render settings (per-field)")
    end
    return any_change
end


-- ----------------------------------------------------------------------------
-- Internal helpers
-- ----------------------------------------------------------------------------


--- Render settings only make sense for rolling documents.
function RenderSettingsBridge._is_supported_doc(ui)
    if not ui or not ui.doc_settings then return false end
    if ui.paging then return false end
    return true
end


--- Whether a remote per-field entry should be applied over the cached one.
--- Strictly newer than what we last saw for that key; malformed entries
--- (not a table, no value, empty datetime) are never applied.  Mirror of
--- MetadataBridge._remote_entry_is_newer.
function RenderSettingsBridge._remote_entry_is_newer(remote_entry, cached_entry)
    if type(remote_entry) ~= "table" then return false end
    if remote_entry.value == nil then return false end

    local remote_ts = remote_entry.datetime_updated or ""
    if remote_ts == "" then return false end

    local cached_ts = (cached_entry and cached_entry.datetime_updated) or ""
    return remote_ts > cached_ts
end


--- Stable fingerprint of a value for change detection.  Scalars map to
--- their string form; a LIST maps to an ORDER-PRESERVING string and a MAP to
--- an order-independent one (so an equal value never looks "changed").  This
--- keeps the per-field timestamp stable across devices, which byte-identity
--- depends on.  Differs from MetadataBridge._fingerprint_value on lists: the
--- only list-valued render key is copt_h_page_margins = {left, right}, which
--- is POSITIONAL -- order is meaningful, so we must NOT sort (sorting would
--- collapse {10,20} and {20,10} to one fingerprint and hide an L/R swap).
--- MetadataBridge's only list field is collections, an unordered set, where
--- sorting is correct; the render bridge has no set field.
function RenderSettingsBridge._fingerprint_value(value)
    if value == nil then return nil end
    if type(value) ~= "table" then
        return tostring(value)
    end

    -- List (all numeric keys) vs map.
    local is_list = true
    for k in pairs(value) do
        if type(k) ~= "number" then is_list = false; break end
    end

    if is_list then
        -- Walk in index order via ipairs (deterministic AND order-preserving);
        -- do NOT sort -- margins are positional, an L/R swap is a real change.
        local list_view = {}
        for _, v in ipairs(value) do
            table.insert(list_view, tostring(v))
        end
        return "LIST\0" .. table.concat(list_view, "\0")
    end

    local pairs_view = {}
    for k, v in pairs(value) do
        table.insert(pairs_view,
            tostring(k) .. "=" .. RenderSettingsBridge._fingerprint_value(v))
    end
    table.sort(pairs_view)
    return "MAP\0" .. table.concat(pairs_view, "\0")
end


--- Deep-equal for scalars and one-level-deep tables (used by apply to
--- skip a no-op doc_settings write).
function RenderSettingsBridge._values_equal(a, b)
    if a == b then return true end
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return false end

    for k, v in pairs(a) do
        if b[k] ~= v then return false end
    end
    for k, v in pairs(b) do
        if a[k] ~= v then return false end
    end
    return true
end


return RenderSettingsBridge
