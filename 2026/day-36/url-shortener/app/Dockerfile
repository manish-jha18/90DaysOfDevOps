# ---------- stage 1: build the dependencies ----------
# Wheels are built here so the runtime image never needs a compiler.
FROM python:3.12-slim AS builder

WORKDIR /build

RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc libpq-dev && \
    rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip wheel --no-cache-dir --wheel-dir /wheels -r requirements.txt

# ---------- stage 2: runtime ----------
FROM python:3.12-slim

# libpq5 is the postgres client library psycopg2 links against at runtime.
# curl is here only for the healthcheck.
RUN apt-get update && \
    apt-get install -y --no-install-recommends libpq5 curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# install from the pre-built wheels - no compiler needed in this stage
COPY --from=builder /wheels /wheels
RUN pip install --no-cache-dir --no-index --find-links=/wheels /wheels/* && \
    rm -rf /wheels

# app code last so the layers above stay cached
COPY app.py .
COPY templates ./templates

# do not run as root
RUN useradd --create-home --uid 10001 appuser && \
    chown -R appuser:appuser /app
USER appuser

EXPOSE 8000

# gunicorn rather than the flask dev server - the dev server is single
# threaded and prints a warning telling you not to use it in production
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "app:app"]
