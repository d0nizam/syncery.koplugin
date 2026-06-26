-- =============================================================================
-- syncery_ui/menu/db_sync_section.lua
-- =============================================================================
--
-- "Statistics & Vocabulary" -- the What's-synced category for the trigger-only
-- sync of the sibling Reading Statistics and Vocabulary Builder plugins.
--
-- Syncery does NOT carry these plugins' SQLite DBs; it triggers each plugin's
-- OWN Cloud-storage sync periodically (a self-rescheduling timer) when the user
-- opts in.
-- See docs/STATS_VOCAB_SYNC_DESIGN.md and syncery_db_sync.lua.
--
-- The rows here only flip plugin fields and persist the matching
-- G_reader_settings keys (via H.makeBoolToggle); the gating/throttling that
-- consumes those keys lives in syncery_db_sync (unit-tested).  The two
-- sub-toggles take the master field, so they are disabled while the master is
-- OFF (long-press then explains "enable the master first").
-- =============================================================================


local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Settings    = require("syncery_settings")

local H = require("syncery_ui/menu/_helpers")
local _ = H._

local M = {}


function M.menuDbSync(plugin)
    local master_help = _(
        "Auto-trigger Reading Statistics and Vocabulary Builder to sync "
        .. "themselves periodically while you read (set the interval below).\n\n"
        .. "These plugins sync over their OWN cloud storage -- not Syncery, and "
        .. "not Syncthing -- so this needs the Cloud storage+ plugin enabled and "
        .. "each plugin's cloud server set.  Off by default.")

    local stats_help = _("Include Reading Statistics in the auto-trigger.")
    local vocab_help = _("Include Vocabulary Builder in the auto-trigger.")
    local interval_help = _(
        "How often to sync Statistics and Vocabulary while you read, in "
        .. "minutes.  Minimum 1.")
    local unify_help = _(
        "Point Statistics and Vocabulary Builder at Syncery's own cloud server, "
        .. "so you set the cloud up once here instead of in each plugin.  This "
        .. "changes those plugins' sync settings; turning it off afterwards "
        .. "leaves the last server in place.  Needs a WebDAV or Dropbox server "
        .. "(FTP cannot sync these databases).")

    local info_text = _(
        "Reading Statistics and Vocabulary Builder keep their data in their "
        .. "own databases, which they sync through KOReader's Cloud storage+ "
        .. "plugin -- over the network, with a three-way merge so two devices "
        .. "don't overwrite each other.\n\n"
        .. "Syncery does not carry or merge these databases itself; it only "
        .. "asks each plugin to run its own sync periodically as you read.  That "
        .. "is why this works over cloud storage only, and not over Syncthing.\n\n"
        .. "To use it: enable the Cloud storage+ plugin, set a cloud server in "
        .. "each plugin's own sync settings, then turn on the switches here.\n\n"
        .. "Or turn on \"Use Syncery's cloud server\" to set the cloud up once "
        .. "here and let Syncery point both plugins at it.")

    -- Drive the module-level DB-sync timer from the live instance.  Guarded so
    -- a fake plugin (tests) without the method is a harmless no-op.
    local function rearm()
        if type(plugin._rearmDbSyncTimer) == "function" then
            plugin:_rearmDbSyncTimer()
        end
    end
    -- Tier 2: assert the unified config the moment the switch changes, so it
    -- takes effect without waiting for the next tick.  Self-gating on the master
    -- and unify flags, so calling it after the toggle ended up OFF is a no-op.
    local function apply_unify()
        if type(plugin._unifyDbSyncConfig) == "function" then
            plugin:_unifyDbSyncConfig()
        end
    end

    return {
        H.makeBoolToggle(plugin, "db_sync_enabled", "syncery_db_sync_enabled",
            _("Sync Vocab & Statistics"), master_help, nil, rearm),
        H.makeBoolToggle(plugin, "db_sync_stats", "syncery_db_sync_stats",
            _("Statistics"), stats_help, "db_sync_enabled"),
        H.makeBoolToggle(plugin, "db_sync_vocab", "syncery_db_sync_vocab",
            _("Vocabulary"), vocab_help, "db_sync_enabled"),
        H.makeBoolToggle(plugin, "db_sync_unify", "syncery_db_sync_unify",
            _("Use Syncery's cloud server"), unify_help, "db_sync_enabled", apply_unify),
        H.makeNumericSetting{
            label_func   = function()
                return string.format(_("Sync interval: %d min"),
                    Settings.get_db_sync_interval_min())
            end,
            title        = _("Sync interval (minutes)"),
            help         = interval_help,
            get          = function() return Settings.get_db_sync_interval_min() end,
            min          = 1,
            max          = 1440,
            apply        = function(n)
                Settings.set_db_sync_interval_min(n)
                rearm()   -- a new cadence takes effect now, not next cycle
            end,
            enabled_func = function() return plugin.db_sync_enabled == true end,
        },
        {
            text           = _("How this works…"),
            keep_menu_open = true,
            callback       = function()
                UIManager:show(InfoMessage:new{ text = info_text })
            end,
        },
    }
end


return M
