# Day 02: Linux Architecture, Processes, and systemd

## Core Components of Linux
Linux operates in layers to keep the system secure and stable.

* **Hardware:** The physical RAM, CPU, and disks.
* **The Kernel:** The core brain of the OS. It talks directly to the hardware and manages memory, CPU time, and devices.
* **User Space:** This is where we work. All our applications, commands, and scripts run here. Programs in user space cannot touch hardware directly; they must politely ask the kernel to do it.
* **Init System (systemd):** The very first process that starts after the kernel loads. It is responsible for booting up the rest of the system and keeping it running.

---

## Processes and Their States
A process is simply a program that is currently running. The kernel tracks every process and assigns it a unique ID (PID). 

A process goes through different states during its lifecycle:

* **Running (R):** The process is actively executing on the CPU or is in line ready to run.
* **Sleeping (S / D):** The process is waiting for something to happen, like waiting for a file to download or a user to type something. 
* **Stopped (T):** The process has been paused by a user signal (like pressing Ctrl+Z in the terminal).
* **Zombie (Z):** The process has finished its task and terminated, but its "parent" process hasn't read its final exit status yet. It is essentially a dead process leaving a tiny footprint.

---

## What is systemd and Why it Matters
**systemd** is the modern service and system manager for Linux. It has PID 1 (Process ID 1) because it is the first thing that starts.

* **What it does:** It starts background services (like web servers or databases), mounts drives, and manages system logging.
* **Why it matters for DevOps:** If an application crashes, systemd can automatically restart it. It also manages dependencies, ensuring that a database service starts completely before the web application tries to connect to it. 

---

## 5 Daily Commands for Troubleshooting

* **`top`** (or `htop`): Displays a live, real-time view of system resources (CPU/RAM) and running processes.
* **`ps aux`**: Takes a snapshot of all currently running processes across the entire system.
* **`systemctl status <service_name>`**: Checks if a specific background service (like nginx or docker) is running, failed, or stopped.
* **`kill <PID>`**: Sends a signal to terminate a stuck or misbehaving process using its Process ID.
* **`journalctl -eu <service_name>`**: Views the most recent logs for a specific service to help figure out why it crashed.
