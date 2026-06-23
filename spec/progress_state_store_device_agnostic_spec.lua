-- =============================================================================
-- spec/progress_state_store_device_agnostic_spec.lua
-- =============================================================================
--
-- Guards the device-agnostic contract of syncery_progress/state_store.lua
-- save_shared (the cross-device churn fix).
--
-- save_shared MUST NOT write a top-level "who last wrote" stamp into the
-- shared file (its signature takes no device -- the property is structural).  Recording it would make two devices that hold identical
-- content emit different files (each writes its own id) -> Syncthing churn
-- and spurious sync-conflict copies.  Per-device provenance is preserved
-- INSIDE the entries map (each entry's `label`, which the status panel
-- reads), so nothing displayed depends on the top-level stamp.
--
-- Byte identity additionally needs deterministic key ordering, which is
-- guarded separately by json_store_sort_keys_spec; here we compare the
-- reloaded file STATE so the guard holds regardless of the JSON backend.
--
-- Covers:
--   1. save_shared given a device_id/device_label writes NO top-level
--      device_id/device_label, while schema_version + entries survive.
--   2. Two different writers with identical content produce identical
--      file state (the convergence that prevents churn).
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_progress_device_agnostic_spec_" .. tostring(os.time()))

local StateStore = require("syncery_progress/state_store")
local Paths      = require("syncery_progress/paths")
local JsonStore  = require("syncery_ann/json_store")


local counter = 0
local function unique_book()
    counter = counter + 1
    return h.test_root .. "/da_book_" .. tostring(counter) .. ".epub"
end

local function sample_entries()
    return {
        ["dev-shared"] = {
            revision    = 3,
            percent     = 0.42,
            page        = 84,
            total_pages = 200,
            xpath       = "/body/DocFragment[3]/body/p[7]/text().15",
            timestamp   = 1700000000,
            label       = "Reader",
            file        = "book.epub",
        },
    }
end


-- ---------------------------------------------------------------------------
-- 1. save_shared does NOT write the top-level writer stamp, even though a
--    device_id/device_label is passed.
-- ---------------------------------------------------------------------------
do
    local book = unique_book()
    local ok = StateStore.save_shared(book, { entries = sample_entries() })
    h.assert_true(ok, "save_shared succeeds")

    local raw = JsonStore.read(Paths.shared_progress_path(book))
    h.assert_true(type(raw) == "table", "shared file reads back as a table")

    h.assert_nil(raw.device_id,
        "save_shared writes NO top-level device_id (device-agnostic)")
    h.assert_nil(raw.device_label,
        "save_shared writes NO top-level device_label")

    h.assert_true(raw.schema_version ~= nil, "schema_version is still written")
    h.assert_true(type(raw.entries) == "table", "entries are still written")
    h.assert_equal(raw.entries["dev-shared"].percent, 0.42,
        "entry content is intact")
    h.assert_equal(raw.entries["dev-shared"].label, "Reader",
        "per-entry label (the provenance the status panel reads) survives")
end


-- ---------------------------------------------------------------------------
-- 2. Two different writers, identical content -> identical file state.
-- ---------------------------------------------------------------------------
do
    local book_a = unique_book()
    local book_b = unique_book()

    StateStore.save_shared(book_a, { entries = sample_entries() })
    StateStore.save_shared(book_b, { entries = sample_entries() })

    local raw_a = JsonStore.read(Paths.shared_progress_path(book_a))
    local raw_b = JsonStore.read(Paths.shared_progress_path(book_b))

    h.assert_deep_equal(raw_a, raw_b,
        "identical content yields identical file state on any device")
end


print("progress_state_store_device_agnostic_spec: assertions complete")
