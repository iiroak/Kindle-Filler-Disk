# Kindle Disk Filler Utility for Windows/PowerShell
# Author: iiroak (https://github.com/iiroak)

Write-Host ""
Write-Host "  +=============================================================+"
Write-Host "  |               Kindle Disk Filler Utility v2.0               |"
Write-Host "  +=============================================================+"
Write-Host "  |     Fills disk to prevent auto-updates on unregistered      |"
Write-Host "  |         tablets. Useful for jailbreak preparation.          |"
Write-Host "  +=============================================================+"
Write-Host ""

$dir = "fill_disk"
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

function Find-NextFreeIndex {
    $index = 0
    while ($true) {
        $filePath = Join-Path $dir "file_$index"
        if (-not (Test-Path $filePath)) {
            return $index
        }
        $index++
    }
}

function Get-FreeBytes {
    $drive = (Get-Location).Path.Substring(0,2)
    $free = (Get-PSDrive -Name $drive[0]).Free
    return $free
}

function Get-PrettyFileSize($size) {
    $suffix = "B", "KB", "MB", "GB", "TB"
    $index = 0
    while ($size -ge 1KB) {
        $size = $size / 1KB
        $index++
    }
    return "{0:N1} {1}" -f $size, $suffix[$index]
}

function Draw-Bar {
    param([int]$Percent, [int]$Total = 50)
    $filled = [math]::Floor($Percent * $Total / 100)
    $empty = $Total - $filled
    $bar = "=" * $filled + "-" * $empty
    return $bar
}

function Write-ProgressLine {
    param(
        [int]$Percent,
        [string]$Status,
        [string]$Detail
    )

    $bar = Draw-Bar -Percent $Percent -Total 32
    $line = "  [{0}] {1,3}%  {2}{3}" -f $bar, $Percent, $Status, $Detail
    $width = [Math]::Max([Console]::WindowWidth - 1, $line.Length)
    [Console]::Write(("`r{0}" -f $line.PadRight($width)))
}

Write-Host "How much free space (in MB) do you want to leave on disk?"
Write-Host "It is highly recommended to leave only 20-50 MB (no more) to prevent updates."
Write-Host ""
Write-Host "  [1] 20 MB (default)"
Write-Host "  [2] 50 MB"
Write-Host "  [3] 100 MB"
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

$expectedFreeSize = $minFreeMB * 1MB
$maxFileSize = 1GB

Write-Host ""
Write-Host "[>] Starting disk fill process..."
Write-Host ""

$i = Find-NextFreeIndex
$totalFreeBytes = (Get-FreeBytes)
$targetFillBytes = $totalFreeBytes - $expectedFreeSize

if ($targetFillBytes -le 0) {
    Write-Host "[!] The requested free space is greater than or equal to the current free space. Nothing to do."
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit
}

while ($true) {
    $fillableBytes = (Get-FreeBytes) - $expectedFreeSize
    if ($fillableBytes -le 0) { break }

    $fileSize = $maxFileSize
    if ($fillableBytes -lt $maxFileSize) {
        $fileSize = $fillableBytes
    }

    if ($fileSize -le 0) { break }

    $fileLabel = Get-PrettyFileSize $fileSize
    $filePath = Join-Path $dir "file_$i"

    $currentFree = Get-FreeBytes
    $usedBytes = $totalFreeBytes - $currentFree
    $percent = [math]::Floor(($usedBytes * 100) / $targetFillBytes)
    if ($percent -lt 0) { $percent = 0 }
    if ($percent -gt 100) { $percent = 100 }

    Write-ProgressLine -Percent $percent -Status "Creating: " -Detail "file_$i ($fileLabel)"

    fsutil file createnew $filePath $fileSize | Out-Null

    if (-not (Test-Path $filePath)) { break }

    $i = Find-NextFreeIndex

    $currentFree = Get-FreeBytes
    $remainingLabel = Get-PrettyFileSize $currentFree
    $usedBytes = $totalFreeBytes - $currentFree
    $percent = [math]::Floor(($usedBytes * 100) / $targetFillBytes)
    if ($percent -lt 0) { $percent = 0 }
    if ($percent -gt 100) { $percent = 100 }

    Write-ProgressLine -Percent $percent -Status "Done:     " -Detail "file_$($i - 1) | Free: $remainingLabel"
}

Write-Host ""
Write-Host "  +---------------------------------------------------------+"
Write-Host "  |  Disk fill complete!                                      |"
Write-Host "  |  Files created: $i"
Write-Host "  |  Target directory: $dir"
Write-Host "  +---------------------------------------------------------+"
Write-Host ""
Read-Host "Press Enter to exit"
