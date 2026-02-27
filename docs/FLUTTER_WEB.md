# Flutter Web Notes

`flutter_soloud` on Web requires special setup for WASM + SharedArrayBuffer support.

---

## Required Script Tags

This repo already includes the required scripts in `frontend/web/index.html`:

```html
<script src="assets/packages/flutter_soloud/web/libflutter_soloud_plugin.js"></script>
<script src="assets/packages/flutter_soloud/web/init_module.dart.js"></script>
```

---

## Cross-Origin Isolation Headers

Web browsers require **COOP/COEP headers** for `SharedArrayBuffer` (used by SoLoud's WASM module).

### Development

```bash
flutter run -d chrome --web-port 3000 \
  --web-header="Cross-Origin-Opener-Policy=same-origin" \
  --web-header="Cross-Origin-Embedder-Policy=require-corp"
```

### Production

Configure your web server to send:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

---

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `_createWorkerInWasm` | Missing COOP/COEP headers | Add the headers above |
| `SharedArrayBuffer is not defined` | Same as above | Add the headers above |
| Audio doesn't play | SoLoud WASM not loaded | Check DevTools → Network for the two script files |

---

## WebSocket URL

If the web app is served over `https://`, use `wss://` (secure WebSocket).
If running over plain `http://` (dev), `ws://` works.

---

[← Back to README](../README.md)
