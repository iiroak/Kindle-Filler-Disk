#!/usr/bin/env bash
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

GVFS_BASE="/run/user/$UID/gvfs"
CUSTOM_OPTION="-- Enter custom path --"
declare -a MTP_MOUNTS

if [ -d "$GVFS_BASE" ]; then
	while IFS= read -r path; do
		MTP_MOUNTS+=("$path")
	done < <(find "$GVFS_BASE" -maxdepth 1 -mindepth 1 -type d -name 'mtp:host=*' 2>/dev/null | sort)
fi

if [ "${#MTP_MOUNTS[@]}" -eq 0 ]; then
	echo "No MTP devices detected under $GVFS_BASE."
	read -r -p "Enter the Kindle path manually (leave empty to exit): " manual_path
	if [ -z "$manual_path" ]; then
		echo "No path provided. Exiting."
		exit 1
	fi
	KINDLE_PATH="$manual_path"
else
	echo "Detected MTP devices:"
	PS3="Select the Kindle to use: "
	SELECT_OPTIONS=("${MTP_MOUNTS[@]}" "$CUSTOM_OPTION")
	while true; do
		select choice in "${SELECT_OPTIONS[@]}"; do
			if [ -z "$choice" ]; then
				echo "Invalid selection. Try again."
				break
			fi
			if [ "$choice" = "$CUSTOM_OPTION" ]; then
				read -r -p "Enter the Kindle path manually: " manual_path
				if [ -z "$manual_path" ]; then
					echo "No path provided. Try selecting again."
					break
				fi
				KINDLE_PATH="$manual_path"
			else
				KINDLE_PATH="$choice"
			fi
			break 2
		done
	done
fi

echo ""
echo "Using Kindle path: $KINDLE_PATH"

TARGET_FREE_MB=20

echo "Checking Kindle storage..."

if [ ! -d "$KINDLE_PATH" ]; then
	echo "ERROR: Kindle storage is not accessible. Cannot write filler files."
	exit 1
fi

echo "Found Kindle at: $KINDLE_PATH"

if STORAGE_INFO=$(df -m "$KINDLE_PATH" 2>/dev/null); then
	TOTAL_MB=$(echo "$STORAGE_INFO" | awk 'NR==2 {print $2}')
	USED_MB=$(echo "$STORAGE_INFO" | awk 'NR==2 {print $3}')
	FREE_MB=$(echo "$STORAGE_INFO" | awk 'NR==2 {print $4}')
else
	echo "Could not get exact storage info. Using estimates..."
	TOTAL_MB=8000
	USED_MB=7920
	FREE_MB=$((TOTAL_MB - USED_MB))
fi

KINDLE_FILL_DIR="$KINDLE_PATH/storage_filler"

echo "Storage Information:"
echo " Total space: ${TOTAL_MB} MB"
echo " Used space: ${USED_MB} MB"
echo " Free space: ${FREE_MB} MB"
echo " Target free space: ${TARGET_FREE_MB} MB"

FILL_NEEDED_MB=$((FREE_MB - TARGET_FREE_MB))

if [ "$FILL_NEEDED_MB" -le 0 ]; then
	echo "No filling needed! Your Kindle already has ${FREE_MB}MB free space."
	exit 0
fi

echo " Space to fill: ${FILL_NEEDED_MB} MB"
echo ""

TMP_DIR=$(mktemp -d)
cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if ! gio info "$KINDLE_PATH" >/dev/null 2>&1; then
	echo "ERROR: gvfs (gio) cannot access $KINDLE_PATH. Make sure the Kindle is mounted via MTP."
	exit 1
fi

gio mkdir "$KINDLE_FILL_DIR" >/dev/null 2>&1 || true

echo "Writing filler files directly to: $KINDLE_FILL_DIR"

generate_chunk() {
	local size_mb=$1
	local label=$2
	local index=$3
	local tmp_file="$TMP_DIR/${label}_filler_${index}.dat"
	local target_file="$KINDLE_FILL_DIR/${label}_filler_${index}.dat"

	echo "  Creating ${label}_filler_${index}.dat (${size_mb}MB)..."
	dd if=/dev/zero of="$tmp_file" bs=1M count="$size_mb" status=none
	if ! gio copy "$tmp_file" "$target_file"; then
		echo "ERROR: Failed to copy ${label}_filler_${index}.dat to the Kindle."
		exit 1
	fi
	rm -f "$tmp_file"
	GENERATED_MB=$((GENERATED_MB + size_mb))
}

GENERATED_MB=0
REMAINING_MB=$FILL_NEEDED_MB

echo "Generating filler files..."

if [ "$REMAINING_MB" -gt 1000 ]; then
	# Create some large files first
	LARGE_FILES=$((REMAINING_MB / 500))
	if [ "$LARGE_FILES" -gt 10 ]; then
		LARGE_FILES=10 # Cap at 10 large files
	fi
	echo "Creating $LARGE_FILES large files (500MB each)..."
	for i in $(seq 1 $LARGE_FILES); do
		generate_chunk 500 "large" "$i"
		REMAINING_MB=$((REMAINING_MB - 500))
	done
fi

if [ "$REMAINING_MB" -gt 100 ]; then
	MEDIUM_FILES=$((REMAINING_MB / 100))
	if [ "$MEDIUM_FILES" -gt 20 ]; then
		MEDIUM_FILES=20 # Cap at 20 medium files
	fi
	echo "Creating $MEDIUM_FILES medium files (100MB each)..."
	for i in $(seq 1 $MEDIUM_FILES); do
		generate_chunk 100 "medium" "$i"
		REMAINING_MB=$((REMAINING_MB - 100))
	done
fi

if [ "$REMAINING_MB" -gt 0 ]; then
	echo "Creating small filler files..."
	SMALL_INDEX=1
	while [ "$REMAINING_MB" -gt 0 ]; do
		SIZE_MB=10
		if [ "$REMAINING_MB" -lt 10 ]; then
			SIZE_MB=$REMAINING_MB
		fi
		generate_chunk "$SIZE_MB" "small" "$SMALL_INDEX"
		REMAINING_MB=$((REMAINING_MB - SIZE_MB))
		SMALL_INDEX=$((SMALL_INDEX + 1))
	done
fi

echo ""
echo "File generation complete!"
echo ""
echo "Generated files in: $KINDLE_FILL_DIR"
gio list "$KINDLE_FILL_DIR"

echo ""
echo "TOTAL SIZE WRITTEN: ${GENERATED_MB} MB"
echo ""
echo "--------------------------------------------------------------------"
echo "INSTRUCTIONS:"
echo "1. Wait for the transfers to finish, then safely eject the Kindle from your OS."
echo "2. Confirm the Kindle now shows roughly ${TARGET_FREE_MB}MB of free space."
echo "3. To free space later, delete the files inside $KINDLE_FILL_DIR directly on the Kindle."
echo "--------------------------------------------------------------------"