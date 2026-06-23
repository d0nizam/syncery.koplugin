-- =============================================================================
-- syncery_ann/time_format.lua
-- =============================================================================
--
-- WHAT THIS FILE DOES
--
-- A tiny module for working with the datetime strings we put inside
-- our JSON files.  Centralized in one place so every other module
-- formats and reads timestamps the same way.
--
--
-- THE FORMAT
--
-- We use "YYYY-MM-DD HH:MM:SS" in LOCAL wall-clock time -- the same
-- convention KOReader uses for its annotation `datetime` fields, which
-- it writes with os.date() WITHOUT the "!" UTC flag.  Example:
-- "2024-11-17 17:57:33".
--
-- Matching KOReader's zone is REQUIRED, not cosmetic: our
-- `datetime_updated` strings are compared (as plain strings) against
-- KOReader's `datetime` inside the merge's newer-wins rule.  If `now()`
-- emitted UTC while KOReader emits local, a deletion on any device east
-- of UTC gets a `datetime_updated` that sorts BEFORE the annotation's
-- creation `datetime` (e.g. "16:40" < "19:38" at UTC+3), so the stale
-- alive copy "wins" and the deleted annotation is resurrected.  That was
-- a real shipped bug; do not reintroduce the "!".
--
-- This format has a nice property: string comparison gives the same
-- result as chronological comparison.  "2024-12-01 00:00:00" sorts
-- after "2024-11-30 23:59:59" both as strings and as times.  This
-- means our merge code can pick "the newer of two annotations" by
-- a simple string comparison, without parsing into Unix timestamps.
--
-- =============================================================================

local TimeFormat = {}


--- Get the current time as a "YYYY-MM-DD HH:MM:SS" LOCAL string,
--- matching KOReader's annotation `datetime` convention so the two are
--- directly string-comparable in the merge's newer-wins rule.
---
--- (Previously this used os.date("!...") = UTC, which silently inverted
--- newer-wins for devices east of UTC and resurrected deleted
--- annotations -- see the file header.)
---
--- @return string The current local time in our standard format.
function TimeFormat.now()
    return os.date("%Y-%m-%d %H:%M:%S")
end


--- Read the datetime_updated field from an annotation, with fallbacks.
---
--- Annotations made by older KOReader versions might only have a
--- `datetime` field (creation time) and no `datetime_updated`.  We
--- treat the creation time as a "last-modified" stand-in for those.
---
--- Returns the empty string for annotations with no datetime at all,
--- which sorts BEFORE any real timestamp — so they always lose merge
--- ties.
---
--- @param annotation table The annotation to inspect.
--- @return string A datetime string suitable for comparison.
function TimeFormat.last_modified_of(annotation)
    if type(annotation) ~= "table" then
        return ""
    end
    return annotation.datetime_updated or annotation.datetime or ""
end


--- Parse a "YYYY-MM-DD HH:MM:SS" datetime string into a Unix-style
--- integer, for COARSE (day-scale) age comparisons.
---
--- The strings we store are LOCAL wall-clock now (see `now()` and the
--- file header).  The legacy `_utc_` in this function's name refers to
--- the ARITHMETIC it performs -- it treats the components as a UTC
--- instant via pure calendar math -- NOT to the timezone of its input.
--- It exists because `os.time({year=..., ...})` interprets its table
--- argument as LOCAL and rounds through DST; this function never calls
--- `os.time`/`os.date`, so it is offset- and DST-agnostic.
---
--- Consequence of local-in / UTC-math: the returned value is shifted
--- from the true epoch by the device's (constant) UTC offset.  The only
--- callers -- tombstone GC and the trash age display -- compare it
--- against an `os.time()` cutoff over a DAYS-long window, where a few
--- hours' constant shift is immaterial.  (A rename is a possible
--- follow-up; behaviour is intentionally unchanged here.)
---
--- Algorithm — direct calendar arithmetic, NO os.time round-trip:
---   epoch = (days_from_1970_to_date) * 86400 + h*3600 + m*60 + s
---
--- The day count comes from `_days_from_2000` (Howard Hinnant's
--- Gregorian date algorithm), anchored to 1970-01-01 by subtracting
--- `_days_from_2000(1970, 1, 1)`.  Because the computation never calls
--- `os.time` or `os.date`, it is completely timezone-independent and
--- immune to DST boundaries — in particular it correctly parses UTC
--- instants whose local wall-clock equivalent does not exist (e.g.
--- 2024-03-31 01:00:00 UTC, which in Europe/London is the exact
--- spring-forward gap 00:59:59 GMT → 02:00:00 BST).  The previous
--- implementation went through `os.time` and an offset-correction
--- loop; that loop could not converge when the input's local
--- wall-clock fell inside a spring-forward gap, producing an answer
--- one hour off.
---
--- Returns 0 for nil / non-string / malformed input.
---
--- @param datetime_string string|nil The datetime string (local wall-clock).
--- @return number The Unix timestamp, or 0 if parsing failed.
function TimeFormat.parse_utc_to_unix(datetime_string)
    if type(datetime_string) ~= "string" then return 0 end

    local y_str, mo_str, d_str, h_str, mi_str, s_str = datetime_string:match(
        "^(%d%d%d%d)-(%d%d)-(%d%d) (%d%d):(%d%d):(%d%d)$")
    if not y_str then return 0 end

    local days = TimeFormat._days_from_2000(
                     tonumber(y_str), tonumber(mo_str), tonumber(d_str))
                 - TimeFormat._days_from_2000(1970, 1, 1)

    return days * 86400
         + tonumber(h_str)   * 3600
         + tonumber(mi_str)  * 60
         + tonumber(s_str)
end


--- Days from 2000-01-01 to the given Gregorian date (Howard Hinnant's
--- date algorithm).  Handles leap years and year boundaries cleanly.
---
--- @param year number
--- @param month number 1..12
--- @param day number 1..31
--- @return number Days since 2000-01-01 (can be negative).
function TimeFormat._days_from_2000(year, month, day)
    if month <= 2 then year = year - 1; month = month + 12 end
    local era = math.floor((year >= 0 and year or year - 399) / 400)
    local year_of_era = year - era * 400
    local day_of_year = math.floor((153 * (month - 3) + 2) / 5) + day - 1
    local day_of_era = year_of_era * 365
                     + math.floor(year_of_era / 4)
                     - math.floor(year_of_era / 100)
                     + day_of_year
    return era * 146097 + day_of_era - 730000
end


return TimeFormat
