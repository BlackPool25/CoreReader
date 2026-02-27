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
  - Use **Download selected** (or use “Download all chapters”)
  - Downloads run in the background (you can keep scrolling/reading)
  - Downloading chapters show a right-side circular progress ring; downloaded chapters show a right-side tick

When you start a download (single/batch), the app asks which voice to download with.
It includes a **Default (settings)** option and applies the choice to the whole batch.

Downloaded chapters are stored as:
- Raw **PCM16 mono** audio (`audio.pcm`)
- A small JSON `meta.json` containing paragraphs + a sentence timeline for highlight sync

The configured SAF folder also stores app state under:
- `LN-TTS/app_state/` (library, chapter cache, reading progress, downloads index)

This makes backup/restore easy: copy that folder to a new device and re-select it.

Backend WS `play` supports `realtime: false` which disables frame pacing so downloads finish quickly.

### Offline playback notes

- **TTS Render Speed is baked into the downloaded PCM.** The voice speed selected at download time is permanently encoded in the audio. Changing the TTS speed slider after downloading has no effect on offline chapters; re-download at the desired speed if you want a different voice tempo.
- **Playback Speed (fast-forward) works freely for downloaded chapters.** It is applied via SoLoud and does not require a re-download. Highlight sync automatically tracks the new rate.
- **Highlight sync** for offline chapters is driven by a pre-recorded sentence timeline (stored in `meta.json`). Timestamps are in milliseconds relative to the start of the raw PCM. The timeline advance rate automatically matches the Playback Speed multiplier.
- **Voice for auto-downloads** follows the session voice active in the Reader at the time the auto-download is triggered (not the saved default in Settings).

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
4. Adjust **default** voice and **TTS Render Speed** in **Settings** (persisted locally).
5. In the Reader, open the **tune ⚙** menu to adjust:
   - **Voice** (session only; changing restarts synthesis).
   - **Playback Speed** — instant SoLoud fast-forward, like YouTube 1.5×. Works for live and downloaded chapters. Does **not** re-synthesise audio.
   - **TTS Render Speed** — changes the Kokoro synthesis tempo; triggers a re-synthesis from the current paragraph (live only). For downloaded chapters this is shown read-only (baked into the PCM at download time).
6. The backend:
  - scrapes the chapter text from the chapter content container (`div.site-content div.overflow-hidden`)
  - splits into sentences (paragraph-aware) and adds short pauses for more natural pacing
  - pre-synthesizes a few sentences ahead (prefetch) to reduce boundary pauses
  - streams **sentence-atomic** PCM16 chunks over WebSocket (one binary message per sentence)
    - each chunk includes a small trailing pause
    - each sentence audio gets a tiny fade-in/out to avoid boundary clicks
7. The app plays audio immediately. Sentence highlights are **sample-accurate**: the start-sample of each sentence chunk is recorded when it is enqueued into SoLoud, and the highlight fires exactly when `SoLoud.getStreamTimeConsumed()` reaches that sample — no wall-clock estimation, no feedback loop.

> Note: This project is intended for personal/local use.

## Speed architecture

The app has **two independent speed controls** that serve different purposes:

| Control | Where | What it does | Triggers re-synthesis? |
|---|---|---|---|
| **TTS Render Speed** | Settings (global) + Reader menu | Sent as `speed` to Kokoro. Controls how fast the voice model speaks. Baked into the synthesised PCM. | Yes (for live chapters) |
| **Playback Speed** | Reader menu | Passed to `SoLoud.setRelativePlaySpeed()`. Fast-forwards already-generated audio. Like YouTube speed control. | No — instant change |

**Highlight sync at any playback speed**: Because highlights are scheduled at exact PCM sample positions and compared against `getStreamTimeConsumed()` (which reflects the actual consumption rate including the playback multiplier), highlights stay in sync with audio at any Playback Speed without any additional correction.

**Downloads**: The TTS Render Speed is baked into the downloaded PCM at download time and saved in `meta.json`. Changing the global TTS speed after downloading doesn't affect existing downloads. The Playback Speed (fast-forward) can be freely changed for downloaded chapters without re-downloading.

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
- Backend scrapes the chapter, emits a `chapter_info` JSON message (paragraphs + audio format), then streams PCM16 audio **sentence chunks**.
- Backend emits `sentence` JSON messages for highlighting, including `paragraph_index` and `sentence_index`.
- Sentence events also include:
  - `char_start` / `char_end` (character offsets within the paragraph) so the client can highlight by range (avoids fragile string matching)
  - `chunk_bytes` / `chunk_samples` (size of the upcoming sentence PCM chunk) so the client can reliably pair sentence metadata with audio
- Frontend can send `{ "command": "pause" }`, `{ "command": "resume" }`, `{ "command": "stop" }` during playback.

### Streaming vs downloads (important)

- Live streaming sends `realtime: true` (default). The backend paces output loosely to avoid huge client buffer bloat.
- Offline downloads send `realtime: false` so the backend sends as fast as synthesis allows.
- Audio chunking is sentence-based, so if buffering happens it should pause **between sentences**, not mid-sentence.

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

## Deploy backend to Modal

This workspace includes a ready-to-deploy Modal app definition in:

- [CoreReader-modal/modal_app.py](../CoreReader-modal/modal_app.py)

It deploys the same FastAPI backend (HTTP + WebSocket) with:
- CPU-only Kokoro ONNX
- Persistent model cache (Modal Volume) so downloads happen once
- 3 CPU cores + 4 GiB RAM (easy to scale up later)

Deploy:

```bash
cd ../CoreReader-modal
modal deploy modal_app.py
```

Modal prints a public base URL like:

- https://<user>--corereader-backend-fastapi-app.modal.run

In the Flutter app Settings, set **WebSocket base URL** to:

- wss://<user>--corereader-backend-fastapi-app.modal.run

The app connects to `/ws` automatically.

## Local persistence (frontend)

The app stores the following locally (SharedPreferences):
- Backend server URL, theme mode, reader font size, default voice, default speed
- Library novels (name + url)
- Cached chapter lists per novel (use **Refresh Chapters** to update)
- Reading progress and read/unread history (auto-mark read on chapter completion)
