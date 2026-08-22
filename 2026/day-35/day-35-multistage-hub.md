# Day 35 – Multi-Stage Builds and Docker Hub

A tiny Go HTTP server, built two ways, to see what multi-stage actually saves. Go makes the point sharply because the compiler is large and the output is a single static binary.

---

## Task 1: The problem with large images

**`go-app/main.go`** — an HTTP server with `/` and `/health`. About 25 lines.

**`go-app/Dockerfile.single`**

```dockerfile
FROM golang:1.22

WORKDIR /src
COPY go.mod .
COPY main.go .

RUN go build -o /src/hello main.go

EXPOSE 8080
CMD ["/src/hello"]
```

Straightforward and completely wrong for production.

```
devops@testvm:~/day-35/go-app$ docker build -f Dockerfile.single -t hello:single .
[+] Building 48.3s (10/10) FINISHED

devops@testvm:~/day-35/go-app$ docker images hello:single
REPOSITORY   TAG      IMAGE ID       CREATED          SIZE
hello        single   4c8f2a91b7d3   30 seconds ago   848MB
```

**848 MB** for a program that prints a line of text.

The binary itself:

```
devops@testvm:~/day-35/go-app$ docker run --rm hello:single ls -lh /src/hello
-rwxr-xr-x 1 root root 7.1M Jul 12 11:02 /src/hello
```

7.1 MB of binary inside an 848 MB image. Everything else is the Go toolchain — compiler, linker, standard library source, git, build cache — all needed to *build* and none of it needed to *run*.

Three reasons that is bad beyond the number:

- **Slow.** Every pull moves 848 MB. On a Kubernetes node scaling up, that is the delay before a pod can serve traffic.
- **Expensive.** Registry storage and egress, multiplied by every tag you keep.
- **Insecure.** More packages means more CVEs. A compiler and a shell in a production image are useful to an attacker who gets code execution.

---

## Task 2: Multi-stage build

**`go-app/Dockerfile`**

```dockerfile
# ---------- stage 1: build ----------
FROM golang:1.22-alpine AS builder

WORKDIR /src
COPY go.mod .
COPY main.go .

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /src/hello main.go

# ---------- stage 2: runtime ----------
FROM alpine:3.20

RUN apk add --no-cache ca-certificates
RUN adduser -D -u 10001 appuser

COPY --from=builder /src/hello /usr/local/bin/hello

USER appuser
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/hello"]
```

```
devops@testvm:~/day-35/go-app$ docker build -t hello:multi .
[+] Building 39.1s (14/14) FINISHED

devops@testvm:~/day-35/go-app$ docker images | grep hello
hello        multi     9e1c4a7b3f80   20 seconds ago   13.4MB
hello        single    4c8f2a91b7d3   6 minutes ago    848MB
```

**848 MB → 13.4 MB. A 63× reduction.**

```
devops@testvm:~/day-35/go-app$ docker run -d -p 8080:8080 --name hello hello:multi
devops@testvm:~/day-35/go-app$ curl localhost:8080
Hello from a multi-stage build. Served by 3f8a2c91d4e7
```

Identical behaviour.

### Why is it so much smaller?

**Only the final `FROM` becomes the image.** Earlier stages are built, used, and thrown away. The Go compiler ran in stage 1 and never appears in the result.

`COPY --from=builder` is the bridge — it reaches into a previous stage and takes specific files. Here, one 7.1 MB binary. The other 840 MB stays behind.

The rough breakdown:

```
alpine:3.20 base           ~7.8 MB
ca-certificates            ~0.5 MB
the hello binary           ~5.1 MB
────────────────────────────────
                          ~13.4 MB
```

Three flags doing work in the build:

- **`CGO_ENABLED=0`** — statically links everything, so the binary has no libc dependency. This is what allows an Alpine (musl) runtime for a binary compiled against a glibc image, and what makes `scratch` possible at all. Without it, the binary compiles fine and then fails at runtime with "no such file or directory", which is a genuinely confusing error for a file that clearly exists — the missing file is the dynamic linker.
- **`-ldflags="-s -w"`** — strips the symbol table and DWARF debug info. Took the binary from 7.1 MB to 5.1 MB. Do not use it if you need readable stack traces.
- **`golang:1.22-alpine` as the builder** — a smaller builder does not affect the final image size at all, but it makes the build faster to pull on a cold CI runner.

### Taking it further: scratch

**`go-app/Dockerfile.scratch`**

```dockerfile
FROM golang:1.22-alpine AS builder
WORKDIR /src
COPY go.mod .
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /src/hello main.go

FROM scratch
COPY --from=builder /src/hello /hello
USER 10001
EXPOSE 8080
ENTRYPOINT ["/hello"]
```

```
devops@testvm:~/day-35/go-app$ docker build -f Dockerfile.scratch -t hello:scratch .
devops@testvm:~/day-35/go-app$ docker images | grep hello
hello        scratch   2d5f8a1b4c70   10 seconds ago   5.14MB
hello        multi     9e1c4a7b3f80   4 minutes ago    13.4MB
hello        single    4c8f2a91b7d3   12 minutes ago   848MB
```

**5.14 MB** — the binary and nothing else. `scratch` is a completely empty image.

```
devops@testvm:~/day-35/go-app$ docker run --rm hello:scratch sh
docker: Error response from daemon: failed to create task for container:
exec: "sh": executable file not found in $PATH
```

No shell. No `ls`, no package manager, no `/etc/passwd`. That is the security benefit — an attacker with code execution has no tools — and the operational cost, because you cannot `docker exec` in to debug. `USER 10001` has to be a numeric UID since there is no user database to look a name up in.

**Where each fits:**

| Base | Size | Use when |
|---|---|---|
| `scratch` | 5.1 MB | Static binary, security matters more than debuggability |
| `alpine` | 13.4 MB | Want a shell for debugging. My default |
| `distroless` | ~20 MB | Google's middle ground: no shell, but certs and timezone data |
| Full `golang` | 848 MB | Never, for runtime |

I would ship the Alpine version. The 8 MB extra buys `docker exec` at 3 a.m., which is worth it.

---

## Task 3: Push to Docker Hub

```
devops@testvm:~$ docker login
Username: manishjha18
Password:
WARNING! Your password will be stored unencrypted in /home/devops/.docker/config.json.
Configure a credential helper to remove this warning. See
https://docs.docker.com/engine/reference/commandline/login/#credential-stores

Login Succeeded
```

That warning is worth acting on rather than ignoring:

```
devops@testvm:~$ cat ~/.docker/config.json
{
	"auths": {
		"https://index.docker.io/v1/": {
			"auth": "bWFuaXNoamhhMTg6ZGNrcl9wYXRfeHh4eA=="
		}
	}
}

devops@testvm:~$ echo "bWFuaXNoamhhMTg6ZGNrcl9wYXRfeHh4eA==" | base64 -d
manishjha18:dckr_pat_xxxx
```

Base64, not encryption. Anyone who can read that file has the credential. Two mitigations: install a credential helper (`docker-credential-pass` or the system keychain), and use a **Docker Hub access token** rather than the account password, so it can be revoked without changing the password.

```
devops@testvm:~$ docker tag hello:multi manishjha18/hello-go:v1.0.0
devops@testvm:~$ docker tag hello:multi manishjha18/hello-go:latest

devops@testvm:~$ docker images | grep hello-go
manishjha18/hello-go   latest   9e1c4a7b3f80   8 minutes ago   13.4MB
manishjha18/hello-go   v1.0.0   9e1c4a7b3f80   8 minutes ago   13.4MB
```

Same IMAGE ID for both — a tag is a label pointing at an image, not a copy. Two tags, one 13.4 MB image on disk.

```
devops@testvm:~$ docker push manishjha18/hello-go:v1.0.0
The push refers to repository [docker.io/manishjha18/hello-go]
5f70bf18a086: Pushed
a1c8e42b91d7: Pushed
c9f2d5a83e14: Pushed
v1.0.0: digest: sha256:8a3f91c4d2e58b1a6c9e0d4a1f27b8a35c6e9f2d1b4a7c0e3f6a9d2b5c8e1f4a size: 946

devops@testvm:~$ docker push manishjha18/hello-go:latest
5f70bf18a086: Layer already exists
a1c8e42b91d7: Layer already exists
c9f2d5a83e14: Layer already exists
latest: digest: sha256:8a3f91c4d2e58b1a6c9e0d4a1f27b8a35c6e9f2d1b4a7c0e3f6a9d2b5c8e1f4a size: 946
```

`Layer already exists` on the second push — same layers, so only the tag reference was created. Layer deduplication from Day 30, working at the registry level.

**Verify by removing everything locally and pulling fresh:**

```
devops@testvm:~$ docker rmi hello:multi manishjha18/hello-go:v1.0.0 manishjha18/hello-go:latest
devops@testvm:~$ docker images | grep hello-go
devops@testvm:~$

devops@testvm:~$ docker run -d -p 8080:8080 --name from-hub manishjha18/hello-go:v1.0.0
Unable to find image 'manishjha18/hello-go:v1.0.0' locally
v1.0.0: Pulling from manishjha18/hello-go
c6a83fedfae6: Pull complete
Status: Downloaded newer image for manishjha18/hello-go:v1.0.0

devops@testvm:~$ curl localhost:8080
Hello from a multi-stage build. Served by 7b3f809e1c4a
```

Pulled from Docker Hub on a clean machine and ran. That round trip is the actual test.

---

## Task 4: The Docker Hub repository

Added a description on the repository page, plus a short overview covering what it does, how to run it and which tags exist. Worth doing — an image with no description is one nobody will trust.

```
devops@testvm:~$ docker push manishjha18/hello-go:v1.1.0
```

The Tags tab now shows `latest`, `v1.0.0` and `v1.1.0` with sizes and push dates.

### `latest` vs a specific tag

```
devops@testvm:~$ docker pull manishjha18/hello-go:v1.0.0
v1.0.0: Pulling from manishjha18/hello-go
Digest: sha256:8a3f91c4d2e58b1a6c9e0d4a1f27b8a35c6e9f2d1b4a7c0e3f6a9d2b5c8e1f4a

devops@testvm:~$ docker pull manishjha18/hello-go:latest
latest: Pulling from manishjha18/hello-go
Digest: sha256:1f4a7b0c3d6e9f2a5b8c1d4e7f0a3b6c9d2e5f8a1b4c7d0e3f6a9b2c5d8e1f4a
```

**Different digests.** `latest` now points at v1.1.0 because that was the most recent push.

**`latest` is not a version.** It is a default tag name with no special meaning — it points at whatever was pushed to it last, which may or may not be the newest release. Nothing enforces anything.

Which is why `FROM node:latest` in a Dockerfile is a bug waiting to happen: the build is reproducible until the day it silently is not. Every base image in this repository is pinned — `golang:1.22-alpine`, `alpine:3.20`, `postgres:16-alpine`.

For genuine immutability you can pin the digest:

```dockerfile
FROM alpine@sha256:1f4a7b0c3d6e9f2a5b8c1d4e7f0a3b6c9d2e5f8a1b4c7d0e3f6a9b2c5d8e1f4a
```

Unambiguous, unmovable, and unreadable — usually reserved for base images in a security-sensitive pipeline.

---

## Task 5: Image best practices

### 1. Minimal base image

```
devops@testvm:~$ docker images | grep -E "^(golang|alpine|ubuntu|debian)"
golang       1.22          f2a5b8c1d4e7   2 weeks ago   836MB
golang       1.22-alpine   8c1d4e7f0a3b   2 weeks ago   248MB
debian       12-slim       b6c9d2e5f8a1   3 weeks ago   74.8MB
ubuntu       22.04         35a88802559d   3 weeks ago   78.1MB
alpine       3.20          a606584aa9aa   5 weeks ago    7.8MB
```

Applied throughout: `alpine:3.20` for the runtime, `golang:1.22-alpine` for the builder.

### 2. Do not run as root

```dockerfile
RUN adduser -D -u 10001 appuser
USER appuser
```

```
devops@testvm:~$ docker run --rm hello:multi id
uid=10001(appuser) gid=10001(appuser) groups=10001(appuser)

devops@testvm:~$ docker run --rm hello:single id
uid=0(root) gid=0(root) groups=0(root)
```

**This is the most important item on the list.** By default a container runs as root — and it is root on the *host* kernel, mapped into the container. Combined with a mounted volume or a kernel escape, that is a direct path to compromising the host. Day 29's isolation point again: the boundary is the kernel, and it is thinner than a VM's.

Two practical notes: `USER` must come **after** any `RUN` that needs to install packages, and a non-root user cannot bind ports below 1024, which is why the app listens on 8080 rather than 80.

### 3. Combine RUN commands

```dockerfile
# bad - three layers, and the cleanup does not shrink anything
RUN apk add --no-cache ca-certificates
RUN apk add --no-cache tzdata
RUN adduser -D appuser

# better - one layer
RUN apk add --no-cache ca-certificates tzdata && \
    adduser -D -u 10001 appuser
```

Day 30's lesson: layers are additive, so a `rm` in a later layer removes nothing from the image. On Alpine, `--no-cache` avoids needing the cleanup at all; on Debian it is `rm -rf /var/lib/apt/lists/*` in the same `RUN`.

Worth not overdoing — merging everything into one giant `RUN` destroys build caching. Group by how often things change.

### 4. Specific tags, never `latest`

```dockerfile
FROM golang:1.22-alpine AS builder    # not golang:latest
FROM alpine:3.20                      # not alpine:latest
```

A build that worked yesterday and fails today with no code change is almost always an unpinned base image.

### Before and after

| Version | Size | Runs as | Base |
|---|---|---|---|
| `hello:single` | 848 MB | root | `golang:1.22` |
| `hello:multi` | 13.4 MB | uid 10001 | `alpine:3.20` |
| `hello:scratch` | 5.14 MB | uid 10001 | `scratch` |

**98.4% smaller and no longer root**, for about fifteen lines of Dockerfile.

---

## Files in this folder

| Path | What it is |
|---|---|
| `go-app/main.go` | Small HTTP server with `/` and `/health` |
| `go-app/go.mod` | Module definition |
| `go-app/Dockerfile.single` | Single stage — 848 MB, the problem |
| `go-app/Dockerfile` | Multi-stage on alpine — 13.4 MB, non-root |
| `go-app/Dockerfile.scratch` | Multi-stage on scratch — 5.14 MB |
| `go-app/.dockerignore` | Keeps `.git` and Dockerfiles out of the context |

---

## What I learned

**1. Only the last `FROM` becomes the image.** Earlier stages are scaffolding and are discarded. `COPY --from=builder` reaches back for the one artefact that matters. Once that clicked, 848 MB → 13.4 MB stopped being surprising — the build tools were never needed at runtime.

**2. `CGO_ENABLED=0` is what makes the tiny runtime possible.** It produces a statically linked binary with no libc dependency, which is why a glibc-built binary can run on musl-based Alpine or on `scratch`. Without it the container fails with "no such file or directory" for a file that is plainly there — the missing thing is the dynamic linker, which is a horrible error to debug cold.

**3. `latest` is a name, not a version.** It points at whatever was pushed most recently. `docker pull` proved it — `v1.0.0` and `latest` returned different digests. That is why every base image here is pinned.

**Two extras:**

- `docker login` stores credentials base64-encoded, not encrypted. Use an access token rather than your password, and a credential helper if the machine is shared.
- Running as non-root is the highest-value line in the whole Dockerfile. Containers default to root, and it is root on the host kernel.
