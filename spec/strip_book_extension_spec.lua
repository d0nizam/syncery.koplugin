-- =============================================================================
-- spec/strip_book_extension_spec.lua
-- =============================================================================
--
-- Util.strip_book_extension — strips a trailing book-file extension from a
-- display TITLE, but ONLY a recognized one, so a title that merely contains a
-- dot ("Dr. No", "Vol. 1") is left intact.  This is the read-side cleaner for a
-- synceryhash title.txt (which caches a metadata title / basename, normally
-- WITHOUT an extension); the old code stripped everything after the last dot,
-- truncating dotted titles.
-- =============================================================================

local h = require("spec.test_helpers")
h.setup("/tmp/syncery_strip_book_ext_spec_" .. tostring(os.time()))

local Util = require("syncery_util")

-- Titles that merely CONTAIN a dot must be preserved unchanged.
h.assert_equal(Util.strip_book_extension("Dr. No"), "Dr. No",
    "dotted title preserved (\". No\" is not an extension)")
h.assert_equal(Util.strip_book_extension("Vol. 1"), "Vol. 1",
    "dotted title with number preserved")
h.assert_equal(Util.strip_book_extension("Something v2.0"), "Something v2.0",
    "version-like dotted title preserved (.0 is not a known extension)")
h.assert_equal(Util.strip_book_extension("S.T.A.L.K.E.R"), "S.T.A.L.K.E.R",
    "acronym-with-dots preserved (.R is not a known extension)")
h.assert_equal(Util.strip_book_extension("Идиотът"), "Идиотът",
    "title with no dot preserved")
h.assert_equal(Util.strip_book_extension("9783161484100"), "9783161484100",
    "bare ISBN-like name preserved")
h.assert_equal(Util.strip_book_extension("notes.xyz"), "notes.xyz",
    "unknown suffix is NOT stripped from a title")

-- A value that IS a filename (junk metadata / legacy cache) is cleaned.
h.assert_equal(Util.strip_book_extension("mybook.epub"), "mybook",
    "recognized extension stripped")
h.assert_equal(Util.strip_book_extension("War and Peace.pdf"), "War and Peace",
    "recognized extension stripped, spaces kept")
h.assert_equal(Util.strip_book_extension("book.EPUB"), "book",
    "extension match is case-insensitive")
h.assert_equal(Util.strip_book_extension("The.Matrix.epub"), "The.Matrix",
    "only the final recognized extension is stripped; inner dots kept")

-- Edges.
h.assert_equal(Util.strip_book_extension(".epub"), ".epub",
    "leading-dot-only value left intact (no empty stem)")
h.assert_equal(Util.strip_book_extension(""), "",
    "empty string returned unchanged")
h.assert_nil(Util.strip_book_extension(nil),
    "nil returned unchanged")
h.assert_equal(Util.strip_book_extension(123), 123,
    "non-string returned unchanged")

print("strip_book_extension_spec: all assertions passed")
h.teardown()
