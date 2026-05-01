# AGENTS.md

## Project Overview

Kindle Disk Filler Utility: creates large dummy files to fill Kindle storage and block automatic updates. Dual-platform (Windows PowerShell, Linux/macOS Bash).

## Scripts

- `Filler.ps1` — Windows/PowerShell entrypoint
- `Filler.sh` — Linux/macOS entrypoint
- `FilesMTP.py` — Generates pre-filled zip archives in `MTP/` folder

## MTP Folder

Pre-generated zip archives (`fill_8gb.zip`, `fill_16gb.zip`, `fill_32gb.zip`, `fill_64gb.zip`) for offline use. To regenerate: run `python FilesMTP.py`.

## No Build/Test/Lint

This repo has no build system, test suite, or CI. Scripts are standalone and run directly.
