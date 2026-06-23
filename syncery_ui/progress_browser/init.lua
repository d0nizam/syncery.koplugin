-- =============================================================================
-- syncery_ui/progress_browser/init.lua
-- =============================================================================
--
-- The Progress Browser: a cross-device reading-PROGRESS dashboard, the
-- progress-domain twin of the Annotation Browser.
--
-- Level 1 (this landing screen): every synced book that has progress, one row
-- each -- a state glyph (a newer position ahead / in sync / current), the
-- book title, and a compact "you -> most recent" position.  Tapping a row opens the
-- per-book detail (Level 2).
--
-- TRANSPORT-AGNOSTIC by construction: it reads only the shared progress files
-- (via the enumerator + ProgressStateStore), which BOTH Syncthing and cloud
-- transports sync.  Nothing here depends on Syncthing folder state or peer
-- connectivity.  Reading position is shown as PERCENT (never page numbers,
-- which vary per device by font/screen) -- the per-device chapter resolves
-- from the xpointer only when the book is open, a Level-2 refinement.
-- =============================================================================

local UIManager   = require("ui/uimanager")
local Menu        = require("ui/widget/menu")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox  = require("ui/widget/confirmbox")
local Screen      = require("device").screen
local ActionBar   = require("syncery_ui/action_bar")

local I18n        = require("syncery_i18n")
local _           = I18n.translate

local ProgressEnum       = require("syncery_ui/progress_browser/progress_enum")
local Aggregate          = require("syncery_ui/progress_browser/aggregate")
local JumpTargets        = require("syncery_ui/progress_browser/jump_targets")
local ProgressStateStore = require("syncery_progress/state_store")
local ProgressConflictResolver = require("syncery_progress/conflict_resolver")
local ProgressBridge     = require("syncery_progress/progress_bridge")
local StatusUI           = require("syncery_ui/status_ui/init")

local ProgressBrowser = {}


-- ----------------------------------------------------------------------------
-- Formatting helpers
-- ----------------------------------------------------------------------------

local function pct(p)
    return string.format("%d%%", math.floor((tonumber(p) or 0) * 100 + 0.5))
end

-- The position to show on a JUMP button.  PDF/paging pages are IDENTICAL across
-- devices, so the page is meaningful and shown.  Reflowable (EPUB) books carry
-- an xpointer and re-paginate per device -- there the page is device-local and
-- the percentage is noise, so NO position number is shown; the button stays
-- descriptive (device + when), which reads clearer.
local function position_text(entry)
    if (type(entry.xpath) ~= "string" or entry.xpath == "") and entry.page then
        return string.format(_("page %s"), tostring(entry.page))
    end
    return nil
end

-- State -> leading glyph (KOReader-recency "at a glance"):
--   behind  a MORE RECENT position is ahead of this device (jump to continue)  ->  up
--   even    the most recent position is at this device's position (in sync)    ->  =
--   neutral this device holds the most recent position, is alone, or is ahead  ->  check
local GLYPH = { behind = "\u{2191}", even = "=", neutral = "\u{2713}" }

-- A book whose shared progress file Syncthing has split into a
-- `.sync-conflict-*` copy gets a calm trailing MERGE glyph on its row (NOT a
-- warning sign -- a position conflict is a divergence to reconcile, not a
-- danger).  The full "(sync-conflict merged)" text appears in the detail.
-- The merged view folds the copies read-only, so the row's position already
-- reflects the reconciled (newest-per-device) state.
local CONFLICT_GLYPH = "\u{22C8}"   -- ⋈ (bowtie / join)

-- The right-aligned "mandatory" cell on a Level-1 row: this device's position
-- relative to the most recent position across devices.
local function row_mandatory(agg)
    if agg.state == "behind" then
        if agg.my_percent then
            return pct(agg.my_percent) .. " \u{2192} " .. pct(agg.recent_percent)
        end
        return "\u{00B7} \u{2192} " .. pct(agg.recent_percent)
    end
    return pct(agg.my_percent or agg.recent_percent)
end

-- A 1-2 line plain-language summary for the detail header (recency-framed).
local function build_summary(agg)
    local lines = {}
    if agg.state == "behind" then
        lines[1] = string.format(_("Most recent: %s on %s."),
            pct(agg.recent_percent), agg.recent_label or "?")
        if agg.my_percent then
            lines[2] = string.format(_("This device: %s."), pct(agg.my_percent))
        else
            lines[2] = _("This device has no saved position for this book.")
        end
    elseif agg.state == "even" then
        lines[1] = string.format(_("In sync at %s."),
            pct(agg.my_percent or agg.recent_percent))
    else -- neutral
        if agg.other_count == 0 then
            lines[1] = string.format(_("Only this device has read this book (%s)."),
                pct(agg.my_percent or agg.recent_percent))
        elseif agg.is_recent_me then
            lines[1] = string.format(_("This device has the most recent position (%s)."),
                pct(agg.my_percent or agg.recent_percent))
        else
            -- This device is ahead of the most recent activity elsewhere.
            lines[1] = string.format(_("This device: %s."), pct(agg.my_percent or 0))
            lines[2] = string.format(_("Most recent elsewhere: %s on %s."),
                pct(agg.recent_percent), agg.recent_label or "?")
        end
    end
    return table.concat(lines, "\n")
end


-- ----------------------------------------------------------------------------
-- Level 2 (FULL): per-book detail as an action panel.  A summary header (this
-- device's position + a ⋈ note when a sync-conflict was folded) over one JUMP
-- button per other device + [Jump to latest] -- every jump goes through the
-- same _doJump + [Undo] flow as the status panel's "Jump to device", and opens
-- the book first when it isn't already open.  This makes the Progress Browser a
-- superset of the old "Show device status" panel.
-- ----------------------------------------------------------------------------

-- Is this exact book file the one currently open in the reader?
function ProgressBrowser._is_book_open(book_path)
    local ReaderUI = require("apps/reader/readerui")
    return ReaderUI.instance ~= nil
        and ReaderUI.instance.document ~= nil
        and ReaderUI.instance.document.file == book_path
end


-- Jump to `entry`'s position with an Undo bar -- the SAME flow the status
-- panel's "Jump to device" uses (_doJump + a scheduled autosave + an [Undo]
-- action bar).  Works whether or not the book is currently open:
--   * already the open book -> jump on THIS instance (`plugin`).
--   * otherwise            -> open it, then jump on the NEWLY-created reader's
--                             Syncery instance (`ReaderUI.instance.syncery`) --
--                             a fresh instance is built on open, so the old
--                             `plugin` must not be used past the open.
function ProgressBrowser._jumpToDevice(plugin, book, entry, label)
    local function jumpWithUndo(syn, ui_obj)
        if not (syn and ui_obj and ui_obj.document and entry) then return end
        local st = syn:getCurrentState()
        if not st then return end
        syn:_doJump(st, entry.page, entry.percent, entry.xpath)
        syn:_schedule("_autosave_action", 0.5, function()
            syn:_save({ silent = true, trigger_sync = false, force = true })
        end)
        ActionBar.show(ui_obj, {
            text         = _("Jumped to position from ") .. (label or _("Another device")),
            button_label = _("Undo"),
            on_action    = function() syn:_undoLastJump() end,
            seconds      = 12,
        })
    end

    local book_path = book and book.book_path
    -- Already the open book: jump on the current instance.
    if book_path and ProgressBrowser._is_book_open(book_path) then
        jumpWithUndo(plugin, plugin.ui)
        return
    end
    if not book_path then
        UIManager:show(InfoMessage:new{ text = _("Cannot find book path.") })
        return
    end

    -- Otherwise open it, then jump on the freshly-created instance.
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(book_path)
    UIManager:scheduleIn(1.5, function()
        local ui = require("apps/reader/readerui").instance
        jumpWithUndo(ui and ui.syncery, ui)
    end)
end


-- Confirm, then merge this book's Syncthing conflict copies into the canonical
-- progress file and delete them (resolve_all_at_path -- path-based, so it works
-- for content-hash books too).  Resolution also happens automatically the
-- next time you open this book; this button just does it now.
function ProgressBrowser._confirmResolve(plugin, book, viewer)
    UIManager:show(ConfirmBox:new{
        text = _("Merge this book's sync-conflict copies into its progress and remove them?\n\nThis also happens automatically the next time you open this book."),
        ok_text = _("Resolve"),
        ok_callback = function()
            local n_seen, _merged, err =
                ProgressConflictResolver.resolve_all_at_path(book and book.progress_path)
            if viewer then UIManager:close(viewer) end
            local msg
            if err then
                msg = _("Could not resolve the sync-conflict.")
            elseif (n_seen or 0) == 0 then
                msg = _("No sync-conflict copies to resolve.")
            else
                msg = _("Sync-conflict resolved.")
            end
            UIManager:show(InfoMessage:new{ text = msg })
        end,
    })
end


function ProgressBrowser.showBookDetail(plugin, book, state, agg, conflict_count)
    -- Summary header (the ButtonDialog title): book + a ⋈ note when a sync
    -- conflict was folded + the cross-device summary (build_summary already
    -- states this device's position and the most recent one).
    local header = {}
    header[#header + 1] = book.title or book.filename or _("Book")
    if conflict_count and conflict_count > 0 then
        header[#header + 1] = CONFLICT_GLYPH .. " " .. _("(sync conflict: merge pending)")
    end
    header[#header + 1] = ""
    header[#header + 1] = build_summary(agg)

    -- Jump buttons.  Freshness-filtered, same as the status panel.
    local dialog
    local fresh = ProgressBridge.filter_fresh_for_display(
        state.entries, plugin.progress_freshness_days)

    local function device_button(entry, lead)
        local label = StatusUI._truncate_label(entry.label, 32) or _("Unknown")
        local parts = { label }
        local pos = position_text(entry)        -- "page N" for PDF; nil for EPUB
        if pos then parts[#parts + 1] = pos end
        parts[#parts + 1] = pct(entry.percent)  -- percent always (PDF page is extra)
        parts[#parts + 1] = StatusUI._get_time_ago(entry.timestamp)
        return {
            text = lead .. " " .. table.concat(parts, " \u{00B7} "),
            callback = function()
                UIManager:close(dialog)
                ProgressBrowser._jumpToDevice(plugin, book, entry, label)
            end,
        }
    end

    -- The most recent device (the single recency anchor) comes straight from
    -- the aggregate, so the dashboard glyph, the summary and this jump all agree.
    local recent_id = agg.recent_device_id
    local per_ids, show_recent =
        JumpTargets.compute(fresh, plugin.device_id, recent_id)
    table.sort(per_ids, function(a, b)
        return (fresh[a].timestamp or 0) > (fresh[b].timestamp or 0)  -- newest first
    end)

    local buttons = {}
    -- One button per OTHER device that is not the most recent (the most recent
    -- one is reached via [Jump to most recent] below, so it gets no separate
    -- button).
    for _, dev_id in ipairs(per_ids) do
        buttons[#buttons + 1] = { device_button(fresh[dev_id], "\u{2192}") }  -- ->
    end

    if #buttons == 0 and not show_recent then
        header[#header + 1] = ""
        header[#header + 1] = _("No other device positions to jump to.")
    end

    -- A ⋈ book can be resolved here (destructive -> its own row, confirmed).
    if conflict_count and conflict_count > 0 then
        buttons[#buttons + 1] = {
            { text = _("Resolve conflict"),
              callback = function() ProgressBrowser._confirmResolve(plugin, book, dialog) end },
        }
    end

    -- Bottom row: [Jump to most recent position] -> the latest-updated device
    -- (hidden when THIS device holds it -- a jump to self) next to [Close].  A
    -- direction arrow shows whether the latest position is ahead (forward) of
    -- or behind (backward) this device, mirroring KOReader's forward/backward.
    local bottom = {}
    if show_recent then
        local f = state.entries[recent_id]
        local flabel = (type(f) == "table"
            and StatusUI._truncate_label(f.label, 24)) or _("Another device")
        local fparts = {}
        local fpos = (type(f) == "table") and position_text(f) or nil   -- page for PDF
        if fpos then fparts[#fparts + 1] = fpos end
        if type(f) == "table" then fparts[#fparts + 1] = pct(f.percent) end

        local arrow = ""
        if agg.my_percent and type(f) == "table" and type(f.percent) == "number" then
            local d = f.percent - agg.my_percent
            if d > 0.005 then arrow = "\u{2191} "          -- latest is ahead (forward)
            elseif d < -0.005 then arrow = "\u{2193} " end -- latest is behind (backward)
        end
        local base = _("Jump to most recent position")
        local recent_text = (#fparts > 0)
            and (arrow .. base .. " \u{00B7} " .. table.concat(fparts, " \u{00B7} "))
            or  (arrow .. base)
        bottom[#bottom + 1] = {
            text = recent_text,
            callback = function()
                UIManager:close(dialog)
                ProgressBrowser._jumpToDevice(plugin, book, f, flabel)
            end,
        }
    end
    bottom[#bottom + 1] = {
        text = _("Close"), callback = function() UIManager:close(dialog) end,
    }
    buttons[#buttons + 1] = bottom

    dialog = ButtonDialog:new{
        title       = table.concat(header, "\n"),
        title_align = "left",
        buttons     = buttons,
    }
    UIManager:show(dialog)
end


-- ----------------------------------------------------------------------------
-- Level 1: the all-books dashboard.
-- ----------------------------------------------------------------------------

function ProgressBrowser.show(plugin)
    if not plugin then return end

    -- Enumerate every progress-bearing synced book, then reduce each to its
    -- cross-device aggregate.  (Synchronous scan, matching the booklist /
    -- annotation enumeration; a cancellable progress wrapper is a later
    -- refinement for very large libraries.)
    local books = ProgressEnum.enumerate()

    local rows = {}
    for _, b in ipairs(books) do
        -- Read the shared progress through the conflict-aware merged view: it
        -- folds any Syncthing `.sync-conflict-*` copies READ-ONLY (newest
        -- position per device), so the dashboard reflects the reconciled state
        -- a sync conflict has split.  pcall + canonical fallback -- merged_view
        -- runs for EVERY enumerated book, so one unreadable conflict copy must
        -- not sink the whole list.  Zero conflicts (the cloud-always / common
        -- case) returns exactly what a plain load would.
        local state, conflict_count
        local ok, merged, n = pcall(
            ProgressConflictResolver.merged_view, b.progress_path)
        if ok and merged then
            state, conflict_count = merged, (n or 0)
        else
            state = ProgressStateStore.load_shared_from_path(b.progress_path)
            conflict_count = 0
        end

        local agg = Aggregate.aggregate_book(
            state.entries, plugin.device_id,
            { freshness_days = plugin.progress_freshness_days })
        -- Most-recently-active first: the newest per-device timestamp.
        local last_ts = 0
        for _, e in pairs(state.entries or {}) do
            if type(e) == "table" then
                local ts = tonumber(e.timestamp) or 0
                if ts > last_ts then last_ts = ts end
            end
        end
        rows[#rows + 1] = {
            book = b, state = state, agg = agg,
            last_ts = last_ts, conflict_count = conflict_count,
        }
    end
    table.sort(rows, function(a, b) return a.last_ts > b.last_ts end)

    local item_table = {}
    if #rows == 0 then
        item_table[#item_table + 1] = {
            text     = _("No synced reading progress found yet."),
            callback = function() end,
        }
    else
        for _, r in ipairs(rows) do
            local glyph = GLYPH[r.agg.state] or GLYPH.neutral
            local title = r.book.title or r.book.filename or _("Book")
            -- Calm trailing merge glyph when a Syncthing conflict copy exists.
            local suffix = (r.conflict_count > 0) and ("  " .. CONFLICT_GLYPH) or ""
            item_table[#item_table + 1] = {
                text      = glyph .. "  " .. title .. suffix,
                mandatory = row_mandatory(r.agg),
                callback  = function()
                    ProgressBrowser.showBookDetail(
                        plugin, r.book, r.state, r.agg, r.conflict_count)
                end,
            }
        end
    end

    local menu_widget
    menu_widget = Menu:new{
        title         = _("Progress Browser"),
        item_table    = item_table,
        is_borderless = true,
        is_popout     = false,
        width         = Screen:getWidth(),
        height        = Screen:getHeight(),
    }
    function menu_widget:onClose()
        UIManager:close(menu_widget)
        return true
    end
    UIManager:show(menu_widget)
end


return ProgressBrowser
