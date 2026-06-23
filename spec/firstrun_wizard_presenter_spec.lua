-- =============================================================================
-- spec/firstrun_wizard_presenter_spec.lua
-- =============================================================================
--
-- The wizard PRESENTER (syncery_ui/wizard_presenter.lua) wired to the real
-- controller (Wizard.run), now driving the coherent slide-up window. A
-- recording stub stands in for the window (records every :setStep(desc)) and
-- for InputDialog / InfoMessage / UIManager, so we drive a full first-run and
-- assert both the per-step DESCRIPTIONS the presenter builds (title, items,
-- footer) and the persistence side effects.
--
-- The window's on-device rendering is NOT tested here (it require()s live
-- KOReader, like toast_widget) — what IS locked is the presenter's
-- spec->desc mapping, the one-persistent-window flow (setStep, not
-- close/reopen), the text steps using InputDialog, and NO toast after Done.
-- =============================================================================


local h = require("spec.test_helpers")

package.loaded["syncery_i18n"] = {
    translate = function(s) return s end,
    ngettext  = function(s, p, n) if n == 1 then return s else return p end end,
}
package.loaded["syncery_ui/wizard"]           = nil
package.loaded["syncery_ui/wizard_presenter"] = nil
local Presenter = require("syncery_ui/wizard_presenter")
local Wizard    = require("syncery_ui/wizard")


-- --- recording environment --------------------------------------------------
--   opts.kosyncthing      KOSyncthing+ detected
--   opts.api       prefill API key ("")
--   opts.online    false -> offline
--   opts.test_ok / opts.test_diag  async test result
--   opts.no_notify omit env.notify (exercise InfoMessage fallback)
--   opts.label     device label default
--   opts.firstrun_done
local function make_env(opts)
    opts = opts or {}
    local rec = { steps = {}, shown = 0, closed = 0, inputs = {}, toasts = {},
                  notes = {}, test_called = 0, full_refreshes = 0,
                  backdrop_shown = 0, backdrop_closed = 0 }
    local saved  = {}
    local plugin = {
        sync_progress    = opts.progress    == true,
        sync_annotations = opts.annotations == true,
    }
    local done = opts.firstrun_done == true

    local function make_win()
        local w = { __is_window = true }
        function w:setStep(desc) rec.steps[#rec.steps + 1] = desc; rec.last = desc end
        return w
    end

    local UIManager = {
        show = function(_self, widget)
            if not widget then return end
            if widget.__is_window then rec.shown = rec.shown + 1
            elseif widget.__is_backdrop then rec.backdrop_shown = rec.backdrop_shown + 1
            elseif widget.__kind == "input" then
                rec.inputs[#rec.inputs + 1] = widget; rec.last_input = widget
            elseif widget.__kind == "info" then
                rec.toasts[#rec.toasts + 1] = widget
            end
        end,
        close = function(_self, widget)
            if widget and widget.__is_window then rec.closed = rec.closed + 1 end
            if widget and widget.__is_backdrop then rec.backdrop_closed = rec.backdrop_closed + 1 end
        end,
        setDirty = function(_self, region, refresh)
            -- Terminal full-screen flash refresh (clears the e-ink ghost).
            if region == "all" and refresh == "full" then
                rec.full_refreshes = rec.full_refreshes + 1
            end
        end,
    }
    local InputDialog = { new = function(_self, o)
        o.__kind = "input"
        o.getInputText  = function() return o.__typed ~= nil and o.__typed or o.input end
        o.onShowKeyboard = function() end
        return o
    end }
    local InfoMessage = { new = function(_self, o) o.__kind = "info"; return o end }

    local env = {
        plugin   = plugin,
        settings = { saveSetting = function(_self, k, v) saved[k] = v end },
        util     = {
            get_device_label = function() return opts.label or "Kobo Model" end,
            set_device_label = function(t)
                t = t and (t:gsub("^%s+", ""):gsub("%s+$", "")) or ""
                if #t == 0 then return false end
                saved.__label = t
                return t
            end,
        },
        kosyncthing_resolver          = function() return opts.kosyncthing and {} or nil end,
        config_xml_key_resolver       = function() return opts.config_xml_key == true end,
        is_first_run_done      = function() return done end,
        persist_first_run_done = function() done = true end,
        get_syncthing_api_key  = function() return opts.api or "" end,
        save_syncthing_api_key = function(k) saved.__api = k end,
        is_online              = function() return opts.online ~= false end,
        test_syncthing         = function(cb)
            rec.test_called = rec.test_called + 1
            cb(opts.test_ok == true, nil, opts.test_diag)
        end,
        make_wizard_window     = function() return make_win() end,
        make_backdrop          = function() return { __is_backdrop = true } end,
        widgets = { InputDialog = InputDialog, InfoMessage = InfoMessage, UIManager = UIManager },
    }
    if not opts.no_notify then
        env.notify = function(text) rec.notes[#rec.notes + 1] = text end
    end
    return env, rec, saved, plugin, function() return done end
end

-- helpers to "drive" the recorded UI
local function footer_btn(desc, label)
    for _, b in ipairs(desc.footer or {}) do if b.label == label then return b end end
    return nil
end
local function tap_footer(rec, label)
    local b = footer_btn(rec.last, label)
    h.assert_true(b ~= nil, "footer button present: " .. tostring(label))
    b.on_tap()
end
local function tap_item(rec, i) rec.last.items[i].on_tap() end
local function count_items(desc, t)
    local n = 0
    for _, it in ipairs(desc.items or {}) do if it.type == t then n = n + 1 end end
    return n
end
local function input_btn(rec, col) rec.last_input.buttons[1][col].callback() end


-- ---------------------------------------------------------------------------
-- Direct deps behaviour (persistence + detection) — unchanged by the window.
-- ---------------------------------------------------------------------------
do
    local env, _rec, saved, plugin = make_env({ kosyncthing = true, label = "MyDev", api = "OLDKEY" })
    local deps = Presenter.makeDeps(env)

    h.assert_true(deps.kosyncthing_detected(), "deps.kosyncthing_detected: true when resolver returns a table")
    h.assert_equal(deps.get_label_default(), "MyDev", "deps.get_label_default: reads the device label")
    h.assert_equal(deps.get_syncthing_api_default(), "OLDKEY", "deps.get_syncthing_api_default: prefills the key")

    deps.save_what({ syncery_sync_progress = true, syncery_sync_annotations = false })
    h.assert_equal(saved.syncery_sync_progress, true, "deps.save_what: persists progress")
    h.assert_equal(saved.syncery_sync_annotations, false, "deps.save_what: persists annotations")
    h.assert_true(plugin.sync_progress, "deps.save_what: mirrors progress")
    h.assert_false(plugin.sync_annotations, "deps.save_what: mirrors annotations")

    deps.save_transport("cloud")
    h.assert_equal(saved.syncery_use_cloud, true, "deps.save_transport: flips use_* key")
    h.assert_true(plugin.use_cloud, "deps.save_transport: mirrors use_*")
    deps.lower_transport("cloud")
    h.assert_equal(saved.syncery_use_cloud, false, "deps.lower_transport: lowers use_* (replace)")
    h.assert_false(plugin.use_cloud, "deps.lower_transport: mirrors the lowered flag")
    deps.save_transport(nil)
    h.assert_nil(saved.syncery_use_, "deps.save_transport(nil): records nothing")

    deps.save_syncthing_api_key("KEY42")
    h.assert_equal(saved.__api, "KEY42", "deps.save_syncthing_api_key: persists via env")

    deps.save_label("  Renamed  ")
    h.assert_equal(saved.__label, "Renamed", "deps.save_label: persists trimmed")
    h.assert_equal(plugin.device_label, "Renamed", "deps.save_label: mirrors CANONICAL value (F3)")
    plugin.device_label = "Keep"
    deps.save_label("   ")
    h.assert_equal(plugin.device_label, "Keep", "deps.save_label: rejected save leaves mirror untouched")
end

do
    local env = make_env({ kosyncthing = false })
    h.assert_false(Presenter.makeDeps(env).kosyncthing_detected(),
        "deps.kosyncthing_detected: false when resolver returns nil")
end


do
    h.assert_true(Presenter.makeDeps(make_env({ config_xml_key = true }))
            .config_xml_key_available(),
        "deps.config_xml_key_available: true when the resolver reports a key")
    h.assert_false(Presenter.makeDeps(make_env({ config_xml_key = false }))
            .config_xml_key_available(),
        "deps.config_xml_key_available: false when no config.xml key")
end


-- ---------------------------------------------------------------------------
-- run_api_test — async toast mapping (saved-first: never blocks).
-- ---------------------------------------------------------------------------
do
    local env, rec = make_env({ test_ok = true })
    Presenter.makeDeps(env).run_api_test()
    h.assert_equal(rec.test_called, 1, "run_api_test: fires the injected test")
    h.assert_true(rec.notes[1]:find("reachable", 1, true) ~= nil, "run_api_test: success -> reachable")
    h.assert_nil(rec.notes[1]:find("Setup complete", 1, true), "run_api_test: no 'Setup complete!' tail")
end
do
    local env, rec = make_env({ test_ok = false, test_diag = "auth_failed" })
    Presenter.makeDeps(env).run_api_test()
    h.assert_true(rec.notes[1]:find("rejected", 1, true) ~= nil, "run_api_test: auth_failed -> rejected")
end
do
    local env, rec = make_env({ test_ok = false })
    Presenter.makeDeps(env).run_api_test()
    h.assert_true(rec.notes[1]:find("Could not reach", 1, true) ~= nil, "run_api_test: other -> unreachable")
end
do
    local env, rec = make_env({ online = false })
    Presenter.makeDeps(env).run_api_test()
    h.assert_equal(rec.test_called, 0, "run_api_test: offline -> no network call")
    h.assert_true(rec.notes[1]:find("No network", 1, true) ~= nil, "run_api_test: offline -> saved-first msg")
end
do
    local env, rec = make_env({ online = false, no_notify = true })
    Presenter.makeDeps(env).run_api_test()
    h.assert_equal(#rec.toasts, 1, "run_api_test: without env.notify the InfoMessage fallback fires")
    h.assert_true(rec.toasts[1].text:find("No network", 1, true) ~= nil, "run_api_test: fallback carries the msg")
end


-- ---------------------------------------------------------------------------
-- Full first-run, NO KOSyncthing+: transport(panel) -> API(input) -> what(panel) ->
-- label(input) -> recap(panel). One window (setStep), NO toast at Done.
-- ---------------------------------------------------------------------------
do
    local env, rec, saved, plugin, is_done = make_env({ kosyncthing = false, test_ok = true })
    Wizard.run(Presenter.makeDeps(env))

    -- Step 1: the window opened on the transport step.
    h.assert_equal(rec.shown, 1, "run: the transport panel is shown")
    h.assert_true(rec.last.title:find("want", 1, true) ~= nil, "run: transport title is the locked wording")
    h.assert_equal(count_items(rec.last, "button_row"), 3, "run: transport has three tappable rows")
    h.assert_equal(#(rec.last.footer or {}), 0, "run: transport step 1 has no Back (no footer)")
    h.assert_true(rec.last.items[1].text:find("Syncthing", 1, true) ~= nil, "run: first row is Syncthing")
    h.assert_true(type(rec.last.on_dismiss) == "function", "run: the panel wires a dismiss (title close)")

    -- Tap Syncthing -> raises flag -> API input step. The panel is CLOSED
    -- before the InputDialog shows (no overlap); the input is not a panel step.
    tap_item(rec, 1)
    h.assert_equal(saved.syncery_use_syncthing, true, "run: tapping Syncthing flips use_syncthing")
    h.assert_true(rec.closed >= 1, "run: the panel is closed before the API InputDialog (no overlap)")
    h.assert_equal(rec.backdrop_shown, 1, "run: a white backdrop is shown behind the API InputDialog")
    h.assert_equal(#rec.steps, 1, "run: the API step does not add a window step")
    h.assert_equal(rec.last_input.title, "Syncthing API key", "run: API step is an InputDialog")
    h.assert_true(rec.last_input.description:find("menu", 1, true) ~= nil, "run: API desc carries the folder note")
    h.assert_equal(rec.last_input.buttons[1][2].text, "Test connection", "run: API primary is 'Test connection'")

    -- Type a key, tap Test -> saved trimmed, async test fired (toast), advance.
    rec.last_input.__typed = "  KEY123  "
    input_btn(rec, 2)
    h.assert_equal(saved.__api, "KEY123", "run: API key trimmed + persisted (saved-first)")
    h.assert_equal(rec.test_called, 1, "run: the async test fired once")
    h.assert_true(rec.notes[1]:find("reachable", 1, true) ~= nil, "run: result is a non-blocking toast")
    h.assert_equal(rec.backdrop_closed, 1, "run: the API backdrop is torn down with the dialog")

    -- Step 2: what-to-sync opens a FRESH window (the panel was closed for the
    -- API input step, so there is never an overlap).
    h.assert_equal(rec.shown, 2, "run: what-to-sync opens a fresh window (panel closed for the API step — no overlap)")
    h.assert_true(rec.last.title:find("What should Syncery sync", 1, true) ~= nil, "run: what title")
    h.assert_true(rec.last.subtitle:find("What's synced", 1, true) ~= nil, "run: what subtitle references the real row (F2)")
    h.assert_equal(count_items(rec.last, "check_row"), 2, "run: two real checkbox rows")
    h.assert_equal(count_items(rec.last, "note"), 1, "run: the reassurance note is present")
    h.assert_true(footer_btn(rec.last, "Back") ~= nil, "run: what has Back")
    h.assert_true(footer_btn(rec.last, "Next") ~= nil, "run: what has Next")

    -- Toggle progress on (re-render in place), then Next.
    local before = #rec.steps
    tap_item(rec, 1)
    h.assert_true(#rec.steps > before, "run: toggling re-renders the panel in place")
    h.assert_true(rec.last.items[1].checked == true, "run: the toggled row is now checked")
    tap_footer(rec, "Next")
    h.assert_equal(saved.syncery_sync_progress, true, "run: progress consent persisted")
    h.assert_equal(saved.syncery_sync_annotations, false, "run: untouched annotations persisted false")

    -- Step 3: label InputDialog.
    h.assert_equal(rec.backdrop_shown, 2, "run: a white backdrop is shown behind the label InputDialog")
    h.assert_equal(rec.last_input.buttons[1][2].text, "Next", "run: label primary is 'Next'")
    rec.last_input.__typed = "  Bedside Kobo  "
    input_btn(rec, 2)
    h.assert_equal(saved.__label, "Bedside Kobo", "run: label persisted trimmed")
    h.assert_equal(plugin.device_label, "Bedside Kobo", "run: session mirror carries canonical value (F3)")
    h.assert_equal(rec.backdrop_closed, 2, "run: the label backdrop is torn down with the dialog")

    -- Step 4: recap opens a fresh window (the panel was closed for the label
    -- input step — again no overlap).
    h.assert_equal(rec.shown, 3, "run: recap opens a fresh window (panel closed for the label step)")
    h.assert_true(rec.last.title:find("Setup complete", 1, true) ~= nil, "run: recap title")
    h.assert_equal(count_items(rec.last, "recap_line"), 3, "run: recap has three lines")
    h.assert_true(rec.last.items[1].text:find("Transport: Syncthing", 1, true) ~= nil, "run: recap names the transport")
    h.assert_true(rec.last.items[1].sub:find("folder", 1, true) ~= nil, "run: no-KOSyncthing+ recap note points at the folder pick")
    h.assert_true(footer_btn(rec.last, "Done") ~= nil, "run: recap closing button is 'Done'")

    -- Done -> close the window, persist firstrun, NO toast.
    local toasts_before = #rec.toasts
    tap_footer(rec, "Done")
    h.assert_true(is_done(), "run: Done persists firstrun-done")
    h.assert_true(rec.closed >= 1, "run: Done closes the window")
    h.assert_true(rec.full_refreshes >= 1,
        "run: Done flash-refreshes the whole screen (clears the e-ink ghost of the wizard)")
    h.assert_equal(#rec.toasts, toasts_before, "run: NO toast after Done — the recap IS the confirmation")
end


-- ---------------------------------------------------------------------------
-- KOSyncthing+ path: transport PRESENT, named 'KOSyncthing+'; no API step; recap
-- has no pending note but still all three lines.
-- ---------------------------------------------------------------------------
do
    local env, rec, saved, _plugin, is_done = make_env({ kosyncthing = true })
    Wizard.run(Presenter.makeDeps(env))

    h.assert_equal(rec.shown, 1, "KOSyncthing+ run: window shown once")
    h.assert_true(rec.last.items[1].text:find("KOSyncthing+", 1, true) ~= nil, "KOSyncthing+ run: row named 'KOSyncthing+'")
    h.assert_true(rec.last.items[1].sub:find("detected", 1, true) ~= nil, "KOSyncthing+ run: row subtitle says it was detected")
    tap_item(rec, 1)
    h.assert_equal(saved.syncery_use_syncthing, true, "KOSyncthing+ run: choosing KOSyncthing+ RAISES use_syncthing (F1)")

    -- No API InputDialog: straight to what-to-sync in the window.
    h.assert_equal(#rec.inputs, 0, "KOSyncthing+ run: no API InputDialog before what-to-sync")
    h.assert_true(rec.last.title:find("What should Syncery sync", 1, true) ~= nil, "KOSyncthing+ run: next panel is what-to-sync")
    tap_footer(rec, "Next")   -- both toggles off

    -- Label input, then recap.
    h.assert_equal(rec.last_input.buttons[1][2].text, "Next", "KOSyncthing+ run: label input")
    input_btn(rec, 2)         -- keep the prefilled default
    h.assert_true(rec.last.title:find("Setup complete", 1, true) ~= nil, "KOSyncthing+ run: recap")
    h.assert_equal(count_items(rec.last, "recap_line"), 3, "KOSyncthing+ run: recap still has all three lines")
    h.assert_true(rec.last.items[1].text:find("KOSyncthing+", 1, true) ~= nil, "KOSyncthing+ run: recap names 'KOSyncthing+'")
    h.assert_true(rec.last.items[1].sub ~= nil
        and rec.last.items[1].sub:find("folder", 1, true) ~= nil,
        "KOSyncthing+ run: recap now nudges toward the folder picker (sub set)")
    h.assert_true(rec.last.items[2].text:find("nothing yet", 1, true) ~= nil, "KOSyncthing+ run: recap says nothing enabled yet")
    tap_footer(rec, "Done")
    h.assert_true(is_done(), "KOSyncthing+ run: completes")
    h.assert_equal(#rec.toasts, 0, "KOSyncthing+ run: no toast after Done")
end


-- ---------------------------------------------------------------------------
-- Back from the API step returns to transport (re-rendered in the window).
-- ---------------------------------------------------------------------------
do
    local env, rec = make_env({ kosyncthing = false, test_ok = true })
    Wizard.run(Presenter.makeDeps(env))
    tap_item(rec, 1)                 -- Syncthing -> API input
    h.assert_equal(rec.last_input.title, "Syncthing API key", "back: at the API input")
    rec.last_input.buttons[1][1].callback()   -- Back
    h.assert_true(rec.last.title:find("want", 1, true) ~= nil,
        "back: Back from API re-renders the transport panel")
end


-- ---------------------------------------------------------------------------
-- Already done: nothing is shown.
-- ---------------------------------------------------------------------------
do
    local env, rec = make_env({ firstrun_done = true })
    Wizard.run(Presenter.makeDeps(env))
    h.assert_equal(rec.shown, 0, "already-done: no window shown")
    h.assert_equal(#rec.steps, 0, "already-done: no step rendered")
    h.assert_equal(#rec.inputs, 0, "already-done: no input dialog")
end
