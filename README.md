# LN-TTS (Backend Scrape + TTS → Flutter Player)

This repo contains:
- `backend/`: FastAPI WebSocket server (scrape chapter text + stream PCM audio from local TTS)
- `frontend/`: Flutter app (Library + chapter list + reader route, settings, local caching/history)

Developer notes for contributors/agents: see `.agents.md`.

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
- Novel details (cover): `GET http://<host>:8000/novel_details?url=<novel_url>`
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

## Offline downloads (Android)

Offline downloads are **Android-only** and use the Android **Storage Access Framework (SAF)**.

- Settings → **Downloads storage** → choose a folder
- In a novel’s chapter list:
  - **Long-press** a chapter to start selecting
  - Use **Clear** / **Download selected** (or use “Download all chapters”)

Downloaded chapters are stored as:
- Raw **PCM16 mono** audio (`audio.pcm`)
- A small JSON `meta.json` containing paragraphs + a sentence timeline for highlight sync

Backend WS `play` supports `realtime: false` which disables frame pacing so downloads finish quickly.

### Settings (using your phone with your PC as the server)

- On desktop (running the Flutter app on the same PC as the backend), the default `ws://localhost:8000` works without changing anything.

- For your phone:
  - Run the backend on your PC.
  - In the Flutter app, open **Settings** and set **WebSocket base URL** to something like:
  - `ws://192.168.1.45:8000`
- Make sure your PC firewall allows inbound `8000/tcp`.

## Runtime flow

1. Add a novel (name + NovelCool URL) in **Add novel**.
2. Open it from **Library** → refresh chapters (cached locally).
3. Pick a chapter to start reading.
4. Adjust **default** voice/speed in **Settings** (persisted locally).
5. In the Reader, you can adjust **session** voice/speed; changes apply instantly by restarting from the current paragraph.
4. The backend:
  - scrapes the chapter text from the chapter content container (`div.site-content div.overflow-hidden`)
  - splits into sentences (paragraph-aware) and adds short pauses for more natural pacing
  - pre-synthesizes a few sentences ahead (prefetch) to reduce boundary pauses
   - streams PCM16 audio frames over WebSocket
5. The app plays audio immediately and highlights the currently spoken sentence (synced via sentence metadata from backend).

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

Audio on Flutter Web with `flutter_soloud` may require cross-origin isolation headers (COOP/COEP). If you see errors mentioning `createWorkerInWasm` or `SharedArrayBuffer`, run with headers (Flutter versions that support it):

```bash
flutter run -d chrome --web-port 3000 \
  --web-header="Cross-Origin-Opener-Policy=same-origin" \
  --web-header="Cross-Origin-Embedder-Policy=require-corp"
```

This repo also includes the required `flutter_soloud` Web bootstrap scripts in `frontend/web/index.html`:
- `assets/packages/flutter_soloud/web/libflutter_soloud_plugin.js`
- `assets/packages/flutter_soloud/web/init_module.dart.js`

## Data flow (high level)

- Frontend (Flutter) calls backend `GET /voices` to populate the voice list.
- Frontend can call backend `GET /novel_details?url=...` to fetch a cover image URL (best-effort).
- Frontend opens `WS /ws` and sends `{ "command": "play", "url": <chapter_url>, "voice": <id>, "speed": <x>, "start_paragraph": <idx> }`.
- Backend scrapes the chapter, emits a `chapter_info` JSON message (paragraphs + audio format), then streams PCM16 audio frames.
- Backend emits `sentence` JSON messages for highlighting, including `paragraph_index` and `sentence_index`.
- Frontend can send `{ "command": "pause" }`, `{ "command": "resume" }`, `{ "command": "stop" }` during playback.

## Deploy backend to Azure (Container Apps)

You’ll deploy a Docker image of the backend, push it to **Azure Container Registry (ACR)**, then run it in **Azure Container Apps**.

### 1) Create resource group + ACR

```bash
az login
az group create -n corereader-rg -l westeurope
az acr create -n <acrName> -g corereader-rg --sku Basic
```

Get your registry login server (this is the “registry link”):

```bash
az acr show -n <acrName> -g corereader-rg --query loginServer -o tsv
```

### 2) Build + push image

Option A (build in Azure, easiest):

```bash
az acr build -r <acrName> -t corereader-backend:v1 -f backend/Dockerfile backend
```

Your image tag to use in Azure will be:

`<loginServer>/corereader-backend:v1`

### 3) Deploy Container App (public HTTPS + WebSockets)

```bash
az extension add --name containerapp --upgrade
az containerapp env create -g corereader-rg -n corereader-env -l westeurope

loginServer=$(az acr show -n <acrName> -g corereader-rg --query loginServer -o tsv)

az containerapp create \
  -g corereader-rg \
  -n corereader-backend \
  --environment corereader-env \
  --image "$loginServer/corereader-backend:v1" \
  --ingress external \
  --target-port 8000 \
  --registry-server "$loginServer"
```

### 4) What URL do I put in the app?

Get the public URL from Azure:

```bash
az containerapp show -g corereader-rg -n corereader-backend \
  --query properties.configuration.ingress.fqdn -o tsv
```

- Your backend base URL will be: `https://<fqdn>`
- The **WebSocket base URL to paste into Settings** is: `wss://<fqdn>`

Notes:
- First startup downloads models; allow extra time for the first boot.
- If you change regions/names, the registry/image/url will change—use the commands above to retrieve the exact values.

## Local persistence (frontend)

The app stores the following locally (SharedPreferences):
- Backend server URL, theme mode, reader font size, default voice, default speed
- Library novels (name + url)
- Cached chapter lists per novel (use **Refresh Chapters** to update)
- Reading progress and read/unread history (auto-mark read on chapter completion)
