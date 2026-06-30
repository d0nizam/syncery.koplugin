# Changelog

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
