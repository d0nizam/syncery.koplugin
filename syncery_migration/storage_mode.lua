-- =============================================================================
-- syncery_migration/storage_mode.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- The storage-mode migration: moving a book's Syncery files (progress
-- + annotations) between the two on-disk LAYOUTS Syncery supports —
--
--     SDR  : files in the book's `.sdr` sidecar directory
--     hash : files in <state_dir>/<book_md5>/
--
-- An ongoing user feature: a user who switches the "Storage mode"
-- setting expects their existing books' files to follow.  Implemented
-- here as plugin-parameter functions (the `syncery_lifecycle/teardown.lua`
-- pattern).
--
-- `main.lua` keeps one-line delegator methods (`_migrateAllBooks`,
-- `_migrateBookFiles`, `migrateSingleBook`) so the
-- live UI callers in `syncery_ui/booklist/` and
-- `syncery_ui/menu/maintenance_section.lua` are unchanged.
--
-- NOTE — this is DISTINCT from `annotation_format.lua` in the same
-- package.  This module moves files between path layouts; that module
-- converts a single file's schema / renames the `.v2.json` suffix.
--
--
-- CRASH SAFETY
--
-- Every file move goes through `Util.move_file` (os.rename with an
-- Android SAF copy-then-delete fallback — never a bare os.rename).  A
-- failed move leaves the source intact, so an interrupted
-- migration simply leaves that book in the old layout; the next run
-- (`migrateSingleBook` skips books already present in the new layout)
-- resumes cleanly.
--
--
-- PUBLIC SURFACE  (every function takes the plugin as first arg)
--
--   StorageMode.migrate_all_books(plugin, old_mode)
--   StorageMode.perform_migration(plugin, books)
--   StorageMode.migrate_book_files(plugin, book_file, from_mode, to_mode)
--   StorageMode.migrate_single_book(plugin, book)  → boolean
--
-- =============================================================================

local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Trapper     = require("ui/trapper")

local Util          = require("syncery_util")
local BookList      = require("syncery_ui/booklist/init")
local AnnPaths      = require("syncery_ann/paths")
local ProgressPaths = require("syncery_progress/paths")
local I18n          = require("syncery_i18n")
local ScatteredMetadata = require("syncery_migration/scattered_metadata")

local _  = I18n.translate
local _n = I18n.ngettext


local StorageMode = {}


-- ----------------------------------------------------------------------------
-- Internal: place ONE file at its destination, honouring the migration
-- contract at FILE granularity:
--   • destination already a file → SKIP the move (never overwrite newer
--     shared data — os.rename would clobber silently), and drop a stale
--     source if a prior partial run left one lingering ("drops the stale
--     source").
--   • source is a file, destination absent → move it (creating the
--     destination directory first).
--   • neither → nothing to place.
--
-- Returns true iff the file is now AT the destination (moved this call,
-- or was already there), false iff there was nothing to place there
-- (no source and no destination — e.g. a book that never had
-- annotations). This per-file result is what lets the book-level loop
-- converge a partially-migrated book on re-run: each file is
-- attempted independently, so a book whose progress moved but whose
-- annotations did not gets its annotations finished on the next pass,
-- and a book that legitimately has no annotations file is not mistaken
-- for "not yet migrated".
-- ----------------------------------------------------------------------------
local function move_one(lfs, src, dst)
    if not dst then return false end

    -- If source and destination are the SAME file, it is already exactly
    -- where it belongs — there is nothing to move and, crucially, nothing
    -- to delete.  (The "drop stale source" branch below assumes src is a
    -- SEPARATE leftover copy; when src==dst it would os.remove the only
    -- file, which is the data-loss bug.)
    if src and src == dst then
        return true
    end

    if lfs.attributes(dst, "mode") == "file" then
        -- Already at the destination. Drop a stale source if one lingers
        -- from an interrupted earlier run (matches Util.move_file's own
        -- "source may linger; next pass drops it" intent).
        if src and lfs.attributes(src, "mode") == "file" then
            os.remove(src)
        end
        return true
    end

    if src and lfs.attributes(src, "mode") == "file" then
        local dir = dst:match("^(.*[/\\])")
        if dir then Util.ensure_dir(dir) end
        return Util.move_file(src, dst) and true or false
    end

    return false   -- no source, no destination → nothing to place
end


-- ----------------------------------------------------------------------------
-- migrate_book_files — move ONE book's progress + annotation files from
-- `from_mode` layout to `to_mode` layout.
--
-- Flips ProgressPaths' storage mode in both directions to compute the
-- old and new paths.  The post-condition (mode left at `to_mode`)
-- matches what the caller already set, so no restore step is needed.
-- ----------------------------------------------------------------------------
function StorageMode.migrate_book_files(plugin, book_file, from_mode, to_mode)
    if not book_file then return end
    local lfs = Util.get_lfs()
    if not lfs then return end

    ProgressPaths.set_storage_mode(from_mode)
    local old_progress = ProgressPaths.shared_progress_path(book_file)
    local old_ann      = AnnPaths.shared_annotations_path(book_file)

    ProgressPaths.set_storage_mode(to_mode)
    local new_progress = ProgressPaths.shared_progress_path(book_file)
    local new_ann      = AnnPaths.shared_annotations_path(book_file)

    move_one(lfs, old_progress, new_progress)
    move_one(lfs, old_ann, new_ann)
end


-- ----------------------------------------------------------------------------
-- migrate_single_book — move ONE scanned book's files into the current
-- (new) storage mode.
--
-- Convergence is per-FILE, not gated on the progress file
-- alone. Each of progress/annotations is placed independently via
-- move_one (destination-exists → skip+drop-stale; absent → move). So a
-- book whose progress already moved but whose annotations did not gets
-- its annotations finished here on re-run, instead of being skipped
-- forever on the progress check.
--
-- Returns true when this pass actually PLACED a file that wasn't already
-- at the destination (a real migration step happened); false when there
-- was nothing left to do — both files already in the new layout, or the
-- book has no Syncery data to move. This keeps the caller's "migrated"
-- vs "skipped" message honest (booklist/actions.lua reads this return).
-- ----------------------------------------------------------------------------
function StorageMode.migrate_single_book(plugin, book)
    local lfs = Util.get_lfs()
    if not lfs or not book or not book.file then return false end

    local dst_prog = ProgressPaths.shared_progress_path(book.file)
    local dst_ann  = AnnPaths.shared_annotations_path(book.file)

    -- Pre-state: a file already at its destination was NOT moved by this
    -- pass, so it must not count as a fresh migration step.
    local prog_pre = dst_prog and lfs.attributes(dst_prog, "mode") == "file"
    local ann_pre  = dst_ann  and lfs.attributes(dst_ann,  "mode") == "file"

    move_one(lfs, book.progress_path, dst_prog)
    move_one(lfs, book.annotations_path, dst_ann)

    -- "Migrated" iff a destination file exists now that did not exist
    -- before this pass (progress or annotations was actually placed).
    local prog_now = dst_prog and lfs.attributes(dst_prog, "mode") == "file"
    local ann_now  = dst_ann  and lfs.attributes(dst_ann,  "mode") == "file"
    local placed_progress    = prog_now and not prog_pre
    local placed_annotations = ann_now  and not ann_pre
    return (placed_progress or placed_annotations) and true or false
end


-- ----------------------------------------------------------------------------
-- perform_migration — run the bulk migration over a list of scanned
-- books, with a Trapper progress dialog and cancellation support.
-- ----------------------------------------------------------------------------
-- @param on_complete function|nil optional callback run INSIDE the Trapper
--        wrap, after the completion message, with (migrated, skipped,
--        cancelled). Must be inside the wrap: per KOReader's Trapper, code
--        placed AFTER Trapper:wrap may execute while the wrapped function is
--        only half-done (the wrap returns early at the first yield), so any
--        follow-up UI must run here, not at the call site.
function StorageMode.perform_migration(plugin, books, on_complete)
    if #books == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No synced books found to migrate."), timeout = 3 })
        return
    end

    local migrated, already_there, not_here = 0, 0, 0
    local lfs = Util.get_lfs()

    -- The OTHER devices that also hold Syncery data for these books (id ->
    -- display name), so the report can name them and tell the user to repeat
    -- the migration there.  Built from the per-device entries each book's
    -- progress JSON already carries -- read once in the loop, no extra scan.
    -- Defensive requires: if a module is unavailable, we simply name nothing.
    local foreign = {}
    local local_id = Util.get_device_id and Util.get_device_id()
    local ok_js, JsonStore  = pcall(require, "syncery_ann/json_store")
    local ok_ss, StateStore = pcall(require, "syncery_progress/state_store")
    local can_collect = ok_js and ok_ss and JsonStore and StateStore

    -- `Trapper:wrap` + periodic `Trapper:info` gives progress updates
    -- and implicit cancellation (info returns false once the user
    -- dismisses the message).
    Trapper:wrap(function()
        Trapper:info(_("Migrating Syncery data…"))
        local cancelled = false
        for index, book in ipairs(books) do
            -- Note every OTHER device that has data for this book, from the
            -- entries already in its progress JSON (read once, here).
            if can_collect and book.progress_path then
                local raw  = JsonStore.read(book.progress_path)
                local norm = StateStore.normalize(raw)
                for id, name in pairs(StateStore.collect_foreign_devices(norm.entries, local_id)) do
                    foreign[id] = name
                end
            end

            if not book.file then
                not_here = not_here + 1
            elseif lfs and lfs.attributes(book.file, "mode") ~= "file" then
                -- Safety net: book.file must resolve to a real book on disk.
                -- The destination's synceryhash hash is derived from this path,
                -- so a malformed book.file (e.g. extension dropped) would send
                -- the moved files to a hash dir nothing else can find while
                -- deleting the source — silent data loss.  If the book the
                -- path names isn't there, do NOT move; leave the source intact.
                not_here = not_here + 1
            else
                local dst_prog = ProgressPaths.shared_progress_path(book.file)
                local dst_ann  = AnnPaths.shared_annotations_path(book.file)

                -- Per-file convergence. Pre-state tells us which
                -- files this pass actually places (vs already present),
                -- so a partially-migrated book (progress moved earlier,
                -- annotations not) gets finished here instead of being
                -- skipped forever on the progress check — and a book that
                -- has no annotations file is not mistaken for unmigrated.
                local prog_pre = dst_prog and lfs.attributes(dst_prog, "mode") == "file"
                local ann_pre  = dst_ann  and lfs.attributes(dst_ann,  "mode") == "file"

                move_one(lfs, book.progress_path, dst_prog)
                move_one(lfs, book.annotations_path, dst_ann)

                local prog_now = dst_prog and lfs.attributes(dst_prog, "mode") == "file"
                local ann_now  = dst_ann  and lfs.attributes(dst_ann,  "mode") == "file"
                if (prog_now and not prog_pre) or (ann_now and not ann_pre) then
                    migrated = migrated + 1       -- placed at least one file this pass
                else
                    already_there = already_there + 1  -- both files already in the new layout
                end
            end

            -- Periodic progress + cancel checkpoint.
            if index % 10 == 0 then
                if not Trapper:info(string.format(
                       _("Migrating Syncery data… (%d done)"),
                       migrated + already_there + not_here)) then
                    cancelled = true
                    break
                end
            end
        end

        Trapper:reset()

        local msg
        if cancelled then
            msg = string.format(
                _("Migration cancelled. %d of %d books processed."),
                migrated + already_there + not_here, #books)
        else
            msg = string.format(
                _n("Migrated %d book.", "Migrated %d books.", migrated), migrated)
            if already_there > 0 then
                msg = msg .. "\n" .. string.format(
                    _n("%d book already in the new location.",
                       "%d books already in the new location.", already_there),
                    already_there)
            end
            if not_here > 0 then
                msg = msg .. "\n" .. string.format(
                    _n("%d book is not on this device \xE2\x80\x94 nothing was moved or deleted for it.",
                       "%d books are not on this device \xE2\x80\x94 nothing was moved or deleted for them.", not_here),
                    not_here)
            end
        end
        -- Name the OTHER devices that also hold data for these books, so the
        -- user knows to repeat the migration there.  Sorted for a stable order
        -- (pairs() order is unspecified).  Shown only when there are others and
        -- the run completed (a cancelled run is reported on its own).
        local foreign_names = {}
        for _, name in pairs(foreign) do foreign_names[#foreign_names + 1] = name end
        table.sort(foreign_names)
        local has_foreign = #foreign_names > 0
        if not cancelled and has_foreign then
            msg = msg .. "\n" .. string.format(
                _("Syncery also has data from your other devices: %s. Run this migration on each of them too."),
                table.concat(foreign_names, ", "))
        end
        -- Optional follow-up, computed INSIDE the wrap (see on_complete
        -- docstring).  It RETURNS a widget to show AFTER this message is
        -- dismissed (sequential), or nil for none.  Detection inside it stays
        -- synchronous.  `skipped` is kept as a combined (already-here +
        -- not-here) count for the existing contract; callers that ignore the
        -- args are unaffected.
        local followup
        if type(on_complete) == "function" then
            followup = on_complete(migrated, already_there + not_here, cancelled)
        end

        -- A report that names other devices, flags books not on this device, or
        -- has a follow-up to show next, is worth reading -- keep it up until
        -- dismissed instead of vanishing.  nil timeout = stays until dismissed;
        -- 4 = auto-vanish.  (Lua note: `sticky and nil or 4` is ALWAYS 4 --
        -- `and nil` makes the left falsy -- so branch explicitly.)
        local sticky = (not cancelled) and (has_foreign or not_here > 0 or followup ~= nil)
        local timeout = 4
        if sticky then timeout = nil end
        -- Show the follow-up only after THIS message closes (by tap or its own
        -- timeout), so the two read in sequence -- migration result first,
        -- advisory next -- instead of stacking with the advisory on top.
        local dismiss_cb
        if followup then dismiss_cb = function() UIManager:show(followup) end end
        UIManager:show(InfoMessage:new{
            text = msg,
            timeout = timeout,
            dismiss_callback = dismiss_cb,
        })
        if plugin._logActivity then
            plugin:_logActivity(_("Migrate books"), string.format(
                "%d migrated, %d already there, %d not here%s",
                migrated, already_there, not_here,
                cancelled and " (cancelled)" or ""))
        end
    end)
end


-- ----------------------------------------------------------------------------
-- dedup_books_by_file — collapse a scanned-book list to ONE entry per book
-- file.  The migration may find the same book from more than one location
-- (a fixed-tree finder AND the root-walk), and migrating it twice is unsafe:
-- after the first move places the destination, the second pass hits move_one's
-- "dst exists, src differs → os.remove(src)" branch and could delete a
-- legitimate second source.  De-duping by book.file before migrating prevents
-- that.  Entries whose file is unknown cannot be de-duped, so they are kept.
--
-- `seen` (optional) carries book paths already emitted by the fixed-tree
-- finders, so root-walk rows for the same book are dropped here too.  The
-- list is rewritten in place AND returned.
-- ----------------------------------------------------------------------------
function StorageMode.dedup_books_by_file(books, seen)
    seen = seen or {}
    local kept = {}
    for _, b in ipairs(books) do
        if not (b and b.file) then
            -- No resolvable path → cannot de-dup; keep it.
            kept[#kept + 1] = b
        elseif not seen[b.file] then
            seen[b.file] = true
            kept[#kept + 1] = b
        end
        -- else: duplicate book.file → drop.
    end
    for i = #books, 1, -1 do books[i] = nil end
    for _, b in ipairs(kept) do books[#books + 1] = b end
    return books
end


-- ----------------------------------------------------------------------------
-- migrate_all_books — discover every book with Syncery data in the OLD
-- mode and bulk-migrate them.  SDR mode may need a root directory from
-- the user when no Syncthing folders are configured.
-- ----------------------------------------------------------------------------
-- data_already_at_destination — is there genuinely nothing to migrate because
-- the data already lives in the CURRENT (destination) mode?
--
-- Migration moves JSONs FROM the opposite mode INTO the current mode. The
-- callsite derives the source as "opposite of current", which IS the right
-- source — but it then scans that source blindly. If the user toggled the mode
-- back and forth without migrating (or already migrated), the data is already
-- in the current mode and the opposite tree is empty; the old flow scanned the
-- empty opposite tree and reported "No synced books found to migrate" — true in
-- the literal sense, but misleading, since the user's data plainly exists.
--
-- This helper detects exactly that case so the caller can say something
-- accurate ("already in the current storage location") instead. It fires ONLY
-- when current HAS JSONs AND the opposite has NONE:
--   * normal (data in opposite)        -> false (real migration needed)
--   * already-done (current, not opp.) -> TRUE  (nothing to migrate)
--   * mixed (both)                     -> false (opposite leftovers to migrate)
--   * empty (neither)                  -> false (let the normal empty path run)
--
-- Read-only; uses the same JSON enumeration as orphan-cleanup.
--
-- @return boolean already_home, integer current_count
function StorageMode.data_already_at_destination(plugin, lfs)
    local current = plugin and plugin.storage_mode
    if current ~= "sdr" and current ~= "hash" then return false, 0 end

    local ok_oa, OrphanAdapters = pcall(require, "syncery_migration/orphan_adapters")
    if not ok_oa or not OrphanAdapters or type(OrphanAdapters.build_deps) ~= "function" then
        return false, 0
    end
    local ok_deps, deps = pcall(OrphanAdapters.build_deps, { lfs = lfs })
    if not ok_deps or type(deps) ~= "table" or type(deps.syncery_jsons) ~= "function" then
        return false, 0
    end
    local ok_list, entries = pcall(deps.syncery_jsons)
    if not ok_list or type(entries) ~= "table" then return false, 0 end

    -- Count JSONs that belong to the current mode vs the opposite mode.
    local function mode_of(klass)
        if klass == "synceryhash" then return "hash" end
        if klass == "doc" or klass == "dir" or klass == "hashdocsettings" then return "sdr" end
        return nil
    end
    local current_count, opposite_count = 0, 0
    for _, e in ipairs(entries) do
        local m = mode_of(e.klass)
        if m == current then
            current_count = current_count + 1
        elseif m ~= nil then
            opposite_count = opposite_count + 1
        end
    end

    -- Fire only when there is data in the destination and none left to migrate.
    return (current_count > 0 and opposite_count == 0), current_count
end

function StorageMode.migrate_all_books(plugin, old_mode)
    local lfs = Util.get_lfs()
    if not lfs then
        UIManager:show(InfoMessage:new{
            text = _("Filesystem access unavailable.") })
        return
    end

    -- Before selecting a migration branch, check whether the data is already in
    -- the current (destination) storage location with nothing left in the other
    -- mode to migrate. This is the toggle-back-and-forth / already-migrated case:
    -- the old flow would scan the (empty) opposite tree and report "No synced
    -- books found", which is misleading. Report it accurately instead. (Skipped
    -- when an explicit old_mode is passed — e.g. tests — so existing behaviour
    -- and the explicit-source contract are preserved.)
    if old_mode ~= "hash" and old_mode ~= "sdr" then
        local already_home, n = StorageMode.data_already_at_destination(plugin, lfs)
        if already_home then
            UIManager:show(InfoMessage:new{
                text = string.format(_n(
                    "Your Syncery data is already in the current storage location (%d book). Nothing to migrate.",
                    "Your Syncery data is already in the current storage location (%d books). Nothing to migrate.",
                    n), n),
                timeout = 4,
            })
            return
        end
    end

    -- Derive the source mode from the toggle when not explicitly given (the
    -- source IS the opposite of the current destination). The data-already-home
    -- check above has ruled out the misleading empty-opposite case.
    if old_mode ~= "hash" and old_mode ~= "sdr" then
        old_mode = (plugin and plugin.storage_mode == "sdr") and "hash" or "sdr"
    end

    local books = {}
    if old_mode == "hash" then
        BookList.scanHash(books)
        -- synceryhash -> SDR only. After Syncery has moved its OWN JSON data,
        -- detect (READ-ONLY) whether the user's native KOReader metadata.lua
        -- files are scattered across non-preferred locations, and advise that
        -- KOReader's own "Move book metadata" can consolidate them. Syncery
        -- never moves KOReader's files. Detection runs from INSIDE the Trapper
        -- wrap (via on_complete) -- where the scanned-book set is valid -- and
        -- on_complete RETURNS the advisory widget, so perform_migration shows it
        -- AFTER the migration-result message is dismissed (sequential, advisory
        -- second) rather than stacked on top. This runs ONLY in the hash-branch,
        -- so it never fires for SDR -> synceryhash (content-addressed; scattering
        -- is irrelevant there).
        local scattered_report
        StorageMode.perform_migration(plugin, books, function()
            scattered_report = ScatteredMetadata.detect(books)
            local r = scattered_report
            if r.total_scattered > 0 then
                -- Build the per-location breakdown lines (e.g. "3 in koreader/docsettings").
                local lines = {}
                for loc, count in pairs(r.by_location) do
                    local label = ScatteredMetadata.LOCATION_LABELS[loc] or loc
                    lines[#lines + 1] = string.format(
                        _("\xE2\x80\xA2 %d in %s"), count, label)
                end
                table.sort(lines)
                local body = string.format(_(
                    "You just migrated your Syncery JSON files.\n\n"
                    .. "But I also detected that your KOReader metadata.lua files are "
                    .. "stored in locations other than your selected one (%s). "
                    .. "Here's what I found:\n%s\n\n"
                    .. "Syncery doesn't move these files. If you'd like to consolidate "
                    .. "them, go to the File Browser and use the menu: "
                    .. "\xE2\x9A\x99 \xE2\x86\x92 Document \xE2\x86\x92 Move book metadata."),
                    r.preferred_label or "?", table.concat(lines, "\n"))
                return InfoMessage:new{ text = body }
            elseif r.total_scanned > 0 then
                return InfoMessage:new{ text = string.format(_(
                    "All your KOReader metadata is already in the selected location (%s)."),
                    r.preferred_label or "?"), timeout = 4 }
            end
            -- total_scanned == 0: stay silent (nothing scanned, or the
            -- detection API is unavailable — we make no claim either way).
        end)
        return scattered_report
    end

    -- SDR mode: a book's Syncery files live in KOReader's CURRENT metadata
    -- location, but a user who CHANGED that location mid-life can have files
    -- lingering in an OLD one.  So scan ALL THREE locations (doc/dir/hash) and
    -- de-dup, the same coverage "Manage all synced books" uses:
    --   * doc  — `<book>.sdr` beside the book → root-walk (scanSDR) over the
    --            Syncthing folders PLUS the folders of recently-opened books
    --            (history), so it works even with no Syncthing folders set.
    --   * dir  — `docsettings/<path>.sdr` → find_synced_books_in_dir.
    --   * hash — `hashdocsettings/XX/<hash>.sdr` → find_synced_books.
    -- scanHash is deliberately NOT given these books (feeding hashdocsettings
    -- books to scanHash made move_one delete them, src==dst — the old bug);
    -- they enter `books` here with their OWN src paths and are de-duped below.
    local seen = {}

    -- doc: Syncthing folder paths + history-derived roots (de-duped).
    local roots = {}
    do
        local seen_root = {}
        for __, r in ipairs(BookList.getScanRoots()) do
            if not seen_root[r] then seen_root[r] = true; roots[#roots + 1] = r end
        end
        for __, r in ipairs(BookList.deriveRootsFromHistory()) do
            if not seen_root[r] then seen_root[r] = true; roots[#roots + 1] = r end
        end
    end
    local had_any_root = #roots > 0

    -- dir + hash: the fixed KOReader trees (always checked, no roots needed).
    local ok_ss, StateStore = pcall(require, "syncery_progress/state_store")
    local normalize = ok_ss and StateStore and StateStore.normalize or nil
    local ok_hf, HashLocationFinder = pcall(require, "syncery_ann/hash_location_finder")
    if ok_hf and HashLocationFinder then
        for __, b in ipairs(HashLocationFinder.find_synced_books(seen, { normalize = normalize })) do
            books[#books + 1] = b
        end
        for __, b in ipairs(HashLocationFinder.find_synced_books_in_dir(seen, { normalize = normalize })) do
            books[#books + 1] = b
        end
    end

    -- A book found in a fixed tree above must not be re-added by the root-walk
    -- below; scanSDR keys its own progress paths (it does NOT consult `seen`),
    -- so after both scans we collapse the WHOLE list by book.file.  IMPORTANT:
    -- dedup must start from a FRESH slate, NOT the `seen` the finders filled —
    -- otherwise every finder-found book is seen as an already-present duplicate
    -- and dropped (the bug that lost all hashdocsettings/docsettings books).
    local function run_root_scan_and_migrate(scan_roots)
        BookList.scanSDR(scan_roots or {}, books)
        StorageMode.dedup_books_by_file(books)
        StorageMode.perform_migration(plugin, books)
    end

    if had_any_root then
        run_root_scan_and_migrate(roots)
        return
    end

    -- No roots for the doc-location walk.  If the fixed trees already found
    -- books, migrate them now (no picker needed).  Otherwise offer the picker
    -- as a true last resort — only when we had nothing to look in.
    if #books > 0 then
        StorageMode.dedup_books_by_file(books)
        StorageMode.perform_migration(plugin, books)
        return
    end

    BookList.promptForScanRoot(function(chosen_roots)
        run_root_scan_and_migrate(chosen_roots)
    end)
end


return StorageMode
