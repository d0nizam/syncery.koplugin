-- =============================================================================
-- spec/progress_load_shared_from_path_spec.lua
-- =============================================================================
--
-- Guards syncery_progress/state_store.lua load_shared_from_path -- the
-- explicit-path reader the Progress Browser relies on.
--
-- The Progress Browser enumerates books by walking the filesystem for
-- syncery-progress.json files and carries each book's REAL progress_path
-- (synceryhash content-hash books have no derivable book_path at all).  It
-- must read those files directly, with the same empty-on-failure contract
-- load_shared gives -- never a crash, always a well-formed `entries` map.
--
-- Covers:
--   1. A file written by save_shared reads back via load_shared_from_path
--      with every device entry intact (round-trip on an explicit path).
--   2. nil path -> empty state + "no_path" (the load_shared contract).
--   3. Absent file -> empty state + "not_found" (fresh start, no crash).
--   4. load_shared(book) routes THROUGH load_shared_from_path and returns
--      the saved content end-to-end (the delegation the refactor introduced).
-- =============================================================================


local h = require("spec.test_helpers")
h.setup("/tmp/syncery_progress_load_from_path_spec_" .. tostring(os.time()))

local StateStore = require("syncery_progress/state_store")
local Paths      = require("syncery_progress/paths")


local counter = 0
local function unique_book()
    counter = counter + 1
    return h.test_root .. "/lsp_book_" .. tostring(counter) .. ".epub"
end

local function sample_entries()
    return {
        ["dev-a"] = {
            percent   = 0.61,
            timestamp = 1700000000,
            label     = "Phone",
            xpath     = "/body/DocFragment[14]/body/p[2]/text().3",
            file      = "book.epub",
        },
        ["dev-b"] = {
            percent   = 0.38,
            timestamp = 1699990000,
            label     = "Kindle",
            file      = "book.epub",
        },
    }
end


-- ---------------------------------------------------------------------------
-- 1. Round-trip on an explicit path: what save_shared wrote, the explicit
--    reader reads back -- every device entry intact.
-- ---------------------------------------------------------------------------
do
    local book = unique_book()
    StateStore.save_shared(book, { entries = sample_entries() })
    local path = Paths.shared_progress_path(book)

    local state = StateStore.load_shared_from_path(path)
    h.assert_true(type(state.entries) == "table",
        "load_shared_from_path returns an entries map")
    h.assert_true(state.entries["dev-a"] ~= nil,
        "the explicit-path read recovers the dev-a entry (not an empty state)")
    if state.entries["dev-a"] then
        h.assert_equal(state.entries["dev-a"].percent, 0.61,
            "reads the EXACT file given (dev-a percent intact)")
    end
    if state.entries["dev-b"] then
        h.assert_equal(state.entries["dev-b"].label, "Kindle",
            "all device entries survive the explicit-path read")
    end
end


-- ---------------------------------------------------------------------------
-- 2. nil path -> empty-but-well-formed state + "no_path".
-- ---------------------------------------------------------------------------
do
    local state, diag = StateStore.load_shared_from_path(nil)
    h.assert_true(next(state.entries) == nil,
        "nil path yields an empty entries map (no nil-check burden on callers)")
    h.assert_equal(diag, "no_path",
        "nil path reports the no_path diagnostic")
end


-- ---------------------------------------------------------------------------
-- 3. Absent file -> empty state + "not_found" (fresh start, no crash).
-- ---------------------------------------------------------------------------
do
    local missing = h.test_root .. "/does_not_exist_progress.json"
    local state, diag = StateStore.load_shared_from_path(missing)
    h.assert_true(next(state.entries) == nil,
        "absent file yields an empty entries map")
    h.assert_equal(diag, "not_found",
        "absent file reports not_found")
end


-- ---------------------------------------------------------------------------
-- 4. Delegation end-to-end: load_shared(book) routes through
--    load_shared_from_path and returns the saved content.
-- ---------------------------------------------------------------------------
do
    local book = unique_book()
    StateStore.save_shared(book, { entries = sample_entries() })

    local via_book = StateStore.load_shared(book)
    h.assert_true(via_book.entries["dev-a"] ~= nil,
        "load_shared(book) recovers the saved entry through the delegation")
    if via_book.entries["dev-a"] then
        h.assert_equal(via_book.entries["dev-a"].percent, 0.61,
            "load_shared(book) routes through load_shared_from_path (saved content returned)")
    end
end


print("progress_load_shared_from_path_spec: assertions complete")
