# Changelog

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
