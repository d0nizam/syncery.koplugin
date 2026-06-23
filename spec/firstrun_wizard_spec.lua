-- =============================================================================
-- spec/firstrun_wizard_spec.lua
-- =============================================================================
--
-- The PURE LOGIC of the first-run wizard (syncery_ui/wizard.lua), flow per
-- the locked redesign. No UI here: step ordering, the transport /
-- what-to-sync choices, the settings-write mapping, the recap builders and
-- the user-visible text.
--
-- Locks that matter beyond plain coverage:
--   1. The transport step is ALWAYS present (the old KOSyncthing+-skip left
--      use_syncthing false — bug F1). A regression that re-adds the skip
--      fails here.
--   2. Replace-semantics: re-choosing the transport lowers ONLY the flag
--      this run raised.
--   3. The what-to-sync state maps to the VERIFIED consent keys
--      (syncery_sync_progress / syncery_sync_annotations) — catches drift.
--   4. TEXT AUDIT: the reassurance copy carries NO digits — the design
--      forbids invented annotation counts.
-- =============================================================================


local h = require("spec.test_helpers")


-- Deterministic i18n: identity translate, independent of any stub a
-- previously-run spec may have left in package.loaded. Then load the
-- module under test fresh so it binds to this stub.
package.loaded["syncery_i18n"] = {
    translate = function(s) return s end,
    ngettext  = function(s, p, n) if n == 1 then return s else return p end end,
}
package.loaded["syncery_ui/wizard"] = nil
local Wizard = require("syncery_ui/wizard")


-- ---------------------------------------------------------------------------
-- shouldRun — the single "show once" gate is the firstrun-done flag.
-- ---------------------------------------------------------------------------
do
    h.assert_true(Wizard.shouldRun(false),
        "shouldRun: runs when first-run is not yet done")
    h.assert_true(Wizard.shouldRun(nil),
        "shouldRun: a nil/unset flag counts as not-done -> runs")
    h.assert_false(Wizard.shouldRun(true),
        "shouldRun: does NOT run once first-run is done")
end


-- ---------------------------------------------------------------------------
-- stepOrder — transport is ALWAYS first (never skipped); the syncthing_api
-- sub-step appears only for a Syncthing pick without KOSyncthing+; done always last.
-- ---------------------------------------------------------------------------
do
    local with_auto = Wizard.stepOrder({ api_key_autodetectable = true })
    h.assert_deep_equal(with_auto, { "transport", "what", "label", "done" },
        "stepOrder: key auto-detectable -> transport step PRESENT (F1: never skipped)")

    local no_auto = Wizard.stepOrder({ api_key_autodetectable = false })
    h.assert_deep_equal(no_auto, { "transport", "what", "label", "done" },
        "stepOrder: not auto-detectable, no pick yet -> the four base steps")

    local default = Wizard.stepOrder()
    h.assert_deep_equal(default, { "transport", "what", "label", "done" },
        "stepOrder: no opts -> the four base steps")

    local st_manual = Wizard.stepOrder({ transport = "syncthing", api_key_autodetectable = false })
    h.assert_deep_equal(st_manual,
        { "transport", "syncthing_api", "what", "label", "done" },
        "stepOrder: syncthing, key NOT auto-detectable -> API sub-step inserted after transport")

    local st_auto = Wizard.stepOrder({ transport = "syncthing", api_key_autodetectable = true })
    h.assert_deep_equal(st_auto, { "transport", "what", "label", "done" },
        "stepOrder: syncthing, key auto-detectable -> no API sub-step (KOSyncthing+ or config.xml)")

    local cloud = Wizard.stepOrder({ transport = "cloud", api_key_autodetectable = false })
    h.assert_deep_equal(cloud, { "transport", "what", "label", "done" },
        "stepOrder: cloud -> no API sub-step")

    h.assert_equal(st_manual[#st_manual], "done",
        "stepOrder: done is always the last step")
    h.assert_equal(Wizard.STEP.DONE, "done", "STEP.DONE id is stable")
    h.assert_equal(Wizard.STEP.SYNCTHING_API, "syncthing_api",
        "STEP.SYNCTHING_API id is stable")
end


-- ---------------------------------------------------------------------------
-- Transport choices — three ids including the explicit "later"; KOSyncthing+
-- only ENRICHES the Syncthing row (label + description), id unchanged.
-- ---------------------------------------------------------------------------
do
    for _, kosyncthing in ipairs({ false, true }) do
        local choices = Wizard.transportChoices(kosyncthing)
        h.assert_equal(#choices, 3,
            "transportChoices(kosyncthing=" .. tostring(kosyncthing) .. "): exactly three options")
        local by_id = {}
        for _, c in ipairs(choices) do
            by_id[c.id] = c
            h.assert_true(type(c.label) == "string" and #c.label > 0,
                "transportChoices: '" .. tostring(c.id) .. "' has a label")
            h.assert_true(type(c.desc) == "string" and #c.desc > 0,
                "transportChoices: '" .. tostring(c.id) .. "' has a description")
        end
        h.assert_true(by_id.syncthing ~= nil, "transportChoices: includes syncthing")
        h.assert_true(by_id.cloud     ~= nil, "transportChoices: includes cloud")
        h.assert_true(by_id.later     ~= nil, "transportChoices: includes 'decide later'")
    end

    local plain = Wizard.transportChoices(false)[1]
    h.assert_equal(plain.label, "Syncthing",
        "transportChoices: no KOSyncthing+ -> row named plain 'Syncthing'")
    h.assert_equal(plain.desc, "Private file sync",
        "transportChoices: no KOSyncthing+ -> 'Private file sync' description")

    local kosyncthing_row = Wizard.transportChoices(true)[1]
    h.assert_equal(kosyncthing_row.id, "syncthing",
        "transportChoices: KOSyncthing+ row keeps the 'syncthing' id (same transport)")
    h.assert_equal(kosyncthing_row.label, "KOSyncthing+",
        "transportChoices: KOSyncthing+ detected -> row named 'KOSyncthing+'")
    h.assert_true(kosyncthing_row.desc:find("detected", 1, true) ~= nil,
        "transportChoices: KOSyncthing+ description says it was detected")
end


-- ---------------------------------------------------------------------------
-- normalizeTransport — real transports resolve to a name; "later"/unknown
-- resolve to no transport.
-- ---------------------------------------------------------------------------
do
    h.assert_equal(Wizard.normalizeTransport("syncthing").transport, "syncthing",
        "normalizeTransport: syncthing")
    h.assert_equal(Wizard.normalizeTransport("cloud").transport, "cloud",
        "normalizeTransport: cloud")
    h.assert_nil(Wizard.normalizeTransport("later").transport,
        "normalizeTransport: 'later' selects no transport")
    h.assert_nil(Wizard.normalizeTransport("nonsense").transport,
        "normalizeTransport: unknown id selects no transport")
end


-- ---------------------------------------------------------------------------
-- What-to-sync rows reflect the supplied state.
-- ---------------------------------------------------------------------------
do
    local rows = Wizard.whatToSyncRows({ progress = true, annotations = false })
    h.assert_equal(#rows, 2, "whatToSyncRows: exactly two toggles (progress + annotations)")
    h.assert_equal(rows[1].key, "progress",    "whatToSyncRows: row 1 is progress")
    h.assert_equal(rows[2].key, "annotations", "whatToSyncRows: row 2 is annotations")
    h.assert_true(rows[1].checked,  "whatToSyncRows: progress reflects checked=true")
    h.assert_false(rows[2].checked, "whatToSyncRows: annotations reflects checked=false")

    local off = Wizard.whatToSyncRows(nil)
    h.assert_false(off[1].checked, "whatToSyncRows: nil state -> progress off")
    h.assert_false(off[2].checked, "whatToSyncRows: nil state -> annotations off")
end


-- ---------------------------------------------------------------------------
-- toggleWhat flips one key and is immutable (does not mutate the input).
-- ---------------------------------------------------------------------------
do
    local start_state = { progress = false, annotations = false }
    local after = Wizard.toggleWhat(start_state, "progress")
    h.assert_true(after.progress,  "toggleWhat: progress flipped on")
    h.assert_false(after.annotations, "toggleWhat: annotations untouched")
    h.assert_false(start_state.progress,
        "toggleWhat: input state is NOT mutated (returns a new table)")

    local back = Wizard.toggleWhat(after, "progress")
    h.assert_false(back.progress, "toggleWhat: flipping again toggles back off")

    local ignored = Wizard.toggleWhat(start_state, "metadata")
    h.assert_false(ignored.progress, "toggleWhat: unknown key changes nothing")
    h.assert_false(ignored.annotations, "toggleWhat: unknown key changes nothing")
end


-- ---------------------------------------------------------------------------
-- whatToSyncWrites maps onto the VERIFIED consent setting keys.
-- ---------------------------------------------------------------------------
do
    local on = Wizard.whatToSyncWrites({ progress = true, annotations = true })
    h.assert_equal(on.syncery_sync_progress, true,
        "whatToSyncWrites: progress -> syncery_sync_progress=true")
    h.assert_equal(on.syncery_sync_annotations, true,
        "whatToSyncWrites: annotations -> syncery_sync_annotations=true")

    local off = Wizard.whatToSyncWrites({ progress = false, annotations = false })
    h.assert_equal(off.syncery_sync_progress, false,
        "whatToSyncWrites: off -> syncery_sync_progress=false")
    h.assert_equal(off.syncery_sync_annotations, false,
        "whatToSyncWrites: off -> syncery_sync_annotations=false")

    local nilstate = Wizard.whatToSyncWrites(nil)
    h.assert_equal(nilstate.syncery_sync_progress, false,
        "whatToSyncWrites: nil state -> progress key false (consent-first)")
    h.assert_equal(nilstate.syncery_sync_annotations, false,
        "whatToSyncWrites: nil state -> annotations key false")
end


-- ---------------------------------------------------------------------------
-- Step headers. Transport has NO subtitle by design (the old one described
-- the removed KOSyncthing+ skip); the what subtitle references the menu row by its
-- REAL name; the API sub-step has a header + the folder note carries no
-- manual folder-ID instruction.
-- ---------------------------------------------------------------------------
do
    for _, sid in ipairs({ "transport", "syncthing_api", "what", "label", "done" }) do
        local hdr = Wizard.stepHeader(sid)
        h.assert_true(type(hdr.title) == "string" and #hdr.title > 0,
            "stepHeader: '" .. sid .. "' has a title")
    end

    local t_hdr = Wizard.stepHeader("transport")
    h.assert_true(t_hdr.title:find("want", 1, true) ~= nil,
        "stepHeader: transport title is the locked 'How do you want…' wording")
    h.assert_nil(t_hdr.subtitle,
        "stepHeader: transport has NO subtitle (the KOSyncthing+-skip text is gone)")

    local what_hdr = Wizard.stepHeader("what")
    h.assert_true(what_hdr.subtitle:find("What's synced", 1, true) ~= nil,
        "stepHeader: 'what' subtitle references the REAL menu row name (F2)")
    h.assert_nil(what_hdr.subtitle:find("consent-first", 1, true),
        "stepHeader: the '(consent-first)' jargon is gone")

    local api_hdr = Wizard.stepHeader("syncthing_api")
    h.assert_true(api_hdr.subtitle:find("API Key", 1, true) ~= nil,
        "stepHeader: API sub-step says where to find the key")
    h.assert_nil(api_hdr.subtitle:find("empty", 1, true),
        "stepHeader: the misleading 'Leave empty…' advice is gone (F4)")

    h.assert_nil(Wizard.stepHeader("done").subtitle,
        "stepHeader: done step has no static subtitle (recap is dynamic)")

    local note = Wizard.apiFolderNote()
    h.assert_true(note:find("menu", 1, true) ~= nil,
        "apiFolderNote: points the folder pick at the menu (no manual ID)")
end


-- ---------------------------------------------------------------------------
-- Reassurance text: trimmed body, NO digits (no invented counts), and the
-- old "nothing is lost" tail is gone. The removed metadata pointer stays
-- removed.
-- ---------------------------------------------------------------------------
do
    local r_title = Wizard.reassuranceTitle()
    local r_body  = Wizard.reassuranceBody()
    h.assert_true(type(r_title) == "string" and #r_title > 0,
        "reassuranceTitle: non-empty")
    h.assert_true(type(r_body) == "string" and #r_body > 0,
        "reassuranceBody: non-empty")
    h.assert_nil(r_body:find("nothing is lost", 1, true),
        "reassuranceBody: the approved trim removed the tail")
    h.assert_nil(r_title:match("%d"),
        "TEXT AUDIT: reassurance title has no digits (no invented counts)")
    h.assert_nil(r_body:match("%d"),
        "TEXT AUDIT: reassurance body has no digits (no invented counts)")

    h.assert_nil(Wizard.metadataPointerText,
        "metadataPointerText is removed (its 'Settings ->' path was false — F2)")
end


-- ---------------------------------------------------------------------------
-- Done summary — lists the enabled types with the menu's ' · ' joiner, or
-- says "nothing yet". Carries no digits.
-- ---------------------------------------------------------------------------
do
    local both = Wizard.doneSummary({ progress = true, annotations = true })
    h.assert_true(both:find("progress", 1, true) ~= nil,
        "doneSummary: mentions progress when on")
    h.assert_true(both:find("annotations", 1, true) ~= nil,
        "doneSummary: mentions annotations when on")
    h.assert_true(both:find(" · ", 1, true) ~= nil,
        "doneSummary: uses the menu's ' · ' joiner (unified)")

    local one = Wizard.doneSummary({ progress = true, annotations = false })
    h.assert_true(one:find("progress", 1, true) ~= nil,
        "doneSummary: mentions the one enabled type")
    h.assert_nil(one:find("annotations", 1, true),
        "doneSummary: omits the disabled type")

    h.assert_true(Wizard.doneSummary(nil):find("nothing", 1, true) ~= nil,
        "doneSummary: nil state -> 'nothing yet' wording")
    h.assert_nil(both:match("%d"),
        "TEXT AUDIT: done summary has no digits (no invented counts)")

    local labels = Wizard.enabledLabels({ progress = true, annotations = true })
    h.assert_deep_equal(labels, { "progress", "annotations" },
        "enabledLabels: both on, in order")
end


-- ---------------------------------------------------------------------------
-- Recap builders (step 4). Per-path note: KOSyncthing+ -> nil; plain syncthing ->
-- the folder note; cloud -> the existing Transports pointer; none -> the honest
-- local-journaling note. Display label mirrors what the user tapped.
-- ---------------------------------------------------------------------------
do
    h.assert_equal(Wizard.transportDisplayLabel("syncthing", true), "KOSyncthing+",
        "transportDisplayLabel: syncthing + KOSyncthing+ -> 'KOSyncthing+'")
    h.assert_equal(Wizard.transportDisplayLabel("syncthing", false), "Syncthing",
        "transportDisplayLabel: syncthing, no KOSyncthing+")
    h.assert_equal(Wizard.transportDisplayLabel("cloud", false), "Cloud",
        "transportDisplayLabel: cloud")
    h.assert_equal(Wizard.transportDisplayLabel(nil, false), "Decide later",
        "transportDisplayLabel: no transport -> 'Decide later'")

    h.assert_true(Wizard.recapTransportLine("cloud", false)
            :find("Transport:", 1, true) ~= nil,
        "recapTransportLine: uses the 'Transport: %s' format")

    -- Every Syncthing path now points to the folder picker (KOSyncthing+
    -- auto-adopts only a sole folder; with several, or for config.xml/manual,
    -- the user picks).  The note is the same regardless of KOSyncthing+, and
    -- worded conditionally so a single folder reads it as not-applicable.
    local sf = Wizard.recapNote("syncthing")
    h.assert_true(sf:find("folder", 1, true) ~= nil
            and sf:find("Transports", 1, true) ~= nil,
        "recapNote: syncthing -> choose-folder note under Transports (always)")
    h.assert_true(sf:find("more than one", 1, true) ~= nil,
        "recapNote: wording is conditional on multiple folders (non-redundant for one)")
    local cl = Wizard.recapNote("cloud")
    h.assert_true(cl:find("Cloud", 1, true) ~= nil
            and cl:find("Transports", 1, true) ~= nil,
        "recapNote: cloud -> finish-setup pointer under Transports")
    h.assert_true(Wizard.recapNote(nil):find("locally", 1, true) ~= nil,
        "recapNote: no transport -> the honest local-journaling note")

    h.assert_true(Wizard.recapDeviceLine("Kobo"):find("Kobo", 1, true) ~= nil,
        "recapDeviceLine: carries the device label")

    h.assert_nil(Wizard.transportSetupPointer,
        "transportSetupPointer is removed (replaced by recapNote)")
    h.assert_nil(Wizard.doneToast,
        "doneToast is removed (the recap screen IS the confirmation)")
end


-- ===========================================================================
-- Controller — Wizard.run(deps) with a fake presenter.
-- ===========================================================================
--
-- The fake presenter records which steps were shown and drives the chain by
-- invoking the scripted response (on_choice / on_dismiss / on_back) for each
-- step. `rec` captures every persistence side effect.

local UNSET = {}  -- sentinel: "save_transport never called" vs nil

local function run_with(opts)
    local rec = {
        presented       = {},
        saved_what      = nil,
        saved_transport = UNSET,
        lowered         = {},
        saved_label     = nil,
        saved_api       = nil,
        api_tests       = 0,
        done_count      = 0,
        done_spec       = nil,
    }
    local deps = {
        firstrun_done     = function() return opts.firstrun_done == true end,
        set_firstrun_done = function() rec.done_count = rec.done_count + 1 end,
        kosyncthing_detected     = function() return opts.kosyncthing == true end,
        config_xml_key_available = function() return opts.config_xml_key == true end,
        current_what      = function()
            return opts.current_what or { progress = false, annotations = false }
        end,
        save_what       = function(w) rec.saved_what = w end,
        save_transport  = function(t) rec.saved_transport = t end,
        lower_transport = function(t) rec.lowered[#rec.lowered + 1] = t end,
        get_syncthing_api_default = function() return opts.api_default or "" end,
        save_syncthing_api_key    = function(k) rec.saved_api = k end,
        run_api_test              = function() rec.api_tests = rec.api_tests + 1 end,
        get_label_default = function() return opts.label_default or "Model" end,
        save_label        = function(l) rec.saved_label = l end,
        present_step      = function(spec)
            rec.presented[#rec.presented + 1] = spec.kind
            if spec.kind == "done" then rec.done_spec = spec end
            opts.respond(spec, rec)
        end,
    }
    Wizard.run(deps)
    return rec
end


-- Full happy path, NO KOSyncthing+, Syncthing chosen: the API sub-step appears.
do
    local rec = run_with({
        kosyncthing = false,
        respond = function(spec)
            if spec.kind == "transport" then
                spec.on_choice("syncthing")
            elseif spec.kind == "syncthing_api" then
                spec.on_choice("  ABC123  ")   -- trimmed before save
            elseif spec.kind == "what" then
                spec.on_choice({ progress = true, annotations = true })
            elseif spec.kind == "label" then
                spec.on_choice("My Kobo")
            elseif spec.kind == "done" then
                spec.on_choice()
            end
        end,
    })
    h.assert_deep_equal(rec.presented,
        { "transport", "syncthing_api", "what", "label", "done" },
        "run: Syncthing without KOSyncthing+ -> API sub-step between transport and what")
    h.assert_equal(rec.saved_transport, "syncthing",
        "run: transport choice persisted (raises the flag)")
    h.assert_equal(rec.saved_api, "ABC123",
        "run: API key trimmed and persisted")
    h.assert_equal(rec.api_tests, 1,
        "run: the async connection test fired once")
    h.assert_equal(rec.saved_what.syncery_sync_progress, true,
        "run: progress consent persisted")
    h.assert_equal(rec.saved_label, "My Kobo",
        "run: device label persisted")
    h.assert_true(rec.done_count >= 1,
        "run: completion persists firstrun_done")
    h.assert_true(rec.done_spec.transport_line:find("Syncthing", 1, true) ~= nil,
        "run: recap transport line names the chosen transport")
    h.assert_true(rec.done_spec.note:find("folder", 1, true) ~= nil,
        "run: no-KOSyncthing+ recap note points at the folder pick")
    h.assert_true(rec.done_spec.device_line:find("My Kobo", 1, true) ~= nil
            or rec.done_spec.device_line:find("Model", 1, true) ~= nil,
        "run: recap carries a device-name line")
end


-- Empty API key: nothing saved, no test, but the wizard advances.
do
    local rec = run_with({
        kosyncthing = false,
        respond = function(spec)
            if spec.kind == "transport" then spec.on_choice("syncthing")
            elseif spec.kind == "syncthing_api" then spec.on_choice("   ")
            elseif spec.kind == "what" then spec.on_choice(nil)
            elseif spec.kind == "label" then spec.on_choice("")
            elseif spec.kind == "done" then spec.on_choice() end
        end,
    })
    h.assert_nil(rec.saved_api, "run: whitespace API key is not saved")
    h.assert_equal(rec.api_tests, 0, "run: no test without a key")
    h.assert_true(rec.done_count >= 1, "run: empty-key path still completes")
end


-- KOSYNCTHING+ path: transport step PRESENT (the F1 inversion); choosing Syncthing
-- raises the flag and SKIPS the API sub-step; the recap has no pending note
-- and names "KOSyncthing+".
do
    local rec = run_with({
        kosyncthing = true,
        respond = function(spec)
            if spec.kind == "transport" then
                spec.on_choice("syncthing")
            elseif spec.kind == "what" then
                spec.on_choice({ progress = false, annotations = true })
            elseif spec.kind == "label" then
                spec.on_choice("")          -- empty -> label not saved
            elseif spec.kind == "done" then
                spec.on_choice()
            end
        end,
    })
    h.assert_deep_equal(rec.presented, { "transport", "what", "label", "done" },
        "run: KOSyncthing+ detected -> transport step PRESENT, API sub-step skipped")
    h.assert_equal(rec.saved_transport, "syncthing",
        "run: KOSyncthing+ path RAISES use_syncthing (the F1 fix)")
    h.assert_equal(rec.saved_what.syncery_sync_annotations, true,
        "run: KOSyncthing+ path still captures consent")
    h.assert_nil(rec.saved_label,
        "run: empty label input is not saved")
    h.assert_true(rec.done_spec.note ~= nil
            and rec.done_spec.note:find("folder", 1, true) ~= nil,
        "run: KOSyncthing+ path recap now nudges toward the folder picker")
    h.assert_true(rec.done_spec.transport_line:find("KOSyncthing+", 1, true) ~= nil,
        "run: KOSyncthing+ recap names 'KOSyncthing+'")
end


-- A config.xml-readable run (no KOSyncthing+): the API sub-step is skipped just
-- like the KOSyncthing+ case, but via the broader auto-detect signal.  The row
-- still reads "Syncthing" (KOSyncthing+ absent) and the recap nudges to the
-- folder picker.
do
    local rec = run_with({
        kosyncthing    = false,
        config_xml_key = true,
        respond = function(spec)
            if spec.kind == "transport" then
                spec.on_choice("syncthing")
            elseif spec.kind == "what" then
                spec.on_choice({ progress = true, annotations = false })
            elseif spec.kind == "label" then
                spec.on_choice("")
            elseif spec.kind == "done" then
                spec.on_choice()
            end
        end,
    })
    h.assert_deep_equal(rec.presented, { "transport", "what", "label", "done" },
        "run: config.xml key auto-detected -> API sub-step skipped (no KOSyncthing+)")
    h.assert_equal(rec.saved_transport, "syncthing",
        "run: config.xml path still raises use_syncthing")
    h.assert_true(rec.done_spec.transport_line:find("Syncthing", 1, true) ~= nil,
        "run: config.xml recap row reads 'Syncthing' (not KOSyncthing+)")
end


-- Label trim: whitespace-padded input is saved trimmed; whitespace-only is
-- treated as empty (the default silently stays).
do
    local rec = run_with({
        kosyncthing = true,
        respond = function(spec)
            if spec.kind == "transport" then spec.on_choice("later")
            elseif spec.kind == "what" then spec.on_choice(nil)
            elseif spec.kind == "label" then spec.on_choice("  Bedside Kobo  ")
            elseif spec.kind == "done" then spec.on_choice() end
        end,
    })
    h.assert_equal(rec.saved_label, "Bedside Kobo",
        "run: label is trimmed before saving")

    local rec2 = run_with({
        kosyncthing = true,
        respond = function(spec)
            if spec.kind == "transport" then spec.on_choice("later")
            elseif spec.kind == "what" then spec.on_choice(nil)
            elseif spec.kind == "label" then spec.on_choice("   ")
            elseif spec.kind == "done" then spec.on_choice() end
        end,
    })
    h.assert_nil(rec2.saved_label,
        "run: whitespace-only label behaves as empty (not saved)")
end


-- Replace-semantics via Back: Syncthing -> Back -> Cloud lowers ONLY the
-- flag this run raised, then raises the new one.
do
    local first_pick = true
    local rec = run_with({
        kosyncthing = false,
        respond = function(spec)
            if spec.kind == "transport" then
                if first_pick then
                    first_pick = false
                    spec.on_choice("syncthing")
                else
                    spec.on_choice("cloud")
                end
            elseif spec.kind == "syncthing_api" then
                spec.on_back()              -- user changes their mind
            elseif spec.kind == "what" then
                spec.on_choice(nil)
            elseif spec.kind == "label" then
                spec.on_choice("")
            elseif spec.kind == "done" then
                spec.on_choice()
            end
        end,
    })
    h.assert_deep_equal(rec.presented,
        { "transport", "syncthing_api", "transport", "what", "label", "done" },
        "run: Back from the API step returns to transport; cloud path follows")
    h.assert_deep_equal(rec.lowered, { "syncthing" },
        "run: re-choice lowers ONLY the flag this run raised")
    h.assert_equal(rec.saved_transport, "cloud",
        "run: the new pick is raised")
    h.assert_true(rec.done_spec.note:find("Cloud", 1, true) ~= nil,
        "run: recap note follows the FINAL pick (cloud)")
end


-- Replace-semantics to "later": the raised flag is lowered, nothing new
-- raised, and the recap carries the honest local-journaling note.
do
    local first_pick = true
    local went_back  = false
    local rec = run_with({
        kosyncthing = true,
        respond = function(spec)
            if spec.kind == "transport" then
                if first_pick then
                    first_pick = false
                    spec.on_choice("syncthing")
                else
                    spec.on_choice("later")
                end
            elseif spec.kind == "what" then
                if not went_back then
                    went_back = true
                    spec.on_back()
                else
                    spec.on_choice(nil)
                end
            elseif spec.kind == "label" then
                spec.on_choice("")
            elseif spec.kind == "done" then
                spec.on_choice()
            end
        end,
    })
    h.assert_deep_equal(rec.lowered, { "syncthing" },
        "run: switching to 'later' lowers the raised flag")
    h.assert_equal(rec.saved_transport, "syncthing",
        "run: save_transport was last called with the original raise (later saves nothing)")
    h.assert_true(rec.done_spec.note:find("locally", 1, true) ~= nil,
        "run: 'later' recap carries the honest local-journaling note")
    h.assert_true(rec.done_spec.transport_line:find("Decide later", 1, true) ~= nil,
        "run: 'later' recap transport line says 'Decide later'")
end


-- Back availability: none on the first step; present afterwards.
do
    run_with({
        kosyncthing = false,
        respond = function(spec)
            if spec.kind == "transport" then
                h.assert_nil(spec.on_back,
                    "run: the FIRST step has no Back")
                spec.on_choice("later")
            elseif spec.kind == "what" then
                h.assert_true(type(spec.on_back) == "function",
                    "run: later steps expose on_back")
                spec.on_dismiss()
            end
        end,
    })
end


-- Already done: run is a no-op (no step shown, nothing persisted).
do
    local rec = run_with({
        firstrun_done = true,
        respond = function() error("present_step must not be called when already done") end,
    })
    h.assert_deep_equal(rec.presented, {},
        "run: firstrun already done -> no steps shown")
    h.assert_equal(rec.done_count, 0,
        "run: already-done run touches nothing")
end


-- Dismiss at the very first step still marks done (no re-nag).
do
    local rec = run_with({
        kosyncthing = false,
        respond = function(spec)
            if spec.kind == "transport" then spec.on_dismiss() end
        end,
    })
    h.assert_deep_equal(rec.presented, { "transport" },
        "run: dismissing step 1 stops the chain")
    h.assert_true(rec.done_count >= 1,
        "run: dismissal persists firstrun_done so the wizard never re-nags")
end


-- Dismiss at the "what" step persists whatever was toggled, then marks done.
do
    local rec = run_with({
        kosyncthing = true,
        respond = function(spec)
            if spec.kind == "transport" then
                spec.on_choice("later")
            elseif spec.kind == "what" then
                local s = spec.on_toggle("progress")
                h.assert_true(s.progress, "run: on_toggle returns the new state")
                spec.on_dismiss()
            end
        end,
    })
    h.assert_deep_equal(rec.presented, { "transport", "what" },
        "run: dismiss at 'what' stops the chain there")
    h.assert_equal(rec.saved_what.syncery_sync_progress, true,
        "run: a toggle made before dismissing is still persisted")
    h.assert_true(rec.done_count >= 1, "run: dismiss at 'what' marks done")
end


-- ===========================================================================
-- main.lua wiring + text audit.
-- ===========================================================================
do
    local f = io.open("main.lua", "r") or io.open("../main.lua", "r")
    h.assert_true(f ~= nil, "text-audit: could open main.lua")
    local src = f and f:read("*a") or ""
    if f then f:close() end

    h.assert_true(src:find("WizardPresenter.makeDeps", 1, true) ~= nil,
        "wiring: maybeShowFirstRunDialog builds wizard deps via the presenter")
    h.assert_true(src:find("Wizard.run(deps)", 1, true) ~= nil,
        "wiring: maybeShowFirstRunDialog runs the wizard controller")
    h.assert_true(src:find("save_syncthing_api_key", 1, true) ~= nil,
        "wiring: the inline API-key sub-step is plumbed (Settings-backed)")
    h.assert_true(src:find("test_syncthing", 1, true) ~= nil,
        "wiring: the async connection test is plumbed (menu helper)")

    -- Stale legacy device-name-only dialog text is GONE from main.lua.
    h.assert_nil(src:find("whose progress is whose on other devices", 1, true),
        "text-audit: legacy first-run dialog description removed from main.lua")
    h.assert_nil(src:find("Name this device\"", 1, true),
        "text-audit: legacy 'Name this device' dialog title removed from main.lua")
    h.assert_nil(src:find("current_label ~= default_model", 1, true),
        "gate B: the label-based first-run skip is removed (firstrun flag is the sole gate)")
end
