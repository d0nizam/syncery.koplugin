-- =============================================================================
-- spec/cloud_prefetch_spec.lua
-- =============================================================================
--
-- Unit tests for Checkpoint 1 of the cloud prefetch design
-- : the book_id safety gate, remote
-- listing grouping, and validated-write primitives shared by both
-- transport paths.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup()

local ProgressPaths = require("syncery_progress/paths")

local PluginSync = require("syncery_transports/plugin_sync")


-- ── _isSafeBookId (Constraint X — security-critical, test first) ───────────

h.assert_true(PluginSync._isSafeBookId("9AFFCFE4A34647A08208E4D610DF10C3"),
    "normal hex book_id accepted")
h.assert_true(PluginSync._isSafeBookId("abc-123_ABC"),
    "hyphen/underscore accepted")
h.assert_false(PluginSync._isSafeBookId("../../../etc/passwd"),
    "path traversal rejected")
h.assert_false(PluginSync._isSafeBookId("/etc/passwd"),
    "absolute path rejected")
h.assert_false(PluginSync._isSafeBookId("a/b"),
    "embedded slash rejected")
h.assert_false(PluginSync._isSafeBookId(""),
    "empty string rejected")
h.assert_false(PluginSync._isSafeBookId(nil),
    "nil rejected")
h.assert_false(PluginSync._isSafeBookId(12345),
    "non-string rejected")


-- ── _groupRemoteEntries (Constraint Q) ──────────────────────────────────────

local function entry(text, filesize)
    return { text = text, filesize = filesize }
end

do
    local entries = {
        entry("syncery-progress-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.json", 100),
        entry("syncery-annotations-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.json", 200),
        entry("syncery-progress-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB.json", 50),
        entry("syncery-manifest-somedevice.txt", 10),      -- different kind, ignored
        entry("random-file.txt", 5),                        -- non-matching, ignored
        entry("syncery-progress-../../../etc/passwd.json", 999), -- unsafe, ignored
    }
    local grouped = PluginSync._groupRemoteEntries(entries)

    h.assert_true(grouped["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"] ~= nil,
        "book A grouped")
    h.assert_equal(grouped["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"].progress.filesize, 100,
        "book A progress filesize carried through")
    h.assert_equal(grouped["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"].annotations.filesize, 200,
        "book A annotations filesize carried through")
    h.assert_true(grouped["BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"] ~= nil,
        "book B grouped (progress only)")
    h.assert_nil(grouped["BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"].annotations,
        "book B has no annotations entry")

    local unsafe_count = 0
    for book_id in pairs(grouped) do
        if book_id:match("[^%w%-_]") then unsafe_count = unsafe_count + 1 end
    end
    h.assert_equal(unsafe_count, 0,
        "no unsafe book_id ever entered the grouped table")
end


-- ── _validateAndPlace (Constraints I, J) ────────────────────────────────────

local test_dir = "/tmp/cloud_prefetch_spec_" .. tostring(os.time())
os.execute("mkdir -p " .. test_dir)

do
    local final_path = test_dir .. "/valid.json"
    local ok = PluginSync._validateAndPlace('{"a":1}', final_path)
    h.assert_true(ok, "valid JSON content placed successfully")
    local f = io.open(final_path, "rb")
    h.assert_true(f ~= nil, "final file exists after placement")
    if f then
        h.assert_equal(f:read("*a"), '{"a":1}', "final file content matches")
        f:close()
    end
    h.assert_true(io.open(final_path .. ".tmp") == nil,
        "temp file does not linger after a successful placement")
end

do
    local final_path = test_dir .. "/empty.json"
    local ok, err = PluginSync._validateAndPlace("", final_path)
    h.assert_false(ok, "empty content rejected")
    h.assert_true(err ~= nil, "error message returned for empty content")
    h.assert_true(io.open(final_path) == nil,
        "no file written for empty content")
end

do
    local final_path = test_dir .. "/invalid.json"
    local ok, err = PluginSync._validateAndPlace("not json {{{", final_path)
    h.assert_false(ok, "invalid JSON rejected")
    h.assert_true(err ~= nil, "error message returned for invalid JSON")
    h.assert_true(io.open(final_path) == nil,
        "no file written for invalid JSON")
    h.assert_true(io.open(final_path .. ".tmp") == nil,
        "temp file cleaned up after invalid-JSON rejection")
end

os.execute("rm -rf " .. test_dir)


-- ── _downloadAndValidate (Constraints I, O, P) ──────────────────────────────

local dl_dir = "/tmp/cloud_prefetch_spec_dl_" .. tostring(os.time())
os.execute("rm -rf " .. dl_dir)  -- ensure makePath's mkdir -p is exercised

local fake_plugin = { state_dir = dl_dir .. "/" }
do
    -- Happy path: the cloud I/O facade writes valid JSON to its temp path.
    -- _downloadAndValidate asked for.
    local fake_cloud_io = {
        download_cloud_file = function(_self, remote_name, local_path)
            local f = io.open(local_path, "wb")
            f:write('{"entries":{}}')
            f:close()
            return true
        end,
    }
    local ok = PluginSync._downloadAndValidate(
        fake_plugin, fake_cloud_io, "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", "progress")
    h.assert_true(ok, "happy-path download+validate succeeds")
    local final_path = dl_dir .. "/cloud_staging/prefetch/syncery-progress-CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC.json"
    local f = io.open(final_path, "rb")
    h.assert_true(f ~= nil, "final file exists after successful download")
    if f then f:close() end
end

do
    -- Failed facade response: no file should exist anywhere.
    local fake_cloud_io = {
        download_cloud_file = function()
            return false, "rejected"
        end,
    }
    local ok = PluginSync._downloadAndValidate(
        fake_plugin, fake_cloud_io, "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD", "progress")
    h.assert_false(ok, "failed cloud I/O response rejected")
    local final_path = dl_dir .. "/cloud_staging/prefetch/syncery-progress-DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD.json"
    h.assert_true(io.open(final_path) == nil,
        "no final file for a failed download")
    h.assert_true(io.open(final_path .. ".tmp") == nil,
        "no lingering temp file for a failed download")
end

os.execute("rm -rf " .. dl_dir)

-- ── _moveOrCopyDelete (Constraint C) ────────────────────────────────────────

local mv_dir = "/tmp/cloud_prefetch_spec_mv_" .. tostring(os.time())
os.execute("mkdir -p " .. mv_dir)

do
    -- Same-filesystem path: plain os.rename succeeds.
    local src = mv_dir .. "/src1.json"
    local dst = mv_dir .. "/dst1.json"
    local f = io.open(src, "wb"); f:write('{"x":1}'); f:close()
    local ok = PluginSync._moveOrCopyDelete(src, dst)
    h.assert_true(ok, "same-filesystem move succeeds")
    h.assert_true(io.open(src) == nil, "source removed after successful rename")
    local df = io.open(dst, "rb")
    h.assert_true(df ~= nil, "destination exists after move")
    if df then h.assert_equal(df:read("*a"), '{"x":1}', "destination content correct"); df:close() end
end

do
    -- Force os.rename to fail (simulating EXDEV) -- fallback path must
    -- write+verify+delete instead, never losing the source before the
    -- destination write is confirmed.
    local src = mv_dir .. "/src2.json"
    local dst = mv_dir .. "/dst2.json"
    local f = io.open(src, "wb"); f:write('{"y":2}'); f:close()

    local real_rename = os.rename
    os.rename = function() return nil, "Invalid cross-device link" end
    local ok = PluginSync._moveOrCopyDelete(src, dst)
    os.rename = real_rename

    h.assert_true(ok, "EXDEV-simulated fallback still succeeds")
    h.assert_true(io.open(src) == nil, "source removed after fallback completes")
    local df = io.open(dst, "rb")
    h.assert_true(df ~= nil, "destination exists after fallback")
    if df then h.assert_equal(df:read("*a"), '{"y":2}', "fallback destination content correct"); df:close() end
end

do
    -- Missing source: neither path should raise.
    local ok = PluginSync._moveOrCopyDelete(mv_dir .. "/does-not-exist.json", mv_dir .. "/dst3.json")
    h.assert_false(ok, "missing source reported as failure, not a crash")
end

do
    -- Real-device bug: os.rename reports success (true) but the source
    -- is still physically present on some Android FUSE/SAF setups.
    -- _moveOrCopyDelete must not trust the return value blindly -- verify
    -- and force-remove the leftover once the destination is confirmed.
    local src = mv_dir .. "/src4.json"
    local dst = mv_dir .. "/dst4.json"
    local f = io.open(src, "wb"); f:write('{"z":4}'); f:close()

    local real_rename = os.rename
    os.rename = function(_s, d)
        -- Simulate the quirk: destination gets created, source does not
        -- actually get removed, yet rename still reports success.
        local wf = io.open(d, "wb"); wf:write('{"z":4}'); wf:close()
        return true
    end
    local ok = PluginSync._moveOrCopyDelete(src, dst)
    os.rename = real_rename

    h.assert_true(ok, "the operation is still reported as overall successful")
    h.assert_true(io.open(src) == nil,
        "the lingering source is force-removed once the destination is verified present")
    local df = io.open(dst, "rb")
    h.assert_true(df ~= nil, "destination is present")
    if df then df:close() end
end

os.execute("rm -rf " .. mv_dir)

-- ── apply_staged_prefetch (Constraints M, G, toggle-respecting) ─────────────

local ap_dir = "/tmp/cloud_prefetch_spec_ap_" .. tostring(os.time())
os.execute("rm -rf " .. ap_dir)
os.execute("mkdir -p " .. ap_dir .. "/cloud_staging/prefetch")

local function make_fake_plugin(overrides)
    local p = {
        state_dir        = ap_dir .. "/",
        sync_progress     = true,
        sync_annotations  = true,
        sync_metadata     = true,
        sync_render_settings = true,
        _isFileTypeSynced = function(_self, _book_file) return true end,
    }
    for k, v in pairs(overrides or {}) do p[k] = v end
    return p
end

local book_id = "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"
local fake_book_file = ap_dir .. "/fake_book.epub"
do  -- a real, existing (empty) book file so path-building has something to work with
    local f = io.open(fake_book_file, "wb"); f:write("x"); f:close()
end

local function stage(kind, content)
    local path = ap_dir .. "/cloud_staging/prefetch/syncery-" .. kind .. "-" .. book_id .. ".json"
    local f = io.open(path, "wb"); f:write(content); f:close()
    return path
end

do
    -- Unsafe book_id: defensive check must skip entirely, no crash.
    local plugin = make_fake_plugin()
    local ok = pcall(PluginSync.apply_staged_prefetch, plugin, "../../../etc/passwd", fake_book_file)
    h.assert_true(ok, "unsafe book_id does not raise")
end

do
    -- File type not synced: must return immediately, nothing moved.
    stage("progress", '{"entries":{}}')
    local plugin = make_fake_plugin({
        _isFileTypeSynced = function() return false end,
    })
    local ok = pcall(PluginSync.apply_staged_prefetch, plugin, book_id, fake_book_file)
    h.assert_true(ok, "unsynced file type does not raise")
    local still_staged = io.open(ap_dir .. "/cloud_staging/prefetch/syncery-progress-" .. book_id .. ".json")
    h.assert_true(still_staged ~= nil, "staged file left untouched when file type is not synced")
    if still_staged then still_staged:close() end
end

do
    -- sync_progress = false: progress must stay staged, not moved.
    os.execute("rm -f " .. ap_dir .. "/cloud_staging/prefetch/syncery-progress-" .. book_id .. ".json")
    stage("progress", '{"entries":{}}')
    local plugin = make_fake_plugin({ sync_progress = false })
    local ok = pcall(PluginSync.apply_staged_prefetch, plugin, book_id, fake_book_file)
    h.assert_true(ok, "sync_progress=false path does not raise")
    local still_staged = io.open(ap_dir .. "/cloud_staging/prefetch/syncery-progress-" .. book_id .. ".json")
    h.assert_true(still_staged ~= nil, "progress stays staged when sync_progress is false")
    if still_staged then still_staged:close() end
end

do
    -- End-to-end happy path for apply_staged_prefetch's actual success
    -- case (Checkpoint 2's own tests above only covered the skip/guard
    -- conditions -- their absence is exactly how the real-device
    -- directory-creation bug below reached a device unnoticed).
    --
    -- NOTE on scope: this does NOT reproduce the specific real-device
    -- failure (missing .sdr sidecar directory) end-to-end, because this
    -- suite's docsettings stub (spec/test_helpers/init.lua)
    -- unconditionally mkdir-p's the sidecar directory as a side effect
    -- of resolving the path at all (getSidecarDir) -- and
    -- apply_staged_prefetch itself must resolve that same path (to get
    -- progress_dst/annot_dst) before _ensure_parent_dir ever runs, so
    -- the directory already exists by then regardless of the fix. Real
    -- KOReader's docsettings:getSidecarDir only returns a path string
    -- and creates nothing, which is what actually produced the
    -- "cannot open destination" failure on device. The
    -- _ensure_parent_dir fix itself is a direct, one-line application
    -- of the same require("util").makePath pattern already used a few
    -- lines above for the prefetch/ side of this same function --
    -- confirmed correct by that precedent and the device log, not by an
    -- automated reproduction of the missing-directory precondition,
    -- which this harness cannot currently produce.
    local fresh_book_id = "FEEDFACE00112233FEEDFACE00112233"
    local fresh_book_file = ap_dir .. "/never_opened_book.epub"
    do
        local f = io.open(fresh_book_file, "wb"); f:write("x"); f:close()
    end

    local function stage_for(id, kind, content)
        local path = ap_dir .. "/cloud_staging/prefetch/syncery-" .. kind .. "-" .. id .. ".json"
        local f = io.open(path, "wb"); f:write(content); f:close()
        return path
    end
    stage_for(fresh_book_id, "progress", '{"entries":{"D1":{"percent":0.3}}}')
    stage_for(fresh_book_id, "annotations", '{"annotations":{}}')

    local plugin = make_fake_plugin()
    local ok_call = pcall(PluginSync.apply_staged_prefetch, plugin, fresh_book_id, fresh_book_file)
    h.assert_true(ok_call, "apply does not raise on the success path")

    local progress_dst = ProgressPaths.shared_progress_path(fresh_book_file)
    h.assert_true(progress_dst ~= nil, "a canonical progress path is resolvable")
    if progress_dst then
        local f = io.open(progress_dst, "rb")
        h.assert_true(f ~= nil,
            "progress content actually landed in canonical storage")
        if f then
            h.assert_equal(f:read("*a"), '{"entries":{"D1":{"percent":0.3}}}',
                "moved content matches what was staged")
            f:close()
        end
    end
    h.assert_true(io.open(ap_dir .. "/cloud_staging/prefetch/syncery-progress-" .. fresh_book_id .. ".json") == nil,
        "the source is actually gone from prefetch/ once the move truly succeeds")
end

do
    -- BUGFIX (confirmed empirically via the two-device investigation
    -- harness): apply_staged_prefetch used to ONLY move files into
    -- canonical storage, never staging anything at the FLAT
    -- cloud_staging/ level generateManifest actually scans. A book
    -- that was prefetched and applied but never genuinely
    -- opened/read (so do_cloud_upload never ran for it) stayed in
    -- generateManifest's "never-opened" candidate list FOREVER
    -- (my_manifest.files[book_id] never got an entry), AND the
    -- prefetch staleness check ALWAYS re-downloaded it (the staged
    -- prefetch/ copy was just moved away, so "not staged_size" read
    -- as true every time) -- both firing on every subsequent Sync
    -- Now, indefinitely, for a book with zero real local activity
    -- beyond the one apply. The fix stages a copy of the just-applied
    -- content at the flat level too, exactly mirroring what a real
    -- push would have left there.
    local id2 = "AB12AB12AB12AB12AB12AB12AB12AB12"
    local book_file2 = ap_dir .. "/flat_stage_book.epub"
    do local f = io.open(book_file2, "wb"); f:write("x"); f:close() end

    local function stage_for2(kind, content)
        local path = ap_dir .. "/cloud_staging/prefetch/syncery-" .. kind .. "-" .. id2 .. ".json"
        local f = io.open(path, "wb"); f:write(content); f:close()
    end
    stage_for2("progress", '{"entries":{"D1":{"percent":0.4}}}')
    stage_for2("annotations", '{"annotations":{"k":{"text":"hi"}}}')

    local plugin = make_fake_plugin()
    PluginSync.apply_staged_prefetch(plugin, id2, book_file2)

    local flat_progress = ap_dir .. "/cloud_staging/syncery-progress-" .. id2 .. ".json"
    local flat_annotations = ap_dir .. "/cloud_staging/syncery-annotations-" .. id2 .. ".json"
    local fp = io.open(flat_progress, "rb")
    h.assert_true(fp ~= nil,
        "a copy of the applied progress content is ALSO staged at the flat "
        .. "cloud_staging/ level, not just moved into canonical storage")
    if fp then
        h.assert_equal(fp:read("*a"), '{"entries":{"D1":{"percent":0.4}}}',
            "the flat-staged copy's content matches what was applied")
        fp:close()
    end
    local fa = io.open(flat_annotations, "rb")
    h.assert_true(fa ~= nil,
        "a copy of the applied annotations content is ALSO staged at the flat level")
    if fa then fa:close() end

    -- BUGFIX: the
    -- just-applied content's hash must ALSO land in Fix 4's
    -- push_content_cache, keyed by book_file (matching do_cloud_upload's
    -- own push_cache[state.file] key) -- otherwise do_cloud_upload's
    -- guaranteed-next dispatch (2.5s later, per Constraint H's ordering)
    -- finds nothing cached and unconditionally re-pushes content that
    -- just arrived from the peer.
    local push_cache = PluginSync._read_push_cache(plugin)
    local book_cache = push_cache[book_file2]
    h.assert_true(book_cache ~= nil,
        "apply_staged_prefetch registers a push_content_cache entry for "
        .. "this book_file")
    if book_cache then
        h.assert_equal(book_cache.progress_hash,
            PluginSync._content_hash('{"entries":{"D1":{"percent":0.4}}}'),
            "cached progress_hash matches the just-applied content's hash")
        h.assert_equal(book_cache.annotations_hash,
            PluginSync._content_hash('{"annotations":{"k":{"text":"hi"}}}'),
            "cached annotations_hash matches the just-applied content's hash")
    end
end

os.execute("rm -rf " .. ap_dir)

-- ── _prefetchViaFallback (Constraints S, T -- corrected during implementation) ──

do
    local calls = {}
    local fake_cloud_io = {
        pull_cloud_prefetch = function(_self, book_id, kind, content)
            table.insert(calls, {
                book_id = book_id,
                kind = kind,
                content = content,
            })
        end,
    }
    PluginSync._prefetchViaFallback({ state_dir = "/tmp/" }, fake_cloud_io,
        "1234567890ABCDEF1234567890ABCDEF", "progress")

    h.assert_equal(#calls, 1, "exactly one semantic prefetch call for one kind")
    h.assert_equal(calls[1].kind, "progress",
        "BUGFIX: kind is now the REAL "
        .. "\"progress\", matching the SAME remote cloud object a genuine "
        .. "peer push writes to -- the old \"prefetch_progress\" kind "
        .. "silently pointed at a cloud object no real push ever wrote to")
    h.assert_equal(calls[1].book_id, "1234567890ABCDEF1234567890ABCDEF",
        "book_id passed through unchanged")
    h.assert_true(type(calls[1].content) == "string"
        and calls[1].content ~= "",
        "a non-empty bootstrap envelope string is provided as content")

    PluginSync._prefetchViaFallback({ state_dir = "/tmp/" }, fake_cloud_io,
        "1234567890ABCDEF1234567890ABCDEF", "annotations")
    h.assert_equal(calls[2].kind, "annotations",
        "annotations kind is passed through as the REAL remote kind too")
end


-- ── enumerate_prefetch_staging / extract_title_hint (section 4.4) ──────────

local ui_dir = "/tmp/cloud_prefetch_spec_ui_" .. tostring(os.time())
os.execute("rm -rf " .. ui_dir)
os.execute("mkdir -p " .. ui_dir .. "/cloud_staging/prefetch")

do
    -- Missing folder entirely: must return {} without raising.
    local plugin = { state_dir = "/tmp/definitely-does-not-exist-" .. tostring(os.time()) .. "/" }
    local by_book = PluginSync.enumerate_prefetch_staging(plugin)
    h.assert_deep_equal(by_book, {}, "missing prefetch folder yields an empty table, not an error")
end

do
    local plugin = { state_dir = ui_dir .. "/" }
    local id1 = "1111111111111111111111111111111A"
    local id2 = "2222222222222222222222222222222B"

    local function write(name, content)
        local f = io.open(ui_dir .. "/cloud_staging/prefetch/" .. name, "wb")
        f:write(content); f:close()
    end
    write("syncery-progress-" .. id1 .. ".json",
        '{"entries":{"D1":{"file":"/mnt/us/Books/BG/Some Author - A Title.epub","percent":0.3}}}')
    write("syncery-annotations-" .. id1 .. ".json", '{"annotations":{}}')
    write("syncery-progress-" .. id2 .. ".json", '{"entries":{}}')
    write("syncery-progress-not$safe.json", '{"entries":{}}')  -- unsafe (regex), must be ignored
    write("not-a-syncery-file.txt", "junk")                             -- non-matching, ignored

    local by_book = PluginSync.enumerate_prefetch_staging(plugin)
    h.assert_true(by_book[id1] ~= nil, "book 1 (both kinds) grouped")
    h.assert_true(by_book[id1].progress ~= nil, "book 1 progress path present")
    h.assert_true(by_book[id1].annotations ~= nil, "book 1 annotations path present")
    h.assert_true(by_book[id2] ~= nil, "book 2 (progress only) grouped")
    h.assert_nil(by_book[id2].annotations, "book 2 has no annotations entry")

    local unsafe_count = 0
    for id in pairs(by_book) do
        if id:match("[^%w%-_]") then unsafe_count = unsafe_count + 1 end
    end
    h.assert_equal(unsafe_count, 0, "unsafe book_id never entered the enumerated table")

    local title, full_path = PluginSync.extract_title_hint(by_book[id1].progress)
    h.assert_equal(title, "Some Author - A Title",
        "title extracted from entries[*].file basename, extension stripped")
    h.assert_equal(full_path, "/mnt/us/Books/BG/Some Author - A Title.epub",
        "second return is the FULL recorded path, unstripped")

    local no_title = PluginSync.extract_title_hint(by_book[id2].progress)
    h.assert_nil(no_title, "no \"file\" field present -> nil, not an error")

    h.assert_nil(PluginSync.extract_title_hint(nil), "nil path -> nil, no raise")
    h.assert_nil(PluginSync.extract_title_hint(ui_dir .. "/does-not-exist.json"),
        "missing file -> nil, no raise")
end

os.execute("rm -rf " .. ui_dir)


-- ── _ensure_parent_dir (real-device bug, tested in true isolation from ──
-- ── the docsettings stub's own directory-creating side effect) ──────────

do
    local eps_dir = "/tmp/cloud_prefetch_spec_eps_" .. tostring(os.time())
    os.execute("rm -rf " .. eps_dir)
    -- eps_dir itself does not exist yet -- a genuinely missing multi-level
    -- parent, matching the real device's ".sdr directory does not exist
    -- for a never-opened book" precondition exactly, with no stub in the
    -- way to mask it.
    local target = eps_dir .. "/Some Book.sdr/Some Book.epub.syncery-progress.json"

    PluginSync._ensure_parent_dir(target)

    local lfs = require("syncery_util").get_lfs()
    h.assert_true(lfs.attributes(eps_dir .. "/Some Book.sdr/", "mode") == "directory",
        "the missing multi-level parent directory is created")

    -- And the actual failure mode this fixes: without ensuring the
    -- parent first, writing to target would fail outright.
    local f = io.open(target, "wb")
    h.assert_true(f ~= nil, "the destination is now openable for writing")
    if f then f:write("ok"); f:close() end

    os.execute("rm -rf " .. eps_dir)
end

do
    -- nil path must not raise.
    local ok = pcall(PluginSync._ensure_parent_dir, nil)
    h.assert_true(ok, "nil path does not raise")
end

do
    -- Already-existing parent: must not error, must remain a no-op in
    -- effect (makePath's own documented "mkdir -p" semantics).
    local eps_dir2 = "/tmp/cloud_prefetch_spec_eps2_" .. tostring(os.time())
    os.execute("mkdir -p " .. eps_dir2)
    local ok = pcall(PluginSync._ensure_parent_dir, eps_dir2 .. "/f.json")
    h.assert_true(ok, "an already-existing parent directory does not raise")
    os.execute("rm -rf " .. eps_dir2)
end

h.report("cloud_prefetch_spec")
