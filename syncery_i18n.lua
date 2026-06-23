-- syncery_i18n.lua – Lightweight PO-based i18n for Syncery
--
-- Returns two functions:
--   translate(msgid)               → translated string, or msgid on miss
--   ngettext(singular, plural, n)  → correct plural form for n
--
-- PO files are expected at:
--   <plugin_dir>/locale/<lang>.po

local logger = require("logger")

-- Resolve the directory this file lives in so we can find locale/*.po
local _dir = (debug.getinfo(1, "S").source:match("^@(.+[/\\])") or "./")

-- ── plural rules ──────────────────────────────────────────────────────────────
-- A small whitelist of well-known Plural-Forms expressions.
-- Unknown rules fall back to the English (n != 1) two-form rule.
local PLURAL_RULES = {
    ["(n != 1)"]  = { nplurals = 2, fn = function(n) return n ~= 1 and 1 or 0 end },
    ["n != 1"]    = { nplurals = 2, fn = function(n) return n ~= 1 and 1 or 0 end },
    ["(n > 1)"]   = { nplurals = 2, fn = function(n) return n  > 1 and 1 or 0 end },
    ["n > 1"]     = { nplurals = 2, fn = function(n) return n  > 1 and 1 or 0 end },
    ["0"]         = { nplurals = 1, fn = function(_) return 0 end },    -- zh, ja …
    -- Slavic three-form rule (bg, ru, uk, hr …)
    ["(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2)"] = {
        nplurals = 3,
        fn = function(n)
            n = math.floor(math.abs(n))
            local m10, m100 = n % 10, n % 100
            if m10 == 1 and m100 ~= 11 then return 0 end
            if m10 >= 2 and m10 <= 4 and (m100 < 10 or m100 >= 20) then return 1 end
            return 2
        end,
    },
}

local DEFAULT_PLURAL = PLURAL_RULES["(n != 1)"]

local function parse_plural_header(header_msgstr)
    if not header_msgstr or header_msgstr == "" then return DEFAULT_PLURAL end
    local pf = header_msgstr:match("Plural%-Forms:%s*([^\n]*)")
    if not pf then return DEFAULT_PLURAL end
    local expr = pf:match("plural%s*=%s*(.-)%s*;?%s*$")
    if not expr then return DEFAULT_PLURAL end
    expr = expr:match("^%s*(.-)%s*$")
    return PLURAL_RULES[expr] or DEFAULT_PLURAL
end

-- ── PO parser (msgid_plural / msgstr[N] / BOM) ────────────────────────────────
local function parsePO(filepath)
    local f = io.open(filepath, "r")
    if not f then return nil, nil end

    local function unescape(s)
        return (s:gsub("\\\\", "\001"):gsub("\\n", "\n")
                 :gsub("\\t", "\t"):gsub('\\"', '"'):gsub("\001", "\\"))
    end

    local map           = {}
    local header_msgstr = nil
    local cur, mode, str_idx = nil, nil, nil

    local function flush()
        if not cur then return end
        if cur.id == "" then
            header_msgstr = cur.str or ""
        elseif cur.id then
            local entry
            if cur.id_plural and cur.strs and next(cur.strs) then
                local non_empty = false
                for __, v in pairs(cur.strs) do
                    if v ~= "" then non_empty = true; break end
                end
                if non_empty then
                    entry = { plurals = cur.strs, id_plural = cur.id_plural }
                end
            elseif cur.str and cur.str ~= "" then
                entry = { str = cur.str }
            end
            if entry then map[cur.id] = entry end
        end
        cur, mode, str_idx = nil, nil, nil
    end

    local first = true
    for line in f:lines() do
        if first then
            line = line:gsub("^\xEF\xBB\xBF", "")   -- strip UTF-8 BOM
            first = false
        end
        line = line:match("^%s*(.-)%s*$")

        if line == "" or line:sub(1, 1) == "#" then
            -- blank / comment: skip
        elseif line:match("^msgctxt%s+") then
            flush()
            mode = "ctxt"   -- ignore msgctxt and its continuation strings
        elseif line:match("^msgid_plural%s+") then
            if cur then
                cur.id_plural = unescape(line:match('^msgid_plural%s+"(.*)"$') or "")
                mode = "id_plural"
            end
        elseif line:match("^msgid%s+") then
            flush()
            cur = { id = unescape(line:match('^msgid%s+"(.*)"$') or ""), strs = {} }
            mode = "id"
        elseif line:match("^msgstr%s*%[%s*%d+%s*%]%s*") then
            local idx = tonumber(line:match("^msgstr%s*%[%s*(%d+)%s*%]"))
            local s   = unescape(line:match('^msgstr%s*%[%s*%d+%s*%]%s*"(.*)"$') or "")
            if cur and idx then
                cur.strs[idx] = s
                str_idx = idx
                mode    = "str_n"
            end
        elseif line:match("^msgstr%s+") then
            if cur then
                cur.str = unescape(line:match('^msgstr%s+"(.*)"$') or "")
                mode = "str"
            end
        elseif line:sub(1, 1) == '"' then
            if cur then
                local cont = unescape(line:match('^"(.*)"$') or "")
                if     mode == "id"        then cur.id        = cur.id        .. cont
                elseif mode == "id_plural" then cur.id_plural = cur.id_plural .. cont
                elseif mode == "str"       then cur.str       = (cur.str       or "") .. cont
                elseif mode == "str_n" and str_idx then
                    cur.strs[str_idx] = (cur.strs[str_idx] or "") .. cont
                end
                -- ctxt continuations intentionally ignored
            end
        end
    end
    flush()
    f:close()

    return (next(map) or header_msgstr) and map or nil, header_msgstr
end

-- ── language detection & PO loading ──────────────────────────────────────────

local function detectLang()
    local lang = G_reader_settings and G_reader_settings:readSetting("language")
    if type(lang) == "string" and lang ~= "" then return lang end
    local lc = os.getenv("LANG") or os.getenv("LC_ALL") or os.getenv("LC_MESSAGES") or ""
    return lc:match("^([%a_]+)") or "en"
end

local function loadPO(lang)
    if lang == "en" or lang:match("^en[_%-]") then return nil, nil end
    local tag = lang
    while tag and tag ~= "" do
        local path = _dir .. "locale/" .. tag .. ".po"
        local t, header = parsePO(path)
        if t then
            logger.info("Syncery i18n: loaded " .. path)
            return t, header
        end
        local shorter = tag:match("^(.+)[_%-][^_%-]+$")
        if not shorter then break end
        tag = shorter
    end
    return nil, nil
end

-- ── public translate / ngettext ───────────────────────────────────────────────

local _i18n_loaded = false
local _translations, _plural = nil, DEFAULT_PLURAL

local function initI18n()
    if _i18n_loaded then return end
    _i18n_loaded = true
    local map, header = loadPO(detectLang())
    _translations = map
    _plural       = parse_plural_header(header)
end

--- translate(msgid) → translated string, or msgid on miss.
local function translate(msgid)
    if not _i18n_loaded then initI18n() end
    if type(_translations) == "table" then
        local entry = _translations[msgid]
        if entry then
            if entry.str and entry.str ~= "" then return entry.str end
            -- Plural-only entry: return the singular (index 0) plural form.
            if entry.plurals and entry.plurals[0] and entry.plurals[0] ~= "" then
                return entry.plurals[0]
            end
        end
    end
    return msgid
end

--- ngettext(singular, plural, n) → correct plural form for n.
local function ngettext(singular, plural, n)
    if not _i18n_loaded then initI18n() end
    n = tonumber(n) or 0
    if type(_translations) == "table" then
        local entry = _translations[singular]
        if entry and entry.plurals then
            local idx = _plural.fn(n)
            local s = entry.plurals[idx]
            if s and s ~= "" then return s end
        end
    end
    return n == 1 and singular or plural
end

return { translate = translate, ngettext = ngettext }
