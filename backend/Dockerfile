# syntax=docker/dockerfile:1
FROM python:3.12-slim

WORKDIR /app

# System deps for lxml/bs4 + general networking
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    gcc \
    g++ \
    libc6-dev \
  && rm -rf /var/lib/apt/lists/*

# Install uv
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
  && ln -s /root/.local/bin/uv /usr/local/bin/uv

# Copy dependency metadata first for better layer caching
COPY pyproject.toml uv.lock* /app/

# Create venv + install deps
RUN uv venv --python 3.12 \
  && uv sync

# Copy app code
COPY . /app/

EXPOSE 8000

# Ensure models exist, then start server (avoid `uv run` here to prevent any
# auto-sync behavior re-installing CPU onnxruntime).
CMD ["/bin/sh", "-lc", "uv run python download_models.py && uv run python server.py"]
