--[[--
Detects KOReader native `metadata.<ext>.lua` files that sit in a location
OTHER than the user's currently-chosen `document_metadata_folder` — i.e.
"scattered" across doc/dir/hash because a book passed through different
metadata locations over its lifetime (e.g. hashdocsettings earlier, then the
user switched to docsettings, leaving the old file behind).

----------------------
READ-ONLY, ADVISORY ONLY
----------------------
This module NEVER moves, copies, deletes, or writes anything. It only inspects
KOReader's own DocSettings to report WHERE each book's native metadata
physically sits.

It exists so the synceryhash -> SDR migration flow can tell the user, after
Syncery has finished migrating its OWN JSON files, that some KOReader native
metadata is scattered, and that KOReader's File Browser -> "Move book metadata"
can consolidate it if they wish. Syncery deliberately does NOT perform that
consolidation: moving KOReader's files is KOReader's concern, and the operation
is a File-Browser-bound UI command with no clean programmatic entry
point. We only DETECT and REPORT.

This is correct ONLY for the synceryhash -> SDR direction. In the SDR ->
synceryhash direction Syncery moves to content-addressed storage where the
scattering of KOReader's path-addressed metadata is irrelevant, so there is
nothing to advise; callers must not invoke this for that direction.
----------------------------------------]]

local ScatteredMetadata = {}

-- Human-readable labels for KOReader metadata locations. These mirror the
-- wording KOReader uses in its own "Book metadata location" menu.
local LOCATION_LABELS = {
    doc  = "book folder",
    dir  = "koreader/docsettings",
    hash = "koreader/hashdocsettings",
    hist = "legacy history",
}

--- Build the empty report shape. Centralised so early returns (no DocSettings,
--- bad input) hand back the same structure a full run would.
local function empty_report()
    return {
        preferred       = nil,  -- the chosen document_metadata_folder ("doc"/"dir"/"hash")
        preferred_label = nil,  -- its human-readable label
        scattered       = {},   -- array of { file, location, label } NOT in preferred
        by_location     = {},   -- map: actual location -> count of scattered books there
        total_scanned   = 0,    -- books for which a native metadata.lua was found
        total_scattered = 0,    -- #scattered
    }
end

--- Detect which of `books` have their native KOReader metadata.lua in a
--- location other than the currently-preferred one.
---
--- @param books table array of book records; each entry is inspected for a
---        `.file` string (absolute path to the book). Entries without a usable
---        file, or whose book has no native metadata.lua at all, are skipped.
--- @param deps table|nil optional injection (mirrors hash_location_finder):
---        deps.docsettings — a DocSettings-like module exposing
---                           `findSidecarFile(doc_path) -> (sidecar_file, location)`.
---                           Default: require("docsettings").
---        deps.preferred   — preferred location string ("doc"/"dir"/"hash").
---                           Default: G_reader_settings "document_metadata_folder"
---                           (falling back to "doc").
--- @return table report (see empty_report for the shape). On a missing or
---        too-old DocSettings API the report is empty (graceful degrade: the
---        caller simply shows no advisory).
function ScatteredMetadata.detect(books, deps)
    deps = deps or {}
    local report = empty_report()

    -- Resolve DocSettings, guarded exactly like hash_location_finder: injected
    -- for tests, else required; if the primitive we need is absent (older
    -- KOReader), degrade to an empty report rather than erroring.
    local DocSettings = deps.docsettings
    if not DocSettings then
        local ok_ds, mod = pcall(require, "docsettings")
        if not ok_ds then return report end
        DocSettings = mod
    end
    if type(DocSettings.findSidecarFile) ~= "function" then
        return report
    end

    -- Resolve the preferred location (the user's chosen KOReader setting).
    local preferred = deps.preferred
    if not preferred then
        if _G.G_reader_settings then
            preferred = _G.G_reader_settings:readSetting("document_metadata_folder", "doc")
        else
            preferred = "doc"
        end
    end
    report.preferred       = preferred
    report.preferred_label = LOCATION_LABELS[preferred] or preferred

    if type(books) ~= "table" then return report end

    for _, book in ipairs(books) do
        local file = type(book) == "table" and book.file or nil
        if type(file) == "string" and file ~= "" then
            -- findSidecarFile returns (sidecar_file, location); location is nil
            -- when the book has NO native metadata.lua anywhere. We only care
            -- about the location. Wrapped in pcall: a faithful KOReader build
            -- won't throw, but a foreign/edge build might, and a detection
            -- helper must never break the migration that called it.
            local ok_find, _sidecar, location = pcall(function()
                return DocSettings:findSidecarFile(file)
            end)
            if ok_find and type(location) == "string" and location ~= "" then
                report.total_scanned = report.total_scanned + 1
                if location ~= preferred then
                    report.total_scattered = report.total_scattered + 1
                    report.scattered[#report.scattered + 1] = {
                        file     = file,
                        location = location,
                        label    = LOCATION_LABELS[location] or location,
                    }
                    report.by_location[location] =
                        (report.by_location[location] or 0) + 1
                end
            end
        end
    end

    return report
end

--- Expose the labels so the UI layer (Step 3) can render consistent wording
--- without duplicating the map.
ScatteredMetadata.LOCATION_LABELS = LOCATION_LABELS

return ScatteredMetadata
