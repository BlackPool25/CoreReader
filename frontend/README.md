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

## Recent Bug Fixes

### Bug 1 — Settings page loads instantly
The settings screen no longer blocks on the `/voices` network call. Voices are
fetched asynchronously with an inline spinner on the voice dropdown; all other
settings render immediately from the cached `AppSettingsScope`.

### Bug 2 — Reader AppBar shows "Chapter N" only
The AppBar title is hardcoded to `Chapter ${_chapter.n}`, preventing long novel
titles from overflowing. The full title is shown in the body header instead.

### Bug 3 — Session settings sheet is scrollable
The bottom sheet body is wrapped in `SingleChildScrollView` so the Apply button
is always reachable, even on small screens.

### Bug 4 — Pause stops at the last heard sentence
On resume, playback restarts from the last heard paragraph index instead of
trying to unpause the SoLoud buffer at an arbitrary position. Both live and
offline timelines track `lastHeardParagraphIndex`.

### Bug 5 — In-memory audio cache (rewind without re-fetching)
`NovelStreamController` caches sentence-level PCM data as it arrives from the
backend. A sliding window of up to 3 chapters is kept. `hasCachedAudio()` and
`replayFromCache()` allow the reader to rewind to a previous paragraph without
making a new backend request.

### Bug 6 — SharedPreferences is the canonical store
`LocalStore` now always reads/writes SharedPreferences first. SAF (Android
Storage Access Framework) is used as a write-through secondary backup. If SAF
permissions are revoked, data is recovered from SharedPreferences instead of
being lost.

### Bug 7 — Non-blocking novel detail screen
The chapter list is no longer replaced by a full-screen spinner during refresh.
A `LinearProgressIndicator` overlays the existing content, keeping the UI
interactive while the backend responds.

### Bug 8 — Download audio quality improvements
- **Write-chain race fix**: `chapter_complete` now waits for all queued PCM
  writes to SAF before signaling completion, preventing truncated audio files.
- **Pre-buffering**: Offline playback buffers ~2 seconds of PCM before starting
  the playback clock, eliminating initial glitches.
- **Pacing**: Yield frequency during offline PCM loading increased to every 4
  chunks with a 4ms delay to avoid overwhelming the SoLoud buffer.
