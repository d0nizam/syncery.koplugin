-- =============================================================================
-- syncery_ui/progress_browser/aggregate.lua
-- =============================================================================
--
-- Pure per-book state computation for the Progress Browser's all-books view.
-- Given ONE book's shared progress `entries` map and the local device id, it
-- reduces them to a compact row model organised around the MOST RECENT reading
-- position -- the same anchor KOReader's own progress sync (kosync) uses: a
-- single "latest record" (last write wins), with the local position compared to
-- it as "forward" (the latest is ahead -> catch up) or not.  We deliberately do
-- NOT organise around Kindle's "furthest page read": that model breaks on
-- re-reading (it always points at the end until manually cleared), which is
-- exactly why KOReader chose recency + a forward/backward prompt instead.
--
-- TRANSPORT-AGNOSTIC: it reads only the shared progress entries (percent /
-- timestamp / label), which BOTH Syncthing and cloud transports sync.  It does
-- NOT consult peer connectivity or any transport state.  "Freshness" is the
-- Syncery-stamped per-entry timestamp (a LOCAL stamp), the same
-- window the status panel uses -- never a transport "last seen".
--
-- The state token is limited to reading-POSITION-vs-recency states:
--   "behind"  -- a MORE RECENT position exists AHEAD of this device (forward;
--               actionable -- jump to the latest to continue).  Also when this
--               device has no position at all but another device does.
--   "even"    -- the most recent position is at this device's position (synced).
--   "neutral" -- this device HOLDS the most recent position, is the only device,
--               or is ahead of the most recent activity (nothing to catch up to).
-- A genuine cross-device CONFLICT (e.g. metadata status complete-vs-abandoned)
-- is a separate concern surfaced per-book elsewhere; it is intentionally NOT
-- synthesized here from positions alone (no phantom conflict state).
-- =============================================================================

local ProgressBridge = require("syncery_progress/progress_bridge")

local Aggregate = {}

-- Two devices truly synced to the same position derive (near-)identical
-- percent; allow a hair of tolerance for rounding across KOReader versions /
-- device font sizes (kosync rounds the percent for the same reason).
local DEFAULT_EPSILON = 0.005   -- 0.5 %

--- @param entries  table       device_id -> { percent, timestamp, label, ... }
--- @param local_id string|nil  this device's id
--- @param opts     table|nil   { freshness_days, now_epoch, epsilon }
--- @return table row {
---   my_percent, recent_percent, recent_label, recent_device_id,
---   is_recent_me (boolean), other_count (number),
---   state ("behind" | "even" | "neutral")
--- }
function Aggregate.aggregate_book(entries, local_id, opts)
    opts = opts or {}
    local epsilon = opts.epsilon or DEFAULT_EPSILON
    entries = type(entries) == "table" and entries or {}

    local fresh = ProgressBridge.filter_fresh_for_display(
        entries, opts.freshness_days, opts.now_epoch)

    -- This device's entry: prefer fresh, fall back to the unfiltered map so a
    -- long-idle local position still counts (mirrors the status panel, which
    -- always shows "this device" even when its own entry is stale).
    local my = (local_id and (fresh[local_id] or entries[local_id])) or nil
    local my_percent = my and tonumber(my.percent) or nil

    -- Candidates: my entry (always, if present) plus every FRESH other device.
    -- Stale others are hidden, so they neither show nor anchor recency.
    local candidates = {}
    if my then
        candidates[#candidates + 1] = {
            percent = my_percent or 0, label = my.label, id = local_id,
            ts = tonumber(my.timestamp) or 0,
        }
    end
    local other_count = 0
    for dev_id, entry in pairs(fresh) do
        if dev_id ~= local_id and type(entry) == "table" and entry.percent then
            other_count = other_count + 1
            candidates[#candidates + 1] = {
                percent = tonumber(entry.percent) or 0, label = entry.label,
                id = dev_id, ts = tonumber(entry.timestamp) or 0,
            }
        end
    end

    -- The MOST RECENT (max timestamp) candidate -- KOReader's "latest record":
    -- the single anchor the dashboard organises around.
    local recent = nil
    for _, c in ipairs(candidates) do
        if not recent or c.ts > recent.ts then recent = c end
    end
    local recent_percent = recent and recent.percent or 0
    local is_recent_me   = recent ~= nil and recent.id == local_id

    -- State token (recency-framed).
    local state
    if my_percent == nil then
        -- This device has no position; if anyone else does, the latest is a
        -- jump target ("behind"); otherwise nothing to show.
        state = (other_count > 0) and "behind" or "neutral"
    elseif other_count == 0 then
        state = "neutral"                                  -- only this device
    elseif is_recent_me then
        state = "neutral"                                  -- this device holds the latest
    elseif (recent_percent - my_percent) > epsilon then
        state = "behind"                                   -- a newer position is ahead
    elseif math.abs(recent_percent - my_percent) <= epsilon then
        state = "even"                                     -- latest is at my position
    else
        state = "neutral"                                  -- I'm ahead of the latest activity
    end

    return {
        my_percent       = my_percent,
        recent_percent   = recent_percent,
        recent_label     = recent and recent.label or nil,
        recent_device_id = recent and recent.id or nil,
        is_recent_me     = is_recent_me,
        other_count      = other_count,
        state            = state,
    }
end

return Aggregate
