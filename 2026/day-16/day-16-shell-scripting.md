# Day 16 – Shell Scripting Basics

First day writing scripts instead of typing commands one at a time. All six scripts are saved in this folder.

---

## Task 1: My first script

**`hello.sh`**

```bash
#!/bin/bash
# Day 16 - Task 1: my first script

echo "Hello, DevOps!"
```

**Run it:**

```
devops@testvm:~/day-16$ chmod +x hello.sh
devops@testvm:~/day-16$ ./hello.sh
Hello, DevOps!
```

### What happens if I remove the shebang line

I tested this properly instead of guessing, and the answer is more interesting than "it breaks".

```
devops@testvm:~/day-16$ cat no_shebang.sh
echo "Hello, DevOps!"

devops@testvm:~/day-16$ chmod +x no_shebang.sh
devops@testvm:~/day-16$ ./no_shebang.sh
Hello, DevOps!
```

It still worked. That surprised me. The reason is that when there is no shebang, the shell running the script falls back to using itself, and my shell is already bash — so it accidentally does the right thing.

The problem shows up as soon as the script uses anything bash-specific and something other than bash runs it:

```
devops@testvm:~/day-16$ cat arrays.sh
FRUITS=("apple" "banana")
echo "${FRUITS[0]}"

devops@testvm:~/day-16$ sh arrays.sh
arrays.sh: 1: Syntax error: "(" unexpected
```

`sh` on Ubuntu is `dash`, not bash, and dash has no arrays. With `#!/bin/bash` at the top the kernel runs bash regardless of what shell called it.

**So the shebang says which interpreter runs the file.** Without it the script works by luck, and the luck runs out on a different machine, in cron, or in a CI job where the calling shell is not bash. Also worth knowing: the shebang is only used when the file is executed directly (`./script.sh`). It is ignored entirely if I run `bash script.sh`, because then I have named the interpreter myself.

---

## Task 2: Variables

**`variables.sh`**

```bash
#!/bin/bash
# Day 16 - Task 2: variables and quoting

NAME="Manish"
ROLE="DevOps Engineer"

echo "Hello, I am $NAME and I am a $ROLE"

# double quotes expand the variable, single quotes do not
echo "Double quotes: $NAME"
echo 'Single quotes: $NAME'
```

**Output:**

```
devops@testvm:~/day-16$ ./variables.sh
Hello, I am Manish and I am a DevOps Engineer
Double quotes: Manish
Single quotes: $NAME
```

### Single vs double quotes

- **Double quotes** expand variables. `"$NAME"` becomes `Manish`.
- **Single quotes** are literal. `'$NAME'` stays as the four characters `$NAME`.

Rule of thumb I am going with: use double quotes by default, single quotes only when I genuinely want a `$` to survive.

**The spacing rule caught me out:**

```
devops@testvm:~/day-16$ NAME = "Manish"
NAME: command not found
```

No spaces around `=`. With a space, bash reads `NAME` as a command and `=` and `"Manish"` as its arguments. `NAME="Manish"` works.

**Why quoting variables matters:**

```
devops@testvm:~/day-16$ FILE="my report.txt"
devops@testvm:~/day-16$ touch $FILE
devops@testvm:~/day-16$ ls
my  report.txt

devops@testvm:~/day-16$ rm my report.txt
devops@testvm:~/day-16$ touch "$FILE"
devops@testvm:~/day-16$ ls
'my report.txt'
```

Unquoted, bash split the value at the space and created two files. Quoted, it made one. This is why almost every variable in a real script is wrapped in double quotes.

---

## Task 3: User input with read

**`greet.sh`**

```bash
#!/bin/bash
# Day 16 - Task 3: reading user input

read -p "Enter your name: " NAME
read -p "Enter your favourite tool: " TOOL

echo "Hello $NAME, your favourite tool is $TOOL"
```

**Output:**

```
devops@testvm:~/day-16$ ./greet.sh
Enter your name: Manish
Enter your favourite tool: Docker
Hello Manish, your favourite tool is Docker
```

`-p` prints the prompt on the same line. Without it I would need a separate `echo`, and the cursor would drop to the next line.

Two flags worth remembering: `read -s` hides the input, which is what you want for a password, and `read -t 10` gives up after 10 seconds so a script does not hang forever waiting for someone who is not there.

---

## Task 4: If-else conditions

**`check_number.sh`**

```bash
#!/bin/bash
# Day 16 - Task 4: positive, negative or zero

read -p "Enter a number: " NUM

if [ "$NUM" -gt 0 ]; then
    echo "$NUM is positive"
elif [ "$NUM" -lt 0 ]; then
    echo "$NUM is negative"
else
    echo "$NUM is zero"
fi
```

**Output across three runs:**

```
devops@testvm:~/day-16$ ./check_number.sh
Enter a number: 42
42 is positive

devops@testvm:~/day-16$ ./check_number.sh
Enter a number: -7
-7 is negative

devops@testvm:~/day-16$ ./check_number.sh
Enter a number: 0
0 is zero
```

**`file_check.sh`**

```bash
#!/bin/bash
# Day 16 - Task 4: does the file exist

read -p "Enter a filename: " FILENAME

if [ -f "$FILENAME" ]; then
    echo "$FILENAME exists and is a regular file"
elif [ -d "$FILENAME" ]; then
    echo "$FILENAME exists but it is a directory, not a file"
else
    echo "$FILENAME does not exist"
fi
```

**Output:**

```
devops@testvm:~/day-16$ ./file_check.sh
Enter a filename: hello.sh
hello.sh exists and is a regular file

devops@testvm:~/day-16$ ./file_check.sh
Enter a filename: /etc
/etc exists but it is a directory, not a file

devops@testvm:~/day-16$ ./file_check.sh
Enter a filename: nothing.txt
nothing.txt does not exist
```

I added the `-d` branch because my first version reported `/etc` as "does not exist", which is wrong and misleading. `-f` means *regular file* specifically, not "something is there".

### Comparison operators

The two sets are not interchangeable, which tripped me up:

| Numbers | Strings | Meaning |
|---|---|---|
| `-eq` | `=` | equal |
| `-ne` | `!=` | not equal |
| `-gt` | `>` | greater than |
| `-lt` | `<` | less than |
| `-ge` | | greater or equal |
| `-le` | | less or equal |

Using `>` on numbers does not compare them — inside `[ ]` it redirects output to a file:

```
devops@testvm:~/day-16$ [ 5 > 10 ] && echo "5 is bigger"
5 is bigger
devops@testvm:~/day-16$ ls
10  hello.sh  variables.sh ...
```

It created a file called `10` and the test succeeded, because a successful redirect returns 0. Completely wrong answer with no error. `-gt` is what I want.

**Common file test flags:**

| Flag | True when |
|---|---|
| `-f` | regular file exists |
| `-d` | directory exists |
| `-e` | exists, either kind |
| `-r` / `-w` / `-x` | readable / writable / executable |
| `-z` | string is empty |
| `-n` | string is not empty |

---

## Task 5: Combining it all

**`server_check.sh`**

```bash
#!/bin/bash
# Day 16 - Task 5: check a service status

SERVICE="ssh"

read -p "Do you want to check the status of $SERVICE? (y/n) " ANSWER

if [ "$ANSWER" = "y" ]; then
    if systemctl is-active --quiet "$SERVICE"; then
        echo "$SERVICE is ACTIVE"
    else
        echo "$SERVICE is NOT active"
    fi
    systemctl status "$SERVICE" --no-pager
elif [ "$ANSWER" = "n" ]; then
    echo "Skipped."
else
    echo "Please answer y or n"
fi
```

**Output — answering y:**

```
devops@testvm:~/day-16$ ./server_check.sh
Do you want to check the status of ssh? (y/n) y
ssh is ACTIVE
● ssh.service - OpenBSD Secure Shell server
     Loaded: loaded (/lib/systemd/system/ssh.service; enabled; vendor preset: enabled)
     Active: active (running) since Sat 2026-06-27 07:14:02 UTC; 2h 31min ago
   Main PID: 806 (sshd)
      Tasks: 1 (limit: 4558)
     Memory: 8.0M
        CPU: 341ms
```

**Answering n:**

```
devops@testvm:~/day-16$ ./server_check.sh
Do you want to check the status of ssh? (y/n) n
Skipped.
```

**Answering something else:**

```
devops@testvm:~/day-16$ ./server_check.sh
Do you want to check the status of ssh? (y/n) maybe
Please answer y or n
```

The useful discovery here was `systemctl is-active --quiet`. My first attempt tried to grep the status text:

```bash
systemctl status "$SERVICE" | grep -q "active (running)"
```

That works until the output wording changes or the locale is different. `is-active --quiet` prints nothing and just sets the exit code, which is exactly what an `if` needs. Parsing human-readable output is fragile; using a command's exit code is not.

---

## Scripts in this folder

| Script | What it does |
|---|---|
| `hello.sh` | Prints a message, demonstrates the shebang |
| `variables.sh` | Variables and single vs double quotes |
| `greet.sh` | Reads two values from the user |
| `check_number.sh` | Positive, negative or zero |
| `file_check.sh` | Tests for a file or a directory |
| `server_check.sh` | Asks, then reports whether a service is active |

---

## What I learned

**1. The shebang is about portability, not about making the script run.** My script without one worked fine, because my interactive shell happens to be bash. It would break the moment cron, `sh`, or a different distro ran it. Working on my machine and being correct are two different things.

**2. Quote your variables.** `touch $FILE` created two files from `"my report.txt"` while `touch "$FILE"` created one. Word splitting is silent — no error, just wrong behaviour. Double quotes by default is the habit worth building.

**3. Use exit codes, not text output, for decisions.** `systemctl is-active --quiet` gives a clean 0 or 1. Grepping for "active (running)" happens to work today and breaks when the message changes. The same idea applies to `[ 5 > 10 ]` silently creating a file instead of comparing numbers — the wrong tool fails without complaining.

**One more that cost me time:** no spaces around `=` in an assignment. `NAME = "Manish"` makes bash look for a command called `NAME`.
