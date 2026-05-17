# TapKar AI Mobile App (Flutter)

User-facing surface — the **mandatory** submission deliverable. WhatsApp-style chat, native Urdu voice input, live agent-reasoning panel, booking history.

## Day 2 setup (in Antigravity)

This directory will be initialized with `flutter create` on Day 2. Before that runs, prompt Antigravity:

> Generate an implementation plan for the TapKar AI Flutter mobile app. Read `../docs/architecture.md` for system design, `../flow-explainer.html` for the UX storyboard, `../backend/src/agents/*.agent.md` for the API contract, and `../backend/src/types.ts` for data shapes. The app needs:
>
> - WhatsApp-style chat screen (left bubble for assistant, right bubble for user)
> - Native voice input button with Urdu STT (`flutter_speech_to_text` plugin, `lang: ur-PK`)
> - Live agent-trace side panel (collapsible cards per agent step, streams from the backend via SSE)
> - Booking confirmation card UI
> - Booking history screen
> - Multilingual rendering — Noto Nastaliq Urdu font for Urdu text (RTL), Inter for Roman Urdu / English
>
> Target: Android + iOS via single codebase. Backend URL configurable via `--dart-define=API_URL=...`.

Save the plan to `../antigravity-artifacts/YYYYMMDD-NN-mobile-bootstrap-plan.md`.

## Project layout (after `flutter create`)

```
mobile/
├── lib/
│   ├── main.dart
│   ├── screens/
│   │   ├── chat_screen.dart
│   │   ├── trace_panel.dart
│   │   ├── booking_confirmation.dart
│   │   └── history_screen.dart
│   ├── services/
│   │   ├── api.dart              # backend client
│   │   ├── voice.dart            # STT wrapper
│   │   └── trace_stream.dart     # SSE listener
│   ├── models/                   # ports of ../backend/src/types.ts
│   └── widgets/
│       ├── chat_bubble.dart
│       ├── trace_card.dart
│       └── ...
├── android/
├── ios/
├── pubspec.yaml
└── ...
```

## Key dependencies (pubspec.yaml)

- `flutter_speech_to_text` — native Urdu STT
- `flutter_tts` — optional, for voice confirmations
- `http` / `dio` — backend client
- `eventflux` or `sse_client` — server-sent events for live trace
- `flutter_localizations` — Urdu locale
- `google_fonts` — Noto Nastaliq Urdu, Inter

## Demo mode

The app should have a "Demo Mode" dropdown in settings with 3 scripted scenarios that always work, in case the live demo network fails. Each scenario plays a pre-canned trace + booking flow.

## Acceptance criteria

- Voice input in Urdu works on a real Android device
- Urdu text renders correctly in Noto Nastaliq
- Trace panel updates as backend streams steps
- Booking confirmation appears with correct receipt
- APK can be installed via `flutter build apk --release` + upload to Firebase App Distribution
