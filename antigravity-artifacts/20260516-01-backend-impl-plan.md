# Backend Implementation Plan — Day 1

**Date:** 2026-05-16
**Author:** Antigravity IDE (Claude Code extension)
**Scope:** Cloud-Run-deployable Express service implementing the TapKar AI agent loop.

> **Compliance note (per organizer clarification 2026-05-16):** Antigravity is the development IDE only. The deployed backend is plain Node.js + TypeScript and depends on a Gemini API key — *not* on Antigravity at runtime.

---

## 1. Goal

Implement a working backend that:

1. Accepts a natural-language user message via `POST /run`
2. Runs a custom TypeScript orchestrator loop that dispatches 5 subagents (intent, discovery, ranking, booking, follow-up) by calling the Gemini API once per agent decision
3. Streams every reasoning step as Server-Sent Events to the mobile client
4. Persists the full trace to Firestore (with in-memory fallback so Day 1 works without GCP)
5. Returns a confirmed booking + scheduled follow-ups
6. Honors the anti-monolithic rule: **zero business logic outside `.agent.md` prompts**

## 2. File layout (target state)

```
backend/src/
├── index.ts                # Express app, /run endpoint, SSE wiring
├── config.ts               # Env-var loading + validation
├── data.ts                 # Loads taxonomy + providers JSON once at boot
├── store.ts                # Firestore wrapper w/ in-memory fallback
├── gemini.ts               # Gemini client + runAgent(name, state) helper
├── orchestrator.ts         # ReAct loop, yields trace steps as it goes
├── types.ts                # (exists)
├── agents/                 # (exists — 6 .agent.md system prompts)
└── tools/
    ├── index.ts            # Re-exports + Gemini-function-declaration registry
    ├── geo.ts              # detect_language, geocode, distance_km
    ├── taxonomy.ts         # read_taxonomy, search_taxonomy
    ├── providers.ts        # search_providers, filter_by_*, get_reviews, capacity
    ├── places.ts           # places_*_search (stubs returning [] when USE_REAL_PLACES=false)
    ├── bookings.ts         # create/get/update_booking, generate_receipt
    ├── notifications.ts    # send_notification, send_user_message
    ├── scheduling.ts       # schedule_job, cancel_scheduled_jobs, list_due_jobs
    └── trace.ts            # start_trace, write_trace_step, end_trace
```

## 3. Key design decisions

| Decision | Choice | Why |
|---|---|---|
| Agent runtime | Custom TypeScript ReAct loop, one Gemini API call per agent decision | Compliance — Antigravity is not in the runtime |
| LLM SDK | `@google/genai` v0.5+ with native function calling | Cleanest tool binding; no JSON parsing |
| Default model | `gemini-2.5-pro` (configurable per agent via env) | Best reasoning/cost balance; switch to flash for speed |
| Persistence | Firestore if `GCP_PROJECT` is set; in-memory `Map<>` otherwise | Day 1 must work without GCP setup |
| Streaming | Server-Sent Events from Express | Simplest mobile-friendly streaming; standard MIME `text/event-stream` |
| Validation | `zod` schemas on `/run` request body | Already in package.json |
| Mock-vs-real Places | `USE_REAL_PLACES=false` default → return `[]` from places_*_search; mock providers cover demo flows | Don't burn GCP credits on Day 1 |
| Conversation state | One-shot per `/run` for Day 1; ranking-agent `auto_pick` mode skips user confirmation | Demo runs end-to-end without back-and-forth |

## 4. Orchestrator loop (sketch)

```
async function* runOrchestrator(input):
  state = { user_input, intent: null, candidates: null, ranked: null, booking: null }
  run_id = start_trace(input)
  yield {step: 'run_started', run_id}

  while not state.completed and steps < MAX_STEPS:
    decision = await callGemini(
      systemPrompt: load('agents/orchestrator.agent.md'),
      userPrompt: JSON.stringify(state),
      functionDecls: [dispatch_subagent, send_user_message, complete],
    )
    yield {agent: 'orchestrator', reasoning: decision.thinking, ...}

    switch decision.action:
      case dispatch_subagent:
        result = await runSubagent(decision.subagent_name, state)
        yield {agent: decision.subagent_name, ...}
        state[decision.subagent_name] = result
      case send_user_message:
        yield {user_message: decision.text}
        // Day 1: if ranking auto-picked, no user wait — proceed
      case complete:
        state.completed = true

  end_trace(run_id, {status: state.completed ? 'complete' : 'timeout'})
```

## 5. Anti-monolithic guarantees

- **No `if (category === 'plumber')`** anywhere — ranking weights live in `taxonomy.json`, the LLM reads them and decides.
- **No scoring formula in code** — `ranking.agent.md` produces scores; code only transports them.
- **No hardcoded sequence** — orchestrator's next action is chosen by Gemini, not by a switch in code.
- **Tools are pure I/O** — `search_providers()` takes exact filters and reads files/DB. Decisions about *which* filters live in agents.

Any reviewer can `grep -E "if.*(category|urgency|service) ===" backend/src` and find zero matches.

## 6. Verification (Day 1 acceptance test)

```bash
cd backend
npm install
GEMINI_API_KEY=... npm run dev   # listens on :8080

# In another shell:
curl -N -X POST http://localhost:8080/run \
  -H "Content-Type: application/json" \
  -d '{"user_id":"u_demo","user_input":"kal subah Gulshan mein AC theek karwana hai, achha wala banda bhejo"}'
```

Expected: SSE stream emitting ~6 trace steps (orchestrator → intent → discovery → ranking → booking → follow-up) over ~15s, ending with a `result` event containing a `booking_id`. Trace stored in `traces/{run_id}` (Firestore or memory).

## 7. Open items (Day 2+)

- Real Places API integration behind the `USE_REAL_PLACES=true` flag
- Conversation state for multi-turn (user confirmation step)
- Cloud Run deployment manifest
- Authentication (HMAC-signed user IDs from mobile)
- Rate limiting

## 8. Risk log

| Risk | Mitigation |
|---|---|
| Gemini capacity 503s (witnessed today) | Retry with exponential backoff; auto-fallback to `gemini-2.5-flash` if Pro is exhausted |
| Output token limits on huge JSON | Per-agent output schemas keep responses bounded; orchestrator carries lightweight state |
| Firestore not set up | In-memory fallback active by default |
| Time pressure | Mock-only mode is the default; real Places API is opt-in |
