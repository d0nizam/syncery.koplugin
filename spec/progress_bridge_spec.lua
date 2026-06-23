-- =============================================================================
-- spec/progress_bridge_spec.lua
-- =============================================================================
--
-- Tests for syncery_progress/progress_bridge.lua — the live-state
-- reader and the display-filter helpers.
--
-- The bridge reads from KOReader's `ui` object.  We use the existing
-- `make_fake_ui` from the test helpers, plus a tiny extension that
-- adds a fake `document` so the bridge can ask for page/xpath.
--
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_progress_bridge_spec_" .. tostring(os.time()))

local ProgressBridge = require("syncery_progress/progress_bridge")


-- ----------------------------------------------------------------------------
-- Helper: build a fake ReaderUI with a document and footer.
-- ----------------------------------------------------------------------------


local function make_fake_progress_ui(opts)
    opts = opts or {}
    local doc = {
        file = opts.file or "/tmp/test_book.epub",
        getCurrentPage = function() return opts.page or 1 end,
        getPageCount   = function() return opts.total_pages or 0 end,
        getXPointer    = function() return opts.doc_xpath or "" end,
        getProps       = function() return { title = "Test" } end,
    }

    local rolling = nil
    if opts.is_rolling then
        rolling = {
            current_page    = opts.page,
            total_pages     = opts.total_pages,
            xpointer        = opts.xpath,
        }
    end

    return {
        paging       = opts.paging or false,
        rolling      = rolling,
        document     = doc,
        footer       = opts.footer,
        view         = nil,
    }
end


-- ----------------------------------------------------------------------------
-- read_from_live: rolling document with all fields populated
-- ----------------------------------------------------------------------------


do
    local ui = make_fake_progress_ui{
        file = "/tmp/rolling_book.epub",
        is_rolling = true,
        page = 50, total_pages = 200,
        xpath = "/body/DocFragment[3]/body[1]/p[7]",
        footer = { percent_finished = 0.245 },
    }

    local entry = ProgressBridge.read_from_live(ui, "Phone")
    h.assert_true(entry ~= nil, "non-nil entry for rolling document")
    h.assert_equal(entry.file, "/tmp/rolling_book.epub", "file is captured")
    h.assert_equal(entry.page, 50, "page is captured")
    h.assert_equal(entry.total_pages, 200, "total_pages is captured")
    h.assert_equal(entry.xpath, "/body/DocFragment[3]/body[1]/p[7]",
        "xpath is captured for rolling document")
    h.assert_equal(entry.percent, 0.245,
        "percent comes from footer when present")
    h.assert_equal(entry.label, "Phone", "device label is stamped")
    h.assert_true(entry.is_rolling, "is_rolling flag set")
end


-- ----------------------------------------------------------------------------
-- read_from_live: paging document (no xpath; percent derived from page/total)
-- ----------------------------------------------------------------------------


do
    local ui = make_fake_progress_ui{
        file = "/tmp/book.pdf",
        paging = true,
        page = 50, total_pages = 200,
        -- No footer percent provided; bridge should derive (50-1)/200 = 0.245
    }

    local entry = ProgressBridge.read_from_live(ui)
    h.assert_equal(entry.page, 50, "page from paging API")
    h.assert_equal(entry.total_pages, 200, "total_pages from paging API")
    h.assert_nil(entry.xpath, "no xpath for paging document")
    h.assert_equal(entry.percent, 49/200,
        "percent derived from (page-1)/total when no footer")
    h.assert_false(entry.is_rolling, "is_rolling false for paging document")
end


-- ----------------------------------------------------------------------------
-- read_from_live: footer overrides null page/total in fallback path
-- ----------------------------------------------------------------------------


do
    -- Neither paging nor rolling — generic fallback through document API.
    local ui = make_fake_progress_ui{
        file = "/tmp/x.epub",
        page = nil, total_pages = nil,  -- doc API returns 0/0
        footer = { percent_finished = 0.5, pageno = 100, pages = 200 },
    }

    -- Patch the doc methods so they return clearly-no-value to test the
    -- footer fallback for page/total.
    ui.document.getCurrentPage = function() return nil end
    ui.document.getPageCount   = function() return 0   end

    local entry = ProgressBridge.read_from_live(ui)
    h.assert_equal(entry.page, 100,
        "page falls back to footer.pageno when doc API yields nothing")
    h.assert_equal(entry.total_pages, 200,
        "total_pages falls back to footer.pages")
    h.assert_equal(entry.percent, 0.5,
        "percent from footer")
end


-- ----------------------------------------------------------------------------
-- read_from_live: no document → nil
-- ----------------------------------------------------------------------------


do
    h.assert_nil(ProgressBridge.read_from_live(nil),
        "nil ui returns nil entry")
    h.assert_nil(ProgressBridge.read_from_live({}),
        "ui without document returns nil entry")
    h.assert_nil(ProgressBridge.read_from_live({ document = {} }),
        "document without file returns nil entry (KOReader half-initialized)")
end


-- ----------------------------------------------------------------------------
-- read_from_live: throwing document methods are swallowed gracefully
-- ----------------------------------------------------------------------------


do
    local ui = make_fake_progress_ui{ paging = true, file = "/tmp/x.pdf" }
    ui.document.getCurrentPage = function() error("kapow") end
    ui.document.getPageCount   = function() error("boom") end

    -- Should not crash; should produce a zero-progress entry.
    local entry = ProgressBridge.read_from_live(ui)
    h.assert_true(entry ~= nil, "throwing methods don't crash the bridge")
    h.assert_equal(entry.page, 1, "zero-progress fallback for page")
    h.assert_equal(entry.percent, 0, "zero-progress fallback for percent")
end


-- ----------------------------------------------------------------------------
-- read_from_live: rolling doc with empty xpointer falls back to doc.getXPointer
-- ----------------------------------------------------------------------------


do
    local ui = make_fake_progress_ui{
        file = "/tmp/rolling_two.epub",
        is_rolling = true,
        page = 1, total_pages = 200,
        xpath = "",            -- empty string in rolling.xpointer
        doc_xpath = "/body/p", -- but document has a real one
    }

    local entry = ProgressBridge.read_from_live(ui)
    h.assert_equal(entry.xpath, "/body/p",
        "empty rolling.xpointer falls back to document.getXPointer")
end


-- ----------------------------------------------------------------------------
-- filter_fresh_for_display: keeps fresh entries, drops stale ones
-- ----------------------------------------------------------------------------


do
    -- Use a realistic "now" (epoch seconds) so that cutoff is a real
    -- positive number — that's what production conditions look like.
    -- The earlier draft used `now = 1_000_000` which made cutoff
    -- *negative*, accidentally including entries with timestamp=0.
    local now    = 1700000000   -- 2023-11-14, well above 90*86400
    local cutoff = now - 90 * 86400

    local entries = {
        FRESH  = { revision = 5, timestamp = now - 86400  },   -- 1 day old
        BORDER = { revision = 5, timestamp = cutoff },         -- exactly at cutoff
        STALE  = { revision = 5, timestamp = cutoff - 1 },     -- 1 sec older than cutoff
        NO_TS  = { revision = 5 },                             -- missing timestamp
    }

    local fresh = ProgressBridge.filter_fresh_for_display(entries, 90, now)
    h.assert_true(fresh.FRESH  ~= nil, "FRESH entry kept")
    h.assert_true(fresh.BORDER ~= nil, "BORDER entry (at cutoff) kept")
    h.assert_nil(fresh.STALE,         "STALE entry filtered out")
    h.assert_nil(fresh.NO_TS,         "entry with no timestamp filtered out (default 0)")

    -- Original map unmodified.
    h.assert_true(entries.STALE ~= nil, "original map not mutated")
    h.assert_true(entries.NO_TS ~= nil, "original map not mutated 2")
end


-- ----------------------------------------------------------------------------
-- filter_fresh_for_display: nil / non-table input returns empty
-- ----------------------------------------------------------------------------


do
    h.assert_deep_equal(ProgressBridge.filter_fresh_for_display(nil), {},
        "nil input returns empty map")
    h.assert_deep_equal(ProgressBridge.filter_fresh_for_display("garbage"), {},
        "non-table input returns empty map")
end


-- ----------------------------------------------------------------------------
-- strip_metadata_fields: keeps progress fields, drops metadata fields
-- ----------------------------------------------------------------------------


do
    local dirty = {
        revision = 5,
        percent = 0.5,
        page = 100,
        total_pages = 200,
        xpath = "/x",
        file = "/tmp/x.epub",
        label = "Phone",
        timestamp = 999,
        device_id = "DA",
        is_rolling = true,
        -- legacy / metadata-bridge concerns:
        status       = "reading",
        rating       = 5,
        collections  = { "Favorites" },
        summary      = { note = "..." },
        custom_metadata = { title = "X" },
        handmade_toc = { stub = true },
    }

    local clean = ProgressBridge.strip_metadata_fields(dirty)

    h.assert_equal(clean.revision,    5,      "revision kept")
    h.assert_equal(clean.percent,     0.5,    "percent kept")
    h.assert_equal(clean.page,        100,    "page kept")
    h.assert_equal(clean.total_pages, 200,    "total_pages kept")
    h.assert_equal(clean.xpath,       "/x",   "xpath kept")
    h.assert_equal(clean.label,       "Phone","label kept")
    h.assert_equal(clean.device_id,   "DA",   "device_id kept")
    h.assert_true(clean.is_rolling,           "is_rolling kept")

    h.assert_nil(clean.status,          "status stripped")
    h.assert_nil(clean.rating,          "rating stripped")
    h.assert_nil(clean.collections,     "collections stripped")
    h.assert_nil(clean.summary,         "summary stripped")
    h.assert_nil(clean.custom_metadata, "custom_metadata stripped")
    h.assert_nil(clean.handmade_toc,    "handmade_toc stripped")

    -- Original not mutated.
    h.assert_equal(dirty.status, "reading", "original entry not mutated")
end


-- ----------------------------------------------------------------------------
-- gotoxpointer_args: the resume jump marks the SAME position it jumps to, so
-- KOReader flashes its margin marker at the resumed line (visual aid only).
-- ----------------------------------------------------------------------------


do
    local target, marker = ProgressBridge.gotoxpointer_args("/body/DocFragment[3]/p[2]/text()[1].17")
    h.assert_equal(target, "/body/DocFragment[3]/p[2]/text()[1].17",
        "jump target is the resume xpointer")
    h.assert_equal(marker, "/body/DocFragment[3]/p[2]/text()[1].17",
        "marker_xp equals the target — marker lands on the resumed line")
    h.assert_equal(target, marker,
        "target and marker are the same position (anchor unchanged; marker is purely visual)")

    -- Passing through whatever it's given (no transformation, no guessing).
    local t2, m2 = ProgressBridge.gotoxpointer_args("xp://abc")
    h.assert_equal(t2, "xp://abc", "passes the given xpointer through as target")
    h.assert_equal(m2, "xp://abc", "passes the given xpointer through as marker")
end


-- ----------------------------------------------------------------------------
-- xpointer_resolves: the gate for the resume jump.  A remote xpointer that
-- does NOT resolve in the copy opened here (different edition/file, or a DOM
-- paginated differently by another crengine) must not be jumped to -- the
-- caller falls back to page/percent instead of feeding KOReader a dead anchor
-- that later crashes getPageFromXPointer.
-- ----------------------------------------------------------------------------


do
    local function doc_resolving(result)
        return { isXPointerInDocument = function(_, _) return result end }
    end

    h.assert_equal(
        ProgressBridge.xpointer_resolves(doc_resolving(true), "/body/DocFragment[3]/p[2].17"),
        true, "resolves: true when the document contains the xpointer (same file)")

    -- The whole point of the gate: absent here -> do NOT jump, fall back.
    h.assert_equal(
        ProgressBridge.xpointer_resolves(doc_resolving(false), "/body/DocFragment[3]/p[2].17"),
        false, "does NOT resolve: xpointer absent here (cross-edition)")

    h.assert_equal(ProgressBridge.xpointer_resolves(doc_resolving(true), ""),
        false, "empty xpointer never resolves")
    h.assert_equal(ProgressBridge.xpointer_resolves(doc_resolving(true), nil),
        false, "nil xpointer never resolves")
    h.assert_equal(ProgressBridge.xpointer_resolves(nil, "/body/p[1].0"),
        false, "nil document never resolves")

    -- C++ call is guarded, not type-predicated: a throwing or missing method
    -- degrades to false instead of crashing the jump.
    local doc_throws = { isXPointerInDocument = function() error("boom") end }
    h.assert_equal(ProgressBridge.xpointer_resolves(doc_throws, "/body/p[1].0"),
        false, "throwing isXPointerInDocument degrades to not-resolvable")
    h.assert_equal(ProgressBridge.xpointer_resolves({}, "/body/p[1].0"),
        false, "missing isXPointerInDocument method degrades to not-resolvable")
end
