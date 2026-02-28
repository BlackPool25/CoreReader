# CoreReader

**A light-novel reader with high-quality AI text-to-speech.**

CoreReader scrapes light novels from NovelCool and reads them aloud using [Kokoro](https://github.com/thewh1teagle/kokoro-onnx) TTS. The backend does all the heavy lifting (scraping + synthesis); the Flutter app is a thin player that streams audio over WebSocket.

> **Personal / local use only.** This project is not affiliated with NovelCool.

---

## Features

- **50+ natural English voices** via Kokoro ONNX (CPU, no GPU needed)
- **Sentence-accurate highlighting** — highlights follow audio playback precisely at any speed
- **Offline downloads** — download chapters as lossless FLAC for offline listening (Android)
- **Two independent speed controls** — TTS render speed (synthesis tempo) + playback speed (fast-forward)
- **Mihon-style chapter management** — filter, sort, grid/list display, bulk select, mark-as-read
- **Auto-advance** — automatically moves to the next chapter
- **Persistent settings** — filters, sort order, display preferences, voice, speed all survive app restarts
- **Multiple deployment options** — free HuggingFace Space, local Docker, Azure, Modal

---

## Quick Start

### 1. Get a backend running

Pick **one** of these options (easiest first):

| Option | Cost | Setup time | Guide |
|--------|------|------------|-------|
| **HuggingFace Space** (recommended) | Free | 2 min | [docs/BACKEND_HUGGINGFACE.md](docs/BACKEND_HUGGINGFACE.md) |
| **Local Docker** | Free | 5 min | [docs/BACKEND_LOCAL.md](docs/BACKEND_LOCAL.md) |
| **Azure Container Apps** | Paid | 15 min | [docs/BACKEND_AZURE.md](docs/BACKEND_AZURE.md) |
| **Modal** | Free tier | 10 min | [docs/BACKEND_MODAL.md](docs/BACKEND_MODAL.md) |

### 2. Install the app

```bash
cd frontend
flutter pub get
flutter run          # Linux desktop, Android, or Web
```

### 3. Connect

Open **Settings** in the app and paste your backend URL:

| Backend | URL to paste |
|---------|-------------|
| HuggingFace | `wss://<your-space>.hf.space` |
| Local Docker | `ws://192.168.x.x:8000` (your PC's LAN IP) |
| Azure | `wss://<fqdn>` |
| Modal | `wss://<user>--corereader-backend-fastapi-app.modal.run` |

---

## How It Works

```
┌─────────────┐       WS /ws          ┌──────────────┐
│  Flutter App│ ◄──────────────────► │   Backend    │
│  (player)   │   PCM16 audio +      │  (FastAPI)   │
│             │   sentence events    │              │
└─────────────┘                      │  ┌─────────┐ │
                                     │  │ Scraper │ │  ← NovelCool
                                     │  │ Kokoro  │ │  ← TTS (CPU)
                                     │  └─────────┘ │
                                     └──────────────┘
```

1. Add a novel (name + NovelCool URL) in the app.
2. Open it → refresh chapters (fetched from backend, cached locally).
3. Tap a chapter to start reading. Audio streams sentence-by-sentence.
4. Adjust voice, TTS speed, playback speed in the Reader menu.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full data flow and protocol details.

---

## Project Structure

```
backend/
  server.py           # FastAPI HTTP + WebSocket server
  scraper.py          # NovelCool chapter scraping
  tts.py              # Kokoro ONNX TTS engine (float32 pipeline, session recycling)
  download_models.py  # Model downloader (kokoro-v1.0.onnx + voices)

frontend/
  lib/
    main.dart
    app.dart
    screens/           # Library, NovelDetail, Reader, Settings
    services/          # WebSocket streaming, settings, downloads
    widgets/           # Shared UI components
```

---

## Documentation

| Page | Description |
|------|-------------|
| [Backend: HuggingFace](docs/BACKEND_HUGGINGFACE.md) | Free hosted backend — zero install |
| [Backend: Local Docker](docs/BACKEND_LOCAL.md) | Run on your own machine |
| [Backend: Azure](docs/BACKEND_AZURE.md) | Deploy to Azure Container Apps |
| [Backend: Modal](docs/BACKEND_MODAL.md) | Deploy to Modal (serverless) |
| [Architecture](docs/ARCHITECTURE.md) | Data flow, WS protocol, speed controls |
| [Offline Downloads](docs/OFFLINE_DOWNLOADS.md) | Android offline playback |
| [Flutter Web](docs/FLUTTER_WEB.md) | Web-specific setup (COOP/COEP headers) |
| [Frontend Build](docs/FRONTEND_BUILD.md) | Build prerequisites and troubleshooting |

---

## License

This project is for personal, non-commercial use.
