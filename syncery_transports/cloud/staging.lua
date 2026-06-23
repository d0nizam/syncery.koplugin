-- =============================================================================
-- syncery_transports/cloud/staging.lua
-- =============================================================================
--
-- Pure helpers for the cloud transport.  No state, no I/O — these are
-- here so the trickier rules (how to name cloud objects so they don't
-- collide, how to safely stage to a temp file) can be tested
-- independently of any real cloud provider.
--
-- WHY STAGING EXISTS
--
-- KOReader's SyncService keys remote files by the BASENAME of the
-- local path it's handed, not the full path.  That's a problem in
-- Syncery's hash storage mode, where every book's progress file is
-- literally named `progress.json` — they'd all collide in the cloud,
-- overwriting each other.
--
-- Fix: never upload the original file directly.  Stage the bytes into
-- a temp file whose name encodes both the book ID and the file kind
-- ("progress" / "annotations"), then upload THAT.  We always go
-- through this staging step (even in SDR mode where the source name
-- happens to be unique) so the cloud key scheme is uniform regardless
-- of how the local file is stored.  Uniform keys also mean a device
-- that switches storage modes (SDR ↔ hash) keeps talking to the same
-- cloud objects — no orphaned uploads.
--
-- WHAT GOES IN A CLOUD NAME
--
-- Format: `syncery-<kind>-<book_id>.json`
--   • kind     — "progress" or "annotations"; must be a fixed enum
--                so that adding a new kind one day doesn't accidentally
--                shadow an existing key.
--   • book_id  — the same partial-MD5 hash KOReader uses for
--                hashdocsettings and the Syncthing doc_id.
--                Stable across devices for the same book.
--
-- Everything is lowercase ASCII so the name survives every cloud
-- provider's filename rules (Dropbox case-folds, FTP can be 8.3
-- restrictive, WebDAV varies).  No spaces, no path separators, no
-- punctuation other than `-` and `.`.
--
-- =============================================================================


local Staging = {}


-- ----------------------------------------------------------------------------
-- Allowed "kind" values.  Keep this enum closed: any caller passing
-- an unknown kind gets a nil return from cloud_name_for, which the
-- transport classifies as REJECTED.  We do NOT want stale cloud keys
-- created from typos.
-- ----------------------------------------------------------------------------


Staging.KINDS = {
    progress    = true,
    annotations = true,
}


-- ----------------------------------------------------------------------------
-- Name builder.
-- ----------------------------------------------------------------------------


--- Build the canonical cloud-object name for a (kind, book_id) pair.
--- Returns nil if either input is unusable — caller treats nil as a
--- programmer error and surfaces REJECTED.
---@param kind string         "progress" or "annotations"
---@param book_id string      stable partial-MD5 hash
---@return string|nil
function Staging.cloud_name_for(kind, book_id)
    if not Staging.KINDS[kind] then return nil end
    if type(book_id) ~= "string" or book_id == "" then return nil end
    -- Defensive: strip anything that could create a path traversal
    -- attack if a malformed book_id ever flowed through us.  The
    -- expected shape is 32 hex chars (a full MD5 digest — KOReader's
    -- partialMD5 hashes only parts of the file for speed but still
    -- returns the full 128-bit digest); we accept a slightly broader
    -- alphanumeric set to be lenient with legitimately weird future IDs.
    if book_id:match("[^%w%-_]") then return nil end
    return "syncery-" .. kind .. "-" .. book_id .. ".json"
end


-- ----------------------------------------------------------------------------
-- Temp-path builder.
--
-- Where the staged file lives.  We use a fixed staging directory
-- under the user's settings dir, with the cloud_name as the filename
-- — that way SyncService sees the right basename and the right
-- bytes in one go.
--
-- The caller is responsible for `mkdir -p` of the staging dir
-- (we don't want this module touching the filesystem).
-- ----------------------------------------------------------------------------


--- Compute the local staging file path for a cloud upload.
---@param staging_dir string   absolute path to the staging directory
---@param cloud_name string    output of Staging.cloud_name_for
---@return string|nil
function Staging.staging_path_for(staging_dir, cloud_name)
    if type(staging_dir) ~= "string" or staging_dir == "" then return nil end
    if type(cloud_name) ~= "string" or cloud_name == "" then return nil end
    local cleaned = staging_dir:gsub("/+$", "")
    return cleaned .. "/" .. cloud_name
end


return Staging
