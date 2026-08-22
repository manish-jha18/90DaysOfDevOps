# Day 03 – Linux Commands Cheat Sheet

My personal reference. Only commands I have actually run and understand — no copied lists.

---

## Process management

| Command | What it does |
|---|---|
| `ps aux` | Every process on the box, with CPU, memory and state |
| `ps aux \| grep nginx` | Find one process by name |
| `pgrep -x sshd` | Get just the PID, cleaner than grep |
| `top` | Live CPU and memory view. `M` sorts by memory, `P` by CPU, `q` quits |
| `htop` | Same idea, easier to read. Needs installing |
| `kill <pid>` | Ask a process to stop cleanly (SIGTERM) |
| `kill -9 <pid>` | Force it to stop (SIGKILL). Last resort, no cleanup happens |
| `pkill -f "python app.py"` | Kill by matching the full command line |
| `nice -n 10 <cmd>` | Start a command at lower priority |

**Note:** always try `kill` before `kill -9`. A plain kill lets the process flush its files and shut down properly.

---

## Services and systemd

| Command | What it does |
|---|---|
| `systemctl status <svc>` | Running or not, enabled or not, last few log lines |
| `systemctl start/stop/restart <svc>` | Control the service now |
| `systemctl enable <svc>` | Start it automatically at boot |
| `systemctl list-units --type=service` | Every service and its current state |
| `journalctl -u <svc> -n 50` | Last 50 log lines for that service |
| `journalctl -u <svc> -f` | Follow the log live |

---

## File system

| Command | What it does |
|---|---|
| `ls -lh` | List files with readable sizes |
| `ls -la` | Include hidden dotfiles |
| `cd -` | Jump back to the previous directory |
| `pwd` | Where am I |
| `mkdir -p a/b/c` | Create nested directories in one go |
| `cp -r src/ dest/` | Copy a directory and everything in it |
| `mv old new` | Move or rename |
| `rm -rf <dir>` | Delete a directory and contents. No undo — check `pwd` first |
| `find /var -name "*.log"` | Find files by name |
| `find / -size +100M` | Find files bigger than 100 MB |
| `du -sh /var/log` | Total size of one directory |
| `df -h` | Free space per filesystem |

---

## Reading files and logs

| Command | What it does |
|---|---|
| `cat file` | Print the whole file |
| `less file` | Page through a big file. `/word` searches, `q` quits |
| `head -n 20 file` | First 20 lines |
| `tail -n 50 file` | Last 50 lines |
| `tail -f app.log` | Follow a log as it is written |
| `grep -i "error" app.log` | Find matching lines, case insensitive |
| `grep -c "error" app.log` | Count matches instead of printing them |
| `grep -rn "TODO" .` | Search recursively, show line numbers |
| `wc -l file` | Count lines |
| `sort file \| uniq -c` | Count how many times each line appears |

**The one I use most:**

```
grep "ERROR" app.log | tail -n 20
```

Errors only, most recent last.

---

## Networking

| Command | What it does |
|---|---|
| `ip addr` | My IP addresses and interfaces (replaces `ifconfig`) |
| `ping -c 4 8.8.8.8` | Is the network reachable at all |
| `curl -I https://example.com` | Fetch just the response headers |
| `curl -v https://example.com` | Verbose — shows the DNS, TCP and TLS steps |
| `dig example.com` | DNS lookup, what does this name resolve to |
| `ss -tulpn` | What is listening on which port, and which process owns it |
| `traceroute 8.8.8.8` | Every hop between me and the target |

**How I work through a "site is down" report:**

1. `ping 8.8.8.8` — is the network up at all
2. `dig example.com` — does the name resolve
3. `ss -tulpn \| grep 443` — is anything actually listening
4. `curl -I https://example.com` — what status code comes back

That order goes from the widest possible cause down to the narrowest.

---

## Disk and resources

| Command | What it does |
|---|---|
| `free -h` | Memory. The **available** column is the one that matters |
| `uptime` | How long the box has been up, plus load average |
| `vmstat 1 5` | Five one-second samples. `wa` is io wait, `id` is idle |
| `iostat -x 1 3` | Per-disk IO detail |
| `lsof -i :8080` | Which process is holding port 8080 |

---

## Users and permissions

| Command | What it does |
|---|---|
| `whoami` | Which user am I |
| `id` | My user ID, group ID and all groups |
| `sudo -i` | Become root |
| `chmod +x script.sh` | Make a file executable |
| `chown user:group file` | Change owner and group |

---

## Small things that save time

| Trick | What it does |
|---|---|
| `Ctrl + R` | Search backwards through command history |
| `Ctrl + C` | Cancel the running command |
| `Ctrl + Z` then `bg` | Pause a job and send it to the background |
| `!!` | Repeat the last command — `sudo !!` is the classic |
| `history \| grep docker` | Find a command I ran before |
| `man <command>` | Read the manual, `/` searches inside it |
| `<command> --help` | Faster than `man` when I just need the flags |

---

## Quick reference: which command for which problem

| Problem | Start with |
|---|---|
| Box is slow | `top`, then `vmstat 1 5` |
| Disk is full | `df -h`, then `du -sh /var/*` |
| Service will not start | `systemctl status`, then `journalctl -u` |
| Port already in use | `ss -tulpn` or `lsof -i :<port>` |
| Cannot reach a site | `ping`, `dig`, `curl -I` |
| Process will not die | `kill`, then `kill -9` |
