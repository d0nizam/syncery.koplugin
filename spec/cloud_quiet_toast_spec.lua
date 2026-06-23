-- =============================================================================
-- spec/cloud_quiet_toast_spec.lua
-- =============================================================================
--
-- Tests for syncery_transports/cloud/quiet_toast.lua — the suppressor that
-- swallows the cloud backends' always-on "Successfully synchronized." toast.
--
-- UIManager + gettext are not require-able headless, so we install fakes via
-- package.loaded (quiet_toast resolves them lazily) and drive a controllable
-- clock through QT._clock.  Cleaned up at the end so the fakes don't leak into
-- later specs.
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_cloud_quiet_toast_spec_" .. tostring(os.time()))

local QT = require("syncery_transports/cloud/quiet_toast")

local TARGET = "Toast: Successfully synchronized (translated)."


-- Install a fresh fake UIManager + gettext, reset module state, return the
-- recorder tables.  `fake_ui.show` starts as the ORIGINAL show (records to
-- `shown`); suppress() wraps it.
local function fresh()
    QT._reset()
    local shown, scheduled = {}, {}
    local fake_ui = {}
    fake_ui.show = function(_self, w) table.insert(shown, w) end
    fake_ui.scheduleIn = function(_self, sec, fn)
        table.insert(scheduled, { sec = sec, fn = fn })
    end
    package.loaded["ui/uimanager"] = fake_ui
    package.loaded["gettext"] = function(msgid)
        return msgid == "Successfully synchronized." and TARGET or msgid
    end
    local CLOCK = { t = 1000 }
    QT._clock = function() return CLOCK.t end
    return { ui = fake_ui, shown = shown, scheduled = scheduled, clock = CLOCK }
end


-- (1) suppress() activates and schedules the hygiene restore.
do
    local f = fresh()
    local ok = QT.suppress(30)
    h.assert_true(ok == true, "suppress() returns true when UIManager is resolvable")
    h.assert_equal(#f.scheduled, 1, "suppress() schedules exactly one restore check")
end


-- (2) In window: the success toast is swallowed; every other widget passes.
do
    local f = fresh()
    QT.suppress(30)  -- window: [1000, 1030)
    f.ui.show(f.ui, { text = TARGET })
    f.ui.show(f.ui, { text = "Some unrelated notification" })
    h.assert_equal(#f.shown, 1, "in window: success toast swallowed, other widget passes")
    h.assert_equal(f.shown[1].text, "Some unrelated notification",
        "the widget that passed is the non-target one")
end


-- (3) Out of window: the SAME success string passes through again.
do
    local f = fresh()
    QT.suppress(30)
    f.clock.t = 1000 + 31  -- past suppress_until (1030)
    f.ui.show(f.ui, { text = TARGET })
    h.assert_equal(#f.shown, 1, "out of window: the success string is no longer swallowed")
    h.assert_equal(f.shown[1].text, TARGET, "the success string reaches show once the window lapses")
end


-- (4) A non-Notification / text-less widget is never touched, even in window.
do
    local f = fresh()
    QT.suppress(30)
    f.ui.show(f.ui, { foo = "bar" })   -- no .text
    f.ui.show(f.ui, "a bare string")   -- not even a table
    h.assert_equal(#f.shown, 2, "widgets without the target text always pass through")
end


-- (5) Hygiene: firing the scheduled check past the window un-installs the wrapper.
do
    local f = fresh()
    QT.suppress(30)
    local wrapped = f.ui.show
    h.assert_true(wrapped ~= nil, "wrapper installed")
    f.clock.t = 2000  -- well past the window
    f.scheduled[1].fn()  -- run the restore check
    h.assert_true(f.ui.show ~= wrapped, "after the restore check, UIManager.show is restored")
end


-- (6) Extension: a second suppress() before the window lapses keeps swallowing,
--     and the restore check re-schedules rather than un-installing early.
do
    local f = fresh()
    QT.suppress(30)            -- window end 1030
    f.clock.t = 1025
    QT.suppress(30)            -- extends to 1055
    f.clock.t = 1031           -- past the FIRST end, before the SECOND
    f.scheduled[1].fn()        -- restore check: window still active → reschedule
    h.assert_equal(#f.scheduled, 2, "restore check re-schedules while the window is extended")
    f.ui.show(f.ui, { text = TARGET })
    h.assert_equal(#f.shown, 0, "still swallowing inside the extended window")
end


-- (7) Headless: no UIManager / gettext → suppress() is a no-op, no crash.
do
    QT._reset()
    package.loaded["ui/uimanager"] = nil
    package.loaded["gettext"] = nil
    local ok, ret = pcall(QT.suppress, 30)
    h.assert_true(ok == true, "suppress() does not raise when headless")
    h.assert_true(ret == false, "suppress() returns false when UIManager is unavailable")
end


-- Clean up the fakes so they do not leak into later specs.
package.loaded["ui/uimanager"] = nil
package.loaded["gettext"] = nil
QT._reset()
