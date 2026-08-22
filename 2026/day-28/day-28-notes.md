# Day 28 – Revision: Days 1 to 27

Four weeks in. No new material today, just an honest audit of what has actually stuck.

---

## Task 1: Self-assessment checklist

Marked honestly rather than optimistically, because the point is to find gaps.

### Linux

| Skill | Status |
|---|---|
| Navigate the file system, create/move/delete files and directories | Confident |
| Manage processes — list, kill, background/foreground | Confident |
| Work with systemd — start, stop, enable, check status | Confident |
| Read and edit text files using vi/vim or nano | **Need to revisit** |
| Troubleshoot CPU, memory, disk with top, free, df, du | Confident |
| Explain the file system hierarchy | Confident |
| Create users and groups, manage passwords | Confident |
| Set permissions with chmod (numeric and symbolic) | **Need to revisit** — symbolic form only |
| Change ownership with chown and chgrp | Confident |
| Create and manage LVM volumes | **Need to revisit** |
| Check connectivity — ping, curl, ss, dig | Confident |
| Explain DNS, IP addressing, subnets, ports | Confident |

### Shell scripting

| Skill | Status |
|---|---|
| Variables, arguments, user input | Confident |
| if/elif/else and case | Confident |
| for, while, until loops | Confident |
| Functions with arguments and return values | Confident |
| grep, awk, sed, sort, uniq | Confident on grep/sort/uniq, shaky on awk beyond `{print $1}` |
| set -e, set -u, set -o pipefail, trap | Confident on the set flags, **have not used trap for real** |
| Schedule scripts with crontab | Confident |

### Git and GitHub

| Skill | Status |
|---|---|
| init, stage, commit, log | Confident |
| Create and switch branches | Confident |
| Push and pull | Confident |
| Explain clone vs fork | Confident |
| Merge — fast-forward vs merge commit | Confident |
| Rebase, and when to use it over merge | Confident |
| stash and stash pop | Confident |
| Cherry-pick | Confident |
| Squash merge vs regular merge | Confident |
| reset (soft/mixed/hard) and revert | Confident |
| GitFlow, GitHub Flow, Trunk-Based | Confident on what they are, **less sure choosing between them under real constraints** |
| GitHub CLI for repos, PRs, issues | Confident |

**Tally:** 24 confident, 5 need revisiting, 0 not attempted.

The pattern is clear — the gaps are in things I read about but did not use enough. `trap`, symbolic `chmod` and LVM were each done once and not repeated.

---

## Task 2: Revisiting weak spots

### 1. Symbolic chmod

Numeric form is automatic now. Symbolic still made me stop and think, so I drilled it.

```
devops@testvm:~/revision$ touch test.sh && ls -l test.sh
-rw-rw-r-- 1 devops devops 0 Jul  6 09:22 test.sh

devops@testvm:~/revision$ chmod u+x test.sh && ls -l test.sh
-rwxrw-r-- 1 devops devops 0 Jul  6 09:22 test.sh

devops@testvm:~/revision$ chmod g-w test.sh && ls -l test.sh
-rwxr--r-- 1 devops devops 0 Jul  6 09:22 test.sh

devops@testvm:~/revision$ chmod o= test.sh && ls -l test.sh
-rwxr----- 1 devops devops 0 Jul  6 09:22 test.sh

devops@testvm:~/revision$ chmod a+r test.sh && ls -l test.sh
-rwxr--r-- 1 devops devops 0 Jul  6 09:22 test.sh
```

The grammar finally landed: **who** + **operator** + **what**.

| Who | Operator | What |
|---|---|---|
| `u` owner | `+` add | `r` read |
| `g` group | `-` remove | `w` write |
| `o` others | `=` set exactly | `x` execute |
| `a` all | | |

What I had been missing is when symbolic is genuinely better. `chmod +x script.sh` adds execute **without touching anything else**. The numeric equivalent means working out all nine bits and risks changing something by accident. And `chmod -R u+X dir/` with a capital `X` adds execute only to directories and files that already have it — impossible to express numerically. That one is genuinely useful for fixing a source tree.

### 2. LVM

Done once on Day 13 and not since, which is exactly how knowledge evaporates. Rebuilt it from scratch without looking at my notes.

```
devops@testvm:~$ sudo dd if=/dev/zero of=/tmp/disk2.img bs=1M count=512
512+0 records in
512+0 records out
536870912 bytes (537 MB, 512 MiB) copied, 0.94 s, 571 MB/s

devops@testvm:~$ sudo losetup -fP /tmp/disk2.img
devops@testvm:~$ sudo pvcreate /dev/loop1
  Physical volume "/dev/loop1" successfully created.
devops@testvm:~$ sudo vgcreate revision-vg /dev/loop1
  Volume group "revision-vg" successfully created
devops@testvm:~$ sudo lvcreate -L 200M -n test-lv revision-vg
  Logical volume "test-lv" created.
devops@testvm:~$ sudo mkfs.ext4 /dev/revision-vg/test-lv > /dev/null
devops@testvm:~$ sudo mkdir -p /mnt/test && sudo mount /dev/revision-vg/test-lv /mnt/test
devops@testvm:~$ df -h /mnt/test
Filesystem                        Size  Used Avail Use% Mounted on
/dev/mapper/revision--vg-test--lv 190M   14K  176M   1% /mnt/test
```

Got the chain right from memory: **PV → VG → LV → filesystem → mount**. What I had half-forgotten was that extending is two commands, not one:

```
devops@testvm:~$ sudo lvextend -L +100M /dev/revision-vg/test-lv
  Size of logical volume revision-vg/test-lv changed from 200.00 MiB to 300.00 MiB.
devops@testvm:~$ df -h /mnt/test | tail -1
/dev/mapper/revision--vg-test--lv 190M   14K  176M   1% /mnt/test
```

Still 190M — because `lvextend` grew the container and the filesystem has not been told.

```
devops@testvm:~$ sudo resize2fs /dev/revision-vg/test-lv
The filesystem on /dev/revision-vg/test-lv is now 307200 (1k) blocks long.
devops@testvm:~$ df -h /mnt/test | tail -1
/dev/mapper/revision--vg-test--lv 287M   14K  269M   1% /mnt/test
```

Cleaned up afterwards with `umount`, `lvremove`, `vgremove`, `pvremove`, `losetup -d`.

### 3. trap

I had documented `trap` in the Day 21 cheat sheet without ever using it, which does not count.

```bash
#!/bin/bash
set -euo pipefail

LOCKFILE="/tmp/revision.lock"
WORKDIR=$(mktemp -d)

cleanup() {
    echo "cleanup running..."
    rm -f "$LOCKFILE"
    rm -rf "$WORKDIR"
    echo "cleanup done"
}
trap cleanup EXIT

if [ -e "$LOCKFILE" ]; then
    echo "Already running. Exiting."
    exit 1
fi
touch "$LOCKFILE"

echo "Working in $WORKDIR"
echo "test" > "$WORKDIR/data.txt"
sleep 2
echo "Work finished"
```

```
devops@testvm:~/revision$ ./trap_demo.sh
Working in /tmp/tmp.9dK2mL8pQx
Work finished
cleanup running...
cleanup done

devops@testvm:~/revision$ ls /tmp/revision.lock
ls: cannot access '/tmp/revision.lock': No such file or directory
```

**Then I tested the case that matters** — killing it partway through:

```
devops@testvm:~/revision$ ./trap_demo.sh
Working in /tmp/tmp.4bN7xR2wKm
^C
cleanup running...
cleanup done

devops@testvm:~/revision$ ls /tmp/revision.lock
ls: cannot access '/tmp/revision.lock': No such file or directory
```

The cleanup ran on Ctrl+C too. That is the whole value: without `trap`, an interrupted script leaves the lock file behind and every future run refuses to start. `trap ... EXIT` fires on normal exit, on error, and on interruption.

This is the gap I am most glad I closed. A stale lock file from a cron job that was killed is a classic 3 a.m. problem, and I now understand the one-line fix.

---

## Task 3: Quick-fire questions

Answered from memory first, then checked. Marking where I was wrong.

**1. What does `chmod 755 script.sh` do?**
Owner gets read, write and execute (7 = 4+2+1). Group and others get read and execute (5 = 4+1). The standard setting for a script that everyone may run but only the owner may edit. ✓

**2. Difference between a process and a service?**
A process is any running program. A service is a process managed by the init system — started at boot, restarted on failure, controlled through `systemctl`. Every service is a process; most processes are not services. ✓

**3. How do you find which process is using port 8080?**
`sudo ss -tulpn | grep :8080`, or `sudo lsof -i :8080`. `sudo` matters — without it the process name column is blank for processes you do not own. ✓

**4. What does `set -euo pipefail` do?**
`-e` exit on any command failure, `-u` error on an undefined variable, `-o pipefail` make a pipeline fail if any stage fails rather than only the last. ✓

**5. Difference between `git reset --hard` and `git revert`?**
`reset --hard` moves the branch pointer back and discards the commits and the file changes — rewrites history, unsafe once pushed. `revert` adds a new commit containing the inverse changes — history is preserved, safe on shared branches. ✓

**6. Branching strategy for a team of 5 shipping weekly?**
GitHub Flow. Five people is small enough not to need GitFlow's ceremony, and weekly shipping with one production version is exactly what it is designed for. If the weekly release needed a stabilisation window, a single release branch on top would cover it. ✓

**7. What does `git stash` do and when would you use it?**
Shelves uncommitted changes and gives you a clean working tree. Used when you need to switch branches mid-task — an urgent bug on another branch, or a pull that is blocked by local changes. ✓
*Missed:* I forgot that stash ignores untracked files unless you pass `-u`.

**8. Schedule a script to run every day at 3 AM?**
`crontab -e`, then `0 3 * * * /path/to/script.sh >> /var/log/script.log 2>&1`. Absolute path is required, and the redirect matters because cron discards output. ✓

**9. Difference between `git fetch` and `git pull`?**
`fetch` downloads remote commits and updates the `origin/*` pointers without touching your branch or files. `pull` is `fetch` plus `merge` — it changes your working directory and can conflict. ✓

**10. What is LVM and why use it over regular partitions?**
A layer between physical disks and filesystems. Disks become physical volumes, pooled into a volume group, carved into logical volumes. The advantages: a volume can be resized while mounted, it can span multiple physical disks, and adding capacity means adding a disk to the pool rather than repartitioning. ✓

**Score: 10 correct, one incomplete answer (the untracked-files detail on stash).**

---

## Task 4: Organising the work

```
devops@testvm:~/90DaysOfDevOps$ git status
On branch master
nothing to commit, working tree clean

devops@testvm:~/90DaysOfDevOps$ git log --oneline | wc -l
28

devops@testvm:~/90DaysOfDevOps$ ls 2026/ | head -5
README.md
day-01
day-02
day-03
day-04
```

All days committed and pushed. `git-commands.md` covers Days 22–26. The shell scripting cheat sheet from Day 21 is complete. Profile and repos cleaned up on Day 27.

---

## Task 5: Teach it back

**Explaining file permissions to someone new to Linux:**

Every file in Linux has an owner and belongs to a group. Permissions answer one question: what may each kind of person do with this file?

There are three kinds of person. The **owner**, usually whoever created it. The **group**, a named set of users — think "the developers". And **others**, meaning everyone else on the system.

And there are three things they might be allowed to do: **read** it, **write** to it, or **execute** it as a program.

Three kinds of person, three permissions each, so nine settings. That is exactly what `ls -l` shows:

```
-rwxr-xr--  1  manish  developers  1024  Jul 6  backup.sh
 ↑↑↑ ↑↑↑ ↑↑↑
 owner group others
```

Read it in groups of three. The owner has `rwx` — read, write, execute. The group has `r-x` — read and execute, but the dash means no writing. Others have `r--` — they can only read it.

You will also see permissions as numbers, like `chmod 755`. It is the same thing: read is worth 4, write 2, execute 1, and you add them up for each group. So 7 is 4+2+1, all three. 5 is 4+1, read and execute. `755` is just `rwxr-xr--` written shorter.

One thing that catches people out: on a **directory**, execute does not mean "run it". It means "enter it". A directory you can read but not enter lets you see the names of the files inside but not open any of them.

The reason any of this matters is that it is how a shared machine stays safe. Your files are yours, your team's shared folder is writable by your team, and a random user cannot read the file with the passwords in it.

---

## Where I actually stand after four weeks

**What has genuinely stuck** is anything I broke and had to fix. The `sudo cat > file` failure on Day 08, the subshell eating my counter on Day 19, the cherry-pick that conflicted because it depended on an earlier commit — I will not forget those, because I had to work out why.

**What has not stuck** is anything I only read. `trap` was in my cheat sheet for a week before today and I could not have written it from memory. Same with LVM after one session.

**The lesson for the next 62 days:** doing a thing once is enough to write it down, not enough to know it. The topics I redid today took twenty minutes each and moved from "have seen it" to "can do it". Worth building that into the routine rather than saving it for revision days.

**Three things to carry forward:**

1. **Check before changing.** `ls -l`, `git status`, `systemctl status`, `pwd`. Nearly every mistake in four weeks came from acting before looking.
2. **Test the failure case.** Day 09 was only proven correct when the wrong user was *denied*. A success on its own proves nothing.
3. **Exit codes over parsed text.** `systemctl is-active --quiet` instead of grepping for "active (running)". Works the same regardless of wording or locale.

**Going into Docker on Day 29,** the Linux foundation is what should make it easier — containers are processes with namespaces, images are layered filesystems, and `docker exec` drops into a shell where all the Days 2–15 commands still apply.
