#!/bin/bash
# Day 18 - Task 2: functions that report disk and memory

check_disk() {
    echo "--- Disk usage of / ---"
    df -h / | awk 'NR==1 || NR==2'
}

check_memory() {
    echo "--- Memory usage ---"
    free -h
}

# main
check_disk
echo
check_memory
