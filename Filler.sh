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

usage() {
    cat <<'EOF'
Usage:
  ./Filler.sh
    Fill the filesystem you're running from (USB mass storage / mounted drive).

  ./Filler.sh --mtp
    Create a local "fill_disk/" payload you can copy to a Kindle over MTP
    (e.g. Paperwhite 12th gen) using OpenMTP.

Options (MTP mode):
  --free-mb <MB>     Free space shown in OpenMTP (in MB)
  --leave-mb <MB>    Free space to leave on Kindle (default: prompt / 20MB)
  --payload-dir <d>  Output folder (default: fill_disk)
EOF
}

MODE="drive"                  # drive|mtp
FREE_MB=""
PAYLOAD_DIR="fill_disk"
LEAVE_MB=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mtp) MODE="mtp"; shift ;;
        --free-mb) FREE_MB="${2:-}"; shift 2 ;;
        --leave-mb) LEAVE_MB="${2:-}"; shift 2 ;;
        --payload-dir) PAYLOAD_DIR="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1"; usage; exit 2 ;;
    esac
done

# Function to get free space in MB on the current filesystem
get_free_mb() {
    df -Pm "$1" | awk 'NR==2 {print $4}'
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
    local n="${size%[GgMm]}"
    case "$size" in
        *[Gg]) dd if=/dev/zero of="$path" bs=1m count=$((n * 1024)) status=none ;;
        *[Mm]) dd if=/dev/zero of="$path" bs=1m count="$n" status=none ;;
        *) dd if=/dev/zero of="$path" bs=1 count="$n" status=none ;;
    esac
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
}

prompt_leave_mb() {
    if [[ -n "$LEAVE_MB" ]]; then
        if [[ "$LEAVE_MB" =~ ^[0-9]+$ ]] && [ "$LEAVE_MB" -gt 0 ]; then
            minFreeMB="$LEAVE_MB"
            return
        fi
        echo "Invalid --leave-mb value. Falling back to menu."
    fi

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
}

run_drive_mode() {
    local dir="fill_disk"
    mkdir -p "$dir"
    local i=0

    prompt_leave_mb

    echo "Filling disk with files. Please wait..."
    local totalFreeMB
    totalFreeMB=$(get_free_mb "$dir")
    local previousFreeMB=-1

    while true; do
        local freeMB
        freeMB=$(get_free_mb "$dir")
        local local_progress=0

        if [ "$previousFreeMB" -ge 0 ]; then
            local last_iteration_progress=$(( previousFreeMB - freeMB ))
            local denominator=$(( totalFreeMB - minFreeMB ))
            if [ "$denominator" -gt 0 ]; then
                local_progress=$(( (last_iteration_progress * 100) / denominator ))
                draw_bar "$local_progress"
            fi
        fi

        local fileSize fileLabel
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

        local filePath="$dir/file_$i"
        create_file "$fileSize" "$filePath"
        if [ ! -f "$filePath" ]; then
            break
        else
            previousFreeMB=$freeMB
            i=$((i+1))
        fi
    done

    printf '\n'
    echo "Space exhausted or less than $minFreeMB MB free after creating $i files in $dir."
    echo "You can now check the $dir folder. Press Enter to exit."
    read -r _
}

run_mtp_mode() {
    local dir="$PAYLOAD_DIR"

    prompt_leave_mb

    if [[ -z "$FREE_MB" ]]; then
        echo "Open OpenMTP, select your Kindle, and note the FREE space it shows."
        read -p "Enter Kindle free space from OpenMTP (in MB): " FREE_MB
    fi

    if ! [[ "$FREE_MB" =~ ^[0-9]+$ ]] || [ "$FREE_MB" -le 0 ]; then
        echo "Invalid --free-mb / input. Please provide Kindle free space in MB (integer)."
        exit 2
    fi

    local fillMB=$(( FREE_MB - minFreeMB ))
    if [ "$fillMB" -le 0 ]; then
        echo "Nothing to do: Kindle free space (${FREE_MB}MB) is already <= leave target (${minFreeMB}MB)."
        exit 0
    fi

    local localFreeMB
    localFreeMB=$(get_free_mb ".")
    if [ "$localFreeMB" -lt "$fillMB" ]; then
        echo "Not enough free space on this computer to generate the payload."
        echo "Need about: ${fillMB}MB, available here: ${localFreeMB}MB"
        exit 2
    fi

    echo "About to create ~${fillMB}MB of filler files in: $dir"
    read -p "Continue? [y/N]: " yn
    case "$yn" in
        [Yy]*) ;;
        *) echo "Cancelled."; exit 0 ;;
    esac

    mkdir -p "$dir"

    echo "Creating local MTP payload..."
    local remainingMB="$fillMB"
    local i=0

    while [ "$remainingMB" -ge 10 ]; do
        local fileSize fileLabel chunkMB
        if [ "$remainingMB" -ge 1024 ]; then
            fileSize=1G; fileLabel="1GB"; chunkMB=1024
        elif [ "$remainingMB" -ge 100 ]; then
            fileSize=100M; fileLabel="100MB"; chunkMB=100
        else
            fileSize=10M; fileLabel="10MB"; chunkMB=10
        fi

        local filePath="$dir/file_$i"
        create_file "$fileSize" "$filePath"
        if [ ! -f "$filePath" ]; then
            echo "Failed creating $fileLabel file at $filePath"
            exit 2
        fi

        remainingMB=$(( remainingMB - chunkMB ))
        i=$((i+1))
    done

    echo "Done. Copy the folder '$dir' to your Kindle using OpenMTP (recommended: into 'documents/')."
    echo "If you still have more free space than desired, re-run --mtp with the updated free space."
}

if [[ "$MODE" == "mtp" ]]; then
    run_mtp_mode
else
    run_drive_mode
fi
