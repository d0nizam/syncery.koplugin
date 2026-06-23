-- =============================================================================
-- syncery_ann/mtime_gate.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- It owns the decision "should the annotation back-sync run for this book
-- right now, and what mtime should we remember afterwards?"  `checkRemote`
-- (in main.lua) debounces the orchestrator on the shared annotation file's
-- modification time: it runs the merge only when the file's mtime differs
-- from the last value we remembered, or when we have not synced this book
-- yet this session (cache still 0).
--
--
-- WHY THIS IS A SEPARATE FILE (and why the cache timing matters)
--
-- The merge writes the shared file (save_shared) WHEN its content changed:
-- JsonStore.write is skip-if-unchanged, so a no-op merge leaves the file (and
-- its mtime) untouched.  When it DOES write, our own merge bumps the mtime.
-- The original inline code read the mtime ONCE, before the merge, and then
-- cached that PRE-write value:
--
--     local ann_mtime = file_mtime(path)         -- mtime BEFORE the merge
--     if changed or cache == 0 then
--         sync()                                  -- may write (mtime moves)
--         cache = ann_mtime                       -- caches the PRE-write value!
--     end
--
-- That left the cache stale by construction: on the very next checkRemote
-- (resume, syncNow, the +2s re-arm, or any later tick) the file's current
-- mtime no longer matched the cached pre-write value, so the orchestrator
-- ran a SECOND time even though nothing had changed but our own write.  A
-- redundant merge every cycle — wasteful, and (before S3) it was one of the
-- ways the phantom-tombstone window opened (a second merge with the local
-- live list still empty).
--
-- The fix is to remember the mtime AS IT IS AFTER the merge: re-read it once
-- the merge has run.  This is correct whether the merge wrote (mtime bumped)
-- or skipped a no-op (mtime unchanged) — the re-read captures the file's real
-- current state either way.  Then the next tick sees "current == cached" and
-- correctly skips, until a genuine remote change moves the mtime again.
--
-- Note this does NOT make the gate miss real remote changes:
--   * A remote write at a LATER second moves the mtime -> current ~= cache
--     -> we merge.  Caught.
--   * The only blind spot is a remote write in the EXACT same wall-clock
--     second as our own write (lfs mtime is whole-second granularity).
--     That is transient: it is caught by the next remote change at any later
--     second, or by the next book open (the cache is a fresh-instance field
--     reset to 0 per book -> cache == 0 forces a merge).  See
--     ANNOTATION_DELIVERY_DESIGN.md Q1.
--
--
-- PURITY / TESTABILITY
--
-- `run` takes the current mtime, the remembered cache, and two injected
-- callbacks (do_sync, read_mtime).  It returns the new cache value and
-- whether it synced.  No globals, no I/O of its own -- the unit test hands
-- in fakes and asserts both the sync decision AND that the returned cache
-- reflects the POST-sync mtime, which is the whole point of the fix.

local MtimeGate = {}

--- Decide whether the annotation back-sync should run, given the shared
--- file's current mtime and the value we last remembered.
---
--- Runs when the mtime has changed since last time, OR when we have not
--- synced this book yet this session (cache == 0).
---
--- @param current_mtime number The shared file's mtime right now (0 if absent).
--- @param cache number The mtime we remembered last time (0 = never synced this session).
--- @return boolean Whether the merge should run now.
function MtimeGate.should_sync(current_mtime, cache)
    return current_mtime ~= cache or cache == 0
end

--- Run the gated annotation back-sync and compute the mtime to remember.
---
--- This encapsulates the read-decide-REREAD sequence so the cache reflects
--- the file's state AFTER the merge (whether it wrote or skipped a no-op),
--- not the pre-merge value.
---
--- @param current_mtime number The shared file's mtime read before the merge.
--- @param cache number The previously remembered mtime (0 = fresh this session).
--- @param do_sync function Called (no args) to run the merge when the gate opens.
--- @param read_mtime function Called (no args) AFTER the merge to re-read the
---        file's mtime; its return value becomes the new cache.  Capturing the
---        post-merge mtime (bumped if it wrote, unchanged if the write was a
---        skipped no-op) is what closes the redundant-second-merge bug.
--- @return number new_cache The mtime to remember (post-merge when synced; unchanged otherwise).
--- @return boolean did_sync Whether the merge ran.
function MtimeGate.run(current_mtime, cache, do_sync, read_mtime)
    if not MtimeGate.should_sync(current_mtime, cache) then
        return cache, false
    end
    do_sync()
    -- Re-read AFTER the merge so the cache reflects the file's real mtime --
    -- whether the merge wrote (bump) or skipped a no-op rewrite (no bump,
    -- JsonStore.write is skip-if-unchanged).  Either way the next tick then
    -- compares against the true current value instead of re-running for
    -- nothing.
    local post_mtime = read_mtime()
    return post_mtime, true
end

return MtimeGate
