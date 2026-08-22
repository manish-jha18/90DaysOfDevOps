# Day 08 – Cloud Server Setup: Docker, Nginx and Web Deployment

First day working on a real cloud server instead of a local VM. Launched an EC2 instance, installed Docker and Nginx, opened port 80, and served a page to the internet.

**Setup used:** AWS EC2, `t2.micro` (free tier), Ubuntu 22.04 LTS, region `ap-south-1`, public IP `13.234.19.204`.

---

## Part 1: Launch the instance and connect

Created the instance from the EC2 console: Ubuntu 22.04 AMI, `t2.micro`, new key pair `devops-key.pem`, and allowed SSH from my IP only.

The key file has to be locked down before SSH will touch it:

```
devops@testvm:~$ chmod 400 devops-key.pem

devops@testvm:~$ ssh -i devops-key.pem ubuntu@13.234.19.204
The authenticity of host '13.234.19.204' can't be established.
ED25519 key fingerprint is SHA256:kL8vQm2xR9pT4wN6yB1cJ7hF3sD5gA0eZ.
Are you sure you want to continue connecting (yes/no/[fingerprint])? yes
Warning: Permanently added '13.234.19.204' (ED25519) to the list of known hosts.
Welcome to Ubuntu 22.04.4 LTS (GNU/Linux 6.8.0-1014-aws x86_64)

  System information as of Tue Jun 16 08:31:12 UTC 2026

  System load:  0.08              Processes:             104
  Usage of /:   21.4% of 7.57GB   Users logged in:       0
  Memory usage: 24%               IPv4 address for eth0: 172.31.14.88

ubuntu@ip-172-31-14-88:~$
```

The prompt changed to `ubuntu@ip-172-31-14-88`, which is the private IP. The public IP is what I connect to from outside; the box itself only knows its private address.

---

## Part 2: Install Docker and Nginx

**Update the package list first:**

```
ubuntu@ip-172-31-14-88:~$ sudo apt update && sudo apt upgrade -y
Get:1 http://ap-south-1.ec2.archive.ubuntu.com/ubuntu jammy InRelease [270 kB]
Get:2 http://ap-south-1.ec2.archive.ubuntu.com/ubuntu jammy-updates InRelease [128 kB]
Fetched 6,842 kB in 2s (3,102 kB/s)
Reading package lists... Done
Building dependency tree... Done
28 packages can be upgraded.
```

**Install Docker:**

```
ubuntu@ip-172-31-14-88:~$ sudo apt install docker.io -y

ubuntu@ip-172-31-14-88:~$ sudo systemctl enable --now docker
Synchronizing state of docker.service with SysV service script...

ubuntu@ip-172-31-14-88:~$ docker --version
Docker version 24.0.7, build 24.0.7-0ubuntu2~22.04.1
```

Running `docker ps` as my normal user failed at first:

```
ubuntu@ip-172-31-14-88:~$ docker ps
permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock
```

Fixed by adding myself to the `docker` group, then reconnecting so the new group applies:

```
ubuntu@ip-172-31-14-88:~$ sudo usermod -aG docker ubuntu
ubuntu@ip-172-31-14-88:~$ exit

devops@testvm:~$ ssh -i devops-key.pem ubuntu@13.234.19.204

ubuntu@ip-172-31-14-88:~$ docker ps
CONTAINER ID   IMAGE     COMMAND   CREATED   STATUS    PORTS     NAMES
```

Empty list, but no error. That is the result I wanted.

**Install Nginx:**

```
ubuntu@ip-172-31-14-88:~$ sudo apt install nginx -y

ubuntu@ip-172-31-14-88:~$ systemctl status nginx --no-pager
● nginx.service - A high performance web server and a reverse proxy server
     Loaded: loaded (/lib/systemd/system/nginx.service; enabled; vendor preset: enabled)
     Active: active (running) since Tue 2026-06-16 08:44:19 UTC; 21s ago
   Main PID: 1841 (nginx)
      Tasks: 2 (limit: 1121)
     Memory: 3.1M
        CPU: 28ms
     CGroup: /system.slice/nginx.service
             ├─1841 "nginx: master process /usr/sbin/nginx -g daemon on; master_process on;"
             └─1842 "nginx: worker process"
```

**Confirm it answers locally before worrying about the internet:**

```
ubuntu@ip-172-31-14-88:~$ curl -I http://localhost
HTTP/1.1 200 OK
Server: nginx/1.18.0 (Ubuntu)
Date: Tue, 16 Jun 2026 08:55:41 GMT
Content-Type: text/html
Content-Length: 615
Connection: keep-alive
```

`200 OK` from inside the box. So Nginx is fine and anything still broken is a network problem, not a web server problem.

---

## Part 3: Security group configuration

The browser timed out at first. Nginx was running and `curl localhost` worked, so the block had to be the security group — port 80 was never opened.

Added an inbound rule in the EC2 console:

| Type | Protocol | Port | Source |
|---|---|---|---|
| SSH | TCP | 22 | My IP only |
| HTTP | TCP | 80 | 0.0.0.0/0 |

Checked from my laptop:

```
devops@testvm:~$ curl -I http://13.234.19.204
HTTP/1.1 200 OK
Server: nginx/1.18.0 (Ubuntu)
Date: Tue, 16 Jun 2026 08:52:14 GMT
Content-Type: text/html
Content-Length: 615
Connection: keep-alive
```

**A custom page to confirm I control the content:**

```
ubuntu@ip-172-31-14-88:~$ echo "<h1>Day 08 - Deployed by Manish</h1>" | sudo tee /var/www/html/devops.html
<h1>Day 08 - Deployed by Manish</h1>
```

Loads at `http://13.234.19.204/devops.html`.

---

## Part 4: Extract Nginx logs

Nginx writes two logs. Access log for every request, error log for what went wrong.

```
ubuntu@ip-172-31-14-88:~$ sudo tail -n 5 /var/log/nginx/access.log
13.126.44.87 - - [16/Jun/2026:09:01:19 +0000] "GET /devops.html HTTP/1.1" 200 328 "-" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/126.0.0.0"
13.126.44.87 - - [16/Jun/2026:09:01:44 +0000] "GET /missing-page HTTP/1.1" 404 555 "-" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/126.0.0.0"
185.220.101.34 - - [16/Jun/2026:09:07:55 +0000] "GET /wp-login.php HTTP/1.1" 404 555 "-" "Mozilla/5.0 (compatible; Nmap Scripting Engine)"
185.220.101.34 - - [16/Jun/2026:09:07:56 +0000] "GET /.env HTTP/1.1" 404 555 "-" "Mozilla/5.0 (compatible; Nmap Scripting Engine)"
13.126.44.87 - - [16/Jun/2026:09:15:22 +0000] "GET / HTTP/1.1" 200 615 "-" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/126.0.0.0"
```

Worth pausing on those `185.220.101.34` lines. That is not me. Within 20 minutes of opening port 80, a bot was probing for `/wp-login.php` and `/.env`. All returned 404, but if I had left a real `.env` in the web root it would have been handed over. Good reminder that a public IP gets scanned immediately.

**Save both logs to a file:**

```
ubuntu@ip-172-31-14-88:~$ sudo cat /var/log/nginx/access.log /var/log/nginx/error.log > ~/nginx-logs.txt
-bash: /home/ubuntu/nginx-logs.txt: Permission denied
```

That failed and it took me a minute to see why. `sudo` applies to `cat`, but the `>` redirect is done by my shell, which is not root. Two ways round it:

```
ubuntu@ip-172-31-14-88:~$ sudo sh -c 'cat /var/log/nginx/access.log /var/log/nginx/error.log > /home/ubuntu/nginx-logs.txt'
ubuntu@ip-172-31-14-88:~$ sudo chown ubuntu:ubuntu ~/nginx-logs.txt

ubuntu@ip-172-31-14-88:~$ ls -l ~/nginx-logs.txt
-rw-r--r-- 1 ubuntu ubuntu 3218 Jun 16 09:18 /home/ubuntu/nginx-logs.txt
```

**Download it to my laptop:**

```
devops@testvm:~$ scp -i devops-key.pem ubuntu@13.234.19.204:~/nginx-logs.txt .
nginx-logs.txt                                100% 3218   28.4KB/s   00:00
```

The file is saved in this folder as `nginx-logs.txt`.

---

## Commands Used

| Command | Purpose |
|---|---|
| `chmod 400 devops-key.pem` | Lock the key file, SSH refuses anything looser |
| `ssh -i devops-key.pem ubuntu@<ip>` | Connect to the instance |
| `sudo apt update && sudo apt upgrade -y` | Refresh and update packages |
| `sudo apt install docker.io -y` | Install Docker |
| `sudo systemctl enable --now docker` | Start Docker and enable it at boot |
| `sudo usermod -aG docker ubuntu` | Run docker without sudo |
| `sudo apt install nginx -y` | Install Nginx |
| `systemctl status nginx` | Confirm the service is running |
| `curl -I http://localhost` | Test locally before testing publicly |
| `sudo tail -n 20 /var/log/nginx/access.log` | Read the access log |
| `sudo sh -c 'cat ... > file'` | Redirect as root |
| `scp -i key.pem ubuntu@<ip>:~/file .` | Copy a file down to my laptop |

---

## Challenges Faced

**1. Browser timed out but the server was fine.**
`curl localhost` returned 200 while the browser hung. The gap between those two results is the security group. Testing locally first told me the web server was healthy and saved me from restarting Nginx for no reason.

**2. `docker ps` gave permission denied.**
The Docker socket is owned by the `docker` group. Adding myself with `usermod -aG` was not enough on its own — group membership is read at login, so I had to disconnect and reconnect.

**3. `sudo cat ... > file` still failed.**
The redirect is performed by my shell, not by `sudo`. Wrapping the whole thing in `sudo sh -c '...'` fixed it. This one is worth remembering because the error message points nowhere near the real cause.

**4. Public IP changes on stop/start.**
I stopped the instance to save free-tier hours and came back to a different IP. An Elastic IP would keep it fixed.

---

## What I Learned

- Test from inside the box before blaming the network. `curl localhost` splits "is the service broken" from "is the firewall closed" in one command.
- Security groups are the first thing to check when a cloud service is unreachable from outside but healthy inside.
- `sudo` applies to the command, not to the redirect. Use `sudo sh -c` or `tee` when writing to a protected path.
- Group changes need a fresh login to take effect.
- A public IP is scanned by bots within minutes. Nothing sensitive belongs in a web root, ever.
- Nginx keeps two separate logs, and the error log gives the actual filesystem path it tried to open, which makes 404s easy to diagnose.
