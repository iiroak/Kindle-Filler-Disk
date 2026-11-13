# Kindle Disk Filler

Fill Kindle storage to block automatic updates on unregistered tablets. Useful for jailbreak preparation.

## What this is (and what it is not)

There are two different things the community calls "filler", and mixing them up
causes a lot of confusion:

- **OTA blocker filler (this tool).** Fills the device's free space with dummy
  files so the Kindle cannot download an over-the-air (OTA) update. This is what
  `Filler.sh` / `Filler.ps1` do.
- **SpringBreak filler folders.** Some jailbreak guides (e.g. SpringBreak) ask
  you to create specific folders as part of their flow. Those folders are **not**
  the same thing and **do not** block OTA by themselves.

If your goal is to stop automatic updates, use this tool. If you are following a
jailbreak guide, follow that guide's steps for its own folders — do not mix the
two.

## Quick Run

**Linux / macOS:**
```bash
curl -fsSL https://github.com/iiroak/Kindle-Filler-Disk/raw/main/Scripts/Filler.sh | bash
```

**Windows (PowerShell):**
```powershell
irm https://github.com/iiroak/Kindle-Filler-Disk/raw/main/Scripts/Filler.ps1 | iex
```

**Windows (CMD):**
```cmd
powershell -Command "irm https://github.com/iiroak/Kindle-Filler-Disk/raw/main/Scripts/Filler.ps1 | iex"
```

## Which method should I use? (decision tree)

```
1. Does your Kindle show up as a USB drive/volume on your computer?
   - Yes  -> Mass Storage. The script fills it directly. (older Kindles)
   - No   -> It is probably MTP (11th gen+, Scribe, Basic 2024, PW5/PW6).
             The script writes into the device's storage folder over MTP.

2. Do you want to BLOCK OTA updates, or are you following SpringBreak?
   - Block OTA      -> use this tool (fill mode).
   - SpringBreak    -> follow that guide's folder steps; don't mix them.

3. Did the per-file fill fail on your MTP device?
   - Yes -> the script offers the pre-built ZIP fallback (last resort).
   - Or use the GUI alternative (jannikac/mtp-filler).

4. Already blocked OTA and want to read normally again?
   - Run the script and choose "Remove filler files" to reclaim space.

5. Kindle still shows "storage full" after removing?
   - Empty the Trash (.Trashes on macOS), disconnect/reconnect,
     and reboot the Kindle.
```

## Modes: fill and remove

When you run the script it first asks what to do:

- **Fill** — creates dummy files to occupy free space and block OTA updates.
  Before writing, it shows the destination, connection type and free space and
  asks for confirmation. You choose how much space to leave:
  - `20 MB` aggressive OTA block (may trigger "storage almost full" notifications)
  - `50 MB` balanced
  - `100 MB` daily use (fewer notifications, still blocks most OTA)
- **Remove** — deletes the `fill_disk/` folder, checks that it is really gone,
  and reports free space **before and after**, so you can verify the space was
  reclaimed. On Windows MTP devices, Windows may ask you to confirm the delete.

When a fill ends, the summary shows how many files were written in this run,
how much space is free now, and whether the fill completed or stopped early.

### Safety

- The script never fills your PC by accident: it only writes to a detected
  Kindle or a device you explicitly pick, and it **refuses** system/home paths
  (`/`, `/home`, Desktop, Downloads, the Windows system drive, …).
- If no Kindle is detected, the manual list only offers real storage devices.
  Anything that is not a removable/external device is labeled, and you must
  type `FILL` before the script writes to it.
- If the script hits an error, it shows the error and waits instead of closing
  the window silently (Windows) or exiting without a message (Linux/macOS).

## Supported Devices

| Kindle Model | Connection | Supported |
|-------------|------------|-----------|
| Kindle Basic (older) | Mass Storage | Yes |
| Kindle Paperwhite (up to 11th gen) | Mass Storage | Yes |
| Kindle Paperwhite 12th gen | MTP | Yes (Linux/Windows) |
| Kindle Basic 2024 | MTP | Yes (Linux/Windows) |
| Kindle Scribe | MTP | Yes (Linux/Windows) |

## How It Works

The script **automatically detects** your Kindle's connection type:

1. **Mass Storage** (older Kindles): appears as a regular USB drive. Files are created directly on the device.
2. **MTP** (modern Kindles): appears as a portable device. Files are created locally then transferred via MTP protocol.

### MTP nested storage structure

MTP devices are **not** writable at their root. The device root contains one or
more storage folders, and files can only be written *inside* one of them:

```
Kindle                          <- device root (NOT writable)
└── Internal Storage            <- storage folder (write here)
    └── fill_disk/              <- the script writes the filler files here
```

The name of the storage folder is **localized** and varies by device
(`Internal Storage`, `Almacenamiento interno compartido`, `Espace de stockage
interne`, `SD card`, …). The scripts detect it automatically: if there is a
single storage folder they use it; otherwise they match a multilingual list of
known names and fall back to the first available folder.

### Detection Methods

| OS | Mass Storage Detection | MTP Detection |
|----|----------------------|---------------|
| Linux | `findmnt` by volume label "Kindle" | `gio mount -l` (requires `gvfs`) |
| macOS | `/Volumes/Kindle` | Not supported (macOS lacks MTP) |
| Windows | Drive with volume name "Kindle" | `Shell.Application` COM (portable devices) |

## MTP Support (Linux)

For newer Kindles that use MTP protocol, you need `gvfs` installed:

```bash
# Ubuntu/Debian
sudo apt install gvfs gvfs-backends

# Fedora
sudo dnf install gvfs gvfs-mtp

# Arch Linux
sudo pacman -S gvfs gvfs-mtp
```

For the pre-built ZIP fallback (below) you also need `unzip` and `curl` (or
`wget`), which are present on most systems by default.

## Pre-built ZIP fallback (last resort)

If the normal per-file fill method fails on your device (e.g. an MTP device
that refuses scripted writes), the scripts offer a fallback: they download a
pre-built archive of zero-filled files from this repo's
[`Zips/`](https://github.com/iiroak/Kindle-Filler-Disk/tree/main/Zips) folder
and copy its contents into `fill_disk/` on the device.

- The archives are tiny to download (~8–66 MB) but expand to ~8/16/32/64 GB
  (zeros compress about 1000:1).
- The script picks the smallest archive that covers your device's free space
  (`fill_8gb.zip`, `fill_16gb.zip`, `fill_32gb.zip`, `fill_64gb.zip`). If free
  space can't be read, it asks for your Kindle's size.
- The archive is extracted one file at a time, so it does **not** need
  gigabytes of scratch space on your PC.
- The space you chose to leave free is respected: files that would not fit are
  skipped, so the fallback can leave somewhat more free space than requested.

This is only triggered when the primary method wrote nothing; you are always
prompted before anything is downloaded.

## GUI alternative

If you prefer a graphical tool instead of these scripts,
[`jannikac/mtp-filler`](https://github.com/jannikac/mtp-filler) is a mature
cross-platform option (Rust + `libmtp`/Windows WPD) that ships a GUI **and** a
CLI in a single pre-built binary for Windows, macOS and Linux. It does the same
job (fill an MTP device's storage to block OTA updates) with a point-and-click
interface.

## Notes

- Recommended free space: 20-50 MB to block updates
- The filler is written as **100 MB files** (`file_0`, `file_1`, … in `fill_disk`),
  using smaller 50/10/1 MB pieces only for the final tail. This is intentional: to
  add a book later you can **delete a single file to free 100 MB** and copy it in,
  while the device stays full enough to keep OTA updates blocked — no need to remove
  everything.
- Multiple runs are safe — existing filler files are kept and the script
  continues from where it left off, also after you deleted single files
- To free the space again, run the script and pick **Remove filler files**
  (it reports free space before/after). Deleting `fill_disk/` by hand also works.
- The script **will not** create files on your PC — it only targets the Kindle device
- If no Kindle is detected, the script lists the available devices so you can
  pick one, and aborts with a clear error message if there are none
- Linux/macOS, mass storage: wait for the "Flushing data to the device" step to
  finish before unplugging the Kindle

## Running from File (Windows)

If you download `Filler.ps1` and run it locally, PowerShell may block it with an execution policy error. Solutions:

```powershell
# Option A: Run with bypass (one-time)
powershell -ExecutionPolicy Bypass -File .\Filler.ps1

# Option B: Change policy permanently (recommended)
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

The `irm | iex` command works without any changes because it runs in the current session.

## Troubleshooting

### "No Kindle device detected"
- Ensure your Kindle is connected via USB cable
- Unlock the Kindle and make sure it shows the home screen
- For MTP Kindles on Linux: install `gvfs gvfs-backends`
- Try disconnecting and reconnecting the USB cable

### Script fills PC storage instead of Kindle (FIXED in v2.1)
This issue was fixed in v2.1. The script now detects the Kindle device before creating any files.

### "El archivo no está firmado digitalmente" (Windows)
See [Running from File](#running-from-file-windows) above.

### "Fill stopped early"
The summary says this when a write failed before the target was reached. The
error is printed just above the summary (device full, disconnected, locked or
read-only). Reconnect the Kindle and run the script again; it resumes.

### MTP is slow
MTP transfers are inherently slower than mass storage. The script writes 100MB files in both modes (with a 50/10/1MB tail); on MTP each file is streamed one at a time, which balances speed and reliability. v2.2 reduced the waiting between files, but the transfer itself is limited by the device.

## Manual

Copy `Filler.ps1` (Windows) or `Filler.sh` (Linux/macOS) to Kindle root via USB, then run.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## Credits

- [iiroak](https://github.com/iiroak) — Original author
- [vinaooo](https://github.com/vinaooo) — MTP detection and auto-detection for Linux ([#8](https://github.com/iiroak/Kindle-Filler-Disk/issues/8))
- [simoneeti](https://github.com/simoneeti) — gio-based MTP approach for Linux ([#34](https://github.com/iiroak/Kindle-Filler-Disk/issues/34))
- [johnabs](https://github.com/johnabs) — dd single-file suggestion ([#18](https://github.com/iiroak/Kindle-Filler-Disk/issues/18))
- [zhangyoufu](https://github.com/zhangyoufu) — mkfile performance issue on macOS ([#19](https://github.com/iiroak/Kindle-Filler-Disk/issues/19))
- [SkylarPlayz348](https://github.com/SkylarPlayz348) — pre-built MTP filler archives used by the zip fallback
- [jannikac](https://github.com/jannikac) — [`mtp-filler`](https://github.com/jannikac/mtp-filler), the cross-platform GUI/CLI alternative
