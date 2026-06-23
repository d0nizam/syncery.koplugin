-- =============================================================================
-- spec/update_spec.lua
-- =============================================================================
--
-- Tests for the PURE helpers of syncery_update.lua — the plugin self-updater.
--
--   * getInstalledVersion  — reads `version` from a _meta.lua (path injected)
--   * parseVersion         — "v1.2.3" -> { 1, 2, 3 }
--   * isNewer              — component-wise semver "strictly newer?"
--   * selectAsset          — picks the download URL + strip_root for a release
--   * stripMarkdown        — flattens GitHub release-note markdown
--
-- The network / UI surface (downloadFile, httpGetJSON, install, check) is
-- loadfile-only here: it talks to GitHub, the filesystem and KOReader widgets,
-- and is exercised on a real device against the test repo.  The module requires
-- its KOReader / JSON deps LAZILY, so it loads under bare luajit and these pure
-- helpers run with no stubs.
--
-- =============================================================================

local h = require("spec.test_helpers")

-- A temp root for the one helper that touches disk (getInstalledVersion).
h.setup("/tmp/syncery_test_update_" .. tostring(os.time()))

local Update = require("syncery_update")


-- ----------------------------------------------------------------------------
-- parseVersion
-- ----------------------------------------------------------------------------
do
    local p = Update.parseVersion("v4.7.0")
    h.assert_equal(p[1], 4, "parseVersion: strips leading v, major")
    h.assert_equal(p[2], 7, "parseVersion: minor")
    h.assert_equal(p[3], 0, "parseVersion: patch")

    local q = Update.parseVersion("1.2")
    h.assert_equal(q[1], 1, "parseVersion: no-v major")
    h.assert_equal(q[2], 2, "parseVersion: no-v minor")
    h.assert_equal(q[3], nil, "parseVersion: missing component absent (not 0-padded)")

    local r = Update.parseVersion("2.x.5")
    h.assert_equal(r[2], 0, "parseVersion: non-numeric component -> 0")
end


-- ----------------------------------------------------------------------------
-- isNewer  (the test scenario relies on this: installed 1.1.1, latest 4.7.0)
-- ----------------------------------------------------------------------------
do
    h.assert_true(Update.isNewer("4.7.0", "1.1.1"),
        "isNewer: 4.7.0 > 1.1.1 (the 1.1.1->4.7.0 update test path)")
    h.assert_false(Update.isNewer("1.1.1", "4.7.0"),
        "isNewer: 1.1.1 is NOT newer than 4.7.0 (no downgrade offer)")
    h.assert_false(Update.isNewer("4.7.0", "4.7.0"),
        "isNewer: equal versions are not newer (up-to-date)")
    h.assert_true(Update.isNewer("4.7.1", "4.7.0"),
        "isNewer: patch bump detected")
    h.assert_true(Update.isNewer("v4.8.0", "4.7.9"),
        "isNewer: minor beats higher patch; v-prefix tolerated")
    -- Different component counts: 4.7 vs 4.7.0 are equal (missing -> 0).
    h.assert_false(Update.isNewer("4.7", "4.7.0"),
        "isNewer: 4.7 == 4.7.0 (shorter padded with 0, not newer)")
    h.assert_true(Update.isNewer("4.7.0.1", "4.7.0"),
        "isNewer: extra component makes it newer")
end


-- ----------------------------------------------------------------------------
-- selectAsset  (Syncery's archives are WRAPPED -> strip_root is always true)
-- ----------------------------------------------------------------------------
do
    -- Prefer a .zip asset over the zipball.
    local url, strip = Update.selectAsset({
        assets = { { name = "syncery_koplugin.zip", browser_download_url = "ASSET" } },
        zipball_url = "ZIPBALL",
    })
    h.assert_equal(url, "ASSET", "selectAsset: prefers the .zip asset URL")
    h.assert_true(strip, "selectAsset: wrapped .zip asset -> strip_root true")

    -- A non-zip asset is ignored; fall through to the zipball.
    local url2, strip2 = Update.selectAsset({
        assets = { { name = "notes.txt", browser_download_url = "TXT" } },
        zipball_url = "ZIPBALL",
    })
    h.assert_equal(url2, "ZIPBALL", "selectAsset: skips non-zip asset, uses zipball")
    h.assert_true(strip2, "selectAsset: zipball -> strip_root true")

    -- A .zip asset missing its download URL is skipped.
    local url3 = Update.selectAsset({
        assets = { { name = "x.zip" } },
        zipball_url = "ZIPBALL",
    })
    h.assert_equal(url3, "ZIPBALL", "selectAsset: .zip without download_url is skipped")

    -- Neither asset nor zipball -> nil, nil.
    local url4, strip4 = Update.selectAsset({ assets = {} })
    h.assert_nil(url4, "selectAsset: no asset and no zipball -> nil url")
    h.assert_nil(strip4, "selectAsset: no asset and no zipball -> nil strip")

    -- Missing assets table is tolerated (nil -> {}).
    local url5 = Update.selectAsset({ zipball_url = "ZIPBALL" })
    h.assert_equal(url5, "ZIPBALL", "selectAsset: nil assets tolerated, uses zipball")
end


-- ----------------------------------------------------------------------------
-- stripMarkdown
-- ----------------------------------------------------------------------------
do
    h.assert_equal(Update.stripMarkdown("## Heading"), "Heading",
        "stripMarkdown: removes heading markers")
    h.assert_equal(Update.stripMarkdown("a **bold** b"), "a bold b",
        "stripMarkdown: removes bold")
    h.assert_equal(Update.stripMarkdown("a *italic* b"), "a italic b",
        "stripMarkdown: removes italic")
    h.assert_equal(Update.stripMarkdown("run `code` now"), "run code now",
        "stripMarkdown: removes inline code")
    h.assert_equal(Update.stripMarkdown(nil), "",
        "stripMarkdown: nil -> empty string (no crash)")
end


-- ----------------------------------------------------------------------------
-- getInstalledVersion  (path injected at a temp fixture)
-- ----------------------------------------------------------------------------
do
    local fx = h.test_root .. "/fixture_meta.lua"
    local f = io.open(fx, "w")
    f:write('return {\n  name = "Syncery",\n  version = "4.7.0",\n}\n')
    f:close()
    h.assert_equal(Update.getInstalledVersion(fx), "4.7.0",
        "getInstalledVersion: reads version from _meta.lua fixture")

    -- Missing file -> "unknown" (pcall on dofile swallows the error).
    h.assert_equal(Update.getInstalledVersion(h.test_root .. "/nope.lua"), "unknown",
        "getInstalledVersion: missing meta -> unknown")

    -- Present but no version field -> "unknown".
    local fx2 = h.test_root .. "/fixture_noversion.lua"
    local f2 = io.open(fx2, "w")
    f2:write('return { name = "Syncery" }\n')
    f2:close()
    h.assert_equal(Update.getInstalledVersion(fx2), "unknown",
        "getInstalledVersion: meta without version -> unknown")
end


h.report("update_spec")
