-- =============================================================================
-- spec/viewer_lifted_goto_button_spec.lua
-- =============================================================================
--
-- Source-text guard (viewer_lifted.lua requires many UI widgets at module
-- load time, so it cannot be require()'d directly here -- matching
-- main.lua's own testing constraint) for a real bug: the "Go to
-- highlight/note/bookmark" button was gated on `book_exists` ALONE,
-- making it the ONLY way to reach openBookAtNote -- where the "locate
-- the file" flow (syncery_ui/prefetch_locate.lua) lives -- completely
-- unreachable for is_prefetch_only/path_unresolved_here notes. Confirmed
-- on-device: such notes showed only a "Close" button, no way to ever
-- trigger the locate prompt.
--
-- =============================================================================

local h = require("spec.test_helpers")
h.setup()

local path = "syncery_ui/annotation_viewer/viewer_lifted.lua"
local f = io.open(path, "r")
local src = f:read("*a")
f:close()

h.assert_true(
    src:find("book_exists or note.is_prefetch_only or note.path_unresolved_here", 1, true) ~= nil,
    "BUGFIX GUARD: the goto-button's visibility condition includes "
    .. "is_prefetch_only/path_unresolved_here, not book_exists alone -- "
    .. "otherwise the locate flow has no UI entry point in the Annotation "
    .. "Browser at all")

print("viewer_lifted_goto_button_spec: all assertions passed")
