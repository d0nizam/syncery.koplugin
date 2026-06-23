-- =============================================================================
-- syncery_ui/progress_browser/jump_targets.lua
-- =============================================================================
--
-- Pure selection logic for the Progress Browser per-book detail: which other
-- devices get their own jump button, and whether the [Jump to latest] button
-- should appear.  No UI dependencies, so it is unit-testable headless (init.lua
-- requires UI widgets and can only be loadfile-checked).
--
-- Rule:
--   * A per-device button is shown for every OTHER device that is NOT the
--     latest -- the latest is reached via [Jump to latest], so it gets no
--     separate button (avoids repeating it).
--   * [Jump to latest] is shown only when the latest is NOT this device
--     (jumping to your own position is pointless).  When THIS device is the
--     latest, [Jump to latest] is hidden and the other devices still get their
--     own buttons.
-- =============================================================================

local JumpTargets = {}

--- @param entries     table   map device_id -> entry (already freshness-filtered)
--- @param this_id     string  this device's id
--- @param latest_id   string|nil  the latest (max-timestamp) device's id (may equal this_id)
--- @return table   device_ids that get a per-device button (excl. this + latest)
--- @return boolean whether to show [Jump to latest] (latest exists and != this)
function JumpTargets.compute(entries, this_id, latest_id)
    local per_device = {}
    for dev_id, entry in pairs(entries or {}) do
        if type(entry) == "table" and entry.percent
                and dev_id ~= this_id and dev_id ~= latest_id then
            per_device[#per_device + 1] = dev_id
        end
    end
    local show_latest = (latest_id ~= nil) and (latest_id ~= this_id)
    return per_device, show_latest
end

return JumpTargets
