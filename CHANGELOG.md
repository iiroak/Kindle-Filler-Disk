# Changelog

## 2.2 - 2026-11-13

Bug-fix release for both scripts: `Scripts/Filler.ps1` (Windows) and
`Scripts/Filler.sh` (Linux/macOS).

### Safety

- **Both:** Disks that are not removable are now labeled in the manual device
  list and require typing `FILL` before anything is written.
- **PowerShell:** The manual device list only shows real portable devices under
  "(MTP)". The system drive, optical drives, network drives and user folders
  could previously appear there and be selected as a fill target.
- **Bash:** The manual device list only shows real block-device mounts. Pseudo
  and fuse mounts (`/run`, cgroup, gvfs) are gone, and system and home paths are
  hidden instead of being listed and then refused.
- **Bash:** The macOS boot volume is recognized by its device, not by the name
  "Macintosh HD".
- **Bash:** Mount paths containing spaces are decoded correctly.

### Fill

- **Both:** Resuming works. Existing `file_N` names are skipped, including gaps
  left by deleting single files.
  - PowerShell mass-storage mode used to count existing files as newly written.
  - Bash mass-storage mode could re-create and shrink existing files.
  - Bash MTP mode failed on the first file of any second run.
- **Both:** Created files are verified by size, and a failed write stops the
  loop with a real error message.
- **Both:** MTP mode keeps its own running total of bytes written and trusts
  the lower of that and the reported free space. A stale or missing reading can
  no longer overshoot the "leave free" target.
- **PowerShell:** An MTP copy counts as finished only when the file is on the
  device and Windows has released the local temp file. The temp file is no
  longer deleted mid-transfer.
- **PowerShell:** `fsutil` results are checked by exit code.
- **Bash:** Filler files are really allocated on the device. The `truncate`
  shortcut is only accepted there if it actually used the space; on a
  filesystem with sparse-file support it used none and the loop never ended.
- **Bash:** A stall guard stops the loop if free space does not go down.
- **Bash:** The `dd` fallback works with BSD/macOS `dd`.
- **Bash:** No more silent exits. With `set -e`, a failed write, unzip or
  delete ended the script without a message. These are handled explicitly, and
  anything unexpected is reported with its line number.
- **Bash:** MTP free space is read with `gio info -f`, with the previous query
  as fallback.
- **Bash:** MTP copy errors from `gio` are shown, and the script stops if the
  `fill_disk` folder cannot be created.

### Performance

- **PowerShell, MTP:** Copy completion is polled four times per second instead
  of once, and the device is only queried while nothing is being copied.
- **PowerShell, MTP:** The device folder is listed once at the start instead of
  being walked before every file and on every poll.
- **PowerShell, MTP:** The local temp file is renamed and reused for the next
  chunk instead of being created and deleted each time.
- **Bash, MTP:** Device requests per file are roughly halved: the folder is
  listed once, and free space is read once per file instead of twice.
- **Bash, MTP:** Local temp files are created sparse first, so they are instant
  and use no disk space or RAM.
- **Both, MTP:** The pause between files is 0.1 s instead of 0.3 s.
- **Bash, mass storage:** The write cache is flushed before the summary, so
  "complete" means the data is on the device. This adds time at the end rather
  than saving it.
- Mass-storage write speed itself is unchanged: FAT32 cannot preallocate space
  without writing it, so the device's flash and USB speed set the pace.

### Zip fallback

- **Both:** The archive size is rounded up to cover the free space. Previously
  10 GB free selected the 8 GB archive and left 2 GB free.
- **Both:** Entries are extracted one at a time, the "leave free" setting is
  respected, existing files are skipped, and the result is reported honestly.
- **Bash:** Downloaded and temporary files are always cleaned up.

### Remove mode

- **Both:** Removal is verified instead of always printing `[OK] Removed`.
- **PowerShell:** On MTP the folder is deleted in one operation (one Windows
  prompt instead of one per file), and the script waits for it to finish.
- **PowerShell:** Filler files left in the storage root are found and offered
  for deletion.

### Other

- **Both:** The final summary shows files written in this run, the free space
  now, and whether the fill completed or stopped early.
- **PowerShell:** `$mtpFreeKnown` renamed to `$freeKnown`; the Linux-only
  `gvfs` hint replaced with a Windows one; unused `Find-NextFreeIndex` removed.
- **Bash:** MTP device names in the manual list are parsed correctly; the temp
  directory comes from `mktemp`; unused `SCRIPT_DIR` removed.

### Known limitations

- The downloaded fallback archive has no checksum verification (no published
  hashes to check against).
- The zip fallback can leave more free space than requested, because it skips
  any archive entry that would not fit.
- Bash, MTP mode: the zip fallback needs local temp space for one archive entry
  at a time.
- PowerShell, remove mode: deleting filler files from the storage root may
  prompt once per file.
