# Day 2 — Flutter Mobile App Implementation Plan

**Date:** 2026-05-17
**Scope:** TapKar AI Flutter mobile app — the mandatory submission deliverable.

## 1. Goal

A working Flutter Android app that:

1. Presents a WhatsApp-style chat interface
2. Accepts voice input in Urdu / Roman Urdu / English
3. Streams the live agent trace from the backend via SSE
4. Shows booking confirmation + scheduled follow-ups
5. Displays history of past bookings
6. Renders Urdu text correctly (Noto Nastaliq Urdu font)

## 2. Stack

| Layer | Choice | Why |
|---|---|---|
| Framework | Flutter 3.41.9 stable | Google's mobile framework; signal for a Google hackathon |
| Language | Dart | Flutter native |
| State management | `provider` package (or `riverpod`) | Simple, no boilerplate |
| Voice STT | `speech_to_text` plugin | Native Android speech recognition (supports `ur-PK`) |
| HTTP | `http` package | Standard, supports streaming reads |
| SSE | Manual implementation over `http.Client().send()` | No good Flutter SSE library; ~30 lines of code |
| Storage | `shared_preferences` | Persist booking history locally |
| Fonts | `google_fonts` — Noto Nastaliq Urdu + Inter | Multilingual rendering |
| Icons | `lucide_icons` or built-in Material | — |

## 3. File layout

```
mobile/tapkar_ai/
├── lib/
│   ├── main.dart                    # App entry
│   ├── theme.dart                   # Colors, typography
│   ├── models/
│   │   └── types.dart               # Mirrors of backend types
│   ├── services/
│   │   ├── api.dart                 # /run SSE client, /traces/:id, /healthz
│   │   ├── voice.dart               # Urdu STT wrapper
│   │   └── storage.dart             # SharedPreferences booking history
│   ├── state/
│   │   └── app_state.dart           # ChangeNotifier for chat + traces + bookings
│   ├── screens/
│   │   ├── chat_screen.dart         # Main chat + trace side panel
│   │   ├── history_screen.dart      # Past bookings list
│   │   └── settings_screen.dart     # Language preference, demo mode
│   └── widgets/
│       ├── chat_bubble.dart         # User + assistant bubble variants
│       ├── voice_input_button.dart  # Mic with animation
│       ├── trace_card.dart          # One agent step in trace panel
│       ├── trace_panel.dart         # Scrollable list of trace_cards
│       ├── booking_card.dart        # Booking confirmation receipt
│       └── language_chip.dart       # "ur" / "en" / "roman_ur" indicator
├── android/                         # Android config (auto-generated)
├── pubspec.yaml                     # Dependencies
└── README.md
```

## 4. Backend API contract (already exists)

| Endpoint | Method | Purpose |
|---|---|---|
| `POST /run` | SSE stream | Send user message, receive agent steps live |
| `GET /traces/:run_id` | JSON | Fetch a completed run trace |
| `GET /healthz` | JSON | Server status |

Backend URL: configurable via `--dart-define=API_URL=http://10.0.2.2:8080` (Android emulator localhost mapping) or `--dart-define=API_URL=http://<phone-LAN-ip>:8080` for physical device.

## 5. UX flow

```
1. App opens → ChatScreen
2. User taps mic, speaks "kal subah Gulshan mein plumber chahiye"
3. Voice → text → user message bubble appears
4. POST /run, SSE stream starts
5. Trace panel (right side or bottom sheet) animates each agent step:
     - intent extracts service + location + time
     - discovery finds candidates
     - ranking picks top
     - booking creates bk_xxxxx
     - followup schedules 4 reminders
6. Booking card slides in with receipt
7. History updates
```

## 6. Multilingual handling

- App UI labels in 3 languages; default to user's last-detected language
- Urdu text uses `font: 'NotoNastaliqUrdu'` + `textDirection: TextDirection.rtl`
- Roman Urdu and English use `Inter` font + LTR
- Voice STT: locale switchable (`ur-PK`, `en-PK`, fallback `en-US`)

## 7. Day 2 acceptance test

```bash
# Backend running:
cd backend && npm run dev

# Build & install Flutter app on connected Android device:
cd mobile/tapkar_ai
flutter pub get
flutter run --dart-define=API_URL=http://<lan-ip>:8080

# OR build APK for sideloading:
flutter build apk --release --dart-define=API_URL=http://<lan-ip>:8080
# Output: build/app/outputs/flutter-apk/app-release.apk
```

Acceptance:
- App installs and opens on physical Android device
- User can tap mic, speak in Urdu, see text appear in input field
- Tap send → live trace panel animates 5 steps
- Booking confirmation card appears at end
- History tab shows the booking

## 8. Hackathon submission tie-in

This satisfies deliverable #1 (Mobile app link) by producing an installable APK. Hosting options:
- Firebase App Distribution (recommended)
- Google Drive direct download link
- Play Store internal test track

## 9. Out of scope for Day 2

- iOS build (deliverable only requires "mobile" — Android is sufficient)
- Provider-side app
- Push notifications
- Authentication (assume single demo user)
- Online maps display
- Booking cancellation flow
