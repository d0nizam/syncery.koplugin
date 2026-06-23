-- =============================================================================
-- spec/annotation_state_store_device_agnostic_spec.lua
-- =============================================================================
--
-- Guards the device-agnostic contract of syncery_ann/state_store.lua
-- save_shared (the cross-device churn fix, Fix 2).
--
-- save_shared MUST NOT write a top-level "who last wrote" stamp into the
-- shared file (its signature takes no device -- the property is structural).  Recording it would make two devices that hold identical
-- content emit different files -> Syncthing churn + spurious sync-conflict
-- copies.  Provenance is preserved elsewhere: per-annotation `device_id`
-- (winner-based, survives the merge) and the device-local sync journal
-- (which now sources the writer from the LIVE device, not this file --
-- see sync_journal.record_merge + sync_journal_spec).
--
-- Byte identity additionally needs deterministic key ordering, which is
-- guarded separately by json_store_sort_keys_spec; here we compare the
-- reloaded file STATE so the guard holds regardless of the JSON backend.
--
-- Covers:
--   1. save_shared given a device_id/device_label writes NO top-level
--      device_id/device_label, while schema_version + annotations +
--      metadata + render_settings survive, AND each annotation's own
--      device_id (the winner-based attribution) is untouched.
--   2. Two different writers with identical content produce identical
--      file state.
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_annotation_device_agnostic_spec_" .. tostring(os.time()))

local StateStore = require("syncery_ann/state_store")
local Paths      = require("syncery_ann/paths")
local JsonStore  = require("syncery_ann/json_store")


local counter = 0
local function unique_book()
    counter = counter + 1
    return h.test_root .. "/da_ann_book_" .. tostring(counter) .. ".epub"
end

local function sample_state()
    return {
        annotations = {
            ["PAGE5|/body/DocFragment[3]/p[7]"] = {
                datetime_updated = "2024-01-01T00:00:00",
                device_id        = "creator-dev",   -- per-annotation, kept
                device_label     = "Creator",
                text             = "a highlight",
                page             = 5,
            },
        },
        metadata = {
            status = {
                generation = 0,
                candidates = {
                    { value = "reading", device_id = "creator-dev", device_label = "Creator" },
                },
            },
        },
        render_settings = {
            copt_font_size = {
                value            = 22,
                datetime_updated = "2024-01-01T00:00:00",
            },
        },
    }
end


-- ---------------------------------------------------------------------------
-- 1. save_shared does NOT write the top-level writer stamp, while content
--    (including each annotation's own device_id) survives.
-- ---------------------------------------------------------------------------
do
    local book = unique_book()
    local ok = StateStore.save_shared(book, sample_state())
    h.assert_true(ok, "save_shared succeeds")

    local raw = JsonStore.read(Paths.shared_annotations_path(book))
    h.assert_true(type(raw) == "table", "shared file reads back as a table")

    h.assert_nil(raw.device_id,
        "save_shared writes NO top-level device_id (device-agnostic)")
    h.assert_nil(raw.device_label,
        "save_shared writes NO top-level device_label")

    h.assert_true(raw.schema_version ~= nil, "schema_version is still written")
    h.assert_true(type(raw.annotations) == "table", "annotations survive")
    h.assert_true(type(raw.metadata) == "table", "metadata survives")
    h.assert_true(type(raw.render_settings) == "table", "render_settings survives")

    local ann = raw.annotations["PAGE5|/body/DocFragment[3]/p[7]"]
    h.assert_true(type(ann) == "table", "the annotation survives")
    h.assert_equal(ann.device_id, "creator-dev",
        "per-annotation device_id (winner-based attribution) is untouched")
end


-- ---------------------------------------------------------------------------
-- 2. Identical content -> identical file state (deterministic + device-
--    agnostic: save_shared has no writer input to diverge on, so two
--    devices that build the same content emit the same file).
-- ---------------------------------------------------------------------------
do
    local book_a = unique_book()
    local book_b = unique_book()

    StateStore.save_shared(book_a, sample_state())
    StateStore.save_shared(book_b, sample_state())

    local raw_a = JsonStore.read(Paths.shared_annotations_path(book_a))
    local raw_b = JsonStore.read(Paths.shared_annotations_path(book_b))

    h.assert_deep_equal(raw_a, raw_b,
        "identical content yields identical file state on any device")
end


print("annotation_state_store_device_agnostic_spec: assertions complete")
