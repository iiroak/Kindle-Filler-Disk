# Kindle Disk Filler Utility for Windows/PowerShell
# Author: iiroak (https://github.com/iiroak)
# Supports Mass Storage and MTP (newer Kindles)

# Global safety net: if any unhandled terminating error occurs, show it and
# keep the window open instead of closing silently (common PowerShell pain).
trap {
    Write-Host ""
    Write-Host "[!] Unexpected error: $($_.Exception.Message)"
    Write-Host "    (line $($_.InvocationInfo.ScriptLineNumber))"
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host ""
Write-Host "  +=============================================================+"
Write-Host "  |               Kindle Disk Filler Utility v2.2               |"
Write-Host "  +=============================================================+"
Write-Host "  |     Fills disk to prevent auto-updates on unregistered      |"
Write-Host "  |         tablets. Useful for jailbreak preparation.          |"
Write-Host "  +=============================================================+"
Write-Host ""

# --- PORTABLE DEVICE CHECK ---
# Decide whether a "This PC" shell item is a real portable (MTP/WPD)
# device. Drives of ANY type (system, fixed, optical, network), UNC paths and
# ordinary filesystem folders are rejected, so they can never be picked as an
# "MTP" target.
function Test-IsPortableDevice($item) {
    if (-not $item) { return $false }
    try { if ($item.IsFileSystem) { return $false } } catch {}
    $path = ''
    try { $path = [string]$item.Path } catch {}
    if ($path -match '^[A-Za-z]:') { return $false }   # drive letter path
    if ($path -match '^\\\\')      { return $false }   # UNC / network path
    $name = [string]$item.Name
    try {
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            $l = $d.Name.Substring(0, 1)
            if ($name -match "\($l`:\)") { return $false }   # e.g. "Local Disk (C:)"
        }
    } catch {}
    return $true
}

# --- DETECT KINDLE ---
function Find-Kindle {
    Write-Host "[*] Detecting Kindle device..."

    # 1. Try Mass Storage (older Kindles with drive letter)
    $drives = Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue
    foreach ($drive in $drives) {
        if ($drive.VolumeName -eq "Kindle") {
            $label = $drive.VolumeName
            Write-Host "[OK] Kindle found as Mass Storage: $($drive.DeviceID)\"
            return @{
                Path = "$($drive.DeviceID)\"
                Type = "mass_storage"
                DriveLetter = $drive.DeviceID[0]
                Name = "$label ($($drive.DeviceID))"
            }
        }
    }

    # 2. Try MTP via Shell.Application COM
    try {
        $shell = New-Object -ComObject Shell.Application
        $thisPC = $shell.Namespace(0x11)
        if ($thisPC) {
            foreach ($item in $thisPC.Items()) {
                # Must also be a real portable device, not a drive/folder
                if ($item.Name -match "Kindle" -and (Test-IsPortableDevice $item)) {
                    Write-Host "[OK] Kindle found as MTP device: $($item.Name)"
                    return @{
                        Path = $item.Path
                        Type = "mtp"
                        ShellItem = $item
                        DeviceName = $item.Name
                        Name = $item.Name
                    }
                }
            }
        }
    } catch {
        Write-Host "[!] Shell.Application MTP detection failed: $_"
    }

    return $null
}

# --- MANUAL DEVICE SELECTION ---
function Select-Device {
    Write-Host ""
    Write-Host "[*] No Kindle found. Listing all available devices..."
    Write-Host ""

    $devices = @()
    $idx = 1

    # List all logical disks
    $drives = Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue
    $sysDrive = $env:SystemDrive   # e.g. "C:" - never a Kindle; protect it
    foreach ($drive in $drives) {
        if ($drive.DriveType -ne 3 -and $drive.DriveType -ne 2) { continue }
        # Safety: do not offer the system drive as a fill target.
        if ($drive.DeviceID -eq $sysDrive) { continue }
        $label = if ($drive.VolumeName) { $drive.VolumeName } else { "Unnamed" }
        $sizeGB = if ($drive.Size) { [math]::Round($drive.Size / 1GB, 1) } else { 0 }
        $freeGB = if ($drive.FreeSpace) { [math]::Round($drive.FreeSpace / 1GB, 1) } else { 0 }
        # Flag internal/fixed disks so they are obvious in the list and
        # require an extra confirmation later.
        $isFixed = ($drive.DriveType -eq 3)
        $tag = if ($isFixed) { "  [!] INTERNAL/FIXED DISK" } else { "" }
        $devices += @{
            Type = "mass_storage"
            Path = "$($drive.DeviceID)\"
            DriveLetter = $drive.DeviceID[0]
            IsFixed = $isFixed
            Name = "$label ($($drive.DeviceID)) - ${freeGB}GB free / ${sizeGB}GB"
        }
        Write-Host "  [$idx] $label ($($drive.DeviceID)) - ${freeGB}GB free / ${sizeGB}GB$tag"
        $idx++
    }

    # List MTP/WPD devices via Shell COM (only real portable devices, not drives)
    try {
        $shell = New-Object -ComObject Shell.Application
        $thisPC = $shell.Namespace(0x11)
        if ($thisPC) {
            foreach ($item in $thisPC.Items()) {
                # Only real portable devices: no drives of any type and no
                # ordinary folders shown under This PC.
                if (-not (Test-IsPortableDevice $item)) { continue }

                $devices += @{
                    Type = "mtp"
                    Path = $item.Path
                    ShellItem = $item
                    DeviceName = $item.Name
                    Name = "$($item.Name) (MTP)"
                }
                Write-Host "  [$idx] $($item.Name) (MTP)"
                $idx++
            }
        }
    } catch {}

    if ($devices.Count -eq 0) {
        Write-Host "    No devices found."
        return $null
    }

    Write-Host ""
    $choice = Read-Host "  Select device (1-$($devices.Count))"
    $choiceNum = 0
    if ([int]::TryParse($choice, [ref]$choiceNum) -and $choiceNum -ge 1 -and $choiceNum -le $devices.Count) {
        return $devices[$choiceNum - 1]
    }

    Write-Host "    Invalid selection."
    return $null
}

# --- FREE SPACE ---
function Get-FreeBytes($kindle) {
    if ($kindle.Type -eq "mass_storage") {
        $drive = Get-PSDrive -Name $kindle.DriveLetter -ErrorAction SilentlyContinue
        if ($drive) { return $drive.Free }
        return 0
    }
    # MTP free space is resolved via Get-MtpFreeBytes on the storage folder.
    return 0
}

# --- MTP HELPERS ---
# MTP devices expose a nested structure: the device root is NOT writable;
# it contains one or more storage folders (e.g. "Internal Storage",
# "Almacenamiento interno compartido", "SD card"). We must descend into the
# storage folder before creating/writing files. Names are localized and vary
# by device, so we use a multilingual preferred list plus generic fallbacks.
#
# IMPORTANT: Shell COM collections on MTP devices must be iterated BY INDEX
# (.Item($k)); a foreach over .Items() silently yields nothing on many devices.
$script:MtpStorageNames = @(
    'Internal Storage','Internal shared storage','Internal storage','Phone',
    'Almacenamiento interno compartido','Almacenamiento interno','Almacenamiento',
    'Espace de stockage interne','Stockage interne','Stockage partag',
    'Interner gemeinsamer Speicher','Interner Speicher','Speicher',
    'Memoria interna condivisa','Memoria interna',
    'Armazenamento interno compartilhado','Armazenamento interno',
    'Gedeeld intern geheugen','Interne opslag',
    'SD card','Tarjeta SD','Carte SD'
)

function Get-MtpStorageFolder($deviceItem) {
    # Returns a Shell Folder object for the writable storage inside an MTP device.
    if (-not $deviceItem) { return $null }
    $devFolder = $null
    try { $devFolder = $deviceItem.GetFolder() } catch { return $null }
    if (-not $devFolder) { return $null }

    $items = $devFolder.Items()
    $count = 0
    try { $count = $items.Count } catch { $count = 0 }
    if ($count -eq 0) { return $null }

    # Collect folder entries by INDEX (foreach is unreliable on MTP)
    $folders = @()
    for ($k = 0; $k -lt $count; $k++) {
        $it = $items.Item($k)
        if ($it -and $it.IsFolder) { $folders += $it }
    }

    # No subfolders: fall back to the device root itself
    if ($folders.Count -eq 0) { return $devFolder }
    # Single storage: use it
    if ($folders.Count -eq 1) { return $folders[0].GetFolder() }

    # Multiple: prefer a known storage name (exact match)
    foreach ($p in $script:MtpStorageNames) {
        foreach ($f in $folders) {
            if ($f.Name -eq $p) { return $f.GetFolder() }
        }
    }
    # Partial/heuristic match on common storage keywords
    foreach ($f in $folders) {
        if ($f.Name -match '(?i)intern|shared|storage|almacen|stockage|speicher|memoria|armazen|opslag') {
            return $f.GetFolder()
        }
    }
    # Fallback: first folder
    return $folders[0].GetFolder()
}

function Get-MtpFreeBytes($storageFolder) {
    if (-not $storageFolder) { return 0 }
    try {
        $self = $storageFolder.Self
        if ($self) {
            $v = $self.ExtendedProperty('System.FreeSpace')
            if ($v) { return [long]$v }
        }
    } catch {}
    return 0
}

function Get-MtpCapacityBytes($storageFolder) {
    if (-not $storageFolder) { return 0 }
    try {
        $self = $storageFolder.Self
        if ($self) {
            $v = $self.ExtendedProperty('System.Capacity')
            if ($v) { return [long]$v }
        }
    } catch {}
    return 0
}

function Get-MtpItemNames($folder) {
    # Returns a hashtable of child names (index-based iteration).
    $names = @{}
    if (-not $folder) { return $names }
    try {
        $items = $folder.Items()
        $c = $items.Count
        for ($k = 0; $k -lt $c; $k++) {
            $n = $items.Item($k).Name
            if ($n) { $names[$n] = $true }
        }
    } catch {}
    return $names
}

function Get-MtpNextIndex($folder) {
    $names = Get-MtpItemNames $folder
    $idx = 0
    while ($names.ContainsKey("file_$idx")) { $idx++ }
    return $idx
}

# Shell CopyHere is asynchronous. While Windows is still copying, it
# keeps the local source file open, so "can we open it exclusively?" tells us
# whether the transfer is still running.
function Test-FileUnlocked($path) {
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'None')
        $fs.Close()
        return $true
    } catch { return $false }
}

# Wait until the file is listed on the device AND the local source has
# been released. Gives up if nothing shows up after $appearTimeout seconds with
# no transfer in progress, or after the hard limit.
function Wait-MtpCopy {
    param($folder, [string]$name, [string]$localPath,
          [int]$appearTimeout = 180, [int]$hardTimeout = 1200, [scriptblock]$OnTick)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $unlockedStreak = 0
    $lastTick = 0
    while ($sw.Elapsed.TotalSeconds -lt $hardTimeout) {
        # Poll 4x per second so a finished copy is noticed quickly.
        Start-Sleep -Milliseconds 250
        $unlocked = Test-FileUnlocked $localPath
        if ($unlocked) { $unlockedStreak++ } else { $unlockedStreak = 0 }
        # Only ask the device while nothing is being copied, so the transfer
        # itself is not slowed down by extra MTP requests.
        $present = $false
        if ($unlocked) {
            $present = Test-MtpItemPresent $folder $name ($unlockedStreak % 2 -eq 0)
        }
        # Done: on the device, and source released for 2 checks in a row.
        if ($present -and $unlockedStreak -ge 2) { return $true }
        $sec = [int]$sw.Elapsed.TotalSeconds
        # Not on the device, nothing copying, and we waited long enough: failed.
        if (-not $present -and $unlocked -and $sec -ge $appearTimeout) { return $false }
        if ($OnTick -and $sec -ge ($lastTick + 5)) { $lastTick = $sec; & $OnTick $sec }
    }
    return $false
}

# True if <name> is in the MTP folder. ParseName is a single lookup; walking
# the whole folder (slow with hundreds of files) is only done when $fullScan
# is set and the quick lookup found nothing.
function Test-MtpItemPresent($folder, [string]$name, [bool]$fullScan) {
    try { if ($folder.ParseName($name)) { return $true } } catch {}
    if ($fullScan) { return (Get-MtpItemNames $folder).ContainsKey($name) }
    return $false
}

# Free space the fill loop should trust. The value Windows reports for
# MTP storage is often cached, so we also keep our own estimate
# (free at start - bytes we wrote) and use whichever is LOWER.
function Get-MtpEffectiveFree($storageFolder, [long]$startFree, [long]$written) {
    $est = [Math]::Max($startFree - $written, 0)
    $reported = Get-MtpFreeBytes $storageFolder
    if ($reported -gt 0 -and $reported -lt $est) { return [long]$reported }
    return [long]$est
}

# --- PRE-BUILT ZIP FALLBACK (last resort) ---
# When the per-file fill method fails entirely, download a pre-built archive of
# zero-filled files and copy its contents onto the device. Archives hold
# ~8/16/32/64 GB but are only a few MB to download (zeros compress ~1000:1).
$script:ZipBaseUrl = "https://github.com/iiroak/Kindle-Filler-Disk/raw/main/Zips"

function Get-ZipBucket($freeBytes) {
    # Round UP to the smallest archive that covers the free space.
    $gb = $freeBytes / 1GB
    if     ($gb -le 8)  { return 8 }
    elseif ($gb -le 16) { return 16 }
    elseif ($gb -le 32) { return 32 }
    else                { return 64 }
}

# Returns @{ Ok = <bool>; Copied = <int> }
function Invoke-ZipFallback {
    param($kindle, [long]$freeBytes, [long]$minFreeBytes, $massTargetDir, $mtpFillFolder, $tempDir)

    $result = @{ Ok = $false; Copied = 0 }

    if ($tempDir -and -not (Test-Path $tempDir)) {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }

    # Choose bucket by free space, or ask if unknown.
    $freeKnown = $freeBytes -gt 0
    if ($freeKnown) {
        $bucket = Get-ZipBucket $freeBytes
        Write-Host "[*] Detected $([math]::Round($freeBytes/1GB,1)) GB free -> using fill_${bucket}gb.zip"
        if ($freeBytes -gt 64GB) {
            Write-Host "[!] More than 64 GB free: the largest archive will not fill the device completely."
        }
    } else {
        Write-Host "  What is your Kindle's storage size?"
        Write-Host "    [1] 8 GB   [2] 16 GB   [3] 32 GB   [4] 64 GB"
        $zc = Read-Host "  Choice (1-4) [1]"
        switch ($zc) { "2" {$bucket=16} "3" {$bucket=32} "4" {$bucket=64} default {$bucket=8} }
    }

    $zip = "fill_${bucket}gb.zip"
    $url = "$script:ZipBaseUrl/$zip"
    $tmpzip = Join-Path $env:TEMP "kindle_$zip"

    Write-Host "[*] Downloading $zip ..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        (New-Object System.Net.WebClient).DownloadFile($url, $tmpzip)
    } catch {
        Write-Host "[!] Download failed: $_"
        return $result
    }
    if (-not (Test-Path $tmpzip)) { Write-Host "[!] Download failed."; return $result }

    # Go entry by entry. Before each entry, check that it still fits while
    # leaving the requested free space, and count what was really written.
    $copied = 0; $failed = 0; $skipped = 0
    $estFree = $freeBytes
    $existing = @{}
    if ($kindle.Type -ne "mass_storage") { $existing = Get-MtpItemNames $mtpFillFolder }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $za = $null
    try {
        $za = [System.IO.Compression.ZipFile]::OpenRead($tmpzip)
        foreach ($e in $za.Entries) {
            if ([string]::IsNullOrEmpty($e.Name)) { continue }  # directory entry

            if ($kindle.Type -eq "mass_storage") {
                $dest = Join-Path $massTargetDir $e.Name
                if (Test-Path $dest) { continue }               # already there
                if ($freeKnown) {
                    $estFree = Get-FreeBytes $kindle
                    if (($estFree - $e.Length) -lt $minFreeBytes) { $skipped++; continue }
                }
                Write-Host "  [zip] extracting $($e.Name) ..."
                try {
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $false)
                    $copied++
                } catch {
                    Write-Host "[!] Extraction of $($e.Name) failed: $($_.Exception.Message)"
                    Remove-Item $dest -Force -ErrorAction SilentlyContinue   # partial file
                    $failed++
                    break
                }
            } else {
                if ($existing.ContainsKey($e.Name)) { continue }  # already there
                if ($freeKnown -and (($estFree - $e.Length) -lt $minFreeBytes)) { $skipped++; continue }
                $tmpf = Join-Path $tempDir $e.Name
                Write-Host "  [zip] copying $($e.Name) ..."
                $ok = $false
                try {
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $tmpf, $true)
                    $mtpFillFolder.CopyHere($tmpf, 0x14)
                    $ok = Wait-MtpCopy -folder $mtpFillFolder -name $e.Name -localPath $tmpf
                } catch {
                    Write-Host "[!] Copy of $($e.Name) failed: $($_.Exception.Message)"
                }
                Remove-Item $tmpf -Force -ErrorAction SilentlyContinue
                if ($ok) {
                    $copied++
                    $estFree -= $e.Length
                } else {
                    Write-Host "[!] $($e.Name) did not arrive on the device. Stopping."
                    $failed++
                    break
                }
            }
        }
    } catch {
        Write-Host "[!] Could not read the archive: $($_.Exception.Message)"
        $failed++
    } finally {
        if ($za) { $za.Dispose() }
    }

    Remove-Item $tmpzip -Force -ErrorAction SilentlyContinue
    if ($kindle.Type -ne "mass_storage" -and $tempDir -and (Test-Path $tempDir)) {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $result.Copied = $copied
    $result.Ok = ($copied -gt 0 -and $failed -eq 0)
    if ($result.Ok) {
        Write-Host "[OK] Zip fallback complete: $copied file(s) written, $skipped skipped to keep the requested free space."
    } elseif ($copied -gt 0) {
        Write-Host "[!] Zip fallback stopped early: $copied file(s) written, $failed failed."
    } else {
        Write-Host "[!] Zip fallback wrote nothing."
    }
    return $result
}

# --- REMOVE FILLER (cleanup mode) with before/after free space ---
function Remove-Filler {
    param($kindle)
    $dir = "fill_disk"
    Write-Host ""
    if ($kindle.Type -eq "mass_storage") {
        $before = Get-FreeBytes $kindle
        Write-Host "[*] Free space before: $(Get-PrettySize $before)"
        $target = Join-Path $kindle.Path $dir
        Write-Host "[*] Removing '$dir' ..."
        if (Test-Path $target) {
            # Verify the removal and report the real outcome.
            try {
                Remove-Item -Path $target -Recurse -Force -ErrorAction Stop
            } catch {
                Write-Host "[!] Error while removing: $($_.Exception.Message)"
            }
            if (Test-Path $target) {
                Write-Host "[!] '$target' could not be removed completely. Some files are still there."
            } else {
                Write-Host "[OK] Removed $target"
            }
        } else {
            Write-Host "[!] No '$dir' folder found at $target"
        }
        $after = Get-FreeBytes $kindle
        Write-Host "[*] Free space after:  $(Get-PrettySize $after)"
    } else {
        $storage = Get-MtpStorageFolder $kindle.ShellItem
        if (-not $storage) { Write-Host "[!] Cannot access MTP storage."; return }
        $before = Get-MtpFreeBytes $storage
        Write-Host "[*] Free space before: $(Get-PrettySize $before)"

        # Delete the whole folder in ONE operation (one Windows prompt
        # instead of one per file), then wait until it is really gone.
        $foundAnything = $false
        $fdItem = $storage.ParseName($dir)
        if ($fdItem -and $fdItem.IsFolder) {
            $foundAnything = $true
            Write-Host "[*] Removing '$dir' via MTP ..."
            Write-Host "    If Windows asks for confirmation, click Yes. This can take a few minutes."
            try { $fdItem.InvokeVerb('delete') } catch {}
            $waited = 0
            $gone = $false
            while ($waited -lt 600) {
                Start-Sleep -Seconds 2; $waited += 2
                if (-not (Get-MtpItemNames $storage).ContainsKey($dir)) { $gone = $true; break }
            }
            if ($gone) { Write-Host "[OK] Removed '$dir'" }
            else { Write-Host "[!] '$dir' is still on the device (delete declined or still running)." }
        }

        # Fill mode writes into the storage root when it cannot create
        # the subfolder. Find those leftovers too (names like file_0, file_1 ...).
        $rootFiles = @()
        try {
            $items = $storage.Items()
            for ($k = 0; $k -lt $items.Count; $k++) {
                $it = $items.Item($k)
                if ($it -and -not $it.IsFolder -and $it.Name -match '^file_\d+$') { $rootFiles += $it }
            }
        } catch {}
        if ($rootFiles.Count -gt 0) {
            $foundAnything = $true
            Write-Host "[*] Found $($rootFiles.Count) filler file(s) in the storage root (file_N)."
            Write-Host "    Windows may ask for confirmation once per file."
            $delRoot = Read-Host "  Delete them? (y/N)"
            if ($delRoot -match '^[yYsS]') {
                foreach ($rf in $rootFiles) { try { $rf.InvokeVerb('delete') } catch {} }
                $waited = 0
                while ($waited -lt 600) {
                    Start-Sleep -Seconds 2; $waited += 2
                    $left = @((Get-MtpItemNames $storage).Keys | Where-Object { $_ -match '^file_\d+$' }).Count
                    if ($left -eq 0) { break }
                }
                if ($left -eq 0) { Write-Host "[OK] Removed filler files from the storage root" }
                else { Write-Host "[!] $left filler file(s) are still in the storage root." }
            }
        }

        if (-not $foundAnything) { Write-Host "[!] No filler files found on the device." }

        Start-Sleep -Seconds 1
        $after = Get-MtpFreeBytes $storage
        Write-Host "[*] Free space after:  $(Get-PrettySize $after)"
    }
    Write-Host ""
    Write-Host "[i] If the Kindle still reports 'storage full', disconnect it,"
    Write-Host "    reconnect the USB cable, and reboot the Kindle."
}


# --- HELPERS ---
function Get-PrettySize($bytes) {
    $suffix = "B", "KB", "MB", "GB", "TB"
    $index = 0
    $size = [double]$bytes
    while ($size -ge 1KB -and $index -lt 4) {
        $size = $size / 1KB
        $index++
    }
    return "{0:N1} {1}" -f $size, $suffix[$index]
}

function Get-PrettySizeMB($mb) {
    if ($mb -ge 1024) { return "{0:N1} GB" -f ($mb / 1024) }
    return "$mb MB"
}

# Pick the next file size to write. Uniform 100 MB files are used as the primary
# chunk so freeing space later is granular: deleting ONE file frees exactly 100 MB
# (enough for a book) while the device stays nearly full and OTA stays blocked.
# Only the final tail uses 50/10/1 MB to land exactly on the requested free space.
function Get-FillChunk([long]$fillableBytes) {
    if     ($fillableBytes -ge 100MB) { return [long]100MB }
    elseif ($fillableBytes -ge 50MB)  { return [long]50MB }
    elseif ($fillableBytes -ge 10MB)  { return [long]10MB }
    elseif ($fillableBytes -ge 1MB)   { return [long]1MB }
    else                              { return [long]$fillableBytes }
}

function Draw-Bar {
    param([int]$Percent, [int]$Total = 32)
    $filled = [math]::Floor($Percent * $Total / 100)
    $empty = $Total - $filled
    return ("=" * $filled) + ("-" * $empty)
}

function Write-ProgressLine {
    param([int]$Percent, [string]$Status, [string]$Detail)
    $bar = Draw-Bar -Percent $Percent -Total 32
    $line = "  [{0}] {1,3}%  {2}{3}" -f $bar, $Percent, $Status, $Detail
    $width = [Math]::Max([Console]::WindowWidth - 1, $line.Length)
    [Console]::Write(("`r{0}" -f $line.PadRight($width)))
}

# --- MODE SELECTION ---
Write-Host "What do you want to do?"
Write-Host "  [1] Fill the device (block OTA updates)   [default]"
Write-Host "  [2] Remove filler files (free up space again)"
Write-Host ""
$modeChoice = Read-Host "  Choice (1-2) [1]"
if ($modeChoice -eq "2") { $Mode = "remove" } else { $Mode = "fill" }
Write-Host ""

# --- DETECT ---
$kindle = Find-Kindle
if (-not $kindle) {
    $kindle = Select-Device
    if (-not $kindle) {
        Write-Host ""
        Write-Host "[!] No devices available."
        Write-Host ""
        Write-Host "    Make sure the Kindle is unlocked and connected with a data-capable"
        Write-Host "    USB cable, and that it shows up in File Explorer under 'This PC'."
        Write-Host ""
        Read-Host "Press Enter to exit"
        exit
    }
}

Write-Host ""
Write-Host "[OK] Device selected: $($kindle.Name)"

# --- REMOVE MODE: reclaim space and exit ---
if ($Mode -eq "remove") {
    Remove-Filler -kindle $kindle
    Read-Host "Press Enter to exit"
    exit
}

# --- VALIDATE ---
$dir = "fill_disk"

if ($kindle.Type -eq "mass_storage") {
    # Mass storage: work directly on the drive
    $targetDir = Join-Path $kindle.Path $dir
    if (-not (Test-Path $targetDir)) {
        try {
            New-Item -ItemType Directory -Path $targetDir -ErrorAction Stop | Out-Null
            Write-Host "[OK] Directory created: $targetDir"
        } catch {
            Write-Host "[!] Error creating directory: $_"
            Read-Host "Press Enter to exit"
            exit
        }
    } else {
        Write-Host "[OK] Directory exists: $targetDir"
    }
} else {
    # MTP: create temp directory locally, files will be copied via Shell COM
    $tempDir = Join-Path $env:TEMP "kindle_filler_$PID"
    if (-not (Test-Path $tempDir)) {
        New-Item -ItemType Directory -Path $tempDir | Out-Null
    }
    Write-Host "[OK] Using temp directory: $tempDir"
    Write-Host "[*] Files will be created locally then copied via MTP"

    # Descend into the writable storage folder (nested MTP structure).
    $mtpStorageFolder = Get-MtpStorageFolder $kindle.ShellItem
    if (-not $mtpStorageFolder) {
        Write-Host "[!] Cannot access MTP storage."
        Write-Host "    Make sure the device is UNLOCKED and set to 'File Transfer' (MTP) mode,"
        Write-Host "    then disconnect and reconnect the USB cable."
        Read-Host "Press Enter to exit"
        exit
    }
    Write-Host "[OK] Connected to: $($kindle.DeviceName)"
    try { Write-Host "[OK] Storage folder: $($mtpStorageFolder.Title)" } catch {}

    # Create/locate the fill_disk directory INSIDE the storage folder.
    $mtpFillFolder = $null
    $fdItem = $mtpStorageFolder.ParseName($dir)
    if (-not $fdItem) {
        try { $mtpStorageFolder.NewFolder($dir) } catch {}
        Start-Sleep -Seconds 1
        $fdItem = $mtpStorageFolder.ParseName($dir)
    }
    if ($fdItem -and $fdItem.IsFolder) {
        $mtpFillFolder = $fdItem.GetFolder()
        Write-Host "[OK] Directory ready on device: $dir"
    } else {
        # Could not create subfolder: write into the storage root as a fallback.
        $mtpFillFolder = $mtpStorageFolder
        Write-Host "[!] Could not create '$dir' subfolder; writing to storage root instead."
    }
}

Write-Host ""

# --- GET FREE SPACE ---
$totalFreeBytes = Get-FreeBytes $kindle
$freeKnown = $totalFreeBytes -gt 0

if ($freeKnown) {
    Write-Host "[OK] Available space: $(Get-PrettySize $totalFreeBytes)"
} elseif ($kindle.Type -eq "mtp") {
    # MTP free space via System.FreeSpace extended property on the storage folder
    $totalFreeBytes = Get-MtpFreeBytes $mtpStorageFolder
    if ($totalFreeBytes -gt 0) {
        $freeKnown = $true
        $capBytes = Get-MtpCapacityBytes $mtpStorageFolder
        if ($capBytes -gt 0) {
            Write-Host "[OK] Available space (MTP): $(Get-PrettySize $totalFreeBytes) free / $(Get-PrettySize $capBytes) total"
        } else {
            Write-Host "[OK] Available space (MTP): $(Get-PrettySize $totalFreeBytes)"
        }
    } else {
        Write-Host "[!] Cannot determine free space via MTP."
        Write-Host "    The script will fill until the device reports errors."
    }
}

# --- USER INPUT ---
Write-Host ""
Write-Host "How much free space (in MB) do you want to LEAVE on the device?"
Write-Host "  Leaving very little space blocks OTA updates more reliably, but the"
Write-Host "  Kindle may show repeated 'storage almost full' notifications and can"
Write-Host "  be uncomfortable for daily reading."
Write-Host ""
Write-Host "  [1] 20 MB  - aggressive OTA block (may cause notifications) [default]"
Write-Host "  [2] 50 MB  - balanced"
Write-Host "  [3] 100 MB - daily use (fewer notifications, still blocks most OTA)"
Write-Host "  [4] Custom value"
Write-Host ""
$choice = Read-Host "  Enter your choice (1-4) [1]"

if ($choice -eq "2") {
    $minFreeMB = 50
} elseif ($choice -eq "3") {
    $minFreeMB = 100
} elseif ($choice -eq "4") {
    $custom = Read-Host "  Enter the minimum free space in MB (e.g., 30)"
    $customValue = 0
    if ([int]::TryParse($custom, [ref]$customValue) -and $customValue -gt 0) {
        $minFreeMB = $customValue
    } else {
        Write-Host "Invalid input. Using default (20 MB)."
        $minFreeMB = 20
    }
} else {
    $minFreeMB = 20
}

$minFreeBytes = [long]$minFreeMB * 1MB

# Validate free space if known
if ($freeKnown) {
    $targetFillBytes = $totalFreeBytes - $minFreeBytes
    if ($targetFillBytes -le 0) {
        Write-Host "[!] The requested free space ($minFreeMB MB) is >= current free space. Nothing to do."
        Write-Host ""
        Read-Host "Press Enter to exit"
        exit
    }
    Write-Host ""
    Write-Host "[>] Starting disk fill process..."
    Write-Host "    Target: fill ~$(Get-PrettySize $targetFillBytes), leave $minFreeMB MB free"
} else {
    $targetFillBytes = 0  # Unknown
    Write-Host ""
    Write-Host "[>] Starting disk fill process (free space unknown)..."
    Write-Host "    Will fill until $minFreeMB MB remaining or write errors"
}

Write-Host "    Mode: $($kindle.Type)"
Write-Host ""

# --- CONFIRMATION ---
if ($kindle.Type -eq "mass_storage") {
    $destLabel = "$($kindle.Path)$dir"
} else {
    $destLabel = "$($kindle.Name) -> $dir"
}
$freeLabel = if ($totalFreeBytes -gt 0) { Get-PrettySize $totalFreeBytes } else { "unknown" }
Write-Host "  +--- Please confirm --------------------------------------+"
Write-Host "    Destination : $destLabel"
Write-Host "    Connection  : $($kindle.Type)"
Write-Host "    Free now    : $freeLabel"
Write-Host "    Leaving     : $minFreeMB MB free"
Write-Host "  +---------------------------------------------------------+"
$proceed = Read-Host "  Proceed with filling this device? (y/N)"
if ($proceed -notmatch '^[yYsS]') {
    Write-Host "[!] Cancelled by user. Nothing was written."
    Read-Host "Press Enter to exit"
    exit
}
# A fixed/internal disk is almost never a Kindle. Require a typed word.
if ($kindle.IsFixed) {
    Write-Host ""
    Write-Host "  [!] WARNING: $($kindle.Path) is an INTERNAL/FIXED disk, not a removable device."
    $typed = Read-Host "  Type FILL (capitals) to fill it anyway"
    if ($typed -cne 'FILL') {
        Write-Host "[!] Cancelled. Nothing was written."
        Read-Host "Press Enter to exit"
        exit
    }
}
Write-Host ""

# --- MAIN LOOP ---
$i = 0
$wroteCount = 0
$fillFailed = $false   # Set when the loop stops because of an error

if ($kindle.Type -eq "mass_storage") {
    # ---- MASS STORAGE MODE ----
    $targetDir = Join-Path $kindle.Path $dir

    while ($true) {
        $currentFree = Get-FreeBytes $kindle
        $fillableBytes = $currentFree - $minFreeBytes
        if ($fillableBytes -le 0) { break }

        $fileSize = Get-FillChunk $fillableBytes
        if ($fileSize -le 0) { break }

        $fileLabel = Get-PrettySize $fileSize
        # Resume support: skip names that already exist.
        while (Test-Path (Join-Path $targetDir "file_$i")) { $i++ }
        $filePath = Join-Path $targetDir "file_$i"

        # Progress
        if ($freeKnown) {
            $usedBytes = $totalFreeBytes - $currentFree
            $percent = [math]::Floor(($usedBytes * 100) / $targetFillBytes)
            if ($percent -lt 0) { $percent = 0 }
            if ($percent -gt 100) { $percent = 100 }
        } else {
            $percent = 0
        }

        Write-ProgressLine -Percent $percent -Status "Creating: " -Detail "file_$i ($fileLabel)"

        # Create file
        # Verify the result (exit code + actual size) and show the error.
        $fsOut = & fsutil file createnew $filePath $fileSize 2>&1
        $created = ($LASTEXITCODE -eq 0) -and (Test-Path $filePath)
        if ($created) {
            try { $created = ((Get-Item $filePath).Length -eq $fileSize) } catch { $created = $false }
        }
        if (-not $created) {
            Write-Host "`n[!] Could not create file_$i ($fileLabel): $(($fsOut | Out-String).Trim())"
            Remove-Item $filePath -Force -ErrorAction SilentlyContinue   # partial file
            $fillFailed = $true
            break
        }

        $i++
        $wroteCount++

        # Progress update
        $currentFree = Get-FreeBytes $kindle
        $remainingLabel = Get-PrettySize $currentFree
        if ($freeKnown) {
            $usedBytes = $totalFreeBytes - $currentFree
            $percent = [math]::Floor(($usedBytes * 100) / $targetFillBytes)
            if ($percent -lt 0) { $percent = 0 }
            if ($percent -gt 100) { $percent = 100 }
        } else {
            $percent = 0
        }

        Write-ProgressLine -Percent $percent -Status "Done:     " -Detail "file_$($i-1) | Free: $remainingLabel"
    }

} else {
    # ---- MTP MODE ----
    # Files are copied into the fill_disk folder INSIDE the device storage.
    $targetFolder = $mtpFillFolder
    Write-Host "[OK] Target: $($kindle.DeviceName) -> $dir"

    # Resume from the next free index already present on the device.
    $i = Get-MtpNextIndex $targetFolder
    if ($i -gt 0) { Write-Host "[*] Resuming from file_$i (existing files detected)" }

    $mtpChunk = [long]100MB   # 100MB chunks: balance of speed and MTP reliability
    $mtpBytesWritten = [long]0   # Our own running total
    # Names already on the device: listed once here, then kept up to date
    # locally instead of walking the folder before every file.
    $existingNames = Get-MtpItemNames $targetFolder
    $pooledTmp = $null           # temp file kept from the previous chunk
    $pooledSize = [long]0

    while ($true) {
        # Determine current free space and remaining fillable amount
        $currentFree = 0
        if ($freeKnown) {
            # Use the lower of "reported free" and "start - written".
            # A stale or zero reading must never trigger a blind 100 MB chunk.
            $currentFree = Get-MtpEffectiveFree $mtpStorageFolder $totalFreeBytes $mtpBytesWritten
            $fillableBytes = $currentFree - $minFreeBytes
            if ($fillableBytes -le 0) { break }
            $fileSize = Get-FillChunk $fillableBytes
        } else {
            $fileSize = $mtpChunk
        }
        if ($fileSize -le 0) { break }

        $fileLabel = Get-PrettySize $fileSize

        # Never reuse a name that is already on the device.
        while ($existingNames.ContainsKey("file_$i")) { $i++ }

        # Progress (only meaningful when free space is known)
        if ($freeKnown -and $currentFree -gt 0 -and $totalFreeBytes -gt 0) {
            $usedBytes = $totalFreeBytes - $currentFree
            $percent = [math]::Floor(($usedBytes * 100) / [Math]::Max([long]$targetFillBytes, 1))
            if ($percent -lt 0) { $percent = 0 }
            if ($percent -gt 100) { $percent = 100 }
        } else {
            $percent = 0
        }

        Write-ProgressLine -Percent $percent -Status "Creating: " -Detail "file_$i ($fileLabel)"

        # Local temp file. The one from the previous chunk is renamed and
        # reused when it has the same size, instead of creating a new one.
        $tmpFile = Join-Path $tempDir "file_$i"
        $reused = $false
        if ($pooledTmp -and $pooledSize -eq $fileSize -and (Test-Path $pooledTmp)) {
            try { Move-Item -Path $pooledTmp -Destination $tmpFile -Force -ErrorAction Stop; $reused = $true } catch {}
        }
        if (-not $reused) {
            if ($pooledTmp) { Remove-Item -Path $pooledTmp -Force -ErrorAction SilentlyContinue }
            fsutil file createnew $tmpFile $fileSize | Out-Null
        }
        $pooledTmp = $null

        if (-not (Test-Path $tmpFile)) {
            Write-Host "`n[!] Failed to create temporary file"
            $fillFailed = $true
            break
        }

        # Copy to device via MTP (Shell COM). 0x14 = no progress UI + yes-to-all.
        $copySuccess = $false
        if ($targetFolder) {
            try {
                $targetFolder.CopyHere($tmpFile, 0x14)

                # Wait until the file is on the device AND Windows has
                # released the temp file, so it is never deleted mid-transfer.
                $tick = { param($sec) Write-ProgressLine -Percent $percent -Status "Copying:  " -Detail "file_$i ($fileLabel) - ${sec}s" }
                $copySuccess = Wait-MtpCopy -folder $targetFolder -name "file_$i" -localPath $tmpFile -OnTick $tick
            } catch {
                Write-Host "`n[!] MTP copy failed: $_"
            }
        } else {
            Write-Host "`n[!] No target folder on device"
        }

        # Keep the temp file for the next chunk; remove it if the copy failed.
        if ($copySuccess) {
            $pooledTmp = $tmpFile
            $pooledSize = $fileSize
            $existingNames["file_$i"] = $true
        } else {
            Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue
        }

        if (-not $copySuccess) {
            Write-Host "`n[!] Failed to copy file_$i to device. Storage may be full."
            # Expected way to stop when free space is unknown; an error otherwise.
            if ($freeKnown -or $wroteCount -eq 0) { $fillFailed = $true }
            break
        }

        $i++
        $wroteCount++
        $mtpBytesWritten += $fileSize

        # Progress update
        if ($freeKnown) {
            $currentFree = Get-MtpEffectiveFree $mtpStorageFolder $totalFreeBytes $mtpBytesWritten
            if ($currentFree -gt 0) {
                $remainingLabel = Get-PrettySize $currentFree
                $usedBytes = $totalFreeBytes - $currentFree
                $percent = [math]::Floor(($usedBytes * 100) / [Math]::Max([long]$targetFillBytes, 1))
                if ($percent -lt 0) { $percent = 0 }
                if ($percent -gt 100) { $percent = 100 }
                Write-ProgressLine -Percent $percent -Status "Done:     " -Detail "file_$($i-1) | Free: $remainingLabel"
            }
        }

        # Small delay for MTP stability
        Start-Sleep -Milliseconds 100
    }

    # Cleanup temp dir
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- ZIP FALLBACK (last resort) ---
# If the per-file method wrote nothing, offer the pre-built archive approach.
if ($wroteCount -eq 0) {
    Write-Host ""
    Write-Host "[!] The per-file fill method did not write any files."
    Write-Host "    Last resort: download a pre-built filler archive and copy it to the device."
    $useZip = Read-Host "  Try the pre-built zip fallback? (y/N)"
    if ($useZip -match '^[yYsS]') {
        # The fallback respects the "leave free" setting and returns what it wrote.
        if ($kindle.Type -eq "mass_storage") {
            $freeForZip = Get-FreeBytes $kindle
            $targetDir = Join-Path $kindle.Path $dir
            if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
            $zipResult = @(Invoke-ZipFallback -kindle $kindle -freeBytes $freeForZip -minFreeBytes $minFreeBytes -massTargetDir $targetDir -mtpFillFolder $null -tempDir $null)[-1]
        } else {
            $freeForZip = Get-MtpFreeBytes $mtpStorageFolder
            $zipResult = @(Invoke-ZipFallback -kindle $kindle -freeBytes $freeForZip -minFreeBytes $minFreeBytes -massTargetDir $null -mtpFillFolder $mtpFillFolder -tempDir (Join-Path $env:TEMP "kindle_filler_$PID"))[-1]
        }
        $wroteCount += $zipResult.Copied
        $fillFailed = -not $zipResult.Ok
    }
}

# --- DONE ---
# Summary: what was written this run, how much is free now,
# and whether the fill finished or stopped early.
if ($kindle.Type -eq "mass_storage") {
    $finalFree = Get-FreeBytes $kindle
} else {
    $finalFree = Get-MtpFreeBytes $mtpStorageFolder
}
if ($wroteCount -eq 0) {
    $doneTitle = "Nothing was written."
} elseif ($fillFailed) {
    $doneTitle = "Fill stopped early (see the message above)."
} else {
    $doneTitle = "Disk fill complete!"
}
$finalFreeLabel = if ($finalFree -gt 0) { Get-PrettySize $finalFree } else { "unknown" }
Write-Host ""
Write-Host "  +---------------------------------------------------------+"
Write-Host "  |  $doneTitle"
Write-Host "  |  Files written this run: $wroteCount"
Write-Host "  |  Free space now: $finalFreeLabel"
Write-Host "  |  Connection: $($kindle.Type)"
if ($kindle.Type -eq "mass_storage") {
    Write-Host "  |  Directory: $($kindle.Path)$dir"
} else {
    Write-Host "  |  Directory: $($kindle.Name) -> $dir"
    Write-Host "  |  (files transferred via MTP)"
}
Write-Host "  +---------------------------------------------------------+"
Write-Host ""
Read-Host "Press Enter to exit"