-- =============================================================================
-- syncery_db_sync.lua
-- =============================================================================
--
-- Trigger-only orchestration for the sibling Reading Statistics and Vocabulary
-- Builder plugins.  Syncery does NOT carry or merge their SQLite DBs; it
-- dispatches each plugin's OWN declared sync action as a KOReader Event
-- (`SyncBookStats` / `SyncVocabBuilder` -- the events the plugins registerAction,
-- exactly what a user gesture triggers) on a periodic timer, when the user has
-- opted in.  See docs/STATS_VOCAB_SYNC_DESIGN.md for the full design and traces.
--
-- Two parts:
--   * DbSync.decide(opts) -- PURE: given resolved flags, returns {fire, reason}.
--   * DbSync.run(deps)    -- resolves each DB's opts from ui+settings, calls
--                            decide, and dispatches the plugin's sync on fire.
--
-- The master toggle is OFF by default; when it is OFF, run() fires nothing and
-- Syncery behaves exactly as before this feature.
--
-- Reason codes (decide) -- one of:
--   "master_off"          master toggle OFF                       (silent)
--   "subtoggle_off"       this DB's sub-toggle OFF                (silent)
--   "module_absent"       the plugin isn't loaded (ui.<mod> nil)  (silent)
--   "cloudstorage_absent" Cloud storage+ plugin disabled          (surface)
--   "no_server"           the plugin has no cloud server set      (surface)
--   "fire"                all gates passed -- dispatch the sync
-- The silent/surface split is the honesty layer's job (a later step); decide
-- only returns the code.
--
-- FTP note: there is deliberately NO ftp gate here.  FTP can't sync (the
-- KOReader ftp provider has no upload method), but that is KOReader's
-- capability limit, not Syncery's to replicate -- if an ftp server were somehow
-- configured the plugin's own sync would attempt and fail, and the pcall below
-- absorbs it.
-- =============================================================================


local DbSync = {}


-- The two DBs.  TWO DIFFERENT KEYS are needed per plugin, and conflating them
-- was a real bug:
--   * ui_key -- the key the plugin is registered under on the ReaderUI, i.e.
--     ui[ui_key].  KOReader's PluginLoader registers each plugin under its
--     DIRECTORY name minus ".koplugin" (pluginloader: plugin_name =
--     entry:sub(1, -10); readerui: registerModule(plugin_module.name, ...)), NOT
--     under the plugin's `name` field.  So vocabbuilder.koplugin is
--     ui.vocabbuilder even though its name/settings_key is "vocabulary_builder".
--     (statistics.koplugin happens to match: directory "statistics".)
--   * id -- the settings_key (the plugin's `name` field), used for
--     G_reader_settings:readSetting(id) to read its saved server, and as the
--     stable key for the report.  statistics keeps the server on
--     self.settings (the same table); vocabulary_builder keeps its settings as a
--     file-local, so the saved key is the only place both agree.
-- The server lives under a different field per plugin (sync_server vs server).
local DBS = {
    { id = "statistics",         ui_key = "statistics",   server_field = "sync_server", event = "SyncBookStats",    sub = "stats", db_file = "statistics.sqlite3" },
    { id = "vocabulary_builder", ui_key = "vocabbuilder", server_field = "server",      event = "SyncVocabBuilder", sub = "vocab", db_file = "vocabulary_builder.sqlite3" },
}
-- Exposed so the Tier 2 config-unify wiring (main.lua) can iterate the same DB
-- descriptors -- ui_key (plugin lookup), settings_key (G_reader_settings table),
-- server_field (the cloud-server field to mutate), db_file (for the `.sync` path).
DbSync.DBS = DBS


--- PURE decision.  No side effects, no I/O -- every input is in `opts`:
---   master        (bool)   master toggle
---   sub           (bool)   this DB's sub-toggle
---   mod_present   (bool)   ui.<module> ~= nil
---   cloud_present (bool)   ui.cloudstorage ~= nil
---   has_server    (bool)   the plugin has a cloud server configured
--- Returns { fire = bool, reason = <code> }.  Gate precedence is most-
--- fundamental first, so the reported reason is the one the user would act on
--- (e.g. master_off is reported even when the server is also missing -- don't
--- nag about a server when the feature itself is off).  Spacing between syncs
--- is the periodic timer's job (main.lua), not decide's -- this is a pure gate.
function DbSync.decide(opts)
    if not opts.master        then return { fire = false, reason = "master_off" } end
    if not opts.sub           then return { fire = false, reason = "subtoggle_off" } end
    if not opts.mod_present    then return { fire = false, reason = "module_absent" } end
    if not opts.cloud_present  then return { fire = false, reason = "cloudstorage_absent" } end
    if not opts.has_server     then return { fire = false, reason = "no_server" } end
    return { fire = true, reason = "fire" }
end


--- Does the plugin have a cloud server configured?  `gset` is the
--- G_reader_settings-shaped backend (injected); reads the plugin's saved key.
local function plugin_has_server(gset, key, field)
    if not gset then return false end
    local t = gset:readSetting(key)
    return type(t) == "table" and t[field] ~= nil
end


--- Orchestrate both DBs.  `deps`:
---   ui         ReaderUI (ui[ui_key] per plugin / ui.cloudstorage)
---   settings   Syncery Settings module (master + per-DB sub-toggle getters)
---   gset       G_reader_settings (readSetting for the plugins' server keys)
---   send_event function(event_name) -- dispatch a KOReader Event by name; the
---              caller wires this to UIManager:broadcastEvent(Event:new(name)),
---              which reaches the plugin whatever widget is on top.
--- Returns a per-DB report { statistics = {fired=bool, reason=code},
--- vocabulary_builder = {...} } for the honesty layer / menu.  On fire it sends
--- the plugin's DECLARED sync action as an Event (`SyncBookStats` /
--- `SyncVocabBuilder` -- both registerAction'd by the plugins, exactly what a
--- user gesture triggers) rather than reaching into the plugin's handler.  The
--- sync is async (it schedules a nextTick), so dispatching is all we observe --
--- there is no success signal.  Spacing is the caller's job (the periodic
--- timer); run() fires whenever the gates pass.
function DbSync.run(deps)
    local ui       = deps.ui
    local settings = deps.settings
    local gset     = deps.gset
    local report   = {}

    local master        = settings.get_db_sync_enabled()
    local cloud_present = ui ~= nil and ui.cloudstorage ~= nil

    for _, db in ipairs(DBS) do
        local sub
        if db.sub == "stats" then
            sub = settings.get_db_sync_stats()
        else
            sub = settings.get_db_sync_vocab()
        end
        local mod = ui and ui[db.ui_key] or nil
        local d = DbSync.decide({
            master        = master,
            sub           = sub,
            mod_present   = mod ~= nil,
            cloud_present = cloud_present,
            has_server    = plugin_has_server(gset, db.id, db.server_field),
        })
        if d.fire then
            -- Send the plugin's DECLARED sync Event (decoupled from its internal
            -- handler name).  pcall-guarded so a missing dispatcher or a raising
            -- handler can't break the loop or the report.
            if deps.send_event then
                pcall(deps.send_event, db.event)
            end
        end
        report[db.id] = { fired = d.fire, reason = d.reason }
    end

    return report
end


--- Interpret a run() report into the ONE actionable issue worth surfacing, or
--- nil.  "Actionable" = a state the user can fix: the Cloud storage+ plugin is
--- off (`cloudstorage_absent`) or a plugin has no cloud server set
--- (`no_server`).  Deliberate off-states (`master_off`, `subtoggle_off`) and
--- the transient ones are NOT surfaced.  cloudstorage_absent is a global block
--- (it hits every DB), so it dominates and returns a single result; otherwise
--- the per-DB `no_server` ids are collected in DBS order -- a stable signature
--- for de-duping repeated surfaces.
---   -> { kind = "cloudstorage_absent" }
---    | { kind = "no_server", dbs = { <db id>, ... } }
---    | nil
function DbSync.actionable_summary(report)
    if type(report) ~= "table" then return nil end
    local no_server = {}
    for _, db in ipairs(DBS) do
        local r = report[db.id]
        local reason = r and r.reason
        if reason == "cloudstorage_absent" then
            return { kind = "cloudstorage_absent" }
        elseif reason == "no_server" then
            no_server[#no_server + 1] = db.id
        end
    end
    if #no_server > 0 then
        return { kind = "no_server", dbs = no_server }
    end
    return nil
end


return DbSync
