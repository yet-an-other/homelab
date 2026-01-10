#!/bin/bash

set -euo pipefail

# ==================== LOAD CONFIGURATION ====================
CONFIG_FILE="./backup.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Source configuration
source "$CONFIG_FILE"

# Validate required variables
for var in BACKUP_DIR BASE_PREFIX INCREMENT_PREFIX; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: Required variable $var not set in $CONFIG_FILE"
        exit 1
    fi
done

# Resolve LOG_DIR path
if [[ "$LOG_DIR" == .* ]]; then
    LOG_DIR="$BACKUP_DIR/$LOG_DIR"
fi

# ==================== FUNCTIONS ====================

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# Send ntfy notification
send_ntfy() {
    local title="$1"
    local message="$2"
    local priority="${3:-default}"
    local tags="${4:-}"

    if [ "$NTFY_ENABLED" = true ]; then
        curl -s -H "Title: $title" \
            -H "Priority: $priority" \
            ${tags:+-H "Tags: $tags"} \
            -d "$message" \
            "$NTFY_URL" 2>/dev/null || log "Warning: Failed to send ntfy notification"
    fi
}

# Find current base
find_current_base() {
    find "$BACKUP_DIR" -maxdepth 1 -type d -name "${BASE_PREFIX}*" 2>/dev/null | sed 's|.*/||' | sort | tail -1
}

# List all increments
list_increments() {
    find "$BACKUP_DIR" -maxdepth 1 -type d -name "${INCREMENT_PREFIX}20??-??-??" 2>/dev/null | sed 's|.*/||' | sort
}

# Find latest increment
find_latest_increment() {
    list_increments | tail -1
}

# List all available snapshots (base + increments)
list_all_snapshots() {
    {
        find_current_base
        list_increments
    } | sort
}

# Display usage
usage() {
    cat <<EOF
Usage: $0 [OPTIONS] <restore_destination>

Restore files from backup to specified destination.

OPTIONS:
    -l, --list              List all available snapshots
    -d, --date DATE         Restore from specific date (YYYY-MM-DD)
                           If not specified, restores from latest snapshot
    -n, --dry-run          Show what would be restored without actually doing it
    -h, --help             Show this help message

EXAMPLES:
    # List all available snapshots
    $0 --list

    # Restore latest backup to /restore/path
    $0 /restore/path

    # Restore from specific date
    $0 --date 2025-01-15 /restore/path

    # Dry run to see what would be restored
    $0 --dry-run /restore/path

    # Restore specific date with dry run
    $0 --date 2025-01-15 --dry-run /restore/path

NOTES:
    - The restore destination directory will be created if it doesn't exist
    - Existing files in destination may be overwritten
    - Use --dry-run to preview changes before actual restore
EOF
    exit 0
}

# ==================== PARSE ARGUMENTS ====================

LIST_MODE=false
DRY_RUN=false
RESTORE_DATE=""
RESTORE_DEST=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -l|--list)
            LIST_MODE=true
            shift
            ;;
        -d|--date)
            RESTORE_DATE="$2"
            shift 2
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "ERROR: Unknown option: $1"
            usage
            ;;
        *)
            RESTORE_DEST="$1"
            shift
            ;;
    esac
done

# ==================== LIST MODE ====================

if [ "$LIST_MODE" = true ]; then
    log "=== Available Snapshots ==="

    CURRENT_BASE=$(find_current_base)
    if [ -z "$CURRENT_BASE" ]; then
        log "No backups found in $BACKUP_DIR"
        exit 1
    fi

    BASE_DATE=${CURRENT_BASE#$BASE_PREFIX}
    log ""
    log "Current base: $CURRENT_BASE (${BASE_DATE})"
    log ""
    log "Available restore points:"
    log "-------------------------"

    SNAPSHOTS=$(list_all_snapshots)
    if [ -z "$SNAPSHOTS" ]; then
        log "No snapshots found"
        exit 1
    fi

    while IFS= read -r snapshot; do
        if [[ "$snapshot" == ${BASE_PREFIX}* ]]; then
            date=${snapshot#$BASE_PREFIX}
            size=$(du -sh "$BACKUP_DIR/$snapshot" 2>/dev/null | cut -f1)
            files=$(find "$BACKUP_DIR/$snapshot" -type f 2>/dev/null | wc -l | tr -d '[:space:]')
            printf "  📦 %s (BASE)  - Size: %s, Files: %s\n" "$date" "$size" "$files"
        else
            date=${snapshot#$INCREMENT_PREFIX}
            size=$(du -sh "$BACKUP_DIR/$snapshot" 2>/dev/null | cut -f1)
            files=$(find "$BACKUP_DIR/$snapshot" -type f 2>/dev/null | wc -l | tr -d '[:space:]')
            printf "  📈 %s        - Size: %s, Files: %s\n" "$date" "$size" "$files"
        fi
    done <<< "$SNAPSHOTS"

    LATEST=$(find_latest_increment)
    if [ -z "$LATEST" ]; then
        LATEST=$CURRENT_BASE
    fi
    LATEST_DATE=${LATEST#$INCREMENT_PREFIX}
    LATEST_DATE=${LATEST_DATE#$BASE_PREFIX}

    log ""
    log "Latest snapshot: $LATEST_DATE"
    log ""
    log "To restore, run:"
    log "  $0 <destination_path>"
    log "  $0 --date $LATEST_DATE <destination_path>"

    exit 0
fi

# ==================== RESTORE MODE ====================

# Validate restore destination
if [ -z "$RESTORE_DEST" ]; then
    echo "ERROR: Restore destination not specified"
    echo ""
    usage
fi

# Check if backup directory exists
if [ ! -d "$BACKUP_DIR" ]; then
    log "ERROR: Backup directory does not exist: $BACKUP_DIR"
    exit 1
fi

# Find snapshot to restore from
SNAPSHOT_TO_RESTORE=""

if [ -n "$RESTORE_DATE" ]; then
    # Try to find increment with this date
    INCREMENT_PATH="$BACKUP_DIR/${INCREMENT_PREFIX}${RESTORE_DATE}"
    BASE_PATH="$BACKUP_DIR/${BASE_PREFIX}${RESTORE_DATE}"

    if [ -d "$INCREMENT_PATH" ]; then
        SNAPSHOT_TO_RESTORE="$INCREMENT_PATH"
        SNAPSHOT_NAME="${INCREMENT_PREFIX}${RESTORE_DATE}"
    elif [ -d "$BASE_PATH" ]; then
        SNAPSHOT_TO_RESTORE="$BASE_PATH"
        SNAPSHOT_NAME="${BASE_PREFIX}${RESTORE_DATE}"
    else
        log "ERROR: No snapshot found for date: $RESTORE_DATE"
        log ""
        log "Available snapshots:"
        list_all_snapshots | while read -r s; do
            if [[ "$s" == ${BASE_PREFIX}* ]]; then
                echo "  - ${s#$BASE_PREFIX} (base)"
            else
                echo "  - ${s#$INCREMENT_PREFIX}"
            fi
        done
        exit 1
    fi
else
    # Restore from latest
    LATEST=$(find_latest_increment)
    if [ -z "$LATEST" ]; then
        LATEST=$(find_current_base)
    fi

    if [ -z "$LATEST" ]; then
        log "ERROR: No snapshots found in $BACKUP_DIR"
        exit 1
    fi

    SNAPSHOT_TO_RESTORE="$BACKUP_DIR/$LATEST"
    SNAPSHOT_NAME="$LATEST"
fi

# Extract date from snapshot name
if [[ "$SNAPSHOT_NAME" == ${BASE_PREFIX}* ]]; then
    SNAPSHOT_DATE=${SNAPSHOT_NAME#$BASE_PREFIX}
    SNAPSHOT_TYPE="base"
else
    SNAPSHOT_DATE=${SNAPSHOT_NAME#$INCREMENT_PREFIX}
    SNAPSHOT_TYPE="increment"
fi

# ==================== RESTORE EXECUTION ====================

RESTORE_START_TIME=$(date +%s)

log "=== Restore Started ==="
log "Source snapshot: $SNAPSHOT_NAME ($SNAPSHOT_TYPE)"
log "Snapshot date: $SNAPSHOT_DATE"
log "Destination: $RESTORE_DEST"
log "Dry run: $DRY_RUN"
log ""

# Create destination directory if it doesn't exist
if [ "$DRY_RUN" = false ]; then
    mkdir -p "$RESTORE_DEST"
fi

# Build rsync command
RSYNC_CMD="rsync -avh --delete --no-perms --no-group --no-owner"

if [ "$DRY_RUN" = true ]; then
    RSYNC_CMD="$RSYNC_CMD --dry-run"
fi

# Add extra rsync options if specified
if [ -n "${RSYNC_EXTRA_OPTS:-}" ]; then
    RSYNC_CMD="$RSYNC_CMD $RSYNC_EXTRA_OPTS"
fi

# Execute restore
log "Executing: $RSYNC_CMD \"$SNAPSHOT_TO_RESTORE/\" \"$RESTORE_DEST/\""
log ""

# shellcheck disable=SC2086
$RSYNC_CMD "$SNAPSHOT_TO_RESTORE/" "$RESTORE_DEST/" 2>&1 | while IFS= read -r line; do
    echo "$line"
done

RSYNC_EXIT=${PIPESTATUS[0]}

if [ $RSYNC_EXIT -ne 0 ] && [ $RSYNC_EXIT -ne 24 ]; then
    log ""
    log "ERROR: rsync failed with exit code $RSYNC_EXIT"

    send_ntfy "Restore: FAILED" \
            "Restore operation failed!

Snapshot: $SNAPSHOT_DATE ($SNAPSHOT_TYPE)
Destination: $RESTORE_DEST
Exit code: $RSYNC_EXIT

Please check the logs." \
            "urgent" "x,rotating_light"

    exit 1
fi

# ==================== SUMMARY ====================

RESTORE_END_TIME=$(date +%s)
RESTORE_DURATION=$((RESTORE_END_TIME - RESTORE_START_TIME))

log ""
log "=== Restore Summary ==="
log "Snapshot: $SNAPSHOT_DATE ($SNAPSHOT_TYPE)"
log "Destination: $RESTORE_DEST"
log "Duration: ${RESTORE_DURATION}s"

if [ "$DRY_RUN" = false ]; then
    RESTORED_SIZE=$(du -sh "$RESTORE_DEST" 2>/dev/null | cut -f1)
    RESTORED_FILES=$(find "$RESTORE_DEST" -type f 2>/dev/null | wc -l | tr -d '[:space:]')
    log "Restored size: $RESTORED_SIZE"
    log "Restored files: $RESTORED_FILES"
    log ""
    log "Restore completed successfully!"

    send_ntfy "Restore: Success" \
            "Restore completed successfully

Snapshot: $SNAPSHOT_DATE ($SNAPSHOT_TYPE)
Destination: $RESTORE_DEST
Size: $RESTORED_SIZE
Files: $RESTORED_FILES
Duration: ${RESTORE_DURATION}s" \
            "default" "white_check_mark,package"
else
    log ""
    log "Dry run completed. No files were actually restored."
    log "Remove --dry-run flag to perform actual restore."
fi

log "=== Restore Finished ==="
