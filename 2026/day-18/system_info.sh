#!/bin/bash
# Day 18 - Task 5: system info reporter
set -euo pipefail

print_header() {
    echo
    echo "=============================================="
    echo " $1"
    echo "=============================================="
}

system_info() {
    print_header "HOSTNAME AND OS"
    echo "Hostname : $(hostname)"
    echo "Kernel   : $(uname -r)"
    echo "OS       : $(grep PRETTY_NAME /etc/os-release | cut -d '"' -f2)"
}

uptime_info() {
    print_header "UPTIME AND LOAD"
    uptime -p
    echo "Load average:$(cut -d ' ' -f1-3 /proc/loadavg | sed 's/^/ /')"
}

disk_info() {
    print_header "DISK USAGE (TOP 5)"
    df -h --output=source,size,used,avail,pcent,target \
        | grep -v tmpfs \
        | sort -k5 -hr \
        | head -n 5
}

memory_info() {
    print_header "MEMORY USAGE"
    free -h
}

top_processes() {
    print_header "TOP 5 PROCESSES BY CPU"
    ps -eo pid,pcpu,pmem,comm --sort=-pcpu | head -n 6
}

main() {
    echo "System report generated on $(date '+%Y-%m-%d %H:%M:%S')"
    system_info
    uptime_info
    disk_info
    memory_info
    top_processes
    echo
    echo "Report complete."
}

main
