-- =============================================================================
-- spec/get_device_id_spec.lua
-- =============================================================================
--
-- Tests for Util.get_device_id — Syncery's device identity.
--
-- Syncery reuses KOReader's own `device_id` (a stable random UUID generated
-- once at startup in reader.lua and already used to stamp native annotations).
-- get_device_id must therefore PREFER KOReader's `device_id`, fall back to a
-- self-generated `syncery_device_id` only when KOReader's is absent (e.g. a
-- bare test harness with no reader.lua), and generate + persist one when
-- neither exists.
--
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_get_device_id_spec_" .. tostring(os.time()))

local Util = require("syncery_util")

local _saved_grs = _G.G_reader_settings

-- A controllable G_reader_settings stub backed by a plain table.
local function fresh_grs(initial)
    local store = {}
    for k, v in pairs(initial or {}) do store[k] = v end
    return {
        readSetting = function(_, k) return store[k] end,
        saveSetting = function(_, k, v) store[k] = v end,
        _store = store,
    }
end


-- ----------------------------------------------------------------------------
-- 1. Prefers KOReader's device_id over a (legacy) syncery_device_id
-- ----------------------------------------------------------------------------
do
    _G.G_reader_settings = fresh_grs({
        device_id          = "KOR_UUID_ABC123",
        syncery_device_id  = "dev_legacy_999",
    })
    h.assert_equal(Util.get_device_id(), "KOR_UUID_ABC123",
        "prefers KOReader's device_id over a present syncery_device_id")
end


-- ----------------------------------------------------------------------------
-- 2. Falls back to syncery_device_id when KOReader's device_id is absent
-- ----------------------------------------------------------------------------
do
    _G.G_reader_settings = fresh_grs({ syncery_device_id = "dev_fallback_1" })
    h.assert_equal(Util.get_device_id(), "dev_fallback_1",
        "falls back to syncery_device_id when device_id is absent")
end


-- ----------------------------------------------------------------------------
-- 3. Treats an empty-string device_id as absent (not a valid identity)
-- ----------------------------------------------------------------------------
do
    _G.G_reader_settings = fresh_grs({
        device_id         = "",
        syncery_device_id = "dev_fallback_2",
    })
    h.assert_equal(Util.get_device_id(), "dev_fallback_2",
        "treats an empty device_id as absent and falls back")
end


-- ----------------------------------------------------------------------------
-- 4. Generates and persists a syncery_device_id when neither is present
-- ----------------------------------------------------------------------------
do
    local grs = fresh_grs({})
    _G.G_reader_settings = grs
    local id = Util.get_device_id()
    h.assert_true(id ~= nil and id ~= "",
        "generates a non-empty id when neither device_id nor syncery_device_id exists")
    h.assert_true(id:match("^dev_") ~= nil,
        "the generated fallback id uses the dev_ prefix")
    h.assert_equal(grs._store.syncery_device_id, id,
        "persists the generated id to syncery_device_id")
    -- Stable within the same settings: a second call returns the same id.
    h.assert_equal(Util.get_device_id(), id,
        "a second call returns the same persisted fallback id")
end


_G.G_reader_settings = _saved_grs   -- restore (do not leak across specs)

h.report("get_device_id_spec")
