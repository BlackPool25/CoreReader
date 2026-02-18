# LN-TTS — Agent Handoff Notes

## What this repo is
LN-TTS is a **backend-required** light-novel reader + TTS player.

- **Backend** (Python/FastAPI):
  - Scrapes chapter content + chapter index from NovelCool.
  - Runs Kokoro ONNX TTS (CPU) and streams **PCM16 mono** over WebSocket.
  - Endpoints:
    - `GET /health`
    - `GET /voices`
    - `GET /novel_index?url=...`
    - `GET /novel_details?url=...` → returns cover URL (best-effort)
    - `GET /novel_meta?url=...` → returns `count` (max chapter number when detectable)
    - `GET /novel_chapter?url=...&n=...` → resolves by parsed chapter number when available
    - `WS /ws` → commands: `play`, `pause`, `resume`, `stop`

- **Frontend** (Flutter):
  - Thin UI/player only (no on-device TTS).
  - Fetches voices from backend `/voices`.
  - Uses `web_socket_channel` to connect to `WS /ws`.
  - Uses `flutter_soloud` buffer streaming to play PCM16.

## Current data flow (core)
1) User selects novel URL + chapter number in the app.
2) App resolves chapter URL via backend `GET /novel_chapter`.
3) App opens WS and sends:
   - `{ "command": "play", "url": <chapter_url>, "voice": <id>, "speed": <x>, "prefetch": <n>, "start_paragraph": <idx> }`
  - Offline downloads use the same WS command but add: `{ "realtime": false }` to disable frame pacing.
4) Backend sends JSON events:
   - `chapter_info` (includes paragraphs + audio format)
   - `sentence` (for highlight)
   - `chapter_complete`
   and streams raw PCM16 frames as binary WS messages.
5) Frontend feeds binary frames into a SoLoud buffer stream.

## How to run (dev)
### Backend (recommended)
From repo root:
- `docker compose up -d --build backend`
- Verify:
  - `curl http://127.0.0.1:8000/health`
  - `curl http://127.0.0.1:8000/voices`

### Frontend
From `frontend/`:
- `flutter pub get`
- `flutter run` (Linux/Android)

## Web (important)
`flutter_soloud` on Web requires the WASM module to be initialized.
This repo includes the required script tags in `frontend/web/index.html`:
- `assets/packages/flutter_soloud/web/libflutter_soloud_plugin.js`
- `assets/packages/flutter_soloud/web/init_module.dart.js`

If Web audio still fails with errors like `_createWorkerInWasm` / `SharedArrayBuffer`, check:
- Cross-origin isolation headers (COOP/COEP) when serving the web build.
- That the above assets are actually being served (open DevTools → Network).

## Known pitfalls + fixes
- **Chapter off-by-one**: Novel indexes may include chapter 0/prologue; backend now resolves chapters by parsed chapter number when possible.
- **Periodic audio gaps**: usually under-buffering. Frontend increases:
  - SoLoud `bufferingTimeNeeds`
  - backend `prefetch` sent from client
- **State resets when switching tabs**: fixed by using `IndexedStack` so Reader isn’t disposed.

## Files to know
- Backend:
  - `backend/server.py` (HTTP + WS protocol)
  - `backend/tts.py` (Kokoro streaming)
  - `backend/scraper.py` (NovelCool parsing + chapter index)
  - `backend/download_models.py` (downloads `kokoro-v1.0.onnx` + `voices-v1.0.bin`)

- Frontend:
  - `frontend/lib/screens/reader_screen.dart` (UI, chapter selection, play/pause)
  - `frontend/lib/services/novel_stream_controller.dart` (WS + SoLoud streaming)
  - `frontend/lib/services/settings_store.dart` (Server URL normalization)

## Design constraints (keep it simple)
- Prefer backend as the single source of truth for scraping + voices.
- Avoid introducing state-management packages unless needed; keep layering minimal.
- Don’t add extra screens/features unless explicitly requested.
