# URL Shortener

A small URL shortener built to practise Dockerising a real application end to end. Flask, Postgres, Docker Compose.

Paste a long URL, get a short code back. Following the short link redirects and counts the click.

## Stack

| Part | Choice |
|---|---|
| App | Python 3.12 + Flask, served by gunicorn |
| Database | PostgreSQL 16 (alpine) |
| Orchestration | Docker Compose |
| Image | Multi-stage build, non-root, ~150 MB |

## Running it

You need Docker and Docker Compose. Nothing else — no Python on the host.

```bash
git clone https://github.com/manish-jha18/90DaysOfDevOps.git
cd 90DaysOfDevOps/2026/day-36/url-shortener

cp .env.example .env
# edit .env and set a real POSTGRES_PASSWORD

docker compose up -d --build
```

Then open http://localhost:8000

To use the published image instead of building locally, drop the `build:` line from `docker-compose.yml` — the `image:` key already points at Docker Hub.

```bash
docker pull manishjha18/url-shortener:v1.0.0
```

## Environment variables

All are read from `.env`. There is no default password — Compose refuses to start without one.

| Variable | Required | Default | What it is |
|---|---|---|---|
| `POSTGRES_DB` | yes | — | Database name |
| `POSTGRES_USER` | yes | — | Database user |
| `POSTGRES_PASSWORD` | yes | — | Database password |
| `WEB_PORT` | no | `8000` | Host port to publish the app on |

`.env` is gitignored. Only `.env.example` is committed.

## Endpoints

| Route | Method | Does |
|---|---|---|
| `/` | GET | Form plus the 10 most recent links |
| `/` | POST | Create a short link |
| `/<code>` | GET | Redirect to the target, increment the click count |
| `/health` | GET | Returns 200 if the database is reachable, 503 if not |

## Useful commands

```bash
docker compose ps                      # what is running and healthy
docker compose logs -f web             # follow the app logs
docker compose exec db psql -U urluser urls   # open a psql shell
docker compose down                    # stop, keep the data
docker compose down -v                 # stop and delete the database
```

## Notes

- The `links` table is created on first start; no migration step is needed.
- The app waits for Postgres to pass its healthcheck before starting, so a cold `up` does not race.
- Short codes are 6 random alphanumeric characters. There is no collision check — fine for a demo, not for production.
