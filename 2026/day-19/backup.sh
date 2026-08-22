#!/bin/bash
# Day 19 - Task 2: timestamped backup with retention
set -uo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: $0 <source_directory> <backup_destination>"
    exit 1
fi

SOURCE="$1"
DEST="$2"
RETENTION_DAYS=14
TIMESTAMP=$(date +%Y-%m-%d)
ARCHIVE="$DEST/backup-${TIMESTAMP}.tar.gz"

if [ ! -d "$SOURCE" ]; then
    echo "ERROR: source '$SOURCE' does not exist."
    exit 1
fi

mkdir -p "$DEST" || { echo "ERROR: cannot create destination '$DEST'."; exit 1; }

echo "Backing up $SOURCE -> $ARCHIVE"

# -C so the archive holds relative paths, not /home/devops/...
if tar -czf "$ARCHIVE" -C "$(dirname "$SOURCE")" "$(basename "$SOURCE")"; then
    echo "Archive created."
else
    echo "ERROR: tar failed."
    exit 1
fi

# verify the archive is readable and not empty
if [ ! -s "$ARCHIVE" ]; then
    echo "ERROR: archive is empty."
    exit 1
fi

if ! tar -tzf "$ARCHIVE" > /dev/null 2>&1; then
    echo "ERROR: archive is corrupt, cannot list contents."
    exit 1
fi

SIZE=$(du -h "$ARCHIVE" | cut -f1)
FILE_COUNT=$(tar -tzf "$ARCHIVE" | wc -l)
echo "Verified OK."
echo "  Name  : $(basename "$ARCHIVE")"
echo "  Size  : $SIZE"
echo "  Files : $FILE_COUNT"

# retention
OLD=$(find "$DEST" -maxdepth 1 -type f -name "backup-*.tar.gz" -mtime +"$RETENTION_DAYS" | wc -l)
if [ "$OLD" -gt 0 ]; then
    find "$DEST" -maxdepth 1 -type f -name "backup-*.tar.gz" -mtime +"$RETENTION_DAYS" -delete
    echo "Removed $OLD backup(s) older than $RETENTION_DAYS days."
else
    echo "No backups older than $RETENTION_DAYS days to remove."
fi
