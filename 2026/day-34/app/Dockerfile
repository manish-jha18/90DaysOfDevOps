FROM python:3.12-slim

# curl is needed by the compose healthcheck for this service
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# dependencies first so this layer stays cached when only app.py changes
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# do not run as root
RUN useradd --create-home --shell /bin/bash appuser
USER appuser

EXPOSE 5000

CMD ["python", "app.py"]
