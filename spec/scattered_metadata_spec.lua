-- =============================================================================
-- spec/scattered_metadata_spec.lua
-- =============================================================================
--
-- Tests the READ-ONLY detection module syncery_migration/scattered_metadata.lua
-- (Step 1 of the synceryhash->SDR "your KOReader metadata is scattered" advisory).
--
-- The module asks KOReader's DocSettings, per book, WHERE its native
-- metadata.lua sits (via findSidecarFile -> location), and reports the ones
-- NOT in the user's chosen document_metadata_folder, broken down by location.
--
-- We inject a fake docsettings via deps (mirroring how hash_location_finder is
-- tested) so we control each book's reported location precisely. The module
-- never touches the filesystem, so no real files are needed.
--
-- Scenario (preferred = "doc", i.e. book folder):
--   A -> "doc"   : in preferred  => NOT scattered
--   B -> "dir"   : docsettings   => scattered
--   C -> "hash"  : hashdocsettings => scattered
--   D -> "dir"   : docsettings   => scattered (second, to prove by_location count = 2)
--   E -> nil     : no metadata.lua at all => skipped (not scanned, not scattered)
--
-- Expected report:
--   preferred="doc", preferred_label="book folder"
--   total_scanned=4 (A,B,C,D have metadata; E doesn't)
--   total_scattered=3 (B,C,D)
--   by_location={ dir=2, hash=1 }
--
-- Regression guard: break the core `location ~= preferred` predicate in the
-- real module and prove the counts go wrong (test catches it), then restore.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_scattered_meta_spec_" .. tostring(os.time()))

local ScatteredMetadata = require("syncery_migration/scattered_metadata")

-- A fake DocSettings whose findSidecarFile returns a per-book location.
-- The location map is keyed by book file path; a nil entry models "no
-- native metadata.lua exists for this book" (findSidecarFile returns nil).
local function make_fake_docsettings(location_by_file)
    return {
        findSidecarFile = function(_self, doc_path)
            local loc = location_by_file[doc_path]
            if not loc then
                return nil  -- no metadata.lua anywhere for this book
            end
            -- Return a plausible sidecar path + the location (the location is
            -- what the module actually consumes).
            return doc_path .. ".sdr/metadata.epub.lua", loc
        end,
    }
end

-- ---------------------------------------------------------------------------
-- CASE 1 — the main scenario.
-- ---------------------------------------------------------------------------
do
    local A = "/lib/A.epub"
    local B = "/lib/B.epub"
    local C = "/lib/C.epub"
    local D = "/lib/D.epub"
    local E = "/lib/E.epub"

    local fake = make_fake_docsettings({
        [A] = "doc",
        [B] = "dir",
        [C] = "hash",
        [D] = "dir",
        -- E omitted => no metadata
    })

    local books = {
        { file = A }, { file = B }, { file = C }, { file = D }, { file = E },
    }

    local report = ScatteredMetadata.detect(books, {
        docsettings = fake,
        preferred   = "doc",
    })

    h.assert_equal(report.preferred, "doc", "case1: preferred location recorded")
    h.assert_equal(report.preferred_label, "book folder", "case1: preferred label is human-readable")
    h.assert_equal(report.total_scanned, 4, "case1: 4 books had native metadata (E skipped)")
    h.assert_equal(report.total_scattered, 3, "case1: 3 books scattered (B,C,D)")
    h.assert_equal(report.by_location["dir"], 2, "case1: 2 scattered in docsettings (B,D)")
    h.assert_equal(report.by_location["hash"], 1, "case1: 1 scattered in hashdocsettings (C)")
    h.assert_nil(report.by_location["doc"], "case1: none counted as scattered in preferred (doc)")
    h.assert_equal(#report.scattered, 3, "case1: scattered list has 3 entries")

    -- Each scattered entry carries file, location, and a human label.
    local seen_files = {}
    for _, e in ipairs(report.scattered) do
        seen_files[e.file] = e.location
        h.assert_true(e.label ~= nil and e.label ~= "", "case1: scattered entry has a label")
    end
    h.assert_equal(seen_files[B], "dir", "case1: B reported in dir")
    h.assert_equal(seen_files[C], "hash", "case1: C reported in hash")
    h.assert_equal(seen_files[D], "dir", "case1: D reported in dir")
    h.assert_nil(seen_files[A], "case1: A (in preferred) NOT in scattered list")
    h.assert_nil(seen_files[E], "case1: E (no metadata) NOT in scattered list")
end

-- ---------------------------------------------------------------------------
-- CASE 2 — preferred = "hash": now the SAME books shift classification.
-- A(doc) and B/D(dir) become scattered; C(hash) is now in-preferred.
-- Proves the predicate is relative to the chosen location, not hard-coded.
-- ---------------------------------------------------------------------------
do
    local A = "/lib2/A.epub"
    local B = "/lib2/B.epub"
    local C = "/lib2/C.epub"

    local fake = make_fake_docsettings({ [A] = "doc", [B] = "dir", [C] = "hash" })
    local report = ScatteredMetadata.detect(
        { { file = A }, { file = B }, { file = C } },
        { docsettings = fake, preferred = "hash" })

    h.assert_equal(report.preferred_label, "koreader/hashdocsettings", "case2: hash label")
    h.assert_equal(report.total_scattered, 2, "case2: A and B scattered when preferred=hash")
    h.assert_equal(report.by_location["doc"], 1, "case2: A counted in doc")
    h.assert_equal(report.by_location["dir"], 1, "case2: B counted in dir")
    h.assert_nil(report.by_location["hash"], "case2: C (now in preferred) not scattered")
end

-- ---------------------------------------------------------------------------
-- CASE 3 — graceful degrade: a DocSettings without findSidecarFile yields an
-- empty report (no error). Models an older KOReader lacking the primitive.
-- ---------------------------------------------------------------------------
do
    local report = ScatteredMetadata.detect(
        { { file = "/x/Book.epub" } },
        { docsettings = {}, preferred = "doc" })  -- empty table: no findSidecarFile
    h.assert_equal(report.total_scanned, 0, "case3: nothing scanned without the API")
    h.assert_equal(report.total_scattered, 0, "case3: nothing scattered without the API")
    h.assert_equal(#report.scattered, 0, "case3: empty scattered list without the API")
end

-- ---------------------------------------------------------------------------
-- CASE 4 — robustness: bad input (nil books, entries without .file) is tolerated.
-- ---------------------------------------------------------------------------
do
    local fake = make_fake_docsettings({})
    local r_nil = ScatteredMetadata.detect(nil, { docsettings = fake, preferred = "doc" })
    h.assert_equal(r_nil.total_scanned, 0, "case4: nil books => empty, no error")

    local r_junk = ScatteredMetadata.detect(
        { {}, { file = "" }, "not-a-table", { file = "/lib4/Real.epub" } },
        { docsettings = make_fake_docsettings({ ["/lib4/Real.epub"] = "dir" }), preferred = "doc" })
    h.assert_equal(r_junk.total_scanned, 1, "case4: only the one real book is scanned")
    h.assert_equal(r_junk.total_scattered, 1, "case4: that real book is scattered (dir)")
end

h.teardown()
print("scattered_metadata_spec: all assertions passed")
