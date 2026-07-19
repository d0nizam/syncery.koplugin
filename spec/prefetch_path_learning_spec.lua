-- =============================================================================
-- spec/prefetch_path_learning_spec.lua
-- =============================================================================
--
-- Coverage for the "locate prefetch-only book, learn from it" feature:
-- PluginSync.compute_path_prefix_rule (derive a peer->local path
-- substitution from one manually-confirmed match) and
-- PluginSync.resolve_via_learned_rules (apply learned rules to a NEW
-- prefetch-only book, hash-verifying every candidate before accepting
-- it).
--
-- =============================================================================

local h = require("spec.test_helpers")
local test_root = "/tmp/prefetch_path_learning_spec_" .. tostring(os.time())
h.setup(test_root)

local PluginSync = require("syncery_transports/plugin_sync")


-- ----------------------------------------------------------------------------
-- compute_path_prefix_rule
-- ----------------------------------------------------------------------------

do
    local rule = PluginSync.compute_path_prefix_rule(
        "/storage/emulated/0/Books/Livros Jurídicos/SomeBook.epub",
        "/mnt/us/documents/Livros Jurídicos/SomeBook.epub")
    h.assert_true(rule ~= nil, "a rule is derived when paths share a trailing run")
    h.assert_equal(rule.peer_prefix, "/storage/emulated/0/Books/",
        "peer_prefix is everything before the 2 matching trailing components")
    h.assert_equal(rule.local_prefix, "/mnt/us/documents/",
        "local_prefix is everything before the matching trailing components, local side")
end

do
    -- Only the filename matches (different folder structure entirely).
    local rule = PluginSync.compute_path_prefix_rule(
        "/storage/emulated/0/Books/SomeBook.epub",
        "/mnt/us/documents/fiction/SomeBook.epub")
    h.assert_true(rule ~= nil, "a rule is derived even with just the filename matching")
    h.assert_equal(rule.peer_prefix, "/storage/emulated/0/Books/")
    h.assert_equal(rule.local_prefix, "/mnt/us/documents/fiction/")
end

do
    -- Nothing matches at all -- not even the filename.
    local rule = PluginSync.compute_path_prefix_rule(
        "/storage/emulated/0/Books/BookA.epub",
        "/mnt/us/documents/BookB.epub")
    h.assert_nil(rule, "no matching trailing component at all -> nil, nothing useful to learn")
end

do
    h.assert_nil(PluginSync.compute_path_prefix_rule(nil, "/a/b.epub"), "nil peer_path -> nil")
    h.assert_nil(PluginSync.compute_path_prefix_rule("/a/b.epub", nil), "nil local_path -> nil")
    h.assert_nil(PluginSync.compute_path_prefix_rule("", "/a/b.epub"), "empty peer_path -> nil")
end

do
    -- Component-boundary safety: "eBooks" must not spuriously match
    -- "Books" mid-component.
    local rule = PluginSync.compute_path_prefix_rule(
        "/storage/eBooks/Title.epub",
        "/mnt/Books/Title.epub")
    h.assert_true(rule ~= nil, "still matches on the filename component")
    h.assert_equal(rule.peer_prefix, "/storage/eBooks/",
        "match is on the whole 'Title.epub' component, not a partial 'Books'/'eBooks' overlap")
    h.assert_equal(rule.local_prefix, "/mnt/Books/")
end


-- ----------------------------------------------------------------------------
-- resolve_via_learned_rules
-- ----------------------------------------------------------------------------

do
    -- Real file on disk, real content-id computed via util.partialMD5's
    -- fallback path (no cached doc_settings for a file test_helpers never
    -- opened) -- Paths._book_content_id must genuinely compute a hash for
    -- this to work, so this test proves the FULL, real chain, not a stub.
    local book_dir = test_root .. "/mylib/Livros Jurídicos"
    os.execute("mkdir -p '" .. book_dir .. "'")
    local local_path = book_dir .. "/SomeBook.epub"
    local f = io.open(local_path, "wb")
    f:write("fake epub content for hashing, needs to be a real file on disk")
    f:close()

    local Paths = require("syncery_ann/paths")
    local real_id = Paths._book_content_id(local_path)
    h.assert_true(type(real_id) == "string" and real_id ~= "",
        "sanity: a real content id was computed for the test file")

    local peer_path = "/storage/emulated/0/Books/Livros Jurídicos/SomeBook.epub"
    -- Derive the rule the SAME way the real UI flow would -- via
    -- compute_path_prefix_rule itself, not hand-built -- so this test
    -- exercises the two functions together, matching real usage.
    local rules = { PluginSync.compute_path_prefix_rule(peer_path, local_path) }

    local resolved = PluginSync.resolve_via_learned_rules(peer_path, real_id, rules)
    h.assert_equal(resolved, local_path,
        "a correct, hash-verified rule resolves the new peer_path to the real local file")
end

do
    -- Rule's prefix matches, candidate path exists on disk, but the
    -- CONTENT doesn't match the target book_id -- must be rejected, not
    -- opened. This is the safety net: a coincidental filename match
    -- across two DIFFERENT books must never open the wrong one.
    local book_dir = test_root .. "/mylib2"
    os.execute("mkdir -p '" .. book_dir .. "'")
    local wrong_file = book_dir .. "/SameFilename.epub"
    local f = io.open(wrong_file, "wb")
    f:write("completely different content -- a different book with the same filename")
    f:close()

    local rules = { { peer_prefix = "/peer/root/", local_prefix = book_dir .. "/" } }
    local resolved = PluginSync.resolve_via_learned_rules(
        "/peer/root/SameFilename.epub", "SOME-OTHER-BOOK-ID-ENTIRELY", rules)
    h.assert_nil(resolved,
        "SAFETY NET: prefix matched and the file exists, but its content-id "
        .. "does not match the target -- resolve_via_learned_rules must "
        .. "reject it, never open the wrong book off a coincidental "
        .. "filename/prefix match")
end

do
    -- Rule's prefix matches but no file exists at the candidate path at
    -- all (book was moved/deleted since the rule was learned).
    local rules = { { peer_prefix = "/peer/root/", local_prefix = "/tmp/does-not-exist-" .. tostring(os.time()) .. "/" } }
    local resolved = PluginSync.resolve_via_learned_rules(
        "/peer/root/Book.epub", "any-id", rules)
    h.assert_nil(resolved, "candidate path does not exist on disk -> nil, no raise")
end

do
    -- No rule's prefix matches this peer_path at all.
    local rules = { { peer_prefix = "/some/other/root/", local_prefix = "/tmp/lib/" } }
    local resolved = PluginSync.resolve_via_learned_rules(
        "/completely/different/root/Book.epub", "any-id", rules)
    h.assert_nil(resolved, "no rule's peer_prefix matches -> nil")
end

do
    -- Multiple rules: the FIRST one that hash-verifies wins, even if an
    -- earlier rule's prefix also matched but failed verification.
    local book_dir = test_root .. "/mylib3"
    os.execute("mkdir -p '" .. book_dir .. "'")
    local right_file = book_dir .. "/Book.epub"
    local f = io.open(right_file, "wb")
    f:write("the correct book's content")
    f:close()
    local Paths = require("syncery_ann/paths")
    local real_id = Paths._book_content_id(right_file)

    -- A wrong-file directory that ALSO has a file at the same relative
    -- name but with different content, tried FIRST.
    local wrong_dir = test_root .. "/mylib3_wrong"
    os.execute("mkdir -p '" .. wrong_dir .. "'")
    local wf = io.open(wrong_dir .. "/Book.epub", "wb")
    wf:write("some unrelated content"); wf:close()

    local rules = {
        { peer_prefix = "/peer/", local_prefix = wrong_dir .. "/" },  -- tried first, wrong content
        { peer_prefix = "/peer/", local_prefix = book_dir .. "/" },   -- tried second, correct
    }
    local resolved = PluginSync.resolve_via_learned_rules("/peer/Book.epub", real_id, rules)
    h.assert_equal(resolved, right_file,
        "the first rule fails verification (wrong content) and is skipped; "
        .. "the second, correct rule is used instead")
end

do
    h.assert_nil(PluginSync.resolve_via_learned_rules(nil, "id", {}), "nil peer_path -> nil")
    h.assert_nil(PluginSync.resolve_via_learned_rules("/a/b.epub", nil, {}), "nil target_book_id -> nil")
    h.assert_nil(PluginSync.resolve_via_learned_rules("/a/b.epub", "id", nil), "nil rules -> nil")
    h.assert_nil(PluginSync.resolve_via_learned_rules("/a/b.epub", "id", {}), "empty rules list -> nil")
end

os.execute("rm -rf " .. test_root)

print("prefetch_path_learning_spec: all assertions passed")
