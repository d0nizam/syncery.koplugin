-- =============================================================================
-- spec/jump_toast_spec.lua
-- =============================================================================
--
-- Phase 14.2/14.4 — the jump invitation's pure MESSAGE
-- (syncery_ui/jump_toast.lua). As of 14.4 the show/finish control and the
-- overlay are owned by the notification coordinator (see notify_spec) and the
-- shared toast widget; this module is just the wording, so that is all we
-- assert here. A main.lua audit confirms the invite is routed through the
-- coordinator and the old blocking-modal builder is gone.
-- =============================================================================


local h = require("spec.test_helpers")

package.loaded["syncery_i18n"] = {
    translate = function(s) return s end,
    ngettext  = function(s, p, n) if n == 1 then return s else return p end end,
}
package.loaded["syncery_ui/jump_toast"] = nil
local JumpToast = require("syncery_ui/jump_toast")


-- --- message -----------------------------------------------------------------
do
    local m = JumpToast.message({ remote_label = "Kobo", page = 47 })
    h.assert_true(m:find("Kobo", 1, true) ~= nil, "message: includes the device label")
    h.assert_true(m:find("47", 1, true) ~= nil, "message: includes the page number")

    local p = JumpToast.message({ remote_label = "Tablet", percent = 0.5 })
    h.assert_true(p:find("50", 1, true) ~= nil, "message: percent fallback rounds to 50%")

    -- EPUB: percent + resolved chapter -> the human anchor is appended.
    local c = JumpToast.message({ remote_label = "Kobo", percent = 0.45, chapter = "Chapter 7" })
    h.assert_true(c:find("45", 1, true) ~= nil, "message: percent shown with chapter")
    h.assert_true(c:find("Chapter 7", 1, true) ~= nil, "message: resolved chapter appended")

    -- An empty/missing chapter degrades to percent-only (no dangling separator).
    local ce = JumpToast.message({ remote_label = "Kobo", percent = 0.45, chapter = "" })
    h.assert_true(ce:find("45", 1, true) ~= nil, "message: empty chapter -> percent only")
    h.assert_true(ce:find("Chapter", 1, true) == nil, "message: empty chapter is not shown")

    -- The page form is reserved for paging docs (fixed pages); when both a page
    -- and a percent are present, percent wins (the caller only passes page for
    -- PDFs, where it does NOT also pass percent -- this guards that ordering).
    local pp = JumpToast.message({ remote_label = "Kobo", percent = 0.45, page = 999 })
    h.assert_true(pp:find("45", 1, true) ~= nil and pp:find("999", 1, true) == nil,
        "message: percent takes precedence over page (page is PDF-only, never with percent)")

    local n = JumpToast.message({})
    h.assert_true(type(n) == "string" and #n > 0, "message: default label, no page/percent")
    h.assert_true(n:find("Another device", 1, true) ~= nil,
        "message: defaults the label to 'Another device'")

    h.assert_equal(JumpToast.actionLabel(), "Jump", "actionLabel is 'Jump'")
end


-- --- main.lua wiring + dead-code audit ---------------------------------------
do
    local f = io.open("main.lua", "r") or io.open("../main.lua", "r")
    h.assert_true(f ~= nil, "audit: could open main.lua")
    local src = f and f:read("*a") or ""
    if f then f:close() end

    -- The jump invite and the post-jump [Undo] confirmations are raised through
    -- the NON-BLOCKING bottom action bar (ActionBar.show -- a ReaderView view
    -- module + a button touch zone), NOT a toast/window, so the reader keeps
    -- paging. The new-annotation / new-render "[Reload]" affordance ALSO goes
    -- through ActionBar.show, but on LANE 1: the action bar stacks two
    -- INDEPENDENT lanes -- the jump/undo bar in lane 0 (bottom) and the reload in
    -- lane 1 (above it) -- so both are visible AT THE SAME TIME (position and
    -- content are independent axes; no queuing/sequencing). Four .show sites in
    -- main.lua: invite + the two undo bars (lane 0) + the reload (lane 1). The
    -- manual-jump bar lives in status_ui, audited there.
    h.assert_true(src:find('require("syncery_ui/action_bar")', 1, true) ~= nil,
        "wiring: the action bar module is required")
    local show_count = select(2, src:gsub("ActionBar%.show%(", ""))
    h.assert_equal(show_count, 4,
        "wiring: invite + 2 undo (lane 0) + reload (lane 1) all go through ActionBar.show (4 sites)")
    local defer_count = select(2, src:gsub("ActionBar%.defer%(", ""))
    h.assert_equal(defer_count, 0,
        "wiring: no ActionBar.defer -- the reload no longer queues, it shows on its own lane")
    -- The reload offer is on lane 1, so it stacks above (not preempts) the jump
    -- bar: exactly one `lane = 1` in main.lua, and it is the reload's show.
    local lane1_count = select(2, src:gsub("lane = 1", ""))
    h.assert_equal(lane1_count, 1,
        "wiring: the reload bar is shown on lane 1 (stacks above the lane-0 jump bar)")

    -- REGRESSION (the jump-vs-reload pre-emption bug): a shown jump bar must NOT
    -- silently DROP the pending reload. Previously checkRemote did
    --   if jump_shown then self._pending_ann_reload = nil; ... else offer end
    -- so a device reading on the SAME open re-fired the jump every checkRemote
    -- tick and re-dropped the reload -- the "N new annotations -- reload" bar
    -- never appeared in-session, and the receiving side re-pulled the same
    -- annotations on every close (the live ui.annotation list, which Syncery
    -- never mutates, was never refreshed). The fix offers the reload regardless
    -- of the jump (its OWN lane), so the old "jump bar IS up ... drop" branch is
    -- gone.
    h.assert_true(src:find("jump bar IS up", 1, true) == nil,
        "regression: jump no longer drops the pending reload (own lane instead)")

    -- The action bar stacks two independent lanes: per-lane view-module / touch-
    -- zone identity (view_key), M.show places the bar on spec.lane and preempts
    -- only the SAME lane, and M.dismiss tears down EVERY lane on document leave.
    do
        local af = io.open("syncery_ui/action_bar.lua", "r")
            or io.open("../syncery_ui/action_bar.lua", "r")
        h.assert_true(af ~= nil, "audit: could open action_bar.lua")
        local asrc = af and af:read("*a") or ""
        if af then af:close() end
        h.assert_true(asrc:find("function view_key(lane)", 1, true) ~= nil,
            "wiring: action_bar keys view modules per lane (view_key)")
        h.assert_true(asrc:find("local lane = spec.lane or 0", 1, true) ~= nil,
            "wiring: M.show places the bar on spec.lane")
        h.assert_true(asrc:find("for lane = 0, LANE_COUNT - 1 do", 1, true) ~= nil,
            "wiring: M.dismiss tears down EVERY lane on document leave")
        h.assert_true(asrc:find("function M.defer", 1, true) == nil,
            "wiring: M.defer is gone (independent lanes replace the queue/drain)")
    end
    -- Reload affordance: when checkRemote applies changes that are only visible
    -- at the next open (annotations -- live list not mutated mid-session; AND
    -- font & layout -- copt_* written but not re-rendered) and no position jump
    -- pre-empts, _maybeOfferReload shows a [Reload] bar that triggers
    -- ReaderUI:reloadDocument (its close stages both; the reopen loads them).
    -- Metadata is NOT here -- it applies live and needs no reload.
    h.assert_true(src:find("_maybeOfferReload", 1, true) ~= nil,
        "wiring: the reload offer helper exists")
    h.assert_true(src:find("self.ui:reloadDocument()", 1, true) ~= nil,
        "wiring: the [Reload] button triggers ReaderUI:reloadDocument")
    h.assert_true(src:find("self._pending_ann_reload = result.annotations_pulled", 1, true) ~= nil,
        "wiring: a remote annotation pull arms the reload offer (annotations_pulled)")
    -- Font & layout (render) changes arm the SAME affordance -- they too are only
    -- visible at the next open, so they share the [Reload] bar.
    h.assert_true(src:find("self._pending_render_reload = true", 1, true) ~= nil,
        "wiring: an applied render change arms the reload offer (render_applied)")
    -- The bar text names exactly which section(s) changed: annotations-only
    -- (plural-counted), render-only, or both.
    h.assert_true(src:find("%d new annotation from another device", 1, true) ~= nil,
        "text: annotations-only reload message (plural-counted)")
    h.assert_true(src:find("New font & layout from another device", 1, true) ~= nil,
        "text: render-only reload message")
    h.assert_true(src:find("New annotations and font & layout from another device", 1, true) ~= nil,
        "text: combined annotations + render reload message")
    -- The old notify-coordinator invite is gone (it was a blocking window).
    h.assert_nil(src:find("Notify.notifyInvite", 1, true),
        "dead code: the jump invite no longer uses the notify invite (now the action bar)")
    -- The ask-path jump confirms with the "Jumped to new position." bar.
    h.assert_true(src:find("Jumped to new position.", 1, true) ~= nil,
        "wiring: ask-path jump confirms via the action bar")

    -- The jump invite no longer shows the remote device's PAGE for reflowable
    -- books: that page is device-local (each device re-paginates for its own
    -- font/screen).  The ask path branches on the shared xpointer -- reflowable
    -- (xpath present) -> percent + the chapter resolved FROM that xpointer
    -- (_resolveChapter, via ui.toc:getTocTitleByPage which takes an xpointer
    -- directly); paging (PDF, no xpointer) -> the fixed page, which is the same
    -- across devices.  The old unconditional `page = opts.r_page` is gone.
    h.assert_true(src:find("function Syncery:_resolveChapter", 1, true) ~= nil,
        "wiring: the xpointer->chapter resolver helper exists")
    h.assert_true(src:find("getTocTitleByPage", 1, true) ~= nil,
        "wiring: chapter resolved via the in-memory TOC (getTocTitleByPage on the xpointer)")
    h.assert_true(src:find("jump_opts.chapter = self:_resolveChapter", 1, true) ~= nil,
        "wiring: the ask-path invite passes the resolved chapter (reflowable branch)")
    h.assert_true(src:find("jump_opts.page = opts.r_page", 1, true) ~= nil,
        "wiring: the paging (PDF) branch still shows the fixed page")
    h.assert_true(src:find("pcall(function() return ui.toc:getTocTitleByPage", 1, true) ~= nil,
        "wiring: chapter resolution is pcall-guarded (getTocTitleByPage crashes on non-string)")
    -- The post-jump undo window (pre_jump_until, set by _doJump) is 60 seconds.
    h.assert_true(src:find("pre_jump_until = os.time() + 60", 1, true) ~= nil,
        "wiring: the post-jump undo window is 60 seconds")
    -- jump_mode "never" suppresses the automatic prompt entirely.
    h.assert_true(src:find('self.jump_mode == "never"', 1, true) ~= nil,
        "wiring: _promptJump suppresses the prompt in 'never' mode")
    -- ...but "never" gates ONLY the position axis: the reload bar is a different
    -- axis and must still be offered when no jump bar competes.  checkRemote
    -- captures whether _promptJump actually raised a bar (true = ask/auto bar
    -- shown; false = "never" declined) and offers the reload on the declined
    -- path instead of dropping it -- so "never" cannot silently swallow incoming
    -- annotations / render until the next open.  That makes THREE no-jump-bar
    -- reload paths: `not best`, `not should_prompt`, and "never".
    h.assert_true(src:find("local jump_shown = self:_promptJump", 1, true) ~= nil,
        "wiring: checkRemote captures whether _promptJump raised a jump bar")
    local reload_calls = select(2, src:gsub("self:_maybeOfferReload%(%)", ""))
    h.assert_equal(reload_calls, 3,
        "wiring: reload offered at all three no-jump-bar paths (not best / not should_prompt / 'never')")
    -- jump_mode "auto" short-circuits straight to the jump.
    h.assert_true(src:find('self.jump_mode == "auto"', 1, true) ~= nil,
        "wiring: _promptJump auto-jumps in 'auto' mode")
    -- The blocking-modal message builder is long gone.
    h.assert_nil(src:find("function Syncery:_buildJumpMessage", 1, true),
        "dead code: _buildJumpMessage removed")
    h.assert_nil(src:find("Jump there?", 1, true),
        "dead code: the old modal 'Jump there?' message is gone")
    -- The superseded standalone show-controller is no longer wired.
    h.assert_nil(src:find("JumpToast.show", 1, true),
        "dead code: the standalone JumpToast.show wiring is gone (notify owns it)")
    h.assert_nil(src:find("JumpToastWidget", 1, true),
        "dead code: JumpToastWidget require/use removed (toast_widget supersedes it)")
end
