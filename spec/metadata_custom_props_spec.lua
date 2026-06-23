-- =============================================================================
-- spec/metadata_custom_props_spec.lua
-- =============================================================================
--
-- Tests that MetadataBridge reads user-edited book properties from KOReader's
-- REAL location — `custom_props` in the separate `custom_metadata.lua` sidecar
-- file — rather than a `doc_settings["custom_metadata"]` key that KOReader
-- never writes.
--
-- Scenario (as requested): a book with NO custom metadata -> _read_custom emits
-- nothing; then the user adds custom metadata (title/author) in the separate
-- file -> _read_custom now detects and emits it (so it becomes syncable).
--
-- The file access is isolated behind MetadataBridge._load_custom_props, which
-- we stub here so the test exercises our logic without touching disk.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_metadata_custom_props_spec_" .. tostring(os.time()))

local MetadataBridge = require("syncery_ann/metadata_bridge")


-- Save/restore the seam so each case controls what "the custom file" holds.
local original_load = MetadataBridge._load_custom_props


local function with_custom_props(props, fn)
    MetadataBridge._load_custom_props = function(_ui) return props end
    local ok, err = pcall(fn)
    MetadataBridge._load_custom_props = original_load
    if not ok then error(err) end
end


-- A minimal ui; _read_custom only forwards it to the (stubbed) seam.
local fake_ui = { doc_settings = {} }


-- ----------------------------------------------------------------------------
-- TEST 1: a book WITHOUT custom metadata -> _read_custom emits nothing.
-- ----------------------------------------------------------------------------


do
    -- No custom file at all (getCustomMetadataFile would return false) -> seam nil.
    with_custom_props(nil, function()
        local md = MetadataBridge._read_custom(fake_ui)
        h.assert_nil(md, "book without custom metadata emits nil")
    end)

    -- Custom file exists but has no user-editable fields set -> still nil.
    with_custom_props({}, function()
        local md = MetadataBridge._read_custom(fake_ui)
        h.assert_nil(md, "empty custom_props emits nil")
    end)
end


-- ----------------------------------------------------------------------------
-- TEST 2: the user ADDS custom metadata (title + author) -> _read_custom
-- detects and emits exactly those fields.
-- ----------------------------------------------------------------------------


do
    -- KOReader's custom_props keys match ours: title/authors/series/series_index/language.
    local custom_props = {
        title   = "My Custom Title",
        authors = "Edited Author",
    }
    with_custom_props(custom_props, function()
        local md = MetadataBridge._read_custom(fake_ui)
        h.assert_true(md ~= nil, "custom metadata is detected once added")
        h.assert_equal(md.title, "My Custom Title", "custom title is emitted")
        h.assert_equal(md.authors, "Edited Author", "custom author is emitted")
        -- Untouched fields stay nil (only what the user actually set).
        h.assert_nil(md.series, "unset series stays nil")
        h.assert_nil(md.language, "unset language stays nil")
    end)
end


-- ----------------------------------------------------------------------------
-- TEST 3: all seven user-editable custom fields (incl. keywords/description)
-- round-trip through _read_custom.
-- ----------------------------------------------------------------------------


do
    local custom_props = {
        title        = "T",
        authors      = "A",
        series       = "S",
        series_index = 3,
        language     = "en",
        keywords     = "sci-fi, classic",
        description  = "A short summary.",
    }
    with_custom_props(custom_props, function()
        local md = MetadataBridge._read_custom(fake_ui)
        h.assert_equal(md.title,        "T",  "title")
        h.assert_equal(md.authors,      "A",  "authors")
        h.assert_equal(md.series,       "S",  "series")
        h.assert_equal(md.series_index, 3,    "series_index")
        h.assert_equal(md.language,     "en", "language")
        h.assert_equal(md.keywords,     "sci-fi, classic", "keywords now synced")
        h.assert_equal(md.description,  "A short summary.", "description now synced")
    end)
end


-- ----------------------------------------------------------------------------
-- TEST 4: _read_custom emits when at least ONE of title/authors/series/language
-- is set (series_index alone is not a user-meaningful edit).
-- ----------------------------------------------------------------------------


do
    with_custom_props({ series = "Just a series" }, function()
        local md = MetadataBridge._read_custom(fake_ui)
        h.assert_true(md ~= nil, "series alone is enough to emit")
        h.assert_equal(md.series, "Just a series", "series carried")
    end)

    with_custom_props({ series_index = 5 }, function()
        local md = MetadataBridge._read_custom(fake_ui)
        h.assert_nil(md, "series_index alone does not emit (no primary field set)")
    end)
end


-- ----------------------------------------------------------------------------
-- TEST 5: the SEAM itself (_load_custom_props) reads `custom_props` from the
-- file resolved via getCustomMetadataFile — NOT some other key.  We fake the
-- DocSettings file access so the test verifies the real read path's shape
-- without touching disk.
-- ----------------------------------------------------------------------------


do
    -- This test must exercise the real _load_custom_props, so restore it first
    -- (the with_custom_props helper above stubs it; we are outside that here).
    -- We override the module require seam: _load_custom_props calls
    -- ui.doc_settings:getCustomMetadataFile() then require("docsettings")
    -- .openSettingsFile(path):readSetting("custom_props").

    -- Case A: book without a custom file -> getCustomMetadataFile returns false.
    local ui_no_file = {
        doc_settings = {
            getCustomMetadataFile = function(_self) return false end,
        },
    }
    h.assert_nil(MetadataBridge._load_custom_props(ui_no_file),
        "_load_custom_props returns nil when there is no custom file")

    -- Case B: getCustomMetadataFile missing entirely (older/edge) -> nil, no crash.
    local ui_no_method = { doc_settings = {} }
    local okp = pcall(MetadataBridge._load_custom_props, ui_no_method)
    h.assert_true(okp, "_load_custom_props does not crash without getCustomMetadataFile")
    h.assert_nil(MetadataBridge._load_custom_props(ui_no_method),
        "_load_custom_props returns nil when getCustomMetadataFile is absent")

    -- Case C: a real custom file path -> reads custom_props via openSettingsFile.
    -- We fake the docsettings module so openSettingsFile returns a settings
    -- object whose readSetting("custom_props") yields our table — proving the
    -- seam reads the `custom_props` KEY specifically.
    local fake_doc_settings_module = {
        openSettingsFile = function(path)
            -- The path is whatever getCustomMetadataFile returned.
            return {
                _path = path,
                readSetting = function(_self, key)
                    if key == "custom_props" then
                        return { title = "FromFile", authors = "FileAuthor" }
                    end
                    return nil  -- any OTHER key must NOT be how we read custom data
                end,
            }
        end,
    }
    package.loaded["docsettings"] = fake_doc_settings_module

    local ui_with_file = {
        doc_settings = {
            getCustomMetadataFile = function(_self)
                return "/fake/sidecar/custom_metadata.lua"
            end,
        },
    }
    local props = MetadataBridge._load_custom_props(ui_with_file)
    h.assert_true(props ~= nil, "_load_custom_props loads props from the resolved file")
    h.assert_equal(props.title, "FromFile",
        "_load_custom_props reads the custom_props KEY (title)")
    h.assert_equal(props.authors, "FileAuthor",
        "_load_custom_props reads the custom_props KEY (authors)")

    package.loaded["docsettings"] = nil  -- clean up the faked module
end


-- ----------------------------------------------------------------------------
-- TEST 6 (WRITE — apply remote): applying remote custom metadata to a book
-- WITHOUT a custom file creates one and writes custom_props via
-- flushCustomMetadata.  Then a read sees the same values (round-trip).
-- ----------------------------------------------------------------------------


do
    -- A fake custom-metadata file backed by an in-memory table, modelling
    -- KOReader's DocSettings: readSetting/saveSetting on its own data +
    -- flushCustomMetadata persisting (here: just marks flushed).
    local function make_fake_custom_file(initial)
        local data = initial or {}
        return {
            data = data,
            _flushed = false,
            _flush_path = nil,
            readSetting = function(self, key) return self.data[key] end,
            saveSetting = function(self, key, val) self.data[key] = val end,
            flushCustomMetadata = function(self, doc_path)
                self._flushed = true
                self._flush_path = doc_path
                return true
            end,
        }
    end

    -- Track the file the seam creates/opens.
    local created_file
    local fake_module = {
        openSettingsFile = function(path)
            created_file = make_fake_custom_file()
            created_file._opened_path = path  -- nil when creating new
            return created_file
        end,
    }
    package.loaded["docsettings"] = fake_module

    -- Book WITHOUT a custom file: getCustomMetadataFile returns false.
    local ui = {
        doc_settings = {
            data = { doc_path = "/books/mybook.epub" },
            getCustomMetadataFile = function(_self) return false end,
            readSetting = function(_self, key)
                if key == "doc_props" then
                    return { title = "Original Title", authors = "Orig Author" }
                end
                return nil
            end,
        },
    }

    local remote = { title = "Synced Title", authors = "Synced Author" }
    local changed = MetadataBridge._apply_custom(ui, "/books/mybook.epub", remote)

    h.assert_true(changed, "applying remote custom metadata reports a change")
    h.assert_true(created_file ~= nil, "a custom file handle was created")
    h.assert_true(created_file._flushed, "flushCustomMetadata was called (persisted)")
    h.assert_equal(created_file._flush_path, "/books/mybook.epub",
        "flush used the document path")

    -- The written custom_props hold the synced values.
    local written = created_file.data.custom_props
    h.assert_true(written ~= nil, "custom_props was written")
    h.assert_equal(written.title, "Synced Title", "synced title persisted to custom_props")
    h.assert_equal(written.authors, "Synced Author", "synced author persisted to custom_props")

    -- A new file backs up the original doc_props (so a later reset can restore).
    h.assert_true(created_file.data.doc_props ~= nil,
        "new custom file backs up original doc_props")
    h.assert_equal(created_file.data.doc_props.title, "Original Title",
        "doc_props backup holds the ORIGINAL title")

    package.loaded["docsettings"] = nil
end


-- ----------------------------------------------------------------------------
-- TEST 7 (WRITE — existing file, merge): applying remote metadata to a book
-- that ALREADY has custom_props merges in, leaving untouched fields intact and
-- not re-flushing when nothing actually changes.
-- ----------------------------------------------------------------------------


do
    -- Model a persistent on-disk custom file: openSettingsFile returns a handle
    -- backed by the SAME underlying data across calls (so a second apply sees
    -- what the first one wrote — as a real file would).
    local persistent_data = { custom_props = { title = "Keep Me", series = "Old Series" } }
    local last_handle
    local fake_module = {
        openSettingsFile = function(path)
            last_handle = {
                data = persistent_data,  -- shared, persists across opens
                _flushed = false,
                _opened_path = path,
                readSetting = function(self, key) return self.data[key] end,
                saveSetting = function(self, key, val) self.data[key] = val end,
                flushCustomMetadata = function(self) self._flushed = true; return true end,
            }
            return last_handle
        end,
    }
    package.loaded["docsettings"] = fake_module

    local ui = {
        doc_settings = {
            data = { doc_path = "/books/has_custom.epub" },
            getCustomMetadataFile = function(_self)
                return "/sdr/has_custom/custom_metadata.lua"  -- existing
            end,
            readSetting = function(_self, _key) return nil end,
        },
    }

    -- Remote sets a NEW series + adds language; title is left untouched.
    local changed = MetadataBridge._apply_custom(ui, "/books/has_custom.epub",
        { series = "New Series", language = "fr" })

    h.assert_true(changed, "merge into existing custom_props reports change")
    h.assert_equal(last_handle._opened_path, "/sdr/has_custom/custom_metadata.lua",
        "opened the EXISTING custom file (not a new one)")
    h.assert_equal(persistent_data.custom_props.title, "Keep Me",
        "untouched field (title) preserved")
    h.assert_equal(persistent_data.custom_props.series, "New Series",
        "changed field (series) updated")
    h.assert_equal(persistent_data.custom_props.language, "fr",
        "new field (language) added")

    -- Applying the SAME values again is a no-op (no change, no flush) — now that
    -- the file persists, the second apply sees the already-written values.
    last_handle._flushed = false
    local changed2 = MetadataBridge._apply_custom(ui, "/books/has_custom.epub",
        { series = "New Series", language = "fr" })
    h.assert_false(changed2, "re-applying identical values reports no change")
    h.assert_false(last_handle._flushed, "no flush when nothing changed")

    package.loaded["docsettings"] = nil
end


-- ----------------------------------------------------------------------------
-- TEST 8 (cache reset on create): creating custom_metadata.lua for a book that
-- had none must reset the open book's getCustomMetadataFile path cache, or
-- _load_custom_props (and KOReader's instance reads) miss the new file until
-- reopen and the apply value-gate re-applies it every sync.
-- ----------------------------------------------------------------------------


do
    package.loaded["docsettings"] = {
        openSettingsFile = function(_path)
            return {
                data = {},
                readSetting = function(self, key) return self.data[key] end,
                saveSetting = function(self, key, val) self.data[key] = val end,
                flushCustomMetadata = function() return true end,
            }
        end,
    }

    local reset_called
    local ui = {
        doc_props = {},
        doc_settings = {
            data = { doc_path = "/books/new.epub" },
            getCustomMetadataFile = function(_self, reset_cache)
                if reset_cache then reset_called = true; return end
                return false  -- no custom file yet -> create path
            end,
            readSetting = function(_self, key)
                if key == "doc_props" then return { title = "Orig" } end
                return nil
            end,
        },
    }

    MetadataBridge._apply_custom(ui, "/books/new.epub", { title = "Synced" })
    h.assert_true(reset_called,
        "creating custom_metadata.lua resets the path cache (getCustomMetadataFile(true))")

    package.loaded["docsettings"] = nil
end


-- ----------------------------------------------------------------------------
-- TEST 9 (display refresh): a custom-metadata apply updates the OPEN document's
-- in-memory doc_props (so the reader reflects it live) and broadcasts
-- InvalidateMetadataCache for the file (so the coverbrowser re-extracts
-- custom_metadata.lua when the FileManager is next shown).
-- ----------------------------------------------------------------------------


do
    local persistent = { custom_props = {} }
    package.loaded["docsettings"] = {
        openSettingsFile = function(_path)
            return {
                data = persistent,
                readSetting = function(self, key) return self.data[key] end,
                saveSetting = function(self, key, val) self.data[key] = val end,
                flushCustomMetadata = function() return true end,
            }
        end,
    }

    local broadcasts = {}
    package.loaded["ui/uimanager"] = {
        broadcastEvent = function(_self, ev) table.insert(broadcasts, ev) end,
    }
    package.loaded["ui/event"] = {
        new = function(_self, name, arg) return { name = name, arg = arg } end,
    }

    local ui = {
        doc_props = { title = "Old", authors = "Old A", display_title = "Old" },
        doc_settings = {
            data = { doc_path = "/books/disp.epub" },
            getCustomMetadataFile = function(_self) return "/sdr/disp/custom_metadata.lua" end,
            readSetting = function(_self, _key) return nil end,
        },
    }

    MetadataBridge._apply_custom(ui, "/books/disp.epub",
        { title = "New Title", authors = "New Author" })

    h.assert_equal(ui.doc_props.title, "New Title",         "doc_props.title updated in memory")
    h.assert_equal(ui.doc_props.authors, "New Author",      "doc_props.authors updated in memory")
    h.assert_equal(ui.doc_props.display_title, "New Title", "doc_props.display_title updated for title")

    local found_invalidate = false
    for _, ev in ipairs(broadcasts) do
        if ev.name == "InvalidateMetadataCache" and ev.arg == "/books/disp.epub" then
            found_invalidate = true
        end
    end
    h.assert_true(found_invalidate,
        "InvalidateMetadataCache broadcast for the book file (coverbrowser eviction)")

    package.loaded["ui/uimanager"] = nil
    package.loaded["ui/event"]     = nil
    package.loaded["docsettings"]  = nil
end


-- ----------------------------------------------------------------------------
-- TEST 10 (keywords/description sync): the two text fields added to the custom
-- scope (KOReader's BookInfo.props) are written on apply, alongside the others.
-- ----------------------------------------------------------------------------


do
    local persistent = { custom_props = {} }
    package.loaded["docsettings"] = {
        openSettingsFile = function(_path)
            return {
                data = persistent,
                readSetting = function(self, key) return self.data[key] end,
                saveSetting = function(self, key, val) self.data[key] = val end,
                flushCustomMetadata = function() return true end,
            }
        end,
    }
    local ui = {
        doc_props = {},
        doc_settings = {
            data = { doc_path = "/books/kw.epub" },
            getCustomMetadataFile = function(_self) return "/sdr/kw/custom_metadata.lua" end,
            readSetting = function(_self, _key) return nil end,
        },
    }

    local changed = MetadataBridge._apply_custom(ui, "/books/kw.epub",
        { keywords = "fantasy, epic", description = "An epic tale." })

    h.assert_true(changed, "applying keywords/description reports a change")
    h.assert_equal(persistent.custom_props.keywords, "fantasy, epic",
        "keywords written to custom_props")
    h.assert_equal(persistent.custom_props.description, "An epic tale.",
        "description written to custom_props")

    package.loaded["docsettings"] = nil
end


print("metadata_custom_props_spec: all assertions passed")
