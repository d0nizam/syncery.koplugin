-- =============================================================================
-- spec/orphan_cleanup_names_spec.lua
-- =============================================================================
--
-- Integration test for the names/skip the new `_cleanupOrphans` UI method
-- presents. The method itself goes through ConfirmBox/UIManager (not unit-
-- testable here), but the DECISION + LABELLING pipeline it runs is:
--
--     deps   = OrphanAdapters.build_deps{...}
--     result = OrphanCleanup.scan(deps)
--     for each result.orphans[i]: re-derive klass from path, display_name(...)
--
-- We reproduce exactly that pipeline over a real fake filesystem and assert the
-- user-visible names and the fail-closed count. This covers what the method
-- shows without needing the widget layer.
--
-- =============================================================================

local h = require("spec.test_helpers")
local lfs = require("lfs")
local OrphanAdapters = require("syncery_migration/orphan_adapters")
local OrphanCleanup  = require("syncery_migration/orphan_cleanup")

h.setup("/tmp/syncery_test_orphannames_" .. tostring(os.time()))
local ROOT = h.test_root

local function mkdirp(path) os.execute("mkdir -p '" .. path .. "' 2>/dev/null") end
local function wf(path, content)
    local dir = path:match("^(.*)/[^/]+$"); if dir then mkdirp(dir) end
    local f = assert(io.open(path, "wb")); f:write(content); f:close()
end
local function wmeta(path, fields)
    local parts = {}
    for k, v in pairs(fields) do parts[#parts+1] = k .. " = '" .. v .. "'" end
    wf(path, "return {\n  " .. table.concat(parts, ",\n  ") .. ",\n}\n")
end
local function content_hash(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local data = f:read("*a") or ""; f:close()
    local hsh = 5381
    for i = 1, #data do hsh = (hsh * 33 + data:byte(i)) % 4294967296 end
    return string.format("%08x", hsh)
end

-- mirror the method's klass re-derivation from a path
local function klass_of(path)
    return path:match("/synceryhash/") and "synceryhash"
        or path:match("/hashdocsettings/") and "hashdocsettings"
        or path:match("/docsettings/") and "dir"
        or "doc"
end
-- run the method's pipeline; return { names=[...], fail_closed=N }
local function run_pipeline(opts)
    local deps = OrphanAdapters.build_deps(opts)
    local r = OrphanCleanup.scan(deps)
    local names = {}
    for _, p in ipairs(r.orphans) do
        names[#names + 1] = OrphanAdapters.display_name({ path = p, klass = klass_of(p) })
    end
    table.sort(names)
    return { names = names, fail_closed = #(r.fail_closed or {}), kept = #(r.kept or {}) }
end
local function contains(t, v) for _, x in ipairs(t) do if x == v then return true end end return false end

-- ==========================================================================
-- A — mixed orphans across modes → correct user-visible names
-- ==========================================================================
do
    local home = ROOT .. "/A_home"
    local sh   = ROOT .. "/A_sh/synceryhash"

    -- doc book DELETED → orphan, name = "Gone.epub"
    local doc_sdr = home .. "/Gone.epub.sdr"
    wf(doc_sdr .. "/Gone.epub.syncery-progress.json", "{}")
    wmeta(doc_sdr .. "/metadata.epub.lua", { partial_md5_checksum = "h_gone", doc_path = home .. "/Gone.epub" })
    -- (book file not created → deleted)

    -- doc book PRESENT → kept (not shown)
    local live = home .. "/Live.epub"; wf(live, "LIVE")
    local live_sdr = home .. "/Live.epub.sdr"
    wf(live_sdr .. "/Live.epub.syncery-progress.json", "{}")
    wmeta(live_sdr .. "/metadata.epub.lua", { partial_md5_checksum = content_hash(live), doc_path = live })

    -- synceryhash DELETED → orphan, name = "Book <hash>"
    wf(sh .. "/de/deadbeef12345/syncery-progress.json", "{}")

    local out = run_pipeline({
        lfs = lfs,
        home_dir = function() return home end,
        configured_roots = function() return nil end,
        book_content_id = function(p) return content_hash(p) end,
        synceryhash_root = function() return sh end,
        dir_tree_root = function() return nil end,
        hash_tree_root = function() return nil end,
    })
    h.assert_equal(#out.names, 2, "A: two orphans shown")
    h.assert_true(contains(out.names, "Gone.epub"), "A: doc orphan shown by filename")
    h.assert_true(contains(out.names, "Book deadbeef12"), "A: synceryhash orphan shown as 'Book <short-hash>'")
    h.assert_false(contains(out.names, "Live.epub"), "A: present book NOT shown")
    h.assert_equal(out.kept, 1, "A: the live book's JSON kept")
end

-- ==========================================================================
-- B — fail-closed count surfaced (dir orphan, no metadata → undeterminable)
-- ==========================================================================
do
    local home = ROOT .. "/B_home"
    local dir  = ROOT .. "/B_dir/docsettings"
    -- a dir-mode JSON with NO metadata.lua → no hash, no doc_path → fail-closed
    wf(dir .. "/some/Book.epub.sdr/Book.epub.syncery-progress.json", "{}")

    local out = run_pipeline({
        lfs = lfs,
        home_dir = function() return home end,
        configured_roots = function() return nil end,
        book_content_id = function(_) return nil end,
        synceryhash_root = function() return nil end,
        dir_tree_root = function() return dir end,
        hash_tree_root = function() return nil end,
    })
    h.assert_equal(#out.names, 0, "B: nothing flagged as deletable orphan")
    h.assert_equal(out.fail_closed, 1, "B: one file fail-closed (skipped, surfaced to user)")
end

-- ==========================================================================
-- C — empty: no orphans, no fail-closed
-- ==========================================================================
do
    local home = ROOT .. "/C_home"
    local live = home .. "/Only.epub"; wf(live, "ONLY")
    local sdr = home .. "/Only.epub.sdr"
    wf(sdr .. "/Only.epub.syncery-progress.json", "{}")
    wmeta(sdr .. "/metadata.epub.lua", { partial_md5_checksum = content_hash(live), doc_path = live })

    local out = run_pipeline({
        lfs = lfs,
        home_dir = function() return home end,
        configured_roots = function() return nil end,
        book_content_id = function(p) return content_hash(p) end,
        synceryhash_root = function() return nil end,
        dir_tree_root = function() return nil end,
        hash_tree_root = function() return nil end,
    })
    h.assert_equal(#out.names, 0, "C: no orphans when book present")
    h.assert_equal(out.fail_closed, 0, "C: no fail-closed")
end

h.teardown()
print("orphan_cleanup_names_spec: all assertions passed")
