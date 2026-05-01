# Kindle Disk Filler Utility

This utility helps fill up the storage space on your Kindle (or any device) to prevent automatic updates, especially useful for jailbreak preparation. It is available for Windows (PowerShell) and Linux/macOS (Bash).

**Important:** Copy the script (`Filler.ps1` or `Filler.sh`) to the root directory of your Kindle when it is connected via USB. The root directory is the main folder you see when you open the Kindle drive on your computer (not inside any subfolder).

## Usage

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
- You can safely delete individual dummy files (e.g., `file_0`, `file_1`, etc.) in the fill_disk folder if you need to free up some space temporarily.
- The script can be started multiple times. It will automatically find the next free index and continue filling the disk without conflicts.
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
