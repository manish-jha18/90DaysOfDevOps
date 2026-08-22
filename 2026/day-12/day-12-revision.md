# Day 12 – Breather and Revision (Days 01–11)

No new tools today. Went back over the first eleven days, re-ran a few things, and wrote down what stuck and what did not.

---

## Mindset and plan

Re-read my Day 01 plan. The three goals still hold — a production-grade app on Kubernetes, infrastructure provisioned with Terraform, and an end-to-end CI/CD pipeline. No change needed there.

Two honest adjustments:

- **Weekdays are tighter than the plan assumes.** I budgeted 1 to 2 hours after work. Some days it has been closer to 45 minutes, and the weekend block has quietly absorbed the difference. The budget is realistic; my assumption that every weekday would hit the top of the range was not.
- **I underestimated Linux.** I expected Days 01–11 to be a warm-up before the real tools. Permissions and ownership took genuine effort, especially the difference between what a permission bit means on a file versus a directory. Glad the challenge spent this long here.

Something I said on Day 01 that is proving right: hands-on labs over watching videos. The days where I only read about a command have already faded. The ones where I ran it, broke it, and read the error have stuck.

One thing I want to add to the plan: be able to explain what I did without looking at my notes. Writing a file I could not talk through in a conversation is not learning.

---

## Processes and services (re-ran from Day 04/05)

```
devops@testvm:~$ systemctl status ssh --no-pager
● ssh.service - OpenBSD Secure Shell server
     Loaded: loaded (/lib/systemd/system/ssh.service; enabled; vendor preset: enabled)
     Active: active (running) since Mon 2026-06-22 06:03:52 UTC; 3h 41min ago
   Main PID: 809 (sshd)
      Tasks: 1 (limit: 4558)
     Memory: 8.1M
        CPU: 402ms
```

```
devops@testvm:~$ ps aux --sort=-%mem | head -4
USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root           1  0.0  0.4 167644 12240 ?        Ss   06:03   0:02 /sbin/init
root         412  0.0  0.3  84520  9884 ?        Ss   06:03   0:00 /lib/systemd/systemd-journald
root         809  0.0  0.2  15436  8296 ?        Ss   06:03   0:00 sshd: /usr/sbin/sshd -D
```

**Observation:** Ran both from memory this time, no cheat sheet. The `--sort=-%mem` flag is the one I keep having to think about — the minus sign means descending, and without it the biggest consumer ends up at the bottom.

Uptime is only 3h41m because I rebooted the VM this morning. Two weeks ago I would have found that alarming; now I check `Active:` against the boot time before assuming a service crashed.

---

## File skills (re-ran from Days 06–11)

**1. Append and read:**

```
devops@testvm:~/day-12$ echo "revision day - 22 June" >> revision-log.txt
devops@testvm:~/day-12$ tail -n 1 revision-log.txt
revision day - 22 June
```

**2. Permission change:**

```
devops@testvm:~/day-12$ touch check.sh
devops@testvm:~/day-12$ chmod 750 check.sh
devops@testvm:~/day-12$ ls -l check.sh
-rwxr-x--- 1 devops devops 0 Jun 22 09:48 check.sh
```

Did 750 in my head this time: owner 4+2+1, group 4+1, others 0. That was slow on Day 10.

**3. Ownership change:**

```
devops@testvm:~/day-12$ sudo chown tokyo:developers check.sh
devops@testvm:~/day-12$ ls -l check.sh
-rwxr-x--- 1 tokyo developers 0 Jun 22 09:48 check.sh
```

```
devops@testvm:~/day-12$ id tokyo
uid=1001(tokyo) gid=1001(tokyo) groups=1001(tokyo),1004(developers),1007(project-team)
```

Still correct from Day 09. Nothing drifted.

---

## Cheat sheet refresh — 5 commands I would reach for first

Skimmed the Day 03 sheet. These are the ones I would actually type in the first minute of an incident:

1. `systemctl status <service>` — is it up, is it enabled, why did it stop
2. `journalctl -u <service> -n 50` — what did it say before it died
3. `df -h` — a full disk causes failures that look like everything else
4. `ps aux --sort=-%cpu | head` — what is eating the box
5. `ss -tulpn` — is anything actually listening on the port

The rest of the sheet is useful but these five cover most of the first pass.

---

## User and group sanity check (re-ran from Day 09/11)

```
devops@testvm:~$ sudo useradd -m -s /bin/bash rio
devops@testvm:~$ sudo usermod -aG developers rio

devops@testvm:~$ id rio
uid=1005(rio) gid=1008(rio) groups=1008(rio),1004(developers)

devops@testvm:~$ sudo -u rio touch /opt/dev-project/rio-test.txt
devops@testvm:~$ ls -l /opt/dev-project/rio-test.txt
-rw-rw-r-- 1 rio rio 0 Jun 22 10:02 /opt/dev-project/rio-test.txt
```

Worked first time. `rio` is in `developers`, `/opt/dev-project` is group-writable by `developers`, so the write succeeded. Cleaned up after:

```
devops@testvm:~$ sudo rm /opt/dev-project/rio-test.txt
devops@testvm:~$ sudo userdel -r rio
```

`-r` removes the home directory too. Without it the user is gone but `/home/rio` stays behind.

---

## Mini self-check

### 1. Which 3 commands save me the most time right now, and why?

**`journalctl -u <service> -n 50`** — goes straight to one service's logs. Before this I was grepping `/var/log/syslog` and reading everything on the system at once.

**`ls -l`** — permissions, owner and group in a single line. Most of my Day 10 and 11 mistakes were found by reading this output properly instead of guessing.

**`Ctrl + R`** — history search. I retype far fewer long commands, and it stops the typos that come with retyping a path.

### 2. How do I check if a service is healthy? Exact commands.

```
systemctl status <service>      # active? enabled? when did it start?
journalctl -u <service> -n 50   # what did it log before any problem
ss -tulpn | grep <port>         # is it actually listening
```

In that order. `status` can say `active (running)` while the process is wedged and not accepting connections, so the port check is what confirms it is genuinely serving.

### 3. How do I safely change ownership and permissions without breaking access?

Check the current state first, change one thing, verify, then test as the affected user.

```
ls -l config.yaml                          # before
sudo chown appuser:appgroup config.yaml    # change
ls -l config.yaml                          # after
sudo -u appuser cat config.yaml            # does it still work
```

What makes it unsafe is `-R` on the wrong path, and using `chmod 777` to make an error go away. 777 does not fix a permissions problem, it hides it and creates a security one. The right move is working out *which* user needs access and giving them exactly that.

### 4. What will I focus on in the next 3 days?

- **`chmod` in symbolic form.** I am comfortable with 640 and 755 now, but `u+x`, `g-w`, `o=r` still make me stop and think.
- **`journalctl` flags beyond `-n` and `-u`.** Specifically `--since`, `-p err` and `-f`. Filtering by time and severity would have saved me effort on Day 07.
- **`vim`.** I can insert, save and quit. That is all. Enough to be dangerous, not enough to be quick. Worth 20 minutes on `dd`, `/search` and `:%s`.

---

## Key takeaways from Days 01–11

- **Check before you change.** `ls -l`, `systemctl status`, `pwd`. Every mistake I made this fortnight came from acting before looking.
- **Test the negative case.** On Day 09 the setup was only proven correct when `professor` was *denied* access. A success on its own proves nothing.
- **Read logs before restarting.** A restart clears the evidence and often fixes the symptom while hiding the cause.
- **Permissions and ownership are separate.** The right owner on a world-readable file is still a world-readable file.
- **The error message is rarely the cause.** "Permission denied" on Day 08 was a security group, not a permission. `203/EXEC` on Day 07 was a missing execute bit, not a broken app.

---

## Where I feel shaky

Being honest so I know what to come back to:

- Symbolic `chmod` — still slower than the numeric form.
- `vim` beyond insert and save.
- Networking. Day 08 worked, but I was following steps rather than understanding the packet path. Days 14 and 15 cover this and I need them.
- I have not broken anything badly yet. Everything so far has been building, not repairing. Real confidence probably comes from fixing something I broke myself.
