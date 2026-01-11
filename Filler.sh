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

GREEN='\033[0;32m'
NC='\033[0m'

# Function to get free space in MB on the current filesystem
get_free_mb() {
    df -Pm $dir | awk 'NR==2 {print $4}'
}

create_file () {
    local size=$1 path=$2

    # Linux on ext4/xfs/btrfs → *instant* allocation
    if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "$size" "$path"  && return
    fi
    # macOS
    if command -v mkfile    >/dev/null 2>&1; then
        mkfile "$size" "$path"        && return
    fi

    # Portable but very slow ;(
    dd if=/dev/zero of="$path" bs="$size" count=1 status=none
}

PROGRESS=0
TOTAL_UNITS=100          # keep at 100 if you want a 0‑100 % bar

draw_bar () {
    local add=$1
    (( add == 0 )) && return 

    PROGRESS=$(( PROGRESS + add ))
    (( PROGRESS > TOTAL_UNITS )) && PROGRESS=$TOTAL_UNITS 

    local pct=$(( PROGRESS * 100 / TOTAL_UNITS ))
    local filled=$(( pct / 2 ))
    local empty=$(( 50 - filled ))

    printf -v fill_str '%*s' "$filled" ''
    fill_str=${fill_str//#} # If filled is 0, this might act weird, see below

    fill_str=$(printf "%${filled}s" | tr ' ' '#')
    empty_str=$(printf "%${empty}s" | tr ' ' '-')

    printf "\rProgress: [%b%s%b%s] %d%%" "$GREEN" "$fill_str" "$NC" "$empty_str" "$pct"
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
totalFreeMB=$(get_free_mb)
previousFreeMB=-1
while true; do
    freeMB=$(get_free_mb)
    local_progress=0

    if [ "$previousFreeMB" -ge 0 ]; then
        last_iteration_progress=$(( $previousFreeMB - $freeMB))
        local_progress=$(( ((last_iteration_progress) * 100 / (totalFreeMB - minFreeMB)) ))
        draw_bar "$local_progress"
    fi
    
    local_progress=0
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
    create_file "$fileSize" "$filePath"
    if [ ! -f "$filePath" ]; then
        break
    else
        previousFreeMB=$freeMB
        i=$((i+1))
    fi
done

echo "Space exhausted or less than $minFreeMB MB free after creating $i files in $dir."
echo "You can now check the $dir folder. Press Enter to exit."
read -r _