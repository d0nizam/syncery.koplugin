-- =============================================================================
-- spec/cloud_staging_spec.lua
-- =============================================================================
--
-- Tests for syncery_transports/cloud/staging.lua — pure functions.
--
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_cloud_staging_spec_" .. tostring(os.time()))

local Staging = require("syncery_transports/cloud/staging")


-- ----------------------------------------------------------------------------
-- cloud_name_for: produces stable, collision-resistant names.
-- ----------------------------------------------------------------------------


do
    h.assert_equal(Staging.cloud_name_for("progress", "abc123"),
        "syncery-progress-abc123.json",
        "happy path: progress")
    h.assert_equal(Staging.cloud_name_for("annotations", "deadbeef"),
        "syncery-annotations-deadbeef.json",
        "happy path: annotations")
end


-- ----------------------------------------------------------------------------
-- cloud_name_for: unknown kind → nil.  Closed enum, by design.
-- ----------------------------------------------------------------------------


do
    h.assert_nil(Staging.cloud_name_for("settings", "abc"),
        "unknown kind 'settings' rejected")
    h.assert_nil(Staging.cloud_name_for("PROGRESS", "abc"),
        "uppercase kind rejected (lowercase only)")
    h.assert_nil(Staging.cloud_name_for("", "abc"),
        "empty kind rejected")
    h.assert_nil(Staging.cloud_name_for(nil, "abc"),
        "nil kind rejected")
end


-- ----------------------------------------------------------------------------
-- cloud_name_for: malformed book_id → nil.  Path-traversal defence.
-- ----------------------------------------------------------------------------


do
    h.assert_nil(Staging.cloud_name_for("progress", ""),
        "empty book_id rejected")
    h.assert_nil(Staging.cloud_name_for("progress", nil),
        "nil book_id rejected")
    h.assert_nil(Staging.cloud_name_for("progress", "a/b"),
        "slash rejected (path traversal)")
    h.assert_nil(Staging.cloud_name_for("progress", "../etc/passwd"),
        ".. rejected (path traversal)")
    h.assert_nil(Staging.cloud_name_for("progress", "abc def"),
        "space rejected")
    h.assert_nil(Staging.cloud_name_for("progress", "a.b"),
        "dot rejected (would split the extension)")
end


-- ----------------------------------------------------------------------------
-- cloud_name_for: hyphen and underscore in book_id are OK (lenient
-- with legitimate future IDs).
-- ----------------------------------------------------------------------------


do
    h.assert_equal(Staging.cloud_name_for("progress", "abc_123-def"),
        "syncery-progress-abc_123-def.json",
        "hyphen + underscore allowed in book_id")
end


-- ----------------------------------------------------------------------------
-- staging_path_for: joins dir + name, normalizes trailing slashes.
-- ----------------------------------------------------------------------------


do
    h.assert_equal(
        Staging.staging_path_for("/data/staging", "syncery-progress-abc.json"),
        "/data/staging/syncery-progress-abc.json",
        "no trailing slash needed")
    h.assert_equal(
        Staging.staging_path_for("/data/staging/", "x.json"),
        "/data/staging/x.json",
        "single trailing slash collapsed")
    h.assert_equal(
        Staging.staging_path_for("/data/staging///", "x.json"),
        "/data/staging/x.json",
        "many trailing slashes collapsed")
end


do
    h.assert_nil(Staging.staging_path_for("", "x.json"),
        "empty dir rejected")
    h.assert_nil(Staging.staging_path_for("/d", ""),
        "empty name rejected")
    h.assert_nil(Staging.staging_path_for(nil, "x.json"),
        "nil dir rejected")
end
