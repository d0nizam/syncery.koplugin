-- =============================================================================
-- spec/json_store_sort_keys_spec.lua
-- =============================================================================
--
-- Regression spec: syncery_ann/json_store.lua must ask the JSON encoder to
-- emit object keys in a STABLE (sorted) order.
--
-- WHY THIS MATTERS
--
-- Annotations live in the shared file as a position-keyed object, and the
-- merge is a commutative per-key last-write-wins: two devices that ingest the
-- same set of changes converge to an identical logical state.  But "identical
-- state" only becomes "identical file" if the serialization is deterministic.
-- rapidjson, by default, emits object keys in Lua table-iteration order, which
-- can differ between two devices that built the same map via different insert
-- orders.  The result is byte-different files for identical content, which
-- Syncthing (or any folder-sync) then shuttles back and forth and can turn
-- into a spurious sync-conflict.  Passing `{ sort_keys = true }` closes the
-- gap: identical state -> identical bytes -> no churn.
--
-- WHAT WE ASSERT
--
-- We assert the CONTRACT (json_store passes sort_keys=true to the encoder),
-- not the byte output.  The harness encoder is real rapidjson when it's
-- installed, but falls back to cjson otherwise, and cjson has no sort option
-- to honour -- so an output-equality test would be non-portable.  The
-- byte-determinism itself is a property of rapidjson's sort_keys and is
-- verified against the real library; here we guard that json_store keeps
-- REQUESTING it.  A spy wraps the encoder and records the options it receives.
-- =============================================================================


local h = require("spec.test_helpers")
local test_root = "/tmp/syncery_json_store_sortkeys_spec_" .. tostring(os.time())
h.setup(test_root)


-- ---------------------------------------------------------------------------
-- Spy on the JSON encoder, then (re)load JsonStore so it binds to the spy.
-- json_store calls `rapidjson.encode(...)` as a field lookup at call time, so
-- replacing the field on the module table is enough to observe the options.
-- ---------------------------------------------------------------------------

local rapidjson      = require("rapidjson")
local original_encode = rapidjson.encode
local captured_opts

rapidjson.encode = function(data, opts)
    captured_opts = opts
    return original_encode(data, opts)
end

package.loaded["syncery_ann/json_store"] = nil
local JsonStore = require("syncery_ann/json_store")


-- ---------------------------------------------------------------------------
-- A normal write requests sorted keys.
-- ---------------------------------------------------------------------------

do
    captured_opts = nil
    local path = test_root .. "/sortkeys_write.json"
    os.remove(path)
    os.remove(path .. ".tmp")

    -- Keys deliberately NOT in alphabetical insert order, to make the intent
    -- (a sorted serialization) concrete.
    local ok = JsonStore.write(path, { zebra = 1, apple = 2, mango = 3 })

    h.assert_true(ok, "write succeeds")
    h.assert_true(type(captured_opts) == "table",
        "json_store passes an options table to the JSON encoder")
    h.assert_equal(captured_opts and captured_opts.sort_keys, true,
        "json_store requests sort_keys=true so identical state serializes to identical bytes")
end


-- Restore the encoder so any later spec sharing module state is unaffected.
rapidjson.encode = original_encode
