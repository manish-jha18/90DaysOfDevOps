# Day 20 – Log Analyzer and Report Generator

The task is a daily log summary: count errors, pull out critical events, find the most common failures, and write it all to a report file.

The folder had `sample_logs_generator.sh` but no log file, so I generated one with it first:

```
devops@testvm:~/day-20$ ./sample_logs_generator.sh sample_log.log 200
Log file created at: sample_log.log with 200 lines.
```

Each line looks like this:

```
2026-06-29 08:19:48 [CRITICAL] Database connection lost - 28339
2026-06-29 08:31:05 [ERROR] Failed to connect - 12153
```

Timestamp, level in square brackets, message, then a random number. That trailing number matters — it is different on every line, so any grouping has to strip it first or every message looks unique.

---

## The script

**`log_analyzer.sh`**

```bash
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
```

---

## Running it

```
devops@testvm:~/day-20$ ./log_analyzer.sh sample_log.log
Analyzing: sample_log.log

--- Error Count ---
Total lines matching ERROR or Failed: 47

--- Critical Events ---
Line 8: 2026-06-29 08:19:48 [CRITICAL] Database connection lost - 28339
Line 25: 2026-06-29 08:54:17 [CRITICAL] Disk space below threshold - 23285
Line 27: 2026-06-29 08:58:20 [CRITICAL] Service unresponsive - 7979
Line 32: 2026-06-29 09:08:08 [CRITICAL] Service unresponsive - 3801
Line 33: 2026-06-29 09:11:53 [CRITICAL] Database connection lost - 14984
Line 34: 2026-06-29 09:13:27 [CRITICAL] Memory limit exceeded - 11425
Line 35: 2026-06-29 09:15:45 [CRITICAL] Memory limit exceeded - 15362
Line 37: 2026-06-29 09:20:38 [CRITICAL] Database connection lost - 23541
Line 48: 2026-06-29 09:50:13 [CRITICAL] Disk space below threshold - 13495
Line 53: 2026-06-29 10:02:39 [CRITICAL] Database connection lost - 14664
... and 30 more (full list is in the report)

--- Top 5 Error Messages ---
     11 Out of memory
     10 Failed to connect
      9 Segmentation fault
      9 Invalid input
      8 Disk full

Report written to: log_report_2026-06-29.txt
```

**Validation cases:**

```
devops@testvm:~/day-20$ ./log_analyzer.sh
ERROR: no log file given.
Usage: ./log_analyzer.sh <log_file> [--archive]

devops@testvm:~/day-20$ ./log_analyzer.sh missing.log
ERROR: 'missing.log' does not exist or is not a regular file.

devops@testvm:~/day-20$ echo $?
1
```

The generated report is saved in this folder as `log_report_2026-06-29.txt`.

---

## How the top-5 pipeline works

This was the interesting part of the task. Building it up one stage at a time:

**Stage 1 — get the ERROR lines:**
```
devops@testvm:~/day-20$ grep "ERROR" sample_log.log | head -3
2026-06-29 08:31:05 [ERROR] Failed to connect - 12153
2026-06-29 08:44:19 [ERROR] Out of memory - 30514
2026-06-29 09:02:47 [ERROR] Disk full - 8122
```

**Stage 2 — cut off everything before the message.** `awk -F'] '` splits on `"] "`, so field 2 is whatever follows the level:
```
devops@testvm:~/day-20$ grep "ERROR" sample_log.log | awk -F'] ' '{print $2}' | head -3
Failed to connect - 12153
Out of memory - 30514
Disk full - 8122
```

**Stage 3 — strip the trailing number.** Without this every line is unique and the counts are all 1:
```
devops@testvm:~/day-20$ grep "ERROR" sample_log.log | awk -F'] ' '{print $2}' | sed 's/ - [0-9]*$//' | head -3
Failed to connect
Out of memory
Disk full
```

**Stage 4 — `sort | uniq -c | sort -rn | head -5`:**
```
     11 Out of memory
     10 Failed to connect
      9 Segmentation fault
      9 Invalid input
      8 Disk full
```

The `sort` before `uniq` is required. **`uniq` only collapses adjacent duplicate lines**, so unsorted input gives nonsense. I got this wrong first time and saw the same message appear four separate times in the output. Then `sort -rn` sorts numerically in reverse to put the biggest count first — `sort -r` alone would sort as text and put "9" above "11".

---

## Commands and tools used

| Tool | How I used it |
|---|---|
| `grep -c` | Count matching lines without printing them |
| `grep -n` | Print matches with their line number, for critical events |
| `grep -E` | Extended regex, for the `ERROR\|Failed` alternation |
| `awk -F'] '` | Split each line on a multi-character separator to isolate the message |
| `sed 's/ - [0-9]*$//'` | Strip the trailing random number |
| `sort` | Group identical messages so `uniq` can count them |
| `uniq -c` | Count occurrences of each unique line |
| `sort -rn` | Order by count, largest first |
| `head -5` | Keep the top 5 |
| `wc -l < file` | Count total lines |
| `{ ... } > file` | Redirect a whole block into the report in one go |
| `mkdir -p` | Create `archive/` only if it is missing |

**On `wc -l < "$LOG_FILE"` versus `wc -l "$LOG_FILE"`:** the redirect version outputs just the number. Passing the filename makes `wc` print the filename too, which then has to be stripped. Small thing, avoids an extra `awk`.

**On the `{ ... } > "$REPORT_FILE"` block:** grouping every `echo` in braces and redirecting once is much cleaner than putting `>>` on twenty separate lines, and it means the file is opened once instead of twenty times.

---

## Two decisions I made

**Archiving is opt-in.** Task 6 says to move the log into `archive/` after analysis. I made that a `--archive` flag rather than automatic, because a script that silently moves its input file is unpleasant to work with — running it twice would fail the second time with "file not found" and the reason would not be obvious.

```
devops@testvm:~/day-20$ ./log_analyzer.sh sample_log.log --archive
...
Report written to: log_report_2026-06-29.txt
Archived sample_log.log -> archive/sample_log.log
```

**`set -uo pipefail` but not `-e`.** `grep -c` returns exit code 1 when it finds zero matches, which is not an error here — a log with no errors is good news. With `set -e` the script would exit on a clean log file, which is exactly backwards.

---

## What I learned

**1. `uniq` needs sorted input.** It only collapses *adjacent* duplicates, so `uniq -c` without a preceding `sort` produces plausible-looking but wrong counts. Nothing warns you. This is the single most useful thing I picked up today, and it applies to any counting pipeline.

**2. Normalise before you group.** Every error line ended in a different random number, so grouping raw lines gave 47 groups of 1. Stripping the variable part with `sed` first is what makes the aggregation meaningful. Real logs have this problem worse — timestamps, request IDs, PIDs all need removing before you can see the pattern.

**3. `grep -c` returning 1 on no matches breaks `set -e`.** Exit codes do not always mean success or failure in the way you assume, and "found nothing" is a normal outcome for a search. Worth checking a command's exit-code behaviour before wrapping it in strict mode.

**One extra:** `awk -F'] '` accepts a multi-character field separator, which made splitting on `"] "` a one-liner. I had assumed `-F` took a single character and was about to write a much uglier `cut`.
