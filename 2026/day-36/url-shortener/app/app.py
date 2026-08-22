"""A small URL shortener. Flask + Postgres, deliberately simple."""
import os
import string
import random

import psycopg2
from psycopg2.extras import RealDictCursor
from flask import Flask, request, redirect, render_template, jsonify

app = Flask(__name__)

DB_CONFIG = {
    "host": os.environ.get("DB_HOST", "db"),
    "dbname": os.environ.get("POSTGRES_DB", "urls"),
    "user": os.environ.get("POSTGRES_USER", "urluser"),
    "password": os.environ.get("POSTGRES_PASSWORD", ""),
}
ALPHABET = string.ascii_letters + string.digits


def get_conn():
    return psycopg2.connect(**DB_CONFIG)


def init_db():
    """Create the table on first start. Safe to run repeatedly."""
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS links (
                code       TEXT PRIMARY KEY,
                target     TEXT NOT NULL,
                clicks     INTEGER NOT NULL DEFAULT 0,
                created_at TIMESTAMP NOT NULL DEFAULT NOW()
            )
            """
        )


def make_code(length=6):
    return "".join(random.choices(ALPHABET, k=length))


@app.route("/", methods=["GET", "POST"])
def index():
    short_url = None
    if request.method == "POST":
        target = request.form.get("url", "").strip()
        if target:
            if not target.startswith(("http://", "https://")):
                target = "https://" + target
            code = make_code()
            with get_conn() as conn, conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO links (code, target) VALUES (%s, %s)", (code, target)
                )
            short_url = request.host_url + code

    with get_conn() as conn, conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute("SELECT code, target, clicks FROM links ORDER BY created_at DESC LIMIT 10")
        links = cur.fetchall()

    return render_template("index.html", short_url=short_url, links=links)


@app.route("/<code>")
def follow(code):
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute("UPDATE links SET clicks = clicks + 1 WHERE code = %s RETURNING target", (code,))
        row = cur.fetchone()
    if row is None:
        return jsonify(error="unknown short code"), 404
    return redirect(row[0])


@app.route("/health")
def health():
    """Used by the container healthcheck."""
    try:
        with get_conn() as conn, conn.cursor() as cur:
            cur.execute("SELECT 1")
        return jsonify(status="ok", database="up"), 200
    except Exception as exc:
        return jsonify(status="degraded", database="down", error=str(exc)), 503


init_db()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
