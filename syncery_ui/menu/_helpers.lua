-- =============================================================================
-- syncery_ui/menu/_helpers.lua
-- =============================================================================
--
-- Shared helpers for every menu section.  Two classes of helper live
-- here:
--
--   1. **Menu-row combinators** (safe, helpHold, gatedHold,
--      makeBoolToggle).  Wrappers that build menu
--      callbacks with consistent behaviour — pcall toasts for errors,
--      gated hold_callbacks that explain why an item is disabled,
--      boolean toggles wired to G_reader_settings with a master-switch
--      gate.
--
--   2. **Config / transport accessors** (load_/save_syncthing_cfg,
--      test_*_connection, folder discovery). Adapters between the
--      section code (which thinks in tables) and `syncery_settings`
--      (which exposes get/set per field).
--      Centralised here so the test/wizard surfaces don't get
--      duplicated across the wizard-section and the manual-edit
--      section.
--
-- Plus two more things:
--
--   3. **`H.status_snapshot(plugin)` — the Smart Header source of
--      truth.**  Calls `plugin._transport:get_status()` exactly once
--      per render and caches the result on the plugin instance under
--      `_menu_status_snapshot` (cleared after each menu rebuild).
--      Every section that needs to read transport state goes through
--      this function.  If multiple rows called `get_status()` independently
--      we'd issue N copies of the same query per menu render; this
--      shared snapshot reduces it to one.
--
-- =============================================================================


local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger      = require("logger")

local I18n        = require("syncery_i18n")
local Settings    = require("syncery_settings")
local HttpClient  = require("syncery_transports/http_client")
local LocalUrl    = require("syncery_transports/syncthing/local_url")
local Providers   = require("syncery_transports/syncthing/providers/init")

local _  = I18n.translate
local _n = I18n.ngettext


local H = {}

-- Re-export translation primitives so sections can write
-- `local _ = H._` / `local _n = H._n` at the top and keep call sites
-- short.
H._  = _
H._n = _n


-- ============================================================================
-- 1. Menu-row combinators
-- ============================================================================

--- Wrap a callback so any error becomes a user-visible toast instead
--- of a silent crash.  `label` shows in the toast text so the user
--- knows which action failed.
function H.safe(label, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            logger.warn("Syncery menu [" .. label .. "]: " .. tostring(err))
            UIManager:show(InfoMessage:new{
                icon    = "notice-warning",
                text    = string.format(
                    _("Syncery encountered an unexpected error.\n\n"
                   .. "Action: %s\nDetails: %s"), label, tostring(err)),
                timeout = 6,
            })
        end
    end
end


--- hold_callback that just pops up `text` as an info toast.  The
--- common case for "long-press shows help".
function H.helpHold(text)
    return function()
        UIManager:show(InfoMessage:new{ text = text })
    end
end


--- hold_callback for items behind a condition.  When `condition_fn()`
--- is false, shows `gate_reason` ("why is this disabled").  When
--- true, shows `help` (even an enabled item gets an explanation on
--- long-press).
function H.gatedHold(condition_fn, gate_reason, help)
    return function()
        if not condition_fn() then
            UIManager:show(InfoMessage:new{ text = gate_reason })
        else
            UIManager:show(InfoMessage:new{ text = help })
        end
    end
end


--- Network pre-check for one-shot, user-initiated network actions
--- (Test connection, Discover folders, the wizard's final test).
---
--- `socket.http.request` in http_client is SYNCHRONOUS
--- and blocks the event loop until the request completes or times out.
--- On an e-reader — where WiFi is off by default — tapping one of these
--- actions would freeze the whole UI for the full timeout window with
--- no spinner and no response to touch, indistinguishable from a hang.
---
--- This is the same model the background sync paths already use:
--- `plugin:_isNetworkOnline()` is the one shared connectivity predicate
--- (see PluginSync.do_cloud_upload), so Syncthing's diagnostics and the
--- cloud upload path gate on identical logic. `_isNetworkOnline` fails
--- OPEN — when KOReader's NetworkMgr is unavailable it returns true — so
--- desktop/test environments without a NetworkMgr behave exactly as
--- before this guard existed.
---
--- Unlike the background paths, these are DIAGNOSTICS whose result the
--- user is waiting on right now, so there is deliberately NO wifi-backoff
--- retry here: a "Syncthing is reachable" toast (or a folder list) that
--- pops up unprompted two minutes later when WiFi happens to return would
--- be confusing. We surface an honest message immediately and stop.
---
--- @param plugin       the Syncery instance (exposes :_isNetworkOnline()).
--- @param offline_msg  optional custom text; defaults to the generic
---                     "connect, then try again" line. Callers that have
---                     just persisted user input pass a variant that says
---                     the settings are saved.
--- @return boolean true when online (caller proceeds); false when offline
---                 (a toast was shown; caller should return).
function H.network_ready(plugin, offline_msg)
    if plugin and plugin:_isNetworkOnline() then
        return true
    end
    UIManager:show(InfoMessage:new{
        icon    = "notice-warning",
        text    = offline_msg
            or _("No network connection.\nConnect to the network, then try again."),
        timeout = 4,
    })
    return false
end


--- hold_callback for a transport master-toggle row.  Tap toggles
--- the master switch; long-press
--- opens the per-transport status panel — but ONLY when the transport
--- is enabled.  A disabled transport has no meaningful status, so the
--- long-press falls back to the help toast in that case.
---
--- `enabled_fn()` reports whether the transport's `use_*` toggle is
--- on.  `help` is the same help string the row's `help_text` carries,
--- reused for the disabled-transport fallback.
---
--- The status_panel module is required lazily inside the closure so
--- `_helpers.lua` has no load-time dependency on `syncery_ui/
--- status_panel.lua` (which itself requires this file — a static
--- require here would be a cycle).
function H.statusPanelHold(plugin, transport_id, enabled_fn, help)
    return function()
        if enabled_fn and not enabled_fn() then
            UIManager:show(InfoMessage:new{ text = help })
            return
        end
        local ok, Panel = pcall(require, "syncery_ui/status_panel")
        if ok and Panel and type(Panel.show) == "function" then
            Panel.show(plugin, transport_id)
        else
            -- Defensive: if the panel module fails to load, the
            -- long-press still does something useful.
            UIManager:show(InfoMessage:new{ text = help })
        end
    end
end


--- Build a checkbox-style row backed by a plugin field + a
--- G_reader_settings key.  Optional `master_field` makes the item
--- disabled when the named plugin field is false; in that
--- case long-press explains "enable the master first".
function H.makeBoolToggle(plugin, field, key, label, help, master_field, after_set)
    local item = {
        text           = label,
        help_text      = help,
        keep_menu_open = true,
        checked_func   = function() return plugin[field] == true end,
        callback       = function(tmi)
            plugin[field] = not plugin[field]
            if G_reader_settings then
                G_reader_settings:saveSetting(key, plugin[field])
            end
            if after_set then after_set(plugin[field]) end
            if tmi then tmi:updateItems() end
        end,
    }
    if master_field then
        item.enabled_func = function() return plugin[master_field] == true end
        item.hold_callback = function()
            if not plugin[master_field] then
                UIManager:show(InfoMessage:new{
                    text = _("Enable the master switch first to control this option.")
                })
            else
                UIManager:show(InfoMessage:new{ text = help })
            end
        end
    else
        item.hold_callback = H.helpHold(help)
    end
    return item
end


--- Build a numeric-input menu row.
---
--- A single place for the "tap → InputDialog(number) → validate range →
--- apply" pattern, so the several orphan settings added in 12.3 don't
--- each re-implement (and risk diverging on) the dialog wiring.
---
--- @param opts table {
---   label_func   = function() -> string,  -- the row's dynamic label
---   help         = string,                 -- help_text + long-press
---   title        = string,                 -- dialog title
---   get          = function() -> number,   -- current value (for prefill)
---   min          = number, max = number,   -- inclusive valid range
---   apply        = function(n),            -- persist the validated value
---   unit         = string|nil,             -- for the confirmation toast
---   enabled_func = function|nil,           -- optional Pattern-2 gate
--- }
--- @return table menu item
function H.makeNumericSetting(opts)
    local InputDialog = require("ui/widget/inputdialog")
    local item = {
        text_func      = opts.label_func,
        help_text      = opts.help,
        keep_menu_open = true,
        hold_callback  = H.helpHold(opts.help),
        callback       = function()
            local dlg
            dlg = InputDialog:new{
                title      = opts.title,
                input      = tostring(opts.get()),
                input_type = "number",
                buttons = {{
                    { text = _("Cancel"),
                      callback = function() UIManager:close(dlg) end },
                    { text = _("Save"), is_enter_default = true,
                      callback = function()
                          local n = tonumber(dlg:getInputText())
                          if n and n >= opts.min and n <= opts.max then
                              opts.apply(n)
                              UIManager:close(dlg)
                              UIManager:show(InfoMessage:new{
                                  text = opts.unit
                                      and string.format(_("Set to %d %s."), n, opts.unit)
                                      or  string.format(_("Set to %d."), n),
                                  timeout = 2,
                              })
                          else
                              UIManager:show(InfoMessage:new{
                                  text = string.format(
                                      _("Please enter a number between %d and %d."),
                                      opts.min, opts.max),
                                  timeout = 3,
                              })
                          end
                      end },
                }},
            }
            UIManager:show(dlg)
            dlg:onShowKeyboard()
        end,
    }
    if opts.enabled_func then
        item.enabled_func = opts.enabled_func
    end
    return item
end


-- ============================================================================
-- 2. Config table accessors
--
-- These keep a single-table `load_*` / `save_*` shape so the dialog
-- code doesn't have to call individual `Settings.set_*` accessors.
-- Reads/writes go through `syncery_settings`, so the transports see
-- writes immediately on their next read.
-- ============================================================================


function H.load_syncthing_cfg()
    return {
        api_key   = Settings.get_syncthing_api_key(),
        folder_id = Settings.get_syncthing_folder_id(),
        folder    = Settings.get_syncthing_folder(),
    }
end


function H.save_syncthing_cfg(cfg)
    if cfg.api_key   ~= nil then Settings.set_syncthing_api_key(cfg.api_key)     end
    if cfg.folder_id ~= nil then Settings.set_syncthing_folder_id(cfg.folder_id) end
    if cfg.folder    ~= nil then Settings.set_syncthing_folder(cfg.folder)       end
end


--- Is an AUTOMATIC (non-manual) Syncthing key source present?  KOSyncthing+
--- and config.xml both sit ahead of the manual provider in the chain
--- (KOSyncthing+ → config.xml → manual), so when either is present the
--- manual key is functionally unreachable.  Two consumers:
---   • "Set up API key…" is hidden — entering a manual key can't take effect.
---   • "Test connection" routes through the active provider (KOSyncthing+'s
---     apiCall / config.xml's authoritative URL) rather than the manual
---     key + scheme probe.
--- rawget so a present-but-empty __index never trips a metatable side
--- effect — the same guard kosyncthing_plus_provider and main.lua use.
function H.syncthing_auto_key_present()
    if rawget(_G, "KOSyncthingPlusAPI") ~= nil then return true end
    if Providers.config_xml_key_available() then return true end
    return false
end

--- Is a Syncthing API key usable from ANY source (manual OR an automatic
--- provider)?  The manual key is only one of three ways Syncery obtains the
--- key the transport talks to Syncthing with, so a row that needs "a key is
--- available" (Test connection, Choose Syncthing folder) must be satisfied
--- when the key comes from a higher-priority provider, not only when the
--- user typed one in.  Mirrors the first-run wizard's `api_auto` plus the
--- manual key.
function H.syncthing_key_usable()
    local manual = Settings.get_syncthing_api_key()
    if manual and manual ~= "" then return true end
    return H.syncthing_auto_key_present()
end


-- ============================================================================
-- 3. Test-connection helpers
--
-- Diagnostics shape (ok / "unreachable" / "auth_failed" / "http_<code>")
-- that the menu's branching messages expect.
-- ============================================================================


--- GET /rest/system/version against the user's Syncthing.  Cheap; doesn't list
--- folders or expose anything sensitive.  Returns (ok, code|nil, diag) via cb.
---
--- Auto-probes the scheme: tries https first, then http on a connection-level
--- miss, and persists the working scheme so normal operation builds the right
--- URL without re-probing.  Syncthing's GUI commonly serves over https (self-
--- signed, 307-redirecting http->https), so https-first reaches it directly; a
--- daemon that ANSWERS on https (even to reject the key) confirms https — only a
--- no-response miss falls through to http.
---
--- `client_factory` is injectable for tests (defaults to HttpClient.new); the
--- production callers pass nothing.
function H.test_syncthing_connection(callback, client_factory)
    client_factory = client_factory or HttpClient.new

    local api_key = Settings.get_syncthing_api_key()
    if api_key == "" then callback(false, nil, "no_api_key"); return end
    local port = Settings.get_syncthing_port()

    -- One attempt at a given scheme.  on_done(ok, code|nil, diag, conn_miss):
    -- conn_miss is true ONLY for a no-response failure (so the caller may retry
    -- the other scheme); any HTTP answer — success or rejection — sets it false.
    local function attempt(scheme, on_done)
        local client = client_factory({
            base_url    = LocalUrl.build(scheme, port),
            headers     = { ["X-API-Key"] = api_key },
            timeout_sec = 6,
        })
        if not client then on_done(false, nil, "no_http_module", true); return end
        client:get("/rest/system/version", function(ok, err, body, status)
            if ok then
                on_done(true, status or 200, "ok", false)
            elseif err == "rejected" then
                if status == 401 or status == 403 then
                    on_done(false, status, "auth_failed", false)
                else
                    on_done(false, status, "http_" .. tostring(status or "?"), false)
                end
            else
                on_done(false, nil, err or "unreachable", true)
            end
        end)
    end

    -- HTTPS-first (matches the companion plugin's probe order).  Syncthing's
    -- GUI commonly serves over HTTPS with a self-signed cert and 307-redirects
    -- HTTP->HTTPS, so probing https first reaches it directly instead of
    -- bouncing off the redirect.  Fall back to http only on a NO-RESPONSE
    -- miss.  The working scheme is persisted so listing/push skip re-probing.
    attempt("https", function(ok, code, diag, conn_miss)
        if not conn_miss then
            Settings.set_syncthing_scheme("https")
            callback(ok, code, diag)
            return
        end
        attempt("http", function(ok2, code2, diag2, conn_miss2)
            if not conn_miss2 then Settings.set_syncthing_scheme("http") end
            callback(ok2, code2, diag2)
        end)
    end)
end


--- Cloud "test connection" surrogate.  The new cloud transport has no
--- equivalent zero-cost probe, so the best we can do is report
--- whether the server descriptor is well-formed — actual reachability
--- surfaces on the next real upload via the orchestrator's status
--- callback.
function H.test_cloud_connection(callback)
    -- Config-only check: cloud has no cheap connectivity primitive (the provider
    -- contract is just `sync`, a heavy bidirectional transfer), so reachability
    -- is verified on the next real sync, not here.  One boolean: configured or not.
    callback(Settings.is_cloud_configured())
end


-- ============================================================================
-- 4. Status snapshot — the single source of truth for transport state
--
-- Every section that wants to read transport state goes through
-- `status_snapshot(plugin)`.  It calls plugin._transport:get_status()
-- exactly once per render and caches the table on the plugin instance.
-- The cache is per-menu-build: `clear_status_snapshot` zeroes it after
-- the top menu is fully rebuilt, so the next render starts fresh.
--
-- This is the "centralised cache" discipline: if every section called
-- get_status() independently we'd
-- issue N copies of the same query per menu render.
--
-- The snapshot has this shape:
--   {
--     syncthing = {
--       display_name = "Syncthing",
--       available    = true,
--       summary      = "ready (replication via daemon)",
--       orch_last_error_class  = nil,
--       orch_any_pending_retry = false,
--     },
--     cloud  = {...},
--   }
--
-- When _transport is missing (test fakes that don't wire it in, or a
-- plugin that crashed during init) we return an empty table and let
-- callers branch on `snapshot[id]` being nil.  Section code should
-- treat "no snapshot entry" as "transport disabled".
-- ============================================================================


function H.status_snapshot(plugin)
    if plugin._menu_status_snapshot then
        return plugin._menu_status_snapshot
    end
    local snap = {}
    if plugin._transport and type(plugin._transport.get_status) == "function" then
        local ok, result = pcall(plugin._transport.get_status, plugin._transport)
        if ok and type(result) == "table" then snap = result end
    end
    plugin._menu_status_snapshot = snap
    return snap
end


--- Drop the cached snapshot.  Call after a menu rebuild so the next
--- render reads fresh data.  `init.lua` wires this into buildTopMenu's
--- exit so callers don't need to remember.
function H.clear_status_snapshot(plugin)
    plugin._menu_status_snapshot = nil
end


--- Convenience: derive a per-transport state label from the snapshot.
--- Returns one of:
---   "disabled"        — user toggle off, or transport not registered
---   "unsupported"     — a provider is picked but it can't sync (e.g. FTP)
---   "needs_config"    — toggle on but key/server not set
---   "syncing"         — has pending retries right now
---   "error"           — last_error_class indicates a fault
---   "ready"           — available, no retries, no error
---
--- Sections use this to pick a label without re-parsing summary strings.
function H.transport_state(snapshot, transport_id)
    local s = snapshot[transport_id]
    if not s then return "disabled" end
    if not s.available then
        local summary = s.summary or ""
        if summary:match("disabled") then return "disabled" end
        -- Structured flags (from the cloud transport's canonical `state`), not
        -- summary-string matches.  Order mirrors the state precedence:
        --   no_backend  — a server is picked but NO cloud backend can dispatch it
        --                 (install/enable "Cloud storage+") — distinct from and
        --                 takes precedence over "unsupported".
        --   unsupported — a backend exists but can't sync this server type (FTP).
        -- Anything else with a server set is "nothing (fully) configured".
        if s.backend_unavailable then return "no_backend" end
        if s.unsupported_provider then return "unsupported" end
        return "needs_config"
    end
    if s.orch_any_pending_retry then return "syncing" end
    if s.orch_last_error_class   then return "error"   end
    return "ready"
end


return H
