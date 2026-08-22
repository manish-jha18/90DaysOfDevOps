# Day 29 – Introduction to Docker

## Task 1: What is Docker?

### What is a container and why do we need them?

A container is a process running on the host kernel with its own isolated view of the filesystem, network and process tree. That is genuinely all it is — the "container" is not a thing the kernel knows about, it is a normal process with some restrictions applied.

Two Linux kernel features do the work:

- **Namespaces** decide what a process can *see*. Its own PID list, its own network interfaces, its own mount table. Inside the container, the app thinks it is PID 1 on its own machine.
- **cgroups** decide what a process can *use*. CPU, memory, IO limits.

The problem it solves is the one everybody quotes — "it works on my machine". An app depends on a particular Python version, particular system libraries, particular config. Move it to a server with different versions and it breaks. A container image packages the app *and* everything below it except the kernel, so the environment is identical everywhere.

The second reason is density. A server can run hundreds of containers because each one is just a process. It cannot run hundreds of VMs.

### Containers vs Virtual Machines

The real difference is **the kernel**.

```
VIRTUAL MACHINES                    CONTAINERS

┌──────┐ ┌──────┐ ┌──────┐         ┌──────┐ ┌──────┐ ┌──────┐
│ App  │ │ App  │ │ App  │         │ App  │ │ App  │ │ App  │
├──────┤ ├──────┤ ├──────┤         ├──────┤ ├──────┤ ├──────┤
│ Libs │ │ Libs │ │ Libs │         │ Libs │ │ Libs │ │ Libs │
├──────┤ ├──────┤ ├──────┤         └──────┘ └──────┘ └──────┘
│Guest │ │Guest │ │Guest │              ↓        ↓        ↓
│  OS  │ │  OS  │ │  OS  │         ┌────────────────────────┐
└──────┘ └──────┘ └──────┘         │    Docker Engine       │
     ↓        ↓        ↓            ├────────────────────────┤
┌────────────────────────┐          │      Host OS Kernel    │
│      Hypervisor        │          ├────────────────────────┤
├────────────────────────┤          │       Hardware         │
│      Host OS           │          └────────────────────────┘
├────────────────────────┤
│      Hardware          │
└────────────────────────┘
```

Each VM carries a **complete guest operating system** with its own kernel. Containers **share the host kernel** and carry only the libraries above it.

| | Virtual Machine | Container |
|---|---|---|
| Kernel | Its own | Shares the host's |
| Size | Gigabytes | Megabytes |
| Startup | 30 seconds to minutes | Under a second |
| Isolation | Strong — hardware level | Weaker — kernel level |
| Per host | Tens | Hundreds |
| Runs a different OS? | Yes, Windows on Linux | No, Linux only on a Linux kernel |

The isolation difference is the part worth taking seriously. A VM escape means defeating the hypervisor. A container escape means defeating the kernel — and every container shares that one kernel. That is why untrusted multi-tenant workloads still get VMs, and why running a container as root is worse than it sounds.

The Windows/Mac detail follows from this: Docker Desktop runs a small Linux VM underneath, because a Linux container needs a Linux kernel. So on my laptop it is containers *inside* a VM.

### Docker architecture

```
   ┌──────────────┐         ┌─────────────────────────────┐
   │ Docker CLI   │  REST   │      Docker Daemon          │
   │  (client)    │────────▶│       (dockerd)             │
   │ docker run   │  API    │                             │
   └──────────────┘         │  builds, runs, manages      │
                            │  ┌────────┐  ┌───────────┐  │
                            │  │ Images │  │Containers │  │
                            │  └────────┘  └───────────┘  │
                            │  ┌────────┐  ┌───────────┐  │
                            │  │Volumes │  │ Networks  │  │
                            │  └────────┘  └───────────┘  │
                            └──────────┬──────────────────┘
                                       │ pull / push
                                       ▼
                            ┌─────────────────────────────┐
                            │   Registry (Docker Hub)     │
                            └─────────────────────────────┘
```

**Docker client** — the `docker` command. It does almost nothing itself; it sends REST calls to the daemon over a Unix socket at `/var/run/docker.sock`.

**Docker daemon (`dockerd`)** — the process that does the actual work: pulling images, creating containers, managing networks and volumes. Runs as root.

**Image** — a read-only template. Layered, and layers are shared between images.

**Container** — a running instance of an image, with a thin writable layer on top.

**Registry** — where images are stored and shared. Docker Hub is the default.

The client/daemon split explains something from Day 08: `docker ps` gave "permission denied" because talking to the daemon means writing to `/var/run/docker.sock`, which is owned by the `docker` group. It also means the client can point at a daemon on another machine entirely by setting `DOCKER_HOST`.

Worth being aware of: membership of the `docker` group is effectively root access, because you can start a container that mounts the host filesystem.

---

## Task 2: Install Docker

```
devops@testvm:~$ sudo apt update && sudo apt install docker.io -y

devops@testvm:~$ docker --version
Docker version 24.0.7, build 24.0.7-0ubuntu2~22.04.1

devops@testvm:~$ sudo systemctl enable --now docker
Synchronizing state of docker.service with SysV service script...

devops@testvm:~$ sudo usermod -aG docker $USER
```

Logged out and back in for the group change to take effect — same lesson as Day 08, group membership is read at login.

```
devops@testvm:~$ docker run hello-world
Unable to find image 'hello-world:latest' locally
latest: Pulling from library/hello-world
c1ec31eb5944: Pull complete
Digest: sha256:d211f485f2dd1dee407a80973c8f129f00d54604d2c90732e8e320e5038a0348
Status: Downloaded newer image for hello-world:latest

Hello from Docker!
This message shows that your installation appears to be working correctly.

To generate this message, Docker took the following steps:
 1. The Docker client contacted the Docker daemon.
 2. The Docker daemon pulled the "hello-world" image from the Docker Hub.
    (amd64)
 3. The Docker daemon created a new container from that image which runs the
    executable that produces the output you are currently reading.
 4. The Docker daemon streamed that output to the Docker client, which sent it
    to your terminal.
```

Those four steps are the architecture diagram, described by the container itself. Client talks to daemon, daemon pulls from the registry, daemon creates the container, output streams back.

`Unable to find image ... locally` then `Pulling` is worth noting: `docker run` pulls automatically if the image is missing.

---

## Task 3: Run real containers

### Nginx

```
devops@testvm:~$ docker run -d -p 8080:80 --name web nginx
Unable to find image 'nginx:latest' locally
latest: Pulling from library/nginx
a2abf6c4d29d: Pull complete
c7a4e4382001: Pull complete
4044b9ba67c9: Pull complete
Status: Downloaded newer image for nginx:latest
7f3a91c4d2e58b1a6c9e0d4a1f27b8a35c6e9f2d1b4a7c0e3f6a9d2b5c8e1f4a

devops@testvm:~$ curl -I http://localhost:8080
HTTP/1.1 200 OK
Server: nginx/1.25.3
Content-Type: text/html
Content-Length: 615
```

That long hex string is the container ID. The short form (first 12 characters) is what `docker ps` shows and is enough for any command.

### Ubuntu, interactively

```
devops@testvm:~$ docker run -it --name mylinux ubuntu bash
Unable to find image 'ubuntu:latest' locally
latest: Pulling from library/ubuntu
Status: Downloaded newer image for ubuntu:latest

root@a1b2c3d4e5f6:/# whoami
root

root@a1b2c3d4e5f6:/# ls /
bin  boot  dev  etc  home  lib  media  mnt  opt  proc  root  run  sbin  srv  sys  tmp  usr  var

root@a1b2c3d4e5f6:/# ps aux
USER   PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root     1  0.1  0.0   4624  3968 pts/0    Ss   09:14   0:00 bash
root     9  0.0  0.0   7060  1580 pts/0    R+   09:14   0:00 ps aux

root@a1b2c3d4e5f6:/# cat /etc/os-release | head -2
PRETTY_NAME="Ubuntu 24.04.1 LTS"
NAME="Ubuntu"

root@a1b2c3d4e5f6:/# uname -r
5.15.0-119-generic

root@a1b2c3d4e5f6:/# exit
exit
```

Three things stand out:

**`ps aux` shows two processes.** On the host that command lists over a hundred. The PID namespace means the container sees only its own, and `bash` is PID 1. If PID 1 exits, the container stops — that is why a container "does nothing" if its main process is a one-shot command.

**`/etc/os-release` says Ubuntu 24.04 but `uname -r` shows my host's 5.15 kernel.** A perfect demonstration of the VM comparison — different userland, same kernel. There is no Ubuntu 24.04 kernel running anywhere.

**The hostname is the container ID.** Default behaviour, and it makes prompts easy to tell apart.

### Listing, stopping, removing

```
devops@testvm:~$ docker ps
CONTAINER ID   IMAGE     COMMAND                  CREATED         STATUS         PORTS                  NAMES
7f3a91c4d2e5   nginx     "/docker-entrypoint.…"   4 minutes ago   Up 4 minutes   0.0.0.0:8080->80/tcp   web

devops@testvm:~$ docker ps -a
CONTAINER ID   IMAGE         COMMAND                  CREATED         STATUS                     PORTS                  NAMES
7f3a91c4d2e5   nginx         "/docker-entrypoint.…"   4 minutes ago   Up 4 minutes               0.0.0.0:8080->80/tcp   web
a1b2c3d4e5f6   ubuntu        "bash"                   6 minutes ago   Exited (0) 2 minutes ago                          mylinux
b8c2d91e4f07   hello-world   "/hello"                 9 minutes ago   Exited (0) 9 minutes ago                          nifty_bardeen
```

`docker ps` shows only running containers. `-a` includes stopped ones — and they are still there, taking up disk, until removed. That is the source of the "why is my disk full" problem.

`nifty_bardeen` is a random name Docker generated because I did not pass `--name`.

```
devops@testvm:~$ docker stop web
web

devops@testvm:~$ docker rm web
web

devops@testvm:~$ docker rm mylinux nifty_bardeen
mylinux
nifty_bardeen
```

`docker stop` sends SIGTERM and waits 10 seconds before SIGKILL, so the app gets a chance to shut down cleanly. A running container cannot be removed without `-f`.

---

## Task 4: Explore

### Detached mode

```
devops@testvm:~$ docker run nginx
/docker-entrypoint.sh: /docker-entrypoint.d/ is not empty, will attempt to perform configuration
2026/07/07 09:31:02 [notice] 1#1: start worker processes
```

The terminal is stuck — logs stream to it and Ctrl+C stops the container. Useless for anything long-running.

```
devops@testvm:~$ docker run -d nginx
9e4f07b8c2d1a6f3e8b5c2d9f4a7e0b3c6d9f2a5e8b1c4d7f0a3e6b9c2d5f8a1
```

With `-d` it prints the container ID and returns immediately. The container runs in the background.

### Custom name

```
devops@testvm:~$ docker run -d --name my-nginx nginx
devops@testvm:~$ docker logs my-nginx
```

Without `--name` you get something like `nifty_bardeen` and end up copying IDs around. Named containers are also reachable by name on a custom network, which matters on Day 32.

### Port mapping

```
devops@testvm:~$ docker run -d -p 8080:80 --name web nginx

devops@testvm:~$ docker port web
80/tcp -> 0.0.0.0:8080
```

`-p 8080:80` is **host:container**. Traffic to port 8080 on my machine is forwarded to port 80 inside the container. Getting the order backwards is a rite of passage.

Without `-p`, the container runs but nothing outside can reach it. `EXPOSE` in a Dockerfile is only documentation — it does not publish anything.

```
devops@testvm:~$ docker run -d -p 8081:80 --name web2 nginx
devops@testvm:~$ docker ps --format "table {{.Names}}\t{{.Ports}}"
NAMES     PORTS
web2      0.0.0.0:8081->80/tcp
web       0.0.0.0:8080->80/tcp
```

Two containers both listening on port 80 internally, mapped to different host ports. No conflict, because each has its own network namespace.

### Logs

```
devops@testvm:~$ curl -s http://localhost:8080 > /dev/null
devops@testvm:~$ docker logs web
/docker-entrypoint.sh: Configuration complete; ready for start up
2026/07/07 09:38:14 [notice] 1#1: start worker processes
172.17.0.1 - - [07/Jul/2026:09:41:22 +0000] "GET / HTTP/1.1" 200 615 "-" "curl/7.81.0" "-"

devops@testvm:~$ docker logs -f web       # follow, Ctrl+C to stop
devops@testvm:~$ docker logs --tail 5 web
devops@testvm:~$ docker logs -t web       # with timestamps
```

`docker logs` shows whatever the main process wrote to stdout and stderr. This is why containerised apps log to stdout rather than to a file — anything written to a file inside the container is invisible to `docker logs` and disappears when the container is removed.

The client IP `172.17.0.1` is the host as seen from inside the container: the `docker0` bridge gateway, the same interface that showed up in Day 14's `ip addr`.

### Running commands inside a container

```
devops@testvm:~$ docker exec web ls /usr/share/nginx/html
50x.html
index.html

devops@testvm:~$ docker exec web cat /etc/nginx/nginx.conf | head -4
user  nginx;
worker_processes  auto;
error_log  /var/log/nginx/error.log notice;
pid        /var/run/nginx.pid;

devops@testvm:~$ docker exec -it web bash
root@7f3a91c4d2e5:/# nginx -v
nginx version: nginx/1.25.3
root@7f3a91c4d2e5:/# exit
```

`docker exec` starts a *new* process in an already-running container. `docker run` creates a new container. Confusing these is a common beginner mistake — `docker run -it nginx bash` gives a fresh container with bash instead of nginx, not a shell in the running one.

`-it` is two flags: `-i` keeps stdin open, `-t` allocates a TTY. Both are needed for an interactive shell; either alone behaves oddly.

Changes made with `exec` live in the container's writable layer and vanish when the container is removed. Fine for looking around, useless for configuration.

---

## What I learned

- **A container is a process, not a small VM.** `ps aux` inside Ubuntu showed two processes, and `uname -r` showed my host's kernel. Namespaces change what the process can see; they do not create a new machine.
- **`-p host:container`, in that order.** Without it the container is unreachable, and `EXPOSE` alone publishes nothing.
- **`docker run` creates, `docker exec` enters.** Different commands for genuinely different things.
- **Stopped containers persist** until removed, quietly consuming disk. `docker ps -a` is the honest view.
- **Containerised apps log to stdout** because that is what `docker logs` reads. Logging to a file inside a container is a dead end.
- Being in the `docker` group is effectively root on the host, since you can mount the host filesystem into a container.
