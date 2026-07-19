-- =============================================================================
-- spec/prefetch_locate_spec.lua
-- =============================================================================
--
-- Coverage for syncery_ui/prefetch_locate.lua's PURE half:
-- try_auto_resolve (apply already-learned rules, no prompting) and
-- verify_and_learn (given a user-picked file, verify + persist a new
-- rule). The UI half (prompt) is not covered here -- no real KOReader
-- UI in this sandbox, matching main.lua's own testing constraint; kept
-- deliberately thin in the module itself for exactly this reason.
--
-- =============================================================================

local h = require("spec.test_helpers")
local test_root = "/tmp/prefetch_locate_spec_" .. tostring(os.time())
h.setup(test_root)

local PrefetchLocate = require("syncery_ui/prefetch_locate")
local Settings       = require("syncery_settings")
local Paths          = require("syncery_ann/paths")


-- ----------------------------------------------------------------------------
-- try_auto_resolve
-- ----------------------------------------------------------------------------

do
    h.assert_nil(PrefetchLocate.try_auto_resolve("some-id", "/peer/Book.epub"),
        "no learned rules yet -> nil, no raise")
    h.assert_nil(PrefetchLocate.try_auto_resolve(nil, "/peer/Book.epub"), "nil book_id -> nil")
    h.assert_nil(PrefetchLocate.try_auto_resolve("id", nil), "nil peer_path -> nil")
end

do
    -- A learned rule exists and correctly resolves a NEW book under the
    -- same peer folder, without ever prompting.
    local lib_dir = test_root .. "/autolib"
    os.execute("mkdir -p '" .. lib_dir .. "'")
    local local_path = lib_dir .. "/NewBook.epub"
    local f = io.open(local_path, "wb")
    f:write("some real content for this second book")
    f:close()
    local real_id = Paths._book_content_id(local_path)

    Settings.add_prefetch_path_rule("/peer/root/", lib_dir .. "/")

    local resolved = PrefetchLocate.try_auto_resolve(real_id, "/peer/root/NewBook.epub")
    h.assert_equal(resolved, local_path,
        "an existing learned rule auto-resolves a NEW book under the same peer folder")
end

do
    -- MRU: a rule that just successfully resolved a book gets bumped to
    -- the front, so the NEXT prefetch-only book (common case: several
    -- in a row right after a Sync Now) tries it first. Uses prefixes
    -- not touched by any earlier block in this file, so this test does
    -- not depend on (or get confused by) whatever rules earlier blocks
    -- already persisted.
    local lib_a = test_root .. "/mru_a"
    os.execute("mkdir -p '" .. lib_a .. "'")
    local file_a = lib_a .. "/BookA.epub"
    local fa = io.open(file_a, "wb"); fa:write("book A content"); fa:close()
    local id_a = Paths._book_content_id(file_a)

    Settings.add_prefetch_path_rule("/mru-test/older/", "/nowhere/stale/")
    Settings.add_prefetch_path_rule("/mru-test/rootA/", lib_a .. "/")

    local resolved = PrefetchLocate.try_auto_resolve(id_a, "/mru-test/rootA/BookA.epub")
    h.assert_equal(resolved, file_a, "resolves correctly via the matching rule")

    h.assert_equal(Settings.get_prefetch_path_rules()[1].peer_prefix, "/mru-test/rootA/",
        "the rule that just resolved is now FIRST in the list -- MRU bump applied")
end


-- ----------------------------------------------------------------------------
-- verify_and_learn
-- ----------------------------------------------------------------------------

do
    local lib_dir = test_root .. "/verifylib"
    os.execute("mkdir -p '" .. lib_dir .. "'")
    local selected_path = lib_dir .. "/Picked.epub"
    local f = io.open(selected_path, "wb")
    f:write("the actual content of the picked file")
    f:close()
    local real_id = Paths._book_content_id(selected_path)

    local matched, learned = PrefetchLocate.verify_and_learn(
        real_id, "/peer/somewhere/Picked.epub", selected_path)
    h.assert_true(matched, "content-id matches -> matched=true")
    h.assert_true(learned ~= nil, "a NEW rule was learned and reported back")
    h.assert_equal(learned.peer_prefix, "/peer/somewhere/")
    h.assert_equal(learned.local_prefix, lib_dir .. "/")

    -- Confirm it was actually PERSISTED (not just returned).
    local rules = Settings.get_prefetch_path_rules()
    local found = false
    for _, r in ipairs(rules) do
        if r.peer_prefix == "/peer/somewhere/" and r.local_prefix == lib_dir .. "/" then
            found = true
        end
    end
    h.assert_true(found, "the learned rule was persisted via Settings.add_prefetch_path_rule")
end

do
    -- Mismatch: content-id does not match the target -- must report
    -- false and must NOT learn anything (a wrong file must never teach
    -- Syncery a wrong rule).
    local lib_dir = test_root .. "/mismatchlib"
    os.execute("mkdir -p '" .. lib_dir .. "'")
    local wrong_path = lib_dir .. "/Wrong.epub"
    local f = io.open(wrong_path, "wb")
    f:write("this is definitely not the right book")
    f:close()

    local rules_before = #Settings.get_prefetch_path_rules()
    local matched, learned = PrefetchLocate.verify_and_learn(
        "some-target-id-that-wont-match", "/peer/x/Wrong.epub", wrong_path)
    h.assert_false(matched, "content-id mismatch -> matched=false")
    h.assert_nil(learned, "no rule reported on mismatch")
    h.assert_equal(#Settings.get_prefetch_path_rules(), rules_before,
        "SAFETY NET: a mismatched file never gets to persist a rule, even a wrong one")
end

do
    -- Matched, but peer_path unknown (nothing to derive a rule from) --
    -- still a genuine match, just nothing new learned.
    local lib_dir = test_root .. "/nopeerlib"
    os.execute("mkdir -p '" .. lib_dir .. "'")
    local selected_path = lib_dir .. "/Solo.epub"
    local f = io.open(selected_path, "wb")
    f:write("solo book content")
    f:close()
    local real_id = Paths._book_content_id(selected_path)

    local matched, learned = PrefetchLocate.verify_and_learn(real_id, nil, selected_path)
    h.assert_true(matched, "matches even without a peer_path to learn from")
    h.assert_nil(learned, "nothing learned when peer_path is unavailable")
end

do
    local matched, learned = PrefetchLocate.verify_and_learn(nil, "/p/x.epub", "/l/x.epub")
    h.assert_false(matched, "nil book_id -> matched=false, no raise")
    h.assert_nil(learned)
end

print("prefetch_locate_spec: all assertions passed")
