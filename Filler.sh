#!/bin/bash
# Kindle Disk Filler Utility for Linux/macOS
# Author: iroak (https://github.com/bastianmarin)
# This tool fills the disk to prevent automatic updates on tablets
# that have not been registered. Useful for jailbreak preparation.
#
# ENHANCEMENTS:
# - Added automatic detection for both Mass Storage and MTP devices
# - Supports modern Kindle devices using MTP protocol
# - Creates files locally first, then transfers to prevent partial files on device
# - Implements retry logic and fallback methods for MTP connection stability
# - Maintains compatibility with older Kindles using Mass Storage mode

set -e

# Global variables
TEMP_DIR="/tmp/kindle_filler_$$"
KINDLE_PATH=""
KINDLE_LOCAL_PATH=""  # GVFS fallback path for MTP devices
CONNECTION_TYPE=""

# Cleanup function to ensure no local files remain
cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
        echo "Cleaned up temporary files."
    fi
}

# Set trap to cleanup on exit
trap cleanup EXIT

# Function to detect Kindle device via lsusb
detect_kindle() {
    # Amazon Vendor IDs: 1949 (Amazon Technologies Inc.)
    # This works for both old Mass Storage and modern MTP Kindles
    if lsusb | grep -E "(1949:|Amazon)" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Function to detect connection type (MTP vs Mass Storage)
# Modern Kindles use MTP protocol, older ones use Mass Storage Device
detect_connection_type() {
    # Check for traditional mount first (older Kindles)
    local mount_point=$(mount | grep -i kindle | head -1 | awk '{print $3}')
    if [ -n "$mount_point" ]; then
        KINDLE_PATH="$mount_point"
        CONNECTION_TYPE="mass_storage"
        return 0
    fi
    
    # Check for MTP via gio (modern Kindles)
    if command -v gio > /dev/null 2>&1; then
        local mtp_uri=$(gio mount -l 2>/dev/null | grep -i kindle | grep "mtp://" | head -1 | sed 's/.*-> \(mtp:\/\/[^[:space:]]*\).*/\1/' | sed 's|/$||')
        if [ -n "$mtp_uri" ]; then
            # Most modern Kindles have "Internal Storage" directory
            if gio list "$mtp_uri" 2>/dev/null | grep -q "Internal Storage"; then
                KINDLE_PATH="$mtp_uri/Internal Storage"
                # Extract device name from URI for GVFS path
                local device_name=$(echo "$mtp_uri" | sed 's|mtp://||')
                local gvfs_path="/run/user/$(id -u)/gvfs/mtp:host=${device_name}/Internal Storage"
                if [ -d "$gvfs_path" ]; then
                    KINDLE_LOCAL_PATH="$gvfs_path"
                fi
            else
                KINDLE_PATH="$mtp_uri"
                local device_name=$(echo "$mtp_uri" | sed 's|mtp://||')
                local gvfs_path="/run/user/$(id -u)/gvfs/mtp:host=${device_name}"
                if [ -d "$gvfs_path" ]; then
                    KINDLE_LOCAL_PATH="$gvfs_path"
                fi
            fi
            CONNECTION_TYPE="mtp"
            return 0
        fi
    fi
    
    return 1
}

# Function to get free space based on connection type
get_free_mb() {
    case "$CONNECTION_TYPE" in
        "mass_storage")
            # Traditional filesystem approach for older Kindles
            df -Pm "$KINDLE_PATH" | awk 'NR==2 {print $4}'
            ;;
        "mtp")
            # For MTP devices, filesystem info is at the device root
            local device_root=$(echo "$KINDLE_PATH" | sed 's|/Internal Storage||')
            local free_bytes=$(gio info "$device_root" 2>/dev/null | grep "filesystem::free" | grep -o '[0-9]*')
            if [ -n "$free_bytes" ]; then
                echo $((free_bytes / 1024 / 1024))
            else
                # Fallback: try getting info from Internal Storage path
                free_bytes=$(gio info "$KINDLE_PATH" 2>/dev/null | grep "filesystem::free" | grep -o '[0-9]*')
                if [ -n "$free_bytes" ]; then
                    echo $((free_bytes / 1024 / 1024))
                else
                    echo "Error: Cannot determine free space"
                    return 1
                fi
            fi
            ;;
        *)
            echo "0"
            ;;
    esac
}

# Function to create directory on Kindle
create_kindle_directory() {
    local dir_name="$1"
    
    case "$CONNECTION_TYPE" in
        "mass_storage")
            # Simple directory creation for mounted filesystems
            echo "Creating directory $dir_name on Kindle..."
            if mkdir -p "$KINDLE_PATH/$dir_name" 2>/dev/null; then
                echo "✓ Directory created successfully"
            else
                echo "⚠ Warning: Could not create directory, but continuing..."
            fi
            ;;
        "mtp")
            # MTP devices require special handling with multiple fallback methods
            echo "Creating directory $dir_name on Kindle..."
            
            # Try gio first (native MTP method)
            if gio mkdir "$KINDLE_PATH/$dir_name" 2>/dev/null; then
                echo "✓ Directory created successfully via MTP"
                return 0
            # Try GVFS local path as fallback (often more reliable)
            elif [ -n "$KINDLE_LOCAL_PATH" ] && mkdir -p "$KINDLE_LOCAL_PATH/$dir_name" 2>/dev/null; then
                echo "✓ Directory created successfully via GVFS"
                return 0
            else
                # Check if directory already exists before reporting failure
                if [ -n "$KINDLE_LOCAL_PATH" ] && [ -d "$KINDLE_LOCAL_PATH/$dir_name" ]; then
                    echo "✓ Directory already exists"
                    return 0
                elif gio list "$KINDLE_PATH/$dir_name" >/dev/null 2>&1; then
                    echo "✓ Directory already exists"
                    return 0
                else
                    echo "⚠ Warning: Could not create/access directory, but continuing..."
                    return 0  # Continue anyway as files can still be transferred
                fi
            fi
            ;;
    esac
}

# Function to copy file to Kindle
copy_to_kindle() {
    local local_file="$1"
    local kindle_dest="$2"
    
    case "$CONNECTION_TYPE" in
        "mass_storage")
            # Direct file copy for mounted filesystems
            cp "$local_file" "$KINDLE_PATH/$kindle_dest"
            return $?
            ;;
        "mtp")
            # MTP transfer with multiple methods and retry logic
            # GVFS is often more reliable than direct gio commands
            if [ -n "$KINDLE_LOCAL_PATH" ] && cp "$local_file" "$KINDLE_LOCAL_PATH/$kindle_dest" 2>/dev/null; then
                return 0
            else
                # Fallback to gio with retry logic for MTP instability
                local max_retries=2
                local retry=0
                
                while [ $retry -lt $max_retries ]; do
                    if gio copy "$local_file" "$KINDLE_PATH/$kindle_dest" 2>/dev/null; then
                        return 0
                    else
                        retry=$((retry + 1))
                        if [ $retry -lt $max_retries ]; then
                            echo "Transfer failed, retrying ($retry/$max_retries)..."
                            sleep 1
                        fi
                    fi
                done
                return 1
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

echo "--------------------------------------------------------------------"
echo "|                    Kindle Disk Filler Utility                    |"
echo "| This tool fills the disk to prevent automatic updates on tablets |"
echo "| that have not been registered. Useful for jailbreak preparation. |"
echo "--------------------------------------------------------------------"

# Step 1: Detect Kindle device via USB connection
echo "Detecting Kindle device..."
if ! detect_kindle; then
    echo "Error: No Kindle device detected via USB."
    echo "Please ensure your Kindle is connected via USB cable."
    exit 1
fi
echo "✓ Kindle device detected"

# Step 2: Determine connection protocol (Mass Storage vs MTP)
echo "Identifying connection type..."
if ! detect_connection_type; then
    echo "Error: Could not determine Kindle connection type."
    echo "Please ensure your Kindle is properly connected and mounted/accessible."
    exit 1
fi
echo "✓ Connection type: $CONNECTION_TYPE"
echo "✓ Kindle path: $KINDLE_PATH"

# Create temporary directory for local file creation (prevents disk space usage on host)
mkdir -p "$TEMP_DIR"

dir="fill_disk"
create_kindle_directory "$dir"

# Validate Kindle connectivity before starting the filling process
echo "Checking available space on Kindle..."
initial_free=$(get_free_mb)
if [ "$initial_free" = "Error: Cannot determine free space" ]; then
    echo "Error: Cannot determine free space on Kindle device."
    echo "This may be a temporary MTP connection issue."
    echo "Please try disconnecting and reconnecting your Kindle."
    exit 1
fi
echo "✓ Available space: ${initial_free} MB"

i=0

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

echo "Filling Kindle disk with files. Please wait..."
while true; do
    # Get free space with error handling
    freeMB=$(get_free_mb 2>/dev/null) || {
        echo "Error: Could not get free space information"
        break
    }
    
    # Validate that we got a numeric value
    if ! [[ "$freeMB" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid free space value: $freeMB"
        break
    fi
    
    # Determine optimal file size based on available space
    # Use smaller files for better compatibility with slow USB devices
    if [ "$freeMB" -ge 500 ]; then
        fileSize=100M
        fileLabel="100MB"
    elif [ "$freeMB" -ge 100 ]; then
        fileSize=50M
        fileLabel="50MB"
    elif [ "$freeMB" -ge "$minFreeMB" ]; then
        fileSize=10M
        fileLabel="10MB"
    else
        break
    fi

    # Exit if we've reached the minimum free space threshold
    if [ "$freeMB" -lt "$minFreeMB" ]; then
        break
    fi

    echo "Creating file of size $fileLabel (Free space: ${freeMB}MB)..."

    # Create file locally first (efficient and doesn't consume Kindle space if transfer fails)
    local_file="$TEMP_DIR/file_$i"
    if ! dd if=/dev/zero of="$local_file" bs=$fileSize count=1 status=none 2>/dev/null; then
        echo "Error creating temporary file"
        break
    fi
    
    if [ ! -f "$local_file" ]; then
        echo "Error: Temporary file not created"
        break
    fi

    # Transfer file to Kindle using appropriate method
    kindle_dest="$dir/file_$i"
    if copy_to_kindle "$local_file" "$kindle_dest"; then
        echo "✓ Transferred file_$i of size $fileLabel to Kindle"
    else
        echo "✗ Error transferring file_$i to Kindle"
        rm -f "$local_file"
        break
    fi
    
    # Clean up local file immediately after successful transfer
    rm -f "$local_file"
    i=$((i+1))
    
    # Add small delay to prevent overwhelming the system
    sleep 0.5
done

echo "Space exhausted or less than $minFreeMB MB free after transferring $i files to Kindle."
echo "Files successfully transferred to $dir folder on your Kindle."
echo "✓ All temporary files have been cleaned up."
echo "Press Enter to exit."
read -r _