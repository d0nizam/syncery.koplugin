<div align="center">

# Syncery — Setup &amp; Sync Guide

*Get your KOReader devices syncing, step by step.*

</div>

This is a **task-oriented walkthrough**: how to get Syncery running across two
or more devices from scratch, including the part most guides skip — setting up
the **transport** (Syncthing or cloud) underneath it.

For the full feature/menu/settings reference, see [README.md](README.md).

---

## Contents

- [How Syncery syncs (in one minute)](#how-syncery-syncs-in-one-minute)
- [Quick start](#quick-start)
- [Step 1 — Install Syncery on every device](#step-1--install-syncery-on-every-device)
- [Step 2 — Choose a transport](#step-2--choose-a-transport)
- [Path A — Sync with Syncthing](#path-a--sync-with-syncthing)
- [Path B — Sync with cloud storage](#path-b--sync-with-cloud-storage)
- [Step 3 — Run the setup wizard](#step-3--run-the-setup-wizard)
- [Step 4 — Make both devices agree (storage mode)](#step-4--make-both-devices-agree-storage-mode)
- [Step 5 — First sync, and how to verify it](#step-5--first-sync-and-how-to-verify-it)
- [Exporting your highlights](#exporting-your-highlights)
- [Troubleshooting](#troubleshooting)

---

## How Syncery syncs (in one minute)

Syncery doesn't talk to a server of its own and has no account. Instead:

1. On each device it writes small **plain-JSON files** next to your reading data
   (progress, highlights, notes, bookmarks, metadata, render settings).
2. A **transport** you choose — **Syncthing** (peer-to-peer) or **cloud
   storage** (Dropbox / WebDAV / FTP) — replicates those JSON files between
   devices.
3. When the files arrive, Syncery **merges** them into KOReader's own data with
   a 3-way merge, so concurrent edits on different devices combine instead of
   overwriting each other.

So setting Syncery up is really two jobs: **(a)** get a transport moving files
between your devices, and **(b)** point Syncery at it. This guide does both.

> **Note.** Syncery and the transport are separate. If sync ever looks stuck,
> the first question is always *"are the files actually moving?"* — check the
> transport (Syncthing's web GUI, or your cloud folder) before suspecting
> Syncery.

---

## Quick start

If you already know your way around Syncthing or a WebDAV/cloud server, this is
the whole thing:

1. **Pick a transport** and get it replicating one folder between your devices
   (see [Step 2](#step-2--choose-a-transport)).
2. **Install Syncery** on every device (`*.koplugin` into `plugins/`, restart
   KOReader).
3. **Run the wizard** (it pops up on first launch): pick the transport, turn on
   what you want to sync, name the device.
4. **Set the same storage mode on every device** so the same book lines up
   everywhere (see [Step 4](#step-4--make-both-devices-agree-storage-mode)).

The rest of this guide expands each step.

---

## Step 1 — Install Syncery on every device

Syncery is a normal KOReader plugin. On **each** device:

1. Download the latest `syncery.koplugin.zip` from the
   [Releases](../../releases) page.
2. Unzip it into your KOReader `plugins/` directory, so you end up with a
   folder named exactly `syncery.koplugin` containing `main.lua`, `_meta.lua`,
   and the rest.
3. Restart KOReader.

Syncery then lives under **`☰` → Tools → Syncery**. See
[README → Installation](README.md#installation) for per-device paths
(Kindle / Kobo / Android) and updating.

> **Tip.** Install it everywhere *first*, then configure. The wizard saves your
> data locally even before a transport is set up, so nothing is lost while you
> get the other devices ready.

---

## Step 2 — Choose a transport

| | **Syncthing** | **Cloud storage** |
|---|---|---|
| **How it works** | Peer-to-peer; devices sync directly | Each device uploads/downloads via a provider |
| **Third party** | None — your files never leave your devices | A cloud account or a server you run |
| **Consistency** | Eventually consistent (fire-and-forget) | Immediately consistent (real HTTP response) |
| **Needs** | Syncthing running on each device + a shared folder | A reachable Dropbox / WebDAV / FTP destination |
| **Best when** | You want fully self-hosted, no accounts | You already use a cloud, or want a simple always-reachable target |
| **Setup** | [Path A](#path-a--sync-with-syncthing) | [Path B](#path-b--sync-with-cloud-storage) |

You only need **one**. Pick the path that matches your situation and skip the
other.

---

## Path A — Sync with Syncthing

[Syncthing](https://syncthing.net) is free, open-source, peer-to-peer file
sync. Your devices form direct, encrypted connections — nothing is stored on
anyone else's server. It's the most private option, and the one Syncery was
built around.

### What you need

- Syncthing **running on every device** (including each e-reader).
- One **shared folder** that all those devices replicate.
- Syncery **pointed at that folder** on each device.

The tricky part is the first one, because *how* you run Syncthing differs by
device. The easiest route is the companion plugin below.

### Easiest route — KOSyncthing+

[**KOSyncthing+**](https://github.com/d0nizam/kosyncthing_plus.koplugin) is a
companion KOReader plugin that runs and controls Syncthing from inside
KOReader. It handles the device-specific awkwardness for you and lets Syncery
discover the connection automatically (no API key to copy, no folder to
hand-pick). Install it like any plugin.

What it does depends on the device:

- **Kobo / Kindle** — KOSyncthing+ **owns a native Syncthing daemon**. On first
  run it offers to download the right Syncthing binary, then starts, stops, and
  syncs it for you. On these devices, installing KOSyncthing+ *is* how you get
  Syncthing running — there's nothing else to install.
- **Android e-readers** (Boox, etc.) — KOReader is itself an Android app, so
  Syncthing runs as a **separate Android app**. Install one of:
  [**Syncthing-Fork**](https://f-droid.org/packages/com.github.catfriend1.syncthingfork/)
  (Catfriend1 — the widely used one, on F-Droid and Google Play) or
  **BasicSync** (a lighter alternative). KOSyncthing+ then runs in *remote
  mode*: it bridges to that app and exposes it to Syncery. (On Android, starting
  and stopping the daemon is the Syncthing app's job, not KOSyncthing+'s.)

> **Tip.** On Android you can also skip KOSyncthing+ entirely. If you've
> installed Syncthing-Fork or BasicSync, just point Syncery at it directly with
> the **manual route** below — KOSyncthing+ mainly buys you auto-discovery and a
> conflict badge.

### Manual route — run Syncthing yourself

If you don't use KOSyncthing+, run Syncthing however you like and give Syncery
the connection details by hand:

- On a **computer / NAS / Raspberry Pi**: install Syncthing from
  [syncthing.net](https://syncthing.net/downloads/) and run it normally.
- On **Kobo / Kindle**: use a community plugin that bundles the Syncthing binary
  (for example
  [arthurrump/syncthing.koplugin](https://github.com/arthurrump/syncthing.koplugin)
  or [jasonchoimtt/koreader-syncthing](https://github.com/jasonchoimtt/koreader-syncthing)).
  These drop a Syncthing binary into a plugin folder and expose its web GUI at
  `https://127.0.0.1:8384`.
- On **Android**: use Syncthing-Fork or BasicSync (above).

You'll then enter that daemon's URL and API key into Syncery (see *Point Syncery
at the folder*).

### Pair your devices and share one folder

This part is plain Syncthing and is the same on every platform. Syncthing's own
[Getting Started](https://docs.syncthing.net/intro/getting-started.html) guide
covers it in full; the short version:

1. Open each device's Syncthing **web GUI** (`https://127.0.0.1:8384` on a
   computer/e-reader, or the app's UI on Android).
2. Find each device's **Device ID** under **Actions → Show ID** (a long
   `XXXXXXX-XXXXXXX-…` string, also shown as a QR code).
3. On **both** devices, click **Add Remote Device** and enter the *other*
   device's ID. After a minute they'll connect. (Repeat for every pair of
   devices.)
4. On one device, **Add Folder** (or share an existing one), open its
   **Sharing** tab, and tick the other device(s). On the other device, accept
   the folder when the prompt appears. Put the folder somewhere under your
   user storage (on Kobo, under `/mnt/onboard`).

After this you have **one folder that replicates across all your devices**. That
folder is what Syncery will write into.

> **Tip.** Syncthing only syncs while at least one peer is awake and reachable.
> An always-on box (a home server, NAS, or Raspberry Pi running Syncthing) makes
> a great hub so your e-reader and phone don't both have to be online at the
> same moment.

> **Warning.** Don't point Syncthing at your whole KOReader settings folder or
> home directory — syncing configuration files across devices can cause
> problems (e.g. two devices ending up with the same Device ID). Share a
> *library / data* folder, not a config folder.

### Point Syncery at the folder (the glue)

On each device, open **`☰` → Tools → Syncery → Transports → Configure
Syncthing…**, then:

- **Choose Syncthing folder** — Syncery asks the daemon for its folder list and
  lets you pick the shared one. (With KOSyncthing+ and a single folder, this is
  adopted automatically.) This folder is the scan root and where Syncery writes.
- **Set up API key…** — only needed on the **manual route**. Paste the Syncthing
  REST API key, found in the GUI under **Actions → Settings → GUI → API Key**.
  With KOSyncthing+ this is supplied for you — leave it.
- **Test connection** — pings the daemon and validates the key.

That's it for the Syncery side.

> **Note — conflict copies.** When Syncthing detects a true conflict it writes a
> `*.sync-conflict-*` copy. Syncery automatically adds the pattern
> `*syncery-*sync-conflict-*` to a `.stignore` file at the folder root so the
> daemon never replicates Syncery's own conflict copies. This is a local file
> write, idempotent, and safe even when the daemon is offline — you don't need
> to do anything.

### Worked example — a Kobo and an Android phone

1. **Phone:** install Syncthing-Fork and KOReader + Syncery + KOSyncthing+.
   **Kobo:** install KOReader + Syncery + KOSyncthing+ (KOSyncthing+ downloads
   the Syncthing binary on first run).
2. In Syncthing-Fork (phone) and KOSyncthing+'s GUI (Kobo), grab each Device ID
   and **Add Remote Device** on the other — wait for them to connect.
3. On the phone, create/share a folder (say `Books`) with the Kobo and **accept**
   it on the Kobo.
4. On **both** devices: **Syncery → Transports → Configure Syncthing… → Choose
   Syncthing folder → `Books`**.
5. Set both to the same storage mode ([Step 4](#step-4--make-both-devices-agree-storage-mode)),
   then sync.

---

## Path B — Sync with cloud storage

Cloud transport uploads Syncery's JSON files to a **Dropbox / WebDAV / FTP**
destination through KOReader's built-in cloud support, and downloads them on the
other devices. It's immediately consistent (every upload returns a real status
code) and the destination is always reachable as long as you have a network.

> **Why WebDAV over FTP.** Syncery's cloud conflict detection relies on HTTP
> ETags (an `If-Match` request that returns `412` when the remote copy changed
> underneath you). **FTP has no ETag**, so it can't do that check. If you have a
> choice, prefer **WebDAV**.

### Option 1 — Self-hosted WebDAV with rclone (recommended)

[rclone](https://rclone.org) can serve any folder — or any cloud remote — as a
WebDAV server in one command. Run it on an always-on machine (home server, NAS,
Raspberry Pi):

```sh
rclone serve webdav /path/to/sync-folder \
  --addr :8088 \
  --user yourname \
  --pass yourstrongpassword \
  --etag-hash MD5
```

- `--addr :8088` listens on all interfaces, port 8088. (rclone defaults to
  `127.0.0.1:8080`; use your machine's LAN IP/port so the e-readers can reach
  it.)
- **Always set `--user` / `--pass`** for anything reachable beyond `localhost`.
- `--etag-hash MD5` gives stable ETags, which is what Syncery's conflict
  detection uses.

The WebDAV URL your devices connect to is then `http://<server-ip>:8088/`. See
rclone's [serve webdav](https://rclone.org/commands/rclone_serve_webdav/) docs
for HTTPS, running it as a service, and more.

### Option 2 — Dropbox

KOReader supports Dropbox directly, but Dropbox now requires you to register a
small "app" and generate a token — a few fiddly steps. Rather than repeat them
here, follow this well-tested walkthrough:
[How to set up Dropbox cloud sync with KOReader, step by step](https://www.mobileread.com/forums/showthread.php?t=353670)
(MobileRead forums).

### Option 3 — Hosted WebDAV (Nextcloud, Koofr, etc.)

Any WebDAV provider works. You'll need the WebDAV **URL**, a **username**, and a
**password** (or app password):

- **Nextcloud / ownCloud:** `https://<your-host>/remote.php/dav/files/<username>/`
- **Koofr, Synology, InfiniCLOUD, …:** see the provider's WebDAV settings page
  for the exact URL.

### Add the account in KOReader, then point Syncery at it

1. In KOReader's **File Browser**, open the **tools** menu (the wrench/tools
   icon) → **Cloud storage**, and **add an account** for your provider. KOReader
   explains each field with info buttons as you go; for WebDAV you'll enter the
   URL, username, and password from above.
2. In Syncery, open **`☰` → Tools → Syncery → Transports → Cloud settings**, and
   pick that destination as where Syncery uploads. **Check cloud settings**
   confirms a destination is set; reachability is verified on the next sync.

> **Tip.** The **debounce window** under Cloud settings controls how long
> Syncery waits after a save before uploading mid-reading. Closing a book always
> uploads immediately regardless, so handoff between devices is prompt either
> way.

---

## Step 3 — Run the setup wizard

The first time Syncery loads, a short wizard walks you through up to four steps
in a single panel. (You can re-run it any time from **Syncery → Advanced**.)

1. **How do you want to sync?** — pick **Syncthing**, **Cloud**, or **Decide
   later**. If KOSyncthing+ is detected, the Syncthing row says **KOSyncthing+**
   and uses auto-discovery.
2. **Syncthing API key** *(only if you chose Syncthing without KOSyncthing+)* —
   paste the key from **Syncthing → Settings → GUI → API Key**.
3. **What to sync** — turn on **Reading position** and/or **Annotations**. Both
   start **off** (nothing syncs until you opt in). Finer controls (metadata,
   render settings, individual annotation types) live in **Syncery → What's
   synced** afterwards.
4. **Recap** — confirm the transport, what's synced, and this device's name, then
   tap **Done**.

> **Note.** If you chose *Decide later*, your reading data is still saved
> locally and will travel as soon as you set up a transport — picking later
> costs you nothing.

---

## Step 4 — Make both devices agree (storage mode)

This is the step that quietly decides whether sync actually works. The rule is
simple:

> **The same book must resolve to the same place on every device.**

How a book is matched across devices depends on **Syncery's storage mode**
(**Syncery → Advanced → Storage mode**). There are two, and **all your devices
must use the same one**:

- **Synceryhash (recommended for multi-device).** Syncery stores each book's
  JSON under its own folder, keyed by a hash of the **book's contents** —
  `…/syncery/synceryhash/<hash>/…`. The same book gets the same path on every
  device, no matter where the file lives or what it's named. Independent of
  KOReader's own metadata setting. This is the clean, self-contained choice:
  point your transport at Syncery's hash folder and you're done.
- **Book metadata folder (SDR) — the default.** Syncery writes its JSON
  *inside KOReader's own `.sdr` sidecar folder*, following your KOReader **Book
  metadata location**. This is tidy if you mostly use one device, **but for
  cross-device sync it only lines up if both devices also use the same KOReader
  metadata location** — and specifically KOReader's **hashdocsettings** mode
  (which names the `.sdr` by a content hash, so it matches across devices
  regardless of the book's path). With the other KOReader metadata modes, the
  same book can land at different paths on different devices and won't merge.

> **Recommendation.** For two or more devices, set **Synceryhash** on all of
> them (**Syncery → Advanced → Storage mode → Synceryhash**, then **Migrate all
> books to this storage mode…** if you already have data). It sidesteps the
> KOReader metadata question entirely.
>
> If you prefer to keep the default **SDR** mode, set KOReader's **Book metadata
> location** to **hashdocsettings** on every device — see KOReader's user guide
> section *Book metadata storage options* for what that setting does and its
> trade-offs.

---

## Step 5 — First sync, and how to verify it

1. On **every** device, make sure the same things are enabled under **Syncery →
   What's synced** (at least **Reading position**, and **Annotations** if you
   want highlights/notes to travel).
2. On **device A**, open a book and read a few pages (and add a highlight, to
   test annotations). Let it sync — close the book, or wait for the autosave.
   - **Syncthing:** the daemon replicates in the background; give it a moment and
     check Syncthing shows the folder *Up to Date*.
   - **Cloud:** closing the book uploads immediately.
3. On **device B**, open the **same book**. Syncery should offer to **jump to
   your position from device A** (per your **Jump** setting — Ask first by
   default), and your highlight should appear.

If that round-trip works, you're synced. Add your other devices the same way.

> **Tip — importing what you already have.** If you've been reading and
> annotating before installing Syncery, run **Syncery → Tools → Sync pre-Syncery
> annotations…** on each device to bring existing KOReader highlights and notes
> into the sync.

---

## Exporting your highlights

Syncery doesn't add its own export — it doesn't need to. Because Syncery merges
everything into KOReader's **native** highlight store on each device,
KOReader's built-in **Export Highlights** plugin already sees the merged result.
From **`☰` → Tools → Export Highlights** you can export to **text, Markdown,
HTML, JSON, or Kindle clippings**, or sync to **Joplin, Readwise, Memos, Flomo,
or XMNote**. On a synced device, that export reflects highlights made on *all*
your devices.

---

## Troubleshooting

A few setup-stage gotchas; see [README → Troubleshooting](README.md#troubleshooting)
for the full list.

- **Sync data isn't appearing on another device.** Check, in order: (1) both
  devices are on the **same Syncery storage mode**
  ([Step 4](#step-4--make-both-devices-agree-storage-mode)); (2) the transport
  is actually moving files (Syncthing shows *Up to Date*, or the file is in your
  cloud folder); (3) the same items are enabled under **What's synced** on both.
- **"Transport unavailable" in the Syncery header.** The transport isn't
  reachable: Syncthing isn't running / the folder isn't chosen, or the cloud
  destination is unset or offline. With KOSyncthing+, check **Syncery → Tools →
  Syncthing → KOSyncthing+ integration status…**.
- **Syncthing won't connect.** Confirm both Device IDs were added *and accepted
  on both sides*, both devices have Wi-Fi on, and (for internet sync) that at
  least one peer is reachable. An always-on hub helps.
- **PDF highlights + sync.** Writing highlights *into* a PDF changes the file,
  which changes its content hash — so a moved/edited PDF can lose its match in
  hash-based modes. Prefer KOReader's normal (sidecar) highlights when syncing.

---

<div align="center">

Made a setup work that isn't covered here? Open an issue or PR on
[GitHub](https://github.com/d0nizam) — real-world device combos are the most
useful thing to add.

</div>
