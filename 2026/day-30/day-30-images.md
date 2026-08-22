# Day 30 – Docker Images and Container Lifecycle

## Task 1: Docker images

```
devops@testvm:~$ docker pull nginx
devops@testvm:~$ docker pull ubuntu
devops@testvm:~$ docker pull alpine
Using default tag: latest
latest: Pulling from library/alpine
96526aa774ef: Pull complete
Status: Downloaded newer image for alpine:latest

devops@testvm:~$ docker images
REPOSITORY    TAG       IMAGE ID       CREATED        SIZE
nginx         latest    a72860cb95fd   2 weeks ago    188MB
ubuntu        latest    35a88802559d   3 weeks ago    78.1MB
alpine        latest    a606584aa9aa   5 weeks ago    7.8MB
hello-world   latest    d2c94e258dcb   8 months ago   13.3kB
```

### Why is alpine so much smaller than ubuntu?

7.8 MB against 78.1 MB — ten times smaller. Two reasons:

**A different C library.** Alpine uses **musl libc**; Ubuntu uses **glibc**. musl is a much smaller implementation aiming at size and simplicity rather than completeness.

**A different userland.** Ubuntu ships full GNU coreutils — separate binaries for `ls`, `cp`, `grep` and so on. Alpine uses **BusyBox**, one binary implementing simplified versions of them all.

```
devops@testvm:~$ docker run --rm alpine ls -la /bin/ls /bin/cp
lrwxrwxrwx    1 root     root   12 Jun  2 09:14 /bin/cp -> /bin/busybox
lrwxrwxrwx    1 root     root   12 Jun  2 09:14 /bin/ls -> /bin/busybox

devops@testvm:~$ docker run --rm ubuntu ls -la /bin/ls /bin/cp
-rwxr-xr-x 1 root root 138208 Mar 23  2024 /bin/ls
-rwxr-xr-x 1 root root 149console56 Mar 23  2024 /bin/cp
```

In Alpine both are symlinks to one BusyBox binary. In Ubuntu they are separate programs.

The catch is not free size. musl is not fully glibc-compatible, so some pre-compiled binaries fail on Alpine in ways that are hard to debug — Python packages with C extensions are the classic case. And BusyBox tools accept fewer flags, which breaks scripts written against GNU versions.

Smaller images matter because they pull faster, cost less to store, and carry fewer packages that could have vulnerabilities. `python:3.12-slim` is often the sensible middle ground.

### Inspecting an image

```
devops@testvm:~$ docker inspect nginx --format '{{json .Config}}' | head -c 400
{"Hostname":"","User":"","ExposedPorts":{"80/tcp":{}},"Env":["PATH=/usr/local/sbin:...","NGINX_VERSION=1.25.3"],"Cmd":["nginx","-g","daemon off;"],"Entrypoint":["/docker-entrypoint.sh"]}

devops@testvm:~$ docker inspect nginx --format '{{.Config.Cmd}}'
[nginx -g daemon off;]

devops@testvm:~$ docker inspect nginx --format '{{.Config.Entrypoint}}'
[/docker-entrypoint.sh]

devops@testvm:~$ docker inspect nginx --format '{{.Architecture}} {{.Os}}'
amd64 linux

devops@testvm:~$ docker inspect nginx --format '{{len .RootFS.Layers}}'
7
```

`daemon off;` is the important detail. Nginx normally daemonises into the background, but a container stops when PID 1 exits — so the image explicitly tells nginx to stay in the foreground. Every containerised service does some version of this.

`--format` is much more usable than the full JSON, which is several hundred lines.

### Removing an image

```
devops@testvm:~$ docker rmi hello-world
Untagged: hello-world:latest
Deleted: sha256:d2c94e258dcb3c5ac2798d32e1249e42ef01cba4841c2234249495f87264ac5a

devops@testvm:~$ docker rmi ubuntu
Error response from daemon: conflict: unable to remove repository reference "ubuntu"
(must force) - container a1b2c3d4e5f6 is using its referenced image 35a88802559d
```

Docker refuses to remove an image a container still references, even a stopped one. Remove the container first, or use `-f`.

---

## Task 2: Image layers

```
devops@testvm:~$ docker image history nginx
IMAGE          CREATED       CREATED BY                                      SIZE      COMMENT
a72860cb95fd   2 weeks ago   CMD ["nginx" "-g" "daemon off;"]                0B        buildkit.dockerfile.v0
<missing>      2 weeks ago   STOPSIGNAL SIGQUIT                              0B        buildkit.dockerfile.v0
<missing>      2 weeks ago   EXPOSE map[80/tcp:{}]                           0B        buildkit.dockerfile.v0
<missing>      2 weeks ago   ENTRYPOINT ["/docker-entrypoint.sh"]            0B        buildkit.dockerfile.v0
<missing>      2 weeks ago   COPY 30-tune-worker-processes.sh /docker-ent…   4.62kB    buildkit.dockerfile.v0
<missing>      2 weeks ago   COPY 20-envsubst-on-templates.sh /docker-ent…   3.02kB    buildkit.dockerfile.v0
<missing>      2 weeks ago   COPY docker-entrypoint.sh / # buildkit          1.62kB    buildkit.dockerfile.v0
<missing>      2 weeks ago   RUN /bin/sh -c set -x  && groupadd --system …   109MB     buildkit.dockerfile.v0
<missing>      2 weeks ago   ENV NGINX_VERSION=1.25.3                        0B        buildkit.dockerfile.v0
<missing>      2 weeks ago   /bin/sh -c #(nop) ADD file:4c4b7b1b0a1b0e0a…    74.8MB    <none>
```

### What are layers and why does Docker use them?

Each instruction in a Dockerfile produces a layer — a read-only diff of what changed in the filesystem. The image is those layers stacked, presented as one filesystem by a union filesystem driver (overlay2).

Reading the sizes: the base Debian filesystem is 74.8 MB, the `RUN` that installs nginx adds 109 MB, and everything else is tiny. `EXPOSE`, `CMD`, `ENTRYPOINT` and `ENV` are **0B** because they only set metadata — they change no files.

Three reasons layers matter:

**Sharing.** A layer is identified by the hash of its content, so identical layers are stored once. Ten images built on `python:3.12` share that base on disk and only download it once.

```
devops@testvm:~$ docker pull nginx:1.25-alpine
1.25-alpine: Pulling from library/nginx
96526aa774ef: Already exists
a2abf6c4d29d: Pull complete
```

`Already exists` — the alpine base was there from the earlier pull, so it was not downloaded again.

**Build caching.** Rebuilding reuses unchanged layers. This is why Dockerfile instruction order matters so much, and it is Day 31's topic.

**Efficient distribution.** Pushing a new version of an app uploads only the changed layer, not the whole image.

The trade-off: **layers are additive, so deleting a file does not shrink the image.**

```dockerfile
RUN wget https://example.com/big-file.tar.gz    # layer 1: +200MB
RUN tar -xzf big-file.tar.gz                    # layer 2: +200MB
RUN rm big-file.tar.gz                          # layer 3: +0MB, still 400MB total
```

Layer 3 records a deletion, but layer 1 still holds the file and is still shipped. The fix is one `RUN` with `&&`, so the file never exists at the end of the layer. That is why real Dockerfiles have long chained `RUN` commands ending in `rm -rf /var/lib/apt/lists/*`.

`<missing>` in the IMAGE column is normal — only the final layer gets an ID locally; intermediate layers of a pulled image do not.

---

## Task 3: Container lifecycle

Full lifecycle on one container, checking state at each step.

```
devops@testvm:~$ docker create --name lifecycle-demo nginx
c4d2e58b1a6c9e0d4a1f27b8a35c6e9f2d1b4a7c0e3f6a9d2b5c8e1f4a7b0c3d

devops@testvm:~$ docker ps -a --filter name=lifecycle-demo
CONTAINER ID   IMAGE   COMMAND                  CREATED         STATUS    PORTS   NAMES
c4d2e58b1a6c   nginx   "/docker-entrypoint.…"   3 seconds ago   Created           lifecycle-demo
```

`Created` — the container exists, filesystem and config are set up, but no process is running.

```
devops@testvm:~$ docker start lifecycle-demo
lifecycle-demo
devops@testvm:~$ docker ps --filter name=lifecycle-demo --format "{{.Names}}: {{.Status}}"
lifecycle-demo: Up 2 seconds
```

```
devops@testvm:~$ docker pause lifecycle-demo
devops@testvm:~$ docker ps --filter name=lifecycle-demo --format "{{.Names}}: {{.Status}}"
lifecycle-demo: Up 18 seconds (Paused)
```

`pause` uses the cgroup freezer. Processes are suspended mid-execution and keep all their memory — quite different from stopping, which ends them.

```
devops@testvm:~$ docker unpause lifecycle-demo
devops@testvm:~$ docker stop lifecycle-demo
devops@testvm:~$ docker ps -a --filter name=lifecycle-demo --format "{{.Names}}: {{.Status}}"
lifecycle-demo: Exited (0) 3 seconds ago
```

Exit code 0 — clean shutdown after SIGTERM.

```
devops@testvm:~$ docker restart lifecycle-demo
devops@testvm:~$ docker kill lifecycle-demo
devops@testvm:~$ docker ps -a --filter name=lifecycle-demo --format "{{.Names}}: {{.Status}}"
lifecycle-demo: Exited (137) 2 seconds ago
```

**Exit code 137 instead of 0.** That is 128 + 9, meaning killed by signal 9 (SIGKILL). `kill` sends SIGKILL immediately with no chance to clean up, where `stop` sends SIGTERM and waits.

Exit 137 is worth memorising — it is also what you see when the kernel OOM-killer terminates a container for exceeding its memory limit.

```
devops@testvm:~$ docker rm lifecycle-demo
lifecycle-demo
```

### State diagram

```
                 docker create
                       │
                       ▼
                  ┌─────────┐
                  │ Created │
                  └────┬────┘
                       │ docker start
                       ▼
     docker pause ┌─────────┐ docker stop (SIGTERM, then SIGKILL)
        ┌─────────│ Running │──────────────┐
        ▼         └─────────┘              ▼
   ┌────────┐          ▲   │ docker kill  ┌────────┐
   │ Paused │──────────┘   │  (SIGKILL)   │ Exited │
   └────────┘  unpause     └─────────────▶└───┬────┘
                                              │ docker start / restart
                                              │ docker rm
                                              ▼
                                          (removed)
```

`docker run` is just `docker create` plus `docker start`.

---

## Task 4: Working with running containers

```
devops@testvm:~$ docker run -d -p 8080:80 --name web nginx
devops@testvm:~$ curl -s localhost:8080 > /dev/null

devops@testvm:~$ docker logs web
/docker-entrypoint.sh: Configuration complete; ready for start up
2026/07/08 10:02:41 [notice] 1#1: start worker processes
172.17.0.1 - - [08/Jul/2026:10:04:12 +0000] "GET / HTTP/1.1" 200 615 "-" "curl/7.81.0" "-"

devops@testvm:~$ docker logs -f --tail 10 web        # follow mode, Ctrl+C to leave
```

```
devops@testvm:~$ docker exec -it web bash
root@8b1c4d7f0a3e:/# ls /usr/share/nginx/html
50x.html  index.html
root@8b1c4d7f0a3e:/# df -h /
Filesystem      Size  Used Avail Use% Mounted on
overlay          19G  9.1G  8.9G  51% /
root@8b1c4d7f0a3e:/# exit
```

The root filesystem shows as `overlay` — that is the union filesystem stacking the image's read-only layers with the container's writable layer.

```
devops@testvm:~$ docker exec web nginx -v
nginx version: nginx/1.25.3
```

```
devops@testvm:~$ docker inspect web --format '{{.NetworkSettings.IPAddress}}'
172.17.0.2

devops@testvm:~$ docker inspect web --format '{{json .NetworkSettings.Ports}}'
{"80/tcp":[{"HostIp":"0.0.0.0","HostPort":"8080"}]}

devops@testvm:~$ docker inspect web --format '{{json .Mounts}}'
[]

devops@testvm:~$ docker inspect web --format '{{.State.Status}} (pid {{.State.Pid}})'
running (pid 4218)
```

`172.17.0.2` on the default bridge, and the host is `172.17.0.1`. No mounts, so everything written inside is in the throwaway writable layer.

That PID is a real host process:

```
devops@testvm:~$ ps -p 4218 -o pid,cmd
    PID CMD
   4218 nginx: master process nginx -g daemon off;
```

Visible in the host's process list, exactly as expected for something that is a process rather than a VM.

---

## Task 5: Cleanup

```
devops@testvm:~$ docker stop $(docker ps -q)
8b1c4d7f0a3e
9e4f07b8c2d1

devops@testvm:~$ docker rm $(docker ps -aq)
8b1c4d7f0a3e
9e4f07b8c2d1
a1b2c3d4e5f6
```

`docker ps -q` prints only IDs, which is what makes the command substitution work. `-aq` includes stopped containers.

```
devops@testvm:~$ docker system df
TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          4         0         274.1MB   274.1MB (100%)
Containers      0         0         0B        0B
Local Volumes   2         0         184.3MB   184.3MB (100%)
Build Cache     12        0         48.2MB    48.2MB
```

274 MB of images, none in use, plus 184 MB of orphaned volumes from earlier experiments. This is the command to run when a build server runs out of disk.

```
devops@testvm:~$ docker image prune
WARNING! This will remove all dangling images.
Are you sure you want to continue? [y/N] y
Total reclaimed space: 0B

devops@testvm:~$ docker image prune -a
WARNING! This will remove all images without at least one container associated to them.
Are you sure you want to continue? [y/N] y
Deleted: sha256:a72860cb95fd59e9c696c66441c64f18e66915fa26b249911e83c3854477ed9a
Total reclaimed space: 274.1MB
```

The difference matters. Plain `prune` removes only **dangling** images — untagged leftovers from rebuilds. `-a` removes every image not used by a container, which on a laptop means re-downloading everything afterwards.

```
devops@testvm:~$ docker system prune -a --volumes
WARNING! This will remove:
  - all stopped containers
  - all networks not used by at least one container
  - all volumes not used by at least one container
  - all images without at least one container associated to them
  - all build cache
Total reclaimed space: 506.6MB
```

`--volumes` is the dangerous flag — that is where database data lives. Deleting a container and pruning volumes is how people lose a local database. Everything else here is re-downloadable; volumes are not.

---

## What I learned

**1. Layers are additive, so deleting a file in a later layer does not shrink the image.** The file still exists in the earlier layer and still ships. That single fact explains why real Dockerfiles chain everything into one `RUN` ending with a cleanup — it is not stylistic, it is the only way the cleanup counts.

**2. Exit codes tell you how a container died.** 0 is clean, 137 is SIGKILL — either `docker kill` or the OOM-killer. Seeing the difference between `stop` and `kill` in the exit code made SIGTERM versus SIGKILL concrete rather than theoretical.

**3. `docker system df` before `docker system prune`.** Look at what will be reclaimed first. `prune -a --volumes` will happily delete your local database volume, and unlike images it cannot be re-downloaded.

**Two extras:**

- Images with `daemon off;` and similar exist because a container stops when PID 1 exits. Services that normally background themselves have to be told not to.
- The container's PID from `docker inspect` is a real process in the host's `ps` output. Best reminder that containers are processes.
