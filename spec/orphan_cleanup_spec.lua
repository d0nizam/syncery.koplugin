-- =============================================================================
-- spec/orphan_cleanup_spec.lua
-- =============================================================================
--
-- Tests for syncery_migration/orphan_cleanup.lua — the DECISION CORE of the
-- orphan-cleanup feature (PROJECT_PLAN §23.13 / §23.13c).
--
-- The module is PURE LOGIC: all inputs arrive through injected dependency
-- functions, so these tests supply fake deps directly (no disk, no UI). This
-- mirrors the standalone 44-assertion PoC, but exercises the REAL production
-- module through the project's test harness.
--
-- Each test builds a small "world": a set of present book hashes, a list of
-- JSON entries (each tagged with its location class), and resolvers for the
-- per-entry hash / name. It then asserts the kept / orphan / fail-closed split.
--
-- =============================================================================

local h = require("spec.test_helpers")
local OrphanCleanup = require("syncery_migration/orphan_cleanup")

-- ---- helpers -------------------------------------------------------------

-- Build deps from plain tables.
--   present : { [hash]=true }
--   entries : { { path=, klass= }, ... }
--   hashes  : { [path]=hash | nil }          (json_book_hash)
--   names   : { [path]=true|false|nil }       (json_book_name_present)
local function make_deps(present, entries, hashes, names)
    return {
        present_book_hashes = function() return present end,
        syncery_jsons = function() return entries end,
        json_book_hash = function(e) return hashes[e.path] end,
        json_book_name_present = function(e) return names[e.path] end,
    }
end

-- Membership check on a result list.
local function has(list, path)
    for _, p in ipairs(list) do if p == path then return true end end
    return false
end

-- Assert a result list contains EXACTLY the given paths.
local function assert_set(list, expected, label)
    h.assert_equal(#list, #expected, label .. " (count)")
    for _, p in ipairs(expected) do
        h.assert_true(has(list, p), label .. " contains " .. p)
    end
end

-- ==========================================================================
-- contract: missing deps must assert
-- ==========================================================================
do
    local ok = pcall(function() OrphanCleanup.scan(nil) end)
    h.assert_false(ok, "scan(nil) rejects non-table deps")

    local ok2 = pcall(function() OrphanCleanup.scan({ present_book_hashes = function() end }) end)
    h.assert_false(ok2, "scan rejects incomplete deps")
end

-- ==========================================================================
-- A — every layout, book PRESENT → kept
-- ==========================================================================
do
    local present = { ["h_sh"]=true, ["h_hd"]=true, ["h_doc"]=true, ["h_dir"]=true }
    local entries = {
        { path="/sh.json",  klass="synceryhash" },
        { path="/hd.json",  klass="hashdocsettings" },
        { path="/doc.json", klass="doc" },
        { path="/dir.json", klass="dir" },
    }
    local hashes = { ["/sh.json"]="h_sh", ["/hd.json"]="h_hd", ["/doc.json"]="h_doc", ["/dir.json"]="h_dir" }
    local names  = { ["/doc.json"]=true, ["/dir.json"]=true }
    local r = OrphanCleanup.scan(make_deps(present, entries, hashes, names))
    assert_set(r.kept, { "/sh.json", "/hd.json", "/doc.json", "/dir.json" }, "A: all present kept")
    assert_set(r.orphans, {}, "A: no orphans")
    assert_set(r.fail_closed, {}, "A: no fail-closed")
end

-- ==========================================================================
-- B — every layout, book DELETED → orphan
--   (present-set empty; doc/dir names report book gone)
-- ==========================================================================
do
    local present = {}
    local entries = {
        { path="/sh.json",  klass="synceryhash" },
        { path="/hd.json",  klass="hashdocsettings" },
        { path="/doc.json", klass="doc" },
        { path="/dir.json", klass="dir" },
    }
    local hashes = { ["/sh.json"]="h_sh", ["/hd.json"]="h_hd", ["/doc.json"]="h_doc", ["/dir.json"]="h_dir" }
    local names  = { ["/doc.json"]=false, ["/dir.json"]=false }
    local r = OrphanCleanup.scan(make_deps(present, entries, hashes, names))
    assert_set(r.orphans, { "/sh.json", "/hd.json", "/doc.json", "/dir.json" }, "B: all deleted orphaned")
    assert_set(r.kept, {}, "B: nothing kept")
end

-- ==========================================================================
-- C — RENAMED (same content) → kept via hash (rename-stable), all layouts.
--   Hash still in present-set; doc/dir names would report the OLD path gone
--   but the hash match short-circuits to kept first.
-- ==========================================================================
do
    local present = { ["h_sh"]=true, ["h_hd"]=true, ["h_doc"]=true, ["h_dir"]=true }
    local entries = {
        { path="/sh.json",  klass="synceryhash" },
        { path="/hd.json",  klass="hashdocsettings" },
        { path="/doc.json", klass="doc" },
        { path="/dir.json", klass="dir" },
    }
    local hashes = { ["/sh.json"]="h_sh", ["/hd.json"]="h_hd", ["/doc.json"]="h_doc", ["/dir.json"]="h_dir" }
    local names  = { ["/doc.json"]=false, ["/dir.json"]=false }  -- old path gone after rename
    local r = OrphanCleanup.scan(make_deps(present, entries, hashes, names))
    assert_set(r.kept, { "/sh.json", "/hd.json", "/doc.json", "/dir.json" }, "C: renamed kept via hash")
    assert_set(r.orphans, {}, "C: zero false orphans on rename")
end

-- ==========================================================================
-- D — CONTENT-MODIFIED per mode (the key split):
--   content-keyed (synceryhash/hashdoc): old hash NOT in present → orphan (legit)
--   path-keyed (doc/dir): hash miss, but book still at path → kept via name
-- ==========================================================================
do
    -- present holds only the NEW (post-mod) hashes; the recorded (old) hashes differ
    local present = { ["h_doc_new"]=true, ["h_dir_new"]=true }  -- books exist with new content
    local entries = {
        { path="/sh.json",  klass="synceryhash" },
        { path="/hd.json",  klass="hashdocsettings" },
        { path="/doc.json", klass="doc" },
        { path="/dir.json", klass="dir" },
    }
    -- recorded hashes are the OLD ones (not in present)
    local hashes = { ["/sh.json"]="h_sh_old", ["/hd.json"]="h_hd_old", ["/doc.json"]="h_doc_old", ["/dir.json"]="h_dir_old" }
    local names  = { ["/doc.json"]=true, ["/dir.json"]=true }  -- doc/dir book still at its path
    local r = OrphanCleanup.scan(make_deps(present, entries, hashes, names))
    assert_set(r.orphans, { "/sh.json", "/hd.json" }, "D: content-keyed content-mod → legitimate orphan")
    assert_set(r.kept, { "/doc.json", "/dir.json" }, "D: path-keyed content-mod → kept via name fallback")
    assert_set(r.fail_closed, {}, "D: no fail-closed")
end

-- ==========================================================================
-- E — doc/dir orphan, NO hash recorded but name resolves to a gone book → orphan
--   (NOT fail-closed: the name was determinable and reported absent)
-- ==========================================================================
do
    local present = {}
    local entries = { { path="/doc.json", klass="doc" } }
    local hashes = { ["/doc.json"]=nil }     -- no partial_md5
    local names  = { ["/doc.json"]=false }   -- book gone
    local r = OrphanCleanup.scan(make_deps(present, entries, hashes, names))
    assert_set(r.orphans, { "/doc.json" }, "E: no-hash + name-gone → orphan")
    assert_set(r.fail_closed, {}, "E: not fail-closed")
end

-- ==========================================================================
-- F — true FAIL-CLOSED: path-keyed, no hash AND name undeterminable → not deleted
-- ==========================================================================
do
    local present = {}
    local entries = { { path="/dir.json", klass="dir" } }
    local hashes = { ["/dir.json"]=nil }     -- no hash
    local names  = { ["/dir.json"]=nil }     -- path undeterminable
    local r = OrphanCleanup.scan(make_deps(present, entries, hashes, names))
    assert_set(r.fail_closed, { "/dir.json" }, "F: no hash + undeterminable name → fail-closed")
    assert_set(r.orphans, {}, "F: not orphaned")
    assert_set(r.kept, {}, "F: not kept")
end

-- ==========================================================================
-- F2 — content-keyed fail-closed guard: synceryhash with nil hash (malformed path)
-- ==========================================================================
do
    local present = { ["whatever"]=true }
    local entries = { { path="/bad-sh.json", klass="synceryhash" } }
    local hashes = { ["/bad-sh.json"]=nil }  -- structural hash missing → guard
    local names  = {}
    local r = OrphanCleanup.scan(make_deps(present, entries, hashes, names))
    assert_set(r.fail_closed, { "/bad-sh.json" }, "F2: content-keyed nil hash → fail-closed guard")
    assert_set(r.orphans, {}, "F2: not blindly orphaned")
end

-- ==========================================================================
-- G — doc rename + content-mod together: hash miss AND old path gone → orphan
-- ==========================================================================
do
    local present = { ["h_new"]=true }       -- book exists with new content at new path
    local entries = { { path="/doc.json", klass="doc" } }
    local hashes = { ["/doc.json"]="h_old" } -- recorded old hash, not in present
    local names  = { ["/doc.json"]=false }   -- old path gone
    local r = OrphanCleanup.scan(make_deps(present, entries, hashes, names))
    assert_set(r.orphans, { "/doc.json" }, "G: rename+content-mod → orphan (both identities fail)")
end

-- ==========================================================================
-- H — duplicate content: another identical-content copy keeps the hash present
-- ==========================================================================
do
    local present = { ["dup"]=true }         -- a second copy still has this content
    local entries = { { path="/sh.json", klass="synceryhash" } }
    local hashes = { ["/sh.json"]="dup" }
    local names  = {}
    local r = OrphanCleanup.scan(make_deps(present, entries, hashes, names))
    assert_set(r.kept, { "/sh.json" }, "H: duplicate content → kept (other copy carries hash)")
end

-- ==========================================================================
-- I — 10-entry MIXED across all four modes / mutations
-- ==========================================================================
do
    local entries, hashes, names = {}, {}, {}
    -- present holds hashes for books that still carry their recorded identity
    local present = {}
    -- helper to add an entry
    local function add(path, klass, recorded_hash, in_present, name_present)
        entries[#entries+1] = { path=path, klass=klass }
        hashes[path] = recorded_hash
        if name_present ~= nil then names[path] = name_present end
        if in_present then present[recorded_hash] = true end
    end
    add("/01.json","synceryhash","h01",true)                 -- present  → kept
    add("/02.json","synceryhash","h02",false)                -- deleted  → orphan
    add("/03.json","synceryhash","h03",false)                -- content-mod → orphan (content-keyed)
    add("/04.json","hashdocsettings","h04",true)             -- present  → kept
    add("/05.json","hashdocsettings","h05",false)            -- content-mod → orphan (content-keyed)
    add("/06.json","doc","h06",true,true)                    -- present  → kept
    add("/07.json","doc","h07",false,false)                  -- deleted  → orphan
    add("/08.json","doc","h08",false,true)                   -- content-mod → kept (name)
    add("/09.json","dir","h09",true,false)                   -- renamed  → kept (hash)
    add("/10.json","dir","h10",false,true)                   -- content-mod → kept (name)
    local r = OrphanCleanup.scan(make_deps(present, entries, hashes, names))
    assert_set(r.orphans, { "/02.json", "/03.json", "/05.json", "/07.json" }, "I: 10-mixed orphans")
    assert_set(r.kept, { "/01.json","/04.json","/06.json","/08.json","/09.json","/10.json" }, "I: 10-mixed kept")
    assert_set(r.fail_closed, {}, "I: 10-mixed no fail-closed")
end

-- ==========================================================================
-- J — 60-entry STRESS: synceryhash; first 30 deleted, last 30 present
-- ==========================================================================
do
    local entries, hashes = {}, {}
    local present = {}
    local expect_orphan = {}
    for i = 1, 60 do
        local path = "/s" .. i .. ".json"
        local hash = "sh" .. i
        entries[#entries+1] = { path=path, klass="synceryhash" }
        hashes[path] = hash
        if i > 30 then present[hash] = true else expect_orphan[#expect_orphan+1] = path end
    end
    local r = OrphanCleanup.scan(make_deps(present, entries, hashes, {}))
    assert_set(r.orphans, expect_orphan, "J: stress — exactly the 30 deleted flagged")
    h.assert_equal(#r.kept, 30, "J: stress — exactly 30 kept")
end

-- ==========================================================================
-- K — same book in MULTIPLE locations (scattered): present→both kept; deleted→both orphan
-- ==========================================================================
do
    -- present (book exists, same content → hash present)
    local present1 = { ["hmulti"]=true }
    local entries = {
        { path="/multi-sh.json",  klass="synceryhash" },
        { path="/multi-doc.json", klass="doc" },
    }
    local hashes = { ["/multi-sh.json"]="hmulti", ["/multi-doc.json"]="hmulti" }
    local names  = { ["/multi-doc.json"]=true }
    local r1 = OrphanCleanup.scan(make_deps(present1, entries, hashes, names))
    assert_set(r1.kept, { "/multi-sh.json", "/multi-doc.json" }, "K: scattered present → both kept")

    -- deleted
    local names2 = { ["/multi-doc.json"]=false }
    local r2 = OrphanCleanup.scan(make_deps({}, entries, hashes, names2))
    assert_set(r2.orphans, { "/multi-sh.json", "/multi-doc.json" }, "K: scattered deleted → both orphan")
end

-- ==========================================================================
-- L — empty world: no entries → empty result (no crash)
-- ==========================================================================
do
    local r = OrphanCleanup.scan(make_deps({}, {}, {}, {}))
    assert_set(r.orphans, {}, "L: empty → no orphans")
    assert_set(r.kept, {}, "L: empty → nothing kept")
    assert_set(r.fail_closed, {}, "L: empty → nothing fail-closed")
end

print("orphan_cleanup_spec: all assertions passed")
