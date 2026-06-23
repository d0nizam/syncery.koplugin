-- =============================================================================
-- spec/transport_label_spec.lua
-- =============================================================================
--
-- Tests for Util.transport_label — the journal's transport-context label.
--
-- Syncthing and cloud are INDEPENDENT transports: cloud runs ALONGSIDE
-- Syncthing (a fallback for users without it), not instead of it, so either,
-- both, or neither may be enabled.  The label must name whichever carried the
-- merge -- the journal previously read only the Syncthing flag, so a
-- cloud-only sync was mislabelled "local" and a Syncthing+cloud sync was
-- recorded as just "syncthing".
--
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_transport_label_spec_" .. tostring(os.time()))

local Util = require("syncery_util")


-- ----------------------------------------------------------------------------
-- Both transports on -> the combined label (Syncthing named first)
-- ----------------------------------------------------------------------------
do
    h.assert_equal(Util.transport_label(true, true), "syncthing+cloud",
        "both on -> syncthing+cloud (cloud runs alongside Syncthing)")
end


-- ----------------------------------------------------------------------------
-- Cloud only -> "cloud" (the bug: this used to be "local")
-- ----------------------------------------------------------------------------
do
    h.assert_equal(Util.transport_label(false, true), "cloud",
        "cloud only -> cloud, not the mislabelled 'local'")
end


-- ----------------------------------------------------------------------------
-- Syncthing only -> "syncthing"
-- ----------------------------------------------------------------------------
do
    h.assert_equal(Util.transport_label(true, false), "syncthing",
        "syncthing only -> syncthing")
end


-- ----------------------------------------------------------------------------
-- Neither -> "local" (no transport carries the merge)
-- ----------------------------------------------------------------------------
do
    h.assert_equal(Util.transport_label(false, false), "local",
        "neither -> local")
end


h.report("transport_label_spec")
