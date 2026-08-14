-- =============================================================================
-- syncery_transports/init.lua
-- =============================================================================
--
-- One-call factory for the full transport stack.  Builds: two
-- transports (Syncthing, Cloud) with production defaults,
-- the orchestrator wired to use them, and the bridge wrapped around
-- the orchestrator.
--
-- This file exists so main.lua's transport wiring is exactly TWO lines:
--
--     local Transports = require("syncery_transports/init")
--     self._transport = Transports.build({ doc_id_fn = ..., on_status_change = ... })
--
-- Then the rest of main.lua uses `self._transport:push_syncthing_scan(...)`,
-- `self._transport:push_cloud_files(...)`, etc.
--
-- DEPENDENCY INJECTION SURFACE
--
-- Production code in main.lua only needs to supply two things:
--
--   doc_id_fn       — function(book_file, doc_settings) → string
--                     Resolves the partial-MD5 content hash for a book.
--                     In main.lua this is the doc-id hash or
--                     AnnPaths._book_content_id.
--
--   on_status_change — function()
--                     Called whenever the orchestrator's status changes.
--                     main.lua wires this to its menu-redraw broadcast.
--
-- Everything else (clock, scheduler, settings_reader, http_client_factory,
-- provider_discover, file I/O for Cloud) uses production defaults.
-- Tests build the stack directly via the individual transport
-- constructors with their own fakes — they DON'T go through this
-- factory.
--
-- =============================================================================


local Orchestrator      = require("syncery_transports/orchestrator")
local Bridge            = require("syncery_transports/bridge")
local SyncthingTransport = require("syncery_transports/syncthing/transport")
local CloudTransport    = require("syncery_transports/cloud/transport")
local CloudSession      = require("syncery_transports/cloud/session")
local Settings          = require("syncery_settings")
local Log               = require("syncery_transports/log")
local log               = Log.tag("transports.factory")


local M = {}


--- Build the production transport stack.  Returns a Bridge instance
--- ready for main.lua to use.
---@param opts table
---   .doc_id_fn         function(file, doc_settings) → string  -- required
---   .on_status_change  function() — optional
---   .ui_cloudstorage_resolver  function() → ui.cloudstorage|nil — optional;
---       lets the Cloud transport's provider selector reach the
---       "Cloud storage+" plugin when that backend is chosen.
---@return table  bridge
function M.build(opts)
    opts = opts or {}
    assert(type(opts.doc_id_fn) == "function",
        "Transports.build: doc_id_fn function is required")

    -- Construct transports with their production defaults.  Each
    -- transport reads settings via G_reader_settings (the default
    -- settings_reader) and builds its REST/cloud client via
    -- the default factories.  Tests building this stack should NOT
    -- go through this factory — they should instantiate transports
    -- directly with their own fakes.
    --
    -- A failure to construct ONE transport doesn't kill the others.
    -- pcall each so a (theoretical) malformed user setting doesn't
    -- prevent the other two from working.  Each transport whose
    -- construction fails is logged and skipped; the orchestrator
    -- runs without it.
    local transports = {}
    local function try_add(name, ctor)
        local ok, t_or_err = pcall(ctor)
        if ok and t_or_err then
            table.insert(transports, t_or_err)
        else
            log.warn("transport '%s' failed to construct: %s",
                name, tostring(t_or_err))
        end
    end

    try_add("syncthing", function() return SyncthingTransport.new({}) end)
    try_add("cloud",     function()
        -- One long-lived CloudSession owns the executable server copy, the
        -- selected backend and all direct provider calls.  The transport only
        -- stages payloads and delegates operations to this boundary.
        local session_factory = opts.cloud_session_factory or CloudSession.new
        local session = session_factory({
            settings_api              = opts.settings_api or Settings,
            select_provider           = opts.select_provider,
            ui_cloudstorage_resolver  = opts.ui_cloudstorage_resolver,
            sync_service              = opts.sync_service,
            now                       = opts.now,
            global_settings           = opts.global_settings,
        })
        local ok_transport, transport_or_err = pcall(CloudTransport.new, {
            session             = session,
            on_server_responded = opts.on_server_responded,
            on_reconciled       = opts.on_reconciled,
        })
        if not ok_transport then
            if session and type(session.shutdown) == "function" then
                pcall(function() session:shutdown() end)
            end
            error(transport_or_err)
        end
        return transport_or_err
    end)

    local orch, orch_err = Orchestrator.new({
        transports       = transports,
        on_status_change = opts.on_status_change,
    })
    if not orch then
        for _, transport in ipairs(transports) do
            if type(transport.shutdown) == "function" then
                pcall(transport.shutdown)
            end
        end
        error("Transports.build: orchestrator init failed: " .. tostring(orch_err))
    end

    log.info("built transport stack with %d transport(s)", #transports)
    return Bridge.new({
        orchestrator = orch,
        doc_id_fn    = opts.doc_id_fn,
    })
end


return M
