# Day 4 — Gemini Live (Option A) build

**Date:** 2026-05-20 (final submission day)
**Status:** ✅ Code complete, local E2E green, Cloud Run redeploy in flight

## Goal

Add a real-time voice mode on top of the existing chat product:

- Full-screen "voice orb" UI in the mobile app (Gemini-app style).
- WebSocket bridge `/voice/live` on the backend that connects each client to a Gemini Live session.
- Live model uses a single `book_a_service` tool — the tool's implementation **invokes our existing 5-agent orchestrator**, so the agent trace + booking events stream back to the mobile alongside audio.

This preserves the agentic architecture (5 agents — intent, discovery, ranking, booking, follow-up) while giving the demo a wow-factor voice UX.

## Architecture

```
┌──────────────┐    /voice/live (WSS)   ┌────────────────────────┐    Live API    ┌──────────────┐
│ Voice screen │ ◀────────────────────▶ │  voice-live.ts bridge  │ ◀────────────▶ │ Gemini Live  │
│  (Flutter)   │   16k PCM / 24k PCM   │  (per-client session)  │                │ native audio │
│  • orb UI    │   JSON frames         │                        │                └──────────────┘
│  • mic→WS    │                       │   tool: book_a_service │
│  • WS→player │                       │   ↓                    │
└──────────────┘                       │   runPipeline()        │   ┌────────────────────────────┐
                                       │   ↓                    │ → │  Existing 5-agent pipeline │
                                       │   stream agent_step    │   │  intent → discovery →      │
                                       │   events back to       │   │  ranking → booking →       │
                                       │   client during call   │   │  follow-up                 │
                                       └────────────────────────┘   └────────────────────────────┘
```

**Key design point:** the Live model doesn't replace our agents. It's a voice-first interaction layer that delegates to the agents via a single tool. The existing chat product is untouched.

## Files

### Backend (new)
- `backend/src/voice-live.ts` — WebSocket bridge.
  - `attachLiveVoice(httpServer)` — adds `noServer` WSS, handles `upgrade` only for `/voice/live`.
  - Per-connection state: `session`, `userId`, `language`, `userGender`.
  - Client frames: `auth | audio | text | close`.
  - Server frames: `audio | transcript | tool_call | tool_result | agent_step | ready | error | turn_complete`.
  - Voice picked per user gender (Puck/Aoede) matching our gender-aware TTS strategy elsewhere.
  - System prompt enforces Urdu/Roman-Urdu/English language matching + booking-intent extraction.
  - Forced AI Studio mode (apikey) — Vertex Live model coverage is patchy by region.
- `backend/test-live.mjs` — Node test client. Sends an Urdu booking request, expects `ready` + `tool_call` + `agent_step` events + `turn_complete`.

### Backend (modified)
- `backend/src/index.ts` — wires `attachLiveVoice(httpServer)` after `app.listen` completes.
- `backend/package.json` — `ws@^8.20.1`, `@types/ws@^8.18.1`.
- `deploy.sh` — adds `GEMINI_API_KEY=${GEMINI_API_KEY}` to Cloud Run env. Switched `--set-env-vars` to `^|^` delimiter to keep commas-inside-values safe.

### Mobile (new)
- `mobile/tapkar_ai/lib/screens/voice_live_screen.dart` — full-screen voice UI.
  - `_BotState` enum: connecting | listening | thinking | speaking | error.
  - Animated sweep-gradient orb that pulses based on bot state.
  - 16 kHz PCM mic capture via `record` package, base64-chunked over WS.
  - 24 kHz PCM playback via `audioplayers` — buffered per turn, wrapped in a RIFF/WAV header at `_flushAudio`.
  - Mic auto-pauses while bot is speaking (avoids echo loop).
  - Forwards `agent_step` events through `AppState.handleVoiceLiveStep` so the trace panel + booking card still update.

### Mobile (modified)
- `mobile/tapkar_ai/lib/screens/chat_screen.dart` — `graphic_eq` action button in app bar pushes `VoiceLiveScreen`.
- `mobile/tapkar_ai/lib/state/app_state.dart` — `handleVoiceLiveStep(sseEvent)` mirrors the SSE handler so voice-mode agent traces feed the same UI plumbing as chat-mode SSE events.
- `mobile/tapkar_ai/pubspec.yaml` — `record: ^6.2.0`, `web_socket_channel: ^3.0.3`.

## Local E2E test

```
$ WS_URL=ws://localhost:8080/voice/live node backend/test-live.mjs

[+0.0s] socket open
[+0.5s] <- ready [listening]
[+1.0s] -> text: salaam, mujhe kal subah Gulshan mein plumber chahiye, paani leak ho raha hai
[+1.8s] <- tool_call [thinking]: book_a_service
[+12.6s] <- agent_step      (intent)
[+27.5s] <- agent_step      (discovery)
[+27.5s] <- agent_step      (ranking)
[+40.0s] <- agent_step      (booking — bk_xxxx, status=confirmed)
[+40.0s] <- agent_step      (followup)
[+40.0s] <- tool_result [speaking]
[+55.0s] <- turn_complete [listening]
[+56.6s] closed code=1005

=== SUMMARY ===
Counts: { audio: 81, tool_call: 1, agent_step: 6, transcript: 0, turn_complete: 1, error: 0, ready: 1 }
Audio bytes received: 677764
✅ PASS connection healthy
```

End-to-end works:
- WS upgrade + auth ✓
- Gemini Live correctly identified booking intent from Roman-Urdu text and called the tool with the full user request as `user_request` ✓
- 5-agent pipeline ran inside the tool, 6 `agent_step` events fired ✓
- Tool response narrated back as 81 audio chunks (~677 KB at 24 kHz) ✓
- Turn closed cleanly, zero errors ✓

## Known characteristics

- **Latency:** ~25 s from tool-call to tool-result (the orchestrator itself). This is the existing pipeline's latency, not Live overhead. Acceptable for the demo; flagged for a "bot says 'thoda intezar karein' while running" UX hint (handled by the system prompt).
- **Audio playback model:** per-turn buffering + WAV-wrap, not realtime streaming. Simpler, no audio glitches, slightly higher latency to first sound (~1–2 s after turn_complete). Real-time PCM playback was deferred to keep scope tight.
- **Mic gating:** mic auto-pauses while playing back the bot's voice. Otherwise the bot's voice loops back into the model. Resumes on `onPlayerComplete`.

## Bug found & fixed during smoke test (2026-05-20 15:14 PKT)

Symptom on first APK install: voice screen entered error state — `Voice unavailable / socket closed`. Cloud Run log showed:

```
[live] session closed: code=1007 reason=realtime_input.media_chunks is deprecated. Use audio, video, or text instead.
```

Root cause: `voice-live.ts` used the deprecated `sendRealtimeInput({ media: { … } })` shape. The `media` field translates to `media_chunks` on the wire, which the server has retired for audio payloads.

The `test-live.mjs` harness missed this because it only sent a `text` frame — never an `audio` frame — so the deprecated path was never exercised in tests. Local tests passed; production failed the moment the phone sent its first PCM chunk.

Fix:
- `voice-live.ts:347` — switched to `sendRealtimeInput({ audio: { data, mimeType: 'audio/pcm;rate=16000' } })`.
- `test-live.mjs` — now sends a 1 s silent 16 kHz PCM frame before the text turn, so this deprecation regression can't reach prod again unnoticed.

Re-tested locally (audio frame goes through, tool fires), redeployed, re-tested against Cloud Run (39 audio chunks back, 0 errors), reinstalled APK on emulator, reopened voice screen — orb now reads "Listening — start talking", no error.

## What's still TODO today

1. Cloud Run redeploy with `GEMINI_API_KEY` in env (in flight)
2. Re-test `test-live.mjs` against production URL
3. Build a new release APK with the voice screen + new dart-define
4. Update GitHub release v0.1.1 with new APK
5. README + SUBMISSION.md updates noting the voice mode
6. Screen recording of the Antigravity native agent doing real planning work on this feature (deliverable #4)
