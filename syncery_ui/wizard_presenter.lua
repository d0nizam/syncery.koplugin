-- =============================================================================
-- syncery_ui/wizard_presenter.lua
-- =============================================================================
--
-- First-run wizard PRESENTER (coherent slide-up window).
--
-- Turns the pure controller's per-step specs (see syncery_ui/wizard.lua,
-- Wizard.run) into a SINGLE persistent slide-up window whose body is swapped
-- in place per step — replacing the old chain of modal ButtonDialogs. The
-- choice steps (transport, what-to-sync) and the recap render in the window
-- (real Buttons / CheckButtons); the two text steps (API key, device name)
-- are shown as a KOReader InputDialog on top, so the system keyboard is wired
-- for us. Everything external is INJECTED via `env` so this module is
-- unit-testable with recording stubs (no live KOReader); the window itself
-- (syncery_ui/wizard_window.lua) is injected the same way and stubbed in the
-- spec.
--
-- `env` interface:
--   plugin                 the Syncery instance (read/mirror sync_* and use_*)
--   settings               G_reader_settings (may be nil; guarded)
--   util                   Syncery Util (get_device_label / set_device_label)
--   kosyncthing_resolver()        -> KOSyncthing+ API table | nil   (kosyncthing_plus detect)
--   is_first_run_done()    -> bool                   (the persisted flag)
--   persist_first_run_done()                         (set the flag = true)
--   get_syncthing_api_key() -> string|nil            (prefill; optional)
--   save_syncthing_api_key(key)                      (persist; optional)
--   is_online()            -> bool                   (network gate; optional)
--   test_syncthing(cb)     async connection test, cb(ok, code, diag) (optional)
--   notify(text)           non-blocking toast (optional; InfoMessage fallback)
--   make_wizard_window(spec) -> window               (the slide-up window;
--                          window:setStep(desc); shown/closed via UIManager)
--   make_backdrop() -> widget                        (optional; bare white
--                          full-screen fill shown behind the text-step dialog)
--   widgets = { InputDialog, InfoMessage, UIManager }
-- =============================================================================


local I18n   = require("syncery_i18n")
local _      = I18n.translate
local Wizard = require("syncery_ui/wizard")


local Presenter = {}


-- Join non-empty text fragments with blank lines (InputDialog description).
-- select-based walk (NOT ipairs over {...}): a nil in the MIDDLE of the list
-- must not truncate the rest.
local function block(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local s = select(i, ...)
        if type(s) == "string" and #s > 0 then parts[#parts + 1] = s end
    end
    return table.concat(parts, "\n\n")
end


-- Build the `deps` table consumed by Wizard.run(deps).
function Presenter.makeDeps(env)
    local W        = env.widgets
    local plugin   = env.plugin
    local settings = env.settings
    local util     = env.util

    local function save_setting(key, value)
        if settings then settings:saveSetting(key, value) end
    end

    local deps = {}

    deps.firstrun_done     = function() return env.is_first_run_done() == true end
    deps.set_firstrun_done = function() env.persist_first_run_done() end

    deps.kosyncthing_detected = function()
        local api = env.kosyncthing_resolver and env.kosyncthing_resolver() or nil
        return type(api) == "table"
    end

    deps.config_xml_key_available = function()
        return env.config_xml_key_resolver
            and env.config_xml_key_resolver() == true
    end

    deps.current_what = function()
        return {
            progress    = plugin.sync_progress    == true,
            annotations = plugin.sync_annotations == true,
        }
    end

    deps.save_what = function(writes)
        save_setting("syncery_sync_progress",    writes.syncery_sync_progress)
        save_setting("syncery_sync_annotations", writes.syncery_sync_annotations)
        plugin.sync_progress    = writes.syncery_sync_progress
        plugin.sync_annotations = writes.syncery_sync_annotations
    end

    -- Level-2 transport behaviour: flip the chosen transport's use_* flag
    -- and mirror it onto the plugin. "decide later" (nil) records nothing.
    deps.save_transport = function(name)
        if not name then return end
        save_setting("syncery_use_" .. name, true)
        plugin["use_" .. name] = true
    end

    -- Replace-semantics partner: the controller calls this ONLY for a
    -- flag the same wizard run raised — never for a flag set from the menu,
    -- where both transports may coexist.
    deps.lower_transport = function(name)
        if not name then return end
        save_setting("syncery_use_" .. name, false)
        plugin["use_" .. name] = false
    end

    deps.get_syncthing_api_default = function()
        if env.get_syncthing_api_key then
            return env.get_syncthing_api_key() or ""
        end
        return ""
    end

    deps.save_syncthing_api_key = function(key)
        if env.save_syncthing_api_key then env.save_syncthing_api_key(key) end
    end

    -- Fire-and-forget connection test (saved-first): the key is
    -- already persisted, so the wizard advances without waiting and the
    -- result lands as a non-blocking toast. The diagnostic strings reuse
    -- the menu's verbatim msgids (no translation churn); success drops the
    -- old "Setup complete!" tail — the wizard's recap is the one finish.
    deps.run_api_test = function()
        local notify = env.notify or function(text)
            W.UIManager:show(W.InfoMessage:new{ text = text, timeout = 4 })
        end
        if env.is_online and env.is_online() == false then
            notify(_("No network connection.\nYour settings are saved — test the connection once you're back online."))
            return
        end
        if not env.test_syncthing then return end
        env.test_syncthing(function(ok, _code, diag)
            if ok then
                notify(_("Syncthing is reachable and the API key is valid."))
            elseif diag == "auth_failed" then
                notify(_("API key rejected.\nCheck Syncthing → Settings → GUI → API Key."))
            else
                notify(_("Could not reach Syncthing. Is it running?"))
            end
        end)
    end

    deps.get_label_default = function() return util.get_device_label() end

    deps.save_label = function(text)
        -- Mirror the CANONICAL persisted value, never the raw input
        -- (finding F3): set_device_label trims, rejects empty and clips to
        -- 50 codepoints, returning what it actually saved (or false).
        local saved = util.set_device_label(text)
        if saved then plugin.device_label = saved end
    end

    -- ----- rendering: one persistent window, body swapped per step ----------

    local win  -- the slide-up window (created on the first panel step)

    local function close_window()
        if win then W.UIManager:close(win); win = nil end
    end

    -- A bare white full-screen backdrop shown BEHIND the text-step InputDialog
    -- (device name / API key), so the wizard's white background persists while
    -- the keyboard is up.  The panel is closed for those steps (one window at a
    -- time) and the InputDialog does not cover the whole screen; this fills the
    -- uncovered margins.  No input -- the dialog on top owns interaction.
    -- Optional (`make_backdrop` may be absent in a minimal env): then the steps
    -- simply degrade to the prior behaviour (no backdrop), never crash.
    local backdrop
    local function show_backdrop()
        if backdrop or not env.make_backdrop then return end
        backdrop = env.make_backdrop()
        W.UIManager:show(backdrop)
    end
    local function close_backdrop()
        if backdrop then W.UIManager:close(backdrop); backdrop = nil end
    end

    -- Terminal dismissal (Done / tap-out): the window is an opaque full-screen
    -- widget, so after it closes the app UI underneath must repaint with a
    -- clearing flash or the panel ghosts on e-ink (UIManager's default close
    -- refresh is non-flashing).  Mirrors ScreenSaverLockWidget:onCloseWidget.
    -- The internal panel->InputDialog close uses close_window() (the dialog and
    -- the next panel repaint over it), so it deliberately does NOT flash here.
    local function finish_window()
        close_window()
        W.UIManager:setDirty("all", "full")
    end

    -- Show/refresh the window with a step description. All descs flow through
    -- :setStep so the body swaps IN PLACE (no close/reopen chain).
    local function show_panel(desc)
        if win then
            win:setStep(desc)
        else
            win = env.make_wizard_window{}
            win:setStep(desc)
            W.UIManager:show(win)
        end
    end

    -- Any terminal dismissal also closes the window (the controller's
    -- on_dismiss handles persistence; we just tear the window down).
    local function wrap_dismiss(fn)
        return function()
            finish_window()
            if fn then fn() end
        end
    end

    local function present_transport(spec)
        local items = {}
        for _, c in ipairs(spec.choices) do
            items[#items + 1] = {
                type   = "button_row",
                text   = c.label,
                sub    = c.desc,
                on_tap = function() spec.on_choice(c.id) end,
            }
        end
        local footer = {}
        if spec.on_back then
            footer[#footer + 1] = { label = _("Back"), on_tap = spec.on_back }
        end
        show_panel{
            title      = spec.header.title,
            subtitle   = spec.header.subtitle,
            items      = items,
            footer     = footer,
            on_dismiss = wrap_dismiss(spec.on_dismiss),
        }
    end

    local function present_what(spec)
        -- Re-render in place on every toggle so the real CheckButtons reflect
        -- the new state (the controller holds the canonical state).
        local function render(state)
            local items = {}
            for _, rd in ipairs(Wizard.whatToSyncRows(state)) do
                items[#items + 1] = {
                    type    = "check_row",
                    text    = rd.label,
                    sub     = rd.desc,
                    checked = rd.checked,
                    on_tap  = function() render(spec.on_toggle(rd.key)) end,
                }
            end
            items[#items + 1] = {
                type  = "note",
                title = spec.reassurance.title,
                body  = spec.reassurance.body,
            }
            local footer = {}
            if spec.on_back then
                footer[#footer + 1] = { label = _("Back"), on_tap = spec.on_back }
            end
            footer[#footer + 1] = {
                label  = _("Next"),
                on_tap = function() spec.on_choice(state) end,
            }
            show_panel{
                title      = spec.header.title,
                subtitle   = spec.header.subtitle,
                items      = items,
                footer     = footer,
                on_dismiss = wrap_dismiss(function() spec.on_dismiss() end),
            }
        end
        render(spec.state)
    end

    local function present_done(spec)
        local items = {
            { type = "recap_line", text = spec.transport_line, sub = spec.note },
            { type = "recap_line", text = spec.summary },
            { type = "recap_line", text = spec.device_line },
        }
        local footer = {}
        if spec.on_back then
            footer[#footer + 1] = { label = _("Back"), on_tap = spec.on_back }
        end
        footer[#footer + 1] = {
            label  = _("Done"),
            on_tap = function() finish_window(); spec.on_choice() end,
        }
        show_panel{
            title      = spec.header.title,
            items      = items,
            footer     = footer,
            on_dismiss = wrap_dismiss(spec.on_dismiss),
        }
    end

    -- The two text steps: a KOReader InputDialog shown on top of the window
    -- (system keyboard handled by InputDialog). Back returns to the previous
    -- step (which refreshes the window underneath); the primary button feeds
    -- the typed text to the controller.
    local function present_input(spec, primary_label)
        -- Close the panel, then paint a bare white full-screen backdrop so the
        -- wizard's white background persists behind the InputDialog while the
        -- keyboard is up (the dialog does not cover the whole screen, and the
        -- panel is closed so two windows do not overlap).  The backdrop carries
        -- no input -- the InputDialog on top owns interaction -- and is torn
        -- down together with the dialog on Back / primary.
        close_window()
        show_backdrop()
        local dlg
        dlg = W.InputDialog:new{
            title       = spec.header.title,
            description = block(spec.header.subtitle, spec.note),
            input       = spec.default,
            input_type  = "string",
            buttons     = {{
                {
                    text     = _("Back"),
                    callback = function()
                        W.UIManager:close(dlg)
                        close_backdrop()
                        if spec.on_back then spec.on_back() end
                    end,
                },
                {
                    text             = primary_label,
                    is_enter_default = true,
                    callback         = function()
                        local text = dlg:getInputText()
                        W.UIManager:close(dlg)
                        close_backdrop()
                        spec.on_choice(text)
                    end,
                },
            }},
        }
        W.UIManager:show(dlg)
        if dlg.onShowKeyboard then dlg:onShowKeyboard() end
    end

    deps.present_step = function(spec)
        if spec.kind == Wizard.STEP.TRANSPORT then
            present_transport(spec)
        elseif spec.kind == Wizard.STEP.SYNCTHING_API then
            present_input(spec, _("Test connection"))
        elseif spec.kind == Wizard.STEP.WHAT then
            present_what(spec)
        elseif spec.kind == Wizard.STEP.LABEL then
            present_input(spec, _("Next"))
        elseif spec.kind == Wizard.STEP.DONE then
            present_done(spec)
        end
    end

    return deps
end


return Presenter
