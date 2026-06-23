# syncery_lifecycle

The lifecycle scaffolding for the Syncery KOReader plugin: KOReader event
handlers, debounced timers, and the central teardown sequence.

## Module map

| File          | What it does                                                                              |
|---------------|-------------------------------------------------------------------------------------------|
| `init.lua`    | `Lifecycle.new{plugin, ui_manager, util_now}` — the dispatcher object that main.lua holds |
| `timers.lua`  | `Timers` class: slot-keyed scheduling against UIManager, destroyed-skip, pcall isolation  |
| `teardown.lua`| `Teardown.flush(plugin, ui_manager, util_now, logger, opts)` — the central flush routine  |

## Event handler call shapes

KOReader emits five events that this module handles, plus the autosave
debounce that page/pos updates fire:

```
KOReader event              → Syncery method              → Lifecycle method        → Teardown opts
================================================================================================================
onCloseDocument             → Syncery:onCloseDocument()  → lc:on_close_document()  → { destroying = true }
onSuspend                   → Syncery:onSuspend()        → lc:on_suspend()         → {}
onResume                    → Syncery:onResume()         → lc:on_resume()          → (no teardown; bounded connectivity poll, then checkRemote re-check on wake)
onPowerOff                  → Syncery:onPowerOff()       → lc:on_power_off()       → { shutdown_queue=true }
onQuit                      → Syncery:onQuit()           → lc:on_quit()            → { destroying=true, shutdown_queue=true }
onFlushSettings             → Syncery:onFlushSettings()  → lc:on_flush_settings()  → (no teardown; fires _debouncedScan when doc open)
onPageUpdate / onPosUpdate  → Syncery:scheduleAutoSave() → lc:schedule_auto_save() → (arms _autosave_action via Timers)
```

## Autosave block model (B2)

`schedule_auto_save` suppresses a non-forced autosave when autosave is
"blocked". As of Phase 22 (B2) "blocked" is **two independent
mechanisms**, ORed together — both are also consulted by main.lua's
`_save` gate via `Syncery:_isAutosaveBlocked()`, so the readers can never
disagree:

- **`plugin.blocking_autosave`** (boolean) — an INDEFINITE block, held
  until explicitly cleared. Set by `cancelPendingSync` before a
  destructive reset, where the block must outlast any timer.
- **`plugin.blocking_autosave_until`** (epoch second) — a SELF-HEALING
  window, past which the block lapses on its own. Set by `_doJump` to
  suppress the ordinary debounced autosave from racing the jump's own
  position write. It replaced an indefinite boolean that relied on a
  scheduled recovery save to clear it — a clear that could be skipped
  (book closed within the window → `_save` early-returns before the
  clear) or never fire (the shared `_autosave_action` slot overwritten
  by another schedule), stranding autosave OFF for the whole session.
  A time-boxed window lapses regardless, and the failure direction is
  safe (autosave resuming a touch early just persists a valid position).

`schedule_auto_save` checks both at arm time AND re-checks both at fire
time (the window may be (re)opened by a jump between arm and fire),
using the injected `self._util_now` clock (production: `Util.now`,
scale-compatible with the `os.time()` `_doJump` writes).


`shutdown_queue` is a legacy compat opt accepted unconditionally but
treated as a no-op under the Phase-5 transport stack (there's no
RetryQueue to shut down).

## Teardown step sequence

`Teardown.flush` runs these five steps in order, and each can be
short-circuited by toggles:

1. **Persist progress JSON** — `plugin:_writeSave(state, now, true)`.
   Always safe; runs whenever a document is open.

2. **Flush annotations/bookmarks back to doc_settings** — gated on
   `plugin._back_sync_completed`. Routes to either
   `plugin:_syncBookViaOrchestrator(state)` (new engine) or
   `plugin:syncBookmarks() + plugin:syncAnnotations()` (legacy engine).

3. **Opportunistic auxiliary pushes** — kosync push gated on
   `plugin.use_kosync`, cloud upload gated on `plugin.use_cloud`. The
   kosync gate zeros `plugin.kosync_last_push_at` first so the 15-second
   per-push debounce doesn't eat the critical "last save" push.

4. **Deferred Syncthing scan trigger** — `ui_manager:nextTick(...)` so
   Step 1's bytes are visible to the OS before the scan walks the
   directory. The deferred callback gates on `plugin:_isFileTypeSynced`
   AND `plugin.use_syncthing`; pcall-wrapped so a scan failure doesn't
   propagate.

5. **Tidy** — `opts.destroying` sets `plugin.destroyed = true` and
   pcall-shuts-down `plugin._transport`. Either way,
   `plugin._lifecycle.timers:cancel_all()`.

## Why some things are not here

The prompt suggested extracting `onReaderReady` and a `state.lua`
helper. Both were intentionally left in `main.lua`:

- **`onReaderReady`** is 130 lines and tightly bound to annotation /
  progress / storage_mode / migration concerns. Five of its six
  logical phases are not lifecycle work. Moving it would mean dragging
  `_getLocalAnnotations`, `_buildAnnSnapshot`, `_gcTombstones`,
  `_migrateBookFiles`, and `_loadFirstrunFlag` along — far outside
  Phase 3's scope. The three timer-scheduling calls inside it already
  route through `Syncery:_schedule` (which delegates to `lc:schedule`).

- **`state.lua`** (a separate getter/setter module for `destroyed`,
  `is_saving`, `sync_state`) would have forced edits at ~30 call sites
  across `main.lua`. The flags continue to live on `self`; the
  lifecycle modules read/write them through the injected `plugin` ref.
  Future phases (when `is_saving` and `sync_state` become bound to
  the save / sync orchestrators they describe) can revisit this.

## Test surface

Three specs cover the modules independently:

- `spec/lifecycle_timers_spec.lua` — slot scheduling, re-arm cancels
  prior arm, destroyed-skip, pcall isolation, cancel_all idempotency,
  static SLOTS list integrity.
- `spec/lifecycle_teardown_spec.lua` — step-by-step gating on each
  toggle (`use_kosync`, `use_cloud`, `use_syncthing`, `use_new_sync_engine`,
  `_back_sync_completed`), no-state branch, destroying side effects,
  pcall around `transport:shutdown` and `_doTriggerScan`, legacy compat
  opts produce identical call sequence.
- `spec/lifecycle_init_spec.lua` — dispatcher constructor validation,
  on_* methods route to the right teardown opts, schedule_auto_save
  honours destroyed/blocking_autosave/sync_state AND the self-healing
  `blocking_autosave_until` window (open at arm, lapsed at arm, opened
  between arm and fire, lapsed between arm and fire), schedule/cancel/
  cancel_all_timers passthroughs reach the underlying Timers.

All three use ad-hoc inline fakes for UIManager and the plugin object
rather than reaching for a shared helper, matching the style of the
existing transport specs.
