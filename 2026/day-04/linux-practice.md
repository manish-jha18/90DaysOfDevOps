# Day 04 – Linux Practice: Processes and Services

I picked `cron` as the service to inspect, because it runs on every Linux box by default and it is simple enough to follow end to end.

---

## Process checks

### 1. `ps aux` – everything running

```
devops@testvm:~$ ps aux | head -n 8
USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root           1  0.0  0.4 167644 12208 ?        Ss   06:01   0:02 /sbin/init
root           2  0.0  0.0      0     0 ?        S    06:01   0:00 [kthreadd]
root         412  0.0  0.3  84520  9832 ?        Ss   06:01   0:00 /lib/systemd/systemd-journald
root         658  0.0  0.1  12172  4408 ?        Ss   06:01   0:00 /usr/sbin/cron -f
root         812  0.0  0.2  15436  8104 ?        Ss   06:01   0:00 sshd: /usr/sbin/sshd -D
devops      1420  0.0  0.1   9016  4880 pts/0    Ss   09:12   0:00 -bash
devops      1533  0.0  0.1  10336  3312 pts/0    R+   09:34   0:00 ps aux
```

**What I noticed:**
- PID 1 is `/sbin/init`, which is a symlink to systemd.
- `[kthreadd]` is in square brackets — that means it is a kernel thread, not a normal program.
- `STAT` is `Ss` for most things. `S` is sleeping, the second `s` means it is a session leader.
- My own `ps aux` shows as `R+` because it was the one running when the snapshot was taken.

### 2. `pgrep` – find one PID

```
devops@testvm:~$ pgrep -x cron
658

devops@testvm:~$ ps -o pid,ppid,pcpu,pmem,etime,comm -p 658
    PID    PPID %CPU %MEM     ELAPSED COMMAND
    658       1  0.0  0.1    03:33:12 cron
```

**What I noticed:** `PPID` is 1, so systemd is its parent. Running for 3.5 hours, using almost nothing. `pgrep` is much cleaner than `ps aux | grep cron`, which also matches the grep itself.

---

## Service checks

### 3. `systemctl status cron`

```
devops@testvm:~$ systemctl status cron --no-pager
● cron.service - Regular background program processing daemon
     Loaded: loaded (/lib/systemd/system/cron.service; enabled; vendor preset: enabled)
     Active: active (running) since Wed 2026-06-10 06:01:48 UTC; 3h 33min ago
       Docs: man:cron(8)
   Main PID: 658 (cron)
      Tasks: 1 (limit: 4558)
     Memory: 4.3M
        CPU: 112ms
     CGroup: /system.slice/cron.service
             └─658 /usr/sbin/cron -f
```

**What I noticed:**
- `enabled` means it comes back after a reboot. `active (running)` means it is up right now. Two different things.
- `Main PID: 658` matches what `pgrep` gave me.
- The `-f` flag means run in the foreground — systemd wants that so it can supervise the process itself.

### 4. `systemctl list-units --type=service`

```
devops@testvm:~$ systemctl list-units --type=service --state=running --no-pager
  UNIT                     LOAD   ACTIVE SUB     DESCRIPTION
  cron.service             loaded active running Regular background program processing daemon
  dbus.service             loaded active running D-Bus System Message Bus
  rsyslog.service          loaded active running System Logging Service
  ssh.service              loaded active running OpenBSD Secure Shell server
  systemd-journald.service loaded active running Journal Service
  systemd-logind.service   loaded active running User Login Management
  unattended-upgrades.s…   loaded active running Unattended Upgrades Shutdown

7 loaded units listed.
```

**What I noticed:** Only 7 services running on a fresh VM. Adding `--state=running` cut a very long list down to something readable.

---

## Log checks

### 5. `journalctl -u cron`

```
devops@testvm:~$ journalctl -u cron -n 10 --no-pager
Jun 10 06:01:48 testvm systemd[1]: Started Regular background program processing daemon.
Jun 10 06:01:48 testvm cron[658]: (CRON) INFO (pidfile fd = 3)
Jun 10 06:01:48 testvm cron[658]: (CRON) INFO (Running @reboot jobs)
Jun 10 06:17:01 testvm CRON[1102]: (root) CMD (cd / && run-parts --report /etc/cron.hourly)
Jun 10 07:17:01 testvm CRON[1189]: (root) CMD (cd / && run-parts --report /etc/cron.hourly)
Jun 10 08:17:01 testvm CRON[1271]: (root) CMD (cd / && run-parts --report /etc/cron.hourly)
Jun 10 09:17:01 testvm CRON[1478]: (root) CMD (cd / && run-parts --report /etc/cron.hourly)
```

**What I noticed:** The hourly job fires at 17 minutes past every hour, not on the hour. That is Ubuntu spreading the load so every machine does not hit disk at exactly xx:00. No errors anywhere.

### 6. `tail` on the syslog

```
devops@testvm:~$ sudo tail -n 5 /var/log/syslog
Jun 10 09:17:01 testvm CRON[1478]: (root) CMD (cd / && run-parts --report /etc/cron.hourly)
Jun 10 09:22:14 testvm systemd[1]: Starting Cleanup of Temporary Directories...
Jun 10 09:22:14 testvm systemd[1]: systemd-tmpfiles-clean.service: Deactivated successfully.
Jun 10 09:22:14 testvm systemd[1]: Finished Cleanup of Temporary Directories.
Jun 10 09:30:02 testvm systemd[1]: Started Run anacron jobs.
```

**What I noticed:** `journalctl -u` shows one service. `/var/log/syslog` mixes everything together. The journal is easier when I already know which service I care about.

---

## Mini troubleshooting flow

I tested a job of my own to see the full loop.

**Step 1 — add a cron job:**

```
devops@testvm:~$ crontab -e

devops@testvm:~$ crontab -l
* * * * * echo "cron test at $(date)" >> /tmp/cron-test.log
```

**Step 2 — wait, then check the output:**

```
devops@testvm:~$ cat /tmp/cron-test.log
cron test at Wed Jun 10 09:36:01 UTC 2026
cron test at Wed Jun 10 09:37:01 UTC 2026
cron test at Wed Jun 10 09:38:01 UTC 2026
```

**Step 3 — confirm cron recorded it:**

```
devops@testvm:~$ journalctl -u cron -n 3 --no-pager
Jun 10 09:36:01 testvm CRON[1602]: (devops) CMD (echo "cron test at $(date)" >> /tmp/cron-test.log)
Jun 10 09:37:01 testvm CRON[1615]: (devops) CMD (echo "cron test at $(date)" >> /tmp/cron-test.log)
Jun 10 09:38:01 testvm CRON[1628]: (devops) CMD (echo "cron test at $(date)" >> /tmp/cron-test.log)
```

**Step 4 — clean up:**

```
devops@testvm:~$ crontab -r && rm /tmp/cron-test.log
```

**If the job had not run, my order would be:**
1. `systemctl status cron` — is the service even up
2. `crontab -l` — did the entry actually save
3. `journalctl -u cron | grep CMD` — did cron try to run it
4. If cron tried but nothing happened, the problem is my command, not cron. Usually the PATH, because cron runs with a very small PATH and does not load `.bashrc`. Full paths fix most of it.

---

## What I learned today

- `pgrep -x` beats `ps aux | grep`, which always matches itself.
- `enabled` and `active` mean different things and both matter.
- Square brackets in `ps` output mean kernel threads.
- `journalctl -u <service>` is the fast path once I know the service name.
- Cron failures are usually PATH problems, not cron problems.
