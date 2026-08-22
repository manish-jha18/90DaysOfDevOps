# Day 18 – Functions and Intermediate Concepts

Five scripts, all in this folder. Functions plus strict mode is where scripts start looking like something I would be comfortable putting on a server.

---

## Task 1: Basic functions

**`functions.sh`**

```bash
#!/bin/bash
# Day 18 - Task 1: basic functions

greet() {
    echo "Hello, $1!"
}

add() {
    local SUM=$(( $1 + $2 ))
    echo "$1 + $2 = $SUM"
}

greet "Manish"
greet "DevOps"
add 5 7
add 100 250
```

**Output:**

```
devops@testvm:~/day-18$ ./functions.sh
Hello, Manish!
Hello, DevOps!
5 + 7 = 12
100 + 250 = 350
```

The thing that surprised me: functions take arguments the same way scripts do. Inside `greet`, `$1` is the function's first argument, not the script's. The function shadows the script's `$1` while it runs.

Two rules I hit immediately:

- **Define before you call.** Bash reads top to bottom, so calling a function above its definition gives `command not found`. That is why `main` is always called on the very last line.
- **No commas or parentheses when calling.** It is `greet "Manish"`, not `greet("Manish")`. The empty `()` in the definition is just syntax and never holds parameters.

---

## Task 2: Functions with return values

**`disk_check.sh`**

```bash
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
```

**Output:**

```
devops@testvm:~/day-18$ ./disk_check.sh
--- Disk usage of / ---
Filesystem      Size  Used Avail Use% Mounted on
/dev/root        19G  7.8G   11G  43% /

--- Memory usage ---
               total        used        free      shared  buff/cache   available
Mem:           3.8Gi       734Mi       1.8Gi       1.0Mi       1.2Gi       2.8Gi
Swap:          2.0Gi          0B       2.0Gi
```

### `return` does not do what I expected

This is the biggest gotcha of the day. In most languages a function returns a value. In bash, `return` sets an **exit code** — a number from 0 to 255 — not a value.

```
devops@testvm:~/day-18$ cat return_test.sh
get_number() {
    return 42
}
RESULT=$(get_number)
echo "Captured: '$RESULT'"
echo "Exit code: $?"

devops@testvm:~/day-18$ ./return_test.sh
Captured: ''
Exit code: 0
```

`$RESULT` is empty, because `return 42` produced no output to capture. To get a value out of a function you **echo it and capture with `$( )`**:

```bash
get_number() {
    echo 42
}
RESULT=$(get_number)   # RESULT is now 42
```

So the two mechanisms are:

| Want | Use |
|---|---|
| A value | `echo` inside, capture with `$(func)` |
| Success or failure | `return 0` / `return 1`, check with `if func; then` |

A knock-on effect: a function that echoes its result cannot also print progress messages, because those get captured too. Send status output to stderr with `>&2` when a function has to do both.

---

## Task 3: Strict mode — `set -euo pipefail`

**`strict_demo.sh`**

```bash
#!/bin/bash
# Day 18 - Task 3: what strict mode catches
set -euo pipefail

echo "Script started"

# 1. set -u : using a variable that was never defined
echo "About to use an undefined variable..."
echo "Value is: $UNDEFINED_VAR"

# these lines are never reached
echo "This line never prints"
```

**Output:**

```
devops@testvm:~/day-18$ ./strict_demo.sh
Script started
About to use an undefined variable...
./strict_demo.sh: line 9: UNDEFINED_VAR: unbound variable

devops@testvm:~/day-18$ echo $?
1
```

The script stopped at the undefined variable and exited 1.

### What each flag does

**`set -e` → exit immediately if a command fails**

Without it, a script carries straight on after a failure:

```
devops@testvm:~/day-18$ bash -c 'cp /nope /tmp/x 2>/dev/null; echo "still running"'
still running

devops@testvm:~/day-18$ bash -c 'set -e; cp /nope /tmp/x 2>/dev/null; echo "never printed"'
devops@testvm:~/day-18$ echo $?
1
```

This is how a backup script reports success after the copy failed. Exception, from Day 17: commands in a `||` or `&&` chain, or in an `if` condition, are exempt — bash assumes you are handling those yourself.

**`set -u` → error on an undefined variable**

Without it an undefined variable is silently empty, which is genuinely dangerous:

```
devops@testvm:~/day-18$ bash -c 'echo "would delete: /data/$TYPO/"'
would delete: /data//
```

That expanded to `/data/`. In a real script with `rm -rf` and a mistyped variable name, this is the classic way to delete far more than intended. `set -u` turns the typo into an immediate error instead.

**`set -o pipefail` → a pipeline fails if *any* command in it fails**

This one I had to test to believe. By default a pipeline only reports the exit code of the **last** command:

```
devops@testvm:~/day-18$ bash -c 'cat /nonexistent 2>/dev/null | wc -l; echo "pipeline exit code: $?"'
0
pipeline exit code: 0
```

`cat` failed, but `wc -l` succeeded, so the pipeline reported success. With pipefail:

```
devops@testvm:~/day-18$ bash -c 'set -o pipefail; cat /nonexistent 2>/dev/null | wc -l; echo "pipeline exit code: $?"'
0
pipeline exit code: 1
```

And this is why `-e` alone is not enough:

```
devops@testvm:~/day-18$ bash -c 'set -e; cat /nonexistent 2>/dev/null | wc -l; echo "reached this line"'
0
reached this line

devops@testvm:~/day-18$ bash -c 'set -eo pipefail; cat /nonexistent 2>/dev/null | wc -l; echo "never reached"'
0
devops@testvm:~/day-18$ echo $?
1
```

With `set -e` alone the failure was invisible, because the pipeline as a whole "succeeded". `pipefail` is what makes `-e` work on pipelines, and almost everything real involves a pipe.

**Summary:**

| Flag | Catches |
|---|---|
| `set -e` | A command failed and the script carried on anyway |
| `set -u` | A typo in a variable name silently becoming an empty string |
| `set -o pipefail` | A failure hidden in the middle of a pipeline |

One practical note: adding `set -u` to an existing script often breaks it straight away, usually on optional variables. The fix is a default value — `${VAR:-fallback}` uses `fallback` when `VAR` is unset, and `${1:-}` allows an optional argument.

---

## Task 4: Local variables

**`local_demo.sh`**

```bash
#!/bin/bash
# Day 18 - Task 4: local variables vs global ones

MESSAGE="I am the original global value"

leaky_function() {
    MESSAGE="the global was overwritten in here"
    echo "  inside leaky_function : $MESSAGE"
}

safe_function() {
    local MESSAGE="I only exist inside this function"
    echo "  inside safe_function  : $MESSAGE"
}

echo "Before any function     : $MESSAGE"

safe_function
echo "After safe_function     : $MESSAGE"

leaky_function
echo "After leaky_function    : $MESSAGE"
```

**Output:**

```
devops@testvm:~/day-18$ ./local_demo.sh
Before any function     : I am the original global value
  inside safe_function  : I only exist inside this function
After safe_function     : I am the original global value
  inside leaky_function : the global was overwritten in here
After leaky_function    : the global was overwritten in here
```

The contrast is in the last two lines. After `safe_function` the global is untouched. After `leaky_function` it has been permanently changed.

**Everything in bash is global by default.** That is backwards from most languages, where a variable inside a function is local unless you say otherwise. Here, a variable named `COUNT` or `FILE` inside a function will quietly overwrite a variable of the same name in the main script.

That failure is nasty because it happens at a distance — the function looks fine, and something completely unrelated later in the script misbehaves. `local` costs one word and removes the whole class of bug, so it goes on every variable inside every function.

---

## Task 5: System info reporter

**`system_info.sh`**

```bash
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
```

**Output:**

```
devops@testvm:~/day-18$ ./system_info.sh
System report generated on 2026-06-28 11:14:07

==============================================
 HOSTNAME AND OS
==============================================
Hostname : testvm
Kernel   : 5.15.0-119-generic
OS       : Ubuntu 22.04.4 LTS

==============================================
 UPTIME AND LOAD
==============================================
up 5 hours, 12 minutes
Load average: 0.04 0.09 0.06

==============================================
 DISK USAGE (TOP 5)
==============================================
Filesystem      Size  Used Avail Use% Mounted on
/dev/root        19G  7.8G   11G  43% /
/dev/sda15      105M  6.1M   99M   6% /boot/efi

==============================================
 MEMORY USAGE
==============================================
               total        used        free      shared  buff/cache   available
Mem:           3.8Gi       734Mi       1.8Gi       1.0Mi       1.2Gi       2.8Gi
Swap:          2.0Gi          0B       2.0Gi

==============================================
 TOP 5 PROCESSES BY CPU
==============================================
    PID %CPU %MEM COMMAND
   1847  1.2  0.9 python3
    412  0.3  0.3 systemd-journal
    806  0.1  0.2 sshd
      1  0.0  0.4 systemd
    658  0.0  0.1 cron

Report complete.
```

**What I did deliberately here:**

- **`print_header` exists so the format lives in one place.** Changing the divider means editing one function, not five.
- **A `main` function called on the last line.** Everything above is definitions, and the single call at the bottom shows the order of execution at a glance.
- **`set -euo pipefail` at the top,** which caught a real bug while writing this — my first `disk_info` used a variable I had misspelled, and `-u` failed it immediately instead of printing a blank section.
- **`$( )` rather than backticks** for command substitution. It nests properly and is easier to read.

---

## Scripts in this folder

| Script | What it does |
|---|---|
| `functions.sh` | `greet` and `add`, showing function arguments |
| `disk_check.sh` | Disk and memory checks split into functions |
| `strict_demo.sh` | Demonstrates `set -u` stopping the script |
| `local_demo.sh` | Shows a leaky global versus a `local` variable |
| `system_info.sh` | Full report built from six functions plus `main` |

---

## What I learned

**1. `return` in bash is an exit code, not a value.** `RESULT=$(get_number)` came back empty because `return 42` produces no output. To pass a value out you `echo` it and capture with `$( )`; `return` is only for success or failure. This is the one that would have cost me an hour if I had met it in a real script instead of a demo.

**2. `set -euo pipefail` is three separate protections and `pipefail` is the one people forget.** I proved that `set -e` alone lets a failing `cat` in a pipeline pass silently, because only the last command's exit code counts. Since nearly every real script uses pipes, `-e` without `pipefail` gives false confidence.

**3. Variables in bash are global unless you say otherwise.** `local_demo.sh` showed a function permanently overwriting a variable in the main script. Most languages work the other way round, so this is easy to walk into. One `local` keyword prevents it.

**Two extras worth keeping:**

- Functions must be defined before they are called, which is why `main` goes at the bottom.
- `set -u` breaks scripts that rely on optional variables. `${VAR:-default}` is the fix.
