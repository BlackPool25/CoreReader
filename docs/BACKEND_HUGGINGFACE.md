# Backend: HuggingFace Space (Free)

The easiest way to get a CoreReader backend running — no server, no install, no cost.

A pre-built instance is available at:

**<https://huggingface.co/spaces/shreyas-joshi/CoreReader>**

---

## Option A: Use the existing Space (2 minutes)

1. Visit <https://huggingface.co/spaces/shreyas-joshi/CoreReader>.
2. Wait for the Space to boot (first load may take 1–2 minutes while models download).
3. You should see a status page showing **Status: running** and **TTS Ready: True**.
4. Note the WebSocket URL shown on the page (e.g. `wss://shreyas-joshi-corereader.hf.space`).
5. In the Flutter app, go to **Settings** → **WebSocket base URL** and paste:

   ```
   wss://shreyas-joshi-corereader.hf.space
   ```

That's it. The app will connect to `/ws` automatically.

---

## Option B: Duplicate the Space (your own free instance)

If the shared instance is slow or you want your own:

1. Go to <https://huggingface.co/spaces/shreyas-joshi/CoreReader>.
2. Click the **⋮** menu (top-right) → **Duplicate this Space**.
3. Choose a name (e.g. `my-corereader`), keep it **Public** or **Private**.
4. Click **Duplicate Space**. HuggingFace will build the Docker image and start it.
5. Once the Space is running, your URL will be:

   ```
   wss://<your-username>-<space-name>.hf.space
   ```

6. Paste that into the Flutter app Settings.

---

## Notes

- **Cold starts**: Free HuggingFace Spaces sleep after ~15 min of inactivity. The first request after sleeping takes 30–60 seconds to boot.
- **Performance**: Free Spaces run on shared CPU. TTS synthesis is slower than a local machine but works fine for reading.
- **Persistence**: Models are downloaded on every cold start (cached within a session). This adds ~30s to boot time.
- **Limits**: HuggingFace free tier has no hard request limits, but heavy usage may be throttled.

---

[← Back to README](../README.md)
