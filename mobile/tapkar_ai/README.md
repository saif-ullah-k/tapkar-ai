# TapKar AI — Mobile (Flutter)

> *"Bas tap karo — AI sab kar dega."*
> *Just tap. The AI does everything.*

The user-facing surface of TapKar AI — the **mandatory** submission deliverable for the AI SEEKHO Phase 2 Hackathon.

## Build & run

```bash
# 1. Backend running locally (port 8080)
cd ../../backend && npm run dev

# 2. Find your machine's LAN IP (for physical device testing)
ipconfig | findstr IPv4
# e.g. 192.168.1.42

# 3. Get dependencies
flutter pub get

# 4a. Run on Android emulator (uses 10.0.2.2 to reach host)
flutter run --dart-define=API_URL=http://10.0.2.2:8080

# 4b. Run on physical Android device (same Wi-Fi as your laptop)
flutter run --dart-define=API_URL=http://192.168.1.42:8080

# 5. Build a release APK
flutter build apk --release --dart-define=API_URL=http://192.168.1.42:8080
# Output: build/app/outputs/flutter-apk/app-release.apk
```

## What works

- WhatsApp-style chat with right/left bubbles, RTL for Urdu
- Native voice input (mic button), Urdu STT via `speech_to_text`
- Live agent-trace panel — each agent step animates in as the backend streams
- Booking confirmation card with provider, time, location, follow-ups
- Multilingual font handling: Noto Nastaliq Urdu (RTL) for Urdu, Inter for everything else
- Welcome screen with one-tap example prompts (mixed languages)

## Required Android permissions

These are added to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.BLUETOOTH"/>
```

Plus `<application android:usesCleartextTraffic="true">` so debug builds can talk to `http://` backends on LAN.

## Files

- `lib/main.dart` — entry point, creates AppState
- `lib/state/app_state.dart` — ChangeNotifier for chat + traces + bookings
- `lib/services/api.dart` — SSE client for `/run`, fetcher for `/traces/:id`
- `lib/services/voice.dart` — Urdu STT wrapper
- `lib/screens/chat_screen.dart` — main UI; trace panel on wide screens, bottom sheet on phones
- `lib/widgets/` — chat bubble, trace card, booking card, mic button
- `lib/theme.dart` — colors, fonts, agent-accent palette

## Day 2 acceptance

1. App opens on Android phone or emulator
2. Type or speak "kal subah Gulshan mein plumber chahiye, paani leak ho raha hai"
3. Send — trace panel animates: intent → discovery → ranking → booking → followup
4. Booking card appears with provider name, time, and Roman Urdu follow-up reminders
5. Tap any trace card to expand its reasoning
