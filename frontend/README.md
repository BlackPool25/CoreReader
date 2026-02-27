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

## Mihon-Style Chapter Management (Novel Detail Screen)

The novel detail screen was rewritten with a Mihon-inspired chapter management
experience.

### Filter / Sort / Display Bottom Sheet
A tabbed bottom sheet (opened via the filter icon in the AppBar) with three tabs:

- **Filter**: Tri-state checkboxes for **Downloaded** and **Unread**. Each cycles
  through Off → Include only → Exclude → Off, matching Mihon's behavior.
- **Sort**: Toggle between ascending and descending chapter order.
- **Display**: Switch between list and grid view. Grid mode offers 2, 3, or 4
  column options via ChoiceChips. Labels auto-shorten to just the chapter number
  when columns ≥ 3 to ensure visibility.

### Selection Bottom Action Bar
Long-pressing a chapter enters selection mode. A bottom action bar appears with:
Select all, Mark read, Mark unread, Mark previous as read, Download, Delete.

The **Mark previous as read** action marks all chapters before the lowest
selected chapter as read — useful for catching up when you start reading
mid-novel.

### Mihon-Style Cover Header
The novel detail screen now displays a cover header at the top (like Mihon):
- Blurred cover image background with gradient fade
- Cover thumbnail (100×140) on the left
- Novel title, source domain, and stats (chapter count, downloaded, read) on the
  right
- Full-width **Resume** button showing the current chapter when progress exists

### Simplified AppBar
- **Filter icon**: Opens the Filter/Sort/Display sheet. Icon switches to
  `filter_list_off` when filters are active.
- **Refresh icon**: Refreshes the chapter list.
- **Overflow menu**: Grouped logically — Download actions (all / next 5 / 10 /
  25), divider, Delete downloads, divider, Refresh cover, divider, Remove from
  library.
- **Selection mode**: Shows selected count + close button; actions are in the
  bottom bar instead.
