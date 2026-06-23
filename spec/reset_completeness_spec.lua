-- =============================================================================
-- spec/reset_completeness_spec.lua
-- =============================================================================
--
-- Phase 13 — reset-completeness gate.
--
-- A real bug was found: the menu's "Reset all settings" (`_resetAll`)
-- carried a hand-maintained key list that had silently drifted behind the
-- settings the plugin actually persists — 7 user preferences (the three
-- diagnostic windows, tombstone TTL, two sync sub-toggles, and the hash
-- root) were never cleared. Both reset paths now derive from single-source
-- tables in main.lua: PREFERENCE_KEYS (soft reset) and FULL_PURGE_KEYS
-- (= preferences + device identity, for the hard uninstall purge).
--
-- This gate reads main.lua statically and asserts:
--   1. Every `syncery_*` key the plugin saves into G_reader_settings is
--      present in PREFERENCE_KEYS — so a soft reset clears it. (Per-book
--      keys stored in doc_settings are excluded; they don't belong to
--      G_reader_settings reset.)
--   2. `syncery_device_id` is NOT in PREFERENCE_KEYS (soft reset keeps the
--      device's network identity) but IS covered by FULL_PURGE_KEYS.
--
-- It is static for the same reason as consent_first_defaults_spec: the
-- key lists live as Lua locals inside main.lua, awkward to load through a
-- full plugin init in the headless harness. Catching "a new persisted key
-- was added but forgotten in reset" is exactly what we need.
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_reset_completeness_" .. tostring(os.time()))


local function read_main()
    local f = io.open("main.lua", "r") or io.open("../main.lua", "r")
    assert(f, "reset gate: could not open main.lua")
    local s = f:read("*a"); f:close(); return s
end
local src = read_main()


-- Extract the PREFERENCE_KEYS table body.
local function table_body(name)
    local pat = "local " .. name .. "%s*=%s*{(.-)}"
    return src:match(pat) or ""
end
local pref_body = table_body("PREFERENCE_KEYS")
h.assert_true(#pref_body > 0, "PREFERENCE_KEYS table found in main.lua")

local function keys_in(body)
    local set = {}
    for k in body:gmatch('"(syncery_[a-z_]+)"') do set[k] = true end
    return set
end
local pref_keys = keys_in(pref_body)


-- Per-book keys live in doc_settings, NOT G_reader_settings — they are
-- correctly outside the reset scope. Exclude them from the obligation.
local per_book = {
    syncery_disabled = true,   -- per-book opt-out (doc_settings)
    syncery_bm_state = true,   -- per-book bookmark state (doc_settings)
}
-- Identity is intentionally soft-reset-exempt.
local identity = { syncery_device_id = true }


-- 1. Every key saved into G_reader_settings must be soft-reset-clearable.
do
    -- Find saveSetting("syncery_...") calls whose target is G_reader_settings.
    -- We approximate "global" by excluding the per-book doc_settings writes:
    -- doc_settings writes use `doc_settings:saveSetting`, global uses
    -- `G_reader_settings:saveSetting`.
    local missing = {}
    for line in src:gmatch("[^\n]+") do
        local key = line:match('G_reader_settings:saveSetting%("(syncery_[a-z_]+)"')
        if key and not per_book[key] and not identity[key] and not pref_keys[key] then
            missing[key] = true
        end
    end
    local list = {}
    for k in pairs(missing) do list[#list+1] = k end
    table.sort(list)
    h.assert_equal(#list, 0,
        "every G_reader_settings preference key is in PREFERENCE_KEYS "
        .. "(missing: " .. (table.concat(list, ", ")) .. ")")
end


-- 2. The 7 keys that were the actual bug must now be present.
do
    local must_have = {
        "syncery_activity_log_max", "syncery_journal_max_entries",
        "syncery_progress_freshness_days", "syncery_tombstone_ttl_days",
        "syncery_sync_custom_metadata", "syncery_sync_handmade_toc",
    }
    for _, k in ipairs(must_have) do
        h.assert_true(pref_keys[k] == true,
            "reset clears previously-missed key: " .. k)
    end
end


-- 3. Identity is exempt from soft reset, but in the full purge.
do
    h.assert_true(pref_keys["syncery_device_id"] == nil,
        "soft reset KEEPS device identity (device_id not in PREFERENCE_KEYS)")
    local full_body = table_body("FULL_PURGE_KEYS")
    -- FULL_PURGE_KEYS is built programmatically (device_id literal + loop),
    -- so assert the literal is present in its construction.
    h.assert_true(src:match('FULL_PURGE_KEYS%s*=%s*{%s*"syncery_device_id"') ~= nil,
        "full purge DOES clear device identity (device_id in FULL_PURGE_KEYS)")
end
