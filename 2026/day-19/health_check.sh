#!/bin/bash
# Day 19 - small health check, meant for an every-5-minutes cron entry
set -uo pipefail

DISK_THRESHOLD=80
SERVICE="ssh"

# -P forces POSIX output so a long device name cannot wrap onto a second line
DISK_USED=$(df -P / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')

if [ "$DISK_USED" -ge "$DISK_THRESHOLD" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ALERT] disk usage is ${DISK_USED}% (threshold ${DISK_THRESHOLD}%)"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') [OK] disk usage is ${DISK_USED}%"
fi

if systemctl is-active --quiet "$SERVICE"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [OK] $SERVICE is running"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ALERT] $SERVICE is NOT running"
fi
