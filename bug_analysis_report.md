# LN-TTS Bug Analysis & Refactoring Options

> This is a **read-only planning document**. No files have been changed.
> Please choose an approach for each issue before I start coding.

---

## How the System Currently Works

The project has **two conceptually separate "speed" knobs** that exist today, which is the root of your confusion and the bugs.

| Knob | Where set | What it does | Currently sent to backend? |
|---|---|---|---|
| **TTS generation speed** ("default speed" in Settings) | [Settings](file:///home/lightdesk/Projects/LN-TTS/frontend/lib/services/settings_store.dart#5-264) screen → "Default Speed" slider | Instructs Kokoro to synthesize audio slower/faster. Affects pitch + duration of the resulting PCM. This is the "baked-in" speed. | ✅ Yes — sent as the `speed` field in the WebSocket [play](file:///home/lightdesk/Projects/LN-TTS/frontend/lib/screens/reader_screen.dart#263-308) command |
| **Reader playback speed** ("session speed" in Reader tune icon) | Reader → tune icon → "Speed" slider | Should fast-forward the already-playing audio like a YouTube speed button. Currently this calls `setRelativePlaySpeed` on SoLoud… but only during **streaming** — it currently restarts streaming from the current paragraph with the new speed value sent to the backend (re-synthesise). | ❌ Confusingly, this restarts synthesis instead of fast-forwarding |

### Streaming highlight sync (live chapters)

1. Backend synthesises sentence → sends JSON [sentence](file:///home/lightdesk/Projects/LN-TTS/backend/tts.py#140-144) event → sends binary PCM chunk.
2. Frontend queues [(pcm, event)](file:///home/lightdesk/Projects/LN-TTS/frontend/lib/services/novel_stream_controller.dart#657-715) together as [_LiveSentenceChunk](file:///home/lightdesk/Projects/LN-TTS/frontend/lib/services/novel_stream_controller.dart#28-38).
3. [_pumpSentenceAudio()](file:///home/lightdesk/Projects/LN-TTS/frontend/lib/services/novel_stream_controller.dart#237-283) enqueues the PCM into SoLoud and records the start-sample at which the event should fire ([_ScheduledSentence](file:///home/lightdesk/Projects/LN-TTS/frontend/lib/services/novel_stream_controller.dart#39-49)).
4. A 40 ms timer ([_startLiveTimeline](file:///home/lightdesk/Projects/LN-TTS/frontend/lib/services/novel_stream_controller.dart#193-222)) polls `getStreamTimeConsumed()` and fires events as samples are consumed.

**This is already sample-accurate and well-engineered.** The highlight is driven by actual PCM playback position, not a wall-clock estimate.

### Offline highlight sync (downloaded chapters)

1. During download the backend sends [sentence](file:///home/lightdesk/Projects/LN-TTS/backend/tts.py#140-144) events with `ms_start` (milliseconds since start of stream at synthesis speed).
2. These are saved to `meta.json` as a `timeline` array.
3. During offline playback, a 60 ms timer checks `getStreamTimeConsumed()` and fires matching timeline items.

**This is also correct.** The timestamps in the timeline were recorded against the PCM that was synthesised.

---

## Bug 1 — The "Two Speeds" Problem

### Root cause

The Settings speed slider AND the Reader session speed slider both map to the same underlying value (`_effectiveSpeed`) which is passed as the `speed` field to the backend. There is **no separate playback multiplier** that simply fast-forwards already-generated audio.

When you change the Reader speed slider, [_restartFromCurrentParagraph()](file:///home/lightdesk/Projects/LN-TTS/frontend/lib/screens/reader_screen.dart#366-370) is called, which re-opens the WebSocket and tells the backend to re-synthesise from scratch at the new speed. This is correct behaviour when you want a different TTS voice tempo — but it is jarring (gap + re-buffer) and means the user cannot smoothly speed up/slow down like on a podcast player.

### What the user wants

> *Settings speed* = the tempo Kokoro generates at (baked-in render quality).  
> *Reader speed* = live fast-forward multiplier like YouTube 1.5× (audio pitch-corrected or time-stretched by SoLoud).

### Options

#### Option A — Split the two speed knobs cleanly (Recommended ✅)

**Rename things clearly:**
- **Settings → "TTS Render Speed"** — sent to backend as before. Affects Kokoro output.
- **Reader → "Playback Speed"** — calls `SoLoud.setRelativePlaySpeed()` on the current handle, does **not** restart the stream.

**Key changes needed:**

| File | Change |
|---|---|
| [reader_screen.dart](file:///home/lightdesk/Projects/LN-TTS/frontend/lib/screens/reader_screen.dart) | Split `_sessionSpeed` into `_ttsRenderSpeed` (sent to backend) + `_playbackMultiplier` (applied to SoLoud handle). Session settings sheet shows two sliders. Apply multiplier immediately via [setPlaybackSpeed()](file:///home/lightdesk/Projects/LN-TTS/frontend/lib/services/novel_stream_controller.dart#623-631) without restarting. |
| [novel_stream_controller.dart](file:///home/lightdesk/Projects/LN-TTS/frontend/lib/services/novel_stream_controller.dart) | Add [setPlaybackSpeed(double)](file:///home/lightdesk/Projects/LN-TTS/frontend/lib/services/novel_stream_controller.dart#623-631) already exists — but it must also scale the timeline polling rate for **live streaming** (the 40 ms timer compares consumed samples; `setRelativePlaySpeed` changes how fast SoLoud consumes them, so the timeline already stays in sync automatically — no change needed). For **offline**, the `getStreamTimeConsumed()` call also reflects the actual playback rate, so no change needed. |
| [settings_store.dart](file:///home/lightdesk/Projects/LN-TTS/frontend/lib/services/settings_store.dart) / [app_settings_controller.dart](file:///home/lightdesk/Projects/LN-TTS/frontend/lib/services/app_settings_controller.dart) | Add a separate key for "TTS render speed" (can reuse existing `default_speed`) and a new key for "default playback multiplier". |
| **Offline downloads**: When user changes playback multiplier for an offline chapter, call `setRelativePlaySpeed`. The timeline timestamps are based on the natural PCM duration; however `getStreamTimeConsumed()` in SoLoud reflects the **played** position (it accounts for the playback rate), so the timeline advance rate will automatically match. **No re-download needed.** |
| **Important for downloads**: Store `ttsSpeed` in `meta.json` (already done). When loading a download, the playback multiplier slider should show but the TTS render speed slider should show the baked-in value as read-only (greyed out). |

**Pros:** Clean UX, no re-synthesis on speed change, backwards compatible with existing downloads.  
**Cons:** SoLoud's `setRelativePlaySpeed` may cause slight pitch distortion at extremes (>1.5×). Flutter SoLoud does not expose a time-stretch without pitch change.

#### Option B — Keep one speed knob, widen range, remove confusion

Remove the session speed slider from the Reader. One speed in Settings controls Kokoro. This is the simplest approach but loses any ability to fast-forward during playback.

**Pros:** Zero code complexity.  
**Cons:** No fast-forward during live playback.

#### Option C — Reader speed restarts stream (current behaviour, just make it explicit)

Document and keep the current behaviour but improve the UX by showing a "Regenerating…" indicator and reducing the re-buffer time. No architectural change.

**Pros:** Minimal code change.  
**Cons:** Does not solve the fast-forward desire and still has jank on speed change.

---

## Bug 2 — Highlight Sync Problem (the main sync issue)

> "Currently the speed of text highlighting is different to the audio being played."

### Root cause analysis

After inspecting the code carefully:

**For live streaming** — the architecture is *already correct*. The highlight fires at the exact sample-boundary where the PCM chunk was enqueued into SoLoud. There should be *no* drift unless:

1. **`setRelativePlaySpeed` is called on the SoLoud handle after chunks are enqueued.** The `_scheduledLiveSentences` list stores sample counts. If playback is at 1.5×, SoLoud consumes samples 1.5× faster; `getStreamTimeConsumed()` returns real time, and the conversion back to samples (`consumedSamples = (consumedUs * sr) / 1_000_000`) correctly tracks the played position. So in theory this is fine.

2. **The `speed` value sent to the backend currently controls Kokoro tempo** — if set to 0.9, Kokoro generates roughly 10% slower-sounding audio. The PCM duration is correspondingly longer. SoLoud then plays it at 1.0× (natural). This is fine — the highlight fires at the correct real-time position.

3. **Possible real source of the sync bug**: The `ms_start` stored in the [sentence](file:///home/lightdesk/Projects/LN-TTS/backend/tts.py#140-144) event and used for *downloads* is calculated on the **backend** as `cumulative_samples * 1000 / sample_rate` *before* any silence padding is added. But the TCM chunk that gets enqueued includes both the vocal audio AND a silence tail. The silence is correctly accounted for in `cumulative_samples += len(audio_chunk) // 2` (which is incremented *after* sending the chunk). So the next sentence's `ms_start` includes the previous sentence's silence. This is correct.

4. **Most likely real cause of user-perceived sync**: The reader currently treats the session speed slider as a TTS re-render speed (it calls [_restartFromCurrentParagraph](file:///home/lightdesk/Projects/LN-TTS/frontend/lib/screens/reader_screen.dart#366-370) with the new speed sent to backend). But the user is presumably *changing the speed mid-read* expecting to hear the audio change instantly. Instead there is a ~2-4 second lag while re-synthesis happens, during which stale text is highlighted. This gives the perception of desync.

### Options

#### Option A — Use sample-accurate scheduling for offline too (Recommended ✅, but already near-correct)

The offline timeline already uses `getStreamTimeConsumed()` which is real-time-accurate even with playback speed changes. **The offline path is correct.**

**One small improvement**: During offline playback with a playback multiplier != 1.0, the `getStreamTimeConsumed()` returns wall-clock consumed time. The stored [ms](file:///home/lightdesk/Projects/LN-TTS/backend/tts.py#436-448) timestamps in the timeline are at 1× PCM. After setting `setRelativePlaySpeed(2.0)`, the audio plays at 2×, so `getStreamTimeConsumed()` at 1 second of real time = 2 seconds of PCM =consumed 2000 ms of timeline. This means the timeline will correctly advance at 2× when comparing to stored [ms](file:///home/lightdesk/Projects/LN-TTS/backend/tts.py#436-448) values. ✅ Already correct.

**Nothing to fix** for the highlight mechanism itself. The fix is just splitting the speed knobs (Bug 1).

#### Option B — Add debug overlay showing consumed samples vs scheduled samples

This would help diagnose any remaining sync issues after the speed split. Low priority.

---

## Bug 3 — Reader Speed UX / Semantics Confusion

The [_SessionSettingsSheet](file:///home/lightdesk/Projects/LN-TTS/frontend/lib/screens/reader_screen.dart#624-644) currently shows one "Speed" slider that does two different things depending on context (offline → does nothing; online → restarts synthesis). This needs a UX redesign regardless.

### Proposed UX (matches user's stated intent)

| Slider | Label | Where available | What it does |
|---|---|---|---|
| TTS Render Speed | "Voice Speed (TTS)" | Settings screen only | Sent to Kokoro. Requires re-synthesis / re-download. |
| Playback Multiplier | "Playback Speed" | Reader session sheet | Calls `setRelativePlaySpeed`. Instant, no re-synthesis. Works for both live and downloaded. |

**For offline chapters**: The TTS render speed is baked in. Show it as read-only in the session sheet. Change the playback multiplier freely.

---

## Bug 4 — Auto-download uses wrong speed

In [reader_screen.dart](file:///home/lightdesk/Projects/LN-TTS/frontend/lib/screens/reader_screen.dart) line 324:
```dart
final speed = settings.defaultSpeed;
```
Auto-downloads use the **global Settings speed**, ignoring the voice the reader is currently using. This should use `_effectiveSpeed` (the session render speed). This is a minor bug.

---

## Summary of All Changes Needed

### Backend ([server.py](file:///home/lightdesk/Projects/LN-TTS/backend/server.py), [tts.py](file:///home/lightdesk/Projects/LN-TTS/backend/tts.py))
- **No changes needed to highlight/sync logic.** The backend already sends `ms_start`, `char_start`, `char_end`, `chunk_bytes` per sentence.
- **Potentially**: expose the sentence's location as a fraction of the chapter (paragraph index / total) — but this is already done via `paragraph_index` / `sentence_index`.

### Frontend — Key files

| File | What changes |
|---|---|
| [settings_store.dart](file:///home/lightdesk/Projects/LN-TTS/frontend/lib/services/settings_store.dart) | Add `defaultPlaybackMultiplier` key (default 1.0) |
| [app_settings_controller.dart](file:///home/lightdesk/Projects/LN-TTS/frontend/lib/services/app_settings_controller.dart) | Add getter/setter for `defaultPlaybackMultiplier` |
| [reader_screen.dart](file:///home/lightdesk/Projects/LN-TTS/frontend/lib/screens/reader_screen.dart) | Split session speed into two: `_ttsRenderSpeed` (restarts synthesis) + `_playbackMultiplier` (instant via [setPlaybackSpeed](file:///home/lightdesk/Projects/LN-TTS/frontend/lib/services/novel_stream_controller.dart#623-631)). Fix auto-download to use session render speed. |
| [novel_stream_controller.dart](file:///home/lightdesk/Projects/LN-TTS/frontend/lib/services/novel_stream_controller.dart) | Expose [setPlaybackSpeed](file:///home/lightdesk/Projects/LN-TTS/frontend/lib/services/novel_stream_controller.dart#623-631) more prominently (already exists). No logic change needed. |
| [settings_screen.dart](file:///home/lightdesk/Projects/LN-TTS/frontend/lib/screens/settings_screen.dart) | Rename "Default Speed" to "TTS Render Speed" with explanation. |

### Modal server (`/home/lightdesk/Projects/CoreReader-modal`)
- The Modal deploy copies `backend/` files. After any backend changes, it needs to be redeployed: `cd ../CoreReader-modal && modal deploy modal_app.py`.
- The `modal_app.py` itself needs no changes unless the backend API changes.
- The `README.md` in the Modal repo should be updated to explain the two speed concepts.

### README (`/home/lightdesk/Projects/LN-TTS/README.md`)
- Clarify the two speed knobs and how they interact.
- Document "TTS Render Speed" vs "Playback Speed".

---

## Questions for You — Please Choose

### Q1: Speed Architecture (Bug 1 + 3)

- **Option A** ✅ — Split into TTS Render Speed (Settings) + Playback Multiplier (Reader). Instant fast-forward, SoLoud handles pitch.
- **Option B** — Remove session speed slider, one speed controls all.
- **Option C** — Keep current behaviour, just improve UX feedback.

### Q2: Highlight sync (Bug 2)

Based on analysis: **no backend changes needed**. The highlight sync is sample-accurate for both live and offline, and will automatically stay in sync when you change playback multiplier. Do you agree, or is there a specific sync case you are still observing?

### Q3: Modal deploy

After implementing, should I:
- **Option A** — Deploy to Modal automatically as part of the task?
- **Option B** — Just give you the commands to run (the Modal server doesn't need code changes unless the backend API changes)?

### Q4: README update scope

- **Option A** — Update both READMEs (LN-TTS and CoreReader-modal) with new speed knob documentation.
- **Option B** — Just update the main LN-TTS README.

