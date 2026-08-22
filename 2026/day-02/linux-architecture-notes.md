# Day 02 – Linux Architecture, Processes and systemd

## The three layers

Linux is split into layers, and knowing which layer a problem lives in saves a lot of time.

**1. Hardware** — CPU, RAM, disk, network card.

**2. Kernel space** — the kernel is the only part that talks to hardware directly. It handles:
- Deciding which process runs on the CPU (scheduling)
- Handing out memory
- Reading and writing to disk and network
- Enforcing permissions

**3. User space** — everything else. My shell, `nginx`, `python`, `systemd`. None of these touch hardware. They ask the kernel through **system calls**.

So when I run `cat file.txt`, `cat` does not read the disk. It makes an `open()` and `read()` syscall and the kernel does the actual work. That boundary is the whole design.

---

## How a process is created

Every process except the first one is created by another process.

- **fork()** — a process makes a copy of itself. The copy is the child.
- **exec()** — the child replaces itself with a different program.
- **wait()** — the parent waits for the child to finish and collects its exit code.

When I type `ls` in bash: bash forks itself, the child execs `ls`, bash waits, `ls` exits, bash prints the prompt again.

**PID 1** is special. It is the first process the kernel starts at boot, and on modern Linux that is `systemd`. If a parent dies before its child, the orphaned child gets adopted by PID 1.

---

## Process states

This is what the `STAT` column in `ps` shows.

| State | Letter | What it means |
|---|---|---|
| Running | `R` | On the CPU right now, or queued and ready to run |
| Sleeping (interruptible) | `S` | Waiting for something — input, a network reply, a timer. Most processes are here |
| Uninterruptible sleep | `D` | Waiting on disk or hardware, cannot be killed. Lots of `D` means the disk is the problem |
| Stopped | `T` | Paused, usually by Ctrl+Z |
| Zombie | `Z` | Finished, but the parent has not collected its exit code yet |

**About zombies:** a zombie is already dead. It holds no memory or CPU, just an entry in the process table. `kill` does nothing to it because there is nothing left to kill. The bug is in the parent for not calling `wait()`. Kill the parent and PID 1 adopts the zombie and cleans it up. A handful of zombies is harmless; thousands means the process table will fill up.

---

## What systemd does

systemd is PID 1. It starts everything at boot and keeps it running.

Older systems used SysV init, which ran shell scripts one after another in a fixed order. systemd works out the dependencies and starts things in parallel, so boots are faster.

What it gives me day to day:

- **Units** — everything is a unit. A service is `ssh.service`, a mount point is a `.mount`, a timer is a `.timer`.
- **Automatic restart** — if a service crashes, systemd can bring it straight back up.
- **Dependency ordering** — `After=network.target` means do not start until the network is up.
- **Centralised logs** — every service's output goes to the journal, so `journalctl -u <service>` works the same for everything.
- **Resource limits** — each service runs in its own cgroup, so I can cap its CPU and memory.

**Why it matters for DevOps:** when a service dies at 2 a.m., `systemctl status` and `journalctl -u` are the first two commands. `status` says whether it is running and why it stopped. `journalctl` says what it complained about before dying.

One thing worth remembering: `enabled` and `active` are different. `enabled` means it starts at boot. `active` means it is running now. A service can be active but not enabled, which means it disappears after a reboot.

---

## 5 commands I will use daily

| Command | What I use it for |
|---|---|
| `ps aux` | Full list of processes with CPU, memory and state. Usually piped into `grep` |
| `top` | Live view of what is using CPU and memory. Press `M` to sort by memory |
| `systemctl status <service>` | Is it running, is it enabled, why did it stop |
| `journalctl -u <service> -n 50` | Last 50 log lines for one service. Add `-f` to follow live |
| `kill -9 <pid>` | Force kill a stuck process. Try plain `kill` first so it can shut down cleanly |

---

## Things I want to remember

- User space asks, kernel space does. Every real operation is a syscall.
- Most processes sit in `S`. That is normal, not idle waste.
- `D` state points at the disk, not the application.
- Zombies are a parent bug, not a child problem.
- `enabled` is about boot, `active` is about now.
