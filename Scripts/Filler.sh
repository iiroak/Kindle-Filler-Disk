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

set -eE

TEMP_DIR=""
KINDLE_PATH=""
CONNECTION_TYPE=""
DEVICE_FIXED=0      # 1 = not known to be removable/external
FILE_COUNTER=0      # next file_N index to use
WROTE_COUNT=0       # Files actually written in this run
WRITTEN_MB=0        # MB written in this run
FILL_FAILED=0       # 1 = loop stopped because of an error
MTP_LAST_ERROR=""
ZIP_COPIED=0
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

# Wait for Enter without tripping "set -e" when stdin is closed.
pause() {
    local _
    read -r -p "Press Enter to exit..." _ || true
}

# Global safety net. If a command fails where we did not expect it,
# say so (with the line number) instead of closing silently.
on_unexpected_error() {
    local code=$? line="$1"
    printf '\n[!] Unexpected error (exit code %s) at line %s.\n' "$code" "$line"
    pause
}
trap 'on_unexpected_error $LINENO' ERR

# Private, unpredictable temp dir (works for both connection types).
ensure_temp_dir() {
    if [ -z "$TEMP_DIR" ] || [ ! -d "$TEMP_DIR" ]; then
        TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kindle_filler.XXXXXX")
    fi
}

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
    listing=$(gio list "$base" 2>/dev/null) || listing=""
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
            if [ "$e" = "$k" ]; then echo "${base}/${e}"; return; fi
        done
    done
    for e in "${dirs[@]}"; do
        if printf '%s' "$e" | grep -qiE 'intern|shared|storage|almacen|stockage|speicher|memoria|armazen|opslag'; then
            echo "${base}/${e}"; return
        fi
    done
    echo "${base}/${dirs[0]}"
}

# True if a URI exists on the MTP device.
mtp_exists() {
    gio info "$1" >/dev/null 2>&1
}

# --- PRE-BUILT ZIP FALLBACK (last resort) ---
# When the per-file fill method fails entirely, we can download a pre-built
# archive of zero-filled files (bundled in the repo's Zips/ folder) and copy its
# contents onto the device. The archives hold ~8/16/32/64 GB of data but are
# only a few MB to download (zeros compress ~1000:1).
ZIP_BASE_URL="https://github.com/iiroak/Kindle-Filler-Disk/raw/main/Zips"

choose_zip_bucket() {
    # Pick the SMALLEST bucket (GB) that covers the free space.
    local free_mb="$1"
    if   [ "$free_mb" -le 8192 ];  then echo 8
    elif [ "$free_mb" -le 16384 ]; then echo 16
    elif [ "$free_mb" -le 32768 ]; then echo 32
    else echo 64
    fi
}

# Sets ZIP_COPIED. Returns 0 only if at least one file was written and nothing failed.
zip_fallback() {
    local free_mb="$1"
    ZIP_COPIED=0

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        echo "[!] Need 'curl' or 'wget' for the zip fallback."; return 1
    fi
    if ! command -v unzip >/dev/null 2>&1; then
        echo "[!] Need 'unzip' for the zip fallback (install: apt/dnf/pacman install unzip)."; return 1
    fi

    local bucket zc free_known=0
    if [ -n "$free_mb" ] && [ "$free_mb" -gt 0 ] 2>/dev/null; then
        free_known=1
        bucket=$(choose_zip_bucket "$free_mb")
        echo "[*] Detected ~$((free_mb / 1024)) GB free -> using fill_${bucket}gb.zip"
        if [ "$free_mb" -gt 65536 ]; then
            echo "[!] More than 64 GB free: the largest archive will not fill the device completely."
        fi
    else
        echo "  What is your Kindle's storage size?"
        echo "    [1] 8 GB   [2] 16 GB   [3] 32 GB   [4] 64 GB"
        read -r -p "  Choice (1-4) [1]: " zc || zc=""
        case "$zc" in 2) bucket=16;; 3) bucket=32;; 4) bucket=64;; *) bucket=8;; esac
    fi

    # Always work inside our own temp dir so the EXIT trap cleans up.
    ensure_temp_dir
    local zip="fill_${bucket}gb.zip"
    local url="$ZIP_BASE_URL/$zip"
    local tmpzip="$TEMP_DIR/kindle_${zip}"

    echo "[*] Downloading $zip ..."
    if command -v curl >/dev/null 2>&1; then
        curl -fSL -o "$tmpzip" "$url" || { echo "[!] Download failed."; return 1; }
    else
        wget -O "$tmpzip" "$url" || { echo "[!] Download failed."; return 1; }
    fi

    # Go entry by entry. Before each entry, check that it still fits while
    # leaving the requested free space, skip files that are already there,
    # and count what was really written.
    local keep_mb="${minFreeMB:-0}"
    local copied=0 failed=0 skipped=0
    local entry bn bytes size_mb now_free est_free="$free_mb" dest

    case "$CONNECTION_TYPE" in
        mass_storage)
            if ! mkdir -p "$KINDLE_PATH/$dir" 2>/dev/null; then
                echo "[!] Cannot create $KINDLE_PATH/$dir"; rm -f "$tmpzip"; return 1
            fi ;;
        mtp)
            if ! mtp_exists "$KINDLE_PATH/$dir"; then
                gio mkdir "$KINDLE_PATH/$dir" 2>/dev/null || true
            fi ;;
    esac

    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        case "$entry" in */) continue;; esac   # skip directory entries
        bn=$(basename "$entry")
        bytes=$(unzip -l "$tmpzip" "$entry" 2>/dev/null | awk 'NR==4 {print $1}') || bytes=""
        case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
        size_mb=$(( (bytes + 1048575) / 1048576 ))

        if [ "$CONNECTION_TYPE" = "mass_storage" ]; then
            dest="$KINDLE_PATH/$dir/$bn"
            if [ -e "$dest" ]; then continue; fi           # already there
            if [ "$free_known" -eq 1 ]; then
                now_free=$(get_free_mb) || now_free=""
                if [ -n "$now_free" ] && [ $((now_free - size_mb)) -lt "$keep_mb" ]; then
                    skipped=$((skipped + 1)); continue
                fi
            fi
            echo "  [zip] extracting $bn ..."
            if unzip -p "$tmpzip" "$entry" > "$dest" 2>/dev/null; then
                copied=$((copied + 1))
            else
                echo "    [!] extraction failed: $bn (device full?)"
                rm -f "$dest"                               # partial file
                failed=$((failed + 1))
                break
            fi
        else
            dest="$KINDLE_PATH/$dir/$bn"
            if mtp_exists "$dest"; then continue; fi        # already there
            if [ "$free_known" -eq 1 ] && [ $((est_free - size_mb)) -lt "$keep_mb" ]; then
                skipped=$((skipped + 1)); continue
            fi
            echo "  [zip] copying $bn ..."
            if unzip -p "$tmpzip" "$entry" > "$TEMP_DIR/$bn" 2>/dev/null \
               && MTP_LAST_ERROR=$(gio copy "$TEMP_DIR/$bn" "$dest" 2>&1); then
                copied=$((copied + 1))
                est_free=$((est_free - size_mb))
                rm -f "$TEMP_DIR/$bn"
            else
                echo "    [!] copy failed: $bn ${MTP_LAST_ERROR:+($MTP_LAST_ERROR)}"
                rm -f "$TEMP_DIR/$bn"
                failed=$((failed + 1))
                break
            fi
        fi
    done < <(unzip -Z1 "$tmpzip" 2>/dev/null)

    rm -f "$tmpzip"
    ZIP_COPIED=$copied

    if [ "$copied" -gt 0 ] && [ "$failed" -eq 0 ]; then
        echo "[OK] Zip fallback complete: $copied file(s) written, $skipped skipped to keep the requested free space."
        return 0
    elif [ "$copied" -gt 0 ]; then
        echo "[!] Zip fallback stopped early: $copied file(s) written, $failed failed."
        return 1
    fi
    echo "[!] Zip fallback wrote nothing."
    return 1
}

echo ""
echo "  +=============================================================+"
echo "  |           Kindle Disk Filler Utility v2.2                   |"
echo "  +=============================================================+"
echo "  |  Fills disk to prevent auto-updates on unregistered         |"
echo "  |  tablets. Useful for jailbreak preparation.                 |"
echo "  +=============================================================+"
echo ""

# findmnt -r escapes spaces etc. as \x20; turn them back into real
# characters so paths with spaces work.
decode_mnt() {
    printf '%b' "$1"
}

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
        KINDLE_PATH="$(decode_mnt "$kindle_mount")"
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

# Is this mount KNOWN to be a removable/external device?
# Returns 0 only on a positive answer; "unknown" counts as not removable.
is_removable_path() {
    local p="$1" src flags
    if [ "$(uname)" = "Darwin" ]; then
        if diskutil info "$p" 2>/dev/null | grep -Eq 'Device Location: +External|Removable Media: +(Removable|Yes)|Protocol: +USB'; then
            return 0
        fi
        return 1
    fi
    src=$(findmnt -rn -o SOURCE --target "$p" 2>/dev/null | head -1)
    src="${src%%\[*}"                       # strip btrfs "[/subvol]" suffix
    if [ -z "$src" ] || ! command -v lsblk >/dev/null 2>&1; then
        return 1
    fi
    flags=$(lsblk -ndo RM,HOTPLUG "$src" 2>/dev/null | head -1)
    case "$flags" in *1*) return 0 ;; esac
    return 1
}

# True for the macOS boot/data volume (matched by device, not by name).
is_macos_system_volume() {
    local d r data
    d=$(df -P "$1" 2>/dev/null | awk 'NR==2 {print $1}')
    r=$(df -P / 2>/dev/null | awk 'NR==2 {print $1}')
    data=$(df -P /System/Volumes/Data 2>/dev/null | awk 'NR==2 {print $1}')
    if [ -n "$d" ] && { [ "$d" = "$r" ] || [ "$d" = "$data" ]; }; then
        return 0
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
    local fixed tag

    # List mounted drives (mass storage)
    if [ "$(uname)" = "Darwin" ]; then
        for vol in /Volumes/*/; do
            [ -d "$vol" ] || continue
            vol="${vol%/}"
            local name=$(basename "$vol")
            [ "$name" = "Macintosh HD" ] && continue
            # Skip the boot volume whatever it is called
            if is_macos_system_volume "$vol" || is_dangerous_path "$vol"; then continue; fi
            if is_removable_path "$vol"; then fixed=0; tag=""; else fixed=1; tag="  [!] NOT A REMOVABLE DEVICE"; fi
            devices+=("mass_storage|$vol|$name|$fixed")
            printf "  [%d] %s (mass storage: %s)%s\n" "$idx" "$name" "$vol" "$tag"
            idx=$((idx + 1))
        done
    else
        while IFS= read -r line; do
            local target=$(echo "$line" | awk '{print $1}')
            local source=$(echo "$line" | awk '{print $2}')
            local label=$(echo "$line" | awk '{print $3}')
            # Decode \x20-style escapes from findmnt -r
            target="$(decode_mnt "$target")"
            label="$(decode_mnt "$label")"
            [ -z "$label" ] && label="$(basename "$target")"
            # Only real block devices (drops /run, fuse, cgroup, ...)
            [[ "$source" == /dev/* ]] || continue
            # Skip root, boot, system mounts
            [[ "$target" == "/" ]] && continue
            [[ "$target" == /boot* ]] && continue
            [[ "$target" == /sys* ]] && continue
            [[ "$target" == /proc* ]] && continue
            [[ "$target" == /dev* ]] && continue
            [[ "$source" == /dev/loop* ]] && continue
            # Do not even list paths we would refuse anyway
            if is_dangerous_path "$target"; then continue; fi
            if is_removable_path "$target"; then fixed=0; tag=""; else fixed=1; tag="  [!] NOT A REMOVABLE DEVICE"; fi
            devices+=("mass_storage|$target|$label|$fixed")
            printf "  [%d] %s (mass storage: %s)%s\n" "$idx" "$label" "$target" "$tag"
            idx=$((idx + 1))
        done < <(findmnt -rn -o TARGET,SOURCE,LABEL 2>/dev/null | grep -v "tmpfs\|devtmpfs\|squashfs")
    fi

    # List MTP devices via gio
    if command -v gio >/dev/null 2>&1; then
        while IFS= read -r line; do
            local uri=$(echo "$line" | grep -o 'mtp://[^ ]*' | sed 's|/$||')
            [ -z "$uri" ] && continue
            # gio prints "Mount(0): NAME -> mtp://..."; take NAME.
            local name=$(echo "$line" | sed -E 's/^[^:]*: *//; s/ *(->|→) *mtp:.*$//')
            [ -z "$name" ] && name="$uri"
            devices+=("mtp|$uri|$name|0")
            printf "  [%d] %s (MTP: %s)\n" "$idx" "$name" "$uri"
            idx=$((idx + 1))
        done < <(gio mount -l 2>/dev/null | grep "mtp://")
    fi

    if [ ${#devices[@]} -eq 0 ]; then
        echo "    No devices found."
        return 1
    fi

    echo ""
    local choice
    read -r -p "  Select device (1-$((idx-1))): " choice || choice=""
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$idx" ]; then
        local selected="${devices[$((choice-1))]}"
        CONNECTION_TYPE=$(echo "$selected" | cut -d'|' -f1)
        local path=$(echo "$selected" | cut -d'|' -f2)
        DEVICE_FIXED=$(echo "$selected" | cut -d'|' -f4)

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
            # filesystem::free is a FILESYSTEM attribute, so ask for it with
            # "gio info -f"; fall back to the plain query if that returns nothing.
            local out free_bytes
            out=$(gio info -f -a "filesystem::free" "$KINDLE_PATH" 2>/dev/null) || out=""
            free_bytes=$(printf '%s\n' "$out" | awk -F': ' '/filesystem::free/ {print $2; exit}' | tr -d ' ')
            if [ -z "$free_bytes" ]; then
                out=$(gio info -a "filesystem::free" "$KINDLE_PATH" 2>/dev/null) || out=""
                free_bytes=$(printf '%s\n' "$out" | awk -F': ' '/filesystem::free/ {print $2; exit}' | tr -d ' ')
            fi
            if [ -n "$free_bytes" ] && [ "$free_bytes" -gt 0 ] 2>/dev/null; then
                echo $((free_bytes / 1024 / 1024))
            else
                echo ""
            fi
            ;;
    esac
}

# The free space the fill loop should trust. For MTP we also keep our
# own estimate (free at start - MB we wrote) and use whichever is LOWER, so a
# stale or missing reading cannot overshoot the target.
current_free_mb() {
    local rep est
    rep=$(get_free_mb) || rep=""
    if [ "$CONNECTION_TYPE" = "mtp" ]; then
        est=$((initialFreeMB - WRITTEN_MB))
        if [ "$est" -lt 0 ]; then est=0; fi
        if [ -n "$rep" ] && [ "$rep" -lt "$est" ]; then echo "$rep"; else echo "$est"; fi
    else
        echo "$rep"
    fi
}

# --- FILE CREATION ---
# create_file <size in MB> <path> [sparse_ok]
# "sparse_ok" is only passed for LOCAL temp files (MTP mode). On the
# device itself the file must really occupy space, so truncate is not used
# there: on filesystems with sparse-file support it would allocate nothing.
create_file() {
    local mb_size="$1" path="$2" sparse_ok="${3:-no}"
    [ "$mb_size" -lt 1 ] && mb_size=1

    # Local temp file: a sparse file is instant and uses no disk (or RAM on a
    # tmpfs /tmp), so try that before really allocating anything.
    if [ "$sparse_ok" = "sparse_ok" ] && command -v truncate >/dev/null 2>&1; then
        truncate -s "${mb_size}M" "$path" 2>/dev/null && return 0
    fi
    if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "${mb_size}M" "$path" 2>/dev/null && return 0
        rm -f "$path" 2>/dev/null || true
    fi
    if command -v mkfile >/dev/null 2>&1; then
        mkfile "${mb_size}m" "$path" 2>/dev/null && return 0
        rm -f "$path" 2>/dev/null || true
    fi
    # bs in bytes and no "status=" so BSD/macOS dd accepts it too.
    dd if=/dev/zero of="$path" bs=1048576 count="$mb_size" 2>/dev/null
}

# True if the file exists and has exactly <MB> megabytes.
file_has_size() {
    local path="$1" mb="$2" actual
    [ -f "$path" ] || return 1
    actual=$(wc -c < "$path" 2>/dev/null | tr -d ' ')
    [ "$actual" = "$((mb * 1048576))" ]
}

create_file_mtp() {
    local size_mb="$1" dest_path="$2"
    local tmp_file="${TEMP_DIR}/file_${FILE_COUNTER}"
    MTP_LAST_ERROR=""

    create_file "$size_mb" "$tmp_file" sparse_ok || true

    if [ ! -f "$tmp_file" ]; then
        MTP_LAST_ERROR="could not create local temporary file in $TEMP_DIR"
        return 1
    fi

    # Keep gio's error text so it can be shown to the user.
    if MTP_LAST_ERROR=$(gio copy "$tmp_file" "$dest_path" 2>&1); then
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
    read -r -p "$1 [y/N]: " ans || ans=""
    case "$ans" in y|Y|s|S) return 0 ;; *) return 1 ;; esac
}

# --- REMOVE FILLER (cleanup mode) with before/after free space ---
remove_filler() {
    local before after
    before=$(get_free_mb) || before=""
    echo ""
    echo "[*] Free space before: ${before:-unknown} MB"
    echo "[*] Removing '$dir' from the device..."

    case "$CONNECTION_TYPE" in
        mass_storage)
            if [ -d "$KINDLE_PATH/$dir" ]; then
                # Verify the removal and report the real outcome.
                rm -rf "$KINDLE_PATH/$dir" 2>/dev/null || true
                if [ -e "$KINDLE_PATH/$dir" ]; then
                    echo "[!] '$KINDLE_PATH/$dir' could not be removed completely. Some files are still there."
                else
                    echo "[OK] Removed $KINDLE_PATH/$dir"
                fi
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
            if mtp_exists "$target"; then
                local f fn
                while IFS= read -r f; do
                    [ -z "$f" ] && continue
                    fn=$(printf '%s' "$f" | cut -f1); fn="${fn%/}"
                    [ -z "$fn" ] && continue
                    gio remove "$target/$fn" 2>/dev/null || gio trash "$target/$fn" 2>/dev/null || true
                done < <(gio list "$target" 2>/dev/null)
                gio remove "$target" 2>/dev/null || gio trash "$target" 2>/dev/null || true
                # Check that it is really gone.
                if mtp_exists "$target"; then
                    echo "[!] '$dir' is still on the device. Some files could not be removed."
                else
                    echo "[OK] Removed '$dir' via MTP"
                fi
            else
                echo "[!] No '$dir' folder found on the device."
            fi
            ;;
    esac

    after=$(get_free_mb) || after=""
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
read -r -p "  Choice (1-2) [1]: " modechoice || modechoice=""
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
        pause
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
        pause
        exit 1
    fi
    # Verify it's writable
    if ! touch "$KINDLE_PATH/.test_write" 2>/dev/null; then
        echo "[!] Error: Cannot write to $KINDLE_PATH. Check permissions."
        pause
        exit 1
    fi
    rm -f "$KINDLE_PATH/.test_write"
elif [ "$CONNECTION_TYPE" = "mtp" ]; then
    if ! mtp_exists "$KINDLE_PATH"; then
        echo "[!] Error: Cannot access Kindle via MTP at $KINDLE_PATH"
        echo "    Try disconnecting and reconnecting your Kindle."
        pause
        exit 1
    fi
    ensure_temp_dir
fi

# --- REMOVE MODE: reclaim space and exit ---
if [ "$MODE" = "remove" ]; then
    remove_filler
    pause
    exit 0
fi

echo ""

# --- CREATE DIRECTORY ON KINDLE ---
echo "[*] Preparing fill_disk directory on Kindle..."

# If the folder cannot be created there is nowhere to write to, so stop here.
case "$CONNECTION_TYPE" in
    mass_storage)
        if mkdir -p "$KINDLE_PATH/$dir" 2>/dev/null && [ -d "$KINDLE_PATH/$dir" ]; then
            echo "[OK] Directory ready: $KINDLE_PATH/$dir"
        else
            echo "[!] Error: Could not create $KINDLE_PATH/$dir"
            pause
            exit 1
        fi
        ;;
    mtp)
        if mtp_exists "$KINDLE_PATH/$dir"; then
            echo "[OK] Directory already exists on Kindle"
        elif gio mkdir "$KINDLE_PATH/$dir" 2>/dev/null; then
            echo "[OK] Directory created on Kindle via MTP"
        else
            echo "[!] Error: Could not create '$dir' on the Kindle via MTP."
            echo "    Make sure the device is unlocked, then reconnect it and try again."
            pause
            exit 1
        fi
        ;;
esac

echo ""

# --- GET FREE SPACE ---
initialFreeMB=$(get_free_mb) || initialFreeMB=""
if [ -z "$initialFreeMB" ] || [ "$initialFreeMB" -le 0 ] 2>/dev/null; then
    echo "[!] Error: Cannot determine free space on Kindle."
    echo "    This may be a temporary MTP connection issue."
    echo "    Try disconnecting and reconnecting your Kindle."
    pause
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
read -r -p "  Enter your choice (1-4) [1]: " choice || choice=""

case "$choice" in
    2) minFreeMB=50 ;;
    3) minFreeMB=100 ;;
    4)
        read -r -p "  Enter the minimum free space in MB (e.g., 30): " custom || custom=""
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
    pause
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
    pause
    exit 0
fi

# A disk that is not known to be removable is almost never a Kindle.
# Require a typed word before filling it.
if [ "$DEVICE_FIXED" = "1" ]; then
    echo ""
    echo "  [!] WARNING: $KINDLE_PATH is NOT a known removable/external device."
    read -r -p "  Type FILL (capitals) to fill it anyway: " typed || typed=""
    if [ "$typed" != "FILL" ]; then
        echo "[!] Cancelled. Nothing was written."
        pause
        exit 0
    fi
fi

echo ""
echo "[>] Starting disk fill process..."
echo "    Target: fill ~${targetFillMB} MB, leave ${minFreeMB} MB free"
echo "    Mode: $CONNECTION_TYPE"
echo ""

# True if file_N already exists in the fill folder on the device.
# For MTP the folder is listed once (MTP_EXISTING) instead of asking the device
# before every file.
MTP_EXISTING=""
filler_exists() {
    if [ "$CONNECTION_TYPE" = "mtp" ]; then
        case $'\n'"$MTP_EXISTING"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; esac
        return 1
    else
        [ -e "$KINDLE_PATH/$dir/$1" ]
    fi
}

# --- MAIN LOOP ---
if [ "$CONNECTION_TYPE" = "mtp" ]; then
    MTP_EXISTING=$(gio list "$KINDLE_PATH/$dir" 2>/dev/null | cut -f1 | sed 's|/$||') || MTP_EXISTING=""
fi

# Free space is read once per file: the reading taken after each write is
# reused at the top of the next iteration.
stallCount=0
freeMB=$(current_free_mb)
while true; do
    if [ -z "$freeMB" ]; then
        printf '\n'
        echo "[!] Lost access to the device (free space can no longer be read)."
        FILL_FAILED=1
        break
    fi
    fillableMB=$((freeMB - minFreeMB))
    [ "$fillableMB" -le 0 ] && break

    # Determine file size.
    # Use uniform 100 MB files as the primary chunk so that freeing space later is
    # granular: deleting ONE file frees exactly 100 MB (enough for a book/document)
    # while the device stays nearly full and OTA updates remain blocked.
    # Only the final tail uses 50/10/1 MB to land exactly on the requested free space.
    if [ "$fillableMB" -ge 100 ]; then
        sizeMB=100
    elif [ "$fillableMB" -ge 50 ]; then
        sizeMB=50
    elif [ "$fillableMB" -ge 10 ]; then
        sizeMB=10
    else
        sizeMB=1
    fi
    fileSize="${sizeMB}M"

    # Resume support. Never reuse a name that is already on the device.
    while filler_exists "file_${FILE_COUNTER}"; do
        FILE_COUNTER=$((FILE_COUNTER + 1))
    done

    # Progress
    usedMB=$((initialFreeMB - freeMB))
    percent=$((usedMB * 100 / targetFillMB))
    [ "$percent" -gt 100 ] && percent=100
    [ "$percent" -lt 0 ] && percent=0
    render_progress "$percent" "Creating: " "file_${FILE_COUNTER} ($fileSize)"

    # Create file
    case "$CONNECTION_TYPE" in
        mass_storage)
            dest="$KINDLE_PATH/$dir/file_${FILE_COUNTER}"
            # Handle a failed write explicitly (set -e would otherwise end the
            # script without a message); the file must have the full size to count.
            if ! create_file "$sizeMB" "$dest" || ! file_has_size "$dest" "$sizeMB"; then
                printf '\n'
                echo "[!] Could not create file_${FILE_COUNTER} ($fileSize). The device may be full, read-only or disconnected."
                rm -f "$dest" 2>/dev/null || true      # partial file
                FILL_FAILED=1
                break
            fi
            ;;
        mtp)
            if ! create_file_mtp "$sizeMB" "$KINDLE_PATH/$dir/file_${FILE_COUNTER}"; then
                printf '\n'
                echo "[!] Write failed. Storage might be completely full."
                [ -n "$MTP_LAST_ERROR" ] && echo "    gio said: $MTP_LAST_ERROR"
                FILL_FAILED=1
                break
            fi
            ;;
    esac

    FILE_COUNTER=$((FILE_COUNTER + 1))
    WROTE_COUNT=$((WROTE_COUNT + 1))
    WRITTEN_MB=$((WRITTEN_MB + sizeMB))

    # Update progress
    newFreeMB=$(current_free_mb)
    if [ -z "$newFreeMB" ]; then
        printf '\n'
        echo "[!] Lost access to the device (free space can no longer be read)."
        FILL_FAILED=1
        break
    fi

    # Stall guard. If writing files does not reduce the free space,
    # stop instead of creating files forever.
    if [ "$newFreeMB" -ge "$freeMB" ]; then
        stallCount=$((stallCount + 1))
    else
        stallCount=0
    fi
    if [ "$stallCount" -ge 3 ]; then
        printf '\n'
        echo "[!] Free space is not going down although files are being written."
        echo "    Stopping to avoid an endless loop. Is this really the Kindle?"
        FILL_FAILED=1
        break
    fi

    freeMB=$newFreeMB
    usedMB=$((initialFreeMB - freeMB))
    percent=$((usedMB * 100 / targetFillMB))
    [ "$percent" -gt 100 ] && percent=100
    [ "$percent" -lt 0 ] && percent=0

    remainingLabel="${freeMB} MB"
    [ "$freeMB" -ge 1024 ] && remainingLabel="$(awk "BEGIN {printf \"%.1f\", $freeMB/1024}") GB"

    render_progress "$percent" "Done:     " "file_$((FILE_COUNTER-1)) | Free: $remainingLabel"

    # Small delay for MTP to prevent overwhelming the connection
    [ "$CONNECTION_TYPE" = "mtp" ] && sleep 0.1
done

# Mass storage writes go through the system's write cache. Flush it so the
# data is really on the device before we report success.
if [ "$CONNECTION_TYPE" = "mass_storage" ] && [ "$WROTE_COUNT" -gt 0 ]; then
    printf '\n'
    echo "[*] Flushing data to the device (do not unplug it yet)..."
    sync -f "$KINDLE_PATH" 2>/dev/null || sync 2>/dev/null || true
fi

# --- ZIP FALLBACK (last resort) ---
# If the per-file method wrote nothing, offer the pre-built archive approach.
if [ "$WROTE_COUNT" -eq 0 ]; then
    printf '\n'
    echo "[!] The per-file fill method did not write any files."
    echo "    Last resort: download a pre-built filler archive and copy it to the device."
    read -r -p "  Try the pre-built zip fallback? (y/N): " usezip || usezip=""
    case "$usezip" in
        y|Y|s|S)
            # zip_fallback reports whether it really wrote anything.
            if zip_fallback "$initialFreeMB"; then FILL_FAILED=0; else FILL_FAILED=1; fi
            WROTE_COUNT=$((WROTE_COUNT + ZIP_COPIED))
            ;;
    esac
fi

# --- DONE ---
# Summary: what was written this run, how much is free now,
# and whether the fill finished or stopped early.
finalFreeMB=$(get_free_mb) || finalFreeMB=""
if [ "$WROTE_COUNT" -eq 0 ]; then
    doneTitle="Nothing was written."
elif [ "$FILL_FAILED" -eq 1 ]; then
    doneTitle="Fill stopped early (see the message above)."
else
    doneTitle="Disk fill complete!"
fi

printf '\n'
echo "  +---------------------------------------------------------+"
echo "  |  $doneTitle"
echo "  |  Files written this run: $WROTE_COUNT"
echo "  |  Free space now: ${finalFreeMB:-unknown} MB"
echo "  |  Connection: $CONNECTION_TYPE"
echo "  |  Directory: $KINDLE_PATH/$dir"
if [ "$CONNECTION_TYPE" = "mtp" ]; then
    echo "  |  (files transferred via MTP)"
fi
echo "  +---------------------------------------------------------+"
echo ""
pause
