-- =============================================================================
-- spec/progress_conflict_resolver_spec.lua
-- =============================================================================
--
-- Tests for syncery_progress/conflict_resolver.lua directly.
--
-- The orchestrator spec already exercises the end-to-end "resolve_all
-- folds a conflict file into the main file" flow, but a few surfaces
-- aren't reachable through there:
--
--   * `merge_two_states` as a pure function (no I/O at all).
--   * `find_conflict_files` pattern-matching, including the `~`
--     separator variant some Syncthing setups produce.
--   * Edge cases: malformed conflict file, empty states, dominant
--     device attribution on tie.
--
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_progress_conflict_spec_" .. tostring(os.time()))

local ConflictResolver = require("syncery_progress/conflict_resolver")
local Paths            = require("syncery_progress/paths")
local JsonStore        = require("syncery_ann/json_store")


-- ----------------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------------


local counter = 0
local function unique_book_file()
    counter = counter + 1
    local p = h.test_root .. "/cr_book_" .. tostring(counter) .. ".epub"
    local f = io.open(p, "wb")
    if f then f:write(""); f:close() end
    return p
end


-- Make sure we're in SDR mode so conflict files live in the sidecar
-- (where find_conflict_files can iterate them).
Paths.set_storage_mode("sdr")


-- ----------------------------------------------------------------------------
-- merge_two_states: empty + empty = empty
-- ----------------------------------------------------------------------------


do
    local merged = ConflictResolver.merge_two_states(nil, nil)
    h.assert_deep_equal(merged.entries, {}, "nil + nil -> empty entries")
    h.assert_equal(merged.schema_version, 1, "schema_version normalized to 1")
end


-- ----------------------------------------------------------------------------
-- merge_two_states: one side empty, the other survives
-- ----------------------------------------------------------------------------


do
    local state_a = {
        schema_version = 1,
        device_id = "PHONE", device_label = "Phone",
        entries = {
            PHONE = { revision = 3, percent = 0.3, timestamp = 100 },
        },
    }
    local merged = ConflictResolver.merge_two_states(state_a, {})
    h.assert_equal(merged.entries.PHONE.revision, 3,
        "non-empty side preserved")
    h.assert_nil(merged.device_id,
        "merged file is device-agnostic (no top-level writer stamp)")
end


-- ----------------------------------------------------------------------------
-- merge_two_states: per-key newer wins (revision then timestamp)
-- ----------------------------------------------------------------------------


do
    local state_a = {
        schema_version = 1,
        entries = {
            PHONE = { revision = 5, percent = 0.50, timestamp = 100 },
            TABLET = { revision = 1, percent = 0.10, timestamp = 50 },
        },
    }
    local state_b = {
        schema_version = 1,
        entries = {
            PHONE = { revision = 3, percent = 0.30, timestamp = 200 },  -- older rev
            TABLET = { revision = 4, percent = 0.40, timestamp = 80 },  -- newer rev
            EREADER = { revision = 1, percent = 0.05, timestamp = 60 }, -- only on b
        },
    }
    local merged = ConflictResolver.merge_two_states(state_a, state_b)

    h.assert_equal(merged.entries.PHONE.revision, 5,
        "PHONE: state_a wins on higher rev")
    h.assert_equal(merged.entries.TABLET.revision, 4,
        "TABLET: state_b wins on higher rev")
    h.assert_equal(merged.entries.EREADER.revision, 1,
        "EREADER: b-only, adopted")

    local count = 0
    for _ in pairs(merged.entries) do count = count + 1 end
    h.assert_equal(count, 3, "three devices in merged state")
end


-- ----------------------------------------------------------------------------
-- merge_two_states: equal revision, timestamp tie-break
-- ----------------------------------------------------------------------------


do
    local state_a = { entries = {
        PHONE = { revision = 5, percent = 0.50, timestamp = 100 },
    } }
    local state_b = { entries = {
        PHONE = { revision = 5, percent = 0.55, timestamp = 200 },  -- newer ts
    } }
    local merged = ConflictResolver.merge_two_states(state_a, state_b)
    h.assert_equal(merged.entries.PHONE.percent, 0.55,
        "newer timestamp wins at equal revision")
end


-- ----------------------------------------------------------------------------
-- merge_two_states: true tie picks state_b (deterministic fallback)
-- ----------------------------------------------------------------------------


do
    local same  = { revision = 5, percent = 0.5, timestamp = 100 }
    local entry_a = { revision = 5, percent = 0.5, timestamp = 100, marker = "a" }
    local entry_b = { revision = 5, percent = 0.5, timestamp = 100, marker = "b" }

    local merged = ConflictResolver.merge_two_states(
        { entries = { PHONE = entry_a } },
        { entries = { PHONE = entry_b } })
    h.assert_equal(merged.entries.PHONE.marker, "b",
        "deterministic fallback picks state_b (incoming side)")
end


-- ----------------------------------------------------------------------------
-- merge_two_states: dominant device attribution prefers side with newest entry
-- ----------------------------------------------------------------------------


do
    local state_a = {
        device_id = "ALPHA", device_label = "Alpha",
        entries = {
            ALPHA = { revision = 3, percent = 0.30, timestamp = 100 },
        },
    }
    local state_b = {
        device_id = "BETA", device_label = "Beta",
        entries = {
            BETA = { revision = 5, percent = 0.50, timestamp = 200 },  -- newer
        },
    }
    local merged = ConflictResolver.merge_two_states(state_a, state_b)
    h.assert_nil(merged.device_id,
        "merged file is device-agnostic (entries merge regardless of writer)")
    h.assert_nil(merged.device_label,
        "no top-level device_label written")
end


-- ----------------------------------------------------------------------------
-- merge_two_states expects already-normalized input (does not normalize itself)
-- ----------------------------------------------------------------------------


do
    -- Both halves are already in the normalized wrapper shape.
    -- merge_two_states does NOT normalize internally — that's the
    -- caller's job (the orchestrator routes loads through `normalize`
    -- before calling).  This test documents that contract.
    local state_a = { schema_version = 1, entries = {} }
    local state_b = { schema_version = 1, entries = {
        BETA = { revision = 2, percent = 0.20, timestamp = 100 },
    } }
    local merged = ConflictResolver.merge_two_states(state_a, state_b)
    h.assert_equal(merged.entries.BETA.revision, 2, "BETA preserved")
end


-- ----------------------------------------------------------------------------
-- find_conflict_files: matches `.sync-conflict-` pattern (period variant)
-- ----------------------------------------------------------------------------


do
    local book = unique_book_file()
    local main_path = Paths.shared_progress_path(book)

    -- We need the directory to exist; touch the main file so the
    -- directory is created.  (lfs.dir iterates the sidecar dir.)
    JsonStore.write(main_path, { schema_version = 1, entries = {} })

    local sidecar_dir = main_path:match("^(.*)/[^/]+$")

    -- Plant two conflict files (with period and tilde separators)
    -- plus one decoy file that should NOT be picked up.
    local stem = main_path:match("([^/]+)%.json$")
    local conflict_dot = sidecar_dir .. "/" .. stem
        .. ".sync-conflict-20251101-120000-AAA.json"
    local conflict_tilde = sidecar_dir .. "/" .. stem
        .. "~sync-conflict-20251101-120001-BBB.json"
    local decoy = sidecar_dir .. "/" .. stem .. ".backup.json"

    for _, p in ipairs({ conflict_dot, conflict_tilde, decoy }) do
        local f = io.open(p, "wb"); if f then f:write("{}"); f:close() end
    end

    local found = ConflictResolver.find_conflict_files(book)
    h.assert_equal(#found, 2,
        "find_conflict_files returns both conflict files (period and tilde variants)")

    -- Both period AND tilde matched.
    local seen_dot, seen_tilde = false, false
    for _, p in ipairs(found) do
        if p == conflict_dot   then seen_dot = true end
        if p == conflict_tilde then seen_tilde = true end
    end
    h.assert_true(seen_dot,   "period-form conflict file matched")
    h.assert_true(seen_tilde, "tilde-form conflict file matched")
end


-- ----------------------------------------------------------------------------
-- find_conflict_files: empty book returns empty list
-- ----------------------------------------------------------------------------


do
    -- Use a non-existent book path; lfs.dir will fail safely.
    local found = ConflictResolver.find_conflict_files(
        "/this/path/does/not/exist/at/all.epub")
    h.assert_equal(#found, 0,
        "non-existent dir returns empty list (no crash)")
end


-- ----------------------------------------------------------------------------
-- resolve_all: malformed conflict file is skipped, others still merge
-- ----------------------------------------------------------------------------


do
    local book = unique_book_file()
    local main_path = Paths.shared_progress_path(book)

    -- Plant a valid main file.
    JsonStore.write(main_path, {
        schema_version = 1,
        entries = {
            PHONE = { revision = 1, percent = 0.10, timestamp = 100,
                      device_id = "PHONE" },
        },
    })

    local sidecar_dir = main_path:match("^(.*)/[^/]+$")
    local stem = main_path:match("([^/]+)%.json$")

    -- One valid conflict file.
    local good_conflict = sidecar_dir .. "/" .. stem
        .. ".sync-conflict-20251101-120000-GOO.json"
    JsonStore.write(good_conflict, {
        schema_version = 1,
        entries = {
            TABLET = { revision = 3, percent = 0.30, timestamp = 200,
                       device_id = "TABLET" },
        },
    })

    -- One malformed conflict file (not valid JSON).
    local bad_conflict = sidecar_dir .. "/" .. stem
        .. ".sync-conflict-20251101-120001-BAD.json"
    local f = io.open(bad_conflict, "wb")
    if f then f:write("this isn't JSON {{{{ ###"); f:close() end

    local n_seen, n_merged, err =
        ConflictResolver.resolve_all(book)

    h.assert_equal(n_seen, 2, "saw both conflict files")
    h.assert_equal(n_merged, 1, "merged only the good one")
    h.assert_nil(err, "no error returned overall")

    -- Both conflict files should be gone after a successful main save.
    h.assert_nil(io.open(good_conflict, "rb"),
        "good conflict file deleted after merge")
    h.assert_nil(io.open(bad_conflict, "rb"),
        "bad conflict file ALSO deleted (otherwise it'd hang around forever)")

    -- The merged main file should have both entries.
    local loaded, _ = JsonStore.read(main_path)
    h.assert_true(loaded.entries.PHONE  ~= nil, "PHONE preserved")
    h.assert_true(loaded.entries.TABLET ~= nil, "TABLET adopted from conflict")
end


-- ----------------------------------------------------------------------------
-- resolve_all: no conflict files = no-op (zero returns, no errors)
-- ----------------------------------------------------------------------------


do
    local book = unique_book_file()
    local main_path = Paths.shared_progress_path(book)
    JsonStore.write(main_path, { schema_version = 1, entries = {} })

    local n_seen, n_merged, err = ConflictResolver.resolve_all(book)
    h.assert_equal(n_seen, 0, "no conflicts seen")
    h.assert_equal(n_merged, 0, "no conflicts merged")
    h.assert_nil(err, "no error on a clean book")
end


-- ----------------------------------------------------------------------------
-- merged_view: zero conflicts returns the normalized canonical state (count 0).
-- This is the cloud-always / common case -- identical to a plain load.
-- ----------------------------------------------------------------------------


do
    local book = unique_book_file()
    local main_path = Paths.shared_progress_path(book)
    JsonStore.write(main_path, {
        schema_version = 1,
        entries = { ["phone"] = { percent = 0.30, revision = 1, timestamp = 1000, label = "Phone" } },
    })

    local merged, n = ConflictResolver.merged_view(main_path)
    h.assert_equal(n, 0, "merged_view: zero conflict files -> count 0")
    h.assert_true(merged.entries["phone"] ~= nil, "canonical entry present")
    if merged.entries["phone"] then
        h.assert_equal(merged.entries["phone"].percent, 0.30,
            "zero-conflict merged_view == the canonical state")
    end
end


-- ----------------------------------------------------------------------------
-- merged_view: a NEWER position in a Syncthing conflict copy wins, folded
-- READ-ONLY (the copy is neither modified nor deleted).
-- ----------------------------------------------------------------------------


do
    local book = unique_book_file()
    local main_path = Paths.shared_progress_path(book)
    JsonStore.write(main_path, {
        schema_version = 1,
        entries = { ["phone"] = { percent = 0.30, revision = 1, timestamp = 1000, label = "Phone" } },
    })

    local sidecar_dir = main_path:match("^(.*)/[^/]+$")
    local stem = main_path:match("([^/]+)%.json$")
    local conflict_path = sidecar_dir .. "/" .. stem
        .. ".sync-conflict-20251101-120000-PHN.json"
    JsonStore.write(conflict_path, {
        schema_version = 1,
        entries = { ["phone"] = { percent = 0.70, revision = 2, timestamp = 2000, label = "Phone" } },
    })

    local function read_bytes(p)
        local f = io.open(p, "rb"); if not f then return nil end
        local b = f:read("*a"); f:close(); return b
    end
    local main_before     = read_bytes(main_path)
    local conflict_before = read_bytes(conflict_path)

    local merged, n = ConflictResolver.merged_view(main_path)
    h.assert_equal(n, 1, "merged_view: one conflict copy -> count 1")
    h.assert_true(merged.entries["phone"] ~= nil, "device entry present after fold")
    if merged.entries["phone"] then
        h.assert_equal(merged.entries["phone"].percent, 0.70,
            "the NEWER position (rev 2 / ts 2000) from the conflict copy wins")
    end

    -- READ-ONLY: neither file changed, neither deleted (unlike resolve_all).
    h.assert_true(read_bytes(main_path) ~= nil, "canonical file still exists")
    h.assert_true(read_bytes(conflict_path) ~= nil, "conflict copy NOT deleted (read-only)")
    h.assert_equal(read_bytes(main_path), main_before,
        "merged_view does NOT modify the canonical file")
    h.assert_equal(read_bytes(conflict_path), conflict_before,
        "merged_view does NOT modify the conflict copy")
end


-- ----------------------------------------------------------------------------
-- merged_view: nil path -> empty-but-well-formed state, count 0.
-- ----------------------------------------------------------------------------


do
    local merged, n = ConflictResolver.merged_view(nil)
    h.assert_equal(n, 0, "nil path -> count 0")
    h.assert_true(type(merged.entries) == "table" and next(merged.entries) == nil,
        "nil path -> empty entries map")
end


-- ----------------------------------------------------------------------------
-- resolve_all_at_path: DESTRUCTIVE path-based resolve (the WRITE twin of
-- merged_view) -- merges conflict copies into the canonical AND deletes them.
-- This is the path the Progress Browser's [Resolve conflict] button uses.
-- ----------------------------------------------------------------------------


do
    local function exists(p)
        local f = io.open(p, "rb"); if f then f:close(); return true end
        return false
    end

    local book = unique_book_file()
    local main_path = Paths.shared_progress_path(book)
    JsonStore.write(main_path, {
        schema_version = 1,
        entries = { ["phone"] = { percent = 0.30, revision = 1, timestamp = 1000, label = "Phone" } },
    })

    local sidecar_dir = main_path:match("^(.*)/[^/]+$")
    local stem = main_path:match("([^/]+)%.json$")
    local conflict_path = sidecar_dir .. "/" .. stem
        .. ".sync-conflict-20251101-120000-PHN.json"
    JsonStore.write(conflict_path, {
        schema_version = 1,
        entries = { ["phone"] = { percent = 0.70, revision = 2, timestamp = 2000, label = "Phone" } },
    })

    local n_seen, n_merged, err = ConflictResolver.resolve_all_at_path(main_path)
    h.assert_equal(n_seen, 1, "resolve_all_at_path: one conflict seen")
    h.assert_equal(n_merged, 1, "resolve_all_at_path: one conflict merged")
    h.assert_nil(err, "resolve_all_at_path: no error")

    -- The canonical file now holds the merged (newest) position...
    local after = JsonStore.read(main_path)
    h.assert_true(after ~= nil and after.entries and after.entries["phone"] ~= nil,
        "canonical still present after resolve")
    if after and after.entries and after.entries["phone"] then
        h.assert_equal(after.entries["phone"].percent, 0.70,
            "resolve_all_at_path folds the newer position into the canonical")
    end

    -- ...and the conflict copy is DELETED (the destructive difference vs merged_view).
    h.assert_true(not exists(conflict_path),
        "resolve_all_at_path deletes the conflict copy after a successful save")
end


-- ----------------------------------------------------------------------------
-- resolve_all_at_path: no conflicts -> no-op; nil -> no_main_path.
-- ----------------------------------------------------------------------------


do
    local book = unique_book_file()
    local main_path = Paths.shared_progress_path(book)
    JsonStore.write(main_path, { schema_version = 1, entries = {} })
    local n_seen, _, err = ConflictResolver.resolve_all_at_path(main_path)
    h.assert_equal(n_seen, 0, "resolve_all_at_path: no conflicts -> 0 seen")
    h.assert_nil(err, "resolve_all_at_path: no conflicts -> no error")

    local s2, _, e2 = ConflictResolver.resolve_all_at_path(nil)
    h.assert_equal(s2, 0, "resolve_all_at_path(nil) -> 0 seen")
    h.assert_equal(e2, "no_main_path", "resolve_all_at_path(nil) -> no_main_path")
end
