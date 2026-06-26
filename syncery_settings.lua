-- =============================================================================
-- syncery_settings.lua
-- =============================================================================
--
-- The single source of truth for transport-related settings I/O.
--
-- WHY THIS MODULE EXISTS
--
-- Settings I/O does not belong inside the transports.  A design where
-- each transport owns its own settings layer with an in-process cache
-- needs an invalidate hook the menu must call after every write —
-- forget once, and the menu shows fresh values while the next push
-- still uses stale ones.
--
-- The transports here re-read settings on every
-- call via their injected `settings_reader`, so no per-module cache
-- exists and no invalidate dance is needed.  This module is the
-- write-side counterpart: a flat API for the menu to call, persisting
-- to the same G_reader_settings keys the transports read.
--
-- DESIGN
--
-- • One module, all keys.  The settings surface is small enough that
--   spreading it across three files (one per transport) creates more
--   navigation friction than it removes.
--
-- • No shared module-level cache.  Every read goes through the backend
--   directly.  The backend (G_reader_settings) already caches in
--   memory; we don't need a second layer.
--
-- • Read-write asymmetry is OK.  `set_*` validates and writes; `get_*`
--   reads with a sensible default.  Validation lives at the write
--   boundary so a corrupt persisted value (from a previous version)
--   still reads as a default rather than crashing.
--
-- • Listeners exist for the rare case where something in-process
--   needs to know about a settings change (e.g. invalidating a
--   per-conversation cache).  Most code doesn't subscribe — transports
--   re-read on every call by design.
--
-- BACKEND INJECTION
--
-- In production the backend is `_G.G_reader_settings`.  Tests inject
-- a table with `readSetting / saveSetting / delSetting` so they don't
-- need a real KOReader environment.  The seam is intentionally tiny
-- — anything more elaborate (a fake G_reader_settings shaped like the
-- real one) is overkill for what this module does.
--
-- =============================================================================


local Settings = {}


-- ----------------------------------------------------------------------------
-- Key constants.
--
-- Match the names the new transports' `default_settings_reader` looks up.
-- Renaming any of these requires changing the corresponding TOGGLE_KEY /
-- KEY_* constant inside the transport so the two sides stay aligned —
-- spec/transports_factory_spec.lua exercises that alignment end-to-end.
-- ----------------------------------------------------------------------------


-- Builds the loopback base URL (host 127.0.0.1) from the stored scheme + port.
local LocalUrl = require("syncery_transports/syncthing/local_url")


-- Master toggles (one per transport).  COLLAPSED: this is the SAME canonical
-- key the checkbox + wizard write (`syncery_use_<name>`), and the same key the
-- transports read internally via their TOGGLE_KEY constant.  The old separate
-- `syncery_sync_via_<name>` keys were a redundant mirror: the wizard wrote only
-- `use_*`, so picking a different transport left `sync_via_*` stale and
-- is_available() diverged from the checkbox (label "ready" while unchecked).
-- One key now — nothing to keep in sync.
local KEY_SYNCTHING_ENABLED = "syncery_use_syncthing"
local KEY_CLOUD_ENABLED     = "syncery_use_cloud"

-- Syncthing manual-config keys.  Read by the manual provider when the
-- KOSyncthing+ plugin isn't installed (or the user disabled auto-config).
local KEY_SYNCTHING_API_KEY   = "syncery_syncthing_api_key"
local KEY_SYNCTHING_FOLDER_ID = "syncery_syncthing_folder_id"
local KEY_SYNCTHING_FOLDER    = "syncery_syncthing_folder"
local KEY_SYNCTHING_PORT      = "syncery_syncthing_port"
local KEY_SYNCTHING_SCHEME    = "syncery_syncthing_scheme"


-- Cloud server descriptor.  Persisted as a Lua table — the new cloud
-- transport reads it with `type(server) == "table"`, which is what
-- G_reader_settings returns for a previously-saved table value.  No
-- JSON wrapping required.
local KEY_CLOUD_SERVER = "syncery_cloud_server"
-- Cached resolved IP for the cloud server's host, persisted across sessions so
-- the reachability probe has a non-blocking target from cold start (see
-- cloud_reachability.lua).  An internal cache, not a user-facing setting:
-- {host, ip}, re-resolved by the module when the host changes or the IP goes
-- stale.  No `fire` on write -- nothing in the menu/transports reacts to it.
local KEY_CLOUD_SERVER_IP = "syncery_cloud_server_ip"

-- DB sync (Reading Statistics + Vocabulary Builder).  Trigger-only flags
-- Syncery consults at close/suspend; the master is OFF by default.
local KEY_DB_SYNC_ENABLED  = "syncery_db_sync_enabled"
local KEY_DB_SYNC_STATS    = "syncery_db_sync_stats"
local KEY_DB_SYNC_VOCAB    = "syncery_db_sync_vocab"
local KEY_DB_SYNC_INTERVAL = "syncery_db_sync_interval_min"
local KEY_DB_SYNC_UNIFY    = "syncery_db_sync_unify"


-- ----------------------------------------------------------------------------
-- Backend plumbing.
-- ----------------------------------------------------------------------------


-- nil ⇒ use _G.G_reader_settings at call time.  Tests inject via
-- _set_backend so they don't need a real KOReader environment.
local backend = nil


local function active_backend()
    if backend then return backend end
    return _G.G_reader_settings
end


local function gs(key, default)
    local b = active_backend()
    if not b then return default end
    local v = b:readSetting(key)
    if v == nil then return default end
    return v
end


local function ss(key, value)
    local b = active_backend()
    if not b then return false end
    b:saveSetting(key, value)
    return true
end


local function ds(key)
    local b = active_backend()
    if not b then return end
    if type(b.delSetting) == "function" then b:delSetting(key) end
end


-- ----------------------------------------------------------------------------
-- Listeners.  Each listener registers for a specific transport_id (one
-- of "syncthing"/"cloud") or "*" for all.  Fires after a
-- successful write.  pcall'd so a broken listener can't stop other
-- listeners or the write itself.
-- ----------------------------------------------------------------------------


local listeners = {}


local function fire(transport_id)
    for _, entry in ipairs(listeners) do
        if entry.transport_id == "*" or entry.transport_id == transport_id then
            pcall(entry.fn, transport_id)
        end
    end
end


--- Register a change listener for a transport.
--- @param transport_id string  "syncthing" | "cloud" | "*"
--- @param fn function          fn(transport_id)
--- @return function unsubscribe
function Settings.on_change(transport_id, fn)
    assert(type(fn) == "function",
        "Settings.on_change: fn must be a function")
    transport_id = transport_id or "*"
    local entry = { transport_id = transport_id, fn = fn }
    table.insert(listeners, entry)
    return function()
        for i, e in ipairs(listeners) do
            if e == entry then table.remove(listeners, i); return end
        end
    end
end


-- ----------------------------------------------------------------------------
-- Test hooks.  Production code never calls these.
-- ----------------------------------------------------------------------------


--- Inject a backend (table with readSetting / saveSetting / delSetting).
--- Pass nil to revert to _G.G_reader_settings.
function Settings._set_backend(b) backend = b end


--- Clear listeners and reset to default backend.  Use between test cases
--- to prevent listener accumulation across cases that share a session.
function Settings._reset_for_tests()
    listeners = {}
    backend   = nil
end


-- ----------------------------------------------------------------------------
-- Master toggles.
-- ----------------------------------------------------------------------------


-- Read-only accessors for the master toggle.  There is no setter: the menu
-- checkbox and the wizard set `plugin.use_<name>` AND save the canonical
-- `syncery_use_<name>` key directly.  The old set_*_enabled existed only to
-- write the separate `sync_via_*` mirror, which is gone.
function Settings.get_syncthing_enabled() return gs(KEY_SYNCTHING_ENABLED, false) == true end
function Settings.get_cloud_enabled()     return gs(KEY_CLOUD_ENABLED, false) == true end


-- ----------------------------------------------------------------------------
-- Syncthing.
-- ----------------------------------------------------------------------------


--- The Syncthing GUI base URL is COMPUTED, not stored: host is always the
--- loopback (Syncery syncs local files, so the daemon is on this device), the
--- scheme is auto-detected by the connection test, and the port is an
--- overridable Advanced setting.  See syncery_transports/syncthing/local_url.
function Settings.get_syncthing_url()
    return LocalUrl.build(Settings.get_syncthing_scheme(), Settings.get_syncthing_port())
end


function Settings.get_syncthing_api_key() return gs(KEY_SYNCTHING_API_KEY, "") end
function Settings.set_syncthing_api_key(v)
    ss(KEY_SYNCTHING_API_KEY, type(v) == "string" and v or "")
    fire("syncthing")
end


function Settings.get_syncthing_folder_id() return gs(KEY_SYNCTHING_FOLDER_ID, "") end

--- Empty / non-string folder_id is stored as "" (no folder chosen yet):
--- the folder picker is the only way to set a real id, and the scan guard
--- treats "" as "not configured".  No "default" seed.
function Settings.set_syncthing_folder_id(v)
    local s = (type(v) == "string" and v ~= "") and v or ""
    ss(KEY_SYNCTHING_FOLDER_ID, s)
    fire("syncthing")
end


--- The single chosen Syncthing folder, as a `{folder_id, path, label}` record
--- (or nil before one is picked).  The picker fetches the folder list live and
--- persists only the one the user chose — there is no stored list.
function Settings.get_syncthing_folder() return gs(KEY_SYNCTHING_FOLDER, nil) end
function Settings.set_syncthing_folder(v)
    -- Only persist a real table; anything else clears the key.
    ss(KEY_SYNCTHING_FOLDER, type(v) == "table" and v or nil)
    fire("syncthing")
end


--- Port of the Syncthing GUI on 127.0.0.1.  Default 8384; values outside
--- 1024-65535 (or a corrupt persisted value) read back as the default.  The
--- Advanced port field gates input to that range, so set_ only sees valid
--- values from the UI; the guard here protects against a stale persisted one.
function Settings.get_syncthing_port()
    local n = tonumber(gs(KEY_SYNCTHING_PORT, 8384))
    if type(n) ~= "number" or n ~= n or n < 1024 or n > 65535 then return 8384 end
    return math.floor(n)
end
function Settings.set_syncthing_port(v)
    local n = tonumber(v)
    if type(n) == "number" and n == n and n >= 1024 and n <= 65535 then
        ss(KEY_SYNCTHING_PORT, math.floor(n))
        fire("syncthing")
    end
end


--- Scheme for the Syncthing GUI: "http" (default) or "https".  Set by the
--- connection test's auto-probe (BasicSync serves https); anything but the
--- exact string "https" normalises to "http".
function Settings.get_syncthing_scheme()
    return (gs(KEY_SYNCTHING_SCHEME, "http") == "https") and "https" or "http"
end
function Settings.set_syncthing_scheme(v)
    ss(KEY_SYNCTHING_SCHEME, (v == "https") and "https" or "http")
    fire("syncthing")
end




-- ----------------------------------------------------------------------------
-- Cloud.
-- ----------------------------------------------------------------------------


--- Return the cloud server descriptor (as persisted) or nil.  The
--- descriptor is a table whose shape is defined by KOReader's
--- apps/cloudstorage/syncservice picker — Syncery doesn't introspect
--- beyond { url|address|name, type|provider } for the describe helper.
function Settings.get_cloud_server()
    local v = gs(KEY_CLOUD_SERVER, nil)
    if type(v) ~= "table" then return nil end
    return v
end


--- Persist the cloud server descriptor.  Returns true on success, false
--- if `server` is not a table.  No deep validation — the picker's
--- contract is "whatever it hands back is loadable".
function Settings.set_cloud_server(server)
    if type(server) ~= "table" then return false end
    ss(KEY_CLOUD_SERVER, server)
    fire("cloud")
    return true
end


function Settings.clear_cloud_server()
    ds(KEY_CLOUD_SERVER)
    fire("cloud")
end


--- Read the cached {host, ip} for the cloud server (or nil).  Seeds
--- CloudReachability so its probe is non-blocking from the first call of a
--- session.  Validated shape: a table carrying string host + ip.
function Settings.get_cloud_server_ip()
    local v = gs(KEY_CLOUD_SERVER_IP, nil)
    if type(v) ~= "table" or type(v.host) ~= "string" or type(v.ip) ~= "string" then
        return nil
    end
    return v
end


--- Persist the resolved {host, ip}.  Returns false on non-string input (so a
--- bad resolve never poisons the cache).  No `fire` -- internal cache only.
function Settings.set_cloud_server_ip(host, ip)
    if type(host) ~= "string" or type(ip) ~= "string" then return false end
    ss(KEY_CLOUD_SERVER_IP, { host = host, ip = ip })
    return true
end


--- A short, human-readable summary for menu rows.  Provider kind + a
--- path/URL when we have one.  Returns nil when no server is set.
function Settings.describe_cloud_server()
    local s = Settings.get_cloud_server()
    if not s then return nil end
    local kind  = s.type or s.provider or "?"
    local where = s.url  or s.address  or s.name or ""
    if where == "" then return kind end
    return kind .. " — " .. where
end


function Settings.is_cloud_configured()
    local s = Settings.get_cloud_server()
    return s ~= nil and (s.url ~= nil or s.address ~= nil)
end


-- ----------------------------------------------------------------------------
-- DB sync (Reading Statistics + Vocabulary Builder).
--
-- Trigger-only flags read at close/suspend to decide whether to call the two
-- plugins' own Cloud-storage sync.  Master defaults OFF; the per-DB sub-toggles
-- default ON but are only consulted when the master is ON.  Booleans follow the
-- enabled-flag pattern (no setter — the menu writes the key directly, like
-- syncery_use_cloud).  When the master is OFF nothing here is consulted and
-- Syncery's behaviour is identical to before this feature.
-- ----------------------------------------------------------------------------


function Settings.get_db_sync_enabled() return gs(KEY_DB_SYNC_ENABLED, false) == true end
function Settings.get_db_sync_stats()   return gs(KEY_DB_SYNC_STATS,   true)  == true end
function Settings.get_db_sync_vocab()   return gs(KEY_DB_SYNC_VOCAB,   true)  == true end
-- Tier 2 opt-in: when ON, Syncery writes its OWN cloud server into the stats and
-- vocab plugins (unifying their config with Syncery's).  Touches other plugins'
-- settings, so it defaults OFF and is consulted only when the master is ON.
function Settings.get_db_sync_unify()   return gs(KEY_DB_SYNC_UNIFY,   false) == true end


--- Periodic DB-sync interval in minutes.  The standalone timer (main.lua) uses
--- this for its self-rescheduling tick.  Default 5; floor 1 -- a non-number or
--- sub-1 stored value falls back to the default so the timer always gets a sane
--- scheduleIn delay.
function Settings.get_db_sync_interval_min()
    local v = gs(KEY_DB_SYNC_INTERVAL, 5)
    if type(v) ~= "number" or v < 1 then return 5 end
    return v
end


--- Persist the DB-sync interval (minutes).  Rejects non-numbers; floors
--- fractional input and clamps the floor to 1 (the getter's invariant).
--- Returns the stored integer, or nil if the input wasn't a number.
function Settings.set_db_sync_interval_min(n)
    if type(n) ~= "number" then return nil end
    n = math.floor(n)
    if n < 1 then n = 1 end
    ss(KEY_DB_SYNC_INTERVAL, n)
    return n
end


return Settings
