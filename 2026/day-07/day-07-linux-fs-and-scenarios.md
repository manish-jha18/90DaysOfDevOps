# Day 07 – Linux File System Hierarchy and Scenario Practice

## Part 1: File System Hierarchy

### Core directories

#### `/` (root)

The top of the tree. Every other path starts from here. There are no drive letters in Linux, everything hangs off `/`.

```
devops@testvm:~$ ls -l /
total 60
lrwxrwxrwx   1 root root    7 Apr 22 09:11 bin -> usr/bin
drwxr-xr-x   4 root root 4096 Jun 14 06:01 boot
drwxr-xr-x  17 root root 3860 Jun 14 06:01 dev
drwxr-xr-x  95 root root 4096 Jun 14 08:22 etc
drwxr-xr-x   3 root root 4096 Jun 10 07:45 home
drwxr-xr-x  14 root root 4096 Jun 14 06:01 var
```

`bin` is a symlink to `usr/bin`, which surprised me. Modern Ubuntu merged them.

**I would use this when:** I need to check what is mounted where, or find free space with `df -h /`.

---

#### `/home` – user home directories

One folder per normal user. My files, my configs, my SSH keys.

```
devops@testvm:~$ ls -l /home
total 4
drwxr-x--- 5 devops devops 4096 Jun 14 08:15 devops
```

**I would use this when:** Looking for a user's SSH keys in `~/.ssh`, or checking who has an account on the box.

---

#### `/root` – the root user's home

Root does not live in `/home`. It gets its own directory at the top level, so it is still reachable if `/home` is on a separate disk that fails to mount.

```
devops@testvm:~$ sudo ls -l /root
total 8
-rw-r--r-- 1 root root  161 Jun 10 07:45 .bashrc
drwx------ 2 root root 4096 Jun 10 07:46 .ssh
```

**I would use this when:** Checking root's cron jobs or SSH keys during a security review.

---

#### `/etc` – configuration files

Every system-wide config. Text files, no binaries. This is the directory I back up before changing anything.

```
devops@testvm:~$ ls -l /etc | head -6
total 800
drwxr-xr-x 3 root root  4096 Jun 10 07:45 apt
-rw-r--r-- 1 root root  2981 Jun 10 07:46 bash.bashrc
-rw-r--r-- 1 root root  1748 Jun 10 07:45 hosts
-rw-r--r-- 1 root root  2355 Jun 14 06:12 passwd
drwxr-xr-x 4 root root  4096 Jun 10 07:46 ssh
```

**I would use this when:** Changing the SSH port in `/etc/ssh/sshd_config`, or adding a hostname override in `/etc/hosts`.

---

#### `/var/log` – log files

Where services write their logs. The first place to look when something breaks, and the directory most likely to fill a disk.

```
devops@testvm:~$ ls -l /var/log | head -6
total 1284
-rw-r----- 1 syslog adm     84213 Jun 14 09:20 auth.log
drwxr-xr-x 2 root   root     4096 Jun 14 06:01 journal
-rw-r----- 1 syslog adm    412880 Jun 14 09:22 syslog
-rw-rw-r-- 1 root   utmp    26496 Jun 14 08:15 wtmp
```

**I would use this when:** A service failed and I need to know why, or `df -h` shows the disk filling up.

---

#### `/tmp` – temporary files

Scratch space anyone can write to. Cleared on reboot. The sticky bit means I can only delete my own files here, even though the directory is world-writable.

```
devops@testvm:~$ ls -ld /tmp
drwxrwxrwt 12 root root 4096 Jun 14 09:18 /tmp
```

That trailing `t` in `drwxrwxrwt` is the sticky bit.

**I would use this when:** Dumping a quick log extract or test file that I do not want to keep.

---

### Additional directories

#### `/bin` – essential command binaries

The basic commands needed even in single-user mode: `ls`, `cp`, `cat`, `bash`. Now a symlink to `/usr/bin`.

```
devops@testvm:~$ ls -l /bin/ls /bin/cat
-rwxr-xr-x 1 root root 142312 Mar 23  2024 /bin/cat
-rwxr-xr-x 1 root root 138208 Mar 23  2024 /bin/ls
```

**I would use this when:** Checking whether a command exists, usually via `which`.

---

#### `/usr/bin` – user command binaries

Everything else installed by the package manager. Much bigger than `/bin`.

```
devops@testvm:~$ ls /usr/bin | wc -l
1247

devops@testvm:~$ which python3 curl
/usr/bin/python3
/usr/bin/curl
```

**I would use this when:** Writing a script and needing the full path to a binary, since cron does not have my normal PATH.

---

#### `/opt` – optional and third-party software

Software that did not come from the package manager. Each app usually gets its own subdirectory.

```
devops@testvm:~$ ls -l /opt
total 0
```

Empty on my VM right now. It will fill up later in the challenge.

**I would use this when:** Installing a vendor tool that ships as a tarball instead of a `.deb`.

---

### Hands-on task

**Largest log files:**

```
devops@testvm:~$ du -sh /var/log/* 2>/dev/null | sort -h | tail -5
4.0K	/var/log/dmesg
26K	/var/log/wtmp
84K	/var/log/auth.log
403K	/var/log/syslog
216M	/var/log/journal
```

The journal is by far the biggest at 216 MB. That is systemd's binary log store, and it is capped by `SystemMaxUse` in `/etc/systemd/journald.conf`. `journalctl --disk-usage` shows the same thing, and `journalctl --vacuum-size=100M` would trim it.

**A config file in /etc:**

```
devops@testvm:~$ cat /etc/hostname
testvm
```

One line. This is what shows up in my shell prompt and in log entries.

**My home directory:**

```
devops@testvm:~$ ls -la ~
total 32
drwxr-x--- 5 devops devops 4096 Jun 14 08:15 .
drwxr-xr-x 3 root   root   4096 Jun 10 07:45 ..
-rw------- 1 devops devops  842 Jun 14 09:02 .bash_history
-rw-r--r-- 1 devops devops 3771 Jun 10 07:45 .bashrc
drwx------ 2 devops devops 4096 Jun 10 07:52 .ssh
drwxrwxr-x 2 devops devops 4096 Jun 13 11:02 day-06
```

The dotfiles only appear with `-a`. `.ssh` is `700` and nothing else can read it, which is exactly right — SSH refuses to use keys with loose permissions.

---

## Part 2: Scenario Practice

### Scenario 1: Service not starting

`myapp` failed to start after a reboot.

**Step 1:** `systemctl status myapp`
**Why:** Tells me in one screen whether it is failed, inactive or missing, plus the exit code and the last few log lines.

**Step 2:** `journalctl -u myapp -n 50 --no-pager`
**Why:** The status output truncates. This gives the actual error the app printed before dying.

**Step 3:** `systemctl is-enabled myapp`
**Why:** If this says `disabled`, the service did not fail at all — it was simply never told to start at boot. Different problem, different fix.

**Step 4:** `systemctl cat myapp`
**Why:** Shows the unit file. I can check `ExecStart` points at a binary that exists, and look at `After=` in case it started before a dependency such as the database was ready.

**Step 5 (if the config was edited):** `sudo systemctl daemon-reload` then `sudo systemctl start myapp`
**Why:** systemd caches unit files. Editing one without a reload means the old version keeps running.

**What I expect to see on a failure:**

```
devops@testvm:~$ systemctl status myapp --no-pager
× myapp.service - My Application
     Loaded: loaded (/etc/systemd/system/myapp.service; enabled; vendor preset: enabled)
     Active: failed (Result: exit-code) since Sun 2026-06-14 09:31:07 UTC; 2min ago
    Process: 2214 ExecStart=/opt/myapp/bin/start.sh (code=exited, status=203/EXEC)
   Main PID: 2214 (code=exited, status=203/EXEC)
```

`203/EXEC` means systemd could not execute the file at all. Usually a missing execute bit or a wrong path, which links straight into Scenario 4.

---

### Scenario 2: High CPU usage

The server is slow and I need the process responsible.

**Step 1:** `top`
**Why:** Live view, sorted by CPU by default. Press `q` to quit, `M` to sort by memory instead.

**Step 2:** `ps aux --sort=-%cpu | head -10`
**Why:** A snapshot I can paste into a ticket. `top` is interactive and awkward to copy from.

```
devops@testvm:~$ ps aux --sort=-%cpu | head -6
USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
devops      2891 97.3  1.2 892340 48120 ?        Rl   09:14  12:41 /usr/bin/python3 /opt/report/crunch.py
root         658  0.4  0.1  12172  4408 ?        Ss   06:01   0:02 /usr/sbin/cron -f
root         812  0.1  0.2  15436  8104 ?        Ss   06:01   0:00 sshd: /usr/sbin/sshd -D
root           1  0.0  0.4 167644 12208 ?        Ss   06:01   0:02 /sbin/init
```

**Step 3:** Note the PID — `2891`, a Python script at 97.3% CPU, running for 12 minutes.

**Step 4:** `ps -o pid,ppid,user,etime,cmd -p 2891`
**Why:** Who started it and how long it has been going. If the parent is cron, it is a scheduled job that is stuck rather than user traffic.

**Step 5:** `uptime`
**Why:** Load average across 1, 5 and 15 minutes. It tells me whether this just started or has been going for an hour.

I would not kill it straight away. One process at 97% on a multi-core box may be perfectly normal for a batch job.

---

### Scenario 3: Finding service logs

A developer wants the logs for the `docker` service.

**Step 1:** `systemctl status docker`
**Why:** Confirms the exact unit name and shows the last few lines immediately.

**Step 2:** `journalctl -u docker -n 50 --no-pager`
**Why:** systemd services log to journald, not to a file in `/var/log`. This is the standard way to read them.

**Step 3:** `journalctl -u docker -f`
**Why:** Follows the log live, like `tail -f`. Useful while reproducing a problem.

I practised the pattern on `ssh`, since Docker is not installed yet:

```
devops@testvm:~$ journalctl -u ssh -n 5 --no-pager
Jun 14 06:02:11 testvm systemd[1]: Starting OpenBSD Secure Shell server...
Jun 14 06:02:11 testvm sshd[812]: Server listening on 0.0.0.0 port 22.
Jun 14 06:02:11 testvm sshd[812]: Server listening on :: port 22.
Jun 14 06:02:11 testvm systemd[1]: Started OpenBSD Secure Shell server.
Jun 14 08:15:33 testvm sshd[1402]: Accepted publickey for devops from 10.0.2.2 port 52118 ssh2: RSA SHA256:9xK2...
```

**Useful extras:**
- `journalctl -u docker --since "1 hour ago"` — time window
- `journalctl -u docker -p err` — errors only
- `journalctl -u docker --since today > /tmp/docker.log` — hand a file to the developer

Docker containers are different again — those are `docker logs <container>`, which is not the same as the daemon's own log.

---

### Scenario 4: File permissions issue

`./backup.sh` returns "Permission denied".

**Step 1:** Check the current permissions

```
devops@testvm:~$ ls -l /home/devops/backup.sh
-rw-r--r-- 1 devops devops 214 Jun 14 09:44 /home/devops/backup.sh
```

No `x` anywhere in `-rw-r--r--`, so nobody can execute it. That is the problem.

**Step 2:** Add execute permission

```
devops@testvm:~$ chmod +x /home/devops/backup.sh
```

**Step 3:** Verify

```
devops@testvm:~$ ls -l /home/devops/backup.sh
-rwxr-xr-x 1 devops devops 214 Jun 14 09:44 /home/devops/backup.sh
```

`x` is now present for owner, group and others.

**Step 4:** Run it

```
devops@testvm:~$ ./backup.sh
Backup started at Sun Jun 14 09:46:02 UTC 2026
Backup complete.
```

**If it still failed, the next things I would check:**
- The shebang. A missing or wrong `#!/bin/bash` on the first line gives a confusing error.
- Windows line endings. A file edited on Windows gets `\r` at the end of each line and fails with `bad interpreter: /bin/bash^M`. Fix with `dos2unix backup.sh`.
- The mount. A filesystem mounted `noexec` blocks execution no matter what the permission bits say. Check with `mount | grep /home`.

---

## What I learned today

- `/etc` for config, `/var/log` for logs, `/opt` for third-party software. Knowing this means I stop guessing where to look.
- The systemd journal was 216 MB of my 248 MB `/var/log`, so log growth is a real disk risk, not a theoretical one.
- The sticky bit on `/tmp` is why a world-writable directory is still safe.
- Every scenario followed the same shape: check status, read logs, then check config. Same three steps regardless of the service.
- Exit code `203/EXEC` means systemd could not run the file, which is a permissions or path problem rather than an application bug.
