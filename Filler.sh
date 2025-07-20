#!/bin/bash
# Kindle Disk Filler Utility for Linux/macOS
# Author: iroak (https://github.com/bastianmarin)
# This tool fills the disk to prevent automatic updates on tablets
# that have not been registered. Useful for jailbreak preparation.

set -e

echo "--------------------------------------------------------------------"
echo "|                    Kindle Disk Filler Utility                    |"
echo "| This tool fills the disk to prevent automatic updates on tablets |"
echo "| that have not been registered. Useful for jailbreak preparation. |"
echo "--------------------------------------------------------------------"

dir="fill_disk"
mkdir -p "$dir"
i=0

# Function to get free space in MB on the current filesystem
get_free_mb() {
    df -Pm "$dir" | awk 'NR==2 {print $4}'
}

echo "How much free space (in MB) do you want to leave on disk?"
echo "It is highly recommended to leave only 20-50 MB of free space (no more) to prevent updates."
echo "[1] 20 MB (default)"
echo "[2] 50 MB"
echo "[3] 100 MB"
echo "[4] Custom value"
read -p "Enter your choice (1-4) [1]: " choice

case "$choice" in
    2) minFreeMB=50 ;;
    3) minFreeMB=100 ;;
    4)
        read -p "Enter the minimum free space in MB (e.g., 30): " custom
        if [[ "$custom" =~ ^[0-9]+$ ]] && [ "$custom" -gt 0 ]; then
            minFreeMB=$custom
        else
            echo "Invalid input. Using default (20 MB)."
            minFreeMB=20
        fi
        ;;
    *) minFreeMB=20 ;;
esac

echo "Filling disk with files. Please wait..."
while true; do
    freeMB=$(get_free_mb)
    if [ "$freeMB" -ge 1024 ]; then
        fileSize=1G
        fileLabel="1GB"
    elif [ "$freeMB" -ge 100 ]; then
        fileSize=100M
        fileLabel="100MB"
    elif [ "$freeMB" -ge "$minFreeMB" ]; then
        fileSize=10M
        fileLabel="10MB"
    else
        break
    fi

    if [ "$freeMB" -lt "$minFreeMB" ]; then
        break
    fi

    filePath="$dir/file_$i"
    dd if=/dev/zero of="$filePath" bs=$fileSize count=1 status=none
    if [ ! -f "$filePath" ]; then
        break
    fi
    echo "Created file_$i of size $fileLabel. Remaining free space: $freeMB MB"
    i=$((i+1))
done

echo "Space exhausted or less than $minFreeMB MB free after creating $i files in $dir."
echo "You can now check the $dir folder. Press Enter to exit."
read -r _
