-- =============================================================================
-- spec/conflict_resolver_spec.lua
-- =============================================================================
--
-- Tests for syncery_ann/conflict_resolver.lua, the in-RAM merger that
-- folds Syncthing conflict files back into the main v2 file.
--
-- Unlike the merge_spec and tombstones_spec (pure functions, no I/O),
-- the conflict resolver works with real files on disk.  We exercise
-- it through real disk operations in a per-test temporary directory,
-- using the stubbed `datastorage`/`docsettings` helpers from the
-- test harness to point it at /tmp.
--
-- Each test writes a "main" file plus N conflict files, calls
-- `resolve_all`, then reads the result back and asserts on it.
--
-- =============================================================================

local h = require("spec.test_helpers")

-- The harness's setup() points `datastorage.getSettingsDir` at a
-- /tmp/syncery_test_<time> directory.  All the file paths we compute
-- below derive from that.  We do NOT call h.teardown() between
-- tests because each test uses a distinct fake "book file" path,
-- and the resolver scans only the directory of that book.
h.setup("/tmp/syncery_test_conflict_" .. tostring(os.time()))

local ConflictResolver = require("syncery_ann/conflict_resolver")
local Paths            = require("syncery_ann/paths")
local JsonStore        = require("syncery_ann/json_store")
local Identity         = require("syncery_ann/identity")
local lfs              = require("lfs")


-- ----------------------------------------------------------------------------
-- Test fixtures
-- ----------------------------------------------------------------------------


--- Counter used to generate distinct "book file" paths so each test
--- gets its own sidecar directory and doesn't see stale files from
--- previous tests.
---
--- We anchor under `h.test_root` (NOT a hard-coded `/tmp/...` path)
--- so each `luajit spec/run_tests.lua` invocation gets a clean slate.
--- Previously this used `/tmp/syncery_test_books/...`, which survived
--- across runs and caused mtime-based assertions to flake on the
--- second invocation.
local _book_counter = 0
local function unique_book_file()
    _book_counter = _book_counter + 1
    return string.format("%s/books/book_%03d.epub", h.test_root, _book_counter)
end


--- Build a state-shaped table with one annotation entry at a given
--- position + datetime + text.
local function single_ann_state(opts)
    local pos0 = opts.pos0 or "/p[1].0"
    local pos1 = opts.pos1 or "/p[1].50"
    local ann = {
        type = "highlight",
        pos0 = pos0, pos1 = pos1,
        text = opts.text or "ann",
        datetime_updated = opts.datetime_updated or "2024-01-01 12:00:00",
        deleted = opts.deleted or false,
    }
    return {
        schema_version  = 1,
        annotations     = { [Identity.compute_key(ann)] = ann },
        metadata        = opts.metadata or {},
        render_settings = opts.render_settings or {},
    }
end


--- Set up "main" + conflict files for the given book and return the
--- main file's path and the list of conflict paths created.
local function write_main_and_conflicts(book_path, main_state, conflict_states)
    -- Make sure the sidecar dir exists by triggering the path
    -- computation (which calls _ensure_directory_exists for hash mode,
    -- but in SDR mode we need to mkdir manually).
    Paths.set_storage_mode("sdr")
    local main_path = Paths.shared_annotations_path(book_path)

    -- Ensure the sidecar directory exists for SDR mode.
    local dir = main_path:match("^(.*)/[^/]+$")
    os.execute("mkdir -p '" .. dir .. "' 2>/dev/null")

    assert(JsonStore.write(main_path, main_state))

    -- Conflict-file naming: <stem>.sync-conflict-<date>-<time>-<id>.json
    -- where <stem> is the filename without .json.
    local main_filename = main_path:match("([^/]+)$")
    local stem = main_filename:match("^(.+)%.json$")

    local conflict_paths = {}
    for i, state in ipairs(conflict_states) do
        local timestamp = string.format("20241117-12000%d", i)
        local conflict_id = string.format("DEV%d", i)
        local cpath = string.format("%s/%s.sync-conflict-%s-%s.json",
            dir, stem, timestamp, conflict_id)
        assert(JsonStore.write(cpath, state))
        table.insert(conflict_paths, cpath)
    end

    return main_path, conflict_paths
end


--- Check whether a file exists.
local function file_exists(path)
    local f = io.open(path, "rb")
    if not f then return false end
    f:close()
    return true
end


-- ----------------------------------------------------------------------------
-- Tests
-- ----------------------------------------------------------------------------


-- ── Test 1: no conflict files → resolver returns zeros, no error ────

do
    local book = unique_book_file()
    Paths.set_storage_mode("sdr")
    local main_path = Paths.shared_annotations_path(book)
    os.execute("mkdir -p '" .. main_path:match("^(.*)/[^/]+$") .. "' 2>/dev/null")

    assert(JsonStore.write(main_path, single_ann_state{ text = "only-main" }))

    local seen, merged, err = ConflictResolver.resolve_all(book)
    h.assert_equal(seen, 0,    "no conflicts -> seen=0")
    h.assert_equal(merged, 0,  "no conflicts -> merged=0")
    h.assert_nil(err,          "no conflicts -> no error")
end


-- ── Test 2: find_conflict_files returns matching files only ─────────

do
    local book = unique_book_file()
    write_main_and_conflicts(book, single_ann_state{ text = "main" }, {
        single_ann_state{ text = "c1", pos0 = "/p[2].0", pos1 = "/p[2].10" },
        single_ann_state{ text = "c2", pos0 = "/p[3].0", pos1 = "/p[3].10" },
    })

    local found = ConflictResolver.find_conflict_files(book)
    h.assert_equal(#found, 2, "found both conflict files")
end


-- ── Test 3: single conflict file merges into main ───────────────────

do
    local book = unique_book_file()

    -- Main has annotation A.  Conflict has annotation B at a different
    -- position.  After resolve: main should have both A and B, and
    -- the conflict file should be gone.

    local A = { type = "highlight", pos0 = "/p[1].0", pos1 = "/p[1].50",
                text = "A", datetime_updated = "2024-01-01 12:00:00" }
    local B = { type = "highlight", pos0 = "/p[2].0", pos1 = "/p[2].50",
                text = "B", datetime_updated = "2024-02-01 12:00:00" }

    local main_state = {
        schema_version = 1,
        annotations = { [Identity.compute_key(A)] = A },
        metadata = {}, render_settings = {},
    }
    local conflict_state = {
        schema_version = 1,
        annotations = { [Identity.compute_key(B)] = B },
        metadata = {}, render_settings = {},
    }

    local main_path, conflict_paths =
        write_main_and_conflicts(book, main_state, { conflict_state })

    local seen, merged, err = ConflictResolver.resolve_all(book)
    h.assert_equal(seen, 1,    "saw 1 conflict file")
    h.assert_equal(merged, 1,  "merged 1 conflict file")
    h.assert_nil(err,          "no error")

    -- The conflict file should have been removed.
    h.assert_false(file_exists(conflict_paths[1]),
        "conflict file removed after successful merge")

    -- Main file should contain both A and B.
    local final, _diag = JsonStore.read(main_path)
    h.assert_true(final ~= nil, "main file readable")
    h.assert_true(final.annotations[Identity.compute_key(A)] ~= nil,
        "annotation A preserved")
    h.assert_true(final.annotations[Identity.compute_key(B)] ~= nil,
        "annotation B merged in")
end


-- ── Test 4: same-key conflict, newer datetime wins ──────────────────

do
    local book = unique_book_file()
    local pos0, pos1 = "/p[5].0", "/p[5].20"
    local A_old = { type = "highlight", pos0 = pos0, pos1 = pos1,
                    text = "old version",
                    datetime_updated = "2024-01-01 12:00:00" }
    local A_new = { type = "highlight", pos0 = pos0, pos1 = pos1,
                    text = "new version",
                    datetime_updated = "2024-06-01 12:00:00" }

    local main_state = {
        schema_version = 1,
        annotations = { [Identity.compute_key(A_old)] = A_old },
        metadata = {}, render_settings = {},
    }
    local conflict_state = {
        schema_version = 1,
        annotations = { [Identity.compute_key(A_new)] = A_new },
        metadata = {}, render_settings = {},
    }

    local main_path, _ = write_main_and_conflicts(
        book, main_state, { conflict_state })

    ConflictResolver.resolve_all(book)

    local final, _diag = JsonStore.read(main_path)
    local entry = final.annotations[Identity.compute_key(A_old)]
    h.assert_equal(entry.text, "new version", "newer datetime wins")
end


-- ── Test 5: multiple conflict files all get merged ──────────────────

do
    local book = unique_book_file()

    local A = { type = "highlight", pos0 = "/p[1].0", pos1 = "/p[1].10",
                text = "A", datetime_updated = "2024-01-01 12:00:00" }
    local B = { type = "highlight", pos0 = "/p[2].0", pos1 = "/p[2].10",
                text = "B", datetime_updated = "2024-01-01 12:00:00" }
    local C = { type = "highlight", pos0 = "/p[3].0", pos1 = "/p[3].10",
                text = "C", datetime_updated = "2024-01-01 12:00:00" }
    local D = { type = "highlight", pos0 = "/p[4].0", pos1 = "/p[4].10",
                text = "D", datetime_updated = "2024-01-01 12:00:00" }

    local main_path, conflict_paths = write_main_and_conflicts(book,
        {
            schema_version = 1,
            annotations = { [Identity.compute_key(A)] = A },
            metadata = {}, render_settings = {},
        },
        {
            { schema_version = 1, metadata = {}, render_settings = {},
              annotations = { [Identity.compute_key(B)] = B } },
            { schema_version = 1, metadata = {}, render_settings = {},
              annotations = { [Identity.compute_key(C)] = C } },
            { schema_version = 1, metadata = {}, render_settings = {},
              annotations = { [Identity.compute_key(D)] = D } },
        })

    local seen, merged = ConflictResolver.resolve_all(book)
    h.assert_equal(seen, 3,   "all 3 conflicts seen")
    h.assert_equal(merged, 3, "all 3 conflicts merged")

    for _, p in ipairs(conflict_paths) do
        h.assert_false(file_exists(p), "conflict file " .. p .. " removed")
    end

    local final, _ = JsonStore.read(main_path)
    local n = 0
    for _ in pairs(final.annotations) do n = n + 1 end
    h.assert_equal(n, 4, "final has all 4 annotations")
end


-- ── Test 6: tombstone in conflict file wins over alive in main ──────

do
    local book = unique_book_file()
    local pos0, pos1 = "/p[7].0", "/p[7].20"
    local same_time = "2024-05-01 12:00:00"

    local alive = { type = "highlight", pos0 = pos0, pos1 = pos1,
                    text = "x", deleted = false, datetime_updated = same_time }
    local tomb  = { type = "highlight", pos0 = pos0, pos1 = pos1,
                    text = "x", deleted = true,  datetime_updated = same_time }

    local main_path, _ = write_main_and_conflicts(book,
        {
            schema_version = 1, metadata = {}, render_settings = {},
            annotations = { [Identity.compute_key(alive)] = alive },
        },
        {
            { schema_version = 1, metadata = {}, render_settings = {},
              annotations = { [Identity.compute_key(tomb)] = tomb } },
        })

    ConflictResolver.resolve_all(book)

    local final, _ = JsonStore.read(main_path)
    local entry = final.annotations[Identity.compute_key(alive)]
    h.assert_true(entry.deleted,
        "tombstone wins exact-datetime tie (causality)")
end


-- ── Test 7: ~ separator variant is also caught by the pattern ───────
--
-- Some Syncthing versions / configurations use `~` instead of `.`
-- before "sync-conflict".  Our pattern accepts both.

do
    local book = unique_book_file()
    Paths.set_storage_mode("sdr")
    local main_path = Paths.shared_annotations_path(book)
    local dir = main_path:match("^(.*)/[^/]+$")
    os.execute("mkdir -p '" .. dir .. "' 2>/dev/null")

    local A = { type = "highlight", pos0 = "/p[1].0", pos1 = "/p[1].10",
                text = "A", datetime_updated = "2024-01-01 12:00:00" }
    JsonStore.write(main_path, {
        schema_version = 1, metadata = {}, render_settings = {},
        annotations = { [Identity.compute_key(A)] = A },
    })

    -- Build a conflict path with `~` separator manually.
    local main_filename = main_path:match("([^/]+)$")
    local stem = main_filename:match("^(.+)%.json$")
    local tilde_conflict = string.format(
        "%s/%s~sync-conflict-20241117-120000-TILDE.json", dir, stem)

    local B = { type = "highlight", pos0 = "/p[2].0", pos1 = "/p[2].10",
                text = "B", datetime_updated = "2024-01-01 12:00:00" }
    JsonStore.write(tilde_conflict, {
        schema_version = 1, metadata = {}, render_settings = {},
        annotations = { [Identity.compute_key(B)] = B },
    })

    local seen, merged = ConflictResolver.resolve_all(book)
    h.assert_equal(seen, 1,   "tilde-style conflict found")
    h.assert_equal(merged, 1, "tilde-style conflict merged")
    h.assert_false(file_exists(tilde_conflict), "tilde conflict removed")
end


-- ── Test 8: unreadable conflict file is removed anyway (no jam) ─────
--
-- A corrupt or unreadable conflict file shouldn't pin itself to disk
-- forever.  We log and proceed.

do
    local book = unique_book_file()
    Paths.set_storage_mode("sdr")
    local main_path = Paths.shared_annotations_path(book)
    local dir = main_path:match("^(.*)/[^/]+$")
    os.execute("mkdir -p '" .. dir .. "' 2>/dev/null")
    JsonStore.write(main_path, {
        schema_version = 1, metadata = {}, render_settings = {}, annotations = {},
    })

    -- Bad conflict file: not valid JSON.
    local main_filename = main_path:match("([^/]+)$")
    local stem = main_filename:match("^(.+)%.json$")
    local bad_conflict = string.format(
        "%s/%s.sync-conflict-20241117-120000-BAD.json", dir, stem)
    local f = io.open(bad_conflict, "wb")
    f:write("this is not json {{{")
    f:close()

    local seen, merged, _err = ConflictResolver.resolve_all(book)
    h.assert_equal(seen, 1,   "saw the bad conflict file")
    h.assert_equal(merged, 0, "didn't merge it (unreadable)")
    h.assert_false(file_exists(bad_conflict),
        "bad conflict file removed anyway, so it doesn't jam future runs")
end


-- ── Test 9: merge_two_states pairwise newer-wins ────────────────────

do
    local A_old = { type = "highlight", pos0 = "/p[1].0", pos1 = "/p[1].10",
                    text = "old", datetime_updated = "2024-01-01 12:00:00" }
    local A_new = { type = "highlight", pos0 = "/p[1].0", pos1 = "/p[1].10",
                    text = "new", datetime_updated = "2024-06-01 12:00:00" }

    local state_a = {
        schema_version = 1, metadata = {}, render_settings = {},
        annotations = { [Identity.compute_key(A_old)] = A_old },
    }
    local state_b = {
        schema_version = 1, metadata = {}, render_settings = {},
        annotations = { [Identity.compute_key(A_new)] = A_new },
    }

    local merged = ConflictResolver.merge_two_states(state_a, state_b)
    local entry = merged.annotations[Identity.compute_key(A_old)]
    h.assert_equal(entry.text, "new", "newer wins in merge_two_states")
end


-- ── Render settings accumulate per-field through the conflict merge ──
-- The conflict resolver uses the SAME centralized RenderSettingsBridge.merge
-- as the orchestrator and cloud, so render fields from two sidecar copies
-- accumulate.  If this path ever reverted to a whole-block merge, only one
-- side's block would survive and this test would fail (divergence guard).
do
    local state_a = {
        schema_version = 1, metadata = {}, annotations = {},
        render_settings = {
            copt_font_size = { value = 24, datetime_updated = "2025-06-02 00:00:00" },
        },
    }
    local state_b = {
        schema_version = 1, metadata = {}, annotations = {},
        render_settings = {
            copt_h_page_margins = { value = 15, datetime_updated = "2025-06-01 00:00:00" },
        },
    }
    local merged = ConflictResolver.merge_two_states(state_a, state_b)
    h.assert_equal(merged.render_settings.copt_font_size.value, 24,
        "conflict merge: render font_size from side A survives (per-field)")
    h.assert_equal(merged.render_settings.copt_h_page_margins.value, 15,
        "conflict merge: render margins from side B survive (per-field accumulation)")
end


-- ── Test: same-kind datetime tie is COMMUTATIVE (device-id tiebreak) ──
--
-- _pick_newer_annotation must return the SAME winner regardless of argument
-- order, so conflict-file resolution converges on every device (the argument
-- order while walking sidecar conflict files is not a stable local-vs-remote).
-- The old `return entry_b` fallback favoured argument order and failed this.

do
    local a = { device_id = "alpha", text = "A", deleted = false,
        datetime_updated = "2024-06-01 09:00:00" }
    local b = { device_id = "bravo", text = "B", deleted = false,
        datetime_updated = "2024-06-01 09:00:00" }

    local ab = ConflictResolver._pick_newer_annotation(a, b)
    local ba = ConflictResolver._pick_newer_annotation(b, a)
    h.assert_equal(ab.device_id, ba.device_id,
        "pick_newer_annotation: same-kind datetime tie is COMMUTATIVE (a,b == b,a)")
    -- Deterministic winner = higher device_id ("bravo" > "alpha").
    h.assert_equal(ab.device_id, "bravo",
        "pick_newer_annotation: tie broken on device_id (higher wins), not argument order")
end


-- ── Test: merged_view -- READ-ONLY union of canonical + conflict copies ──
--
-- The annotation browser reads through merged_view to surface annotations a
-- Syncthing conflict split into a sibling file, WITHOUT resolving (no write,
-- no delete) -- resolution still happens on the next sync via resolve_all.

do
    local book = unique_book_file()
    local main_state = single_ann_state{ text = "main-A",
        pos0 = "/p[1].0", pos1 = "/p[1].10", datetime_updated = "2024-01-01 12:00:00" }
    local conflict_state = single_ann_state{ text = "conflict-B",
        pos0 = "/p[2].0", pos1 = "/p[2].20", datetime_updated = "2024-01-01 12:00:00" }

    local main_path, conflict_paths =
        write_main_and_conflicts(book, main_state, { conflict_state })

    -- Capture the canonical file bytes BEFORE the call (read-only proof).
    local bf = io.open(main_path, "rb")
    local main_bytes_before = bf:read("*a"); bf:close()

    local merged, conflict_n = ConflictResolver.merged_view(main_path)
    h.assert_equal(conflict_n, 1,
        "merged_view returns the count of conflict copies folded in (book-level marker signal)")

    local keyA = Identity.compute_key{ pos0 = "/p[1].0", pos1 = "/p[1].10" }
    local keyB = Identity.compute_key{ pos0 = "/p[2].0", pos1 = "/p[2].20" }
    h.assert_true(merged.annotations[keyA] ~= nil,
        "merged_view surfaces the canonical annotation")
    h.assert_true(merged.annotations[keyB] ~= nil,
        "merged_view folds in the annotation that exists ONLY in the conflict copy")

    -- READ-ONLY guard: conflict file still on disk, canonical bytes unchanged.
    h.assert_true(file_exists(conflict_paths[1]),
        "merged_view is READ-ONLY: conflict file NOT deleted (unlike resolve_all)")
    local af = io.open(main_path, "rb")
    local main_bytes_after = af:read("*a"); af:close()
    h.assert_equal(main_bytes_after, main_bytes_before,
        "merged_view is READ-ONLY: canonical file bytes unchanged on disk")
end


-- ── Test: merged_view -- newer-wins per annotation (mirrors resolve_all) ──

do
    local book = unique_book_file()
    local main_state = single_ann_state{ text = "old version",
        pos0 = "/p[3].0", pos1 = "/p[3].30", datetime_updated = "2024-01-01 12:00:00" }
    local conflict_state = single_ann_state{ text = "new version",
        pos0 = "/p[3].0", pos1 = "/p[3].30", datetime_updated = "2024-06-01 12:00:00" }

    local main_path = write_main_and_conflicts(book, main_state, { conflict_state })
    local merged = ConflictResolver.merged_view(main_path)

    local key = Identity.compute_key{ pos0 = "/p[3].0", pos1 = "/p[3].30" }
    h.assert_equal(merged.annotations[key].text, "new version",
        "merged_view: newer datetime wins per annotation (preview of resolution)")
end


-- ── Test: merged_view -- zero conflicts == plain canonical read; nil-safe ──

do
    local book = unique_book_file()
    local main_state = single_ann_state{ text = "lonely",
        pos0 = "/p[4].0", pos1 = "/p[4].40" }
    local main_path = write_main_and_conflicts(book, main_state, {})

    local merged, conflict_n = ConflictResolver.merged_view(main_path)
    local key = Identity.compute_key{ pos0 = "/p[4].0", pos1 = "/p[4].40" }
    h.assert_true(merged.annotations[key] ~= nil,
        "merged_view with no conflicts returns the canonical annotation (plain read)")
    h.assert_equal(conflict_n, 0, "no conflict copies -> count 0 (no marker)")

    -- nil path -> empty-but-well-formed (never crash for an unscanned book).
    local empty, nil_n = ConflictResolver.merged_view(nil)
    h.assert_true(type(empty.annotations) == "table",
        "merged_view(nil) -> empty-but-well-formed state, annotations is a table")
    h.assert_equal(nil_n, 0, "merged_view(nil) -> count 0")
end


-- ── Test: resolve_all_at_path -- path-based entry (annotation browser's
--    "Resolve conflict" action).  Resolves the EXACT annotations file given,
--    with no book_path derivation -- the property that keeps it correct across
--    metadata modes (the browser hands it the file merged_view read). ──

do
    local book = unique_book_file()

    local A = { type = "highlight", pos0 = "/p[1].0", pos1 = "/p[1].50",
                text = "A", datetime_updated = "2024-01-01 12:00:00" }
    local B = { type = "highlight", pos0 = "/p[2].0", pos1 = "/p[2].50",
                text = "B", datetime_updated = "2024-02-01 12:00:00" }
    local main_state = {
        schema_version = 1,
        annotations = { [Identity.compute_key(A)] = A },
        metadata = {}, render_settings = {},
    }
    local conflict_state = {
        schema_version = 1,
        annotations = { [Identity.compute_key(B)] = B },
        metadata = {}, render_settings = {},
    }

    local main_path, conflict_paths =
        write_main_and_conflicts(book, main_state, { conflict_state })

    -- Call the PATH-based entry directly (what the annotation browser uses),
    -- bypassing book_path derivation entirely.
    local seen, merged, err = ConflictResolver.resolve_all_at_path(main_path)
    h.assert_equal(seen, 1,    "resolve_all_at_path: saw 1 conflict file")
    h.assert_equal(merged, 1,  "resolve_all_at_path: merged 1 conflict file")
    h.assert_nil(err,          "resolve_all_at_path: no error")

    h.assert_false(file_exists(conflict_paths[1]),
        "resolve_all_at_path: conflict file removed after merge")

    local final = JsonStore.read(main_path)
    h.assert_true(final ~= nil, "resolve_all_at_path: main file readable")
    h.assert_true(final.annotations[Identity.compute_key(A)] ~= nil,
        "resolve_all_at_path: annotation A preserved")
    h.assert_true(final.annotations[Identity.compute_key(B)] ~= nil,
        "resolve_all_at_path: annotation B merged in")
end


-- ── Test: resolve_all_at_path(nil) -> zeros, no error (safe no-op) ──

do
    local seen, merged, err = ConflictResolver.resolve_all_at_path(nil)
    h.assert_equal(seen, 0,    "resolve_all_at_path(nil): seen=0")
    h.assert_equal(merged, 0,  "resolve_all_at_path(nil): merged=0")
    h.assert_nil(err,          "resolve_all_at_path(nil): no error")
end
