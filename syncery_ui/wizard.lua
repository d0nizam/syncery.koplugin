-- =============================================================================
-- syncery_ui/wizard.lua
-- =============================================================================
--
-- First-run wizard — PURE LOGIC ONLY.
--
-- This module owns the *decisions and text* of the first-run wizard, with
-- NO dependency on UIManager, widgets or G_reader_settings. That keeps it
-- fully unit-testable in the headless harness (the matrix exercises it),
-- and lets a thin UI layer (wizard_presenter.lua) turn each step into the
-- actual KOReader widgets:
--
--   step "transport"     -> choice rows (Syncthing[/KOSyncthing+] / Cloud / later)
--   step "syncthing_api" -> InputDialog (API key; only when Syncthing is
--                           chosen and no kosyncthing_plus is detected)
--   step "what"          -> two toggles (progress / annotations)
--   step "label"         -> InputDialog (device name)
--   step "done"          -> RECAP of the choices (transport / what / name)
--
-- DESIGN CONTRACT (the locked redesign is binding):
--   * A short wizard runs ALWAYS at first start, because consent-first
--     defaults are OFF — a silent first run would sync nothing.
--   * The transport step is ALWAYS shown. A detected kosyncthing_plus only
--     enriches the Syncthing row (name + description); it never skips the
--     step — KOSyncthing+ presence is not KOSyncthing+ desire, and the old skip left
--     `use_syncthing` false (bug F1).
--   * Choosing a transport raises its use_* flag; re-choosing within the
--     same run REPLACES (lowers only the flag THIS run raised — never a
--     flag set from the menu, where both transports may legitimately
--     coexist).
--   * Back is available on every step after the first.
--   * The full menu appears at wizard "done" (NOT after first sync).
--
-- All user-visible strings go through `_()` here; the Bulgarian
-- translations live in locale/bg.po, not in code.
-- =============================================================================


local I18n = require("syncery_i18n")
local _    = I18n.translate


local Wizard = {}


-- Canonical step ids. "what", "label" and "done" always run; "transport"
-- always runs too (never skipped); "syncthing_api" is inserted only when
-- Syncthing is chosen WITHOUT a detected KOSyncthing+ (see stepOrder).
Wizard.STEP = {
    TRANSPORT     = "transport",
    SYNCTHING_API = "syncthing_api",
    WHAT          = "what",
    LABEL         = "label",
    DONE          = "done",
}


-- Local whitespace trim (pure; this module deliberately avoids requiring
-- Util). Returns "" for nil.
local function trim(s)
    if type(s) ~= "string" then return "" end
    return (s:match("^%s*(.-)%s*$"))
end


-- ---------------------------------------------------------------------------
-- Whether the wizard should run at all. The single source of "show once"
-- truth is the persisted firstrun-done flag (main.lua's `_firstrun_done`,
-- backed by `syncery_firstrun_done`). The old maybeShowFirstRunDialog also
-- short-circuited on "device already has a non-default label"; that
-- heuristic is deliberately dropped for the wizard — it would skip the
-- consent step (what-to-sync) for anyone who had merely renamed a device,
-- leaving them syncing nothing. So: run iff first-run is not yet done.
-- ---------------------------------------------------------------------------
function Wizard.shouldRun(firstrun_done)
    return not firstrun_done
end


-- ---------------------------------------------------------------------------
-- Ordered list of step ids for this run.
--   opts.transport     = "syncthing"|"cloud"|nil — the pick so far (nil
--                        before the transport step / for "decide later").
--   opts.api_key_autodetectable = true -> a key is auto-detectable (KOSyncthing+
--                        OR a readable config.xml), so the syncthing_api
--                        sub-step is NOT inserted.
-- The transport step is ALWAYS first (never skipped — F1); "syncthing_api"
-- appears right after it only for a Syncthing pick whose key is NOT
-- auto-detectable; "what", "label",
-- "done" always follow, "done" last. The controller recomputes the order
-- after the transport choice (transport stays index 1, so in-flight advance
-- indexes remain valid).
-- ---------------------------------------------------------------------------
function Wizard.stepOrder(opts)
    opts = opts or {}
    local steps = { Wizard.STEP.TRANSPORT }
    if opts.transport == "syncthing" and not opts.api_key_autodetectable then
        steps[#steps + 1] = Wizard.STEP.SYNCTHING_API
    end
    steps[#steps + 1] = Wizard.STEP.WHAT
    steps[#steps + 1] = Wizard.STEP.LABEL
    steps[#steps + 1] = Wizard.STEP.DONE
    return steps
end


-- ---------------------------------------------------------------------------
-- Step 1 — transport choices. Each is {id, label, desc}. "later" is an
-- explicit, valid choice (the user can set sync up from the menu later);
-- it intentionally selects no transport.
--
-- kosyncthing_detected only ENRICHES the Syncthing row (locked strings): the row
-- is named "KOSyncthing+" and its description says it was detected — but
-- the id stays "syncthing" (same transport) and the user still freely picks
-- Cloud or later.
-- ---------------------------------------------------------------------------
function Wizard.transportChoices(kosyncthing_detected)
    local syncthing
    if kosyncthing_detected then
        syncthing = { id = "syncthing",
            label = _("KOSyncthing+"),
            desc  = _("Private file sync — detected on this device") }
    else
        syncthing = { id = "syncthing",
            label = _("Syncthing"),
            desc  = _("Private file sync") }
    end
    return {
        syncthing,
        { id = "cloud",
          label = _("Cloud"),
          desc  = _("Dropbox / WebDAV / FTP") },
        { id = "later",
          label = _("Decide later"),
          desc  = _("Set this up later from the menu") },
    }
end


-- Normalize a tapped transport id into a canonical choice record. The
-- *persistence policy* (which settings keys to write, and whether to open
-- that transport's setup) is deliberately NOT decided here — it belongs to
-- the UI/wiring step. "later" and any unknown id resolve to no transport.
function Wizard.normalizeTransport(id)
    if id == "syncthing" or id == "cloud" then
        return { transport = id }
    end
    return { transport = nil }
end


-- ---------------------------------------------------------------------------
-- Step "what to sync". Only Progress + Annotations are offered here
-- (a deliberate two-toggle decision). `state` = {progress=bool,
-- annotations=bool}.
-- ---------------------------------------------------------------------------
function Wizard.whatToSyncRows(state)
    state = state or {}
    return {
        { key = "progress",
          label = _("Reading position"),
          desc  = _("How far you've read, across devices"),
          checked = state.progress == true },
        { key = "annotations",
          label = _("Annotations"),
          desc  = _("Highlights, notes and bookmarks"),
          checked = state.annotations == true },
    }
end


-- Flip one key, returning a NEW state table (never mutates the input — the
-- UI layer holds the canonical state and re-renders from the return value).
function Wizard.toggleWhat(state, key)
    state = state or {}
    local next_state = { progress = state.progress, annotations = state.annotations }
    if key == "progress" or key == "annotations" then
        next_state[key] = not (state[key] == true)
    end
    return next_state
end


-- The settings writes implied by a what-to-sync state. The UI layer applies
-- these via G_reader_settings:saveSetting and mirrors them onto the plugin
-- fields (same path as the menu's makeBoolToggle). Keys are the verified
-- consent keys read in main.lua's settings load.
function Wizard.whatToSyncWrites(state)
    state = state or {}
    return {
        syncery_sync_progress    = state.progress == true,
        syncery_sync_annotations = state.annotations == true,
    }
end


-- (The old metadataPointerText — "…live in Settings -> What's synced…" —
-- was removed: it pointed at a non-existent "Settings" level (finding F2),
-- and the new step-2 subtitle now carries the menu reference by its REAL
-- row name.)


-- Calm reassurance about pre-existing native annotations. VERIFIED FACT:
-- native KOReader annotations are read straight from doc_settings when a
-- book syncs (doc_settings_bridge) — there is no "convert" step and nothing
-- is lost. Deliberately carries NO counts: an exact number would require
-- the (separate) bulk scan, and inventing one would be dishonest.
function Wizard.reassuranceTitle()
    return _("The annotations you already have are safe")
end

function Wizard.reassuranceBody()
    return _("Syncery includes them automatically when you open the books.")
end


-- ---------------------------------------------------------------------------
-- Per-step header text. Returns {title=, subtitle=}; the "done" step's
-- subtitle is dynamic (the recap), so it is nil here.
-- ---------------------------------------------------------------------------
function Wizard.stepHeader(step_id)
    if step_id == Wizard.STEP.TRANSPORT then
        return {
            -- No subtitle by design: the title + the three rows self-explain
            -- (the old subtitle described the now-removed KOSyncthing+ skip).
            title    = _("How do you want to sync your files?"),
            subtitle = nil,
        }
    elseif step_id == Wizard.STEP.SYNCTHING_API then
        return {
            title    = _("Syncthing API key"),
            -- No "Leave empty if you don't use authentication" here: an
            -- empty key leaves the manual provider unavailable
            -- (manual_provider.get_config returns nil on empty — F4).
            subtitle = _("Find it in Syncthing → Settings → GUI → API Key."),
        }
    elseif step_id == Wizard.STEP.WHAT then
        return {
            title    = _("What should Syncery sync?"),
            subtitle = _("Turn on what you want. If you don't choose now or "
                .. "in the What's synced menu, nothing will sync."),
        }
    elseif step_id == Wizard.STEP.LABEL then
        return {
            title    = _("Name this device"),
            subtitle = _("So you know whose progress is whose. Defaults to "
                .. "the device model."),
        }
    elseif step_id == Wizard.STEP.DONE then
        return {
            title    = _("Setup complete"),
            subtitle = nil,
        }
    end
    return { title = nil, subtitle = nil }
end


-- The calm note under the API-key input: the folder is NOT typed by hand
-- here — the live picker in the menu is the real path (F5: the manual
-- folder-ID input predates the single-folder collapse).
function Wizard.apiFolderNote()
    return _("You'll choose the folder later from the menu.")
end


-- ---------------------------------------------------------------------------
-- "Done" summary. Reuses the lowercase "progress"/"annotations" msgids that
-- the smart-header already uses (main.lua menu/init.lua) so translations are
-- shared. No counts.
-- ---------------------------------------------------------------------------
function Wizard.enabledLabels(state)
    state = state or {}
    local out = {}
    if state.progress    == true then out[#out + 1] = _("progress")    end
    if state.annotations == true then out[#out + 1] = _("annotations") end
    return out
end


-- Safe single-substitution (gsub, not string.format) so a translated
-- template that drops or mangles a "%s" can never raise.
local function subst(template, value)
    return (template:gsub("%%s", value, 1))
end


function Wizard.doneSummary(state)
    local labels = Wizard.enabledLabels(state)
    if #labels == 0 then
        return _("Syncery will sync: nothing yet.")
    end
    -- " · " matches the menu's smart-header joiner (menu/init.lua).
    return subst(_("Syncery will sync: %s."), table.concat(labels, " · "))
end


-- ---------------------------------------------------------------------------
-- Recap builders (step 4). The done step is a RECAP of the choices, not a
-- bare "done": three lines (transport / what / device name) plus a per-path
-- status note under the transport line.
-- ---------------------------------------------------------------------------

-- The display label of the transport pick — the same label the user tapped
-- in step 1 ("KOSyncthing+" when the plugin is detected).
function Wizard.transportDisplayLabel(transport, kosyncthing_detected)
    if transport == "syncthing" then
        return kosyncthing_detected and _("KOSyncthing+") or _("Syncthing")
    elseif transport == "cloud" then
        return _("Cloud")
    end
    return _("Decide later")
end


function Wizard.recapTransportLine(transport, kosyncthing_detected)
    return subst(_("Transport: %s"),
        Wizard.transportDisplayLabel(transport, kosyncthing_detected))
end


-- Per-path status note under the transport line; nil when nothing is
-- pending (KOSyncthing+ path — the plugin supplies key + folder):
--   * syncthing without KOSyncthing+ — the API key was entered inline; the folder
--     pick (the live picker) remains in the menu;
--   * cloud — credentials/provider setup lives in the menu (reuses the
--     existing pointer string);
--   * no transport ("decide later") — the honest local-journaling note:
--     the DATA layer runs regardless of transport (consent flags gate the
--     JSON writes; use_* gates only the active integration — F1), so
--     nothing is lost while they decide.
function Wizard.recapNote(transport)
    if transport == "syncthing" then
        -- Always point to the folder picker.  KOSyncthing+ auto-adopts a SOLE
        -- folder (it has exactly one to pick); with several folders, or for
        -- the config.xml / manual providers, the user chooses -- so every
        -- Syncthing path gets the same nudge.  The wording is conditional on
        -- "more than one" so the common single-folder case reads it as
        -- not-applicable rather than a redundant command, with no folder-count
        -- probe needed at recap time.
        return _("If you sync more than one Syncthing folder, "
            .. "choose the right one under Transports.")
    elseif transport == "cloud" then
        return subst(_("Finish setting up %s under Transports."), _("Cloud"))
    end
    return _("Saved locally for now — your data will sync once you set up "
        .. "a transport.")
end


function Wizard.recapDeviceLine(label)
    return subst(_("Device name: %s"), tostring(label or ""))
end

-- (The old transportSetupPointer and the doneToast were removed: the recap
-- note above replaces the pointer per path, and the recap screen IS the
-- confirmation — a toast after it was a duplicate.)


-- =============================================================================
-- Controller
-- =============================================================================
--
-- `Wizard.run(deps)` drives the step sequence and decides persistence. It is
-- dependency-injected on purpose: it requires NO UIManager or widgets, so it
-- is fully unit-testable with a fake presenter. The real presenter
-- (wizard_presenter.lua) turns each step spec into KOReader widgets and
-- calls the spec's callbacks.
--
-- `deps` interface:
--   firstrun_done()        -> bool   the persisted "show once" flag
--   set_firstrun_done()             persist the flag = true (+ memory)
--   kosyncthing_detected()        -> bool   kosyncthing_plus auto-detected? (enriches
--                                    the Syncthing row; gates the API step)
--   current_what()         -> {progress=bool, annotations=bool}  prefill state
--   save_what(writes)               persist consent keys (from whatToSyncWrites)
--   save_transport(name)            raise the chosen transport's use_* flag
--   lower_transport(name)           lower a use_* flag (replace-semantics:
--                                   called ONLY for a flag THIS run raised)
--   get_syncthing_api_default() -> string   current API key (prefill)
--   save_syncthing_api_key(key)              persist the API key
--   run_api_test()                  fire the async connection test; the
--                                   result arrives as a non-blocking toast
--                                   (saved-first — the wizard advances
--                                   without waiting)
--   get_label_default()    -> string current/default device label (prefill)
--   save_label(text)                set the device label (canonical mirror)
--   present_step(spec)              show a step; must invoke spec.on_choice /
--                                   spec.on_dismiss (and may use spec.on_toggle
--                                   / spec.on_back when present)
--
-- Persistence timing & abandonment policy (locked by spec):
--   * Each step persists its own effect when the user advances (transport,
--     API key, consent, label) — so progress made is never lost.
--   * Re-choosing the transport (via Back) REPLACES: the flag THIS run
--     raised is lowered before the new one is raised. Flags set from the
--     menu are never touched (both transports may legitimately coexist
--     there).
--   * Reaching "done" persists firstrun_done; "Done" just closes.
--   * ANY terminal dismissal ALSO persists firstrun_done. This is the
--     deliberate "show at most once" guarantee: a dismissed wizard must
--     still set the flag or it would re-appear on every menu open. Whatever
--     was persisted along the way stays; the user can re-run via Reset.
-- =============================================================================
function Wizard.run(deps)
    if not Wizard.shouldRun(deps.firstrun_done()) then return end

    local kosyncthing = deps.kosyncthing_detected()
    -- The api-step-skip uses the BROADER "can we auto-detect a key?" signal:
    -- KOSyncthing+ OR a readable config.xml.  (The transport-row label and the
    -- recap stay on the narrow KOSyncthing+ flag above.)
    local api_auto = kosyncthing
        or (deps.config_xml_key_available ~= nil
            and deps.config_xml_key_available() == true)
    local order = Wizard.stepOrder({ api_key_autodetectable = api_auto })
    local state = {
        what = deps.current_what() or { progress = false, annotations = false },
        transport        = nil,  -- this run's pick (nil = none/"later")
        raised_transport = nil,  -- the use_* flag THIS run raised
    }

    local function mark_done_once()
        deps.set_firstrun_done()
    end

    -- Reaching "done" IS completion; the recap screen is the confirmation
    -- (no toast).
    local function complete()
        mark_done_once()
    end

    local advance
    advance = function(i)
        local step = order[i]
        if step == nil then return end
        -- Back is available on every step after the first.
        local on_back = (i > 1) and function() advance(i - 1) end or nil

        if step == Wizard.STEP.TRANSPORT then
            deps.present_step({
                kind      = Wizard.STEP.TRANSPORT,
                header    = Wizard.stepHeader(step),
                choices   = Wizard.transportChoices(kosyncthing),
                on_choice = function(id)
                    local norm = Wizard.normalizeTransport(id)
                    -- Replace-semantics: lower ONLY what this run raised.
                    if state.raised_transport
                            and state.raised_transport ~= norm.transport then
                        deps.lower_transport(state.raised_transport)
                        state.raised_transport = nil
                    end
                    state.transport = norm.transport
                    if norm.transport
                            and state.raised_transport ~= norm.transport then
                        deps.save_transport(norm.transport)
                        state.raised_transport = norm.transport
                    end
                    -- The pick decides whether the API sub-step exists;
                    -- transport stays index 1, so `i + 1` lands correctly.
                    order = Wizard.stepOrder({
                        transport              = norm.transport,
                        api_key_autodetectable = api_auto,
                    })
                    advance(i + 1)
                end,
                on_back    = on_back,
                on_dismiss = mark_done_once,
            })

        elseif step == Wizard.STEP.SYNCTHING_API then
            deps.present_step({
                kind      = Wizard.STEP.SYNCTHING_API,
                header    = Wizard.stepHeader(step),
                note      = Wizard.apiFolderNote(),
                default   = deps.get_syncthing_api_default(),
                on_choice = function(key)
                    key = trim(key)
                    if #key > 0 then
                        -- Saved-first: the key persists before the
                        -- async test, so an offline test loses nothing.
                        deps.save_syncthing_api_key(key)
                        deps.run_api_test()
                    end
                    advance(i + 1)
                end,
                on_back    = on_back,
                on_dismiss = mark_done_once,
            })

        elseif step == Wizard.STEP.WHAT then
            deps.present_step({
                kind        = Wizard.STEP.WHAT,
                header      = Wizard.stepHeader(step),
                rows        = Wizard.whatToSyncRows(state.what),
                state       = state.what,
                reassurance = {
                    title = Wizard.reassuranceTitle(),
                    body  = Wizard.reassuranceBody(),
                },
                -- The presenter calls this to flip a checkbox; it gets back
                -- the new state to re-render from (pure, immutable).
                on_toggle = function(key)
                    state.what = Wizard.toggleWhat(state.what, key)
                    return state.what
                end,
                on_choice = function(final_state)
                    if final_state then state.what = final_state end
                    deps.save_what(Wizard.whatToSyncWrites(state.what))
                    advance(i + 1)
                end,
                on_back    = on_back,
                on_dismiss = function()
                    -- keep whatever was toggled, then stop nagging
                    deps.save_what(Wizard.whatToSyncWrites(state.what))
                    mark_done_once()
                end,
            })

        elseif step == Wizard.STEP.LABEL then
            deps.present_step({
                kind      = Wizard.STEP.LABEL,
                header    = Wizard.stepHeader(step),
                default   = deps.get_label_default(),
                on_choice = function(label)
                    -- Trim BEFORE the non-empty check: whitespace-only
                    -- behaves as empty -> the current/default label silently
                    -- stays.
                    label = trim(label)
                    if #label > 0 then
                        deps.save_label(label)
                    end
                    advance(i + 1)
                end,
                on_back    = on_back,
                on_dismiss = mark_done_once,
            })

        elseif step == Wizard.STEP.DONE then
            deps.present_step({
                kind           = Wizard.STEP.DONE,
                header         = Wizard.stepHeader(step),
                transport_line = Wizard.recapTransportLine(state.transport, kosyncthing),
                note           = Wizard.recapNote(state.transport),
                summary        = Wizard.doneSummary(state.what),
                device_line    = Wizard.recapDeviceLine(deps.get_label_default()),
                on_back        = on_back,
                on_choice      = complete,
                on_dismiss     = complete,   -- reaching "done" IS completion
            })
        end
    end

    advance(1)
end


return Wizard
