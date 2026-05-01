# Kindle Disk Filler Utility for Windows/PowerShell
# Author: iroak (https://github.com/bastianmarin)

Write-Host "--------------------------------------------------------------------"
Write-Host "|                    Kindle Disk Filler Utility                    |"
Write-Host "| This tool fills the disk to prevent automatic updates on tablets |"
Write-Host "| that have not been registered. Useful for jailbreak preparation. |"
Write-Host "--------------------------------------------------------------------"

$dir = "fill_disk"
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

# Function to find the next free index for a file in the specified directory.
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

# Menu for user to select free space to leave
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

Write-Host "Filling disk with files. Please wait..."
while ($true) {
    $freeBytes = Get-FreeBytes
    $freeMB = [math]::Floor($freeBytes / 1MB)
    $freeGB = [math]::Floor($freeBytes / 1GB)

    if ($freeGB -ge 1) {
        $fileSize = 1GB
        $fileLabel = "1GB"
    } elseif ($freeMB -ge 100) {
        $fileSize = 100MB
        $fileLabel = "100MB"
    } elseif ($freeMB -ge $minFreeMB) {
        $fileSize = 10MB
        $fileLabel = "10MB"
    } else {
        break
    }

    if ($freeMB -lt $minFreeMB) { break }

    $filePath = Join-Path $dir "file_$i"
    fsutil file createnew $filePath $fileSize | Out-Null
    if (-not (Test-Path $filePath)) { break }
    Write-Host ("Created file_$i of size $fileLabel. Remaining free space: {0} MB" -f $freeMB)
    $i = Find-NextFreeIndex
}

Write-Host "Space exhausted or less than $minFreeMB MB free after creating $i files in $dir."
Write-Host "You can now check the $dir folder. Press any key to exit."
Pause
