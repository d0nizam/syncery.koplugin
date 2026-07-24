# Changelog

## [v1.2.3] — 2026-07-24

### Changed
- **The "point out this book" prompts now say *which* book they mean.**
  When migrating storage modes, Syncery picks the book it wants you to
  locate — so it now names it ("Can't find *Title*. Point it out…")
  instead of asking you to point out one of N unnamed books and leaving
  you to guess. The "that file doesn't match" message names the book too,
  in every place the picker is used, since by then you've been through a
  file browser and the title is no longer on screen. Where *you* picked
  the book a moment earlier (Progress Browser, Annotation Browser), the
  opening prompt is unchanged — repeating the title there would just be
  noise.

## [v1.2.2] — 2026-07-23

### Added
- **"Continue reading" in the Progress Browser.** Picking a book you don't
  currently have open now also offers to jump back to where *this* device
  itself last left off, alongside the existing per-device jumps. It covers
  the case where a book's local reading position was reset but its synced
  record wasn't — most often after deleting a book and downloading it again
  (reported in issue #16). Deliberately limited to books that aren't open:
  once a book is open, the live session overwrites that record, so there
  would be nothing left to return to.

## [v1.2.1] — 2026-07-21


### Added
- **Progress Browser and Annotation Browser now find books that exist on
  this device but weren't recognized.** Two related situations, both
  previously reported as errors or silently miscounted:
  - A book synced from another device, never opened here — you can now
    point Syncery at the file directly ("Point to it…"), verified by
    content match, not just filename.
  - A book that WAS opened elsewhere, but this device's recorded path for
    it doesn't resolve (moved, different platform, different folder
    layout) — same "Point to it…" flow, worded for that case
    specifically.
  - Once you locate a book this way, Syncery remembers the folder pattern
    (e.g. "Books/EN" → "Documents/Books/EN") and auto-resolves the next
    book from a sibling folder (e.g. "Books/BG") without asking again.
- **"Migrate all books to this storage mode…" now uses the same "Point to
  it…" flow** for books it can't find automatically, instead of just
  reporting them as "not on this device." Already-learned folder patterns
  from Progress/Annotation Browser are tried silently first.

## [v1.2.0] — 2026-07-17

### Added
- **Cloud prefetch.** Sync Now now discovers books your other devices have
  synced but you have never opened here, and stages their progress and
  annotations ahead of time. They show up immediately in the Progress
  Browser, Booklist, and Annotation Browser — the moment you actually open
  one, its synced state is already there, not fetched from scratch.
- **Cloud Sync-All.** *Sync Now* used to push/pull only the book you had
  open. It now covers your whole library in one pass — every book with a
  pending change goes out, and every book a peer changed comes in — using a
  lightweight per-device manifest so it doesn't have to check every book's
  full content to know what changed.
- **Open-moment pull + jump prompt.** Opening a book now checks the cloud
  right away (a few seconds after load) instead of waiting for the next
  save. If a peer left off further ahead, the jump prompt can appear on the
  very first check. (PR #12 by iav)
- **Deletion-aware reload prompts.** Deleting an annotation on one device
  now offers the same "tap to reload" invitation on others that a *new*
  annotation already did — previously, a deletion updated things silently
  and only became visible after you closed and reopened the book yourself.
  When both new and deleted annotations arrive together, the bar shows a
  compact `+N -M` count.
- **Verbose sync logging** (Advanced, under *Copy diagnostic info*, off by
  default). Writes detailed push/pull decisions, merge results, and
  jump/reload events to `debug.txt` in Syncery's settings folder, capped at
  roughly the last 1000 lines — for troubleshooting sync issues without
  digging through the full `crash.log`. Takes effect immediately, no
  restart needed.
- **Wake Wi-Fi for a cloud push on close** (opt-in). Optionally pushes your
  last reading position on suspend too, not just on close. (PR #7 by iav)
- **Custom Syncthing host.** The Syncthing GUI host was previously fixed to
  `127.0.0.1`; it's now configurable under *Transports → Configure
  Syncthing…*, for setups where the daemon isn't reachable on loopback.
- **Force terminal Syncthing scan past backoff at close/quit.** Ensures the
  last changes are picked up by Syncthing before shutdown, rather than
  being delayed by scan backoff. (PR #8 by iav)
- **Last-read time** now carries
  onto the book's `atime` on sync, instead of only the progress percentage
  moving. (PR #14 by iav)

### Fixed
- A same-page jump prompt (peer at the same position, no real progress
  difference) no longer appears — this previously caused a back-and-forth
  jump prompt oscillation between two devices reading in lockstep.
  (PR #12 by iav)
- Fixed a cloud sync race condition that could occur right at book open,
  and a related one in `pushOpenedBooks`' failure handling that could leave
  a book's push state inconsistent after a transient error.
- Fixed WebDAV folder-listing filtering so unsupported/system entries no
  longer interfere with book discovery.
- Fixed a bug where a book moved between storage locations could leave a
  stale cross-device reference behind.
- Fixed a cache-key bug where Syncery could silently skip pushing a
  genuinely changed book after an unrelated book's push, or — more
  seriously — could skip checking the cloud for a peer's update at all
  once its own content looked unchanged (only the book you had open was
  affected; the fix makes the skip opt-in, used only where it's actually
  safe).
- Fixed a false "font & layout changed" notification that could appear on
  the very first sync of a book between two devices with different
  default fonts, even when neither device had ever customized anything —
  the comparison now falls back to each device's own live rendering
  default instead of assuming a difference.
- Fixed the relative-time display in the jump/undo action bar and status
  section (e.g. "5 minutes ago" instead of a raw timestamp).

## [v1.1.2] — 2026-06-30

### Bugfix
- Annotation browser: focus indicator (blue border) no longer appears on touch-enabled devices. Regression in v1.1.1 - the D-pad focus navigation inadvertently drew a focus border on the first list item on all devices, not just non-touch ones. Now gated on hasDPad() and not isTouchDevice(), matching KOReader's FocusManager convention.

## [v1.1.1] — 2026-06-30

### Added
- Non-touch accessibility
  Action bars (jump/undo/reload): non-touch fallback - the bottom action bars now degrade to focusable ButtonDialogs on devices without touch (Device:hasKeys()),    with a single-slot FIFO queue for serialization. Touch & hybrid devices keep the non-blocking overlay bars. (PR #5)

- Annotation browser: full 5-way D-pad navigation - Up/Down moves focus between notes, Press opens the selected note, Menu opens the main menu (Filter/Sort/Settings). Focused note is highlighted with a blue border. Page nav (Left/Right) and Close (Back) unchanged.

- Progress & Annotation browsers are now bindable as Dispatcher actions (syncery_progress_browser, syncery_annotation_browser) - assign them to a gesture or   hardware key via the Gesture manager / Hotkeys plugin. (PR #5)

### Fixed
- Dispatcher registration fix
Dispatcher actions are now also registered from init(), not only from the one-shot DispatcherRegisterActions broadcast. Fixes a bug where Syncery actions never appeared in the Gesture manager / Hotkeys pickers when Syncery loaded after the broadcast had already fired. (PR #4)

## [v1.1.0] — 2026-06-26

### Added
- Reading Statistics and Vocabulary Builder now sync across your devices.
  Syncery syncs them periodically while you read (with a configurable interval
  and a master on/off switch), and can optionally point both KOReader plugins
  at Syncery's own cloud server so you set the cloud up once instead of in
  three separate places. When sync can't run because the cloud isn't
  configured, Syncery now tells you instead of failing silently.


### Fixed
- The first-run setup wizard is now fully usable on non-touch devices.
  (Reported as issue #1.)
- Clearing a book's star rating, summary note, collections, or custom
  title/author now syncs the removal to your other devices, instead of the old
  value reappearing from a device that still had it.

## [v1.0.0] — 2026-06-19

First public release. Syncery keeps your whole reading state in sync across
every device you read on — no account, and no central server unless you choose
to run one.

- **The full reading state, not just position.** Reading progress, highlights,
  notes, bookmarks, ratings, reading status, and book metadata all travel
  together.
- **Your choice of transport.** Syncthing for peer-to-peer sync with no server,
  or cloud storage — Dropbox, WebDAV, or FTP.
- **Plain JSON beside your books.** Everything is stored as readable JSON in each
  book's sidecar (or a content-hash folder that survives renames), so your data
  is never locked in.
- **Offline-safe merging.** Two devices edited while offline converge to the same
  result instead of overwriting each other; annotations and render settings
  merge the same way regardless of which device synced first.
- **Update from inside KOReader.** *Check for plugin updates* (below *Advanced*)
  fetches the latest release from GitHub, shows the notes, installs it in place,
  and restarts — no bundled certificate, and Android-safe.
