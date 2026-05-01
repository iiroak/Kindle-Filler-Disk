# AGENTS.md

## Project Overview

Kindle Disk Filler Utility: creates large dummy files to fill Kindle storage and block automatic updates. Scripts live in `NoMTP/` and run directly via curl.

## Quick Run

```bash
# Linux/macOS
curl -fsSL https://github.com/iiroak/Kindle-Filler-Disk/raw/main/NoMTP/Filler.sh | bash

# Windows (PowerShell)
irm https://github.com/iiroak/Kindle-Filler-Disk/raw/main/NoMTP/Filler.ps1 | iex
```

## Scripts

- `NoMTP/Filler.ps1` — Windows/PowerShell
- `NoMTP/Filler.sh` — Linux/macOS

## No Build/Test/Lint

This repo has no build system, test suite, or CI. Scripts are standalone and run directly.