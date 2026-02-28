# Architecture

## Data Flow

```
┌──────────────────┐                          ┌──────────────────────┐
│    Flutter App   │                          │       Backend        │
│                  │   GET /voices            │                      │
│  ┌─────────────┐ │ ◄──────────────────────  │  ┌────────────────┐  │
│  │  Settings   │ │                          │  │   FastAPI      │  │
│  └─────────────┘ │   GET /novel_index       │  │                │  │
│                  │ ◄──────────────────────  │  │  ┌───────────┐ │  │
│  ┌─────────────┐ │                          │  │  │  Scraper  │ │  │
│  │  Library    │ │   GET /novel_details     │  │  └───────────┘ │  │
│  └─────────────┘ │ ◄──────────────────────  │  │                │  │
│                  │                          │  │  ┌───────────┐ │  │
│  ┌─────────────┐ │   WS /ws                 │  │  │  Kokoro   │ │  │
│  │  Reader     │ │ ◄════════════════════►   │  │  │  TTS      │ │  │
│  │  (SoLoud)   │ │   JSON events +          │  │  └───────────┘ │  │
│  └─────────────┘ │   binary PCM16 frames    │  └────────────────┘  │
└──────────────────┘                          └──────────────────────┘
```

## WebSocket Protocol

### Client → Server

```json
{ "command": "play", "url": "<chapter_url>", "voice": "af_bella", "speed": 1.0, "prefetch": 3, "start_paragraph": 0 }
{ "command": "play", ..., "realtime": false }   // offline download mode
{ "command": "pause" }
{ "command": "resume" }
{ "command": "stop" }
```

### Server → Client

**`chapter_info`** — sent once after `play`, before audio:

```json
{
  "type": "chapter_info",
  "title": "Chapter 1",
  "url": "...",
  "voice": "af_bella",
  "next_url": "...",
  "prev_url": "...",
  "paragraphs": ["First paragraph...", "Second paragraph..."],
  "start_paragraph": 0,
  "sentence_total": 42,
  "audio": {
    "encoding": "pcm_s16le",
    "sample_rate": 24000,
    "channels": 1,
    "frame_ms": 200,
    "chunking": "sentence"
  }
}
```

**`sentence`** — metadata for each sentence (sent before the corresponding binary chunk):

```json
{
  "type": "sentence",
  "text": "The rain fell steadily.",
  "paragraph_index": 0,
  "sentence_index": 1,
  "ms_start": 4200,
  "char_start": 45,
  "char_end": 68,
  "chunk_samples": 48000,
  "chunk_bytes": 96000
}
```

**Binary frames** — raw PCM16 mono audio (int16, little-endian). One message per sentence.

**`chapter_complete`** — sent when all audio has been streamed:

```json
{
  "type": "chapter_complete",
  "next_url": "...",
  "prev_url": "..."
}
```

**`flac_data`** (downloads only) — sent before `chapter_complete` when `realtime: false`:

```json
{
  "type": "flac_data",
  "size": 1234567,
  "sample_rate": 24000,
  "channels": 1
}
```

The next binary WebSocket message after `flac_data` contains the complete FLAC
file. The client saves this instead of the raw PCM chunks for better compression
and lossless storage.
```

## Speed Controls

The app has **two independent speed controls**:

| Control | Where | What it does | Re-synthesis? |
|---------|-------|-------------|---------------|
| **TTS Render Speed** | Settings + Reader menu | Kokoro synthesis tempo. Baked into PCM. | Yes (live only) |
| **Playback Speed** | Reader menu | SoLoud fast-forward. Like YouTube speed. | No — instant |

### How highlight sync works

Highlights are scheduled at exact PCM sample positions and compared against `SoLoud.getStreamTimeConsumed()`, which reflects the actual consumption rate including the playback multiplier. This means highlights stay in sync at any Playback Speed without additional correction.

## Sentence Offsets

Each `sentence` event includes `char_start` and `char_end` (character offsets within the paragraph text). This allows the client to highlight by substring range rather than fragile string matching.

`chunk_samples` and `chunk_bytes` let the client associate sentence metadata with audio even if transport layers split messages.

## Audio Pacing

- **Live streaming** (`realtime: true`, default): Backend paces output to roughly match playback time, reducing client buffer bloat. A small lookahead (~100ms) avoids stutter.
- **Offline downloads** (`realtime: false`): Backend sends as fast as synthesis allows. The app writes chunks to disk as they arrive. After all sentences, the backend sends a FLAC-encoded copy of the complete chapter for lossless storage.

Audio chunking is sentence-based, so if buffering causes a pause, it happens **between** sentences rather than mid-word.

## Audio Quality

The synthesis pipeline is designed to minimise artefacts:

- **Float32 pipeline**: All audio processing (fade, silence padding) operates on float32. A single float32→int16 conversion happens at the very end, right before sending over WebSocket. This eliminates double-quantisation noise.
- **Raised-cosine fade**: Sentence boundaries use a smooth cosine fade-in/out instead of linear, producing imperceptible transitions.
- **Session recycling**: The ONNX Runtime session is recreated every ~200 sentences to prevent numerical drift from accumulated internal state.
- **Dedicated TTS thread**: Kokoro inference runs on a dedicated `ThreadPoolExecutor(max_workers=1)` to avoid contention with I/O tasks.

---

[← Back to README](../README.md)
