# Kindle Disk Filler

Fill Kindle storage to block automatic updates.

## Quick Run

**Linux / macOS:**
```bash
curl -fsSL https://github.com/iiroak/Kindle-Filler-Disk/raw/main/NoMTP/Filler.sh | bash
```

**Windows (PowerShell):**
```powershell
irm https://github.com/iiroak/Kindle-Filler-Disk/raw/main/NoMTP/Filler.ps1 | iex
```

## Notes

- Recommended free space: 20-50 MB to block updates
- Multiple runs are safe — continues from where it left off
- Delete `fill_disk/` folder to free space after jailbreak

## Manual

Copy `Filler.ps1` (Windows) or `Filler.sh` (Linux/macOS) to Kindle root via USB, then run.