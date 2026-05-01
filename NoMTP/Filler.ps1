# Kindle Disk Filler Utility for Windows/PowerShell
# Author: iroak (https://github.com/iiroak)

Write-Host "--------------------------------------------------------------------"
Write-Host "|                    Kindle Disk Filler Utility                    |"
Write-Host "| This tool fills the disk to prevent automatic updates on tablets |"
Write-Host "| that have not been registered. Useful for jailbreak preparation. |"
Write-Host "--------------------------------------------------------------------"

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

$i = Find-NextFreeIndex

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

Write-Host "How much free space (in MB) do you want to leave on disk?"
Write-Host "It is highly recommended to leave only 20-50 MB of free space (no more) to prevent updates."
Write-Host "[1] 20 MB (default)"
Write-Host "[2] 50 MB"
Write-Host "[3] 100 MB"
Write-Host "[4] Custom value"
$choice = Read-Host "Enter your choice (1-4) [1]"

switch ($choice) {
    '2' { $minFreeMB = 50 }
    '3' { $minFreeMB = 100 }
    '4' {
        $custom = Read-Host "Enter the minimum free space in MB (e.g., 30)"
        if ([int]::TryParse($custom, [ref]$null) -and $custom -gt 0) {
            $minFreeMB = [int]$custom
        } else {
            Write-Host "Invalid input. Using default (20 MB)."
            $minFreeMB = 20
        }
    }
    default { $minFreeMB = 20 }
}

$expectedFreeSize = $minFreeMB * 1MB
$maxFileSize = 1GB

Write-Host "Filling disk with files. Please wait..."
while ($true) {
    $freeBytes = (Get-FreeBytes) - $expectedFreeSize
    $fileSize = $maxFileSize
    if ($freeBytes -lt $maxFileSize) {
        $fileSize = $freeBytes
    }

    if ($fileSize -le $expectedFreeSize) { break }

    $fileLabel = Get-PrettyFileSize $fileSize
    $filePath = Join-Path $dir "file_$i"
    Write-Host ("Creating file_$i of size $fileLabel...")
    fsutil file createnew $filePath $fileSize | Out-Null
    if (-not (Test-Path $filePath)) { break }
    $freeBytes = Get-FreeBytes
    $freeBytesLabel = Get-PrettyFileSize $freeBytes
    Write-Host ("Created file_$i of size $fileLabel. Remaining free space: $freeBytesLabel")
    $i = Find-NextFreeIndex
}

$freeBytes = Get-FreeBytes
$freeBytesLabel = Get-PrettyFileSize $freeBytes

Write-Host "Done filling up the disk. $freeBytesLabel free after creating $i files in $dir."
Write-Host "You can now check the $dir folder. Press any key to exit."
Pause