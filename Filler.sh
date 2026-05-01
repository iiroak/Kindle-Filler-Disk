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

# Finds the next free index for a file in the specified directory
find_next_free_index() {
    local index=0
    while true; do
        if [ ! -f "$dir/file_$index" ]; then
            echo "$index"
            return
        fi
        index=$((index + 1))
    done
}

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
    (( add == 0 )) && return          # ignore no‑progress calls

    PROGRESS=$(( PROGRESS + add ))
    (( PROGRESS > TOTAL_UNITS )) && PROGRESS=$TOTAL_UNITS   # clamp

    local pct=$(( PROGRESS * 100 / TOTAL_UNITS ))   # integer percent
    local filled=$(( pct / 2 ))                     # 50‑char bar (2 % each)

    # build the bar without external commands for better compatibility
    printf -v bar '%*s' "$filled" ''
    bar=${bar// /#}

    printf '\r[%-50s] %3d%%' "$bar" "$pct"
    printf '\n'
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
i=$(find_next_free_index)
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
        i=$(find_next_free_index)
    fi
done

echo "Space exhausted or less than $minFreeMB MB free after creating $i files in $dir."
echo "You can now check the $dir folder. Press Enter to exit."
read -r _
