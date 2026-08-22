# Day 33 – Docker Compose: Multi-Container Basics

Day 32 ended with a network, a volume, two containers and a pile of flags. All of that becomes one YAML file today.

---

## Task 1: Install and verify

```
devops@testvm:~$ docker compose version
Docker Compose version v2.27.1
```

`docker compose` (v2, a plugin, written in Go) has replaced `docker-compose` (v1, a separate Python program). The hyphen is the giveaway — v1 reached end of life in July 2023. Old tutorials still show it, and on some systems `docker-compose` is aliased to v2 anyway, but the space is the current form.

```
devops@testvm:~$ docker compose --help | head -6
Usage:  docker compose [OPTIONS] COMMAND

Define and run multi-container applications with Docker

Commands:
  build       Build or rebuild services
```

---

## Task 2: First compose file

**`compose-basics/docker-compose.yml`**

```yaml
services:
  web:
    image: nginx:1.25-alpine
    container_name: compose-nginx
    ports:
      - "8080:80"
```

```
devops@testvm:~/day-33/compose-basics$ docker compose up
[+] Running 2/2
 ✔ Network compose-basics_default  Created                        0.1s
 ✔ Container compose-nginx         Created                        0.3s
Attaching to compose-nginx
compose-nginx  | /docker-entrypoint.sh: Configuration complete; ready for start up
compose-nginx  | 2026/07/11 14:02:18 [notice] 1#1: start worker processes
```

```
devops@testvm:~$ curl -I localhost:8080
HTTP/1.1 200 OK
Server: nginx/1.25.3
```

Note the first line of output: **`Network compose-basics_default Created`**. Compose made a custom network without being asked, named after the directory. That is the Day 32 lesson applied automatically — custom network, so DNS between services works.

```
devops@testvm:~/day-33/compose-basics$ docker compose down
[+] Running 2/2
 ✔ Container compose-nginx         Removed                        0.4s
 ✔ Network compose-basics_default  Removed                        0.2s
```

`down` removes the containers **and** the network. Without Compose that would be several `docker rm` commands plus a `docker network rm`.

No `version:` key at the top. It was required in older Compose files, is now obsolete, and produces a warning if you include it.

---

## Task 3: WordPress and MySQL

**`wordpress/docker-compose.yml`**

```yaml
services:
  db:
    image: mysql:8.0
    container_name: wp-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - db_data:/var/lib/mysql

  wordpress:
    image: wordpress:6.5-apache
    container_name: wp-app
    restart: unless-stopped
    depends_on:
      - db
    ports:
      - "${WORDPRESS_PORT}:80"
    environment:
      WORDPRESS_DB_HOST: db:3306
      WORDPRESS_DB_NAME: ${MYSQL_DATABASE}
      WORDPRESS_DB_USER: ${MYSQL_USER}
      WORDPRESS_DB_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - wp_data:/var/www/html

volumes:
  db_data:
  wp_data:
```

The line that matters most is `WORDPRESS_DB_HOST: db:3306`. **`db` is the service name**, and Compose's DNS resolves it to the database container. No IP addresses, no `--link`, no ordering tricks. This is exactly what failed on the default bridge in Day 32.

```
devops@testvm:~/day-33/wordpress$ cp .env.example .env
devops@testvm:~/day-33/wordpress$ docker compose up -d
[+] Running 5/5
 ✔ Network wordpress_default  Created                             0.1s
 ✔ Volume "wordpress_db_data" Created                             0.0s
 ✔ Volume "wordpress_wp_data" Created                             0.0s
 ✔ Container wp-db            Started                             1.2s
 ✔ Container wp-app           Started                             1.4s
```

One command created a network, two volumes and two containers, in dependency order.

```
devops@testvm:~/day-33/wordpress$ docker compose ps
NAME     IMAGE                  COMMAND                  SERVICE     STATUS         PORTS
wp-app   wordpress:6.5-apache   "docker-entrypoint.s…"   wordpress   Up 2 minutes   0.0.0.0:8000->80/tcp
wp-db    mysql:8.0              "docker-entrypoint.s…"   db          Up 2 minutes   3306/tcp, 33060/tcp

devops@testvm:~$ curl -sI localhost:8000 | head -1
HTTP/1.1 302 Found
```

A 302 redirect to the installer, which is right for a fresh WordPress. Completed the setup in the browser and published a test post.

### Does the data survive?

```
devops@testvm:~/day-33/wordpress$ docker compose down
[+] Running 3/3
 ✔ Container wp-app           Removed                             1.1s
 ✔ Container wp-db            Removed                             2.3s
 ✔ Network wordpress_default  Removed                             0.2s

devops@testvm:~/day-33/wordpress$ docker volume ls
DRIVER    VOLUME NAME
local     wordpress_db_data
local     wordpress_wp_data
```

Containers and network gone, **volumes still there**. `down` deliberately leaves them.

```
devops@testvm:~/day-33/wordpress$ docker compose up -d
devops@testvm:~$ curl -s localhost:8000 | grep -o "<title>[^<]*</title>"
<title>Day 33 Test Site &#8211; My Docker Compose site</title>
```

Site name and post survived. Two named volumes doing the work: `db_data` for the database, `wp_data` for uploads and plugins.

**The one to be careful with:**

```
devops@testvm:~/day-33/wordpress$ docker compose down -v
[+] Running 5/5
 ✔ Container wp-app             Removed
 ✔ Container wp-db              Removed
 ✔ Volume wordpress_wp_data     Removed
 ✔ Volume wordpress_db_data     Removed
 ✔ Network wordpress_default    Removed
```

`-v` removes the volumes too. That is the whole database gone. Useful for a clean slate, catastrophic by accident.

Volumes get the project name as a prefix — `wordpress_db_data`, from the directory. So two projects can both define `db_data` without colliding.

---

## Task 4: Compose commands

```
devops@testvm:~/day-33/wordpress$ docker compose up -d
[+] Running 2/2
 ✔ Container wp-db   Started
 ✔ Container wp-app  Started
```

```
devops@testvm:~/day-33/wordpress$ docker compose ps
NAME     IMAGE                  SERVICE     STATUS         PORTS
wp-app   wordpress:6.5-apache   wordpress   Up 5 seconds   0.0.0.0:8000->80/tcp
wp-db    mysql:8.0              db          Up 6 seconds   3306/tcp, 33060/tcp

devops@testvm:~/day-33/wordpress$ docker compose ps -a      # includes stopped
```

```
devops@testvm:~/day-33/wordpress$ docker compose logs --tail 3
wp-db   | 2026-07-11T14:22:41.882Z 0 [System] [MY-010931] ready for connections.
wp-app  | AH00558: apache2: Could not reliably determine the server's FQDN
wp-app  | [Sat Jul 11 14:22:43 2026] [mpm_prefork:notice] Apache/2.4.59 configured
```

Interleaved and colour-coded by service. Genuinely useful when tracking a request across two containers.

```
devops@testvm:~/day-33/wordpress$ docker compose logs db --tail 2
wp-db  | 2026-07-11T14:22:41.882Z 0 [System] [MY-010931] ready for connections.

devops@testvm:~/day-33/wordpress$ docker compose logs -f wordpress      # follow one service
```

```
devops@testvm:~/day-33/wordpress$ docker compose stop
[+] Running 2/2
 ✔ Container wp-app  Stopped
 ✔ Container wp-db   Stopped

devops@testvm:~/day-33/wordpress$ docker compose ps -a
NAME     IMAGE                  SERVICE     STATUS
wp-app   wordpress:6.5-apache   wordpress   Exited (0) 8 seconds ago
wp-db    mysql:8.0              db          Exited (0) 9 seconds ago

devops@testvm:~/day-33/wordpress$ docker compose start
```

**`stop` vs `down`:** `stop` halts the containers but leaves them, so `start` resumes quickly. `down` removes containers and the network entirely.

```
devops@testvm:~/day-33/wordpress$ docker compose up -d --build      # rebuild changed images
devops@testvm:~/day-33/wordpress$ docker compose build --no-cache   # force a full rebuild
```

Nothing to build here since both services use pre-built images — that comes in on Day 34.

### Reference

| Command | Does |
|---|---|
| `docker compose up` | Create and start, attached to the logs |
| `docker compose up -d` | Same, in the background |
| `docker compose up -d --build` | Rebuild images first |
| `docker compose ps` | Running services |
| `docker compose logs -f [service]` | Follow logs, optionally for one service |
| `docker compose stop` / `start` | Halt and resume without removing |
| `docker compose restart` | Restart in place |
| `docker compose down` | Remove containers and network, keep volumes |
| `docker compose down -v` | Also remove volumes |
| `docker compose exec <svc> sh` | Shell into a running service |
| `docker compose config` | Show the fully resolved file with variables filled in |
| `docker compose top` | Processes inside each service |

`docker compose exec` takes the **service** name, not the container name, so it works regardless of what the container ended up being called.

---

## Task 5: Environment variables

Two ways to set them, and the difference matters.

**Directly in the file** — fine for anything that is not a secret:

```yaml
environment:
  WORDPRESS_DB_HOST: db:3306
  WORDPRESS_DEBUG: 1
```

**From a `.env` file** — for anything that is:

**`.env.example`** (committed):

```
MYSQL_ROOT_PASSWORD=change-me-root
MYSQL_DATABASE=wordpress
MYSQL_USER=wpuser
MYSQL_PASSWORD=change-me-user
WORDPRESS_PORT=8000
```

The real `.env` is a copy with real values, and it is **gitignored**. There is a `.gitignore` in this folder containing `.env` for exactly that reason. This is the Day 27 lesson — a committed credential stays in the history even after you delete the file.

```
devops@testvm:~/day-33/wordpress$ cp .env.example .env
devops@testvm:~/day-33/wordpress$ cat .gitignore
.env
```

Compose reads `.env` from the project directory automatically. No flag needed.

### Verifying the substitution

`docker compose config` renders the file with every variable resolved, which is the fastest way to check:

```
devops@testvm:~/day-33/wordpress$ docker compose config
name: wordpress
services:
  db:
    container_name: wp-db
    environment:
      MYSQL_DATABASE: wordpress
      MYSQL_PASSWORD: change-me-user
      MYSQL_ROOT_PASSWORD: change-me-root
      MYSQL_USER: wpuser
    image: mysql:8.0
    networks:
      default: null
    restart: unless-stopped
    volumes:
      - type: volume
        source: db_data
        target: /var/lib/mysql
  wordpress:
    container_name: wp-app
    depends_on:
      db:
        condition: service_started
        required: true
    environment:
      WORDPRESS_DB_HOST: db:3306
      WORDPRESS_DB_NAME: wordpress
      WORDPRESS_DB_PASSWORD: change-me-user
      WORDPRESS_DB_USER: wpuser
    image: wordpress:6.5-apache
```

Every `${...}` filled in. If a variable is missing you get a warning and an empty string rather than an error:

```
devops@testvm:~/day-33/wordpress$ mv .env .env.bak
devops@testvm:~/day-33/wordpress$ docker compose config -q
WARN[0000] The "MYSQL_ROOT_PASSWORD" variable is not set. Defaulting to a blank string.
WARN[0000] The "MYSQL_DATABASE" variable is not set. Defaulting to a blank string.
```

**Blank, not an error.** MySQL would then start with an empty root password. `${MYSQL_PASSWORD:?password required}` makes it fail loudly instead, which is what I would use for anything that must be set.

Confirming inside the container:

```
devops@testvm:~/day-33/wordpress$ docker compose exec db printenv MYSQL_DATABASE
wordpress
devops@testvm:~/day-33/wordpress$ docker compose exec wordpress printenv WORDPRESS_DB_HOST
db:3306
```

### `.env` vs `env_file`

Confusing, because they sound the same:

- **`.env`** — variables for **Compose itself**, substituted into the YAML. Used for `${VAR}` in the file.
- **`env_file: .env.app`** — a file whose variables are injected into the **container's** environment, and never seen by Compose.

The first parameterises the compose file; the second configures the app.

---

## Files in this folder

| Path | What it is |
|---|---|
| `compose-basics/docker-compose.yml` | Single nginx service with a port mapping |
| `wordpress/docker-compose.yml` | WordPress + MySQL with named volumes and env vars |
| `wordpress/.env.example` | Template — `cp .env.example .env` before running |
| `wordpress/.gitignore` | Keeps the real `.env` out of the repository |

---

## What I learned

**1. Compose creates a custom network automatically, which is why service names resolve.** Day 32 showed that name resolution fails on the default bridge and works on a custom one. Compose does the right thing without being told, and `db:3306` in a config file just works.

**2. `down` keeps volumes, `down -v` destroys them.** That single flag is the difference between restarting a project and losing the database. Volumes are also prefixed with the project name, so two projects can define `db_data` without clashing.

**3. A missing variable becomes an empty string, silently.** Removing `.env` gave warnings, not an error, and MySQL would have started with a blank root password. `${VAR:?message}` turns that into a hard failure, which is what secrets deserve.

**Two extras:**

- `docker compose config` renders the file with everything substituted. Best way to check a compose file before running it, and it works without the daemon.
- `docker compose exec` takes the service name, not the container name — so it keeps working even if `container_name` changes.
