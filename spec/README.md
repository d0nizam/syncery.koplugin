# Test Suite

109 tests across 92 spec files. No KOReader installation required — all
platform modules are stubbed by the mock layer.

## Running

The suite ships a self-contained runner (`run_tests.lua`) that works under
LuaJIT without any extra dependencies:

```sh
luajit spec/run_tests.lua
```

To run a single spec:

```sh
luajit -e "dofile('spec/run_tests.lua')('spec/storage_mode_spec.lua')"
```

## Setup

### Windows (one-command)

```powershell
.\spec\setup_windows.ps1
```

This does everything automatically: installs MinGW-w64 (C compiler) via
winget, installs LuaRocks standalone (bundles LuaJIT), installs rocks
(`luafilesystem`, `lua-cjson`, `luajson`), runs tests.

The script is idempotent — subsequent runs are much faster because
already-installed components are skipped.

### Windows (manual)

```powershell
# 1. MinGW-w64 (UCRT) — C compiler for Lua rocks
winget install -e --id BrechtSanders.WinLibs.POSIX.UCRT --accept-package-agreements

# 2. LuaRocks — download luarocks-3.12.2-windows-64.zip from
#    https://luarocks.github.io/luarocks/releases/
#    Extract and add to PATH.

# 3. Dependencies
luarocks install luafilesystem
luarocks install lua-cjson
luarocks install luajson

# 4. Run tests
luajit spec/run_tests.lua
```

Notes:
- `luasocket` is **not** needed — HTTP transport tests use injectable
  `request_fn` fakes. Compiling it is blocked by CRTC incompatibility
  between GCC 16+ and LuaJIT on Windows.
- `rapidjson` is **not** needed — `lua-cjson` is used as the JSON library.
- `lpeg` is auto-installed as a dependency of `luajson`.

Without `winget`:
- Install MinGW-w64 manually from [winlibs.com](https://winlibs.com/)
  (UCRT variant, extract, add `mingw64\bin` to PATH), then follow steps 2-4.

### Linux (WSL / native)

```sh
sudo apt update
sudo apt install luajit luarocks
sudo luarocks install luafilesystem
sudo luarocks install lua-cjson
sudo luarocks install luajson
luajit spec/run_tests.lua
```

### Expected output

```
Done: 109 spec(s) passed, 0 failed
```

## Spec files

| File | What it covers | Tests |
|------|---------------|-------|
| `annotation_state_store_device_agnostic_spec` | State-store JSON read/write round-trips with device-agnostic annotation keys | 11 |
| `booklist_actions_spec` | Book-list action dispatching, filtering, selection | 23 |
| `booklist_init_spec` | Book-list initialisation and empty-state handling | 9 |
| `booklist_scan_spec` | Book-list filesystem scan: directory traversal, metadata extraction, error paths | 49 |
| `bridge_spec` | DocSettings ↔ syncery bridge: read active document, refresh triggers, metadata extraction | 118 |
| `bulk_ingest_spec` | Bulk ingestion of annotation/progress records | 43 |
| `cloud_adapter_internals_spec` | Cloud adapter internal routing, state management | 20 |
| `cloud_annotation_merge_callback_spec` | Cloud sync annotation merge callback contract | 41 |
| `cloud_progress_merge_callback_spec` | Cloud sync progress merge callback contract | 46 |
| `cloud_providers_spec` | Cloud provider enumeration, credential storage | 33 |
| `cloud_quiet_toast_spec` | Cloud quiet-mode toast suppression | 13 |
| `cloud_staging_spec` | Cloud staging area: pending changes, conflict detection | 19 |
| `cloud_sync_service_adapter_spec` | Cloud sync service adapter: init, sync, error handling | 23 |
| `cloud_then_syncthing_chained_merge_spec` | Chained merge: cloud then Syncthing pipeline | 25 |
| `cloud_transport_spec` | Cloud HTTP transport: request/response cycle, error classification | 78 |
| `cloudstorage_provider_spec` | Cloud storage provider: file listing, upload/download | 54 |
| `collect_foreign_devices_spec` | Foreign device collection from Syncthing config | 16 |
| `conflict_resolver_spec` | Annotation conflict resolution strategies | 28 |
| `consent_first_defaults_spec` | First-run consent defaults and wizard state | 8 |
| `diagnostic_snapshot_spec` | Diagnostic snapshot capture and formatting | 75 |
| `dispatcher_actions_spec` | Event dispatcher action routing | 17 |
| `doc_settings_bridge_read_active_spec` | Read-active detection through DocSettings bridge | 11 |
| `doc_settings_refresh_spec` | DocSettings change detection and refresh triggers | 44 |
| `firstrun_wizard_presenter_spec` | First-run wizard: presenter logic, page navigation | 94 |
| `firstrun_wizard_spec` | First-run wizard: full lifecycle, consent flow | 149 |
| `folder_discovery_spec` | Sync folder discovery from filesystem | 46 |
| `hash_location_finder_spec` | Hash-based storage location discovery | 31 |
| `identity_spec` | Device identity generation and persistence | 32 |
| `json_store_android_spec` | JSON store: Android-specific path handling | 24 |
| `json_store_skip_unchanged_spec` | JSON store: skip-write optimisation for unchanged data | 16 |
| `json_store_sort_keys_spec` | JSON store: deterministic key sorting | 3 |
| `jump_policy_spec` | Jump-to-location policy and bookmark resolution | 41 |
| `jump_toast_spec` | Jump invite message (percent + resolved chapter / fixed page) + main.lua wiring audit | 45 |
| `kosyncthing_plus_api_client_spec` | KOSync+ API client: request signing, response parsing | 23 |
| `kosyncthing_plus_provider_spec` | KOSync+ provider: account linking, sync orchestration | 39 |
| `lifecycle_init_spec` | Plugin lifecycle: initialisation sequence | 63 |
| `lifecycle_teardown_spec` | Plugin lifecycle: teardown and cleanup | 63 |
| `lifecycle_timers_spec` | Plugin lifecycle: periodic timer scheduling and cancellation | 55 |
| `local_url_spec` | Local URL construction and scheme handling | 10 |
| `materialized_last_sync_spec` | Materialised last-sync timestamp persistence | 15 |
| `menu_advanced_section_spec` | Advanced settings menu section | 21 |
| `menu_annotations_section_spec` | Annotation settings menu section | 72 |
| `menu_helpers_parity_spec` | Menu helper parity between UI and test stubs | 23 |
| `menu_helpers_spec` | Menu helper functions: option building, callback wiring | 36 |
| `menu_init_spec` | Menu initialisation and submenu registration | 37 |
| `menu_maintenance_section_spec` | Maintenance menu section | 60 |
| `menu_per_book_section_spec` | Per-book settings menu section | 28 |
| `menu_status_parity_spec` | Status menu parity between UI and test stubs | 14 |
| `menu_status_section_spec` | Sync status menu section | 45 |
| `menu_transport_section_spec` | Transport configuration menu section | 102 |
| `merge_no_overlap_collapse_spec` | Merge: non-overlapping annotation collapse | 20 |
| `merge_spec` | Core annotation merge logic | 36 |
| `metadata_bridge_spec` | Metadata bridge: KOReader ↔ syncery fields | 84 |
| `metadata_custom_props_spec` | Custom property metadata extraction and mapping | 47 |
| `migration_all_books_e2e_spec` | End-to-end migration: all books path | 7 |
| `migration_already_home_spec` | Migration: already-at-home detection | 11 |
| `migration_matrix_spec` | Migration matrix: cross-version compatibility | 168 |
| `migration_scattered_hook_spec` | Migration: scattered data with hook-based detection | 10 |
| `migration_scattered_ui_spec` | Migration: scattered data with UI notification | 14 |
| `migration_storage_mode_spec` | Migration: storage-mode transition | 59 |
| `move_file_size_verify_spec` | File move: size verification after copy | 8 |
| `move_file_spec` | Atomic file move operations | 16 |
| `mtime_gate_spec` | mtime-based gate: skip unchanged files | 19 |
| `notify_spec` | Notification dispatching: toast, banner, log | 48 |
| `orphan_adapters_assembly_spec` | Orphan adapter assembly and registration | 17 |
| `orphan_adapters_jsons_spec` | Orphan adapter JSON format handling | 19 |
| `orphan_adapters_present_spec` | Orphan adapter presentation logic | 23 |
| `orphan_adapters_resolve_spec` | Orphan adapter resolution strategies | 19 |
| `orphan_cleanup_names_spec` | Orphan cleanup: filename-based detection | 9 |
| `orphan_cleanup_spec` | Orphan cleanup: full lifecycle | 96 |
| `paths_spec` | Path construction, normalisation, validation | 48 |
| `progress_aggregate_spec` | Progress Browser per-book aggregate (KOReader-recency): behind/even/neutral state, most-recent marker (by timestamp, not max %), freshness exclusion + fallback, epsilon honoured | 35 |
| `progress_bridge_spec` | Progress bridge: KOReader ↔ syncery | 51 |
| `progress_conflict_resolver_spec` | Progress conflict resolution + `merged_view` read-only fold + `resolve_all_at_path` destructive merge+delete | 49 |
| `progress_jump_targets_spec` | Per-device jump-button selection (which devices get a button, when the most-recent button shows) | 17 |
| `progress_enum_spec` | Progress Browser book enumeration: root set + progress-only dedup (annotations-only dropped, progress_path kept) | 9 |
| `progress_load_shared_from_path_spec` | Progress state-store explicit-path reader (the Progress Browser's loader) + load_shared delegation contract | 10 |
| `progress_merge_spec` | Core progress merge logic | 51 |
| `progress_orchestrator_spec` | Progress orchestration and scheduling | 66 |
| `progress_paths_spec` | Progress path construction and discovery | 25 |
| `progress_state_store_device_agnostic_spec` | State-store JSON read/write round-trips with device-agnostic progress keys | 9 |
| `render_settings_bridge_spec` | Render settings bridge: KOReader ↔ syncery | 54 |
| `reset_completeness_spec` | Reset completeness: force re-sync on reset | 10 |
| `scan_target_spec` | Scan target: directory-level sync triggers | 22 |
| `scattered_metadata_spec` | Scattered metadata collection and aggregation | 27 |
| `sdr_doc_json_creation_spec` | SDR doc JSON creation and validation | 18 |
| `status_lattice_spec` | Status lattice: state transitions and propagation | 73 |
| `status_panel_spec` | Status panel UI construction | 52 |
| `status_section_spec` | Status section rendering | 28 |
| `status_ui_spec` | Status UI update cycle | 36 |
| `stignore_spec` | `.stignore` file management and pattern handling | 64 |
| `storage_mode_spec` | Storage mode selection and persistence | 27 |
| `strip_book_extension_spec` | Book extension stripping from paths | 15 |
| `sync_journal_panel_spec` | Sync journal browser panel UI | 79 |
| `sync_journal_spec` | Sync journal read/write and query | 58 |
| `sync_orchestrator_spec` | Top-level sync orchestration | 53 |
| `syncery_settings_spec` | Settings registry and persistence | 67 |
| `syncthing_config_xml_provider_spec` | Syncthing config.xml provider: parsing, folder discovery | 24 |
| `syncthing_connection_probe_spec` | Syncthing connection probe and health check | 15 |
| `syncthing_manual_provider_spec` | Syncthing manual config provider | 19 |
| `syncthing_providers_spec` | Syncthing provider enumeration and fallback | 20 |
| `syncthing_transport_spec` | Syncthing REST transport: request/response, error handling | 139 |
| `time_format_spec` | Time formatting: relative, absolute, duration | 24 |
| `tombstones_spec` | Tombstone records: creation, expiry, cleanup | 51 |
| `transport_contract_spec` | Transport contract: interface conformance | 70 |
| `transport_http_client_spec` | HTTP client: request lifecycle, sink capture, error classification, timeout | 85 |
| `transport_orchestrator_spec` | Transport orchestration and retry | 75 |
| `transport_plugin_sync_spec` | Transport plugin sync: full pipeline | 14 |
| `transport_policy_spec` | Transport policy: selection, ordering, fallback | 56 |
| `transport_safe_callback_spec` | Safe callback: error-bound async callback | 25 |
| `transports_factory_spec` | Transport factory: provider↔transport wiring | 21 |
| `trash_spec` | Trash management: move, restore, expire | 29 |
| `wifi_backoff_spec` | Wi-Fi backoff: exponential backoff, cooldown, reset | 32 |
| **Total** | | **109** |

## Infrastructure

| File | Role |
|------|------|
| `run_tests.lua` | Self-contained runner; works under LuaJIT without luarocks. Patches `os.execute`/`io.open` on Windows for cross-platform `mkdir -p`/`rm -rf` compatibility |
| `test_helpers/init.lua` | Stubs `UIManager`, `NetworkMgr`, `Device`, `G_reader_settings`, `DataStorage`, all widgets, `util`, `ffi/util`, `libs/libkoreader-lfs`, `ffi/sha2`, `logger`, `docsettings`, `ui/uimanager`, `device`, `screen`, `input`, `event`, and JSON (rapidjson or cjson) |
| `test_helpers/ko_lib_stubs.lua` | KOReader stub modules: `ui/widget/`, `ui/data/`, `document/`, `apps/`, `frontend/` |
| `test_helpers/menu_test_support.lua` | Menu test support: fake menu construction, callback capture |

### Design rules

- Each spec file is **self-contained**: it calls `h.setup(test_root)` which
  installs only the mock surface it actually needs. Accidental dependencies
  on unrelated globals remain visible as immediate errors rather than silent
  passes.
- `test_helpers/init.lua` provides the shared baseline. Specs that need
  narrower or conflicting behaviour override individual `package.loaded`
  entries before calling `require()`.
- The JSON library is resolved at test-root creation time: `rapidjson` is
  preferred, `cjson` is used as a fallback, and a pure-Lua fallback can be
  added at `load_minimal_json()` in `init.lua`.
- No network access, no real filesystem side-effects outside `test_root`,
  no real processes are started. All KOReader external interfaces
  (`Device`, `UIManager`, `NetworkMgr`) are stubs with controllable state.
- Windows compatibility is maintained entirely in `run_tests.lua` (the
  `os.execute`/`io.open` patch layer) and `test_helpers/init.lua`
  (cross-platform `mkdir -p`/`rm -rf`). Production code is never patched
  for platform differences.
- `luasocket` is not a test dependency. The HTTP transport layer uses
  injectable `request_fn` fakes for all specs; production `socket.http`
  code paths are exercised only when explicitly requested.
