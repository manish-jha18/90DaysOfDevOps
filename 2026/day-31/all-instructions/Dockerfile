# Day 31 Task 2 - every instruction the task asks for
FROM python:3.12-slim

# WORKDIR creates the directory and cd's into it for every later instruction
WORKDIR /app

# copy dependencies first so this layer is cached when only app.py changes
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# app code changes most often, so it goes last
COPY app.py .

# EXPOSE is documentation only - it does not publish the port
EXPOSE 5000

CMD ["python", "app.py"]
