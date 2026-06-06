# Day 03: Linux Commands Cheat Sheet

<img width="1509" height="688" alt="image" src="https://github.com/user-attachments/assets/e4f9a316-c18b-4e2c-8b32-105b5f03ceed" />



This is my go-to toolkit for navigating Linux, managing system processes, and troubleshooting network issues. 

## 📁 File System & Navigation
* **`pwd`** : Prints your current working directory (where you are right now).
* **`ls -lah`** : Lists all files (including hidden ones) with detailed info and human-readable sizes.
* **`cd /path/to/dir`** : Changes your current directory to the specified path.
* **`mkdir -p /path/to/folder`** : Creates a new directory, including any missing parent directories.
* **`rm -rf <folder_name>`** : Forcefully removes a directory and all its contents (use with extreme caution!).
* **`cp -r <source> <destination>`** : Copies a file or an entire directory recursively.
* **`mv <old_name> <new_name>`** : Moves a file to a new location or renames it.
* **`find / -name "app.log"`** : Searches the entire file system for a file named "app.log".
* **`df -h`** : Shows total, used, and available disk space on your mounted drives.
* **`du -sh *`** : Calculates and shows the size of every file and folder in your current directory.

## ⚙️ Process Management & System Info
* **`top`** : Displays a live, updating list of running processes and system resource usage (CPU/RAM).
* **`ps aux`** : Takes a static snapshot of all processes running on the system right now.
* **`kill -9 <PID>`** : Forcefully terminates a stubborn process using its Process ID.
* **`free -m`** : Shows total, used, and free system memory (RAM) in megabytes.
* **`uptime`** : Shows how long the system has been running and the current system load average.
* **`systemctl status <service>`** : Checks if a background service (like docker or sshd) is active or failed.
* **`systemctl restart <service>`** : Restarts a service to apply configuration changes or recover from a crash.
* **`journalctl -u <service> -f`** : Follows the live logs of a specific systemd service (great for debugging).

## 🌐 Networking Troubleshooting
* **`ping <domain_or_IP>`** : Sends packets to a host to check if it is reachable and measures response time.
* **`ip addr`** : Displays the IP addresses assigned to your machine's network interfaces.
* **`curl -v http://endpoint.com`** : Tests web endpoints, downloads files, and shows detailed HTTP headers.
* **`ss -tulpn`** : Lists all active network connections and the ports your server is currently listening on.
* **`dig <domain.com>`** : Performs a DNS lookup to see the IP addresses tied to a domain name.
* **`telnet <IP> <Port>`** : Tests if a specific port is open and accepting connections on a remote server.


