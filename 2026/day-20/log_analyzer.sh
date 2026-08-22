#!/bin/bash
# Day 20 - Log Analyzer and Report Generator
# Usage: ./log_analyzer.sh <log_file> [--archive]
set -uo pipefail

# ---------- Task 1: input and validation ----------

if [ $# -lt 1 ]; then
    echo "ERROR: no log file given."
    echo "Usage: $0 <log_file> [--archive]"
    exit 1
fi

LOG_FILE="$1"
ARCHIVE_MODE="${2:-}"

if [ ! -f "$LOG_FILE" ]; then
    echo "ERROR: '$LOG_FILE' does not exist or is not a regular file."
    exit 1
fi

if [ ! -r "$LOG_FILE" ]; then
    echo "ERROR: '$LOG_FILE' exists but cannot be read. Check permissions."
    exit 1
fi

REPORT_DATE=$(date '+%Y-%m-%d')
REPORT_FILE="log_report_${REPORT_DATE}.txt"

# ---------- helper: pull the message out of a log line ----------
# a line looks like: 2026-06-29 08:31:05 [ERROR] Failed to connect - 12345
# we want just:      Failed to connect
extract_messages() {
    grep "ERROR" "$LOG_FILE" \
        | awk -F'] ' '{print $2}' \
        | sed 's/ - [0-9]*$//' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# ---------- Task 2: error count ----------
count_errors() {
    grep -c -E "ERROR|Failed" "$LOG_FILE"
}

# ---------- Task 3: critical events ----------
critical_events() {
    grep -n "CRITICAL" "$LOG_FILE" | sed 's/^\([0-9]*\):/Line \1: /'
}

# ---------- Task 4: top 5 error messages ----------
top_errors() {
    extract_messages | sort | uniq -c | sort -rn | head -5
}

TOTAL_LINES=$(wc -l < "$LOG_FILE")
ERROR_COUNT=$(count_errors)
CRITICAL_COUNT=$(grep -c "CRITICAL" "$LOG_FILE")

# ---------- console output ----------

echo "Analyzing: $LOG_FILE"
echo
echo "--- Error Count ---"
echo "Total lines matching ERROR or Failed: $ERROR_COUNT"
echo
echo "--- Critical Events ---"
if [ "$CRITICAL_COUNT" -eq 0 ]; then
    echo "None found."
else
    critical_events | head -10
    if [ "$CRITICAL_COUNT" -gt 10 ]; then
        echo "... and $((CRITICAL_COUNT - 10)) more (full list is in the report)"
    fi
fi
echo
echo "--- Top 5 Error Messages ---"
top_errors

# ---------- Task 5: write the report ----------

{
    echo "=================================================="
    echo "           LOG ANALYSIS SUMMARY REPORT"
    echo "=================================================="
    echo
    echo "Date of analysis : $REPORT_DATE"
    echo "Log file         : $LOG_FILE"
    echo "Total lines      : $TOTAL_LINES"
    echo "Total errors     : $ERROR_COUNT  (ERROR or Failed)"
    echo "Critical events  : $CRITICAL_COUNT"
    echo
    echo "--------------------------------------------------"
    echo "TOP 5 ERROR MESSAGES"
    echo "--------------------------------------------------"
    top_errors
    echo
    echo "--------------------------------------------------"
    echo "CRITICAL EVENTS"
    echo "--------------------------------------------------"
    if [ "$CRITICAL_COUNT" -eq 0 ]; then
        echo "None found."
    else
        critical_events
    fi
    echo
    echo "=================================================="
    echo "End of report"
    echo "=================================================="
} > "$REPORT_FILE"

echo
echo "Report written to: $REPORT_FILE"

# ---------- Task 6 (optional): archive the processed log ----------

if [ "$ARCHIVE_MODE" = "--archive" ]; then
    mkdir -p archive
    mv "$LOG_FILE" archive/
    echo "Archived $LOG_FILE -> archive/$(basename "$LOG_FILE")"
fi
