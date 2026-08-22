#!/bin/bash
# Day 19 - Task 1: compress old logs, delete very old archives
set -uo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <log_directory>"
    exit 1
fi

LOG_DIR="$1"
COMPRESS_AFTER_DAYS=7
DELETE_AFTER_DAYS=30

if [ ! -d "$LOG_DIR" ]; then
    echo "ERROR: '$LOG_DIR' is not a directory or does not exist."
    exit 1
fi

echo "Rotating logs in: $LOG_DIR"

# compress .log files older than 7 days
COMPRESSED=0
while IFS= read -r -d '' FILE; do
    if gzip "$FILE" 2>/dev/null; then
        echo "  compressed: $FILE"
        COMPRESSED=$((COMPRESSED + 1))
    else
        echo "  FAILED to compress: $FILE" >&2
    fi
done < <(find "$LOG_DIR" -type f -name "*.log" -mtime +"$COMPRESS_AFTER_DAYS" -print0)

# delete .gz files older than 30 days
DELETED=0
while IFS= read -r -d '' FILE; do
    if rm -f "$FILE"; then
        echo "  deleted:    $FILE"
        DELETED=$((DELETED + 1))
    fi
done < <(find "$LOG_DIR" -type f -name "*.gz" -mtime +"$DELETE_AFTER_DAYS" -print0)

echo "Summary: $COMPRESSED file(s) compressed, $DELETED old archive(s) deleted."
