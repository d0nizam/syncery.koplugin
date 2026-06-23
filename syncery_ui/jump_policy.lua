-- =============================================================================
-- syncery_ui/jump_policy.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- One pure decision: given the "best" reading position from some OTHER
-- device (the candidate the `checkRemote` loop found in the shared
-- progress file), should we raise a jump prompt for it, or stay quiet?
--
-- This logic lives here, not inline inside `main.lua:checkRemote` where
-- it would tangle with KOReader UI access, so the decision is a pure,
-- deterministic function that can be unit-tested in isolation —
-- the path had NO test, which is precisely why a real defect (the old
-- `r_rev <= self.own_revision` gate) survived undetected.
--
-- WHY IT LIVES IN syncery_ui/ (NOT syncery_progress/)
--
-- "Should we interrupt the read with a jump prompt?" is a UI/interaction
-- POLICY, not a data concern.  `syncery_progress/` is a pure
-- data-merging engine and must not carry UI concerns: attaching these
-- thresholds to the `Progress` namespace would conflate "where the data
-- is" with "what the human-attention threshold is".  Keeping the policy
-- (and its thresholds) here,
-- beside the jump-prompt rendering (`jump_toast.lua`), keeps the data
-- engine clean.
--
--
-- THE TWO QUESTIONS
--
-- A jump prompt is worth raising only when BOTH hold:
--
--   1. RE-PROMPT SUPPRESSION — we have not already shown the user this
--      remote device at this revision (or newer).  We track, per remote
--      device, the highest revision we have already prompted about (and
--      the user acknowledged, by jumping or staying).  This is keyed
--      PER DEVICE because `revision` is a per-device monotonic counter
--      (`upsert_local_entry` bumps only the writing device's own key) —
--      so "device B at revision 5" and "device C at revision 5" are
--      unrelated states, and a single global threshold cannot compare
--      them.  Revision ALONE is enough to order one device's states;
--      timestamp would only matter under a device_id collision (two
--      physical devices sharing one id), which is a separate pathology.
--
--   2. SUBSTANTIVE DELTA — the remote position actually differs from
--      ours by enough to be worth a jump.  Tiny percent wobble is
--      ignored (PERCENT_EPSILON); small-but-real percent moves still
--      don't warrant a prompt unless the xpath (DOM anchor, rolling
--      docs) genuinely changed (SYNC_TRIGGER_DELTA).
--
-- The caller owns the acked map (it lives on the plugin instance and is
-- reset per book in onReaderReady) and updates it when the user
-- acknowledges a prompt.  This module never mutates it.
--
-- =============================================================================

local JumpPolicy = {}

-- Percent below this is treated as "no movement" (identical positions).
JumpPolicy.PERCENT_EPSILON    = 0.001

-- Small-but-real percent moves below this don't warrant a prompt on
-- their own — only if the xpath (rolling-doc DOM anchor) also changed.
JumpPolicy.SYNC_TRIGGER_DELTA = 0.005


--- Decide whether to raise a jump prompt for the best remote entry.
---
--- Pure and deterministic: no I/O, no mutation of any argument.
---
--- @param best_entry table|nil The best OTHER-device entry (from
---        `Merge.pick_best`), or nil if there is nothing to consider.
--- @param best_device_id string|nil Its device_id — the MAP KEY returned
---        by `pick_best` (authoritative; the entry's stamped `.device_id`
---        field is not relied on here).
--- @param acked_map table|nil { [device_id] = highest_acked_revision }.
---        Missing/nil is treated as "nothing acknowledged yet".
--- @param l_percent number|nil This device's current percent (0..1).
--- @param l_xpath string|nil This device's current xpath, or nil.
--- @return boolean True = raise the jump prompt; false = suppress.
function JumpPolicy.should_prompt(best_entry, best_device_id, acked_map, l_percent, l_xpath)
    if type(best_entry) ~= "table" then return false end
    acked_map = acked_map or {}

    local r_rev     = tonumber(best_entry.revision) or 0
    local r_percent = tonumber(best_entry.percent)  or 0
    local r_xpath   = best_entry.xpath
    l_percent       = tonumber(l_percent) or 0

    -- 1. Re-prompt suppression (per-device, revision-keyed).
    --    "Never prompted about this device" reads as -1 so that any real
    --    entry (revision >= 1, since upsert starts at 1) is offered once.
    local acked_rev = -1
    if best_device_id ~= nil and acked_map[best_device_id] ~= nil then
        acked_rev = tonumber(acked_map[best_device_id]) or -1
    end
    if r_rev <= acked_rev then return false end

    -- 2. Substantive delta — is it actually worth jumping?
    local delta = math.abs(r_percent - l_percent)
    if delta <= JumpPolicy.PERCENT_EPSILON then return false end
    if delta <= JumpPolicy.SYNC_TRIGGER_DELTA
       and not (r_xpath and r_xpath ~= l_xpath) then
        return false
    end

    return true
end


--- Pick which OTHER device's position to offer as a jump target.
---
--- Pick which device's position to offer as a FORWARD jump target — or nil.
---
--- Two questions, one answer: WHICH device (recency) and WHETHER to offer
--- at all (direction).  Both are recency questions, so they collapse into a
--- single ranking:
---
---   Rank EVERY device — INCLUDING this one — by recency, then return the
---   winner ONLY IF it is not us.  If WE are the most-recently-read, there
---   is nothing newer to offer; an older device would be a BACKWARD jump,
---   suppressed by default.  Otherwise the winner is, by construction, newer
---   than us = a forward jump.
---
--- Why RECENCY, not save-count, not furthest: a per-device revision
--- counter measures how OFTEN a device saved, not how RECENTLY, so ranking
--- by it surfaces the chattiest device.  Why FORWARD-only by recency, not by
--- percent: "forward" means NEWER, not "further in the document" —
--- re-reading legitimately moves you backward in percent, and you still want
--- your most-recent spot, not a stale further one.  The guiding principle —
--- "forward means newer, not necessarily ahead in the document" — is why we
--- order by recency, not by percent, and why backward (older) is suppressed by
--- default.  Syncery's revision is a per-device save-count, not a logical
--- clock, so we rank the jump target by `timestamp` directly, not by revision.
---
--- Our own recency comes from our own entry in the passed map (the shared
--- progress file already includes it — no extra plumbing).  If we have no
--- entry (never saved here) we are simply never the winner, so any device
--- with a real read is offered.
---
--- Pure: no I/O, no mutation.  We deliberately do NOT touch `Merge.pick_best`
--- (its other caller — the conflict resolver's "which device wrote this
--- file" attribution — wants last-writer-by-(revision,timestamp), a
--- different, cosmetic need).  Backward sync could later become an opt-in.
---
--- Order within the ranking: timestamp DESC, then percent DESC, then
--- device_id (only to make exact ties deterministic).
---
--- @param entries table|nil { [device_id] = entry }, freshness-filtered, INCLUDING this device's own entry.
--- @param our_device_id string|nil this device's id — the recency baseline AND the "don't offer ourselves" guard.
--- @return table|nil The most-recently-read OTHER entry when it is newer than us (forward), else nil.
--- @return string|nil Its device_id (the map key).
function JumpPolicy.pick_jump_target(entries, our_device_id)
    local best_entry, best_device_id = nil, nil
    for device_id, entry in pairs(entries or {}) do
        if type(entry) == "table" then
            if JumpPolicy._is_more_recent(entry, device_id, best_entry, best_device_id) then
                best_entry, best_device_id = entry, device_id
            end
        end
    end
    -- If WE are the most-recently-read device, every other candidate is older
    -- than us → a backward jump → suppressed by default.  Nothing to offer.
    if best_device_id == our_device_id then return nil end
    return best_entry, best_device_id
end


--- True iff entry `a` (key `ka`) should beat `b` (key `kb`) as the jump
--- target: more recent (timestamp), then furthest (percent), then a stable
--- device_id tiebreak so the result never depends on Lua's pairs() order.
--- A nil `b` always loses.
function JumpPolicy._is_more_recent(a, ka, b, kb)
    if not a then return false end
    if not b then return true  end

    local ta = tonumber(a.timestamp) or 0
    local tb = tonumber(b.timestamp) or 0
    if ta ~= tb then return ta > tb end

    local pa = tonumber(a.percent) or 0
    local pb = tonumber(b.percent) or 0
    if pa ~= pb then return pa > pb end

    -- Exact (timestamp, percent) tie: pick the smaller device_id so the
    -- choice is deterministic regardless of iteration order.
    return tostring(ka) < tostring(kb)
end


return JumpPolicy
