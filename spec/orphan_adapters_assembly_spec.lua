-- =============================================================================
-- spec/orphan_adapters_assembly_spec.lua
-- =============================================================================
--
-- Tests for OrphanAdapters.build_deps (syncery_migration/orphan_adapters.lua) —
-- the production wiring that assembles the real-world getters into a single deps
-- table for OrphanCleanup.scan.
--
-- We drive it through `opts` overrides (so no G_reader_settings / DataStorage
-- globals are needed) against a real temporary filesystem, and run the assembled
-- deps end-to-end through the decision core. Also checks graceful degradation
-- when getters return nil.
--
-- =============================================================================

local h = require("spec.test_helpers")
local lfs = require("lfs")
local OrphanAdapters = require("syncery_migration/orphan_adapters")
local OrphanCleanup  = require("syncery_migration/orphan_cleanup")

h.setup("/tmp/syncery_test_orphanasm_" .. tostring(os.time()))
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
local function has(list, path)
    for _, p in ipairs(list) do if p == path then return true end end
    return false
end

-- ==========================================================================
-- A — build_deps returns the four callable deps
-- ==========================================================================
do
    local deps = OrphanAdapters.build_deps({
        lfs = lfs,
        home_dir = function() return ROOT .. "/A_home" end,
        configured_roots = function() return nil end,
        book_content_id = function(p) return content_hash(p) end,
        synceryhash_root = function() return nil end,
        dir_tree_root = function() return nil end,
        hash_tree_root = function() return nil end,
    })
    h.assert_equal(type(deps.present_book_hashes), "function", "A: present_book_hashes is a function")
    h.assert_equal(type(deps.syncery_jsons), "function", "A: syncery_jsons is a function")
    h.assert_equal(type(deps.json_book_hash), "function", "A: json_book_hash is a function")
    h.assert_equal(type(deps.json_book_name_present), "function", "A: json_book_name_present is a function")
end

-- ==========================================================================
-- B — END-TO-END through the core: a deleted synceryhash book → orphan,
--     a present doc book → kept, all via the assembled deps
-- ==========================================================================
do
    local home = ROOT .. "/B_home"
    local sh   = ROOT .. "/B_sh/synceryhash"

    -- present doc book + its JSON + metadata
    local doc_book = home .. "/Live.epub"
    wf(doc_book, "LIVE-CONTENT")
    local doc_sdr = home .. "/Live.epub.sdr"
    local doc_json = doc_sdr .. "/Live.epub.syncery-progress.json"
    wf(doc_json, "{}")
    wmeta(doc_sdr .. "/metadata.epub.lua", { partial_md5_checksum = content_hash(doc_book), doc_path = doc_book })

    -- deleted synceryhash book: its JSON keyed by a hash no present book carries
    local sh_json = sh .. "/de/deletedhash99/syncery-progress.json"
    wf(sh_json, "{}")

    local deps = OrphanAdapters.build_deps({
        lfs = lfs,
        home_dir = function() return home end,
        configured_roots = function() return nil end,
        book_content_id = function(p) return content_hash(p) end,
        synceryhash_root = function() return sh end,
        dir_tree_root = function() return nil end,
        hash_tree_root = function() return nil end,
    })
    local r = OrphanCleanup.scan(deps)
    h.assert_true(has(r.kept, doc_json),    "B: present doc book's JSON kept (assembled)")
    h.assert_true(has(r.orphans, sh_json),  "B: deleted synceryhash JSON orphaned (assembled)")
end

-- ==========================================================================
-- C — home_dir ∪ configured-roots union flows through to BOTH present-hashes
--     AND doc-JSON enumeration (a doc JSON in a configured root is found)
-- ==========================================================================
do
    local home  = ROOT .. "/C_home"
    local extra = ROOT .. "/C_extra"
    -- a present book in home (so its hash is in present-set)
    wf(home .. "/InHome.epub", "INHOME")
    -- a doc-mode JSON living in the EXTRA configured root, book present there
    local extra_book = extra .. "/Out.epub"
    wf(extra_book, "OUT-CONTENT")
    local extra_sdr = extra .. "/Out.epub.sdr"
    local extra_json = extra_sdr .. "/Out.epub.syncery-progress.json"
    wf(extra_json, "{}")
    wmeta(extra_sdr .. "/metadata.epub.lua", { partial_md5_checksum = content_hash(extra_book), doc_path = extra_book })

    local deps = OrphanAdapters.build_deps({
        lfs = lfs,
        home_dir = function() return home end,
        configured_roots = function() return { extra } end,   -- OPPORTUNISTIC
        book_content_id = function(p) return content_hash(p) end,
        synceryhash_root = function() return nil end,
        dir_tree_root = function() return nil end,
        hash_tree_root = function() return nil end,
    })
    local r = OrphanCleanup.scan(deps)
    -- the extra-root JSON is both enumerated (doc roots include extra) and its
    -- book present (hash in present-set) → kept
    h.assert_true(has(r.kept, extra_json), "C: doc JSON in configured root enumerated + kept")
    h.assert_false(has(r.orphans, extra_json), "C: not falsely orphaned")
end

-- ==========================================================================
-- D — graceful degradation: ALL getters nil → empty scan, no crash
-- ==========================================================================
do
    local deps = OrphanAdapters.build_deps({
        lfs = lfs,
        home_dir = function() return nil end,
        configured_roots = function() return nil end,
        book_content_id = function(_) return nil end,
        synceryhash_root = function() return nil end,
        dir_tree_root = function() return nil end,
        hash_tree_root = function() return nil end,
    })
    local r = OrphanCleanup.scan(deps)
    h.assert_equal(#r.orphans, 0, "D: nothing orphaned with all getters nil")
    h.assert_equal(#r.kept, 0, "D: nothing kept")
    h.assert_equal(#r.fail_closed, 0, "D: nothing fail-closed")
end

-- ==========================================================================
-- E — build_deps with NO opts (production defaults) must not crash: it resolves
--     real getters (which return nil in the test env) and yields a scannable
--     deps table. We only assert it runs and returns the expected shape.
-- ==========================================================================
do
    local ok, deps = pcall(OrphanAdapters.build_deps)
    h.assert_true(ok, "E: build_deps() with no opts does not error")
    h.assert_equal(type(deps.present_book_hashes), "function", "E: yields present_book_hashes")
    -- scanning may walk real (absent) trees; it must not crash and must be empty-ish
    local ok2, r = pcall(OrphanCleanup.scan, deps)
    h.assert_true(ok2, "E: scanning the default-assembled deps does not error")
    h.assert_equal(type(r.orphans), "table", "E: result has orphans table")
end

-- ==========================================================================
-- F — opts.load_metadata override is threaded into the resolvers. The resolver
-- correctly requires the sibling metadata FILE to exist (the loader reads a real
-- path), so we write a real metadata.epub.lua and inject a loader that returns
-- custom fields for it — proving the override is used, not the default dofile.
-- ==========================================================================
do
    local home = ROOT .. "/F_home"
    local doc_sdr = home .. "/F.epub.sdr"
    local doc_json = doc_sdr .. "/F.epub.syncery-progress.json"
    wf(doc_json, "{}")
    wf(doc_sdr .. "/metadata.epub.lua", "return {}")   -- real file (content irrelevant; loader overridden)
    local injected_hash = "injected123"
    local seen_path = nil
    local deps = OrphanAdapters.build_deps({
        lfs = lfs,
        home_dir = function() return home end,
        configured_roots = function() return nil end,
        book_content_id = function(_) return nil end,
        synceryhash_root = function() return nil end,
        dir_tree_root = function() return nil end,
        hash_tree_root = function() return nil end,
        load_metadata = function(p) seen_path = p; return { partial_md5_checksum = injected_hash, doc_path = "/nope" } end,
    })
    local hash = deps.json_book_hash({ path = doc_json, klass = "doc" })
    h.assert_equal(hash, injected_hash, "F: injected load_metadata used by json_book_hash")
    h.assert_equal(seen_path, doc_sdr .. "/metadata.epub.lua", "F: loader called with the real sibling metadata path")
end

h.teardown()
print("orphan_adapters_assembly_spec: all assertions passed")
