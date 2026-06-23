# syncery_transports/

The transport layer.  Moves bytes between this device and other devices
or servers.

Built in Phase 5 of the Syncery rewrite.  Replaces:

| Legacy file                  | Status              |
|------------------------------|---------------------|
| `syncery_syncthing.lua`      | deleted             |
| `syncery_fork_api.lua`       | deleted             |
| `syncery_kosync.lua`         | deleted             |
| `syncery_cloud.lua`          | deleted             |
| `_doTriggerScan` in main.lua | will be deleted     |
| `_kosyncPushIfDue` ditto     | will be deleted     |
| `_scheduleCloudUpload` ditto | will be deleted     |

See `PROJECT_PLAN.md` (sibling document) for the larger project context.

## Subsystem layout

```
syncery_transports/
├── README.md                       ← you are here
├── init.lua                        ← one-call factory for the full stack
├── interface.lua                   ← contract every transport satisfies
├── orchestrator.lua                ← owns the transport list; push/pull/
│                                     status fan out from here
├── bridge.lua                      ← main.lua-facing facade over the
│                                     orchestrator (UI asks, bridge answers)
├── policy.lua                      ← retry/backoff decisions per transport
├── safe_callback.lua               ← exactly-once callback wrapper
├── plugin_sync.lua                 ← plugin-facing cloud upload/schedule glue
├── http_client.lua                 ← raw Syncthing REST client +
│                                     reachability cache
├── log.lua                         ← transport-layer logging shim
├── stignore.lua                    ← non-blocking writer for Syncthing's
│                                     .stignore (conflict-copy suppression;
│                                     local file, no network — see below)
│
├── syncthing/                      ← peer-to-peer file replication
│   ├── transport.lua               ←   Transport interface implementation
│   ├── local_url.lua               ←   loopback base-URL builder
│   ├── folder_discovery.lua        ←   folder-list parse + live-state enrich
│   ├── kosyncthing_plus_api_client.lua ← KOSyncthing+ apiCall → callback shape
│   └── providers/
│       ├── init.lua                ←   picks the best available provider
│       ├── kosyncthing_plus_provider.lua ← discovery via the KOSyncthing+ plugin
│       └── manual_provider.lua     ←   user-entered URL + API key
│
└── cloud/                          ← Dropbox / WebDAV / FTP via Cloud storage+
    ├── transport.lua
    ├── sync_service_adapter.lua    ←   KOReader SyncService adapter
    ├── staging.lua                 ←   per-book upload staging dir
    ├── quiet_toast.lua             ←   toast suppression helper
    └── providers/
        ├── init.lua
        ├── interface.lua
        ├── cloudstorage_provider.lua
        └── syncservice_provider.lua
```

## Design notes

### Why a provider layer under `syncthing/` but not under `kosync/` or `cloud/`

Syncthing is the only transport that has multiple ways to be reached:

1. **Via the KOSyncthing+ plugin** (`kosyncthing_plus.koplugin`) — its public API exposes the daemon's
   URL and API key without parsing config files, and offers bonus
   capabilities (event subscription, IgnoreRegistry, metadata-aware
   conflict records).

2. **Via a manually-configured URL + API key** — user runs Syncthing
   themselves (Termux, SSH, desktop daemon) and enters the connection
   details in Syncery's settings.

3. **Via any future plugin or scheme** that wants to be a Syncthing
   provider (no examples today; the design supports adding them).

All three end up speaking the same Syncthing REST API.  The provider
layer is just a way to obtain `{url, api_key, folder_id, folders}` plus
optional bonus capabilities — every real data operation goes through
`http_client.lua`, which doesn't know or care which provider supplied
the config.

Kosync has exactly one way to be reached (the kosync server's REST API
with a username/password).  Cloud has exactly one backend — hius07's
"Cloud storage+" plugin (the canonical SyncService since koreader#9709) —
with KOReader's built-in syncservice as an automatic, invisible fallback
when the plugin is off.  No user selection, no provider auto-detection.

### Why `is_eventually_consistent` is part of the interface

Pretending push/pull have the same round-trip semantics across all
three transports would be a lie.  Syncthing's push is fire-and-forget:
we ask the daemon to scan a folder, the daemon eventually notices our
changes and eventually replicates them to peers.  The first peer
eventually applies them.  None of that is observable from the device
that pushed — there's no acknowledgment in the protocol.

Kosync and Cloud, by contrast, give us a real HTTP response code.
"Push returned 200" really means "the server has our bytes."

The contract spec and the status panel both branch on
`is_eventually_consistent()` so they don't make assumptions that hold
for two of the three transports but not the third.

### Why universal capabilities like `setFolderIgnore` live in `http_client.lua`

`setFolderIgnore` is a Syncthing REST endpoint
(`POST /rest/db/ignores`).  Any provider that has the URL and API key
can call it; there's no reason to gate it on "is KOSyncthing+ present".
It lives in `http_client.lua` and is exposed as a capability
(`supports("ignore_patterns")` returns true whenever the transport has
a working http_client).

KOSyncthing+'s own `setFolderIgnore` and the daemon's REST endpoint are
just two paths to the same thing — the KOSyncthing+ provider uses one,
manual_provider uses the other.  Above the provider layer, they look the same.

### Two ways to suppress conflict copies: the `.stignore` file vs REST

Syncery keeps Syncthing from replicating its own conflict copies
(`*syncery-*sync-conflict-*`) using two complementary mechanisms:

- **`.stignore` file (`stignore.lua`)** — the automatic path.  Writes the
  pattern into `.stignore` at the synced folder root, which the daemon
  reads on its next scan.  This is a LOCAL file write (no network), so it
  can never block the UI and works even when the daemon is unreachable.
  It rides `_doTriggerScan` (book activity), NOT startup — an earlier
  design fired the REST call synchronously at startup, which blocked the
  UI for several seconds against an unreachable daemon (the white-screen
  lag).  The write is idempotent and merge-safe (append-only; never
  rewrites the user's own patterns or `#include` lines), and silently
  does nothing when the folder root path isn't known.

- **REST `setFolderIgnore`** — the explicit "Conflict-file integration"
  button.  Registers the same pattern with the daemon directly, for an
  immediate effect when the daemon is reachable.  User-initiated, so the
  network latency is expected there.

Both are only an optimization over the real correctness mechanism: the
conflict resolver merges and removes conflict files locally on every
sync regardless.  Suppression just stops the copies from travelling
before that happens.

Both of the above suppress daemon REPLICATION and use the same literal
glob (`*syncery-*sync-conflict-*`, the `.stignore` `PATTERNS`).  A THIRD,
separate mechanism — the KOSyncthing+ `IgnoreRegistry` scanner
(`register_conflict_menu_ignore` → `register_conflict_scanner_ignore`) —
hides Syncery's conflict copies from the conflict *menu/badge* instead.
It registers a DIFFERENT glob, `*syncery-*` (`Stignore.CONFLICT_SCANNER_PATTERN`),
because that scanner de-mangles a conflict copy to its ORIGINAL basename
before matching, so a glob containing `sync-conflict-` could never match
there.  The two glob constants are deliberately distinct; see
`docs/SYNC_CONFLICT_STRATEGY.md` §2b.

### What the router does, briefly (sketched here, implemented later)

The router owns the registered list of transports.  On a sync event it
walks the list, asks each transport if it's available, and calls push
on the ones that are.  It aggregates per-transport status into the
overall status the UI shows.  Failed pushes are retried per transport
(each transport owns its own retry queue, sized for its protocol —
Syncthing wants exponential backoff because the daemon may be starting
up; Kosync wants a short timeout because the server is either there
or not; Cloud wants jitter because it talks to commercial services
that rate-limit).

## Testing

Two test patterns:

1. **Contract spec** (`spec/transport_contract_spec.lua`): asserts every
   transport satisfies `interface.lua`.  Uses `h.make_fake_transport()`
   to dogfood the contract — if the fake passes but a real transport
   fails the same scenarios, the bug is in the real transport.

2. **Per-transport specs**: unit tests for each transport's internal
   modules (http_client, policy, scanner).  These live in
   `spec/<transport>_<module>_spec.lua` and don't go through the
   interface — they exercise the implementation directly.
