-- =============================================================================
-- syncery_ann/identity.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- It computes a stable identity key for an annotation, based purely on the
-- annotation's POSITION inside the book.  Two annotations at the same
-- position are treated as the same annotation, regardless of what text
-- they highlight or what color they use.  Two annotations at different
-- positions are always different annotations, even if their text is
-- identical.
--
--
-- WHY POSITION-BASED IDENTITY
--
-- The original Syncery used a "fingerprint" computed from the first 50
-- characters of the highlighted text.  This was a problem: if you made
-- three highlights in the same paragraph, the first 50 characters were
-- often identical, so all three got the same fingerprint.  The sync
-- code then could not tell them apart, which led to deleted annotations
-- "resurrecting" when you reopened the book.
--
-- Position is a much better identity key.  When you make a highlight,
-- KOReader records WHERE in the document you placed it — and that
-- "where" is what makes a highlight unique.  If you select the exact
-- same text range again, you genuinely DO get the same annotation
-- (idempotency is the correct behavior).  If you select a different
-- range, even if it overlaps with another, the start and end positions
-- differ, so the key differs.
--
--
-- TWO KINDS OF DOCUMENTS, TWO KINDS OF POSITIONS
--
-- KOReader handles two types of documents differently:
--
--   * Rolling documents (EPUB, FB2, MOBI, etc.)
--     Positions are "XPointer" strings — paths into the document's
--     XML/HTML tree, like:
--       "/body/DocFragment[11]/body/div/p[154]/span[2]/text().25"
--     pos0 is the start, pos1 is the end.  Both are strings.
--
--   * Paging documents (PDF, DJVU, CBZ)
--     Positions are tables with screen coordinates and a zoom factor:
--       { page = 5, x = 100, y = 200, zoom = 1.5 }
--
-- We have to handle both, and they need different key formats.
--
--
-- ZOOM NORMALIZATION FOR PAGING DOCS
--
-- When you make a highlight at zoom 1.5 and the file gets opened on
-- another device at zoom 2.0, the same physical pixel position has
-- different x/y screen coordinates.  We need the key to be the SAME
-- regardless of zoom — otherwise the same highlight on two devices
-- would have two different keys and would never merge.
--
-- Solution: we divide x and y by the zoom factor before putting them
-- in the key.  That gives us "zoom-1.0 normalized" coordinates which
-- are the same on any device.  We also round to integer pixels to
-- avoid floating-point drift causing tiny differences.
--
--
-- BOOKMARKS ARE A SPECIAL CASE
--
-- KOReader's "dog-ear" bookmarks have a page but no pos0/pos1.  We
-- give them their own key format: "BOOKMARK|<page>".  This makes sure
-- a bookmark on page 42 never accidentally collides with a highlight
-- whose key happens to start with "42".
--
-- =============================================================================

local Identity = {}


-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------


--- Compute the position-based key for an annotation.
---
--- Returns a string key on success, or nil if the annotation is
--- malformed (missing position fields, or has positions of mixed
--- types — for example, pos0 as a string but pos1 as a table).
---
--- @param annotation table The annotation, with pos0/pos1 and/or page fields.
--- @return string|nil The key, or nil if the annotation is unusable.
function Identity.compute_key(annotation)
    if type(annotation) ~= "table" then
        return nil
    end

    -- Case 1: bookmark (page-only, no end position).
    if annotation.page and not annotation.pos1 then
        return "BOOKMARK|" .. tostring(annotation.page)
    end

    -- Case 2: highlight or note (needs both pos0 and pos1).
    if not annotation.pos0 or not annotation.pos1 then
        return nil
    end

    local pos0 = annotation.pos0
    local pos1 = annotation.pos1

    -- Both positions must be the same type (both strings for rolling
    -- documents, or both tables for paging documents).  Mixed types
    -- mean the annotation was corrupted somehow — refuse to guess.
    if type(pos0) ~= type(pos1) then
        return nil
    end

    -- Case 2a: rolling document (XPointer strings).
    if type(pos0) == "string" then
        if pos0 == "" or pos1 == "" then
            return nil
        end
        return pos0 .. "||" .. pos1
    end

    -- Case 2b: paging document (coordinate tables).
    if type(pos0) == "table" then
        return Identity._compute_paging_key(annotation, pos0, pos1)
    end

    -- Unknown position type.
    return nil
end


--- Check whether an annotation has a valid, computable identity key.
---
--- This is a convenience for callers who want to filter out unusable
--- annotations before processing them.  It's exactly equivalent to
--- "compute_key returned non-nil".
---
--- @param annotation table The annotation to check.
--- @return boolean True if the annotation has a valid position.
function Identity.is_valid(annotation)
    return Identity.compute_key(annotation) ~= nil
end


--- Parse a key string back into its components.
---
--- Useful for debugging and for code that wants to know whether a
--- given key refers to a bookmark or to a range highlight.  Returns
--- nil if the key string is malformed.
---
--- @param key string The key string previously returned by compute_key.
--- @return string|nil The kind: "BOOKMARK" or "RANGE", or nil.
--- @return string|nil For "BOOKMARK", the page. For "RANGE", the pos0 part.
--- @return string|nil For "RANGE", the pos1 part. Nil otherwise.
function Identity.parse_key(key)
    if type(key) ~= "string" then
        return nil
    end

    local bookmark_page = key:match("^BOOKMARK|(.+)$")
    if bookmark_page then
        return "BOOKMARK", bookmark_page, nil
    end

    local pos0_part, pos1_part = key:match("^(.-)||(.+)$")
    if pos0_part then
        return "RANGE", pos0_part, pos1_part
    end

    return nil
end


-- ----------------------------------------------------------------------------
-- Internal helpers
-- ----------------------------------------------------------------------------


--- Build a key for an annotation in a paging document (PDF, DJVU, etc).
---
--- Positions in paging documents are tables of the form:
---   { page = N, x = number, y = number, zoom = number }
---
--- We zoom-normalize the coordinates (divide x and y by zoom, then
--- round to integers) so that the same physical position generates
--- the same key regardless of the zoom level at which the highlight
--- was originally created.
---
--- @param annotation table The full annotation (we read its .page field).
--- @param pos0 table The start position.
--- @param pos1 table The end position.
--- @return string The computed key.
function Identity._compute_paging_key(annotation, pos0, pos1)
    -- A zoom of zero would crash the division.  This shouldn't happen
    -- in practice, but if it does (corrupted data), treat it as 1.0.
    local zoom_factor = pos0.zoom or 1
    if zoom_factor == 0 then
        zoom_factor = 1
    end

    -- KOReader stores `page` on the annotation itself for paging docs.
    -- Fall back to pos0.page if the top-level field is missing.
    local page_number = annotation.page or pos0.page or 0

    local pos0_x_normalized = math.floor((pos0.x or 0) / zoom_factor)
    local pos0_y_normalized = math.floor((pos0.y or 0) / zoom_factor)
    local pos1_x_normalized = math.floor((pos1.x or 0) / zoom_factor)
    local pos1_y_normalized = math.floor((pos1.y or 0) / zoom_factor)

    return string.format(
        "%d|%d|%d||%d|%d",
        page_number,
        pos0_x_normalized, pos0_y_normalized,
        pos1_x_normalized, pos1_y_normalized
    )
end


return Identity
