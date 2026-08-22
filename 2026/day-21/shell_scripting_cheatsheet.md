# Shell Scripting Cheat Sheet

My own reference from Days 16–20. Kept short on purpose — this is meant for looking things up mid-task, not for reading end to end.

---

## Quick reference

| Topic | Key syntax | Example |
|-------|-----------|---------|
| Variable | `VAR="value"` | `NAME="DevOps"` (no spaces around `=`) |
| Use variable | `"$VAR"` | `echo "Hello $NAME"` |
| Argument | `$1`, `$2` | `./script.sh arg1` |
| Arg count | `$#` | `if [ $# -eq 0 ]; then` |
| All args | `"$@"` | `for A in "$@"; do` |
| Exit code | `$?` | `echo $?` after a command |
| If | `if [ cond ]; then ... fi` | `if [ -f file ]; then` |
| For loop | `for i in list; do ... done` | `for i in 1 2 3; do` |
| While | `while [ cond ]; do ... done` | `while [ $N -gt 0 ]; do` |
| Function | `name() { ... }` | `greet() { echo "Hi $1"; }` |
| Capture output | `VAR=$(cmd)` | `NOW=$(date +%F)` |
| Arithmetic | `$(( ))` | `N=$((N - 1))` |
| Grep | `grep pattern file` | `grep -i "error" log.txt` |
| Awk | `awk '{print $1}' file` | `awk -F: '{print $1}' /etc/passwd` |
| Sed | `sed 's/old/new/g' file` | `sed -i 's/foo/bar/g' config.txt` |
| Strict mode | `set -euo pipefail` | First line after the shebang |

---

## 1. Basics

### Shebang

```bash
#!/bin/bash
```

Tells the kernel which interpreter to run the file with. Without it the calling shell is used, which works until something other than bash runs the script — cron, `sh`, a CI job — and then bash-only syntax breaks. Ignored entirely if you run `bash script.sh`, because you named the interpreter yourself.

### Running a script

```bash
chmod +x script.sh     # once, to make it executable
./script.sh            # run it (./ is required, . is not on $PATH)
bash script.sh         # run without the execute bit, ignores the shebang
```

### Comments

```bash
# a whole-line comment
echo "hello"   # an inline comment
```

### Variables

```bash
NAME="Manish"          # no spaces around =
echo "$NAME"           # double quotes: expands   -> Manish
echo '$NAME'           # single quotes: literal   -> $NAME
echo "${NAME}_suffix"  # braces when the name touches other text
readonly PI=3.14       # cannot be changed afterwards
```

**Always quote your variables.** `touch $FILE` with `FILE="my report.txt"` creates two files; `touch "$FILE"` creates one.

### Default values

```bash
echo "${VAR:-default}"     # use "default" if VAR is unset or empty
echo "${1:-}"              # optional argument, safe under set -u
VAR="${VAR:=default}"      # assign the default if unset
```

### Reading input

```bash
read -p "Enter name: " NAME     # -p prints the prompt on the same line
read -s -p "Password: " PASS    # -s hides what is typed
read -t 10 -p "Quick: " ANS     # -t gives up after 10 seconds
```

### Command-line arguments

| Variable | Holds |
|---|---|
| `$0` | Script name as called |
| `$1`, `$2`, … | Positional arguments |
| `$#` | Number of arguments |
| `"$@"` | All arguments, each kept separate |
| `"$*"` | All arguments joined into one string |
| `$?` | Exit code of the last command |
| `$$` | PID of this script |

**Use `"$@"`, not `"$*"`.** Only `"$@"` survives arguments containing spaces.

---

## 2. Operators and conditionals

### String comparison

```bash
[ "$A" = "$B" ]     # equal
[ "$A" != "$B" ]    # not equal
[ -z "$A" ]         # empty
[ -n "$A" ]         # not empty
```

### Integer comparison

```bash
[ "$A" -eq "$B" ]   # equal
[ "$A" -ne "$B" ]   # not equal
[ "$A" -lt "$B" ]   # less than
[ "$A" -gt "$B" ]   # greater than
[ "$A" -le "$B" ]   # less or equal
[ "$A" -ge "$B" ]   # greater or equal
```

**Never use `>` or `<` on numbers inside `[ ]`.** `[ 5 > 10 ]` does not compare — it redirects output into a file called `10` and returns true. Silent, wrong, no error.

### File tests

```bash
[ -f file ]    # regular file exists
[ -d dir ]     # directory exists
[ -e path ]    # exists, either kind
[ -s file ]    # exists and is not empty
[ -r file ]    # readable
[ -w file ]    # writable
[ -x file ]    # executable
```

### if / elif / else

```bash
if [ "$NUM" -gt 0 ]; then
    echo "positive"
elif [ "$NUM" -lt 0 ]; then
    echo "negative"
else
    echo "zero"
fi
```

### Logical operators

```bash
[ -f file ] && echo "exists"              # run if the first succeeded
[ -f file ] || echo "missing"             # run if the first failed
mkdir /tmp/x || echo "already there"      # the standard fallback pattern
if [ -f a ] && [ -f b ]; then ... fi      # two separate tests, AND
if ! [ -f file ]; then ... fi             # negate
```

### case

```bash
case "$1" in
    start)   echo "starting" ;;
    stop)    echo "stopping" ;;
    restart) echo "restarting" ;;
    *)       echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
```

Cleaner than a stack of `elif` when matching one variable against several fixed values. `*)` is the catch-all and goes last.

---

## 3. Loops

### for — list

```bash
for FRUIT in apple banana mango; do
    echo "$FRUIT"
done

for i in {1..10}; do echo "$i"; done       # brace expansion
for i in {1..10..2}; do echo "$i"; done    # step by 2
```

`{1..$MAX}` does **not** work — brace expansion happens before variables are substituted.

### for — C-style

```bash
for (( i=1; i<=10; i++ )); do
    echo "$i"
done
```

Use this when the limit is in a variable.

### while

```bash
while [ "$N" -gt 0 ]; do
    echo "$N"
    N=$((N - 1))          # forget this and it loops forever
done
```

### until

```bash
until [ "$N" -ge 10 ]; do      # runs *until* the condition becomes true
    N=$((N + 1))
done
```

### break and continue

```bash
for i in {1..10}; do
    [ "$i" -eq 3 ] && continue    # skip this iteration
    [ "$i" -eq 8 ] && break       # leave the loop entirely
    echo "$i"
done
```

### Looping over files

```bash
for FILE in *.log; do
    [ -e "$FILE" ] || continue    # guards against no matches
    echo "processing $FILE"
done
```

Without the guard, an empty directory makes the loop run once with `FILE` set to the literal string `*.log`.

### Looping over command output

```bash
while IFS= read -r LINE; do
    echo "got: $LINE"
done < file.txt

# safe with filenames containing spaces or newlines
while IFS= read -r -d '' FILE; do
    echo "$FILE"
done < <(find . -name "*.log" -print0)
```

**Use `< <(cmd)`, not `cmd | while`.** A pipe runs the loop in a subshell, so any variable you set inside is lost when the loop ends. This is the bug that made my Day 19 counter always print 0.

`IFS=` stops leading and trailing whitespace being trimmed; `-r` stops backslashes being interpreted.

---

## 4. Functions

```bash
greet() {
    local NAME="$1"           # $1 is the *function's* argument
    echo "Hello, $NAME!"
}

greet "Manish"                # no parentheses, no commas
```

### Return values

```bash
# WRONG - return sets an exit code, not a value
get_number() { return 42; }
RESULT=$(get_number)          # RESULT is empty

# RIGHT - echo the value, capture with $( )
get_number() { echo 42; }
RESULT=$(get_number)          # RESULT is 42

# return is for success/failure
is_running() {
    systemctl is-active --quiet "$1" && return 0 || return 1
}
if is_running nginx; then echo "up"; fi
```

| Want | Use |
|---|---|
| A value | `echo` inside, capture with `$(func)` |
| Success or failure | `return 0` / `return 1`, test with `if func; then` |

### local

```bash
counter() {
    local COUNT=0        # without 'local' this overwrites any global COUNT
    COUNT=$((COUNT + 1))
}
```

**Variables are global by default in bash.** Put `local` on every variable inside every function.

### Ordering

Functions must be defined before they are called, which is why the `main` call goes on the last line:

```bash
main() { ... }
main "$@"
```

---

## 5. Text processing

### grep

```bash
grep "error" file            # basic search
grep -i "error" file         # case insensitive
grep -c "error" file         # count matches, do not print them
grep -n "error" file         # show line numbers
grep -v "debug" file         # invert: lines NOT matching
grep -r "TODO" .             # recursive through directories
grep -E "ERROR|Failed" file  # extended regex, alternation
grep -q "x" file             # quiet, exit code only - for if statements
grep -A3 -B3 "error" file    # 3 lines after / before each match
```

`grep -c` exits 1 when it finds nothing, which will kill a script running under `set -e`.

### awk

```bash
awk '{print $1}' file                  # first whitespace-separated column
awk '{print $1, $3}' file              # several columns
awk -F: '{print $1}' /etc/passwd       # custom separator
awk -F'] ' '{print $2}' log            # multi-character separator works
awk 'NR==2 {print $5}' file            # only line 2
awk '$3 > 100 {print}' file            # rows where column 3 exceeds 100
awk '{sum+=$1} END {print sum}' file   # running total
awk 'BEGIN{print "start"} {print} END{print "done"}' file
```

`NR` is the current line number, `NF` the number of fields, `$0` the whole line.

### sed

```bash
sed 's/old/new/' file            # first match on each line
sed 's/old/new/g' file           # every match
sed -i 's/old/new/g' file        # edit the file in place
sed -i.bak 's/old/new/g' file    # in place, keeping a .bak copy
sed -n '5,10p' file              # print only lines 5 to 10
sed '/^#/d' file                 # delete comment lines
sed '/^$/d' file                 # delete blank lines
sed 's|/old/path|/new/path|g'    # | as delimiter, avoids escaping slashes
```

`-i` has no undo. Test without it first, or use `-i.bak`.

### cut

```bash
cut -d: -f1 /etc/passwd      # field 1, colon delimited
cut -d, -f1,3 data.csv       # fields 1 and 3
cut -c1-10 file              # characters 1 to 10
```

Simpler than awk, but only handles a single-character delimiter and cannot cope with repeated spaces.

### sort / uniq

```bash
sort file                 # alphabetical
sort -n file              # numeric
sort -rn file             # numeric, descending
sort -k2 file             # by column 2
sort -h file              # human sizes (1K, 2M, 3G)
sort -u file              # sorted, duplicates removed

sort file | uniq          # remove duplicates
sort file | uniq -c       # count each unique line
sort file | uniq -d       # only lines that appear more than once
```

**`uniq` only collapses adjacent lines, so always `sort` first.** Unsorted input gives wrong counts with no warning.

### tr

```bash
tr 'a-z' 'A-Z' < file        # to upper case
tr -d '\r' < file            # strip Windows carriage returns
tr -s ' ' < file             # squeeze repeated spaces into one
tr -dc '0-9' <<< "abc123"    # keep only digits
```

### wc

```bash
wc -l file        # lines
wc -w file        # words
wc -c file        # bytes
wc -l < file      # just the number, no filename
```

### head / tail

```bash
head -n 20 file      # first 20 lines
tail -n 50 file      # last 50 lines
tail -f app.log      # follow as it is written
tail -F app.log      # follow, and survive log rotation
tail -n +5 file      # from line 5 to the end
```

---

## 6. One-liners I actually use

```bash
# Delete files older than 30 days
find /var/log -name "*.gz" -mtime +30 -delete

# Total lines across every .log file
find . -name "*.log" | xargs wc -l | tail -1

# Replace a string in every .conf file below here
find . -name "*.conf" -exec sed -i 's/old.host/new.host/g' {} +

# Is a service running (exit code, not text)
systemctl is-active --quiet nginx && echo "up" || echo "down"

# Alert if root filesystem is over 80 percent
USED=$(df -P / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
[ "$USED" -ge 80 ] && echo "ALERT: disk at ${USED}%"

# Follow a log, errors only, case insensitive
tail -f app.log | grep -i --line-buffered "error"

# Top 10 IPs in an nginx access log
awk '{print $1}' access.log | sort | uniq -c | sort -rn | head -10

# 10 biggest files under a directory
du -ah /var | sort -rh | head -10

# What is using a port
ss -tulpn | grep :8080

# Kill every process matching a name
pkill -f "python app.py"

# Timestamped backup
tar -czf "backup-$(date +%F).tar.gz" -C /home/devops data

# Wait for a port to open, then continue
until nc -z localhost 5432; do sleep 1; done; echo "postgres is up"
```

`--line-buffered` on that `tail -f | grep` matters — without it grep buffers output and nothing appears for ages.

---

## 7. Error handling and debugging

### Exit codes

```bash
command; echo $?      # 0 = success, anything else = failure
exit 0                # explicit success
exit 1                # generic failure
```

Always `exit 1` after printing a usage message. Exiting 0 tells the caller everything worked.

### Strict mode

```bash
set -euo pipefail     # put this straight after the shebang
```

| Flag | Does |
|---|---|
| `set -e` | Exit immediately if any command fails |
| `set -u` | Error on an undefined variable instead of using "" |
| `set -o pipefail` | A pipeline fails if *any* stage fails, not just the last |

Why `pipefail` matters: with `set -e` alone, `cat /missing \| wc -l` reports success, because only `wc`'s exit code counts. Almost every real script uses pipes, so `-e` without `pipefail` gives false confidence.

`set -e` deliberately ignores commands in a `||` or `&&` chain, or in an `if` condition — bash assumes you are handling those failures yourself. That is what makes `mkdir x || echo "exists"` work under strict mode.

Adding `set -u` to an old script usually breaks it on optional variables. Fix with `${VAR:-default}`.

### Debugging

```bash
set -x            # print each command before running it
set +x            # turn it back off
bash -x script.sh # trace the whole run without editing the file
bash -n script.sh # syntax check only, runs nothing
```

`bash -n` before deploying anything catches typos for free.

### trap

```bash
cleanup() {
    rm -f /tmp/lockfile
    echo "cleaned up"
}
trap cleanup EXIT           # runs on any exit, including errors
trap cleanup INT TERM       # runs on Ctrl+C or kill
```

`trap ... EXIT` is the reliable way to remove temp files and lock files. It fires whether the script finished normally, hit an error, or was interrupted.

---

## Things that have caught me out

- Spaces around `=` in an assignment. `NAME = "x"` looks for a command called `NAME`.
- Unquoted `$VAR` splitting on spaces and silently doing the wrong thing.
- `uniq` without a preceding `sort`.
- `cmd | while read` losing variables to a subshell. Use `< <(cmd)`.
- `[ 5 > 10 ]` creating a file instead of comparing numbers.
- `return 42` from a function producing no capturable value.
- Forgetting `local`, so a function quietly overwrites a global.
- Cron having no PATH and no `.bashrc`. Use absolute paths and redirect output.
- `find -mtime +7` meaning more than 7 *complete* days.
- `grep -c` exiting 1 on zero matches and killing a `set -e` script.

---

## Script template I start from

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: $0 <arg>"
    exit 1
}

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $*"
}

cleanup() {
    rm -f /tmp/myscript.lock
}
trap cleanup EXIT

main() {
    [ $# -lt 1 ] && usage
    log "starting"
    # work goes here
    log "done"
}

main "$@"
```
