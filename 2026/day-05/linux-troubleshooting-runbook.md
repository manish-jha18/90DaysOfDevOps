# Day 05 – Linux Troubleshooting Runbook

The target service for this drill is `ssh` (sshd). I picked it because if it breaks I lose access to the box, so it is worth knowing well.

---

## 0. Environment basics

```
devops@testvm:~$ uname -a
Linux testvm 5.15.0-119-generic #129-Ubuntu SMP Fri Aug 2 19:25:20 UTC 2024 x86_64 x86_64 x86_64 GNU/Linux

devops@testvm:~$ cat /etc/os-release
PRETTY_NAME="Ubuntu 22.04.4 LTS"
NAME="Ubuntu"
VERSION_ID="22.04"
VERSION="22.04.4 LTS (Jammy Jellyfish)"
ID=ubuntu
ID_LIKE=debian
```

**What I see:** Ubuntu 22.04, kernel 5.15, 64-bit. So `apt` and `systemctl` will work, and auth logs live at `/var/log/auth.log`. On RHEL it would be `/var/log/secure`.

---

## 1. Filesystem sanity

Checking that I can write to disk. If this fails, the disk is full or mounted read-only, and that is the whole problem.

```
devops@testvm:~$ mkdir /tmp/runbook-demo

devops@testvm:~$ cp /etc/hosts /tmp/runbook-demo/hosts-copy && ls -l /tmp/runbook-demo
total 4
-rw-r--r-- 1 devops devops 221 Jun 11 10:14 hosts-copy
```

**What I see:** Directory created, file copied, 221 bytes. Disk is writable.

---

## 2. Snapshot: CPU and memory

Get the PID first, then watch only that process instead of all of `top`.

```
devops@testvm:~$ pgrep -x sshd
812

devops@testvm:~$ ps -o pid,pcpu,pmem,rss,etime,comm -p 812
    PID %CPU %MEM   RSS     ELAPSED COMMAND
    812  0.0  0.2  8104    04:12:37 sshd
```

**What I see:** 0% CPU, 0.2% memory, about 8 MB resident, up for 4 hours 12 minutes. A healthy idle sshd. High CPU here would point at a brute-force login flood.

```
devops@testvm:~$ free -h
               total        used        free      shared  buff/cache   available
Mem:           3.8Gi       712Mi       1.9Gi       1.0Mi       1.2Gi       2.9Gi
Swap:          2.0Gi          0B       2.0Gi
```

**What I see:** 2.9 Gi available and swap untouched. The column that matters is **available**, not free. Buff/cache gets handed back when applications need it, so a low "free" number is not a problem on its own.

---

## 3. Snapshot: disk and IO

```
devops@testvm:~$ df -h
Filesystem      Size  Used Avail Use% Mounted on
/dev/root        19G  7.4G   11G  42% /
tmpfs           1.9G     0  1.9G   0% /dev/shm
/dev/sda15      105M  6.1M   99M   6% /boot/efi

devops@testvm:~$ du -sh /var/log
248M	/var/log
```

**What I see:** Root at 42%, fine. `/var/log` at 248 MB is not a problem yet, but this is the directory that quietly fills a disk, so it is worth tracking.

```
devops@testvm:~$ vmstat 1 3
procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
 0  0      0 1988416  98304 1210880    0    0     3     8   62  118  1  0 99  0  0
 0  0      0 1988160  98304 1210880    0    0     0     0   58  104  0  1 99  0  0
 0  0      0 1988160  98304 1210880    0    0     0    12   61  110  1  0 99  0  0
```

**What I see:** `id` (idle) is 99 and `wa` (io wait) is 0. Nothing is queued. A high `wa` would mean the disk is the bottleneck, not the CPU.

---

## 4. Snapshot: network

```
devops@testvm:~$ ss -tulpn | grep sshd
tcp   LISTEN 0      128          0.0.0.0:22        0.0.0.0:*
tcp   LISTEN 0      128             [::]:22           [::]:*
```

**What I see:** sshd is listening on port 22 on IPv4 and IPv6. If these lines were missing, the service is down or bound to a different port.

```
devops@testvm:~$ ping -c 3 8.8.8.8
PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.
64 bytes from 8.8.8.8: icmp_seq=1 ttl=115 time=12.4 ms
64 bytes from 8.8.8.8: icmp_seq=2 ttl=115 time=11.9 ms
64 bytes from 8.8.8.8: icmp_seq=3 ttl=115 time=12.8 ms

--- 8.8.8.8 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2003ms
```

**What I see:** 0% loss, about 12 ms. Outbound network is fine, so any problem is local to the box.

---

## 5. Logs reviewed

Read the logs before restarting anything. A restart destroys the evidence.

```
devops@testvm:~$ systemctl status ssh --no-pager
● ssh.service - OpenBSD Secure Shell server
     Loaded: loaded (/lib/systemd/system/ssh.service; enabled; vendor preset: enabled)
     Active: active (running) since Thu 2026-06-11 06:02:11 UTC; 4h 12min ago
   Main PID: 812 (sshd)
      Tasks: 1 (limit: 4558)
     Memory: 7.9M
        CPU: 384ms
     CGroup: /system.slice/ssh.service
             └─812 "sshd: /usr/sbin/sshd -D [listener] 0 of 10-100 startups"
```

```
devops@testvm:~$ journalctl -u ssh -n 50 --no-pager | tail -n 8
Jun 11 09:41:02 testvm sshd[3120]: Accepted publickey for devops from 10.0.2.2 port 51442 ssh2: RSA SHA256:9xK2...
Jun 11 09:41:02 testvm sshd[3120]: pam_unix(sshd:session): session opened for user devops(uid=1000) by (uid=0)
Jun 11 09:52:18 testvm sshd[3120]: pam_unix(sshd:session): session closed for user devops
Jun 11 10:03:44 testvm sshd[3388]: Invalid user admin from 203.0.113.45 port 40122
Jun 11 10:03:44 testvm sshd[3388]: Failed password for invalid user admin from 203.0.113.45 port 40122 ssh2
Jun 11 10:03:46 testvm sshd[3388]: Connection closed by invalid user admin 203.0.113.45 port 40122 [preauth]
Jun 11 10:07:11 testvm sshd[3402]: Accepted publickey for devops from 10.0.2.2 port 51680 ssh2: RSA SHA256:9xK2...
Jun 11 10:07:11 testvm sshd[3402]: pam_unix(sshd:session): session opened for user devops(uid=1000) by (uid=0)
```

**What I see:** Service is active and enabled, no crashes. My own logins came in on a public key. There is also a failed login for user `admin` from `203.0.113.45`, which is not me. That is a bot scanning port 22.

```
devops@testvm:~$ sudo tail -n 50 /var/log/auth.log | grep -c "Failed password"
7
```

**What I see:** 7 failed password attempts in the recent log. Low volume, so background noise rather than a real attack.

---

## Quick findings

- sshd is healthy: up 4h+, 0% CPU, 8 MB RAM, listening on port 22.
- No resource pressure. CPU idle 99%, 2.9 Gi RAM available, disk at 42%, zero io wait.
- The only real signal is 7 failed logins from an unknown IP. Not an outage, but a good reason to disable password login.
- `/var/log` at 248 MB is the number to keep watching.

---

## If this worsens

1. **Confirm before restarting.** Run `systemctl status ssh` and `journalctl -u ssh -n 100` first. If I am editing config, run `sudo sshd -t` to check the syntax **before** `systemctl restart ssh`. A bad config plus a restart locks me out of the VM. Keep the current session open while testing.
2. **Increase log verbosity.** Set `LogLevel DEBUG` in `/etc/ssh/sshd_config`, reload, and reproduce the failure. Set it back to `INFO` afterwards or the log grows fast.
3. **Trace it or block it.** Use `sudo strace -p 812 -f -e trace=network` to see what sshd is doing at syscall level. If it is brute-force traffic, install `fail2ban` or limit port 22 to my own IP in the security group or `ufw`.

Two more checks if it looked resource-related: `dmesg -T | tail -30` for OOM killer messages, and `ss -s` for a socket count summary.

---

## What I learned today

- Take the snapshot before touching anything.
- `available` memory is the real number, not `free`.
- `wa` in `vmstat` tells me straight away whether I am chasing CPU or disk.
- The logs gave me more in 30 seconds than every resource command combined.
