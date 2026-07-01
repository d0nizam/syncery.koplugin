-- =============================================================================
-- spec/stignore_spec.lua
-- =============================================================================
--
-- Tests for syncery_transports/stignore.lua — the non-invasive `.stignore`
-- writer that replaces the synchronous REST ignore-registration on the
-- startup path (the white-screen lag fix).
--
-- The module touches NO network, so these tests are pure filesystem + pure
-- logic.  `io_open` is injectable, so the unwritable (read-only folder) path
-- is tested deterministically without needing real chmod.
--
-- =============================================================================

local h = require("spec.test_helpers")

local Stignore = require("syncery_transports/stignore")

-- A scratch directory for the file-writing tests.  Unique per run.
local TMP = "/tmp/syncery_stignore_spec_" .. tostring(os.time()) .. "_" .. tostring(math.random(10000))
os.execute("mkdir -p " .. TMP .. " 2>/dev/null")

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local c = f:read("*a")
    f:close()
    return c
end


-- ---------------------------------------------------------------------------
-- GROUP 1: root_for — folder_id → path resolution
-- ---------------------------------------------------------------------------
do
    local folder = { folder_id = "gbp42-o7gzk", path = "/sdcard/Books" }

    h.assert_equal(Stignore.root_for("gbp42-o7gzk", folder), "/sdcard/Books",
        "root_for resolves the folder_id to its path")
    h.assert_nil(Stignore.root_for("does-not-exist", folder),
        "root_for: id mismatch -> nil")

    -- folder_id present but no path -> nil
    h.assert_nil(Stignore.root_for("nopaths-here", { folder_id = "nopaths-here" }),
        "root_for: folder_id present but no path -> nil")

    -- legacy 'id' key still accepted
    h.assert_equal(
        Stignore.root_for("legacy-id-key", { id = "legacy-id-key", path = "/sdcard/Legacy" }),
        "/sdcard/Legacy", "root_for supports the legacy 'id' key")

    h.assert_nil(Stignore.root_for(nil, folder),
        "root_for: nil folder_id -> nil")
    h.assert_nil(Stignore.root_for("", folder),
        "root_for: empty folder_id -> nil")
    h.assert_nil(Stignore.root_for("x", nil),
        "root_for: nil folder -> nil")
    h.assert_nil(Stignore.root_for("x", "not-a-table"),
        "root_for: non-table folder -> nil")
end


-- ---------------------------------------------------------------------------
-- GROUP 1b: the ignore set is EXACTLY the 3 expected literals.  Pins the
-- actual values (not "whatever PATTERNS contains"), so dropping, adding, or
-- altering a pattern is caught here.
-- ---------------------------------------------------------------------------
do
    local want = {
        ["*syncery-*sync-conflict-*"] = true,  -- Syncery's own conflict copies
        ["metadata.*.lua*"]           = true,  -- KOReader main sidecar (+ .old)
        ["custom_metadata.lua*"]      = true,  -- KOReader custom_props (+ .old)
        ["*.annotations.lua*"]        = true,  -- KOReader annotation-sync export (+ .old)
    }
    h.assert_equal(#Stignore.PATTERNS, 4, "exactly 4 ignore patterns")
    for _, p in ipairs(Stignore.PATTERNS) do
        h.assert_true(want[p] == true,
            "PATTERNS contains only expected literals: " .. tostring(p))
        want[p] = nil
    end
    h.assert_true(next(want) == nil, "all 4 expected literals are present")
end


-- ---------------------------------------------------------------------------
-- GROUP 1c: the `.stignore` conflict glob (CONFLICT_PATTERN) stays the LITERAL
-- conflict-copy form and is byte-identical to PATTERNS[1]; the KOSyncthing+
-- scanner glob (CONFLICT_SCANNER_PATTERN) is the de-mangled-ORIGINAL form and is
-- DELIBERATELY different — the v1.1.6+ scanner de-mangles a conflict copy to its
-- original name before matching, so a glob containing `sync-conflict-` could
-- never match there.
-- ---------------------------------------------------------------------------
do
    h.assert_equal(Stignore.CONFLICT_PATTERN, "*syncery-*sync-conflict-*",
        "CONFLICT_PATTERN is the expected literal conflict-copy glob")
    h.assert_equal(Stignore.CONFLICT_PATTERN, Stignore.PATTERNS[1],
        "CONFLICT_PATTERN is the same literal as PATTERNS[1] (the .stignore source)")

    h.assert_equal(Stignore.CONFLICT_SCANNER_PATTERN, "*syncery-*",
        "CONFLICT_SCANNER_PATTERN is the broad de-mangled-original glob")
    h.assert_true(Stignore.CONFLICT_SCANNER_PATTERN ~= Stignore.CONFLICT_PATTERN,
        "scanner glob differs from the .stignore glob (de-mangled vs literal)")
    -- The scanner glob must NOT encode the conflict infix (the scanner strips
    -- it before matching, so such a glob would match nothing).
    h.assert_nil(Stignore.CONFLICT_SCANNER_PATTERN:find("sync%-conflict"),
        "scanner glob does not encode the conflict infix")
end


-- ---------------------------------------------------------------------------
-- GROUP 2: ensure_at_root — write behaviour
-- ---------------------------------------------------------------------------
do
    local d = TMP .. "/g2"
    os.execute("mkdir -p " .. d .. " 2>/dev/null")

    h.assert_equal(Stignore.ensure_at_root(d), "written",
        "ensure_at_root: fresh folder -> written")

    local c = read_file(d .. "/.stignore")
    for _, p in ipairs(Stignore.PATTERNS) do
        h.assert_true(c ~= nil and c:find(p, 1, true) ~= nil,
            "ensure_at_root: pattern present in file: " .. p)
    end
    h.assert_true(c:sub(-1) == "\n",
        "ensure_at_root: file ends with newline")

    h.assert_equal(Stignore.ensure_at_root(d), "already_present",
        "ensure_at_root: second call -> already_present (idempotent)")

    -- A third call must not duplicate any pattern.
    Stignore.ensure_at_root(d)
    c = read_file(d .. "/.stignore")
    for _, p in ipairs(Stignore.PATTERNS) do
        local cnt, idx = 0, 1
        while true do
            local s2 = c:find(p, idx, true)
            if not s2 then break end
            cnt = cnt + 1; idx = s2 + 1
        end
        h.assert_equal(cnt, 1,
            "ensure_at_root: pattern appears exactly once after 3 calls: " .. p)
    end

    h.assert_equal(Stignore.ensure_at_root(nil), "no_path",
        "ensure_at_root: nil root -> no_path")
    h.assert_equal(Stignore.ensure_at_root(""), "no_path",
        "ensure_at_root: empty root -> no_path")
end


-- ---------------------------------------------------------------------------
-- GROUP 2b: migration — an older .stignore with only SOME patterns gains the
-- missing ones (append-only), without duplicating the one already present.
-- ---------------------------------------------------------------------------
do
    local d = TMP .. "/g2b"
    os.execute("mkdir -p " .. d .. " 2>/dev/null")
    -- Seed with ONLY the conflict pattern (the pre-Option-4 state).
    local seed = Stignore.PATTERNS[1]
    local sf = io.open(d .. "/.stignore", "w")
    sf:write(seed .. "\n")
    sf:close()

    h.assert_equal(Stignore.ensure_at_root(d), "written",
        "migration: missing patterns -> written")

    local c = read_file(d .. "/.stignore")
    for _, p in ipairs(Stignore.PATTERNS) do
        h.assert_true(c:find(p, 1, true) ~= nil,
            "migration: pattern present after upgrade: " .. p)
    end
    -- The pre-seeded pattern was NOT duplicated.
    local cnt, idx = 0, 1
    while true do
        local s2 = c:find(seed, idx, true)
        if not s2 then break end
        cnt = cnt + 1; idx = s2 + 1
    end
    h.assert_equal(cnt, 1, "migration: pre-existing pattern not duplicated")

    h.assert_equal(Stignore.ensure_at_root(d), "already_present",
        "migration: second call once complete -> already_present")
end


-- ---------------------------------------------------------------------------
-- GROUP 3: merge-safety — never clobber the user's existing content
-- ---------------------------------------------------------------------------
do
    local d = TMP .. "/g3"
    os.execute("mkdir -p " .. d .. " 2>/dev/null")
    os.execute("printf '#include .stglobalignore\\nmy-notes/\\n*.draft\\n(?d).DS_Store\\n' > "
        .. d .. "/.stignore")

    Stignore.ensure_at_root(d)
    local c = read_file(d .. "/.stignore")

    h.assert_true(c:find("#include .stglobalignore", 1, true) ~= nil,
        "merge-safe: preserves the #include directive")
    h.assert_true(c:find("my%-notes/") ~= nil,
        "merge-safe: preserves user pattern 'my-notes/'")
    h.assert_true(c:find("*.draft", 1, true) ~= nil,
        "merge-safe: preserves user pattern '*.draft'")
    h.assert_true(c:find("%(%?d%)%.DS_Store") ~= nil,
        "merge-safe: preserves '(?d).DS_Store'")
    for _, p in ipairs(Stignore.PATTERNS) do
        h.assert_true(c:find(p, 1, true) ~= nil,
            "merge-safe: our pattern is appended: " .. p)
    end

    -- A file with no trailing newline: our pattern must land on its own line.
    local d2 = TMP .. "/g3b"
    os.execute("mkdir -p " .. d2 .. " 2>/dev/null")
    os.execute("printf 'no-trailing-newline' > " .. d2 .. "/.stignore")
    Stignore.ensure_at_root(d2)
    c = read_file(d2 .. "/.stignore")
    local escaped = Stignore.PATTERNS[1]:gsub("([%*%-%?%(%)%.])", "%%%1")
    h.assert_true(c:find("no%-trailing%-newline\n" .. escaped) ~= nil,
        "merge-safe: first pattern on its own line even without a trailing newline")
end


-- ---------------------------------------------------------------------------
-- GROUP 4: fail-soft — an unwritable folder never crashes
-- ---------------------------------------------------------------------------
do
    -- Inject an io.open that fails on append (read-only mount simulation).
    local fake_io = function(path, mode)
        if mode == "a" then return nil, "EACCES" end
        return io.open(path, mode)
    end
    local d = TMP .. "/g4"
    os.execute("mkdir -p " .. d .. " 2>/dev/null")

    h.assert_equal(Stignore.ensure_at_root(d, fake_io), "unwritable",
        "fail-soft: unwritable append -> 'unwritable' (no crash)")
    h.assert_nil(read_file(d .. "/.stignore"),
        "fail-soft: no file created when unwritable")
end


-- ---------------------------------------------------------------------------
-- GROUP 5: ensure_for_folder — the integration entry point
-- ---------------------------------------------------------------------------
do
    local d = TMP .. "/g5"
    os.execute("mkdir -p " .. d .. " 2>/dev/null")
    local folder = { folder_id = "fid1", path = d }
    local get_folder = function() return folder end

    h.assert_equal(Stignore.ensure_for_folder("fid1", get_folder), "written",
        "ensure_for_folder: writes for a known folder")
    h.assert_equal(Stignore.ensure_for_folder("fid1", get_folder), "already_present",
        "ensure_for_folder: idempotent")
    h.assert_equal(Stignore.ensure_for_folder("nope", get_folder), "no_path",
        "ensure_for_folder: unknown folder_id -> no_path (silent)")
    h.assert_equal(Stignore.ensure_for_folder("fid1", nil), "no_path",
        "ensure_for_folder: nil get_folder -> no_path")

    local get_nopath = function() return { folder_id = "fid2" } end
    h.assert_equal(Stignore.ensure_for_folder("fid2", get_nopath), "no_path",
        "ensure_for_folder: folder without a path -> no_path")
end


-- ---------------------------------------------------------------------------
-- GROUP 6: the whole point — the write never blocks (local file only)
-- ---------------------------------------------------------------------------
do
    local d = TMP .. "/g6"
    os.execute("mkdir -p " .. d .. " 2>/dev/null")
    local folder = { folder_id = "scanfid", path = d }

    local t0 = os.clock()
    local res = Stignore.ensure_for_folder("scanfid", function() return folder end)
    local elapsed = os.clock() - t0

    h.assert_equal(res, "written",
        "non-blocking: the scan-path write actually wrote .stignore")
    h.assert_true(elapsed < 0.5,
        "non-blocking: the write is effectively instant (no network)")
end


-- ---------------------------------------------------------------------------
-- GROUP 7: dead-daemon flow — 3 restarts, ~0s total (the original bug)
-- ---------------------------------------------------------------------------
do
    local d = TMP .. "/g7"
    os.execute("mkdir -p " .. d .. " 2>/dev/null")
    local folder = { folder_id = "deadfid", path = d }

    -- Each "restart" runs startup (now a no-op for network) + a scan write.
    -- The dead daemon never matters: the write is a local file.
    local t0 = os.clock()
    for _ = 1, 3 do
        Stignore.ensure_for_folder("deadfid", function() return folder end)
    end
    local elapsed = os.clock() - t0

    h.assert_true(elapsed < 0.5,
        "dead daemon: 3 restarts cost ~0s (vs 4-10s/restart for the old REST call)")
    h.assert_true(read_file(d .. "/.stignore") ~= nil,
        "dead daemon: suppression is in place (.stignore written offline)")
end


-- ---------------------------------------------------------------------------
-- GROUP 8: REGRESSION GATE — the wiring in main.lua must stay correct
--
-- These read main.lua and assert the two structural invariants of the fix.
-- They fail loudly if anyone reintroduces the synchronous startup REST
-- register (the white-screen lag) or unwires the .stignore write.
-- ---------------------------------------------------------------------------
do
    local function read_main()
        -- spec files run with the plugin root on package.path; main.lua is
        -- at the plugin root.  Find it relative to this spec.
        for _, p in ipairs({ "main.lua", "./main.lua", "../main.lua" }) do
            local f = io.open(p, "r")
            if f then local c = f:read("*a"); f:close(); return c end
        end
        return nil
    end

    local function body_of(src, fn_header)
        -- Extract from `function ... fn_header` up to the next line that is
        -- exactly `end` at column 0 (the function's closing end).
        local start = src:find(fn_header, 1, true)
        if not start then return nil end
        local rest = src:sub(start)
        local body = rest:match("^(.-\n)end\n")
        return body
    end

    local src = read_main()
    h.assert_true(src ~= nil, "regression gate: main.lua is readable")

    if src then
        local setup_body = body_of(src, "function Syncery:_setupKOSyncthingPlusIntegration()")
        h.assert_true(setup_body ~= nil,
            "regression gate: found _setupKOSyncthingPlusIntegration body")
        -- The startup path must NOT call register (that's the lag).
        h.assert_true(
            setup_body == nil
            or setup_body:find("self._transport:register_syncery_ignore_patterns") == nil,
            "regression gate: _setupKOSyncthingPlusIntegration does NOT call register (white-screen lag gone)")

        local scan_body = body_of(src, "function Syncery:_doTriggerScan(state, opts)")
        h.assert_true(scan_body ~= nil,
            "regression gate: found _doTriggerScan body")
        -- The scan path MUST write .stignore (where suppression now happens).
        h.assert_true(
            scan_body ~= nil
            and scan_body:find("Stignore.ensure_for_folder", 1, true) ~= nil,
            "regression gate: _doTriggerScan wires the .stignore write")
    end
end


-- Best-effort cleanup of the scratch directory.
os.execute("rm -rf " .. TMP)
