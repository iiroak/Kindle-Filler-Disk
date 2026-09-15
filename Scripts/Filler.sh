#!/bin/bash
# Kindle Disk Filler Utility for Linux/macOS
# Author: iiroak (https://github.com/iiroak)
# Contributors: vinaooo, simoneeti
# This tool fills the disk to prevent automatic updates on tablets
# that have not been registered. Useful for jailbreak preparation.
#
# Supports:
# - Mass Storage (older Kindles mounted as filesystem)
# - MTP protocol (modern Kindles via gio/gvfs, Linux only)
# - macOS (mass storage only, no MTP support)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMP_DIR=""
KINDLE_PATH=""
CONNECTION_TYPE=""
FILE_COUNTER=0
MODE="fill"
dir="fill_disk"

cleanup() {
    # Only remove our local temp scratch. We deliberately do NOT delete
    # fill_disk here: partial fills are safe (the script resumes on the next
    # run) and there is an explicit "remove filler" mode to reclaim space.
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT

# When piped into bash (curl ... | bash), stdin is the script itself.
# Re-point stdin to the terminal so interactive reads work.
[ -t 0 ] || exec < /dev/tty

# --- MTP STORAGE SUBFOLDER DETECTION ---
# MTP devices expose a nested structure: the mount root is NOT writable; it
# contains one or more storage folders (e.g. "Internal Storage",
# "Almacenamiento interno compartido", "SD card"). We must descend into the
# storage folder before writing. Names are localized and vary per device, so we
# use a multilingual preferred list plus generic fallbacks.
MTP_STORAGE_NAMES=(
    "Internal Storage" "Internal shared storage" "Internal storage" "Phone"
    "Almacenamiento interno compartido" "Almacenamiento interno" "Almacenamiento"
    "Espace de stockage interne" "Stockage interne"
    "Interner gemeinsamer Speicher" "Interner Speicher"
    "Memoria interna condivisa" "Memoria interna"
    "Armazenamento interno compartilhado" "Armazenamento interno"
    "Gedeeld intern geheugen" "Interne opslag"
    "SD card" "Tarjeta SD" "Carte SD"
)

# Echoes the storage subfolder URI for an MTP base URI (or the base itself).
mtp_pick_storage() {
    local base="$1"
    base="${base%/}"

    local listing
    listing=$(gio list "$base" 2>/dev/null)
    if [ -z "$listing" ]; then
        echo "$base"
        return
    fi

    # Collect entry names (first tab-delimited field, strip trailing slash).
    local -a entries=()
    local line name
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        name=$(printf '%s' "$line" | cut -f1)
        name="${name%/}"
        [ -z "$name" ] && continue
        entries+=("$name")
    done <<< "$listing"

    if [ "${#entries[@]}" -eq 0 ]; then
        echo "$base"
        return
    fi

    # Single entry: use it.
    if [ "${#entries[@]}" -eq 1 ]; then
        echo "${base}/${entries[0]}"
        return
    fi

    # Prefer a known storage name (exact match).
    local k e
    for k in "${MTP_STORAGE_NAMES[@]}"; do
        for e in "${entries[@]}"; do
            if [ "$e" = "$k" ]; then
                echo "${base}/${e}"
                return
            fi
        done
    done

    # Heuristic keyword match.
    for e in "${entries[@]}"; do
        if printf '%s' "$e" | grep -qiE 'intern|shared|storage|almacen|stockage|speicher|memoria|armazen|opslag'; then
            echo "${base}/${e}"
            return
        fi
    done

    # Fallback: first entry.
    echo "${base}/${entries[0]}"
}

# Filesystem variant of mtp_pick_storage for gvfs fuse mount paths.
fs_pick_storage() {
    local base="$1"
    base="${base%/}"
    local -a dirs=()
    local d name
    for d in "$base"/*/; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        dirs+=("$name")
    done
    if [ "${#dirs[@]}" -eq 0 ]; then echo "$base"; return; fi
    if [ "${#dirs[@]}" -eq 1 ]; then echo "${base}/${dirs[0]}"; return; fi
    local k e
    for k in "${MTP_STORAGE_NAMES[@]}"; do
        for e in "${dirs[@]}"; do
            [ "$e" = "$k" ] && { echo "${base}/${e}"; return; }
        done
    done
    for e in "${dirs[@]}"; do
        if printf '%s' "$e" | grep -qiE 'intern|shared|storage|almacen|stockage|speicher|memoria|armazen|opslag'; then
            echo "${base}/${e}"; return
        fi
    done
    echo "${base}/${dirs[0]}"
}

# --- PRE-BUILT ZIP FALLBACK (last resort) ---
# When the per-file fill method fails entirely, we can download a pre-built
# archive of zero-filled files (bundled in the repo's Zips/ folder) and copy its
# contents onto the device. The archives hold ~8/16/32/64 GB of data but are
# only a few MB to download (zeros compress ~1000:1).
ZIP_BASE_URL="https://github.com/iiroak/Kindle-Filler-Disk/raw/main/Zips"

choose_zip_bucket() {
    # Pick the largest bucket (GB) that fits in the given free MB.
    local free_mb="$1"
    local free_gb=$((free_mb / 1024))
    if   [ "$free_gb" -ge 64 ]; then echo 64
    elif [ "$free_gb" -ge 32 ]; then echo 32
    elif [ "$free_gb" -ge 16 ]; then echo 16
    else echo 8
    fi
}

zip_fallback() {
    local free_mb="$1"

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        echo "[!] Need 'curl' or 'wget' for the zip fallback."; return 1
    fi
    if ! command -v unzip >/dev/null 2>&1; then
        echo "[!] Need 'unzip' for the zip fallback (install: apt/dnf/pacman install unzip)."; return 1
    fi

    local bucket
    if [ -n "$free_mb" ] && [ "$free_mb" -gt 0 ] 2>/dev/null; then
        bucket=$(choose_zip_bucket "$free_mb")
        echo "[*] Detected ~$((free_mb / 1024)) GB free -> using fill_${bucket}gb.zip"
    else
        echo "  What is your Kindle's storage size?"
        echo "    [1] 8 GB   [2] 16 GB   [3] 32 GB   [4] 64 GB"
        read -p "  Choice (1-4) [1]: " zc
        case "$zc" in 2) bucket=16;; 3) bucket=32;; 4) bucket=64;; *) bucket=8;; esac
    fi

    local zip="fill_${bucket}gb.zip"
    local url="$ZIP_BASE_URL/$zip"
    local tmpzip="${TEMP_DIR:-/tmp}/kindle_${zip}"

    echo "[*] Downloading $zip ..."
    if command -v curl >/dev/null 2>&1; then
        curl -fSL -o "$tmpzip" "$url" || { echo "[!] Download failed."; return 1; }
    else
        wget -O "$tmpzip" "$url" || { echo "[!] Download failed."; return 1; }
    fi

    case "$CONNECTION_TYPE" in
        mass_storage)
            echo "[*] Extracting into $KINDLE_PATH/$dir ..."
            mkdir -p "$KINDLE_PATH/$dir"
            unzip -o "$tmpzip" -d "$KINDLE_PATH/$dir"
            ;;
        mtp)
            # Stream one entry at a time to avoid needing GBs of local scratch.
            gio mkdir "$KINDLE_PATH/$dir" 2>/dev/null || true
            local scratch="${TEMP_DIR:-/tmp}"
            local entry bn
            while IFS= read -r entry; do
                [ -z "$entry" ] && continue
                case "$entry" in */) continue;; esac   # skip directory entries
                bn=$(basename "$entry")
                echo "  [zip] copying $bn ..."
                unzip -p "$tmpzip" "$entry" > "$scratch/$bn" 2>/dev/null
                gio copy "$scratch/$bn" "$KINDLE_PATH/$dir/$bn" 2>/dev/null || echo "    [!] copy failed: $bn"
                rm -f "$scratch/$bn"
            done < <(unzip -Z1 "$tmpzip")
            ;;
    esac

    rm -f "$tmpzip"
    echo "[OK] Zip fallback complete."
    return 0
}

echo ""
echo "  +=============================================================+"
echo "  |           Kindle Disk Filler Utility v2.1                   |"
echo "  +=============================================================+"
echo "  |  Fills disk to prevent auto-updates on unregistered         |"
echo "  |  tablets. Useful for jailbreak preparation.                 |"
echo "  +=============================================================+"
echo ""

# --- DETECT KINDLE DEVICE ---
detect_kindle() {
    echo "[*] Detecting Kindle device..."

    if [ "$(uname)" = "Darwin" ]; then
        # macOS: only mass storage, no MTP support
        local kindle_mount=$(ls /Volumes/ 2>/dev/null | grep -i "kindle" | head -1)
        if [ -n "$kindle_mount" ]; then
            KINDLE_PATH="/Volumes/$kindle_mount"
            CONNECTION_TYPE="mass_storage"
            return 0
        fi
        return 1
    fi

    # Linux: try mass storage first (faster, direct filesystem)
    local kindle_mount=$(findmnt -rn -o TARGET -S LABEL=Kindle 2>/dev/null | head -1)
    if [ -n "$kindle_mount" ]; then
        KINDLE_PATH="$kindle_mount"
        CONNECTION_TYPE="mass_storage"
        return 0
    fi

    # Linux: try MTP via gio (modern Kindles)
    if command -v gio >/dev/null 2>&1; then
        local mtp_uri=$(gio mount -l 2>/dev/null | grep -i "kindle" | grep -o 'mtp://[^ ]*' | head -1)
        if [ -n "$mtp_uri" ]; then
            # Normalize URI (remove trailing slash)
            mtp_uri="${mtp_uri%/}"
            # Descend into the writable storage subfolder (localized names vary)
            KINDLE_PATH="$(mtp_pick_storage "$mtp_uri")"
            CONNECTION_TYPE="mtp"
            return 0
        fi

        # Try auto-mounting MTP device
        gio mount -d 2>/dev/null | grep -i "kindle" >/dev/null 2>&1 && sleep 1
        mtp_uri=$(gio mount -l 2>/dev/null | grep -i "kindle" | grep -o 'mtp://[^ ]*' | head -1)
        if [ -n "$mtp_uri" ]; then
            mtp_uri="${mtp_uri%/}"
            KINDLE_PATH="$(mtp_pick_storage "$mtp_uri")"
            CONNECTION_TYPE="mtp"
            return 0
        fi
    fi

    # Linux: try gvfs fallback path
    local gvfs_path="/run/user/$(id -u)/gvfs"
    if [ -d "$gvfs_path" ]; then
        local kindle_gvfs=$(find "$gvfs_path" -maxdepth 2 -iname "*kindle*" -type d 2>/dev/null | head -1)
        if [ -n "$kindle_gvfs" ]; then
            KINDLE_PATH="$(fs_pick_storage "$kindle_gvfs")"
            CONNECTION_TYPE="mtp"
            return 0
        fi
    fi

    return 1
}

# --- MANUAL DEVICE SELECTION ---
pick_device_manual() {
    echo ""
    echo "[*] No Kindle found. Listing all available devices..."
    echo ""

    local devices=()
    local idx=1

    # List mounted drives (mass storage)
    if [ "$(uname)" = "Darwin" ]; then
        for vol in /Volumes/*/; do
            local name=$(basename "$vol")
            [ "$name" = "Macintosh HD" ] && continue
            devices+=("mass_storage|$vol|$name")
            printf "  [%d] %s (mass storage: %s)\n" "$idx" "$name" "$vol"
            idx=$((idx + 1))
        done
    else
        while IFS= read -r line; do
            local target=$(echo "$line" | awk '{print $1}')
            local source=$(echo "$line" | awk '{print $2}')
            local label=$(echo "$line" | awk '{print $3}')
            [ -z "$label" ] && label="$(basename "$target")"
            # Skip root, boot, system mounts
            [[ "$target" == "/" ]] && continue
            [[ "$target" == /boot* ]] && continue
            [[ "$target" == /sys* ]] && continue
            [[ "$target" == /proc* ]] && continue
            [[ "$target" == /dev* ]] && continue
            [[ "$source" == /dev/loop* ]] && continue
            devices+=("mass_storage|$target|$label")
            printf "  [%d] %s (mass storage: %s)\n" "$idx" "$label" "$target"
            idx=$((idx + 1))
        done < <(findmnt -rn -o TARGET,SOURCE,LABEL 2>/dev/null | grep -v "tmpfs\|devtmpfs\|squashfs")
    fi

    # List MTP devices via gio
    if command -v gio >/dev/null 2>&1; then
        while IFS= read -r line; do
            local uri=$(echo "$line" | grep -o 'mtp://[^ ]*' | sed 's|/$||')
            [ -z "$uri" ] && continue
            local name=$(echo "$line" | sed 's|.*→ *||' | sed 's| *$||')
            [ -z "$name" ] && name="$uri"
            devices+=("mtp|$uri|$name")
            printf "  [%d] %s (MTP: %s)\n" "$idx" "$name" "$uri"
            idx=$((idx + 1))
        done < <(gio mount -l 2>/dev/null | grep "mtp://")
    fi

    if [ ${#devices[@]} -eq 0 ]; then
        echo "    No devices found."
        return 1
    fi

    echo ""
    read -p "  Select device (1-$((idx-1))): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$idx" ]; then
        local selected="${devices[$((choice-1))]}"
        CONNECTION_TYPE=$(echo "$selected" | cut -d'|' -f1)
        local path=$(echo "$selected" | cut -d'|' -f2)

        if [ "$CONNECTION_TYPE" = "mtp" ]; then
            # Descend into the writable storage subfolder (localized names vary)
            KINDLE_PATH="$(mtp_pick_storage "$path")"
        else
            if is_dangerous_path "$path"; then
                echo "[!] Refusing to use '$path' — it looks like a system or"
                echo "    home path. This protects your computer from being"
                echo "    filled up by accident. Pick a real Kindle volume."
                return 1
            fi
            KINDLE_PATH="$path"
        fi
        return 0
    fi

    echo "    Invalid selection."
    return 1
}

# --- FREE SPACE ---
get_free_mb() {
    case "$CONNECTION_TYPE" in
        mass_storage)
            df -Pm "$KINDLE_PATH" 2>/dev/null | awk 'NR==2 {print $4}'
            ;;
        mtp)
            # filesystem::free is a mount-wide attribute; query it directly on
            # the storage path (works regardless of localized folder name).
            local free_bytes
            free_bytes=$(gio info -a "filesystem::free" "$KINDLE_PATH" 2>/dev/null | awk -F': ' '/filesystem::free/ {print $2}' | tr -d ' ')
            if [ -n "$free_bytes" ] && [ "$free_bytes" -gt 0 ] 2>/dev/null; then
                echo $((free_bytes / 1024 / 1024))
            else
                echo ""
            fi
            ;;
    esac
}

# --- FILE CREATION ---
create_file() {
    local size="$1" path="$2"
    # Normalize to MB for dd (works on all platforms)
    local mb_size
    if [[ "$size" == *G ]]; then
        mb_size=$((${size%G} * 1024))
    elif [[ "$size" == *M ]]; then
        mb_size=${size%M}
    else
        mb_size=$((size / 1024 / 1024))
    fi
    [ "$mb_size" -lt 1 ] && mb_size=1

    if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "${mb_size}M" "$path" 2>/dev/null && return 0
    fi
    if command -v truncate >/dev/null 2>&1; then
        # macOS-compatible: instant sparse file
        truncate -s "${mb_size}M" "$path" 2>/dev/null && return 0
    fi
    if command -v mkfile >/dev/null 2>&1; then
        mkfile "${mb_size}m" "$path" 2>/dev/null && return 0
    fi
    dd if=/dev/zero of="$path" bs=1M count="$mb_size" status=none 2>/dev/null
}

create_file_mtp() {
    local size="$1" dest_path="$2"
    local tmp_file="${TEMP_DIR}/file_${FILE_COUNTER}"

    create_file "$size" "$tmp_file"

    if [ ! -f "$tmp_file" ]; then
        echo "[!] Failed to create temporary file"
        return 1
    fi

    if gio copy "$tmp_file" "$dest_path" 2>/dev/null; then
        rm -f "$tmp_file"
        return 0
    else
        rm -f "$tmp_file"
        return 1
    fi
}

# --- PROGRESS BAR ---
render_progress() {
    local percent=$1 status=$2 detail=$3
    local width=32
    local filled=$(( percent * width / 100 ))
    local empty=$(( width - filled ))
    local bar empty_bar
    bar=$(printf '%*s' "$filled" '' | tr ' ' '=')
    empty_bar=$(printf '%*s' "$empty" '' | tr ' ' '-')
    printf '\r\033[2K  [%s%s] %3d%%  %s%s' "$bar" "$empty_bar" "$percent" "$status" "$detail"
}

# --- SAFETY: refuse to write to system / home paths ---
is_dangerous_path() {
    local p="${1%/}"
    [ -z "$p" ] && return 0
    case "$p" in
        "/"|"/root"|"/home"|"/usr"|"/etc"|"/var"|"/boot"|"/opt"|"/bin"|"/sbin"|\
        "/lib"|"/lib64"|"/tmp"|"/mnt"|"/media"|"/run"|"/srv"|"/sys"|"/proc"|"/dev"|\
        "/System"|"/Applications"|"/Users"|"/Library")
            return 0 ;;
    esac
    # Equal to or inside the user's home (Desktop/Downloads/Documents/...)
    if [ -n "$HOME" ]; then
        [ "$p" = "${HOME%/}" ] && return 0
        case "$p" in "${HOME%/}"/*) return 0 ;; esac
    fi
    [ "$p" = "/Volumes/Macintosh HD" ] && return 0
    return 1
}

# --- Yes/No confirmation ---
confirm() {
    local ans
    read -p "$1 [y/N]: " ans
    case "$ans" in y|Y|s|S) return 0 ;; *) return 1 ;; esac
}

# --- REMOVE FILLER (cleanup mode) with before/after free space ---
remove_filler() {
    local before after
    before=$(get_free_mb)
    echo ""
    echo "[*] Free space before: ${before:-unknown} MB"
    echo "[*] Removing '$dir' from the device..."

    case "$CONNECTION_TYPE" in
        mass_storage)
            if [ -d "$KINDLE_PATH/$dir" ]; then
                rm -rf "$KINDLE_PATH/$dir" && echo "[OK] Removed $KINDLE_PATH/$dir"
            else
                echo "[!] No '$dir' folder found at $KINDLE_PATH"
            fi
            if [ "$(uname)" = "Darwin" ]; then
                echo "[i] macOS: also empty the Trash on the Kindle volume"
                echo "    (a hidden .Trashes folder can keep the space used)."
            fi
            ;;
        mtp)
            local target="$KINDLE_PATH/$dir"
            if gio info "$target" >/dev/null 2>&1; then
                local f fn
                while IFS= read -r f; do
                    [ -z "$f" ] && continue
                    fn=$(printf '%s' "$f" | cut -f1); fn="${fn%/}"
                    [ -z "$fn" ] && continue
                    gio remove "$target/$fn" 2>/dev/null || gio trash "$target/$fn" 2>/dev/null
                done < <(gio list "$target" 2>/dev/null)
                gio remove "$target" 2>/dev/null || gio trash "$target" 2>/dev/null
                echo "[OK] Removed '$dir' via MTP"
            else
                echo "[!] No '$dir' folder found on the device."
            fi
            ;;
    esac

    after=$(get_free_mb)
    echo "[*] Free space after:  ${after:-unknown} MB"
    echo ""
    echo "[i] If the Kindle still reports 'storage full', disconnect it,"
    echo "    reconnect the USB cable, and reboot the Kindle."
}

# --- MODE SELECTION ---
echo "What do you want to do?"
echo "  [1] Fill the device (block OTA updates)   [default]"
echo "  [2] Remove filler files (free up space again)"
echo ""
read -p "  Choice (1-2) [1]: " modechoice
case "$modechoice" in 2) MODE="remove" ;; *) MODE="fill" ;; esac
echo ""

# --- DETECT ---
if ! detect_kindle; then
    if ! pick_device_manual; then
        echo ""
        echo "[!] No devices available."
        echo ""
        echo "    If your Kindle uses MTP (newer models), install 'gvfs':"
        echo "    Ubuntu/Debian:  sudo apt install gvfs gvfs-backends"
        echo "    Fedora:         sudo dnf install gvfs gvfs-mtp"
        echo "    Arch:           sudo pacman -S gvfs gvfs-mtp"
        echo ""
        read -p "Press Enter to exit..." _
        exit 1
    fi
fi

echo "[OK] Device selected"
echo "     Connection type: $CONNECTION_TYPE"
echo "     Path: $KINDLE_PATH"

# --- VALIDATE DIRECTORY ---
if [ "$CONNECTION_TYPE" = "mass_storage" ]; then
    if [ ! -d "$KINDLE_PATH" ]; then
        echo "[!] Error: Kindle path $KINDLE_PATH is not accessible."
        read -p "Press Enter to exit..." _
        exit 1
    fi
    # Verify it's writable
    if ! touch "$KINDLE_PATH/.test_write" 2>/dev/null; then
        echo "[!] Error: Cannot write to $KINDLE_PATH. Check permissions."
        read -p "Press Enter to exit..." _
        exit 1
    fi
    rm -f "$KINDLE_PATH/.test_write"
elif [ "$CONNECTION_TYPE" = "mtp" ]; then
    if ! gio info "$KINDLE_PATH" >/dev/null 2>&1; then
        echo "[!] Error: Cannot access Kindle via MTP at $KINDLE_PATH"
        echo "    Try disconnecting and reconnecting your Kindle."
        read -p "Press Enter to exit..." _
        exit 1
    fi
    TEMP_DIR="/tmp/kindle_filler_$$"
    mkdir -p "$TEMP_DIR"
fi

# --- REMOVE MODE: reclaim space and exit ---
if [ "$MODE" = "remove" ]; then
    remove_filler
    read -p "Press Enter to exit..." _
    exit 0
fi

echo ""

# --- CREATE DIRECTORY ON KINDLE ---
echo "[*] Preparing fill_disk directory on Kindle..."

case "$CONNECTION_TYPE" in
    mass_storage)
        if mkdir -p "$KINDLE_PATH/$dir" 2>/dev/null; then
            echo "[OK] Directory ready: $KINDLE_PATH/$dir"
        elif [ -d "$KINDLE_PATH/$dir" ]; then
            echo "[OK] Directory already exists: $KINDLE_PATH/$dir"
        else
            echo "[!] Warning: Could not create directory, but continuing..."
        fi
        ;;
    mtp)
        # Check if directory already exists (match first field, strip trailing /)
        if gio list "$KINDLE_PATH" 2>/dev/null | cut -f1 | sed 's|/$||' | grep -qx "$dir"; then
            echo "[OK] Directory already exists on Kindle"
        elif gio mkdir "$KINDLE_PATH/$dir" 2>/dev/null; then
            echo "[OK] Directory created on Kindle via MTP"
        else
            echo "[!] Warning: Could not create directory via MTP, but continuing..."
        fi
        ;;
esac

echo ""

# --- GET FREE SPACE ---
initialFreeMB=$(get_free_mb)
if [ -z "$initialFreeMB" ] || [ "$initialFreeMB" -le 0 ] 2>/dev/null; then
    echo "[!] Error: Cannot determine free space on Kindle."
    echo "    This may be a temporary MTP connection issue."
    echo "    Try disconnecting and reconnecting your Kindle."
    read -p "Press Enter to exit..." _
    exit 1
fi

echo "[OK] Available space: ${initialFreeMB} MB"

# --- USER INPUT ---
echo ""
echo "How much free space (in MB) do you want to LEAVE on the device?"
echo "  Leaving very little space blocks OTA updates more reliably, but the"
echo "  Kindle may show repeated 'storage almost full' notifications and can"
echo "  be uncomfortable for daily reading."
echo ""
echo "  [1] 20 MB  - aggressive OTA block (may cause notifications) [default]"
echo "  [2] 50 MB  - balanced"
echo "  [3] 100 MB - daily use (fewer notifications, still blocks most OTA)"
echo "  [4] Custom value"
echo ""
read -p "  Enter your choice (1-4) [1]: " choice

case "$choice" in
    2) minFreeMB=50 ;;
    3) minFreeMB=100 ;;
    4)
        read -p "  Enter the minimum free space in MB (e.g., 30): " custom
        if [[ "$custom" =~ ^[0-9]+$ ]] && [ "$custom" -gt 0 ]; then
            minFreeMB=$custom
        else
            echo "Invalid input. Using default (20 MB)."
            minFreeMB=20
        fi
        ;;
    *) minFreeMB=20 ;;
esac

targetFillMB=$((initialFreeMB - minFreeMB))
if [ "$targetFillMB" -le 0 ]; then
    echo "[!] The requested free space ($minFreeMB MB) is >= current free space ($initialFreeMB MB)."
    echo "    Nothing to do."
    read -p "Press Enter to exit..." _
    exit 0
fi

echo ""
echo "  +--- Please confirm --------------------------------------+"
echo "    Destination : $KINDLE_PATH/$dir"
echo "    Connection  : $CONNECTION_TYPE"
echo "    Free now    : ${initialFreeMB} MB"
echo "    Will fill   : ~${targetFillMB} MB  (leaving ${minFreeMB} MB free)"
echo "  +---------------------------------------------------------+"
if ! confirm "  Proceed with filling this device?"; then
    echo "[!] Cancelled by user. Nothing was written."
    read -p "Press Enter to exit..." _
    exit 0
fi

echo ""
echo "[>] Starting disk fill process..."
echo "    Target: fill ~${targetFillMB} MB, leave ${minFreeMB} MB free"
echo "    Mode: $CONNECTION_TYPE"
echo ""

# --- MAIN LOOP ---
while true; do
    freeMB=$(get_free_mb)
    [ -z "$freeMB" ] && break
    fillableMB=$((freeMB - minFreeMB))
    [ "$fillableMB" -le 0 ] && break

    # Determine file size.
    # Use uniform 100 MB files as the primary chunk so that freeing space later is
    # granular: deleting ONE file frees exactly 100 MB (enough for a book/document)
    # while the device stays nearly full and OTA updates remain blocked.
    # Only the final tail uses 50/10/1 MB to land exactly on the requested free space.
    if [ "$fillableMB" -ge 100 ]; then
        fileSize=100M
    elif [ "$fillableMB" -ge 50 ]; then
        fileSize=50M
    elif [ "$fillableMB" -ge 10 ]; then
        fileSize=10M
    elif [ "$fillableMB" -ge 1 ]; then
        fileSize=1M
    else
        fileSize="${fillableMB}M"
    fi

    # Progress
    usedMB=$((initialFreeMB - freeMB))
    percent=$((usedMB * 100 / targetFillMB))
    [ "$percent" -gt 100 ] && percent=100
    [ "$percent" -lt 0 ] && percent=0
    render_progress "$percent" "Creating: " "file_${FILE_COUNTER} ($fileSize)"

    # Create file
    case "$CONNECTION_TYPE" in
        mass_storage)
            create_file "$fileSize" "$KINDLE_PATH/$dir/file_${FILE_COUNTER}"
            if [ ! -f "$KINDLE_PATH/$dir/file_${FILE_COUNTER}" ]; then
                break
            fi
            ;;
        mtp)
            if ! create_file_mtp "$fileSize" "$KINDLE_PATH/$dir/file_${FILE_COUNTER}"; then
                echo ""
                echo "[!] Write failed. Storage might be completely full."
                break
            fi
            ;;
    esac

    FILE_COUNTER=$((FILE_COUNTER + 1))

    # Update progress
    freeMB=$(get_free_mb)
    [ -z "$freeMB" ] && break
    usedMB=$((initialFreeMB - freeMB))
    percent=$((usedMB * 100 / targetFillMB))
    [ "$percent" -gt 100 ] && percent=100
    [ "$percent" -lt 0 ] && percent=0

    remainingLabel="${freeMB} MB"
    [ "$freeMB" -ge 1024 ] && remainingLabel="$(awk "BEGIN {printf \"%.1f\", $freeMB/1024}") GB"

    render_progress "$percent" "Done:     " "file_$((FILE_COUNTER-1)) | Free: $remainingLabel"

    # Small delay for MTP to prevent overwhelming the connection
    [ "$CONNECTION_TYPE" = "mtp" ] && sleep 0.3
done

# --- ZIP FALLBACK (last resort) ---
# If the per-file method wrote nothing, offer the pre-built archive approach.
if [ "$FILE_COUNTER" -eq 0 ]; then
    printf '\n'
    echo "[!] The per-file fill method did not write any files."
    echo "    Last resort: download a pre-built filler archive and copy it to the device."
    read -p "  Try the pre-built zip fallback? (y/N): " usezip
    case "$usezip" in
        y|Y|s|S)
            zip_fallback "$initialFreeMB" && FILE_COUNTER=-1  # -1 = filled via zip
            ;;
    esac
fi

# --- DONE ---
printf '\n'
echo "  +---------------------------------------------------------+"
echo "  |  Disk fill complete!                                    |"
if [ "$FILE_COUNTER" -eq -1 ]; then
    echo "  |  Filled via pre-built zip archive"
else
    echo "  |  Files created: $FILE_COUNTER"
fi
echo "  |  Connection: $CONNECTION_TYPE"
if [ "$CONNECTION_TYPE" = "mass_storage" ]; then
    echo "  |  Directory: $KINDLE_PATH/$dir"
else
    echo "  |  Directory: $KINDLE_PATH/$dir"
    echo "  |  (files transferred via MTP)"
fi
echo "  +---------------------------------------------------------+"
echo ""
read -p "Press Enter to exit..." _
