-- =============================================================================
-- spec/cloud_adapter_internals_spec.lua
-- =============================================================================
--
-- Direct tests for the internal helpers behind the cloud merge callbacks
-- (exposed under Adapter._ for testability). Two edge-closing concerns from
-- PROJECT_PLAN.md 18.9.2 review:
--
--  (1) EMPTY-SECTION JSON ROUND-TRIP, version-INDEPENDENT. The merge
--      callbacks reassemble envelopes/states with empty map sections
--      (annotations={}, metadata={}, render_settings={}, entries={}). If any
--      JSON backend serialises an empty Lua table as a LIST ([]) instead of an
--      OBJECT ({}), the shape validators reject it and a real device would
--      abort. We assert the round-trip through JsonStore (write->read) keeps
--      each empty section a map that the validators accept — so a bad backend
--      fails THIS test instead of shipping the bug to a device. (This is the
--      proof, not a version check: it runs against whatever backend the
--      harness loaded.)
--
--  (2) classify_income is now a SHARED helper (one fn serving both callbacks
--      via injected validator + empty-builder). A regression in it breaks both
--      at once, so it gets DIRECT coverage of the parameterisation, not only
--      indirect coverage through the two callbacks.
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_cloud_internals_spec_" .. tostring(os.time()))

local Adapter   = require("syncery_transports/cloud/sync_service_adapter")
local JsonStore = require("syncery_ann/json_store")

local DIR = h.test_root .. "/it"
os.execute("mkdir -p '" .. DIR .. "' 2>/dev/null")

local _n = 0
local function tmp()
    _n = _n + 1
    return DIR .. "/f" .. _n .. ".json"
end
local function write_raw(path, bytes)
    local f = assert(io.open(path, "wb")); f:write(bytes); f:close()
end


-- ----------------------------------------------------------------------------
-- (1) Empty-section round-trip — ANNOTATION envelope.
--     After write->read, every empty section must still be a table the
--     envelope validator accepts.
-- ----------------------------------------------------------------------------
do
    local p = tmp()
    local env = Adapter._empty_envelope()       -- {annotations={},metadata={},render_settings={}}
    assert(JsonStore.write(p, env), "write empty envelope")
    local back, diag = JsonStore.read(p)
    h.assert_equal(diag, "ok", "empty envelope re-read ok")
    h.assert_equal(type(back.annotations), "table",     "annotations stays a table (not list)")
    h.assert_equal(type(back.metadata), "table",        "metadata stays a table")
    h.assert_equal(type(back.render_settings), "table", "render_settings stays a table")
    h.assert_true(Adapter._is_valid_envelope(back),
        "round-tripped empty envelope still passes the validator")

    -- Double round-trip: a backend might only degrade {} -> [] on the SECOND
    -- pass (re-encoding a freshly-decoded empty container).
    assert(JsonStore.write(p, back), "second write")
    local back2 = JsonStore.read(p)
    h.assert_true(Adapter._is_valid_envelope(back2),
        "envelope still valid after double round-trip")
end


-- ----------------------------------------------------------------------------
-- (1) Empty-section round-trip — PROGRESS state (entries={}).
-- ----------------------------------------------------------------------------
do
    local p = tmp()
    local st = Adapter._empty_progress_state()  -- { schema_version, entries={} }
    assert(JsonStore.write(p, st), "write empty progress state")
    local back, diag = JsonStore.read(p)
    h.assert_equal(diag, "ok", "empty progress state re-read ok")
    h.assert_equal(type(back.entries), "table", "entries stays a table (not list)")
    h.assert_true(Adapter._is_valid_progress_state(back),
        "round-tripped empty progress state still passes the validator")

    assert(JsonStore.write(p, back), "second write")
    local back2 = JsonStore.read(p)
    h.assert_true(Adapter._is_valid_progress_state(back2),
        "progress state still valid after double round-trip")
end


-- ----------------------------------------------------------------------------
-- (1b) A merged envelope that ENDS UP with empty sections (e.g. nothing on
--      either side) must also round-trip valid — closes the path where the
--      merge itself produces {} sections.
-- ----------------------------------------------------------------------------
do
    local p = tmp()
    local merged = {
        schema_version  = 1,
        annotations     = {},   -- both sides empty
        metadata        = {},
        render_settings = {},
    }
    assert(JsonStore.write(p, merged))
    local back = JsonStore.read(p)
    h.assert_true(Adapter._is_valid_envelope(back),
        "all-empty merged envelope round-trips valid (validator would catch a [] degrade)")
end


-- ----------------------------------------------------------------------------
-- (2) classify_income parameterisation — ANNOTATION shape.
-- ----------------------------------------------------------------------------
do
    local isv, mkempty = Adapter._is_valid_envelope, Adapter._empty_envelope

    -- valid envelope -> returned as-is
    local p1 = tmp()
    JsonStore.write(p1, { schema_version = 1, annotations = { ["k"] = { text = "x" } } })
    local r1 = Adapter._classify_income(p1, JsonStore, isv, mkempty)
    h.assert_true(r1 ~= Adapter._INCOME_ABORT and r1.annotations.k ~= nil,
        "classify: valid envelope returned as-is")

    -- missing file -> empty (clean first sync)
    local r2 = Adapter._classify_income(DIR .. "/does_not_exist.json", JsonStore, isv, mkempty)
    h.assert_true(r2 ~= Adapter._INCOME_ABORT and type(r2.annotations) == "table",
        "classify: missing -> empty envelope")

    -- 404-ish unparseable body -> empty
    local p3 = tmp(); write_raw(p3, "<html>404 Not Found</html>")
    local r3 = Adapter._classify_income(p3, JsonStore, isv, mkempty)
    h.assert_true(r3 ~= Adapter._INCOME_ABORT, "classify: 404 body -> empty (not abort)")

    -- corrupt non-404 body -> ABORT
    local p4 = tmp(); write_raw(p4, "\x00\x01 garbage \xff")
    local r4 = Adapter._classify_income(p4, JsonStore, isv, mkempty)
    h.assert_equal(r4, Adapter._INCOME_ABORT, "classify: corrupt non-404 -> INCOME_ABORT")

    -- valid JSON, wrong shape -> ABORT (validator rejects)
    local p5 = tmp(); write_raw(p5, '{"annotations":"not-a-table"}')
    local r5 = Adapter._classify_income(p5, JsonStore, isv, mkempty)
    h.assert_equal(r5, Adapter._INCOME_ABORT, "classify: valid-JSON wrong-shape -> INCOME_ABORT")
end


-- ----------------------------------------------------------------------------
-- (2) classify_income parameterisation — PROGRESS shape (different validator
--     + empty-builder through the SAME helper).
-- ----------------------------------------------------------------------------
do
    local isv, mkempty = Adapter._is_valid_progress_state, Adapter._empty_progress_state

    -- valid progress state -> as-is
    local p1 = tmp()
    JsonStore.write(p1, { schema_version = 1, entries = { dev = { revision = 1 } } })
    local r1 = Adapter._classify_income(p1, JsonStore, isv, mkempty)
    h.assert_true(r1 ~= Adapter._INCOME_ABORT and r1.entries.dev ~= nil,
        "classify(progress): valid state returned as-is")

    -- wrong shape (entries not a table) -> ABORT
    local p2 = tmp(); write_raw(p2, '{"entries":42}')
    local r2 = Adapter._classify_income(p2, JsonStore, isv, mkempty)
    h.assert_equal(r2, Adapter._INCOME_ABORT, "classify(progress): wrong-shape -> INCOME_ABORT")

    -- empty file -> empty progress state, with entries map present
    local p3 = tmp(); write_raw(p3, "")
    local r3 = Adapter._classify_income(p3, JsonStore, isv, mkempty)
    h.assert_true(r3 ~= Adapter._INCOME_ABORT and type(r3.entries) == "table",
        "classify(progress): empty -> empty state")

    -- The SAME helper returns the builder appropriate to EACH subsystem:
    -- progress empties have `entries`, envelope empties have `annotations`.
    h.assert_true(r3.entries ~= nil and r3.annotations == nil,
        "classify(progress): empty builder is the progress one (entries, not annotations)")
end
