# System Architecture — TapKar AI

> Companion document to [`../README.md`](../README.md). Read [`../flow-explainer.html`](../flow-explainer.html) first for a 2-minute animated overview.

## 1. High-level topology

```
┌──────────────────────────────────────────────────────────────────────┐
│  FLUTTER MOBILE APP                                                  │
│  ───────────────────                                                 │
│  • Chat surface (Urdu / Roman Urdu / English)                        │
│  • Native voice input (Urdu STT via Cloud Speech)                    │
│  • Live agent-trace panel — streams reasoning as it happens          │
│  • Booking history + receipts                                        │
└───────────────────────────┬──────────────────────────────────────────┘
                            │ HTTPS  (REST + SSE stream for trace)
                            ▼
┌──────────────────────────────────────────────────────────────────────┐
│  BACKEND  ·  Cloud Run  ·  code authored in Antigravity              │
│  ──────────────────────────────────────────────────────────────────  │
│                                                                      │
│           ┌──────────────────────────────────┐                       │
│           │  ORCHESTRATOR  (Gemini API loop) │                       │
│           │  · plans the workflow            │                       │
│           │  · dispatches subagents          │                       │
│           │  · owns the run trace            │                       │
│           │                                  │                       │
│           │  Implemented as a TypeScript     │                       │
│           │  ReAct-style loop that calls     │                       │
│           │  Gemini API directly. Antigravity│                       │
│           │  is the IDE used to BUILD this   │                       │
│           │  code; runtime depends only on   │                       │
│           │  a Gemini API key.               │                       │
│           └──────┬───────────────────────────┘                       │
│                  │                                                   │
│       ┌──────────┼──────────┬──────────┬──────────┐                  │
│       ▼          ▼          ▼          ▼          ▼                  │
│   ┌───────┐ ┌─────────┐ ┌────────┐ ┌────────┐ ┌──────────┐           │
│   │INTENT │ │DISCOVERY│ │RANKING │ │BOOKING │ │FOLLOW-UP │           │
│   │ AGENT │ │  AGENT  │ │ AGENT  │ │ AGENT  │ │  AGENT   │           │
│   └───┬───┘ └────┬────┘ └───┬────┘ └───┬────┘ └────┬─────┘           │
│       │          │           │          │           │                │
│       ▼          ▼           ▼          ▼           ▼                │
│   ╔══════════════ TOOLS (dumb I/O, ~10 LoC each) ══════════════╗     │
│   ║  detect-language · geocode · search-taxonomy ·             ║     │
│   ║  search-providers · get-availability · get-reviews ·       ║     │
│   ║  create-booking · generate-receipt · send-notification ·   ║     │
│   ║  schedule-reminder · check-status · send-survey            ║     │
│   ╚════════════════════════════════════════════════════════════╝     │
└─────────┬─────────────────┬──────────────────┬───────────────────────┘
          ▼                 ▼                  ▼
     ┌─────────┐      ┌──────────┐      ┌─────────────┐
     │FIRESTORE│      │GOOGLE    │      │CLOUD        │
     │         │      │PLACES API│      │SPEECH-TO-TXT│
     └─────────┘      └──────────┘      └─────────────┘
```

## 2. Component responsibilities

### 2.1 Orchestrator Agent
- Top-level agent. Implemented as a **TypeScript ReAct-style loop in our backend** that uses `backend/src/agents/orchestrator.agent.md` as the system prompt for a Gemini API call. **Not** an Antigravity runtime agent — the deployed product has zero Antigravity dependency, only a Gemini API key.
- Owns the run lifecycle.
- Receives the user message, plans which subagents to invoke and in what order.
- The sequence is **not hardcoded** — orchestrator reasons. If the user changes their mind mid-flow ("actually nevermind, cancel that"), the orchestrator routes to cancellation, not a fixed pipeline.
- Writes to `traces/{run_id}` in Firestore continuously so the mobile app can stream it.

### 2.2 Intent Agent
- Parses the user message in its native language (no translate-then-parse — direct extraction).
- Outputs structured intent: `{service, location, time, urgency, preferences, language}`.
- Tools: `detect-language`, `geocode`, `extract-entities`.

### 2.3 Discovery Agent
- Finds candidate providers near the user.
- Tools: `search-taxonomy`, `search-providers` (mock + Firestore), `places-api`.
- Returns candidate list with provider profiles.

### 2.4 Ranking Agent
- Decides who to recommend. **Pure reasoning over candidate JSON** — no scoring formula in code.
- Reads `ranking_weights` per category from `taxonomy.json` as guidance, but the LLM ultimately decides how to weigh signals based on the user's expressed preferences.
- Returns top 3 with per-candidate `reasoning` strings.

### 2.5 Booking Agent
- Confirms the booking and persists it.
- Tools: `create-booking`, `generate-receipt`, `send-confirmation`.
- Writes `bookings/{id}` to Firestore. Triggers confirmation messages in the user's language.

### 2.6 Follow-up Agent
- Decides what follow-ups make sense (reminder timing, status checks, survey).
- Tools: `schedule-reminder`, `check-status`, `send-survey`.
- Writes scheduled jobs that fire later (Firestore TTL or in-app scheduler — not Cloud Scheduler in the 4-day window).

### 2.7 Voice mode (Gemini Live)
- Optional second entry point — full-duplex voice in addition to the chat surface.
- Mobile opens a WebSocket to `/voice/live` on the same Cloud Run instance.
- The bridge ([`backend/src/voice-live.ts`](../backend/src/voice-live.ts)) opens a per-client Gemini Live session and forwards 16 kHz PCM in / 24 kHz PCM out.
- The Live model is configured with **a single tool**, `book_a_service`. When the user states what/where/when, the model calls that tool with the full request as a string; the bridge runs the 5-agent orchestrator described above and returns the booking outcome. The model then narrates the result in the user's language.
- Architectural consequence: voice mode does **not** replace the agent pipeline. It adds a real-time interaction layer on top of it. The trace panel keeps updating because `agent_step` events stream through the same WebSocket alongside audio chunks.

## 3. Anti-monolithic guarantee

The hackathon brief explicitly forbids "monolithic" architectures with hardcoded business logic. This system satisfies the rule by **never letting code decide anything that an agent could decide**:

### What's in the LLM
- What language is this?
- What service does the user want?
- Which provider is best for this user, *for this request*?
- Should we auto-pick or let the user choose?
- How should we phrase the confirmation in Urdu?
- When should follow-ups fire?

### What's in the tools (deterministic, no logic)
- `search-providers({filters})` → reads Firestore / Places API and returns JSON
- `geocode(text)` → calls Google Geocoding and returns lat/lng
- `create-booking(...)` → writes a Firestore doc
- `send-notification(to, msg)` → writes to a mock inbox doc

**There is no `rankProviders()`, `matchCategory()`, `pickBestTime()`, or `if (urgency === 'high') ...` anywhere in the codebase. Adding a new service category requires zero code changes — it's a row in [`../data/taxonomy.json`](../data/taxonomy.json).**

## 4. Trace log shape

Every agent run writes a single document under `traces/{run_id}`:

```ts
{
  run_id: string,
  user_input: string,
  started_at: Timestamp,
  ended_at: Timestamp | null,
  status: 'running' | 'complete' | 'failed',
  steps: Array<{
    agent: 'orchestrator' | 'intent' | 'discovery' | 'ranking' | 'booking' | 'followup',
    reasoning: string,        // LLM's explanation in plain language
    tools_called: Array<{
      name: string,
      input: any,
      output: any,
      ms: number
    }>,
    output: any,
    ms: number,
    ts: Timestamp
  }>,
  result: {
    booking_id?: string,
    status: 'matched' | 'no_providers' | 'user_cancelled' | ...
  }
}
```

The mobile app subscribes to this doc via Firestore real-time listeners and renders steps as they stream in.

## 5. Service taxonomy

Single source of truth for everything category-related: [`../data/taxonomy.json`](../data/taxonomy.json).

Used by:
- Intent agent (for category disambiguation + multilingual synonyms)
- Discovery agent (for Places API `type` mapping + keyword expansion)
- Ranking agent (for default weight hints)
- Mobile app (for category icons / labels)

Three tiers:
- **Tier 1** (6 categories): scripted demos, rich mock data, category-tuned ranking
- **Tier 2** (~20 categories): mock data + multilingual vocab, default ranking
- **Tier 3** (open domain): fallback via Places API for anything not in the taxonomy

## 6. Multilingual handling

| Input language | Strategy |
|---|---|
| English | Direct LLM parse |
| Roman Urdu | Direct LLM parse with few-shot Roman Urdu examples in prompt |
| Urdu (Nastaliq) | Direct LLM parse — Gemini and Claude both handle native Urdu well |
| Code-switched (mixed) | Direct LLM parse — works because we never translate first |

**Key principle: we never translate-then-parse.** Translation drops urgency cues, register, and intent nuance (e.g. "achha wala banda" = "send a quality person" — translation would say "send a good man" and lose the meaning).

## 7. Firestore schema

```
users/{uid}
  · name, phone, default_location, language_preference

providers/{provider_id}
  · name, category, lat, lng, rating, jobs_completed,
    availability, languages, price_range, verified

bookings/{booking_id}
  · user_id, provider_id, service, time, status,
    created_at, confirmed_at, completed_at

traces/{run_id}
  · user_id, user_input, steps[], result, started_at, ended_at

scheduled_jobs/{job_id}
  · booking_id, fire_at, type, payload, status
```

## 8. External APIs

| API | Purpose | Quota plan |
|---|---|---|
| Google Places API | Open-domain provider discovery (Tier-3 fallback) | Hackathon credits — cache aggressively in Firestore |
| Google Geocoding API | Convert "Gulshan" → lat/lng | Cached static map for known neighborhoods |
| Cloud Speech-to-Text | Urdu voice input | Mobile streams audio chunks |
| Gemini / Claude (via Antigravity) | All agent reasoning | Native via Antigravity |

## 9. Demo-day safety

To avoid live-demo failures:
- Mock data path always available (env flag `USE_REAL_PLACES=false`)
- Three scripted scenarios in "Demo Mode" dropdown
- Recorded backup video in case network fails
- Offline trace replay mode (replays a saved trace doc)

## 10. What's intentionally NOT here (cut to fit 4 days)

- Real WhatsApp/Twilio integration — chat UI is in-app
- Payment integration — booking is simulated per the brief
- Multi-tenant provider auth — judges don't care for MVP
- Production deployment infra — Cloud Run preview is fine
- Test suite beyond happy-path manual checks
