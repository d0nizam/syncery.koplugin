-- =============================================================================
-- spec/migration_resolve_not_here_spec.lua
-- =============================================================================
--
-- Coverage for StorageMode.resolve_not_here_books: the iterative
-- locate+learn flow that "Migrate all books to this storage mode…" now
-- runs on books whose book.file didn't resolve here, BEFORE reporting
-- them as simply absent. Root cause: the plain book_path resolution
-- (Scan.scanHash) has no way to invoke the "locate the file" flow
-- (syncery_ui/prefetch_locate.lua) that Progress/Annotation Browser
-- already use for the same underlying situation.
--
-- PrefetchLocate itself is stubbed here (its own pure functions are
-- already covered by spec/prefetch_locate_spec.lua) -- this spec is
-- about resolve_not_here_books' OWN orchestration: does it try
-- auto-resolve first, does it prompt only for what remains, does a
-- newly-learned rule get retried against the rest, does cancel/skip
-- stop cleanly.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup()

package.loaded["ui/uimanager"] = { show = function() end, close = function() end }
local shown_confirmboxes = {}
package.loaded["ui/widget/confirmbox"] = {
    new = function(_, args)
        table.insert(shown_confirmboxes, args)
        return args
    end,
}

local StorageMode = require("syncery_migration/storage_mode")
-- Same, already-cached PrefetchLocate instance storage_mode.lua itself
-- uses (do NOT reset package.loaded and re-require here -- that would
-- create a SEPARATE table storage_mode.lua's own already-bound local
-- reference would never see, exactly the upvalue-caching pitfall this
-- session traced at length for prefetch_locate.lua's own Settings
-- upvalue).
local PrefetchLocate = require("syncery_ui/prefetch_locate")
local PluginSync     = require("syncery_transports/plugin_sync")

-- peer_path_for_book (storage_mode.lua's own local helper) reads each
-- book's progress_path FILE via PluginSync.extract_title_hint -- stub
-- that instead of writing real fixture files for every book below,
-- since these tests are about resolve_not_here_books' OWN orchestration
-- (already-covered separately: extract_title_hint itself in
-- spec/cloud_prefetch_spec.lua).
local saved_extract_title_hint = PluginSync.extract_title_hint
PluginSync.extract_title_hint = function(progress_path)
    return "title", "/peer/" .. (progress_path:match("([^/]+)%.json$") or "x") .. ".epub"
end


-- ----------------------------------------------------------------------------
-- All books auto-resolve via already-learned rules: no dialog at all.
-- ----------------------------------------------------------------------------

do
    shown_confirmboxes = {}
    local saved_try = PrefetchLocate.try_auto_resolve
    PrefetchLocate.try_auto_resolve = function(book_id, _peer_path)
        return "/resolved/" .. book_id .. ".epub"
    end

    local books = {
        { book_id = "id1", progress_path = "/fake/p1.json" },
        { book_id = "id2", progress_path = "/fake/p2.json" },
    }
    local done_with
    StorageMode.resolve_not_here_books(books, function(resolved) done_with = resolved end)

    h.assert_equal(#shown_confirmboxes, 0, "no dialog shown -- everything auto-resolved")
    h.assert_true(done_with ~= nil, "on_done fired")
    h.assert_equal(#done_with, 2, "both books resolved")
    h.assert_equal(books[1].file, "/resolved/id1.epub", "book.file filled in for book 1")
    h.assert_equal(books[2].file, "/resolved/id2.epub", "book.file filled in for book 2")

    PrefetchLocate.try_auto_resolve = saved_try
end


-- ----------------------------------------------------------------------------
-- Nothing auto-resolves; user cancels/skips the dialog: on_done fires
-- with an EMPTY resolved list, no crash.
-- ----------------------------------------------------------------------------

do
    shown_confirmboxes = {}
    local saved_try = PrefetchLocate.try_auto_resolve
    PrefetchLocate.try_auto_resolve = function() return nil end

    local books = { { book_id = "id3", progress_path = "/fake/p3.json" } }
    local done_with
    StorageMode.resolve_not_here_books(books, function(resolved) done_with = resolved end)

    h.assert_equal(#shown_confirmboxes, 1, "one dialog shown, asking to locate")
    h.assert_true(shown_confirmboxes[1].text:find("1 book couldn't be found", 1, true) ~= nil,
        "dialog text names the count")

    -- Simulate the user tapping "Skip" (cancel_callback).
    shown_confirmboxes[1].cancel_callback()

    h.assert_true(done_with ~= nil, "on_done fired after skip")
    h.assert_equal(#done_with, 0, "nothing resolved when the user skips")

    PrefetchLocate.try_auto_resolve = saved_try
end


-- ----------------------------------------------------------------------------
-- Manual locate for the FIRST unresolved book succeeds, learns a rule,
-- and the SAME rule then auto-resolves the rest -- no second dialog.
-- ----------------------------------------------------------------------------

do
    shown_confirmboxes = {}
    local saved_try    = PrefetchLocate.try_auto_resolve
    local saved_prompt = PrefetchLocate.prompt

    local auto_resolve_calls = 0
    -- First pass (before manual locate): nothing resolves. Second pass
    -- (after manual locate "learns"): resolves id5 too, simulating a
    -- rule that now covers it.
    PrefetchLocate.try_auto_resolve = function(book_id, _peer_path)
        auto_resolve_calls = auto_resolve_calls + 1
        if auto_resolve_calls > 2 and book_id == "id5" then
            return "/resolved/id5.epub"
        end
        return nil
    end
    PrefetchLocate.prompt = function(book_id, _peer_path, on_opened, _explain_text)
        on_opened("/resolved/" .. book_id .. ".epub")
    end

    local books = {
        { book_id = "id4", progress_path = "/fake/p4.json" },
        { book_id = "id5", progress_path = "/fake/p5.json" },
    }
    local done_with
    StorageMode.resolve_not_here_books(books, function(resolved) done_with = resolved end)

    h.assert_equal(#shown_confirmboxes, 1, "one dialog shown for the two unresolved books")
    -- Simulate the user tapping "Point one out…".
    shown_confirmboxes[1].ok_callback()

    h.assert_true(done_with ~= nil, "on_done fired")
    h.assert_equal(#done_with, 2, "both books end up resolved")
    h.assert_equal(books[1].file, "/resolved/id4.epub", "manually-located book gets its file")
    h.assert_equal(books[2].file, "/resolved/id5.epub", "second book auto-resolved after the rule was learned")

    PrefetchLocate.try_auto_resolve = saved_try
    PrefetchLocate.prompt = saved_prompt
end


-- ----------------------------------------------------------------------------
-- Empty input: on_done fires immediately with an empty list, no dialog.
-- ----------------------------------------------------------------------------

do
    shown_confirmboxes = {}
    local done_with
    StorageMode.resolve_not_here_books({}, function(resolved) done_with = resolved end)
    h.assert_equal(#shown_confirmboxes, 0, "no dialog for an empty input list")
    h.assert_true(done_with ~= nil and #done_with == 0, "on_done fires immediately, empty")
end

PluginSync.extract_title_hint = saved_extract_title_hint

print("migration_resolve_not_here_spec: all assertions passed")
