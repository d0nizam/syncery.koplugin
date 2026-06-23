-- =============================================================================
-- syncery_ui/booklist/init.lua
-- =============================================================================
--
-- The "Manage all books with Syncery data" orchestrator.  Split into
-- three modules:
--
--   scan.lua    — getScanRoots / promptForScanRoot / scanHash / scanSDR
--   actions.lua — per-book reset actions + the action-row builder
--   init.lua    — THIS file: showBookList + displayBookMenu
--
-- PUBLIC SURFACE (`BookList.*` compatibility)
--
--   BookList.showBookList(plugin)        — scan + show the list
--   BookList.displayBookMenu(plugin, books)
--   BookList.getScanRoots / promptForScanRoot / scanHash / scanSDR
--                                        — re-exported from scan.lua
--   BookList.showActionsForBook / resetPersonalData / fullReset
--                                        — re-exported from actions.lua
--
-- The re-exports exist so callers can require this package's `init`
-- and reach the scan + action surfaces in one place — including the
-- migration tool, which calls `BookList.scanHash` / `BookList.scanSDR`
-- directly.
--
-- ACTIONS in displayBookMenu — tap opens the per-book action menu
--
-- The split of tap = primary action from long-press = action menu
-- is NOT realized here, and
-- deliberately so: a per-book row has no cheap PRIMARY action distinct
-- from the menu.  The natural primary (a summary: annotation count,
-- last-sync) would need a per-book disk read + JSON parse the list does
-- not do, and the only other candidate (open the book) is the file
-- manager's job, not Syncery's.  So tap opens `showActionsForBook`
-- directly — and that menu is itself the second layer, so no per-item
-- gesture (tap OR hold) reaches an action in fewer than two steps.  A
-- long-press would therefore only duplicate tap; and base `Menu`'s
-- `onMenuHold` is a no-op stub (it must be OVERRIDDEN to invoke an
-- item's `hold_callback`, which this view does not do), so a per-item
-- `hold_callback` here would be dead.  Hence neither is wired: tap is
-- the single, sufficient affordance.
--
-- =============================================================================


local UIManager   = require("ui/uimanager")
local Menu        = require("ui/widget/menu")
local ConfirmBox  = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Screen      = require("device").screen
local Trapper     = require("ui/trapper")

local lfs      = require("libs/libkoreader-lfs")
local Util     = require("syncery_util")
local I18n     = require("syncery_i18n")
local _        = I18n.translate

local Scan    = require("syncery_ui/booklist/scan")
local Actions = require("syncery_ui/booklist/actions")


local BookList = {}


-- ============================================================================
-- Re-exports — keep the flat `BookList.*` surface intact
-- ============================================================================

BookList.getScanRoots       = Scan.getScanRoots
BookList.deriveRootsFromHistory = Scan.deriveRootsFromHistory
BookList.promptForScanRoot  = Scan.promptForScanRoot
BookList.scanHash           = Scan.scanHash
BookList.scanSDR            = Scan.scanSDR

BookList.showActionsForBook = Actions.showActionsForBook
BookList.resetPersonalData  = Actions.resetPersonalData
BookList.fullReset          = Actions.fullReset


-- ============================================================================
-- showBookList — scan the disk, then show the list
-- ============================================================================


function BookList.showBookList(plugin)
    -- The actual scan + display, given a concrete list of roots to walk.
    -- Split out so the interactive root picker (below) can call it AFTER
    -- the user has chosen where to look — the picker is async, so it must
    -- run before the Trapper-wrapped scan, not inside it.
    local function scan_roots_and_display(roots, offer_picker_if_empty)
        local books = {}
        local cancelled = false
        local had_any_root = roots ~= nil and #roots > 0

        local walk = Scan.make_cancellable_walk(books,
            function() return cancelled end,
            function(count)
                if Trapper and Trapper.info then
                    if not Trapper:info(string.format(
                           _("Scanning books… (%d found)"), count)) then
                        cancelled = true
                        return false
                    end
                else
                    coroutine.yield()
                end
                return true
            end)

        Trapper:wrap(function()
            Trapper:info(_("Scanning books…"))

            -- This is the management view: surface Syncery data WHEREVER it
            -- lives, not just where the current storage_mode writes.  Lazy
            -- migration (setStorageMode moves only the open book) can leave
            -- data in synceryhash/ even after a switch to SDR.
            --   * scanHash → synceryhash/ only (synceryhash STORAGE).  It is
            --     deliberately NOT given the hashdocsettings books: migration
            --     also calls scanHash, and feeding it already-migrated
            --     hashdocsettings books made move_one delete them (src==dst).
            -- SDR-storage books live in whichever of KOReader's THREE metadata
            -- locations is/was active (document_metadata_folder); cover all 3:
            --   * find_synced_books        → KOReader hashdocsettings/ ("hash")
            --   * find_synced_books_in_dir → KOReader docsettings/     ("dir")
            --   * root-walk (below)        → `<book>.sdr` beside books ("doc"),
            --     over the roots derived from history + Syncthing folders.
            -- All three share `hash_seen`, so a book in more than one is listed
            -- once.  (The "dir" finder was added to close a gap where "dir"
            -- books appeared only if the user reached the manual picker.)
            Scan.scanHash(books)

            do
                local ok_hf, HashLocationFinder =
                    pcall(require, "syncery_ann/hash_location_finder")
                if ok_hf and HashLocationFinder then
                    local hash_seen = {}
                    for __, b in ipairs(books) do
                        if b.file then hash_seen[b.file] = true end
                    end
                    local ok_ss, StateStore =
                        pcall(require, "syncery_progress/state_store")
                    local normalize = ok_ss and StateStore and StateStore.normalize or nil
                    -- KOReader metadata location = "hash": Syncery SDR files
                    -- live in hashdocsettings/.
                    local extra = HashLocationFinder.find_synced_books(hash_seen, {
                        normalize = normalize,
                    })
                    for __, b in ipairs(extra) do books[#books + 1] = b end
                    -- KOReader metadata location = "dir": Syncery SDR files
                    -- live in docsettings/.  Same seen-set → de-duped across
                    -- trees.  (Without this, "dir"-location books appeared
                    -- only if the user reached the manual picker.)
                    local extra_dir = HashLocationFinder.find_synced_books_in_dir(hash_seen, {
                        normalize = normalize,
                    })
                    for __, b in ipairs(extra_dir) do books[#books + 1] = b end
                end
            end

            local walk_seen = {}
            for __, root in ipairs(roots or {}) do
                if cancelled then break end
                walk(root, "%.syncery%-progress%.json$", walk_seen)
            end

            -- A book can surface from more than one location (e.g. a
            -- lazy-migration leftover in synceryhash AND a fresh SDR sidecar
            -- beside it).  Collapse to the first occurrence per book path;
            -- entries with no resolvable path are kept (cannot be deduped).
            do
                local seen_path, deduped = {}, {}
                for __, b in ipairs(books) do
                    if not b.file then
                        deduped[#deduped + 1] = b
                    elseif not seen_path[b.file] then
                        seen_path[b.file] = true
                        deduped[#deduped + 1] = b
                    end
                end
                for i = #books, 1, -1 do books[i] = nil end
                for __, b in ipairs(deduped) do books[#books + 1] = b end
            end

            Trapper:reset()   -- close the InfoMessage cleanly

            if cancelled and #books == 0 then
                UIManager:show(InfoMessage:new{
                    text = _("Scan cancelled."), timeout = 2 })
            elseif #books == 0 then
                -- Nothing found anywhere Syncery could have written.  Offer
                -- the picker as a true last resort, and only when we had no
                -- roots to scan (otherwise the empty result is real, not a
                -- "we didn't know where to look" problem).
                if offer_picker_if_empty and not had_any_root then
                    Scan.promptForScanRoot(function(chosen_roots)
                        scan_roots_and_display(chosen_roots, false)
                    end)
                else
                    UIManager:show(InfoMessage:new{
                        text = _("No synced books found."), timeout = 3 })
                end
            else
                table.sort(books, function(a, b)
                    return (a.display_name or ""):lower() < (b.display_name or ""):lower()
                end)
                BookList.displayBookMenu(plugin, books)
            end
        end)
    end

    -- The management view surfaces Syncery data wherever it lives.  Scan
    -- roots for the "doc" case (sidecars beside books) come from two sources,
    -- merged: the user's Syncthing folders and the folders of recently-opened
    -- books (history).  The fixed trees (synceryhash, KOReader hashdocsettings,
    -- KOReader docsettings) are always checked inside the scan regardless of
    -- roots.  The picker appears only if the scan finds nothing AND there were
    -- no roots to look in.
    local roots = Scan.getScanRoots()
    local seen_root = {}
    for __, r in ipairs(roots) do seen_root[r] = true end
    for __, r in ipairs(Scan.deriveRootsFromHistory()) do
        if not seen_root[r] then
            seen_root[r] = true
            roots[#roots + 1] = r
        end
    end
    scan_roots_and_display(roots, #roots == 0)
end


-- ============================================================================
-- displayBookMenu — the book list (tap a row → per-book action menu)
-- ============================================================================


-- Relative "synced N ago" from an epoch, for the per-book summary. Every
-- branch is an os.difftime on two epoch values → timezone-independent; a
-- future timestamp from clock skew clamps to "just now" rather than going
-- negative. Returns nil for a missing/zero mtime
-- so the row simply shows no suffix (the file isn't there yet).
local function format_synced_ago(mtime)
    if type(mtime) ~= "number" or mtime <= 0 then return nil end
    local age = os.difftime(os.time(), mtime)
    if     age < 90    then return _("synced just now")
    elseif age < 3600  then return string.format(_("synced %d min ago"),  math.floor(age / 60))
    elseif age < 86400 then return string.format(_("synced %d hr ago"),   math.floor(age / 3600))
    else                    return string.format(_("synced %d days ago"), math.floor(age / 86400))
    end
end


function BookList.displayBookMenu(plugin, books)
    local item_table = {}
    local sdr_count, hash_count = 0, 0
    for __, book in ipairs(books) do
        if book.mode == "sdr" then sdr_count = sdr_count + 1
        elseif book.mode == "hash" then hash_count = hash_count + 1 end
    end

    -- Bulk migration at top
    table.insert(item_table, {
        text = _("Migrate all books to current storage mode"),
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("Move all Syncery data from the previous storage location to the current one?\n\nBooks already in the new location will be skipped."),
                ok_text = _("Migrate"),
                ok_callback = function()
                    -- old_mode intentionally omitted (see maintenance_section):
                    -- migrate_all_books derives the source and detects the
                    -- data-already-in-current case itself.
                    plugin:_migrateAllBooks()
                end,
                cancel_text = _("Cancel"),
            })
        end,
        separator = true,
    })

    for __, book in ipairs(books) do
        local text = string.format("[%s] %s", book.mode:upper(), book.display_name)
        -- Same single stat we already did for the bullet, but now we use its
        -- mtime for a real "last synced" summary instead of a bare dot. No
        -- extra disk read, no JSON parse — just stop throwing the stat away.
        local synced = format_synced_ago(Util.file_mtime(book.annotations_path))
        if synced then
            text = text .. "  — " .. synced
        end
        local book_ref = book
        table.insert(item_table, {
            text = text,
            -- Tap opens the per-book action menu.  No hold_callback: see
            -- the ACTIONS note in the header — base Menu's onMenuHold is a
            -- no-op so it would be dead, and it would only duplicate tap.
            callback = function()
                Actions.showActionsForBook(plugin, book_ref)
            end,
        })
    end

    local menu = Menu:new{
        title = string.format(_("Synced books — %d SDR, %d Synceryhash"), sdr_count, hash_count),
        item_table = item_table,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    UIManager:show(menu)
end


return BookList
