# Frontend Build

Build prerequisites and platform-specific troubleshooting.

---

## Prerequisites

- [Flutter](https://docs.flutter.dev/get-started/install) (stable channel)
- For Android: Android SDK + NDK (via Android Studio or `sdkmanager`)
- For Linux desktop: system libraries (see below)
- For Web: Chrome (for development)

---

## Install and Run

```bash
cd frontend
flutter pub get
flutter run
```

Flutter will auto-detect available targets (Android device, Linux desktop, Chrome).

---

## Linux Desktop

### Missing LLVM linker

If `flutter run -d linux` fails with:

```
Failed to find any of [ld.lld, ld] in LocalDirectory: '/usr/lib/llvm-18/bin'
```

Install the required packages (Ubuntu 24.04):

```bash
sudo apt update
sudo apt install -y lld-18 llvm-18 clang-18 cmake ninja-build pkg-config libgtk-3-dev
```

---

## Android

### Connecting to the backend

- On your phone, set **WebSocket base URL** in Settings to your PC's LAN IP:
  ```
  ws://192.168.x.x:8000
  ```
- Ensure your PC firewall allows inbound TCP port 8000.

### Release build

```bash
cd frontend
flutter build apk --release
```

The APK will be at `build/app/outputs/flutter-apk/app-release.apk`.

---

## Local Persistence

The app stores the following in SharedPreferences:
- Backend server URL, theme mode, reader font size
- Default voice, default TTS speed
- Chapter filter/sort/display preferences (tri-state filters, sort order, grid/list, column count)
- Library novels (name + URL)
- Cached chapter lists per novel
- Reading progress and read/unread history

---

[← Back to README](../README.md)
