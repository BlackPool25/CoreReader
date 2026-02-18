# CoreReader (Flutter frontend)

This is the Flutter UI/player for LN-TTS.

The app requires the backend to be running (no on-device TTS).

## Run

```bash
flutter pub get
flutter run
```

## Backend URL

Settings → **WebSocket base URL**

Examples:
- Local dev (same machine): `ws://localhost:8000`
- Android emulator: `ws://10.0.2.2:8000`
- Physical phone on Wi-Fi: `ws://<your-pc-lan-ip>:8000`
- Azure Container Apps (HTTPS): `wss://<your-app-fqdn>`
- Hugging Face Spaces (HTTPS): `wss://<space-subdomain>.hf.space`
