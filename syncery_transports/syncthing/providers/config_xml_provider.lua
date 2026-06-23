-- =============================================================================
-- syncery_transports/syncthing/providers/config_xml_provider.lua
-- =============================================================================
--
-- The "config.xml" Syncthing provider: auto-discovers the daemon's API key
-- (and GUI port/scheme) by reading the `config.xml` that a LOCAL-daemon
-- Syncthing KOReader plugin writes under the KOReader settings directory.
--
-- This is the e-ink case BETWEEN the two existing providers:
--   * KOSyncthing+ installed  -> kosyncthing_plus_provider (in-process API;
--                                the key never leaves the plugin).
--   * NO KOSyncthing+, but a DIFFERENT Syncthing plugin runs its own daemon
--     on THIS device and writes `settings/syncthing/config.xml` (the path the
--     plugin family — the original koreader-syncthing and its forks — uses)
--     -> THIS provider reads the key straight out of that file, so the user
--     never has to copy it by hand.  Only the folder still needs picking.
--   * Neither of the above (e.g. Android talking to an EXTERNAL app such as
--     BasicSync / Syncthing-Fork, whose config lives in the app's own sandbox,
--     not under KOReader) -> config.xml is absent, get_config returns nil, and
--     the chain falls through to the manual provider (hand-entered key).
--
-- WHY THIS IS SAFE / NON-LOSSY
--
-- Syncery is loopback-only: it writes its progress/annotation files to the
-- LOCAL filesystem, so the daemon that replicates them is necessarily local
-- (a remote daemon could not see those files).  There is exactly one local
-- daemon, and its `config.xml` is the AUTHORITATIVE source for that daemon's
-- api_key/port/scheme.  Reading it can only produce the correct values; there
-- is nothing a manual entry could point at instead.
--
-- HOW IT READS config.xml (pure string match — no XML parser)
--
-- Syncthing's config.xml is a stable, well-known format:
--
--     <gui enabled="true" tls="false">
--         <address>127.0.0.1:8384</address>
--         <apikey>THE-API-KEY</apikey>
--     </gui>
--
--   * api_key : <apikey>...</apikey>   (an empty element is treated as absent,
--               exactly as KOSyncthing+'s own getAPIKey does — an empty key
--               would 401 every request).  This is the ONE required field:
--               no key => this provider declines (returns nil).
--   * scheme  : the `tls` attribute on <gui> ("true" => https, else http).
--   * port    : the trailing :<digits> of <address>.  The HOST is ignored on
--               purpose — LocalUrl always targets 127.0.0.1 (loopback), which
--               is correct even when the GUI binds 0.0.0.0.
--
-- Missing address/tls degrade gracefully: LocalUrl.build defends a bad/missing
-- port (=> 8384) and a missing scheme (=> http), so a sparse config.xml still
-- yields a usable URL as long as the api_key is present.
--
-- The config table shape is IDENTICAL to the manual provider's
-- ({ url, api_key, folder_id, folders }), so the transport's existing
-- HttpClient branch consumes it with no new plumbing.  `folders` is nil: the
-- REST folder_discovery re-enumerates live (same as manual).
--
-- DEPENDENCY INJECTION
--
-- `config_paths` and `file_reader` are injected (production defaults below) so
-- the whole provider is unit-testable without a real DataStorage or a real
-- config.xml on disk — the same boundary-to-globals pattern as the other
-- providers' settings_reader.
-- =============================================================================


local LocalUrl = require("syncery_transports/syncthing/local_url")


local ConfigXmlProvider = {}


-- ----------------------------------------------------------------------------
-- Production default: the ordered list of config.xml paths to try.
--
-- Mirrors the plugin family's layout: `<dataDir>/settings/syncthing/` for the
-- standard binary and `.../settings/syncthing-legacy/` for the legacy one.  We
-- try BOTH (standard first) because the legacy toggle is the OTHER plugin's
-- private setting, not something Syncery owns — trying both covers either mode
-- without reading a foreign key.  Returns {} when DataStorage is unavailable
-- (e.g. headless tests), which simply makes the provider decline.
-- ----------------------------------------------------------------------------


local function default_config_paths()
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok or type(DataStorage) ~= "table"
            or type(DataStorage.getFullDataDir) ~= "function" then
        return {}
    end
    local ok2, base = pcall(function() return DataStorage:getFullDataDir() end)
    if not ok2 or type(base) ~= "string" or base == "" then
        return {}
    end
    base = base:gsub("[/\\]+$", "") .. "/settings/"
    return {
        base .. "syncthing/config.xml",         -- standard mode
        base .. "syncthing-legacy/config.xml",  -- legacy mode
    }
end


-- ----------------------------------------------------------------------------
-- Production default: read a file's whole contents, or nil if it can't be
-- opened (missing file, no permission).  No error propagation — a missing
-- config.xml is the normal "I can't help" signal, not a failure.
-- ----------------------------------------------------------------------------


local function default_file_reader(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end


-- ----------------------------------------------------------------------------
-- Pure: extract the api_key from config.xml content, or nil if absent/empty.
-- ----------------------------------------------------------------------------


local function extract_api_key(content)
    if type(content) ~= "string" then return nil end
    local key = content:match("<apikey>%s*(.-)%s*</apikey>")
    if not key or key == "" then return nil end
    return key
end


-- ----------------------------------------------------------------------------
-- Pure: derive the loopback URL from config.xml's <gui> tls attr + <address>
-- port.  Both are optional; LocalUrl.build supplies the defaults.
-- ----------------------------------------------------------------------------


local function url_from_content(content)
    local tls    = content:match("<gui[^>]-tls%s*=%s*[\"'](%a+)[\"']")
    local scheme = (tls == "true") and "https" or "http"
    local addr   = content:match("<address>%s*(.-)%s*</address>")
    local port   = addr and addr:match(":(%d+)%s*$") or nil
    return LocalUrl.build(scheme, port)
end


-- ----------------------------------------------------------------------------
-- Constructor.
-- ----------------------------------------------------------------------------


--- Build a config.xml provider.
---
--- @param opts table
---   .settings_reader function(key) → any     — reads syncery_syncthing_folder_id
---   .config_paths    function() → {string}   — default: standard+legacy under DataStorage
---   .file_reader     function(path) → string|nil — default: io.open + read
function ConfigXmlProvider.new(opts)
    opts = opts or {}
    local settings_reader = opts.settings_reader or function() return nil end
    local config_paths    = opts.config_paths    or default_config_paths
    local file_reader     = opts.file_reader      or default_file_reader
    assert(type(settings_reader) == "function",
        "ConfigXmlProvider.new: settings_reader must be a function")
    assert(type(config_paths) == "function",
        "ConfigXmlProvider.new: config_paths must be a function")
    assert(type(file_reader) == "function",
        "ConfigXmlProvider.new: file_reader must be a function")

    local p = {}

    function p.id() return "config_xml" end

    function p.get_config()
        -- Find the first candidate config.xml that yields a non-empty key.
        local api_key, content
        for _, path in ipairs(config_paths() or {}) do
            local c = file_reader(path)
            local k = extract_api_key(c)
            if k then
                api_key, content = k, c
                break
            end
        end
        -- The api_key is the readiness gate: no key (no config.xml, or only an
        -- empty <apikey>) means this provider can't help — decline so the
        -- chain falls through to manual.
        if not api_key then return nil end

        local folder_id = settings_reader("syncery_syncthing_folder_id")

        return {
            url       = url_from_content(content),
            api_key   = api_key,
            -- nil when nothing is picked yet: the folder picker is the only
            -- way to set a real folder, and the scan guard treats nil/empty as
            -- "not configured" (push skipped).  Same as the manual provider.
            folder_id = (type(folder_id) == "string" and folder_id ~= "")
                         and folder_id or nil,
            -- No `folders`: list_folders re-enumerates live over REST, exactly
            -- like the manual provider.
            folders   = nil,
        }
    end

    function p.supports(_capability)
        -- A pure config-source, like the manual provider: zero bonus
        -- capabilities (no event subscription, no IgnoreRegistry, no detailed
        -- conflicts — those are KOSyncthing+-only / the scanner's job).
        return false
    end

    return p
end


return ConfigXmlProvider
