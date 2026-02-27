# Backend: Modal (Serverless)

Deploy the backend to [Modal](https://modal.com) for a serverless, auto-scaling endpoint.

---

## Prerequisites

- A [Modal](https://modal.com) account (free tier available)
- `modal` CLI installed: `pip install modal`
- Logged in: `modal setup`

---

## Deploy

The Modal app definition is at `CoreReader-modal/modal_app.py` (sibling to this repo):

```bash
cd CoreReader-modal
modal deploy modal_app.py
```

Modal prints a public URL like:

```
https://<user>--corereader-backend-fastapi-app.modal.run
```

---

## Connect from the App

In the Flutter app → **Settings** → **WebSocket base URL**:

```
wss://<user>--corereader-backend-fastapi-app.modal.run
```

The app connects to `/ws` automatically.

---

## Configuration

The Modal app runs with:
- CPU-only Kokoro ONNX
- Persistent model cache (Modal Volume) — models download once
- 3 CPU cores + 4 GiB RAM (configurable in `modal_app.py`)

---

## Notes

- Modal free tier includes generous compute credits.
- Cold starts take ~30s (model loading). Warm containers respond instantly.
- The container scales to zero when idle (no cost when not in use).

---

[← Back to README](../README.md)
