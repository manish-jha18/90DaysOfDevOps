# Day 19 – Log Rotation, Backup and Crontab

Four scripts, all in this folder. First day where the scripts do something I would actually want running unattended on a server, which changes how carefully you have to write them.

---

## Task 1: Log rotation script

**`log_rotate.sh`**

```bash
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
```

**Tested with a directory of files with faked timestamps:**

```
devops@testvm:~/day-19$ ls -la --time-style=+%Y-%m-%d /tmp/lrtest
-rw-r--r-- 1 devops devops 0 2026-05-20 ancient.log.gz
-rw-r--r-- 1 devops devops 0 2026-06-29 app.log
-rw-r--r-- 1 devops devops 0 2026-06-19 old1.log
-rw-r--r-- 1 devops devops 0 2026-06-19 old2.log
-rw-r--r-- 1 devops devops 0 2026-06-29 recent.log

devops@testvm:~/day-19$ ./log_rotate.sh /tmp/lrtest
Rotating logs in: /tmp/lrtest
  compressed: /tmp/lrtest/old1.log
  compressed: /tmp/lrtest/old2.log
  deleted:    /tmp/lrtest/ancient.log.gz
Summary: 2 file(s) compressed, 1 old archive(s) deleted.

devops@testvm:~/day-19$ ls -1 /tmp/lrtest
app.log
old1.log.gz
old2.log.gz
recent.log
```

The two 10-day-old files were compressed, the 40-day-old archive was deleted, and today's files were left alone. `touch -d "10 days ago" file` is how I made test files with old timestamps without waiting a week.

**Error case:**

```
devops@testvm:~/day-19$ ./log_rotate.sh /tmp/nope
ERROR: '/tmp/nope' is not a directory or does not exist.
devops@testvm:~/day-19$ echo $?
1
```

### Why not just `find -exec`

The hint suggests `find ... -exec gzip {} \;`, which works, but it cannot count what it did. The requirement was to print how many files were handled, so I needed the loop.

The awkward-looking parts are there for a reason:

- **`-print0` and `read -d ''`** separate filenames with a null byte instead of a newline. Filenames can legally contain spaces and newlines, and a plain `for FILE in $(find ...)` breaks on the first space. This is the Day 16 word-splitting problem again, in a form that actually bites.
- **`< <(find ...)`** is process substitution rather than a pipe. With `find ... | while read`, the loop runs in a subshell, so `COMPRESSED` gets incremented inside that subshell and the parent still sees 0. I hit exactly this and the summary always printed zero. Feeding the loop from process substitution keeps it in the current shell.

**On `-mtime +7`:** this means "modified more than 7 full 24-hour periods ago". A file modified 7.5 days ago is *not* matched, because `find` truncates to whole days. Off by one in a way that surprises people.

---

## Task 2: Server backup script

**`backup.sh`**

```bash
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
```

**Output:**

```
devops@testvm:~/day-19$ ./backup.sh /tmp/bktest/data /tmp/bktest/backups
Backing up /tmp/bktest/data -> /tmp/bktest/backups/backup-2026-06-29.tar.gz
Archive created.
Verified OK.
  Name  : backup-2026-06-29.tar.gz
  Size  : 1.0K
  Files : 6
No backups older than 14 days to remove.
```

**Error case:**

```
devops@testvm:~/day-19$ ./backup.sh /tmp/nope /tmp/bktest/backups
ERROR: source '/tmp/nope' does not exist.
devops@testvm:~/day-19$ echo $?
1
```

### Verification is the point

The requirement says "verifies the archive was created successfully", and it is worth being strict about what that means. `tar` exiting 0 is not enough on its own, so there are three checks:

1. `tar` returned success
2. `[ -s "$ARCHIVE" ]` — the file exists and is not zero bytes
3. `tar -tzf` — the archive can actually be listed, so it is not truncated

A backup you have never tried to read is not a backup. Check 3 is cheap and catches a disk that filled up halfway through writing.

**`-C` changes directory before archiving.** Without it, `tar -czf backup.tar.gz /home/devops/data` stores full absolute paths and prints `Removing leading '/' from member names`. Extracting it then produces a nested `home/devops/data` tree. With `-C "$(dirname "$SOURCE")" "$(basename "$SOURCE")"` the archive contains just `data/...`.

**One real flaw:** the archive name uses only the date, so running twice in one day silently overwrites the first archive. `date +%Y-%m-%d_%H-%M-%S` would fix it. I left it as the task specified but it is the first thing I would change for real use.

---

## Task 3: Crontab

**What is currently scheduled:**

```
devops@testvm:~/day-19$ crontab -l
no crontab for devops
```

Nothing for my user. The system-wide jobs live elsewhere:

```
devops@testvm:~/day-19$ ls /etc/cron.daily/
apt-compat  dpkg  logrotate  man-db

devops@testvm:~/day-19$ sudo crontab -l -u root
no crontab for root
```

Worth noticing that `logrotate` is already there. Real servers use the `logrotate` tool rather than a hand-written script — Task 1 is about understanding what it does under the hood.

### Cron syntax

```
* * * * *  command
│ │ │ │ │
│ │ │ │ └── Day of week (0-7, both 0 and 7 mean Sunday)
│ │ │ └──── Month (1-12)
│ │ └────── Day of month (1-31)
│ └──────── Hour (0-23)
└────────── Minute (0-59)
```

### My cron entries

```cron
# Rotate logs every day at 2 AM
0 2 * * * /home/devops/day-19/log_rotate.sh /var/log/myapp >> /var/log/log_rotate.log 2>&1

# Full backup every Sunday at 3 AM
0 3 * * 0 /home/devops/day-19/backup.sh /home/devops/data /backups >> /var/log/backup.log 2>&1

# Health check every 5 minutes
*/5 * * * * /home/devops/day-19/health_check.sh >> /var/log/health_check.log 2>&1

# Full maintenance run daily at 1 AM (Task 4)
0 1 * * * /home/devops/day-19/maintenance.sh
```

Reading them:

| Entry | Meaning |
|---|---|
| `0 2 * * *` | Minute 0 of hour 2, every day |
| `0 3 * * 0` | Minute 0 of hour 3, only on Sunday |
| `*/5 * * * *` | Every 5th minute — `*/n` means a step |
| `0 1 * * *` | Minute 0 of hour 1, every day |

### Three things about cron that catch people out

**1. Cron has almost no PATH.** It is typically just `/usr/bin:/bin`. A script that works in your shell fails under cron with `command not found` because it used something in `/usr/local/bin`. Fixes: use absolute paths in scripts, or set `PATH=` at the top of the crontab.

**2. Cron does not load your shell profile.** No `.bashrc`, no `.profile`, no environment variables you set there. If a script needs `$JAVA_HOME` it must set it itself.

**3. Output goes nowhere useful.** Cron emails stdout to the local user, which on most servers means it is silently discarded. `>> /var/log/thing.log 2>&1` on every entry is essential — without it a job can fail every night for a month with no trace. The `2>&1` must come *after* the `>>`, otherwise stderr still goes to the old destination.

A trick for testing: temporarily schedule the job for two minutes from now rather than waiting until 2 AM. And `run-parts --test /etc/cron.daily` shows what would run without running it.

---

## Task 4: Combined maintenance script

**`maintenance.sh`**

```bash
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
```

**What lands in the log:**

```
devops@testvm:~/day-19$ sudo tail -n 16 /var/log/maintenance.log
2026-06-29 01:00:01 | ########## maintenance run started ##########
2026-06-29 01:00:01 | === START: log rotation ===
2026-06-29 01:00:01 |   Rotating logs in: /var/log/myapp
2026-06-29 01:00:02 |   compressed: /var/log/myapp/access-2026-06-21.log
2026-06-29 01:00:02 |   compressed: /var/log/myapp/error-2026-06-21.log
2026-06-29 01:00:02 |   deleted:    /var/log/myapp/access-2026-05-28.log.gz
2026-06-29 01:00:02 |   Summary: 2 file(s) compressed, 1 old archive(s) deleted.
2026-06-29 01:00:02 | === END:   log rotation (ok) ===
2026-06-29 01:00:02 | === START: backup ===
2026-06-29 01:00:02 |   Backing up /home/devops/data -> /backups/backup-2026-06-29.tar.gz
2026-06-29 01:00:04 |   Archive created.
2026-06-29 01:00:04 |   Verified OK.
2026-06-29 01:00:04 |     Name  : backup-2026-06-29.tar.gz
2026-06-29 01:00:04 |     Size  : 24M
2026-06-29 01:00:04 |     Files : 1183
2026-06-29 01:00:04 | === END:   backup (ok) ===
2026-06-29 01:00:04 | ########## maintenance run finished ##########
```

**The cron entry:**

```cron
0 1 * * * /home/devops/day-19/maintenance.sh
```

No redirect needed on this one, because the script writes to its own log file already.

**Details worth explaining:**

- **`SCRIPT_DIR`** is resolved from `${BASH_SOURCE[0]}` rather than assumed. Cron runs jobs from the user's home directory, not from where the script lives, so a relative path to `log_rotate.sh` would fail. This is the single most common reason a script works by hand and fails under cron.
- **Every line gets its own timestamp**, not just the start of the run. When something takes 40 minutes at 3 AM, knowing which step consumed the time is the whole value of the log.
- **`run_step` takes the command as arguments** and runs it with `"$@"`, so adding another step is a single line.
- **A failing step is recorded but does not abort the run.** A failed rotation should not prevent the backup — those are independent, and I would rather have one failure than two.

---

## Scripts in this folder

| Script | What it does |
|---|---|
| `log_rotate.sh` | Compresses `.log` over 7 days, deletes `.gz` over 30 days, prints counts |
| `backup.sh` | Timestamped `tar.gz`, verifies it, prints size, prunes after 14 days |
| `health_check.sh` | Disk threshold and service check, built for a 5-minute cron |
| `maintenance.sh` | Runs rotation and backup, timestamps everything into one log |

---

## What I learned

**1. A pipe into `while read` creates a subshell, and your counters vanish.** My rotation summary printed `0 file(s) compressed` no matter what, because `COMPRESSED` was being incremented inside a subshell that then exited. Switching to `while ... done < <(find ...)` fixed it. This is invisible in small tests and only shows up when you try to keep state.

**2. Scripts written for cron need absolute paths and their own logging.** Cron gives you a near-empty PATH, no shell profile, and throws stdout away. `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` and `>> logfile 2>&1` are not optional extras — without them a job fails nightly and nobody finds out.

**3. "The command succeeded" is weaker than "the result is correct".** `tar` exiting 0 does not prove the archive is usable. Checking it is non-empty and can be listed with `tar -tzf` costs one line and is the difference between a backup and a file you hope is a backup.

**Two smaller ones:**

- `find -mtime +7` means more than 7 *complete* days, so a 7.5-day-old file is not matched.
- Use `-print0` with `read -d ''` when looping over filenames. Anything else breaks on a space.
