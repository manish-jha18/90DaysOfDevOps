"""Day 34 - small Flask app that talks to Postgres and Redis."""
import os

import psycopg2
import redis
from flask import Flask, jsonify

app = Flask(__name__)

DB_HOST = os.environ.get("DB_HOST", "db")
DB_NAME = os.environ.get("POSTGRES_DB", "appdb")
DB_USER = os.environ.get("POSTGRES_USER", "appuser")
DB_PASS = os.environ.get("POSTGRES_PASSWORD", "")
REDIS_HOST = os.environ.get("REDIS_HOST", "cache")

cache = redis.Redis(host=REDIS_HOST, port=6379, decode_responses=True)


def db_connect():
    return psycopg2.connect(
        host=DB_HOST, dbname=DB_NAME, user=DB_USER, password=DB_PASS
    )


@app.route("/")
def home():
    # every hit increments a counter in redis - proves the cache is reachable
    hits = cache.incr("hits")
    return jsonify(message="Day 34 app stack is up", visits=hits)


@app.route("/health")
def health():
    """Used by the compose healthcheck."""
    return jsonify(status="ok"), 200


@app.route("/db")
def db_check():
    """Proves the app can reach Postgres by service name."""
    try:
        conn = db_connect()
        with conn.cursor() as cur:
            cur.execute("SELECT version();")
            version = cur.fetchone()[0]
        conn.close()
        return jsonify(database="connected", version=version.split(",")[0])
    except Exception as exc:
        return jsonify(database="unreachable", error=str(exc)), 503


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
