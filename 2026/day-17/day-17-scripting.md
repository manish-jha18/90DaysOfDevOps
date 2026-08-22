# Day 17 – Loops, Arguments and Error Handling

Seven scripts today, all saved in this folder. This is the day scripts stopped being a list of commands and started making decisions.

---

## Task 1: For loops

**`for_loop.sh`**

```bash
#!/bin/bash
# Day 17 - Task 1: loop through a list

for FRUIT in apple banana mango orange grapes; do
    echo "Fruit: $FRUIT"
done
```

**Output:**

```
devops@testvm:~/day-17$ ./for_loop.sh
Fruit: apple
Fruit: banana
Fruit: mango
Fruit: orange
Fruit: grapes
```

**`count.sh`**

```bash
#!/bin/bash
# Day 17 - Task 1: print 1 to 10

for i in {1..10}; do
    echo "Number: $i"
done
```

**Output:**

```
devops@testvm:~/day-17$ ./count.sh
Number: 1
Number: 2
Number: 3
Number: 4
Number: 5
Number: 6
Number: 7
Number: 8
Number: 9
Number: 10
```

`{1..10}` is brace expansion — bash builds the whole list before the loop starts. `{1..10..2}` steps by 2. The C-style form also works and is better when the limit is a variable:

```bash
for (( i=1; i<=10; i++ )); do
    echo "Number: $i"
done
```

Brace expansion does **not** work with variables. `{1..$MAX}` produces the literal string `{1..$MAX}` rather than a range, which is a genuinely confusing failure. Use the C-style loop or `seq` when the count is dynamic.

---

## Task 2: While loop

**`countdown.sh`**

```bash
#!/bin/bash
# Day 17 - Task 2: count down to zero

read -p "Enter a number to count down from: " NUM

while [ "$NUM" -gt 0 ]; do
    echo "$NUM"
    NUM=$((NUM - 1))
done

echo "Done!"
```

**Output:**

```
devops@testvm:~/day-17$ ./countdown.sh
Enter a number to count down from: 5
5
4
3
2
1
Done!
```

`$(( ))` is arithmetic expansion. Inside it, variables do not need a `$`, so `$((NUM - 1))` works. My first attempt was `NUM=$NUM-1`, which set NUM to the literal string `5-1` and then the loop compared a string to a number and errored.

**When to use which:** a `for` loop when I know the list up front, a `while` loop when it runs until a condition changes. The countdown could be a for loop, but "keep going while the disk is over 80%" could not.

The obvious bug to avoid is forgetting `NUM=$((NUM - 1))`. The condition never changes and the script loops forever. I did this once and needed Ctrl+C.

---

## Task 3: Command-line arguments

**`greet.sh`**

```bash
#!/bin/bash
# Day 17 - Task 3: greet using a command line argument

if [ $# -eq 0 ]; then
    echo "Usage: ./greet.sh <name>"
    exit 1
fi

echo "Hello, $1!"
```

**Output:**

```
devops@testvm:~/day-17$ ./greet.sh Manish
Hello, Manish!

devops@testvm:~/day-17$ ./greet.sh
Usage: ./greet.sh <name>

devops@testvm:~/day-17$ echo $?
1
```

`exit 1` matters. A usage message followed by exit code 0 tells the caller everything is fine, which breaks anything checking the result. Non-zero means failure, and 0 means success.

**`args_demo.sh`**

```bash
#!/bin/bash
# Day 17 - Task 3: show what the special argument variables hold

echo "Script name         (\$0): $0"
echo "Number of arguments (\$#): $#"
echo "All arguments       (\$@): $@"
echo "First argument      (\$1): $1"
echo "Second argument     (\$2): $2"

echo "---"
echo "Looping over each argument:"
for ARG in "$@"; do
    echo "  -> $ARG"
done
```

**Output:**

```
devops@testvm:~/day-17$ ./args_demo.sh nginx docker k8s
Script name         ($0): ./args_demo.sh
Number of arguments ($#): 3
All arguments       ($@): nginx docker k8s
First argument      ($1): nginx
Second argument     ($2): docker
---
Looping over each argument:
  -> nginx
  -> docker
  -> k8s
```

Note the backslashes in the script — `\$0` prints the literal text `$0` while the unescaped `$0` after it prints the value.

### `"$@"` vs `"$*"`

These look identical until an argument contains a space:

```
devops@testvm:~/day-17$ cat at_vs_star.sh
for A in "$@"; do echo "[at]   $A"; done
for A in "$*"; do echo "[star] $A"; done

devops@testvm:~/day-17$ ./at_vs_star.sh "hello world" second
[at]   hello world
[at]   second
[star] hello world second
```

`"$@"` keeps each argument separate. `"$*"` joins everything into one string. **`"$@"` with the quotes is what you want almost every time** — it is the only form that survives filenames with spaces.

| Variable | Holds |
|---|---|
| `$0` | Script name as it was called |
| `$1`, `$2`, … | Positional arguments |
| `$#` | How many arguments |
| `"$@"` | All arguments, each one separate |
| `"$*"` | All arguments joined into one string |
| `$?` | Exit code of the last command |
| `$$` | PID of the running script |

---

## Task 4: Install packages via script

**`install_packages.sh`**

```bash
#!/bin/bash
# Day 17 - Task 4 and 5: install packages if missing, root required

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: this script must be run as root."
    echo "Try: sudo $0"
    exit 1
fi

PACKAGES="nginx curl wget"

for PKG in $PACKAGES; do
    if dpkg -s "$PKG" &> /dev/null; then
        echo "[SKIP]    $PKG is already installed"
    else
        echo "[INSTALL] $PKG is missing, installing now..."
        if apt-get install -y "$PKG" &> /dev/null; then
            echo "[OK]      $PKG installed successfully"
        else
            echo "[FAIL]    could not install $PKG"
        fi
    fi
done

echo "Done."
```

**Without root (the Task 5 check):**

```
devops@testvm:~/day-17$ ./install_packages.sh
ERROR: this script must be run as root.
Try: sudo ./install_packages.sh
```

**With root:**

```
devops@testvm:~/day-17$ sudo ./install_packages.sh
[INSTALL] nginx is missing, installing now...
[OK]      nginx installed successfully
[SKIP]    curl is already installed
[SKIP]    wget is already installed
Done.
```

**Run a second time:**

```
devops@testvm:~/day-17$ sudo ./install_packages.sh
[SKIP]    nginx is already installed
[SKIP]    curl is already installed
[SKIP]    wget is already installed
Done.
```

The second run doing nothing is the point. A script that can be run repeatedly without changing the result is **idempotent**, and that is what makes it safe to put in automation. Without the `dpkg -s` check the script would reinstall packages every run.

`dpkg -s "$PKG" &> /dev/null` throws away both stdout and stderr and only leaves the exit code, which is all the `if` needs. `&>` is bash shorthand for `> /dev/null 2>&1`.

One caveat: `dpkg -s` also returns 0 for a package that was removed but not purged, since the config files are still registered. `dpkg -l "$PKG" | grep -q '^ii'` is stricter, checking the package is genuinely installed.

---

## Task 5: Error handling

**`safe_script.sh`**

```bash
#!/bin/bash
# Day 17 - Task 5: basic error handling

set -e

TARGET="/tmp/devops-test"

mkdir "$TARGET" || echo "Directory already exists, carrying on"

cd "$TARGET" || { echo "Could not enter $TARGET"; exit 1; }

echo "created by safe_script.sh" > notes.txt || { echo "Could not write the file"; exit 1; }

echo "All steps finished. Working directory is now $(pwd)"
ls -l "$TARGET"
```

**First run:**

```
devops@testvm:~/day-17$ ./safe_script.sh
All steps finished. Working directory is now /tmp/devops-test
total 4
-rw-rw-r-- 1 devops devops 26 Jun 27 14:22 notes.txt
```

**Second run, when the directory already exists:**

```
devops@testvm:~/day-17$ ./safe_script.sh
mkdir: cannot create directory '/tmp/devops-test': File exists
Directory already exists, carrying on
All steps finished. Working directory is now /tmp/devops-test
total 4
-rw-rw-r-- 1 devops devops 26 Jun 27 14:23 notes.txt
```

### What `set -e` and `||` actually do together

This is the part I had to test to believe. `set -e` means "exit immediately if any command fails". So why did `mkdir` failing on the second run not kill the script?

Because **`set -e` ignores any command that is part of a `||` or `&&` chain**. The shell assumes that if you wrote `||`, you are handling the failure yourself. That is exactly what makes the pattern work: `set -e` catches the failures I did *not* anticipate, and `|| { ... }` handles the ones I did.

Proving it, with the `||` removed:

```
devops@testvm:~/day-17$ cat no_handler.sh
#!/bin/bash
set -e
mkdir /tmp/devops-test
echo "this line never prints"

devops@testvm:~/day-17$ ./no_handler.sh
mkdir: cannot create directory '/tmp/devops-test': File exists
devops@testvm:~/day-17$ echo $?
1
```

The script stopped at the failure and never reached the `echo`. Without `set -e` it would have carried on regardless — which is how a backup script ends up cheerfully reporting success after failing to create the backup directory.

**Why `cd` gets a hard exit but `mkdir` does not:** an existing directory is fine, so the script continues. A failed `cd` is not fine — every following command would run in the wrong directory. Writing a file into the wrong place is much worse than a clear error message.

The `{ echo ...; exit 1; }` braces group the two commands so both run on failure. The semicolon before the closing brace is required, and I forgot it twice.

---

## Scripts in this folder

| Script | What it does |
|---|---|
| `for_loop.sh` | Loops over a list of five fruits |
| `count.sh` | Prints 1 to 10 with brace expansion |
| `countdown.sh` | While loop counting down to zero |
| `greet.sh` | Uses `$1`, exits 1 with usage if missing |
| `args_demo.sh` | Shows `$0`, `$#`, `$@`, `$1`, `$2` |
| `install_packages.sh` | Root check, then installs only what is missing |
| `safe_script.sh` | `set -e` plus `\|\|` error handling |

---

## What I learned

**1. `set -e` and `||` are partners, not alternatives.** `set -e` stops the script on any unexpected failure; `||` marks the failures I have deliberately planned for and want to survive. Once I understood that `set -e` deliberately skips commands in a `||` chain, both stopped feeling like magic.

**2. Idempotency is a design choice, and it comes from checking before acting.** `install_packages.sh` checks with `dpkg -s` before installing, so the second run is a no-op. That single check is the difference between a script that is safe to schedule and one nobody dares run twice.

**3. Always quote `"$@"`.** Unquoted, or as `"$*"`, arguments containing spaces get mangled — silently, with no error. Same class of bug as unquoted variables on Day 16, and the same fix.

**Two smaller ones:**

- Brace expansion `{1..10}` is resolved before variables exist, so `{1..$MAX}` does not work. Use a C-style loop when the limit is dynamic.
- `exit 1` after a usage message. Printing an error and exiting 0 tells the caller everything succeeded.
