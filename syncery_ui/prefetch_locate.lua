-- =============================================================================
-- syncery_ui/prefetch_locate.lua
-- =============================================================================
--
-- Shared "locate this prefetch-only book" flow for Progress Browser and
-- Annotation Browser: a row whose progress/annotations were prefetched
-- from a peer, but whose actual book FILE has never been opened on this
-- device
--
-- Two layers, deliberately split:
--   * PURE decision logic (try_auto_resolve, verify_and_learn) -- no UI
--     widgets touched, fully unit-testable. See spec/prefetch_locate_spec.lua.
--   * UI orchestration (prompt) -- ConfirmBox/PathChooser wiring around the
--     pure functions above. Like main.lua, this half is not directly
--     unit-testable (no real KOReader UI in the sandbox) -- kept
--     deliberately thin so the untested surface is small.
--
-- Design history: considered (and rejected) an automatic filesystem scan
-- across "known" folders (Scan.getScanRoots/deriveRootsFromHistory) --
-- deriveRootsFromHistory only knows folders of ALREADY-opened books, which
-- is exactly what a prefetch-only book is NOT, so it would silently miss
-- a book living anywhere else. Settled on: the user (who knows their own
-- device's folder layout) manually locates the file ONCE per differing
-- folder structure via a native file picker; Syncery verifies it by
-- content-id (never trusts path/filename alone) and LEARNS the
-- peer-path -> local-path prefix substitution, so every SUBSEQUENT
-- prefetch-only book under the same peer folder resolves automatically,
-- no picker needed again.
-- =============================================================================

local PluginSync = require("syncery_transports/plugin_sync")
local Settings   = require("syncery_settings")
local Util       = require("syncery_util")

local PrefetchLocate = {}


--- Try resolving `peer_path` (the ORIGIN device's recorded path for a
--- prefetch-only book) to a file on THIS device, using rules already
--- learned from earlier manual confirmations. Pure: no UI, no prompting
--- -- callers use this to skip the picker entirely when a rule from a
--- previous book already covers this one.
---
--- @return string|nil the verified local path, or nil if no learned rule
---   (or none exist yet) produces a content-id-confirmed match.
function PrefetchLocate.try_auto_resolve(book_id, peer_path)
    if type(book_id) ~= "string" or book_id == ""
            or type(peer_path) ~= "string" or peer_path == "" then
        return nil
    end
    local rules = Settings.get_prefetch_path_rules()
    if #rules == 0 then return nil end
    local resolved, matched_rule = PluginSync.resolve_via_learned_rules(peer_path, book_id, rules)
    if resolved and matched_rule then
        -- Most-recently-used-first: bumps the rule that just worked to
        -- the front, so a run of several prefetch-only books from the
        -- same peer folder (the common case right after a Sync Now)
        -- resolves each subsequent one on the FIRST candidate tried,
        -- not after re-checking earlier, no-longer-relevant rules.
        Settings.bump_prefetch_path_rule_to_front(matched_rule)
    end
    return resolved
end


--- Given a user-selected candidate path (from the file picker) and the
--- target book_id, decide whether it is a genuine match, and if so,
--- derive + persist a new learned rule (when `peer_path` is known, so a
--- LATER book under the same peer folder can auto-resolve). Pure: no UI.
---
--- @return boolean matched
--- @return table|nil learned_rule {peer_prefix, local_prefix}, only when
---   matched AND peer_path was provided AND a rule was newly learned
---   (nil if it was already known, or peer_path was absent -- still a
---   genuine match either way, just nothing NEW to persist).
function PrefetchLocate.verify_and_learn(book_id, peer_path, selected_path)
    if type(book_id) ~= "string" or book_id == ""
            or type(selected_path) ~= "string" or selected_path == "" then
        return false, nil
    end
    local ok_paths, Paths = pcall(require, "syncery_ann/paths")
    if not ok_paths or not Paths or type(Paths._book_content_id) ~= "function" then
        return false, nil
    end
    local ok_id, matched_id = pcall(Paths._book_content_id, selected_path)
    if not ok_id or matched_id ~= book_id then
        return false, nil
    end

    local learned = nil
    if type(peer_path) == "string" and peer_path ~= "" then
        local rule = PluginSync.compute_path_prefix_rule(peer_path, selected_path)
        if rule then
            -- add_prefetch_path_rule itself de-dupes an exact repeat, so
            -- calling it every time a rule reduces to the same prefixes
            -- is harmless; `learned` still reports it for callers that
            -- want to know (e.g. UI copy distinguishing "learned" from
            -- "already knew this one").
            Settings.add_prefetch_path_rule(rule.peer_prefix, rule.local_prefix)
            learned = rule
        end
    end
    return true, learned
end


--- The full UI flow: explain the situation, offer to locate the file,
--- verify + learn on a match, offer retry on a mismatch.
--- `on_opened(local_path)` fires once a verified match is found -- the
--- caller is responsible for actually opening the reader (this module
--- has no opinion on HOW; Progress Browser and Annotation Browser each
--- open slightly differently, e.g. Progress Browser follows up with a
--- jump).
--- @param explain_text string|nil the ConfirmBox's explanatory text.
---   Defaults to the never-opened-anywhere-yet wording (the original,
---   still correct for is_prefetch_only). A book that WAS opened
---   elsewhere but has no resolving path on THIS device
---   (path_unresolved_here) is a DIFFERENT situation and needs its own
---   wording -- callers pass it explicitly rather than this module
---   guessing which case it is.
--- @param title string|nil a human-readable name for the book being
---   located, used to NAME it in the mismatch message ("doesn't match
---   <title>") instead of the anonymous "the synced book". Falls back to
---   peer_path's basename when omitted, so a caller that forgets still
---   gets something recognisable -- the peer's own filename is usually
---   the most identifiable thing the user has. Only if BOTH are absent
---   does the anonymous wording remain.
---
---   Note the initial ConfirmBox deliberately does NOT show this: in
---   Progress/Annotation Browser the user tapped a row whose title was
---   on screen a moment earlier, so repeating it is noise. The mismatch
---   message is different -- by then the user has been through a file
---   picker, possibly more than once, and the title is long gone from
---   the screen. Callers that pick the book THEMSELVES (migration's
---   resolve_not_here_books) name it in their own explain_text instead.
function PrefetchLocate.prompt(book_id, peer_path, on_opened, explain_text, title)
    local UIManager   = require("ui/uimanager")
    local ConfirmBox  = require("ui/widget/confirmbox")
    local PathChooser = require("ui/widget/pathchooser")
    local _           = require("gettext")

    local shown = title
    if (not shown or shown == "") and type(peer_path) == "string" then
        shown = peer_path:match("([^/\\]+)$")
    end

    local function open_picker()
        -- Most users' KOReader "Home folder" IS their book library root
        -- (it's what the file manager itself opens to by default) --
        -- prefer it over the bare device default, matching KOReader's
        -- own canonical resolution (filemanagerutil.getHomeFolder:
        -- G_reader_settings "home_dir" if the user set one, else
        -- Device.home_dir, else ".").
        local ok_fmu, filemanagerutil = pcall(require, "apps/filemanager/filemanagerutil")
        local start_path = (ok_fmu and filemanagerutil.getHomeFolder())
            or (require("device") and require("device").home_dir)
            or "/"
        UIManager:show(PathChooser:new{
            select_directory = false,
            select_file      = true,
            path             = start_path,
            file_filter      = function(filename)
                local ext = filename:match("%.([^.\\/]+)$")
                return ext ~= nil and Util.BOOK_EXTENSIONS[ext:lower()] == true
            end,
            onConfirm = function(selected_path)
                local matched = PrefetchLocate.verify_and_learn(book_id, peer_path, selected_path)
                if matched then
                    on_opened(selected_path)
                else
                    local mismatch
                    if shown and shown ~= "" then
                        mismatch = string.format(_(
                            "That file's content doesn't match %s — "
                            .. "likely a different edition or copy. Try a different file?"), shown)
                    else
                        mismatch = _("That file's content doesn't match the synced book — "
                                     .. "likely a different edition or copy. Try a different file?")
                    end
                    UIManager:show(ConfirmBox:new{
                        text        = mismatch,
                        ok_text     = _("Try again"),
                        ok_callback = open_picker,
                        cancel_text = _("Cancel"),
                    })
                end
            end,
        })
    end

    UIManager:show(ConfirmBox:new{
        text = explain_text or _(
            "Synced from another device — hasn't been opened here yet.\n\n"
            .. "If you already have a copy of this book, point Syncery to it."),
        ok_text     = _("Point to it…"),
        ok_callback = open_picker,
        cancel_text = _("Cancel"),
    })
end


return PrefetchLocate
