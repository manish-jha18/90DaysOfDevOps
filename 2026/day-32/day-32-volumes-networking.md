# Day 32 – Docker Volumes and Networking

Two problems today: containers lose their data, and by default they cannot find each other by name.

---

## Task 1: The problem

```
devops@testvm:~$ docker run -d --name pg-test \
    -e POSTGRES_PASSWORD=secret \
    postgres:16-alpine

devops@testvm:~$ docker exec -it pg-test psql -U postgres -c \
    "CREATE TABLE servers (id SERIAL PRIMARY KEY, name TEXT);"
CREATE TABLE

devops@testvm:~$ docker exec -it pg-test psql -U postgres -c \
    "INSERT INTO servers (name) VALUES ('web-01'), ('db-01'), ('cache-01');"
INSERT 0 3

devops@testvm:~$ docker exec -it pg-test psql -U postgres -c "SELECT * FROM servers;"
 id |   name
----+----------
  1 | web-01
  2 | db-01
  3 | cache-01
(3 rows)
```

Now destroy it and start again:

```
devops@testvm:~$ docker stop pg-test && docker rm pg-test
pg-test
pg-test

devops@testvm:~$ docker run -d --name pg-test -e POSTGRES_PASSWORD=secret postgres:16-alpine

devops@testvm:~$ docker exec -it pg-test psql -U postgres -c "SELECT * FROM servers;"
ERROR:  relation "servers" does not exist
LINE 1: SELECT * FROM servers;
                      ^
```

**The data is gone.**

### Why

Every container gets a thin **writable layer** on top of the image's read-only layers. Everything the container writes goes there — and that layer is created with the container and destroyed with it.

```
  ┌─────────────────────────────┐
  │  writable layer (container) │  ← my table lived here, deleted with the container
  ├─────────────────────────────┤
  │  postgres image layers      │  ← read-only, shared
  │  alpine base layer          │
  └─────────────────────────────┘
```

This is deliberate. Containers are meant to be disposable, so anything that must outlive them has to be stored outside them. That is what volumes are for.

Worth noting `docker stop` alone does **not** lose data — the writable layer survives a stop and a start. It is `docker rm` that destroys it. Which is a trap, because it means data survives just long enough to feel safe.

---

## Task 2: Named volumes

```
devops@testvm:~$ docker volume create pgdata
pgdata

devops@testvm:~$ docker volume ls
DRIVER    VOLUME NAME
local     pgdata

devops@testvm:~$ docker run -d --name pg -e POSTGRES_PASSWORD=secret \
    -v pgdata:/var/lib/postgresql/data \
    postgres:16-alpine
```

`/var/lib/postgresql/data` is where Postgres keeps everything. Mounting the volume there means writes land in the volume rather than the writable layer.

```
devops@testvm:~$ docker exec -it pg psql -U postgres -c \
    "CREATE TABLE servers (id SERIAL PRIMARY KEY, name TEXT);"
CREATE TABLE
devops@testvm:~$ docker exec -it pg psql -U postgres -c \
    "INSERT INTO servers (name) VALUES ('web-01'), ('db-01'), ('cache-01');"
INSERT 0 3
```

Destroy the container completely:

```
devops@testvm:~$ docker rm -f pg
pg

devops@testvm:~$ docker ps -a --filter name=pg
CONTAINER ID   IMAGE   COMMAND   CREATED   STATUS   PORTS   NAMES
```

Gone. Now a brand new container with the same volume:

```
devops@testvm:~$ docker run -d --name pg-new -e POSTGRES_PASSWORD=secret \
    -v pgdata:/var/lib/postgresql/data \
    postgres:16-alpine

devops@testvm:~$ docker exec -it pg-new psql -U postgres -c "SELECT * FROM servers;"
 id |   name
----+----------
  1 | web-01
  2 | db-01
  3 | cache-01
(3 rows)
```

**The data survived.** Different container, different ID, same data.

```
devops@testvm:~$ docker volume inspect pgdata
[
    {
        "CreatedAt": "2026-07-11T09:14:22+05:30",
        "Driver": "local",
        "Labels": null,
        "Mountpoint": "/var/lib/docker/volumes/pgdata/_data",
        "Name": "pgdata",
        "Options": null,
        "Scope": "local"
    }
]

devops@testvm:~$ sudo ls /var/lib/docker/volumes/pgdata/_data | head -5
PG_VERSION
base
global
pg_commit_ts
pg_dynshmem
```

The volume is a directory on the host under `/var/lib/docker/volumes/`, managed by Docker. The database files are plainly there.

One thing that caught me out: this also means **upgrading the image reuses the existing data**. Going from `postgres:15` to `postgres:16` with the same volume fails, because the on-disk format differs and Postgres refuses to start. The logs say so clearly, but `docker ps` just shows a container restarting.

---

## Task 3: Bind mounts

```
devops@testvm:~$ mkdir -p ~/day-32/site
devops@testvm:~$ echo "<h1>Version 1</h1>" > ~/day-32/site/index.html

devops@testvm:~$ docker run -d --name web -p 8080:80 \
    -v ~/day-32/site:/usr/share/nginx/html:ro \
    nginx:1.25-alpine

devops@testvm:~$ curl -s localhost:8080
<h1>Version 1</h1>
```

Edit the file on the host, without touching the container:

```
devops@testvm:~$ echo "<h1>Version 2 - edited on the host</h1>" > ~/day-32/site/index.html
devops@testvm:~$ curl -s localhost:8080
<h1>Version 2 - edited on the host</h1>
```

Instant. No rebuild, no restart. This is why bind mounts are the standard development setup — edit code in your editor and the container sees it immediately.

I added `:ro` so the container gets read-only access. Nginx only needs to read, and it means a compromised container cannot rewrite my source files.

### Named volume vs bind mount

| | Named volume | Bind mount |
|---|---|---|
| Where it lives | `/var/lib/docker/volumes/`, Docker-managed | Any path you choose |
| Created by | Docker, automatically if missing | Must already exist |
| Syntax | `-v name:/path` | `-v /host/path:/path` |
| Portable across machines | Yes | No, depends on host layout |
| Performance on Mac/Windows | Good | Noticeably slower |
| Typical use | Database data in production | Source code in development |
| Backup | `docker run --rm -v vol:/data ... tar` | Just copy the folder |

The syntax difference is only whether the first part looks like a path. `-v mydata:/app` is a volume; `-v ./mydata:/app` is a bind mount. Miss the `./` and Docker silently creates a volume named `mydata` instead of mounting your folder — which looks like "my files aren't showing up" with no error.

**The rule I am using:** bind mounts for code in development, named volumes for data that has to persist.

There is one sharp edge with bind mounts:

```
devops@testvm:~$ docker run --rm -v ~/empty-dir:/usr/share/nginx/html nginx:1.25-alpine ls /usr/share/nginx/html
devops@testvm:~$
```

Empty. Mounting a directory **hides whatever the image had there**. The nginx default page is still in the image but shadowed by the mount. This is the usual cause of "my container works until I add a volume".

---

## Task 4: Docker networking basics

```
devops@testvm:~$ docker network ls
NETWORK ID     NAME      DRIVER    SCOPE
8f2c91a4b7e3   bridge    bridge    local
1d4e7a0c3f6b   host      host      local
5c8e1f4a7b0c   none      null      local
```

Three by default:

- **bridge** — the default. Containers get a private IP on `docker0` and reach the outside through NAT.
- **host** — no isolation at all; the container uses the host's network stack directly. `-p` is meaningless. Faster, but the container can bind any host port.
- **none** — no networking whatsoever.

```
devops@testvm:~$ docker network inspect bridge --format '{{json .IPAM.Config}}'
[{"Subnet":"172.17.0.0/16","Gateway":"172.17.0.1"}]
```

`172.17.0.0/16` — a private range from Day 15, and `172.17.0.1` is the gateway, which is the `docker0` interface on the host.

### Two containers on the default bridge

```
devops@testvm:~$ docker run -d --name c1 alpine:3.20 sleep 3600
devops@testvm:~$ docker run -d --name c2 alpine:3.20 sleep 3600

devops@testvm:~$ docker inspect c1 --format '{{.NetworkSettings.IPAddress}}'
172.17.0.2
devops@testvm:~$ docker inspect c2 --format '{{.NetworkSettings.IPAddress}}'
172.17.0.3
```

**By name:**

```
devops@testvm:~$ docker exec c1 ping -c 2 c2
ping: bad address 'c2'
```

**Fails.**

**By IP:**

```
devops@testvm:~$ docker exec c1 ping -c 2 172.17.0.3
PING 172.17.0.3 (172.17.0.3): 56 data bytes
64 bytes from 172.17.0.3: seq=0 ttl=64 time=0.089 ms
64 bytes from 172.17.0.3: seq=1 ttl=64 time=0.104 ms
--- 172.17.0.3 ping statistics ---
2 packets transmitted, 2 packets received, 0% packet loss
```

**Works.** So they are connected, but there is no name resolution.

That is useless in practice, because IPs are assigned in start order and change on every restart. You cannot put `172.17.0.3` in a config file.

---

## Task 5: Custom networks

```
devops@testvm:~$ docker network create my-app-net
2b9d3e8c1f4a7b0c3d6e9f2a5b8c1d4e7f0a3b6c9d2e5f8a1b4c7d0e3f6a9b2c

devops@testvm:~$ docker network ls
NETWORK ID     NAME         DRIVER    SCOPE
8f2c91a4b7e3   bridge       bridge    local
1d4e7a0c3f6b   host         host      local
2b9d3e8c1f4a   my-app-net   bridge    local
5c8e1f4a7b0c   none         null      local

devops@testvm:~$ docker network inspect my-app-net --format '{{json .IPAM.Config}}'
[{"Subnet":"172.18.0.0/16","Gateway":"172.18.0.1"}]
```

A separate subnet, `172.18.0.0/16`.

```
devops@testvm:~$ docker run -d --name app1 --network my-app-net alpine:3.20 sleep 3600
devops@testvm:~$ docker run -d --name app2 --network my-app-net alpine:3.20 sleep 3600

devops@testvm:~$ docker exec app1 ping -c 2 app2
PING app2 (172.18.0.3): 56 data bytes
64 bytes from 172.18.0.3: seq=0 ttl=64 time=0.071 ms
64 bytes from 172.18.0.3: seq=1 ttl=64 time=0.098 ms
--- app2 ping statistics ---
2 packets transmitted, 2 packets received, 0% packet loss
```

**Name resolution works.** `app2` resolved to `172.18.0.3` on its own.

### Why custom networks give name resolution and the default bridge does not

Custom bridge networks get an **embedded DNS server** at `127.0.0.11` inside each container. Docker registers every container's name in it automatically.

```
devops@testvm:~$ docker exec app1 cat /etc/resolv.conf
nameserver 127.0.0.11
options ndots:0

devops@testvm:~$ docker exec app1 nslookup app2
Server:    127.0.0.11
Address 1: 127.0.0.11

Name:      app2
Address 1: 172.18.0.3 app2.my-app-net
```

On the default bridge:

```
devops@testvm:~$ docker exec c1 cat /etc/resolv.conf
nameserver 127.0.0.53
options edns0 trust-ad
search .
```

It uses the host's resolver, which knows nothing about container names. The old way round this was `--link`, now deprecated.

The reason for the difference is largely historical — the default bridge predates Docker's DNS and its behaviour was kept for compatibility. The practical takeaway is simple: **always create a custom network.** Docker Compose does it for you automatically, which is why service names just work there.

Custom networks also isolate. Containers on `my-app-net` cannot reach containers on the default bridge at all, so you can separate a frontend network from a backend one.

---

## Task 6: Putting it together

A database with a volume and an app container, on a shared network.

```
devops@testvm:~$ docker network create app-tier
devops@testvm:~$ docker volume create mysql-data

devops@testvm:~$ docker run -d --name mysql-db \
    --network app-tier \
    -v mysql-data:/var/lib/mysql \
    -e MYSQL_ROOT_PASSWORD=rootpass \
    -e MYSQL_DATABASE=appdb \
    -e MYSQL_USER=appuser \
    -e MYSQL_PASSWORD=apppass \
    mysql:8.0
```

MySQL takes a while to initialise, so it is worth waiting for it rather than assuming:

```
devops@testvm:~$ docker logs mysql-db 2>&1 | tail -2
2026-07-11T10:14:38.117204Z 0 [System] [MY-010931] [Server] /usr/sbin/mysqld: ready for connections.
```

```
devops@testvm:~$ docker run -d --name app --network app-tier alpine:3.20 sleep 3600

devops@testvm:~$ docker exec app ping -c 2 mysql-db
PING mysql-db (172.19.0.2): 56 data bytes
64 bytes from 172.19.0.2: seq=0 ttl=64 time=0.093 ms
--- mysql-db ping statistics ---
2 packets transmitted, 2 packets received, 0% packet loss
```

Ping only proves the name resolves. Better to check the port is actually accepting connections:

```
devops@testvm:~$ docker exec app sh -c "nc -zv mysql-db 3306"
mysql-db (172.19.0.2:3306) open
```

And a real query:

```
devops@testvm:~$ docker run --rm --network app-tier mysql:8.0 \
    mysql -h mysql-db -u appuser -papppass -e "SHOW DATABASES;" 2>/dev/null
+--------------------+
| Database           |
+--------------------+
| appdb              |
| information_schema |
| performance_schema |
+--------------------+
```

**Connected by container name**, from a throwaway container on the same network.

Confirming persistence:

```
devops@testvm:~$ docker run --rm --network app-tier mysql:8.0 \
    mysql -h mysql-db -u appuser -papppass appdb \
    -e "CREATE TABLE t (id INT); INSERT INTO t VALUES (42);" 2>/dev/null

devops@testvm:~$ docker rm -f mysql-db
devops@testvm:~$ docker run -d --name mysql-db --network app-tier \
    -v mysql-data:/var/lib/mysql -e MYSQL_ROOT_PASSWORD=rootpass mysql:8.0

devops@testvm:~$ sleep 20 && docker run --rm --network app-tier mysql:8.0 \
    mysql -h mysql-db -u appuser -papppass appdb -e "SELECT * FROM t;" 2>/dev/null
+------+
| id   |
+------+
|   42 |
+------+
```

Destroyed the database container, created a new one, and the row is still there.

This whole exercise — network, volume, two containers, environment variables, waiting for the database — is exactly what Docker Compose collapses into one YAML file. Which is Day 33.

**Cleanup:**

```
devops@testvm:~$ docker rm -f mysql-db app c1 c2 app1 app2 web pg-new
devops@testvm:~$ docker network rm app-tier my-app-net
devops@testvm:~$ docker volume rm mysql-data pgdata
```

---

## What I learned

**1. `docker stop` keeps your data; `docker rm` destroys it.** The writable layer survives a stop and start, which makes containers feel more durable than they are. The data was only really safe once it lived in a volume.

**2. Custom networks give DNS, the default bridge does not.** Containers on the default bridge can reach each other by IP but not by name — and since IPs change on restart, that is unusable. The fix is one flag, `--network`, and it is why Compose service names resolve automatically.

**3. Mounting over a directory hides what the image put there.** Mounting an empty folder onto nginx's web root produced an empty directory, not a merged view. That is the usual explanation for "it worked until I added a volume".

**Two extras:**

- `-v mydata:/app` and `-v ./mydata:/app` are completely different things. Without the `./`, Docker creates a named volume instead of mounting your folder, silently.
- Reusing a database volume across a major version upgrade fails, because the on-disk format changed. The container just restart-loops and the reason is only in the logs.
