# Day 10 – File Permissions and File Operations Challenge

Worked through all five tasks in `~/day-10` on my Ubuntu VM.

---

## Task 1: Create files

**Empty file with `touch`:**

```
devops@testvm:~/day-10$ touch devops.txt
```

**File with content using `echo`:**

```
devops@testvm:~/day-10$ echo "Day 10 - learning file permissions" > notes.txt
devops@testvm:~/day-10$ echo "chmod changes permissions" >> notes.txt
devops@testvm:~/day-10$ echo "chown changes ownership" >> notes.txt
```

**Script with `vim`:**

```
devops@testvm:~/day-10$ vim script.sh
```

Inside vim: press `i` to insert, type the line, then `Esc` and `:wq` to save and quit. Content:

```bash
echo "Hello DevOps"
```

**Verify:**

```
devops@testvm:~/day-10$ ls -l
total 12
-rw-rw-r-- 1 devops devops   0 Jun 19 09:12 devops.txt
-rw-rw-r-- 1 devops devops  91 Jun 19 09:14 notes.txt
-rw-rw-r-- 1 devops devops  22 Jun 19 09:16 script.sh
```

All three came out as `-rw-rw-r--` (664). Notice `script.sh` has no `x` even though it is a script. Linux does not care about the `.sh` extension — executable is a permission, not a file type.

---

## Task 2: Read files

**Whole file with `cat`:**

```
devops@testvm:~/day-10$ cat notes.txt
Day 10 - learning file permissions
chmod changes permissions
chown changes ownership
```

**Read-only in vim:**

```
devops@testvm:~/day-10$ vim -R script.sh
```

The status line shows `"script.sh" [readonly] 1 line, 22 bytes`. Trying to type gives `E45: 'readonly' option is set (add ! to override)`. Useful for looking at a production config without the risk of saving a change by accident.

**First 5 lines of /etc/passwd:**

```
devops@testvm:~/day-10$ head -n 5 /etc/passwd
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
bin:x:2:2:bin:/bin:/usr/sbin/nologin
sys:x:3:3:sys:/dev:/usr/sbin/nologin
sync:x:4:65534:sync:/bin:/bin/sync
```

**Last 5 lines:**

```
devops@testvm:~/day-10$ tail -n 5 /etc/passwd
devops:x:1000:1000:DevOps User:/home/devops:/bin/bash
tokyo:x:1001:1001::/home/tokyo:/bin/bash
berlin:x:1002:1002::/home/berlin:/bin/bash
professor:x:1003:1003::/home/professor:/bin/bash
nairobi:x:1004:1006::/home/nairobi:/bin/bash
```

The top of the file is system accounts with `/usr/sbin/nologin` as their shell, which stops anyone logging in as them. The bottom is real humans starting at UID 1000, including the users I made on Day 09.

---

## Task 3: Understand permissions

```
devops@testvm:~/day-10$ ls -l devops.txt notes.txt script.sh
-rw-rw-r-- 1 devops devops  0 Jun 19 09:12 devops.txt
-rw-rw-r-- 1 devops devops 91 Jun 19 09:14 notes.txt
-rw-rw-r-- 1 devops devops 22 Jun 19 09:16 script.sh
```

**How to read `-rw-rw-r--`:**

| Position | Value | Meaning |
|---|---|---|
| 1 | `-` | Regular file (`d` would be a directory, `l` a symlink) |
| 2–4 | `rw-` | **Owner** (devops) can read and write, not execute |
| 5–7 | `rw-` | **Group** (devops) can read and write, not execute |
| 8–10 | `r--` | **Others** can only read |

**In numbers:** r=4, w=2, x=1. So `rw-` = 4+2 = 6, and `r--` = 4. That makes all three files **664**.

**Answering the question directly:**
- Read: everyone — owner, group and others.
- Write: owner and group only.
- Execute: nobody. None of the three files can be run right now.

Worth knowing: 664 comes from the default 666 minus the umask of 002. Directories get 777 minus 002 = 775. Linux never gives execute by default on a new file, which is a sensible safety choice.

---

## Task 4: Modify permissions

### 4.1 Make script.sh executable

**Before:**
```
-rw-rw-r-- 1 devops devops 22 Jun 19 09:16 script.sh
```

```
devops@testvm:~/day-10$ chmod +x script.sh
```

**After:**
```
devops@testvm:~/day-10$ ls -l script.sh
-rwxrwxr-x 1 devops devops 22 Jun 19 09:16 script.sh
```

**Run it:**

```
devops@testvm:~/day-10$ ./script.sh
Hello DevOps
```

`chmod +x` added execute for owner, group and others (664 → 775). To give it only to the owner I would use `chmod u+x`.

The `./` in front is required. Without it, bash searches `$PATH` and the current directory is not on `$PATH`:

```
devops@testvm:~/day-10$ script.sh
script.sh: command not found
```

### 4.2 Make devops.txt read-only

**Before:**
```
-rw-rw-r-- 1 devops devops 0 Jun 19 09:12 devops.txt
```

```
devops@testvm:~/day-10$ chmod a-w devops.txt
```

**After:**
```
devops@testvm:~/day-10$ ls -l devops.txt
-r--r--r-- 1 devops devops 0 Jun 19 09:12 devops.txt
```

444 — readable by everyone, writable by nobody. `chmod 444 devops.txt` does the same thing.

### 4.3 Set notes.txt to 640

**Before:**
```
-rw-rw-r-- 1 devops devops 91 Jun 19 09:14 notes.txt
```

```
devops@testvm:~/day-10$ chmod 640 notes.txt
```

**After:**
```
devops@testvm:~/day-10$ ls -l notes.txt
-rw-r----- 1 devops devops 91 Jun 19 09:14 notes.txt
```

Owner `rw-` (6), group `r--` (4), others `---` (0). This is the standard pattern for a file with something sensitive in it.

### 4.4 Create project/ with 755

```
devops@testvm:~/day-10$ mkdir project
devops@testvm:~/day-10$ chmod 755 project

devops@testvm:~/day-10$ ls -ld project
drwxr-xr-x 2 devops devops 4096 Jun 19 09:34 project
```

`x` means something different on a directory. On a file it means "run this". On a directory it means "enter this". A directory with `r` but no `x` lets me list the names inside but not actually open anything, which produces some confusing errors.

**Everything after Task 4:**

```
devops@testvm:~/day-10$ ls -l
total 16
-r--r--r-- 1 devops devops    0 Jun 19 09:12 devops.txt
-rw-r----- 1 devops devops   91 Jun 19 09:14 notes.txt
drwxr-xr-x 2 devops devops 4096 Jun 19 09:34 project
-rwxrwxr-x 1 devops devops   22 Jun 19 09:16 script.sh
```

---

## Task 5: Test permissions

### Writing to a read-only file

```
devops@testvm:~/day-10$ echo "trying to write" > devops.txt
-bash: devops.txt: Permission denied
```

```
devops@testvm:~/day-10$ vim devops.txt
```

vim opens it but shows `W10: Warning: Changing a readonly file`, and `:wq` fails with `E45: 'readonly' option is set (add ! to override)`.

**The surprising part** — I can still delete it:

```
devops@testvm:~/day-10$ rm devops.txt
rm: remove write-protected regular file 'devops.txt'? n
```

Deleting a file is controlled by the write permission on the **directory**, not on the file. `rm` asks for confirmation as a courtesy, but a `rm -f` would remove it without complaint. A read-only file is not a protected file.

### Executing without execute permission

```
devops@testvm:~/day-10$ chmod -x script.sh
devops@testvm:~/day-10$ ./script.sh
-bash: ./script.sh: Permission denied
```

Restored it afterwards:

```
devops@testvm:~/day-10$ chmod +x script.sh
```

An interesting workaround — passing the file to `bash` directly works even with no execute bit, because bash is the thing being executed and the script is just input:

```
devops@testvm:~/day-10$ chmod -x script.sh
devops@testvm:~/day-10$ bash script.sh
Hello DevOps
```

### Reading a file with no read permission

```
devops@testvm:~/day-10$ sudo -u tokyo cat notes.txt
cat: notes.txt: Permission denied
```

`notes.txt` is 640 and tokyo is not the owner or in the `devops` group, so "others" applies and others get nothing.

### Error messages collected

| What I tried | Error |
|---|---|
| Write to a 444 file | `-bash: devops.txt: Permission denied` |
| Save a read-only file in vim | `E45: 'readonly' option is set (add ! to override)` |
| Run a file with no `x` | `-bash: ./script.sh: Permission denied` |
| Run without `./` | `script.sh: command not found` |
| Read a 640 file as another user | `cat: notes.txt: Permission denied` |

The two "Permission denied" ones look identical but mean different things — one is about writing, one is about executing. The command I ran is the only clue.

---

## Files Created

| File | Created with | Final permissions | Numeric |
|---|---|---|---|
| `devops.txt` | `touch` | `-r--r--r--` | 444 |
| `notes.txt` | `echo >` and `>>` | `-rw-r-----` | 640 |
| `script.sh` | `vim` | `-rwxrwxr-x` | 775 |
| `project/` | `mkdir` | `drwxr-xr-x` | 755 |

---

## Permission Changes

| File | Before | After | Command |
|---|---|---|---|
| `script.sh` | `-rw-rw-r--` (664) | `-rwxrwxr-x` (775) | `chmod +x script.sh` |
| `devops.txt` | `-rw-rw-r--` (664) | `-r--r--r--` (444) | `chmod a-w devops.txt` |
| `notes.txt` | `-rw-rw-r--` (664) | `-rw-r-----` (640) | `chmod 640 notes.txt` |
| `project/` | `drwxrwxr-x` (775) | `drwxr-xr-x` (755) | `chmod 755 project` |

---

## Commands Used

| Command | Purpose |
|---|---|
| `touch devops.txt` | Create an empty file |
| `echo "text" > file` | Create a file with content, overwriting |
| `echo "text" >> file` | Append a line |
| `vim script.sh` | Create and edit a file |
| `vim -R script.sh` | Open read-only |
| `cat notes.txt` | Read the whole file |
| `head -n 5 /etc/passwd` | First 5 lines |
| `tail -n 5 /etc/passwd` | Last 5 lines |
| `ls -l` | Show permissions, owner and group |
| `ls -ld project` | Show the directory's own permissions |
| `chmod +x script.sh` | Add execute for everyone |
| `chmod u+x script.sh` | Add execute for the owner only |
| `chmod a-w devops.txt` | Remove write for everyone |
| `chmod 640 notes.txt` | Set exact permissions numerically |
| `sudo -u tokyo cat notes.txt` | Test access as a different user |

---

## What I Learned

- Executable is a permission, not a file extension. `script.sh` was not runnable until I set the `x` bit, and the `.sh` name meant nothing.
- Read-only does not mean protected. I could still delete a 444 file, because deletion is governed by write permission on the parent directory.
- `x` on a directory means "enter", not "run". Removing it makes the directory unusable even when `r` is still there.
- `./script.sh` and `script.sh` are not the same. The current directory is deliberately kept off `$PATH`, so a typo cannot run a stray script.
- The numbers are just r=4, w=2, x=1 added up per column. Once that clicked, 640 and 755 stopped needing a lookup.
- Two different failures both print "Permission denied", so the command I ran is what tells me whether it was a read, write or execute problem.
