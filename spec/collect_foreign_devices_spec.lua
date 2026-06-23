-- =============================================================================
-- spec/collect_foreign_devices_spec.lua
-- =============================================================================
--
-- Tests for StateStore.collect_foreign_devices (syncery_progress/state_store.lua)
-- -- the pure helper that, given a per-device entries map and THIS device's id,
-- returns the OTHER devices that hold data (id -> display name), so the
-- migration report can name the user's other devices. No I/O; the entries are
-- whatever scanHash / the finders already loaded.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/collect_foreign_devices_spec_" .. tostring(os.time()))

local StateStore = require("syncery_progress/state_store")
local F = StateStore.collect_foreign_devices

local LOCAL = "dev_local_aaaaaaaa"
local K     = "dev_kindle_bbbbbbbb"
local O     = "dev_kobo_cccccccc"

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Defensive: nil / non-table / empty -> empty set.
do
    h.assert_equal(count(F(nil, LOCAL)), 0, "nil entries -> empty set")
    h.assert_equal(count(F("oops", LOCAL)), 0, "non-table entries -> empty set")
    h.assert_equal(count(F({}, LOCAL)), 0, "empty entries -> empty set")
end

-- Only the local device present -> nothing foreign (local is excluded).
do
    local e = { [LOCAL] = { device_id = LOCAL, label = "MyPhone", file = "/x" } }
    h.assert_equal(count(F(e, LOCAL)), 0, "only the local device -> no foreign devices")
end

-- Local + two foreign -> exactly the two foreign, carrying their labels.
do
    local e = {
        [LOCAL] = { device_id = LOCAL, label = "MyPhone" },
        [K]     = { device_id = K,     label = "KindlePaperWhite6" },
        [O]     = { device_id = O,     label = "Kobo Clara" },
    }
    local out = F(e, LOCAL)
    h.assert_equal(out[LOCAL], nil, "the local device is excluded")
    h.assert_equal(out[K], "KindlePaperWhite6", "foreign Kindle carries its label")
    h.assert_equal(out[O], "Kobo Clara", "foreign Kobo carries its label")
    h.assert_equal(count(out), 2, "exactly the two foreign devices")
end

-- Foreign entry without a usable label -> falls back to the device id, so it
-- stays unique and traceable (two unlabelled devices never collapse).
do
    local e = {
        [LOCAL] = { device_id = LOCAL, label = "MyPhone" },
        [K]     = { device_id = K },               -- no label field
        [O]     = { device_id = O, label = "" },     -- empty label
    }
    local out = F(e, LOCAL)
    h.assert_equal(out[K], K, "missing label falls back to the device id")
    h.assert_equal(out[O], O, "empty label falls back to the device id")
    h.assert_equal(count(out), 2, "both unlabelled foreign devices are present and distinct")
end

-- A non-table entry value is ignored (malformed JSON should not crash or leak).
do
    local e = {
        [LOCAL]  = { label = "MyPhone" },
        [K]      = { device_id = K, label = "Kindle" },
        ["junk"] = "not a table",
    }
    local out = F(e, LOCAL)
    h.assert_equal(out[K], "Kindle", "valid foreign entry kept")
    h.assert_equal(out["junk"], nil, "non-table entry value ignored")
    h.assert_equal(count(out), 1, "only the valid foreign device counts")
end

-- Degenerate but defined: nil local_id excludes nothing.
do
    local e = { [K] = { device_id = K, label = "Kindle" } }
    local out = F(e, nil)
    h.assert_equal(out[K], "Kindle", "with nil local_id, every device is 'foreign'")
    h.assert_equal(count(out), 1, "the one device is returned")
end

h.teardown()
