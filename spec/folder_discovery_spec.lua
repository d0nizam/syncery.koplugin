-- =============================================================================
-- spec/folder_discovery_spec.lua
-- =============================================================================
--
-- Phase 14.6a — REST folder discovery for the manual Syncthing provider
-- (syncery_transports/syncthing/folder_discovery.lua):
--   * parse_folders — pure JSON-shape -> { folder_id, path } list, for BOTH
--                     the modern array body and the legacy {folders=[...]}.
--   * discover      — async over an injected REST client: success, the
--                     modern->legacy fallback, auth-as-terminal, and the
--                     no-folders sentinel.
--
-- No live daemon: a fake client records the GETs it is asked for and replies
-- with scripted (ok, err, body) tuples.
-- =============================================================================


local h = require("spec.test_helpers")

package.loaded["syncery_transports/syncthing/folder_discovery"] = nil
local FD = require("syncery_transports/syncthing/folder_discovery")


-- --- parse_folders (pure) ----------------------------------------------------
do
    -- Modern shape: a bare folder array.
    local modern = FD.parse_folders({
        { id = "abcd-1234", path = "/books", label = "Books", paused = true },
        { id = " that-one", path = "/more" },
    })
    h.assert_true(modern ~= nil, "parse: modern array yields a list")
    h.assert_equal(#modern, 2, "parse: both folders parsed")
    h.assert_equal(modern[1].folder_id, "abcd-1234", "parse: id mapped to folder_id")
    h.assert_equal(modern[1].path, "/books", "parse: path carried through")
    h.assert_equal(modern[1].label, "Books", "parse: label carried through")
    h.assert_equal(modern[1].state, "paused", "parse: paused config folder -> state=paused")
    h.assert_nil(modern[2].label, "parse: missing label is nil, not empty string")
    h.assert_nil(modern[2].state, "parse: unpaused folder -> state nil")

    -- Legacy shape: a config object with a .folders array.
    local legacy = FD.parse_folders({
        version = 35,
        folders = { { id = "default", path = "/d" } },
        devices = {},
    })
    h.assert_true(legacy ~= nil, "parse: legacy {folders=...} yields a list")
    h.assert_equal(legacy[1].folder_id, "default", "parse: legacy id mapped")

    -- Folders without an id are skipped.
    local mixed = FD.parse_folders({
        { id = "keep", path = "/k" },
        { path = "/no-id" },
        { id = "", path = "/empty-id" },
    })
    h.assert_equal(#mixed, 1, "parse: id-less and empty-id folders skipped")
    h.assert_equal(mixed[1].folder_id, "keep", "parse: only the valid folder kept")

    -- Nothing usable -> nil (single sentinel), never an empty list.
    h.assert_nil(FD.parse_folders({}), "parse: empty input -> nil")
    h.assert_nil(FD.parse_folders({ folders = {} }), "parse: empty folders -> nil")
    h.assert_nil(FD.parse_folders("not a table"), "parse: non-table -> nil")
    h.assert_nil(FD.parse_folders({ folders = { { path = "/x" } } }),
        "parse: folders present but none with an id -> nil")
end


-- A scripted fake REST client. `script` maps an endpoint path to a
-- { ok, err, body } reply; it also records the order of GETs.
local function make_client(script)
    return {
        gets = {},
        get  = function(self, path, cb)
            self.gets[#self.gets + 1] = path
            local r = script[path] or { ok = false, err = "unreachable", body = nil }
            cb(r.ok, r.err, r.body)
        end,
    }
end

-- A decode that just returns whatever Lua table the body "stands for": the
-- script puts the decoded table directly in `body` and we hand it back.
local function passthrough_decode(body) return body end


-- --- discover: modern endpoint succeeds --------------------------------------
do
    local client = make_client({
        [FD.ENDPOINT_MODERN] = { ok = true, body = { { id = "f1", path = "/b" } } },
    })
    local got_folders, got_err
    FD.discover({
        client  = client,
        decode  = passthrough_decode,
        on_done = function(folders, err) got_folders = folders; got_err = err end,
    })
    h.assert_nil(got_err, "discover/modern: no error")
    h.assert_true(got_folders ~= nil and #got_folders == 1, "discover/modern: one folder")
    h.assert_equal(got_folders[1].folder_id, "f1", "discover/modern: folder id surfaced")
    h.assert_equal(#client.gets, 1, "discover/modern: only the modern endpoint was called")
    h.assert_equal(client.gets[1], FD.ENDPOINT_MODERN, "discover/modern: modern endpoint first")
end


-- --- discover: modern 404s, legacy succeeds (version fallback) ---------------
do
    local client = make_client({
        [FD.ENDPOINT_MODERN] = { ok = false, err = "rejected", body = nil },
        [FD.ENDPOINT_LEGACY] = { ok = true, body = { folders = { { id = "leg", path = "/l" } } } },
    })
    local got_folders, got_err
    FD.discover({
        client  = client,
        decode  = passthrough_decode,
        on_done = function(folders, err) got_folders = folders; got_err = err end,
    })
    h.assert_nil(got_err, "discover/fallback: no error after falling back")
    h.assert_true(got_folders ~= nil and got_folders[1].folder_id == "leg",
        "discover/fallback: legacy folder discovered")
    h.assert_equal(#client.gets, 2, "discover/fallback: both endpoints tried")
    h.assert_equal(client.gets[1], FD.ENDPOINT_MODERN, "discover/fallback: modern tried first")
    h.assert_equal(client.gets[2], FD.ENDPOINT_LEGACY, "discover/fallback: legacy tried second")
end


-- --- discover: auth failure is terminal (no fallback) ------------------------
do
    local client = make_client({
        [FD.ENDPOINT_MODERN] = { ok = false, err = "auth_failed", body = nil },
        [FD.ENDPOINT_LEGACY] = { ok = true, body = { folders = { { id = "x" } } } },
    })
    local got_folders, got_err
    FD.discover({
        client  = client,
        decode  = passthrough_decode,
        on_done = function(folders, err) got_folders = folders; got_err = err end,
    })
    h.assert_equal(got_err, "auth_failed", "discover/auth: auth failure reported")
    h.assert_nil(got_folders, "discover/auth: no folders on auth failure")
    h.assert_equal(#client.gets, 1, "discover/auth: legacy NOT tried with a bad key")
end


-- --- discover: reachable but no usable folders -------------------------------
do
    local client = make_client({
        [FD.ENDPOINT_MODERN] = { ok = true, body = { folders = {} } },
    })
    local got_folders, got_err
    FD.discover({
        client  = client,
        decode  = passthrough_decode,
        on_done = function(folders, err) got_folders = folders; got_err = err end,
    })
    h.assert_equal(got_err, "no_folders", "discover/empty: no_folders sentinel")
    h.assert_nil(got_folders, "discover/empty: no folder list")
end


-- --- integration wiring audit (static) --------------------------------------
do
    local function slurp(path)
        local f = io.open(path, "r") or io.open("../" .. path, "r")
        if not f then return "" end
        local s = f:read("*a"); f:close(); return s
    end

    -- The discovery core is consumed by the Syncthing transport's manual
    -- provider (transport.list_folders), which the folder picker calls via the
    -- Bridge.  The old _helpers wrapper (H.discover_syncthing_folders) and its
    -- background auto-discovery caller were both removed.
    local transport = slurp("syncery_transports/syncthing/transport.lua")
    h.assert_true(transport:find("FolderDiscovery.discover", 1, true) ~= nil,
        "wiring: the transport's manual provider calls the discovery core")
end



-- --- parse_status (pure): live state from /rest/db/status -------------------
do
    h.assert_equal(FD.parse_status({ state = "syncing" }), "syncing",
        "parse_status: state string surfaced")
    h.assert_equal(FD.parse_status({ state = "error" }), "error",
        "parse_status: error state surfaced")
    h.assert_nil(FD.parse_status({ state = "" }), "parse_status: empty state -> nil")
    h.assert_nil(FD.parse_status({}), "parse_status: no state field -> nil")
    h.assert_nil(FD.parse_status("not a table"), "parse_status: non-table -> nil")
end


-- --- enrich_live_state: per-folder /rest/db/status merge --------------------
do
    -- Two folders: one seeded paused (from config), one healthy.  Live status
    -- says folder 1 is syncing (overrides paused) and folder 2 is idle (stays
    -- clean -> nil).
    local folders = {
        { folder_id = "f1", path = "/a", state = "paused" },
        { folder_id = "f2", path = "/b" },
    }
    local client = make_client({
        ["/rest/db/status?folder=f1"] = { ok = true, body = { state = "syncing" } },
        ["/rest/db/status?folder=f2"] = { ok = true, body = { state = "idle" } },
    })
    local done
    FD.enrich_live_state(
        { client = client, decode = passthrough_decode, encode_query = function(s) return s end },
        folders,
        function(out) done = out end)
    h.assert_true(done ~= nil, "enrich: on_done called")
    h.assert_equal(folders[1].state, "syncing", "enrich: live syncing overrides seeded paused")
    h.assert_nil(folders[2].state, "enrich: live idle leaves the row clean (nil)")
    h.assert_equal(#client.gets, 2, "enrich: one /rest/db/status GET per folder")
    h.assert_equal(client.gets[1], "/rest/db/status?folder=f1", "enrich: queries folder 1's status")
end

do
    -- A failed status fetch leaves the seeded state untouched (best-effort).
    local f2 = { { folder_id = "p", path = "/p", state = "paused" } }
    local client2 = make_client({})  -- every GET -> { ok = false }
    local done2
    FD.enrich_live_state(
        { client = client2, decode = passthrough_decode, encode_query = function(s) return s end },
        f2, function(out) done2 = out end)
    h.assert_true(done2 ~= nil, "enrich: on_done called even when status fetch fails")
    h.assert_equal(f2[1].state, "paused", "enrich: failed status fetch keeps the seeded paused state")
end

do
    -- Empty list is a no-op that still calls on_done.
    local done3 = false
    FD.enrich_live_state({ client = make_client({}) }, {}, function() done3 = true end)
    h.assert_true(done3, "enrich: empty list still calls on_done")
end


-- --- wiring: the transport enriches discovered folders with live state ------
do
    local function slurp2(path)
        local f = io.open(path, "r") or io.open("../" .. path, "r")
        if not f then return "" end
        local s = f:read("*a"); f:close(); return s
    end
    local transport = slurp2("syncery_transports/syncthing/transport.lua")
    h.assert_true(transport:find("enrich_live_state", 1, true) ~= nil,
        "wiring: the transport's manual provider enriches folders with live state")
end
