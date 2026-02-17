# LN-TTS (Backend Scrape + TTS → Flutter Player)

This repo contains:
- `backend/`: FastAPI WebSocket server (scrape chapter text + stream PCM audio from local TTS)
- `frontend/`: Flutter app (URL input, voice selector, sentence preview, play/pause, next/prev, settings)

## Backend (Python + FastAPI)

This project is intended to run the backend via Docker (start/stop with one command).

### Docker (easy start/stop) — recommended

From the repo root:

```bash
docker compose up -d --build backend
```

Stop:

```bash
docker compose down
```

Logs:

```bash
docker compose logs -f backend
```

This publishes the backend on `http://0.0.0.0:8000`, so your phone can connect using your PC’s LAN IP (e.g. `ws://192.168.1.45:8000`).

### Local (uv) — optional

```bash
cd backend
uv venv
source .venv/bin/activate
uv sync
```

### 2) Download the Kokoro ONNX model

```bash
python download_models.py
```

Downloads:
- `models/kokoro-v1.0.onnx`
- `models/voices-v1.0.bin`

### 3) Run the server (local)

```bash
uv run python server.py
```

Server listens on `0.0.0.0:8000`.
- Health: `GET http://<host>:8000/health`
- Voices: `GET http://<host>:8000/voices`
- WebSocket: `ws://<host>:8000/ws`

### CPU-only

The backend is configured to run on CPU for maximum compatibility across machines.

## Frontend (Flutter)

### Ubuntu 24.04 Linux build prerequisites

If `flutter run -d linux` fails with:
`Failed to find any of [ld.lld, ld] in LocalDirectory: '/usr/lib/llvm-18/bin'`

Install the missing LLVM linker:

```bash
sudo apt update
sudo apt install -y lld-18 llvm-18 clang-18 cmake ninja-build pkg-config libgtk-3-dev
```

### 1) Install deps

```bash
cd frontend
flutter pub get
```

### 2) Run

```bash
flutter run
```

### Settings (using your phone with your PC as the server)

- On desktop (running the Flutter app on the same PC as the backend), the default `ws://localhost:8000` works without changing anything.

- For your phone:
  - Run the backend on your PC.
  - In the Flutter app, open **Settings** and set **WebSocket base URL** to something like:
  - `ws://192.168.1.45:8000`
- Make sure your PC firewall allows inbound `8000/tcp`.

## Runtime flow

1. Paste a NovelCool chapter URL in the Reader screen.
2. Pick a voice and speed.
3. Press **Play**.
4. The backend:
  - scrapes the chapter text from the chapter content container (`div.site-content div.overflow-hidden`)
   - splits into sentences
   - pre-synthesizes a few sentences ahead (prefetch) to reduce boundary pauses
   - streams PCM16 audio frames over WebSocket
5. The app plays audio immediately and shows the currently spoken sentence.

> Note: This project is intended for personal/local use.

## Backend required (Android/Web/Desktop)

The frontend is a thin UI/player. Scraping and TTS always run in the backend.

1) On the PC:
- `docker compose up -d --build`
- Confirm backend is reachable: `http://127.0.0.1:8000/health`

2) On the phone (CoreReader):
- Settings → set **WebSocket base URL** to: `ws://<PC_LAN_IP>:8000`
  - Example: `ws://192.168.29.101:8000`

Notes:
- Make sure your firewall allows inbound TCP 8000.
- Use the PC's LAN IP (not `localhost`).

### Flutter Web note

- If the web app is served over `https://`, browsers will usually require `wss://` (secure websockets).
- If you run the web app over plain `http://` (debug/dev), `ws://` is fine.

## Data flow (high level)

- Frontend (Flutter) calls backend `GET /voices` to populate the voice list.
- Frontend opens `WS /ws` and sends `{ "command": "play", "url": <chapter_url>, "voice": <id>, "speed": <x> }`.
- Backend scrapes the chapter, emits a `chapter_info` JSON message (paragraphs + audio format), then streams PCM16 audio frames.
- Backend emits `sentence` JSON messages for highlighting.
- Frontend can send `{ "command": "pause" }`, `{ "command": "resume" }`, `{ "command": "stop" }` during playback.
