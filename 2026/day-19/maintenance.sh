#!/bin/bash
# Day 19 - Task 4: run rotation and backup, log everything with timestamps
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAINT_LOG="/var/log/maintenance.log"

LOG_DIR="/var/log/myapp"
BACKUP_SOURCE="/home/devops/data"
BACKUP_DEST="/backups"

# prefix every line of output with a timestamp
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $*"
}

# run a step and feed its output through log()
run_step() {
    local NAME="$1"
    shift
    log "=== START: $NAME ==="
    if "$@" 2>&1 | while IFS= read -r LINE; do log "  $LINE"; done; then
        log "=== END:   $NAME (ok) ==="
    else
        log "=== END:   $NAME (FAILED) ==="
    fi
}

{
    log "########## maintenance run started ##########"
    run_step "log rotation" "$SCRIPT_DIR/log_rotate.sh" "$LOG_DIR"
    run_step "backup"       "$SCRIPT_DIR/backup.sh" "$BACKUP_SOURCE" "$BACKUP_DEST"
    log "########## maintenance run finished ##########"
} >> "$MAINT_LOG" 2>&1
