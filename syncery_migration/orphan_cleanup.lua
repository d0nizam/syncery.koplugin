-- =============================================================================
-- syncery_migration/orphan_cleanup.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- This is the DECISION CORE of the orphan-cleanup feature: given the set of
-- books that currently exist and the set of Syncery JSON sidecar files on disk,
-- it classifies each JSON as kept / orphan / fail-closed. It is the production
-- realisation of a design validated by a standalone PoC, and the
-- REPLACEMENT for the old `_cleanupOrphans`.
--
-- It is PURE LOGIC. It touches no files, no UI, no globals — everything it
-- needs comes through injected dependency functions. The filesystem walking,
-- hashing, and confirm-with-names UI live in separate adapter/UI layers (built
-- in later steps); keeping the decision here isolated makes it unit-testable
-- exactly as the PoC was.
--
--
-- THE IDEA (one mechanism for all four KOReader metadata layouts)
--
-- An orphan is a Syncery JSON whose book cannot be found by ANY available
-- identity. Identities are split by how each mode KEYS its sidecar:
--
--   * CONTENT-keyed modes (synceryhash, hashdocsettings): the sidecar is
--     located by content hash, which is STRUCTURAL (synceryhash encodes it in
--     the path; hashdocsettings encodes it in the ".sdr" directory name). We
--     check hash membership ONLY. There is no name fallback, and none is valid:
--     after a content edit the old-hash record is a LEGITIMATE orphan (Syncery
--     and KOReader both abandon it), and synceryhash carries no recoverable
--     name anyway.
--
--   * PATH-keyed modes (doc, dir): the sidecar is located by file path, which
--     is STRUCTURAL (the ".sdr" / JSON filename). Its content hash lives only
--     in the sibling metadata.lua and may be absent (the partial_md5 caveat).
--     We check hash membership (rename-stable) OR book-exists-by-path
--     (content-mod-stable). The union covers both failure axes.
--
--   * fail_closed: when identity is wholly undeterminable, we NEVER delete.
--
--
-- THE INJECTED DEPENDENCIES (supplied by the adapter layer / by tests)
--
--   deps.present_book_hashes()
--       -> { [hash]=true, ... }
--       The content hashes of every book that currently exists. The adapter
--       builds this from home_dir (the BASE, always) unioned with any
--       configured roots (OPPORTUNISTIC; their absence does NOT
--       block). Tests supply a fake set.
--
--   deps.syncery_jsons()
--       -> { { path=<string>, klass=<"synceryhash"|"hashdocsettings"|"doc"|"dir"> }, ... }
--       Every Syncery JSON sidecar found, each tagged with its location class.
--
--   deps.json_book_hash(entry)
--       -> hash<string> | nil
--       The content hash recorded for this JSON's book (from the path for
--       synceryhash, the ".sdr" dir name for hashdocsettings, the sibling
--       metadata.lua for doc/dir). nil when not recorded.
--
--   deps.json_book_name_present(entry)
--       -> true | false | nil
--       PATH-keyed only: does the book exist at its recorded path? true = yes,
--       false = no, nil = the path could not be determined. (Never consulted
--       for content-keyed entries.)
--
--
-- THE RESULT
--
--   { orphans = { <path>, ... },      -- safe to delete (after confirm-with-names)
--     kept = { <path>, ... },         -- a present book carries this identity
--     fail_closed = { <path>, ... } } -- identity undeterminable; do NOT delete
--
-- =============================================================================

local OrphanCleanup = {}

-- The two modes whose sidecar is located by content hash. For these, the hash
-- is structural and authoritative, and a hash miss is a genuine orphan (there
-- is no path identity to fall back to, by design).
local CONTENT_KEYED = { synceryhash = true, hashdocsettings = true }

--- Classify every Syncery JSON as kept / orphan / fail-closed.
---
--- Pure function: all inputs arrive through `deps`. See the file header for the
--- dependency contract and the design rationale.
---
--- @param deps table The injected dependency functions (see header).
--- @return table { orphans = {paths}, kept = {paths}, fail_closed = {paths} }
function OrphanCleanup.scan(deps)
    assert(type(deps) == "table", "orphan_cleanup: deps table required")
    for _, name in ipairs({ "present_book_hashes", "syncery_jsons",
                            "json_book_hash", "json_book_name_present" }) do
        assert(type(deps[name]) == "function",
            "orphan_cleanup: missing dependency '" .. name .. "'")
    end

    local present = deps.present_book_hashes()
    local result = { orphans = {}, kept = {}, fail_closed = {} }

    for _, entry in ipairs(deps.syncery_jsons()) do
        local hash = deps.json_book_hash(entry)

        if CONTENT_KEYED[entry.klass] then
            -- Content-keyed: the hash is structural; no name fallback.
            if hash == nil then
                -- Guard: the hash should always be structurally present for
                -- these modes. If it is not (e.g. a malformed path), refuse to
                -- delete rather than guess.
                result.fail_closed[#result.fail_closed + 1] = entry.path
            elseif present[hash] then
                result.kept[#result.kept + 1] = entry.path
            else
                -- No present book carries this content. The book is gone, or
                -- its content changed (a legitimate orphan in these modes,
                -- mirroring KOReader abandoning the old sidecar).
                result.orphans[#result.orphans + 1] = entry.path
            end
        else
            -- Path-keyed (doc/dir): hash primary (rename-stable), name fallback
            -- (content-mod-stable). Union: kept if EITHER finds the book.
            if hash ~= nil and present[hash] then
                -- Found by content hash — survives renames/moves.
                result.kept[#result.kept + 1] = entry.path
            else
                local name_present = deps.json_book_name_present(entry)
                if name_present == true then
                    -- Found by path — survives content edits (the .sdr stays
                    -- put in doc/dir, so a content-modified book is still
                    -- linked here).
                    result.kept[#result.kept + 1] = entry.path
                elseif name_present == false then
                    -- Neither identity finds a book → orphan.
                    result.orphans[#result.orphans + 1] = entry.path
                else
                    -- name_present == nil: the path is undeterminable and the
                    -- hash did not match. Refuse to delete.
                    result.fail_closed[#result.fail_closed + 1] = entry.path
                end
            end
        end
    end

    return result
end

return OrphanCleanup
