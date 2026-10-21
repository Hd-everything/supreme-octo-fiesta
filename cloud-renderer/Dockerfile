FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg ca-certificates fontconfig fonts-dejavu-core && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY worker.py /app/worker.py
RUN useradd --create-home --uid 10001 worker && chown -R worker:worker /app
USER worker
CMD ["python", "-u", "/app/worker.py"]
