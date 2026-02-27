# Backend: Local Docker

Run the backend on your own machine. Best for development and local network use.

---

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) and Docker Compose installed
- ~2 GB disk space (Docker image + Kokoro models)

---

## Quick Start

From the repo root:

```bash
# Build and start
docker compose up -d --build backend

# Verify
curl http://127.0.0.1:8000/health
# → {"ok":true,"tts_ready":true}

curl http://127.0.0.1:8000/voices
# → {"voices":["af_bella","af_heart",...]}
```

The first startup downloads the Kokoro ONNX model (~300 MB). Subsequent starts are instant.

---

## Stop / Restart

```bash
# Stop
docker compose down

# View logs
docker compose logs -f backend

# Rebuild after code changes
docker compose up -d --build backend
```

---

## Connect from the Flutter App

### Same machine (desktop)

The default `ws://localhost:8000` works — no changes needed.

### Phone on the same Wi-Fi

1. Find your PC's LAN IP:

   ```bash
   # Linux
   ip addr show | grep "inet " | grep -v 127.0.0.1

   # macOS
   ifconfig | grep "inet " | grep -v 127.0.0.1

   # Windows
   ipconfig
   ```

2. In the Flutter app → **Settings** → **WebSocket base URL**:

   ```
   ws://192.168.x.x:8000
   ```

3. Make sure your PC firewall allows inbound TCP port **8000**.

---

## Without Docker (uv)

If you prefer running Python directly:

```bash
cd backend

# Create venv and install dependencies
uv venv
uv sync

# Download Kokoro models
uv run python download_models.py

# Start the server
uv run python server.py
```

Server listens on `0.0.0.0:8000`.

---

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Server status |
| GET | `/voices` | Available TTS voices |
| GET | `/novel_index?url=...` | Chapter list for a novel |
| GET | `/novel_details?url=...` | Novel cover URL (best-effort) |
| GET | `/novel_meta?url=...` | Chapter count |
| GET | `/novel_chapter?url=...&n=...` | Resolve chapter by number |
| WS | `/ws` | Audio streaming WebSocket |

---

[← Back to README](../README.md)
