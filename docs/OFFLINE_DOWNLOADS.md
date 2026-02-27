# Offline Downloads (Android)

Offline downloads use the Android **Storage Access Framework (SAF)** to store chapters as raw PCM audio files.

---

## Setup

1. Go to **Settings** → **Downloads storage** and choose a folder.
2. The app creates an `LN-TTS/` directory structure inside it.

---

## Downloading Chapters

1. Open a novel's chapter list.
2. **Long-press** a chapter to enter selection mode.
3. Select chapters (or use **Select All**).
4. Tap the **Download** icon in the selection bar.
5. Choose a voice for the download batch (includes a "Default (settings)" option).

Downloads run in the background — you can keep reading or browsing.

### Progress indicators

- **Circular ring** (right side of chapter tile) = download in progress
- **Tick icon** (right side) = downloaded and ready for offline playback

---

## How Downloads Work

The app sends a `play` command with `realtime: false`, which tells the backend to stream audio as fast as synthesis allows (no real-time pacing). Each downloaded chapter is stored as:

- `audio.pcm` — raw PCM16 mono audio
- `meta.json` — paragraph text + sentence timeline for highlight sync

---

## Storage Location

```
<chosen SAF folder>/
  LN-TTS/
    app_state/         # Library, chapter cache, reading progress, downloads index
    <novel-id>/
      <chapter-n>/
        audio.pcm
        meta.json
```

**Backup/restore**: Copy the `LN-TTS/` folder to a new device and re-select it in Settings.

---

## Important Notes

- **TTS Render Speed is baked into the PCM.** The voice speed at download time is permanently encoded. To change speed, re-download the chapter.
- **Playback Speed works freely.** Fast-forward via SoLoud applies to downloaded chapters without re-downloading.
- **Highlight sync** for offline chapters uses the pre-recorded sentence timeline in `meta.json`. Timestamps automatically scale with Playback Speed.
- **Voice for auto-downloads** follows the session voice in the Reader, not the default in Settings.

---

[← Back to README](../README.md)
