# Day 31 – Dockerfile: Build Your Own Images

All Dockerfiles are in this folder, one subfolder per task.

---

## Task 1: My first Dockerfile

**`my-first-image/Dockerfile`**

```dockerfile
FROM ubuntu:22.04

RUN apt-get update && \
    apt-get install -y curl && \
    rm -rf /var/lib/apt/lists/*

CMD ["echo", "Hello from my custom image!"]
```

```
devops@testvm:~/day-31/my-first-image$ docker build -t my-ubuntu:v1 .
[+] Building 24.7s (6/6) FINISHED
 => [internal] load build definition from Dockerfile              0.0s
 => [internal] load metadata for docker.io/library/ubuntu:22.04   1.2s
 => [1/2] FROM docker.io/library/ubuntu:22.04                     3.8s
 => [2/2] RUN apt-get update &&     apt-get install -y curl &&…  18.4s
 => exporting to image                                            1.1s
 => => naming to docker.io/library/my-ubuntu:v1                   0.0s

devops@testvm:~/day-31/my-first-image$ docker run --rm my-ubuntu:v1
Hello from my custom image!

devops@testvm:~/day-31/my-first-image$ docker run --rm my-ubuntu:v1 curl --version
curl 7.81.0 (x86_64-pc-linux-gnu) libcurl/7.81.0 OpenSSL/3.0.2 zlib/1.2.11
```

Three things I did deliberately:

**`ubuntu:22.04` not `ubuntu:latest`.** `latest` moves. An image that built fine last month can break today because the base changed underneath. Pinning is the difference between a reproducible build and a coin flip.

**Everything in one `RUN`, joined with `&&`.** From Day 30 — each `RUN` is a layer, and deleting a file in a later layer does not shrink the image. `apt-get update` in its own layer would also leave a stale package index cached forever.

**`rm -rf /var/lib/apt/lists/*` in the same `RUN`.** The apt package index is about 40 MB and useless at runtime. Removing it in the same layer means it never lands in the image at all.

```
devops@testvm:~$ docker images my-ubuntu
REPOSITORY   TAG   IMAGE ID       CREATED         SIZE
my-ubuntu    v1    3f8a2c91d4e7   2 minutes ago   121MB
```

`--rm` on `docker run` deletes the container when it exits — worth using for anything throwaway, or `docker ps -a` fills with dead containers.

---

## Task 2: All the instructions

**`all-instructions/Dockerfile`**

```dockerfile
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 5000

CMD ["python", "app.py"]
```

With `app.py` (a four-line Flask app) and `requirements.txt` alongside it.

| Instruction | What it does here |
|---|---|
| `FROM` | Base image. Everything is built on top of this |
| `WORKDIR` | Creates `/app` and makes it the working directory for every later instruction and for the running container |
| `COPY` | Copies from the build context into the image |
| `RUN` | Executes at **build** time, and the result is baked into a layer |
| `EXPOSE` | Documents that the app listens on 5000. Publishes nothing |
| `CMD` | What runs when the container starts |

```
devops@testvm:~/day-31/all-instructions$ docker build -t flask-demo:v1 .
[+] Building 12.3s (10/10) FINISHED

devops@testvm:~/day-31/all-instructions$ docker run -d -p 5000:5000 --name flask flask-demo:v1
devops@testvm:~/day-31/all-instructions$ curl localhost:5000
Hello from a container built with all six instructions
```

**`RUN` versus `CMD` is the distinction worth being clear about.** `RUN` happens once, at build time, and its effect is stored in the image. `CMD` happens every time a container starts and is stored only as metadata.

**`WORKDIR` rather than `RUN cd /app`.** A `cd` in a `RUN` only affects that one layer — the next instruction is back at `/`. `WORKDIR` persists.

**`EXPOSE` really does nothing on its own:**

```
devops@testvm:~$ docker run -d --name no-ports flask-demo:v1
devops@testvm:~$ curl localhost:5000
curl: (7) Failed to connect to localhost port 5000: Connection refused
```

The image says `EXPOSE 5000` and the app is listening, but without `-p` there is no route in. `EXPOSE` is documentation for humans and for `docker run -P`, nothing more.

**`--no-cache-dir` on pip.** pip caches downloaded wheels in `~/.cache/pip`, which is pure waste inside an image. Saves 30–50 MB on a typical dependency set.

---

## Task 3: CMD vs ENTRYPOINT

**`Dockerfile.cmd`**

```dockerfile
FROM alpine:3.20
CMD ["echo", "hello"]
```

```
devops@testvm:~/day-31/cmd-vs-entrypoint$ docker build -f Dockerfile.cmd -t demo-cmd .

devops@testvm:~/day-31/cmd-vs-entrypoint$ docker run --rm demo-cmd
hello

devops@testvm:~/day-31/cmd-vs-entrypoint$ docker run --rm demo-cmd echo goodbye
goodbye

devops@testvm:~/day-31/cmd-vs-entrypoint$ docker run --rm demo-cmd ls /
bin  dev  etc  home  lib  media  mnt  opt  proc  root  run  sbin  srv  sys  tmp  usr  var
```

**CMD is replaced entirely.** Anything after the image name overrides it. The container ran `ls /` and the `echo hello` was simply discarded.

**`Dockerfile.entrypoint`**

```dockerfile
FROM alpine:3.20
ENTRYPOINT ["echo"]
```

```
devops@testvm:~/day-31/cmd-vs-entrypoint$ docker build -f Dockerfile.entrypoint -t demo-entry .

devops@testvm:~/day-31/cmd-vs-entrypoint$ docker run --rm demo-entry

devops@testvm:~/day-31/cmd-vs-entrypoint$ docker run --rm demo-entry hello world
hello world

devops@testvm:~/day-31/cmd-vs-entrypoint$ docker run --rm demo-entry ls /
ls /
```

**ENTRYPOINT is appended to, not replaced.** The last one is the giveaway — it printed the literal text `ls /` instead of listing the directory, because the container ran `echo ls /`. The entrypoint cannot be escaped from the command line without `--entrypoint`.

**The two together — `Dockerfile.both`:**

```dockerfile
FROM alpine:3.20
ENTRYPOINT ["ping", "-c", "3"]
CMD ["localhost"]
```

```
devops@testvm:~/day-31/cmd-vs-entrypoint$ docker run --rm demo-both
PING localhost (127.0.0.1): 56 data bytes
64 bytes from 127.0.0.1: seq=0 ttl=64 time=0.048 ms
--- localhost ping statistics ---
3 packets transmitted, 3 packets received, 0% packet loss

devops@testvm:~/day-31/cmd-vs-entrypoint$ docker run --rm demo-both 8.8.8.8
PING 8.8.8.8 (8.8.8.8): 56 data bytes
64 bytes from 8.8.8.8: seq=0 ttl=115 time=13.9 ms
--- 8.8.8.8 ping statistics ---
3 packets transmitted, 3 packets received, 0% packet loss
```

`ENTRYPOINT` fixes the command, `CMD` supplies default arguments the user can override. This is the pattern most real images use.

### When to use which

| | Use |
|---|---|
| **CMD alone** | The image can reasonably run different things. Base images like `ubuntu` or `python` |
| **ENTRYPOINT alone** | The container *is* one tool and should always run it |
| **Both** | The container is one tool with sensible default arguments |

Rule of thumb: if the container is a service that should always run that service, use `ENTRYPOINT`. If it is a general-purpose environment, use `CMD`.

**One trap worth knowing** — shell form versus exec form:

```dockerfile
CMD ["nginx", "-g", "daemon off;"]     # exec form: nginx becomes PID 1
CMD nginx -g "daemon off;"             # shell form: /bin/sh -c is PID 1
```

With the shell form, PID 1 is `sh`, which does not forward SIGTERM to its child. `docker stop` then waits the full 10 seconds and SIGKILLs the container instead of shutting it down cleanly. **Always use the JSON array form** unless shell features are genuinely needed.

---

## Task 4: A static website

**`my-website/index.html`** — a small HTML page.

**`my-website/Dockerfile`**

```dockerfile
FROM nginx:1.25-alpine

COPY index.html /usr/share/nginx/html/index.html

EXPOSE 80
```

```
devops@testvm:~/day-31/my-website$ docker build -t my-website:v1 .
[+] Building 2.1s (7/7) FINISHED

devops@testvm:~/day-31/my-website$ docker run -d -p 8080:80 --name site my-website:v1

devops@testvm:~/day-31/my-website$ curl -s localhost:8080 | grep h1
  <h1>Day 31 - Built with a Dockerfile</h1>
```

No `CMD` needed — the base image already sets `nginx -g "daemon off;"` and I am not changing it. Repeating it would just be noise.

`nginx:1.25-alpine` instead of `nginx:1.25`:

```
devops@testvm:~$ docker images | grep -E "nginx|my-website"
my-website   v1            8c1f4a2b9d3e   1 minute ago    43.2MB
nginx        1.25-alpine   4f2e91a7c8b0   2 weeks ago     43.2MB
nginx        latest        a72860cb95fd   2 weeks ago     188MB
```

43 MB against 188 MB for the same job. And `my-website:v1` reports 43.2 MB, the same as its base — because the only thing added is a 400-byte HTML file, and the base layers are shared rather than duplicated.

---

## Task 5: .dockerignore

**`my-website/.dockerignore`**

```
node_modules
.git
.gitignore
*.md
.env
*.log
.DS_Store
Dockerfile
.dockerignore
```

The build context is everything in the directory, and it all gets sent to the daemon before the build starts. Without `.dockerignore`:

```
devops@testvm:~/day-31/my-website$ docker build -t test .
Sending build context to Docker daemon  47.3MB
```

With it:

```
devops@testvm:~/day-31/my-website$ docker build -t test .
Sending build context to Docker daemon  4.096kB
```

47 MB down to 4 KB, because `.git` and `node_modules` are no longer being uploaded.

Two reasons this matters beyond speed:

**Secrets.** A `COPY . .` with a `.env` in the folder puts your credentials in the image, and anyone who pulls it can read them with `docker history`. Excluding `.env` is a security control, not an optimisation.

**Cache invalidation.** `COPY . .` invalidates its layer whenever *any* file in the context changes. Without `.dockerignore`, editing a README triggers a full dependency reinstall.

Verifying the exclusions worked:

```
devops@testvm:~/day-31/my-website$ docker run --rm my-website:v1 ls -a /usr/share/nginx/html
.
..
50x.html
index.html
```

Only the HTML — no `.git`, no Dockerfile.

---

## Task 6: Build optimisation

### Watching the cache work

```
devops@testvm:~/day-31/all-instructions$ docker build -t flask-demo:v2 .
[+] Building 0.4s (10/10) FINISHED
 => CACHED [2/5] WORKDIR /app                                     0.0s
 => CACHED [3/5] COPY requirements.txt .                          0.0s
 => CACHED [4/5] RUN pip install --no-cache-dir -r requirements…  0.0s
 => CACHED [5/5] COPY app.py .                                    0.0s
```

Every step `CACHED`, 0.4 seconds instead of 12.

**Change only `app.py`:**

```
devops@testvm:~/day-31/all-instructions$ echo "# a comment" >> app.py
devops@testvm:~/day-31/all-instructions$ docker build -t flask-demo:v3 .
[+] Building 1.2s (10/10) FINISHED
 => CACHED [2/5] WORKDIR /app                                     0.0s
 => CACHED [3/5] COPY requirements.txt .                          0.0s
 => CACHED [4/5] RUN pip install --no-cache-dir -r requirements…  0.0s
 => [5/5] COPY app.py .                                           0.1s
```

The pip install stayed cached. Only the final `COPY` re-ran. 1.2 seconds.

### Why order matters

**The bad version:**

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY . .                                        # everything, including app.py
RUN pip install --no-cache-dir -r requirements.txt
CMD ["python", "app.py"]
```

```
devops@testvm:~/day-31/bad-order$ echo "# a comment" >> app.py
devops@testvm:~/day-31/bad-order$ docker build -t bad-order:v2 .
[+] Building 11.8s (9/9) FINISHED
 => [3/4] COPY . .                                                0.1s
 => [4/4] RUN pip install --no-cache-dir -r requirements.txt      9.9s
```

**11.8 seconds instead of 1.2**, for a one-line comment change.

The cache works top-down: Docker reuses a layer only if that instruction and everything before it are unchanged. **Once one layer misses, every layer after it rebuilds.** `COPY . .` includes `app.py`, so changing `app.py` invalidates it — and pip install, which comes after, has to run again even though the dependencies are identical.

Copying `requirements.txt` on its own first means the expensive `RUN pip install` only re-runs when dependencies actually change.

**The principle: order instructions from least to most frequently changing.**

```
FROM              # almost never
RUN apt-get ...   # rarely
COPY package.json # occasionally
RUN npm install   # only when the file above changes
COPY . .          # constantly
CMD               # metadata
```

On a real project this is the difference between a 10-second CI build and a 4-minute one on every commit.

One more thing worth knowing: `RUN apt-get update` in its own layer gets cached and can serve a package index that is months old, so a later `apt-get install` fetches stale versions or fails. Another reason to chain `update` and `install` in one `RUN`.

---

## Files in this folder

| Path | What it is |
|---|---|
| `my-first-image/Dockerfile` | Ubuntu base, installs curl, prints a message |
| `all-instructions/` | Dockerfile using FROM, RUN, COPY, WORKDIR, EXPOSE, CMD, plus a Flask app |
| `cmd-vs-entrypoint/Dockerfile.cmd` | CMD only |
| `cmd-vs-entrypoint/Dockerfile.entrypoint` | ENTRYPOINT only |
| `cmd-vs-entrypoint/Dockerfile.both` | Both together, the common pattern |
| `my-website/` | Static site on nginx:alpine, with `.dockerignore` |

---

## What I learned

**1. Layer order is the single biggest lever on build speed.** Copying `requirements.txt` before the rest of the source turned an 11.8-second rebuild into 1.2 seconds. The rule follows from how the cache works — one miss invalidates everything below — so expensive, rarely-changing steps go first.

**2. CMD is a default, ENTRYPOINT is fixed.** Proved it by running `docker run demo-entry ls /` and getting the literal text `ls /` printed, because the container ran `echo ls /`. Combining them gives a fixed command with overridable arguments, which is what most real images do.

**3. `.dockerignore` is a security control as much as a speed one.** It cut the build context from 47 MB to 4 KB, but the important part is keeping `.env` out of the image — `docker history` will show anyone what a `COPY . .` pulled in.

**Two extras:**

- Use the JSON array form for `CMD` and `ENTRYPOINT`. The shell form makes `/bin/sh` PID 1, which does not forward SIGTERM, so `docker stop` hangs for 10 seconds and then kills the container.
- `EXPOSE` genuinely publishes nothing. Confirmed by running a container with `EXPOSE 5000` and no `-p`, and getting connection refused.
