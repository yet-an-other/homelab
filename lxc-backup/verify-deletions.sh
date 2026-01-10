#!/bin/bash

# Quick script to verify deleted files between two snapshots

BACKUP_DIR="/mnt/dst"
OLD_SNAPSHOT="inc-2025-12-27"
NEW_SNAPSHOT="inc-2025-12-31"

echo "Comparing $OLD_SNAPSHOT vs $NEW_SNAPSHOT"
echo "=========================================="
echo ""

# Find files in old that don't exist in new
echo "Files deleted from $OLD_SNAPSHOT to $NEW_SNAPSHOT:"
deleted_count=0

while IFS= read -r -d '' old_file; do
    rel_path="${old_file#$BACKUP_DIR/$OLD_SNAPSHOT/}"
    new_file="$BACKUP_DIR/$NEW_SNAPSHOT/$rel_path"

    if [ ! -e "$new_file" ]; then
        echo "  - $rel_path"
        ((deleted_count++))
    fi
done < <(find "$BACKUP_DIR/$OLD_SNAPSHOT" -type f -print0 2>/dev/null)

echo ""
echo "Total deleted: $deleted_count files"
