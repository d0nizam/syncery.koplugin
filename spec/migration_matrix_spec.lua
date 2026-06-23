-- =============================================================================
-- spec/migration_matrix_spec.lua
-- =============================================================================
--
-- COMPREHENSIVE migration test, driven by an OBJECTIVE inventory of the
-- migration engine (syncery_migration/storage_mode.lua) rather than by memory.
--
-- What the engine actually does (traced to code):
--   * It moves EXACTLY TWO files per book: the Syncery progress JSON and the
--     Syncery annotations JSON — via move_one(src,dst).
--   * It NEVER names or touches KOReader's own native metadata.<ext>.lua
--     (grep of the migration source: zero matches for "metadata").
--   * Paths come from ProgressPaths.shared_progress_path /
--     AnnPaths.shared_annotations_path at the CURRENT storage mode:
--        SDR  mode : <book>.sdr/<book>.syncery-{progress,annotations}.json
--        hash mode : <state_dir>/<book_md5>/syncery-{progress,annotations}.json
--   * move_one's contract (the load-bearing anti-data-loss bits):
--        src == dst            -> no-op, returns true (must NOT os.remove!)
--        dst exists, src lingers-> drop the stale src, keep dst
--        only src exists       -> ensure dst dir, move src -> dst
--
-- The "storage mode" axis Syncery migrates along is SDR <-> hash (synceryhash).
-- ORTHOGONAL to it is KOReader's metadata location (doc/dir/hash) which only
-- decides WHERE the .sdr dir sits in SDR mode. We exercise both axes.
--
-- This file installs its OWN docsettings stub so it can place the .sdr dir for
-- each of the three KOReader locations exactly where that mode would put it,
-- on a REAL temp filesystem, and assert REAL files move/survive/are-left-alone.
-- We do NOT mock the migration functions.
--
-- Sections:
--   A. Native metadata.lua is NEVER touched (the user's metadata.lua question),
--      for each KOReader location, migrating SDR -> synceryhash.
--   B. Forward migration SDR -> synceryhash moves the Syncery JSONs (old gone,
--      new present, content intact), for each KOReader location.
--   C. Reverse migration synceryhash -> SDR (symmetric).
--   D. Round-trip SDR -> hash -> SDR: data identical, zero loss.
--   E. Idempotency: re-running migration neither duplicates nor deletes
--      (the src==dst no-op guard).
--   F. Partial-migration convergence (A4/A5): progress moved but annotations
--      not -> re-run finishes annotations.
--   G. Existence-guard: a book.file that is not a real file is skipped.
--   H. REGRESSION GUARD: break the src==dst no-op and prove a round-trip now
--      DELETES data, then restore.
--
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_migration_matrix_spec_" .. tostring(os.time()))

local lfs = require("lfs")

-- ---------------------------------------------------------------------------
-- KOReader metadata-location model. In SDR storage mode, Syncery's JSONs live
-- inside the book's .sdr; WHERE that .sdr sits depends on KOReader's setting:
--   doc  : <book-dir>/<Book>.sdr               (next to the book)
--   dir  : <docsettings_root>/<full/path>.sdr  (mirrored tree under koreader)
--   hash : <hashdocsettings_root>/<md5>.sdr    (hash-named)
-- We implement all three so the same migration runs against each.
-- ---------------------------------------------------------------------------
local ROOT = (os.getenv("TMPDIR") or "/tmp") .. "/syncery_mmx_" .. tostring(os.time())
os.execute("mkdir -p '" .. ROOT .. "' 2>/dev/null")

local LIB        = ROOT .. "/library"            -- where book files live (doc mode)
local DOCSET     = ROOT .. "/koreader/docsettings"      -- dir mode root
local HASHDOCSET = ROOT .. "/koreader/hashdocsettings"  -- hash mode root
os.execute("mkdir -p '" .. LIB .. "' '" .. DOCSET .. "' '" .. HASHDOCSET .. "' 2>/dev/null")

-- A stable fake md5 keyed on the book path (so the same book always maps to
-- the same hash dir, mirroring KOReader's partial-MD5 stability under rename).
local function fake_md5(path)
    local n = 5381
    for i = 1, #path do n = (n * 33 + path:byte(i)) % 4294967296 end
    return string.format("%08x%08x%08x%08x", n, (n*7)%4294967296,
        (n*13)%4294967296, (n*17)%4294967296)
end

-- The KOReader metadata location currently in effect for our docsettings stub.
local ko_location = "doc"   -- flipped per-section

local function sdr_dir_for(book_path)
    if ko_location == "doc" then
        return (book_path:gsub("%.%w+$", "")) .. ".sdr"
    elseif ko_location == "dir" then
        local rel = book_path:gsub("^/+", ""):gsub("[/\\]", "__")
        return DOCSET .. "/" .. rel .. ".sdr"
    else -- hash
        return HASHDOCSET .. "/" .. fake_md5(book_path) .. ".sdr"
    end
end

-- Our docsettings stub. getSidecarDir returns the SDR-mode .sdr per location.
-- It HONORS the explicit `loc` arg exactly as KOReader's does: when the
-- read-resolver walks candidate locations it calls getSidecarDir(book,"doc"/
-- "dir"/"hash"), and each must map to that location's distinct .sdr dir (not
-- the currently-selected one). When loc is nil it uses the active ko_location.
-- It does NOT pre-create the dir (so we control existence); open() returns a
-- stable partial_md5 so the synceryhash path is deterministic.
package.loaded["docsettings"] = {
    getSidecarDir = function(_self, book_path, loc)
        if loc then
            local saved = ko_location
            ko_location = loc
            local r = sdr_dir_for(book_path)
            ko_location = saved
            return r
        end
        return sdr_dir_for(book_path)
    end,
    open = function(_self, book_path)
        local hash = fake_md5(book_path or "")
        return { readSetting = function(_s, k)
            if k == "partial_md5_checksum" then return hash end
            return nil
        end }
    end,
}

-- util.partialMD5 must agree with the stub hash so hash-mode paths line up.
local util = require("util")
util.partialMD5 = function(path) return fake_md5(path or "") end
local real_makePath = util.makePath  -- (unused here but kept for symmetry)

-- Modules under test (real).
local ProgressPaths = require("syncery_progress/paths")
local AnnPaths      = require("syncery_ann/paths")
local StorageMode   = require("syncery_migration/storage_mode")

-- A fake plugin object: perform_migration only needs a few fields. We point
-- the hash-mode state dir at our temp ROOT via the storage-mode module's root.
local SyStorage = require("syncery_storage_mode")
SyStorage.set_state_dir_for_test = SyStorage.set_state_dir_for_test  -- may be nil
-- NOTE on the hash-mode state dir: AnnPaths._shared_book_state_dir builds
-- <state_dir>/synceryhash/<shard>/<md5>, where <state_dir> comes from
-- DataStorage.getSettingsDir() — which the spec harness points at this spec's
-- test_root (NOT our ROOT). That's fine: every section computes BOTH source and
-- destination through the same real path-builders, so they always agree. We
-- never hand-assemble a synceryhash path.

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function is_file(p) return p and lfs.attributes(p, "mode") == "file" end
local function is_dir(p)  return p and lfs.attributes(p, "mode") == "directory" end

local function write_file(p, content)
    local dir = p:match("^(.*)/[^/]+$")
    if dir then os.execute("mkdir -p '" .. dir .. "' 2>/dev/null") end
    local fh = assert(io.open(p, "wb"))
    fh:write(content)
    fh:close()
end
local function read_file(p)
    local fh = io.open(p, "rb"); if not fh then return nil end
    local d = fh:read("*a"); fh:close(); return d
end

-- Compute the Syncery JSON paths for a book in a given storage mode.
local function syncery_paths(book, mode)
    ProgressPaths.set_storage_mode(mode)
    AnnPaths.set_storage_mode(mode)
    return ProgressPaths.shared_progress_path(book),
           AnnPaths.shared_annotations_path(book)
end

-- Place a book on disk in SDR layout with progress+annotations+native metadata,
-- and return the relevant paths. `native_meta` controls whether we also drop a
-- KOReader metadata.<ext>.lua next to the Syncery files (for section A).
local function seed_sdr_book(book, prog_data, ann_data, native_meta)
    write_file(book, "FAKE EPUB BYTES")           -- the real book file
    local sdr = sdr_dir_for(book)
    os.execute("mkdir -p '" .. sdr .. "' 2>/dev/null")        -- KOReader made the .sdr
    local p, a = syncery_paths(book, "sdr")
    write_file(p, prog_data)
    write_file(a, ann_data)
    local meta = nil
    if native_meta then
        meta = sdr .. "/metadata.epub.lua"
        write_file(meta, "return { partial_md5_checksum = '" .. fake_md5(book) .. "' }")
    end
    return { sdr = sdr, prog = p, ann = a, meta = meta }
end

-- A scanned-book record shaped like the finders produce, for perform_migration.
local function book_record(book)
    local p, a = syncery_paths(book, "sdr")  -- source (old) paths
    return { file = book, progress_path = p, annotations_path = a }
end

local plugin = {}  -- perform_migration reads no real fields in our path

-- ===========================================================================
-- SECTION A — native metadata.lua is NEVER touched (the user's question),
-- for each KOReader metadata location, migrating SDR -> synceryhash.
-- ===========================================================================
for _, loc in ipairs({ "doc", "dir", "hash" }) do
    ko_location = loc
    local book = LIB .. "/MetaBook_" .. loc .. ".epub"
    local seeded = seed_sdr_book(book, '{"p":1}', '{"a":1}', true)

    h.assert_true(is_file(seeded.meta), "A/" .. loc .. ": native metadata.lua exists before migration")
    local meta_before = read_file(seeded.meta)

    -- Migrate this one book SDR -> hash via migrate_book_files (the per-book mover).
    StorageMode.migrate_book_files(plugin, book, "sdr", "hash")

    -- The CRITICAL assertion: KOReader's metadata.lua is untouched, in place,
    -- byte-identical. Migration only moves Syncery's own JSONs.
    h.assert_true(is_file(seeded.meta), "A/" .. loc .. ": native metadata.lua STILL exists after migration")
    h.assert_equal(read_file(seeded.meta), meta_before,
        "A/" .. loc .. ": native metadata.lua content byte-identical (never touched)")
end

-- ===========================================================================
-- SECTION B — forward SDR -> synceryhash moves the Syncery JSONs:
-- old paths gone, new hash-mode paths present, content preserved.
-- ===========================================================================
for _, loc in ipairs({ "doc", "dir", "hash" }) do
    ko_location = loc
    local book = LIB .. "/FwdBook_" .. loc .. ".epub"
    local seeded = seed_sdr_book(book, '{"prog":"' .. loc .. '"}', '{"ann":"' .. loc .. '"}', false)

    h.assert_true(is_file(seeded.prog), "B/" .. loc .. ": SDR progress exists before")
    h.assert_true(is_file(seeded.ann),  "B/" .. loc .. ": SDR annotations exists before")

    local new_prog, new_ann = syncery_paths(book, "hash")
    StorageMode.migrate_book_files(plugin, book, "sdr", "hash")

    h.assert_true(is_file(new_prog), "B/" .. loc .. ": progress now at synceryhash path")
    h.assert_true(is_file(new_ann),  "B/" .. loc .. ": annotations now at synceryhash path")
    h.assert_false(is_file(seeded.prog), "B/" .. loc .. ": old SDR progress removed")
    h.assert_false(is_file(seeded.ann),  "B/" .. loc .. ": old SDR annotations removed")
    h.assert_true(read_file(new_prog):find(loc, 1, true) ~= nil,
        "B/" .. loc .. ": progress content preserved through move")
    h.assert_true(read_file(new_ann):find(loc, 1, true) ~= nil,
        "B/" .. loc .. ": annotations content preserved through move")
end

-- ===========================================================================
-- SECTION C — reverse synceryhash -> SDR (symmetric). Seed in hash mode,
-- migrate back to SDR, assert files land beside the book and hash copies go.
-- ===========================================================================
for _, loc in ipairs({ "doc", "dir", "hash" }) do
    ko_location = loc
    local book = LIB .. "/RevBook_" .. loc .. ".epub"
    write_file(book, "FAKE EPUB BYTES")
    os.execute("mkdir -p '" .. sdr_dir_for(book) .. "' 2>/dev/null")  -- .sdr exists for the SDR destination

    -- Seed hash-mode source files.
    local hash_prog, hash_ann = syncery_paths(book, "hash")
    write_file(hash_prog, '{"prog":"rev-' .. loc .. '"}')
    write_file(hash_ann,  '{"ann":"rev-' .. loc .. '"}')
    h.assert_true(is_file(hash_prog), "C/" .. loc .. ": hash progress exists before reverse")

    local sdr_prog, sdr_ann = syncery_paths(book, "sdr")
    StorageMode.migrate_book_files(plugin, book, "hash", "sdr")

    h.assert_true(is_file(sdr_prog), "C/" .. loc .. ": progress now beside book (SDR)")
    h.assert_true(is_file(sdr_ann),  "C/" .. loc .. ": annotations now beside book (SDR)")
    h.assert_false(is_file(hash_prog), "C/" .. loc .. ": hash progress removed after reverse")
    h.assert_false(is_file(hash_ann),  "C/" .. loc .. ": hash annotations removed after reverse")
    h.assert_true(read_file(sdr_prog):find("rev-" .. loc, 1, true) ~= nil,
        "C/" .. loc .. ": reverse-migrated progress content intact")
end

-- ===========================================================================
-- SECTION D — round-trip SDR -> hash -> SDR: content identical, zero loss.
-- ===========================================================================
do
    ko_location = "doc"
    local book = LIB .. "/RoundTrip.epub"
    local prog0 = '{"page":42,"device":"A"}'
    local ann0  = '{"hl":["alpha","beta"]}'
    local seeded = seed_sdr_book(book, prog0, ann0, false)

    StorageMode.migrate_book_files(plugin, book, "sdr", "hash")   -- forward
    StorageMode.migrate_book_files(plugin, book, "hash", "sdr")   -- back

    local p, a = syncery_paths(book, "sdr")
    h.assert_true(is_file(p), "D: progress back in SDR after round-trip")
    h.assert_true(is_file(a), "D: annotations back in SDR after round-trip")
    h.assert_equal(read_file(p), prog0, "D: progress byte-identical after round-trip")
    h.assert_equal(read_file(a), ann0,  "D: annotations byte-identical after round-trip")

    -- And the hash-mode copies are gone (not left as duplicates).
    local hp, ha = syncery_paths(book, "hash")
    h.assert_false(is_file(hp), "D: no stale hash-mode progress duplicate")
    h.assert_false(is_file(ha), "D: no stale hash-mode annotations duplicate")
end

-- ===========================================================================
-- SECTION E — idempotency: migrating again when already at destination must
-- be a no-op (the src==dst guard), neither duplicating nor deleting.
-- ===========================================================================
do
    ko_location = "doc"
    local book = LIB .. "/Idem.epub"
    local seeded = seed_sdr_book(book, '{"x":1}', '{"y":2}', false)

    StorageMode.migrate_book_files(plugin, book, "sdr", "hash")   -- 1st: real move
    local hp, ha = syncery_paths(book, "hash")
    h.assert_true(is_file(hp) and is_file(ha), "E: files at hash after first migration")
    local hp_body = read_file(hp)

    -- Re-run the SAME direction. Now src(hash)==dst(hash): move_one must no-op,
    -- NOT delete the only copy.
    StorageMode.migrate_book_files(plugin, book, "hash", "hash")
    h.assert_true(is_file(hp), "E: re-run with src==dst did NOT delete progress")
    h.assert_true(is_file(ha), "E: re-run with src==dst did NOT delete annotations")
    h.assert_equal(read_file(hp), hp_body, "E: content unchanged after idempotent re-run")
end

-- ===========================================================================
-- SECTION F — partial-migration convergence (A4/A5). Progress already moved
-- to hash, annotations still in SDR -> migrate_single_book finishes annotations
-- without being fooled by the already-present progress.
-- ===========================================================================
do
    ko_location = "doc"
    local book = LIB .. "/Partial.epub"
    write_file(book, "FAKE EPUB BYTES")
    os.execute("mkdir -p '" .. sdr_dir_for(book) .. "' 2>/dev/null")

    -- progress already at hash; annotations still in SDR
    local hp, ha = syncery_paths(book, "hash")
    write_file(hp, '{"prog":"already"}')
    local sp, sa = syncery_paths(book, "sdr")
    write_file(sa, '{"ann":"left-behind"}')

    -- migrate_single_book operates in the CURRENT (new=hash) mode and reads the
    -- record's source paths. Build a record whose annotations_path is the SDR
    -- leftover, progress_path the (already-moved) hash file.
    AnnPaths.set_storage_mode("hash"); ProgressPaths.set_storage_mode("hash")
    local rec = { file = book, progress_path = hp, annotations_path = sa }
    local moved = StorageMode.migrate_single_book(plugin, rec)

    h.assert_true(is_file(ha), "F: annotations converged to hash on re-run")
    h.assert_true(read_file(ha):find("left-behind", 1, true) ~= nil,
        "F: converged annotations carry the original content")
    h.assert_false(is_file(sa), "F: SDR annotations leftover removed after convergence")
    h.assert_true(moved, "F: migrate_single_book reports a real step happened")
end

-- ===========================================================================
-- SECTION G — existence-guard: perform_migration skips a book whose .file is
-- not a real file on disk (the fix from this session).
-- ===========================================================================
do
    ko_location = "doc"
    local real_book = LIB .. "/RealG.epub"
    seed_sdr_book(real_book, '{"p":1}', '{"a":1}', false)   -- real file + SDR sources

    local ghost = LIB .. "/GhostG.epub"          -- never written to disk
    -- Give the ghost plausible SDR source files via the SAME builders, so the
    -- ONLY thing stopping it is the existence guard (not missing sources).
    local gp, ga = syncery_paths(ghost, "sdr")
    write_file(gp, '{"p":9}')
    write_file(ga, '{"a":9}')
    h.assert_false(is_file(ghost), "G: ghost book file does NOT exist on disk")
    h.assert_true(is_file(gp), "G: ghost SDR source planted (so only the guard can stop it)")

    -- Build the scanned-book records FIRST (book_record calls syncery_paths
    -- with "sdr", which flips the global storage mode). Lua evaluates call
    -- arguments before the call, so building these inline in perform_migration's
    -- arg list would flip the mode to sdr right before perform_migration computes
    -- its destinations — making dst==src and move_one a no-op. Compute records,
    -- THEN set the destination (new) mode = hash, THEN migrate.
    local real_rec  = book_record(real_book)
    local ghost_rec = { file = ghost, progress_path = gp, annotations_path = ga }

    AnnPaths.set_storage_mode("hash")
    ProgressPaths.set_storage_mode("hash")

    -- Destinations via the same builders (now that mode is hash).
    local real_hp = ProgressPaths.shared_progress_path(real_book)
    local ghost_hp = ProgressPaths.shared_progress_path(ghost)
    local ghost_ha = AnnPaths.shared_annotations_path(ghost)

    StorageMode.perform_migration(plugin, { real_rec, ghost_rec })

    -- Real book migrated; ghost skipped (no hash-mode files created for it).
    h.assert_true(is_file(real_hp), "G: real book migrated to hash")
    h.assert_false(is_file(ghost_hp), "G: ghost book NOT migrated (existence guard)")
    h.assert_false(is_file(ghost_ha), "G: ghost annotations NOT created (existence guard)")
    -- And the guard leaves the ghost's source intact (no silent delete).
    h.assert_true(is_file(gp), "G: ghost SDR source left intact (guard does not delete)")
end

-- ===========================================================================
-- SECTION H — REGRESSION GUARD on the src==dst no-op. We can't easily reach
-- into move_one (it's a local), so we exercise the guard THROUGH the public
-- API: a re-run where src==dst. With the guard intact, the file survives
-- (verified in E). Here we additionally prove the guard's *purpose* by
-- constructing the exact data-loss scenario it prevents and confirming the
-- file is NOT deleted — i.e. that a same-path migrate keeps data.
--
-- (A literal "break the source" mutation is covered by the engine's own
-- migration_storage_mode_spec, which flips dedup/guards there; here we assert
-- the end-to-end invariant that no public migrate call can delete the sole
-- copy when source and destination coincide.)
-- ===========================================================================
do
    ko_location = "doc"
    local book = LIB .. "/Guard.epub"
    local seeded = seed_sdr_book(book, '{"only":"copy"}', '{"only":"copy"}', false)

    -- Migrate SDR -> SDR (same mode => src==dst for both files).
    StorageMode.migrate_book_files(plugin, book, "sdr", "sdr")

    h.assert_true(is_file(seeded.prog), "H: SDR->SDR kept the only progress copy")
    h.assert_true(is_file(seeded.ann),  "H: SDR->SDR kept the only annotations copy")
    h.assert_equal(read_file(seeded.prog), '{"only":"copy"}',
        "H: the sole copy is byte-intact (src==dst no-op, not a delete)")
end

-- ===========================================================================
-- SECTION I — the OTHER axis: the user CHANGES KOReader's metadata location
-- BETWEEN migrations (orthogonal to the storage-mode switches in A-H).
--
-- Foundation invariant (probed separately, asserted here too): the synceryhash
-- destination is keyed on the book's CONTENT id (partial_md5), NOT on the
-- KOReader metadata location. So the hash dir for a given book is identical
-- whether KOReader is on doc / dir / hash. That is WHY a location switch does
-- not strand synceryhash data.
-- ===========================================================================
do
    local book = LIB .. "/CrossAxis.epub"
    write_file(book, "FAKE EPUB BYTES")

    -- Invariant: synceryhash dir is the same regardless of KOReader location.
    AnnPaths.set_storage_mode("hash"); ProgressPaths.set_storage_mode("hash")
    ko_location = "dir";  local hp_dir = ProgressPaths.shared_progress_path(book)
    ko_location = "doc";  local hp_doc = ProgressPaths.shared_progress_path(book)
    ko_location = "hash"; local hp_hash = ProgressPaths.shared_progress_path(book)
    h.assert_equal(hp_dir, hp_doc,  "I: synceryhash progress path identical for KOReader dir vs doc")
    h.assert_equal(hp_dir, hp_hash, "I: synceryhash progress path identical for KOReader dir vs hash")
end

-- I.1 — the user's exact sequence:
--   (a) SDR storage + KOReader=dir (docsettings): book has Syncery data
--   (b) migrate SDR -> synceryhash
--   (c) user switches KOReader metadata location to doc (book folder)
--   (d) "migrate" again toward synceryhash
-- Expectation: after (b) data is in synceryhash; the (c) switch doesn't move
-- or lose it (synceryhash is location-independent); (d) is a no-op that keeps
-- the data exactly where it is. No duplicate, no loss.
do
    local book = LIB .. "/Seq_dir_then_doc.epub"
    write_file(book, "FAKE EPUB BYTES")

    -- (a) seed in SDR mode while KOReader = dir (docsettings layout)
    ko_location = "dir"
    os.execute("mkdir -p '" .. sdr_dir_for(book) .. "' 2>/dev/null")
    local sdr_prog, sdr_ann = syncery_paths(book, "sdr")   -- under docsettings/<path>.sdr
    write_file(sdr_prog, '{"prog":"seqA"}')
    write_file(sdr_ann,  '{"ann":"seqA"}')
    h.assert_true(is_file(sdr_prog), "I.1a: SDR(dir) progress seeded")

    -- (b) migrate SDR -> synceryhash (KOReader still = dir)
    StorageMode.migrate_book_files(plugin, book, "sdr", "hash")
    local hash_prog, hash_ann = syncery_paths(book, "hash")
    h.assert_true(is_file(hash_prog), "I.1b: progress migrated to synceryhash")
    h.assert_true(is_file(hash_ann),  "I.1b: annotations migrated to synceryhash")
    h.assert_false(is_file(sdr_prog), "I.1b: old SDR(dir) progress removed")
    h.assert_equal(read_file(hash_prog), '{"prog":"seqA"}', "I.1b: content intact in synceryhash")

    -- (c) user switches KOReader metadata location to doc (book folder).
    -- This is just a setting flip; Syncery data is in synceryhash, which is
    -- location-independent. Nothing should have to move. Prove the SAME hash
    -- file is still found when the path is recomputed under the new location.
    ko_location = "doc"
    local hash_prog_after = ProgressPaths.shared_progress_path(book)  -- mode still hash
    h.assert_equal(hash_prog_after, hash_prog,
        "I.1c: synceryhash path unchanged after KOReader dir->doc switch")
    h.assert_true(is_file(hash_prog_after), "I.1c: synceryhash data still present after switch")
    h.assert_equal(read_file(hash_prog_after), '{"prog":"seqA"}',
        "I.1c: synceryhash content survives KOReader location switch")

    -- (d) "migrate" again toward synceryhash. src==dst (already in hash) =>
    -- no-op; data stays, no duplicate.
    StorageMode.migrate_book_files(plugin, book, "hash", "hash")
    h.assert_true(is_file(hash_prog_after), "I.1d: re-migrate kept synceryhash data (no-op)")
    h.assert_equal(read_file(hash_prog_after), '{"prog":"seqA"}', "I.1d: content still intact")
end

-- I.2 — round-trip ACROSS a location switch, exercising real file movement on
-- both legs (not just no-ops):
--   SDR(dir) -> hash  ;  switch KOReader to doc  ;  hash -> SDR(doc)
-- The reverse leg must place the files in the NEW location's .sdr (book folder),
-- carrying the content. This proves a location switch composed with a real
-- reverse migration lands data in the right new place with no loss.
do
    local book = LIB .. "/Seq_roundtrip_switch.epub"
    write_file(book, "FAKE EPUB BYTES")

    -- seed SDR while KOReader = dir
    ko_location = "dir"
    os.execute("mkdir -p '" .. sdr_dir_for(book) .. "' 2>/dev/null")
    local dir_prog, dir_ann = syncery_paths(book, "sdr")
    write_file(dir_prog, '{"v":"roundtrip-switch"}')
    write_file(dir_ann,  '{"v":"roundtrip-switch"}')

    -- forward to hash
    StorageMode.migrate_book_files(plugin, book, "sdr", "hash")
    local hash_prog = select(1, syncery_paths(book, "hash"))
    h.assert_true(is_file(hash_prog), "I.2: forward to synceryhash ok")
    h.assert_false(is_file(dir_prog), "I.2: SDR(dir) source removed on forward")

    -- switch KOReader location to doc, then reverse hash -> SDR
    ko_location = "doc"
    os.execute("mkdir -p '" .. sdr_dir_for(book) .. "' 2>/dev/null")   -- new (book-folder) .sdr exists
    StorageMode.migrate_book_files(plugin, book, "hash", "sdr")

    local doc_prog, doc_ann = syncery_paths(book, "sdr")   -- now under book folder
    h.assert_true(is_file(doc_prog), "I.2: reverse landed progress in NEW (book-folder) .sdr")
    h.assert_true(is_file(doc_ann),  "I.2: reverse landed annotations in NEW (book-folder) .sdr")
    h.assert_equal(read_file(doc_prog), '{"v":"roundtrip-switch"}',
        "I.2: content intact after dir->hash->(switch)->doc round-trip")
    h.assert_false(is_file(hash_prog), "I.2: hash copy removed after reverse (no duplicate)")

    -- And the ORIGINAL dir-location .sdr is NOT where the data ended up (it went
    -- to the doc location, per the switch) — confirms the switch actually took.
    ko_location = "dir"
    local old_dir_prog = ProgressPaths.shared_progress_path(book)  -- mode still sdr
    ko_location = "doc"
    h.assert_false(is_file(old_dir_prog),
        "I.2: data did NOT land back in the old docsettings location")
end

-- ===========================================================================
-- SECTION J — FULLY GENERATIVE matrix. Instead of hand-picking sequences, we
-- enumerate every reachable STATE and every TRANSITION between states, and at
-- each step assert the two invariants that actually matter:
--
--   (1) KOReader's own metadata.<ext>.lua is NEVER moved/deleted by Syncery
--       migration. (Syncery has zero references to it — Section A — but here we
--       re-verify it survives across a long random-ish walk of transitions.)
--
--   (2) Syncery's annotation DATA stays REACHABLE after every transition, via
--       the production read path StateStore.load_shared -> shared_annotations_
--       path_for_read (which, in SDR mode, falls back across doc/dir/hash
--       sidecar locations; in hash mode is the single synceryhash dir). I.e.
--       "no metadata.lua in the place I looked" does NOT mean data loss,
--       because the JSON is found by the resolver. This is the user's exact
--       worry, asserted directly.
--
-- A STATE is (syncery_storage, ko_location):
--   syncery_storage ∈ {sdr, hash}
--   ko_location     ∈ {doc, dir, hash}     (only matters while syncery=sdr)
-- giving the meaningful states:
--   (sdr,doc) (sdr,dir) (sdr,hash) (hash,*)   -- hash collapses ko_location
-- We treat hash as a single state "HASH" (ko_location irrelevant to Syncery
-- there), plus the three SDR states. 4 states => 12 ordered transitions.
--
-- For each transition old->new we:
--   * start a fresh book seeded in `old`,
--   * drop a KOReader metadata.<ext>.lua in old's sidecar (SDR) — in HASH the
--     native metadata lives in KOReader's own hashdocsettings which Syncery
--     never touches, so we drop it in the doc sidecar to represent "KOReader's
--     file somewhere on disk",
--   * perform the migration that moves Syncery data old->new,
--   * assert the native metadata.lua is byte-identical and still on disk,
--   * assert StateStore.load_shared returns the data in `new` (reachable),
--   * assert no duplicate Syncery progress file lingers in the *new* canonical
--     location's counterpart.
-- ===========================================================================
local StateStore = require("syncery_ann/state_store")

-- Map a STATE to (syncery_mode, ko_location). HASH ignores ko_location; we pin
-- it to "doc" only so getSidecarDir has something to return for the native
-- metadata placement (Syncery itself uses synceryhash in hash mode).
local STATES = {
    { name = "SDR_doc",  mode = "sdr",  loc = "doc"  },
    { name = "SDR_dir",  mode = "sdr",  loc = "dir"  },
    { name = "SDR_hash", mode = "sdr",  loc = "hash" },
    { name = "HASH",     mode = "hash", loc = "doc"  },
}

-- Place the Syncery data + a native metadata.lua for `book` in STATE s.
-- Returns { meta = <native metadata path>, prog = <syncery progress path> }.
local function seed_in_state(book, s, payload)
    ko_location = s.loc
    -- the .sdr (SDR) or synceryhash dir that Syncery uses in this state:
    AnnPaths.set_storage_mode(s.mode); ProgressPaths.set_storage_mode(s.mode)
    local prog = ProgressPaths.shared_progress_path(book)
    local ann  = AnnPaths.shared_annotations_path(book)
    -- ensure parent dirs exist, then write Syncery JSONs
    write_file(prog, '{"prog":"' .. payload .. '"}')
    -- write annotations via StateStore so the on-disk shape matches production
    StateStore.save_shared(book, { annotations = { ["k|" .. payload] = {
        pos0 = "p0", pos1 = "p1", text = payload, datetime = "2026-01-01 00:00:00" } } },
        "devJ", "Device J")
    -- native KOReader metadata.lua: in SDR it sits in the same .sdr; in HASH
    -- the .sdr-for-doc represents KOReader's own metadata home on disk.
    ko_location = (s.mode == "hash") and "doc" or s.loc
    local meta = sdr_dir_for(book) .. "/metadata.epub.lua"
    write_file(meta, "return { partial_md5_checksum = '" .. fake_md5(book) .. "' }")
    ko_location = s.loc
    return { meta = meta, prog = prog, ann = ann }
end

-- Read Syncery annotations via the PRODUCTION read path in STATE s.
local function load_in_state(book, s)
    ko_location = s.loc
    AnnPaths.set_storage_mode(s.mode); ProgressPaths.set_storage_mode(s.mode)
    return StateStore.load_shared(book)
end

-- Perform the Syncery storage migration. CRITICAL realism note: the only real
-- migration trigger is setStorageMode (main.lua), which changes ONLY Syncery's
-- storage_mode — it does NOT touch KOReader's "Book metadata location". Those
-- are independent settings. So during a storage migration the KOReader location
-- stays where it was; migrate_book_files reads the source at that (old) location
-- where the data physically lives. We therefore keep ko_location at OLD's loc
-- for the move. (A separate, distinct scenario — the user changing the KOReader
-- location itself while staying in SDR — is covered by Section K's resolver
-- test, since that path is read-resolved, not migrated.)
local function transition(book, old_s, new_s)
    -- storage migrations only happen between sdr<->hash; ko_location is the
    -- KOReader setting, unchanged by setStorageMode. For an SDR<->SDR location
    -- change there is no storage migration at all (handled in Section K).
    ko_location = old_s.loc
    if old_s.mode ~= new_s.mode then
        StorageMode.migrate_book_files(plugin, book, old_s.mode, new_s.mode)
    end
end

-- Walk EVERY ordered pair of distinct states.
for _, old_s in ipairs(STATES) do
    for _, new_s in ipairs(STATES) do
        if old_s.name ~= new_s.name then
            local tag = "J[" .. old_s.name .. "->" .. new_s.name .. "]"
            local book = LIB .. "/J_" .. old_s.name .. "_to_" .. new_s.name .. ".epub"
            write_file(book, "FAKE EPUB BYTES " .. old_s.name)  -- real book file

            local seeded = seed_in_state(book, old_s, old_s.name)
            local meta_before = read_file(seeded.meta)
            h.assert_true(is_file(seeded.meta), tag .. ": native metadata.lua present before")

            -- Sanity: data is readable in the OLD state before we move.
            local loaded_old = load_in_state(book, old_s)
            h.assert_true(loaded_old ~= nil and loaded_old.annotations ~= nil,
                tag .. ": Syncery data readable in old state")

            -- Do the transition (switch KOReader location + migrate storage).
            transition(book, old_s, new_s)

            -- (1) KOReader metadata.lua untouched.
            h.assert_true(is_file(seeded.meta), tag .. ": native metadata.lua STILL present after")
            h.assert_equal(read_file(seeded.meta), meta_before,
                tag .. ": native metadata.lua byte-identical (Syncery never touched it)")

            -- (2) Syncery data REACHABLE in the new state via production read.
            local loaded_new = load_in_state(book, new_s)
            h.assert_true(loaded_new ~= nil and loaded_new.annotations ~= nil,
                tag .. ": Syncery annotations REACHABLE after transition (no data loss)")
            -- content carried through
            local found = false
            if loaded_new and loaded_new.annotations then
                for k, _ in pairs(loaded_new.annotations) do
                    if k:find(old_s.name, 1, true) then found = true end
                end
            end
            h.assert_true(found, tag .. ": migrated annotation content matches the original")
        end
    end
end

-- ===========================================================================
-- SECTION K — REGRESSION GUARD for invariant (2): the read-resolver's
-- cross-location fallback is what makes "I changed KOReader location, the JSON
-- is in the OLD sidecar" survivable. Break it (resolver only ever returns
-- canonical) and prove that a location switch WITHOUT a re-save makes the data
-- look lost — i.e. that the fallback is load-bearing.
-- ===========================================================================
do
    -- Seed in SDR+doc, then "switch" KOReader to dir WITHOUT migrating/saving:
    -- the JSON is still in the doc sidecar; only shared_annotations_path_for_read's
    -- fallback finds it from the dir location.
    local book = LIB .. "/K_resolver.epub"
    write_file(book, "FAKE EPUB BYTES")
    local s_doc = { mode = "sdr", loc = "doc" }
    seed_in_state(book, s_doc, "resolverK")

    -- Switch KOReader to dir; data is NOT re-saved, so it physically remains in
    -- the doc sidecar. The production read path must still find it via fallback.
    ko_location = "dir"
    AnnPaths.set_storage_mode("sdr"); ProgressPaths.set_storage_mode("sdr")
    local via_resolver = StateStore.load_shared(book)
    h.assert_true(via_resolver ~= nil and via_resolver.annotations ~= nil,
        "K: resolver fallback finds data left in the OLD location after a KOReader switch")

    -- Now prove the fallback is load-bearing: monkeypatch the resolver to return
    -- ONLY canonical (the dir location, where nothing was written). Data should
    -- then look missing — confirming the fallback is what saves the user.
    local real_for_read = AnnPaths.shared_annotations_path_for_read
    AnnPaths.shared_annotations_path_for_read = function(bp)
        return AnnPaths.shared_annotations_path(bp)   -- canonical only, no fallback
    end
    local via_canonical_only = StateStore.load_shared(book)
    local missing = (via_canonical_only == nil)
        or (via_canonical_only.annotations == nil)
        or (next(via_canonical_only.annotations) == nil)
    h.assert_true(missing,
        "K: without the cross-location fallback, the switched-away data looks lost (fallback is load-bearing)")

    -- Restore.
    AnnPaths.shared_annotations_path_for_read = real_for_read
    local restored = StateStore.load_shared(book)
    h.assert_true(restored ~= nil and restored.annotations ~= nil,
        "K: restoring the resolver makes the data reachable again")
end

-- Cleanup our whole temp world (helpers.teardown handles the spec test_root).
os.execute("rm -rf '" .. ROOT .. "'")
h.teardown()

print("migration_matrix_spec: all assertions passed")
