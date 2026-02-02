# Kindle Disk Filler Utility

This utility helps fill up the storage space on your Kindle (or any device) to prevent automatic updates, especially useful for jailbreak preparation. It is available for Windows (PowerShell) and Linux/macOS (Bash).

**Important:** Older Kindles expose a normal USB drive (USB mass storage) and you can run the script *from that mounted drive*.
Newer Kindles (including **Kindle Paperwhite 12th gen**) use **MTP** (no mounted drive letter on Windows / no `/Volumes/Kindle` on macOS), so you must generate the filler files locally and copy them with an MTP tool like **OpenMTP**.

## Usage

## Kindle Paperwhite 12th gen (MTP) on macOS: OpenMTP workflow

1. Install OpenMTP (macOS):
   - Repo: `https://github.com/ganeshrvel/openmtp`
2. Connect your Kindle over USB and open OpenMTP.
3. In OpenMTP, select your Kindle and note the **free space** it shows (in MB).
4. In this repo, run:

```bash
chmod +x Filler.sh
./Filler.sh --mtp
```

5. The script will create a local folder named `fill_disk/` (or your `--payload-dir`) sized to reduce the Kindle’s free space down to your chosen “leave MB”.
6. In OpenMTP, copy the generated `fill_disk/` folder onto the Kindle (recommended destination: `documents/`).

### Alternative (MTP): use prebuilt payload zips

If you prefer not to generate files, there are prebuilt payload zips in `MTP/` (e.g. `MTP/fill_32gb.zip`). Unzip one locally and copy the extracted folder(s) to the Kindle using OpenMTP. If copying stops due to “out of space”, that’s expected—re-run with the updated free space if you want to get closer to 20–50MB remaining.

### Windows (PowerShell)
**Tip:** To quickly open a PowerShell window in the correct folder:
- In File Explorer, navigate to the folder containing `Filler.ps1`.
- Hold `Shift` and right-click in the folder background, then select **"Open PowerShell window here"** or **"Open command window here"**.
- Alternatively, click the address bar, type `powershell`, and press Enter.

1. Open PowerShell in the folder containing `Filler.ps1`.
2. If you get an execution policy error, you can bypass it by running:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Filler.ps1
   ```
   Or, for the current session only:
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   .\Filler.ps1
   ```
3. Follow the on-screen prompts to select how much free space to leave.
4. The script will create files in the `fill_disk` folder until the desired free space remains.

### Linux / macOS (Bash)
1. Open a terminal in the folder containing `Filler.sh`.
2. Make the script executable (if needed):
   ```bash
   chmod +x Filler.sh
   ```
3. Run the script:
   ```bash
   ./Filler.sh
   ```
4. Follow the on-screen prompts to select how much free space to leave.
5. The script will create files in the `fill_disk` folder until the desired free space remains.

---

## Notes
- It is recommended to leave only 20-50 MB of free space to effectively block updates.
- To free up space again, simply delete the `fill_disk` folder after you have finished the jailbreak process.

---

## After Jailbreak: Freeing Up Space
Once you have completed the jailbreak process, you can safely delete the `fill_disk` folder to recover storage space. You may also remove only some of the files if you want to keep the disk nearly full for a while longer.

- **Windows:**
  1. Open File Explorer and navigate to the folder containing `fill_disk`.
  2. Delete the `fill_disk` folder, or remove individual files inside it.

- **Linux / macOS:**
  1. Open a terminal in the folder containing `fill_disk`.
  2. Run:
     ```bash
     rm -rf fill_disk
     ```
     Or remove individual files as needed.

This will restore your available disk space.

## License
MIT License