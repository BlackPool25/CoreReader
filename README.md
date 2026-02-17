# LN-TTS (NovelCool → Local TTS → Flutter Player)

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

## Android note

The Flutter Android app can run fully on-device (no backend server required):
- Scrapes NovelCool directly in-app
- Runs Kokoro ONNX locally via ONNX Runtime
- Downloads the (int8) model + voices on first use and stores them in app storage

You can still use the Python backend mode on desktop/web if you want streaming over LAN.
