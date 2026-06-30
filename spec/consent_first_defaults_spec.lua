-- =============================================================================
-- spec/consent_first_defaults_spec.lua
-- =============================================================================
--
-- Phase 13.B step 2 — consent-first defaults gate.
--
-- Decision (recorded in the plan): a brand-new install must sync NOTHING
-- until the user opts in. Verified there is no installed base, so the
-- defaults are simply flipped (no existing-user reconciliation needed):
--
--     sync_progress    → false
--     sync_annotations → false
--     sync_metadata    → false
--
-- The annotation SUB-toggles (highlights/notes/bookmarks) stay ON: they
-- are gated behind the sync_annotations master and only act once it's on.
--
-- main.lua builds these via a local `read_bool(key, default)` inside the
-- settings-load method, which is awkward to exercise through a full
-- plugin load in the headless harness. So this gate is STATIC: it reads
-- main.lua's source and asserts the default literal for each key. That is
-- enough to catch the one regression we care about — someone flipping a
-- consent-first default back to `true`.
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_consent_defaults_spec_" .. tostring(os.time()))


-- Locate main.lua relative to this spec (spec/ is a sibling of main.lua).
local function read_main()
    -- The runner sets the working dir to the plugin root; main.lua is there.
    local f = io.open("main.lua", "r")
    if not f then
        -- Fallback: try one level up from spec/.
        f = io.open("../main.lua", "r")
    end
    assert(f, "consent gate: could not open main.lua to inspect defaults")
    local src = f:read("*a")
    f:close()
    return src
end

local src = read_main()


--- Find the default literal in a line like:
---     self.sync_progress = read_bool("syncery_sync_progress", false)
--- Returns "true" | "false" | nil.
local function default_for(key)
    -- Match read_bool("<key>", <default>) tolerantly across spacing.
    local pat = 'read_bool%("' .. key .. '"%s*,%s*(%a+)%s*%)'
    return src:match(pat)
end


-- ---------------------------------------------------------------------------
-- The three consent-first keys must default to false.
-- ---------------------------------------------------------------------------
do
    h.assert_equal(default_for("syncery_sync_progress"), "false",
        "consent: sync_progress defaults OFF (nothing syncs until opt-in)")
    h.assert_equal(default_for("syncery_sync_annotations"), "false",
        "consent: sync_annotations defaults OFF")
    h.assert_equal(default_for("syncery_sync_metadata"), "false",
        "consent: sync_metadata defaults OFF")
end


-- ---------------------------------------------------------------------------
-- Annotation sub-toggles stay ON (they're gated behind the master, so
-- ON means "when you enable annotations, you get highlights+notes+bookmarks").
-- ---------------------------------------------------------------------------
do
    h.assert_equal(default_for("syncery_sync_highlights"), "true",
        "consent: highlights stays ON (gated behind annotations master)")
    h.assert_equal(default_for("syncery_sync_notes"), "true",
        "consent: notes stays ON (gated behind annotations master)")
    h.assert_equal(default_for("syncery_sync_bookmarks"), "true",
        "consent: bookmarks stays ON (gated behind annotations master)")
end


-- ---------------------------------------------------------------------------
-- Transports remain OFF (already the case; lock it so a new install never
-- starts pushing data anywhere without an explicit choice).
-- ---------------------------------------------------------------------------
do
    h.assert_equal(default_for("syncery_use_syncthing"), "false",
        "consent: Syncthing transport defaults OFF")
    h.assert_equal(default_for("syncery_use_cloud"), "false",
        "consent: Cloud transport defaults OFF")
end


-- Close-push waking Wi-Fi is opt-in: never bring the radio up behind the user's
-- back without an explicit choice.
do
    h.assert_equal(default_for("syncery_wake_wifi_for_sync"), "false",
        "consent: wake-Wi-Fi-on-close defaults OFF")
    h.assert_equal(default_for("syncery_wake_wifi_on_suspend"), "false",
        "consent: wake-Wi-Fi-on-sleep defaults OFF")
end
