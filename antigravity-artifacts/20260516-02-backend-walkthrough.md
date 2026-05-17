# Backend Build Walkthrough — Day 1

**Date:** 2026-05-16
**Authored by:** Antigravity IDE (Claude Code extension session)
**Companion to:** [20260516-01-backend-impl-plan.md](./20260516-01-backend-impl-plan.md)

This document narrates what Antigravity did, in what order, and why — the IDE's reasoning-trace artifact for hackathon deliverable #6.

---

## Pre-work read

Before writing any code, Antigravity read these files to load full context (~3500 tokens):

| File | Why |
|---|---|
| `README.md` | Brand + positioning |
| `docs/architecture.md` | Anti-monolithic rule (CRITICAL) |
| `backend/src/agents/orchestrator.agent.md` | Top-level agent spec |
| `backend/src/agents/{intent,discovery,ranking,booking,followup}.agent.md` | Subagent specs |
| `backend/src/tools/index.ts` | Tool declarations (signatures only) |
| `backend/src/types.ts` | Shared types |
| `data/taxonomy.json` | Category data shape |
| `data/providers.karachi.json` | Provider data shape |

## Decision log (key choices and rationale)

### D1 — File layout: per-concern modules over single monolith
**Decision:** Split backend into `config.ts`, `data.ts`, `store.ts`, `gemini.ts`, `orchestrator.ts`, `index.ts`, and `tools/index.ts`.
**Reasoning:** Each file has one responsibility. Easier for the Day 2 mobile-side prompt to read and reference. Aligns with the anti-monolithic spirit — code is structured by *what it does* (load data, persist, run LLM, transport, route), not by *what business feature* it serves.

### D2 — In-memory fallback for store
**Decision:** `store.ts` checks `config.useFirestore`; if false, all reads/writes go through `Map<>` collections instead of Firestore.
**Reasoning:** Day 1 must run without GCP setup. The user is still claiming credits and may not have Firestore enabled. The interface is identical, so Day 2 can flip a single env var to upgrade.

### D3 — Gemini native function calling, not custom JSON parsing
**Decision:** Tools are declared as Gemini `FunctionDeclaration`s and exposed via the `tools: [{ functionDeclarations }]` config. The ReAct loop is in `gemini.ts::runAgent()`.
**Reasoning:** Cleaner than asking the model to emit JSON that we then parse. Less brittle. Gemini's function-calling API handles the round-trip serialization. Drops ~80 lines of custom parsing code.

### D4 — Anti-monolithic compliance: zero category-specific code
**Decision:** Tool implementations contain only haversine math (pure geometry, not business logic), exact-match filtering, file I/O, and store I/O. No `if (category === ...)`, no scoring formulas, no priority rules.
**Verification (run this):**
```bash
grep -nE "if.*(category|urgency|service)\s*===" backend/src/**/*.ts
# Expected: zero matches
```

### D5 — `gemini-2.5-pro` as default model
**Decision:** Use `gemini-2.5-pro` for all agents by default; allow per-agent override via `MODEL_INTENT`, `MODEL_DISCOVERY`, etc.
**Reasoning:** Best reasoning/cost balance. Earlier sessions today hit `MODEL_CAPACITY_EXHAUSTED` on Pro variants — the per-agent override env lets Day 2 swap to Flash for high-throughput agents (intent, discovery) and reserve Pro for ranking/orchestrator.

### D6 — Server-Sent Events over WebSocket
**Decision:** `POST /run` streams via SSE (`text/event-stream`). The mobile client subscribes with a streaming HTTP request.
**Reasoning:** One-way server→client is exactly what we need. SSE works through proxies that hate WebSocket. Flutter has clean SSE support via `http`/`dio`. Simpler than WS handshake + framing.

### D7 — Day-1 conversation = one round-trip
**Decision:** No multi-turn user confirmation. Ranking agent's `auto_pick` mode produces a top recommendation that the orchestrator immediately books, then schedules follow-ups, then completes.
**Reasoning:** Demo-friendly. One curl command in, full booking trace out. Multi-turn confirmation lands Day 2 once the mobile UI exists to consume it.

### D8 — Retries for capacity errors
**Decision:** `gemini.ts::withRetry()` catches 503/UNAVAILABLE/CAPACITY/429 with exponential backoff (3 attempts, 800ms / 1.6s / 3.2s).
**Reasoning:** Witnessed `MODEL_CAPACITY_EXHAUSTED` today on both Gemini Pro and Claude Sonnet 4.6 via Antigravity routing. Capacity issues are common during peak hours — backoff lets the run survive transient blips.

## What got built (file-by-file)

| File | Lines | Purpose |
|---|---|---|
| `backend/src/config.ts` | ~60 | Env-var loading, validation, per-agent model resolution |
| `backend/src/data.ts` | ~50 | Cached loaders for `taxonomy.json` + `providers.karachi.json` |
| `backend/src/store.ts` | ~160 | Persistence — Firestore when configured, in-memory otherwise |
| `backend/src/gemini.ts` | ~150 | Gemini client + `runAgent()` ReAct primitive |
| `backend/src/orchestrator.ts` | ~140 | Pipeline loop. Yields `StreamEvent`s. Pure transport. |
| `backend/src/tools/index.ts` | ~480 | All 22 tool implementations + Gemini function declarations + per-agent allowlist |
| `backend/src/index.ts` | ~95 | Express server, SSE wiring, `/run` + `/traces/:id` + `/healthz` |
| `backend/.env.example` | ~25 | Required + optional env vars documented |

## Anti-monolithic audit (self-check)

What the agent prompts decide (lives in `*.agent.md`):
- Which subagent to invoke next
- What service category the user wants
- Which providers to discover and from where
- How to rank candidates (per-user-preference weighting)
- Whether to auto-pick or list options
- What follow-ups make sense for this booking
- All user-facing message wording

What the code does (lives in `*.ts`):
- HTTP routing + SSE framing
- Read JSON files / write Firestore docs
- Call Gemini API
- Filter lists by exact criteria the agent passed in
- Compute distance (math, not a business decision)
- Loop until the orchestrator says "complete"

Zero category names, urgency levels, or service taxonomies appear in any `if` or `switch` statement in the codebase.

## Verification — Day 1 acceptance

Run these in order:

```bash
# 1. Install deps
cd c:\Users\Saifullah\Desktop\Projects\google_challange2\backend
npm install

# 2. Configure
cp .env.example .env
# Edit .env: paste GEMINI_API_KEY=...

# 3. Start the server
npm run dev
# Expected output:
#   [config] No GCP_PROJECT set — using in-memory store (Day 1 mode).
#   [config] USE_REAL_PLACES=false — Discovery uses mock providers only.
#   [data] Loaded taxonomy: 32 categories
#   [data] Loaded providers: 48 seed providers
#   [tapkar-ai] listening on http://localhost:8080

# 4. Smoke test via curl (in another shell)
curl -N -X POST http://localhost:8080/run \
  -H "Content-Type: application/json" \
  -d '{
    "user_id":"u_demo",
    "user_input":"kal subah Gulshan mein AC theek karwana hai, achha wala banda bhejo"
  }'
```

Expected SSE stream (approximate, ~15s total):
```
event: run_started
data: {"run_id":"run_xxx","user_input":"...","started_at":"..."}

event: step
data: {"agent":"orchestrator","reasoning":"new request, route to intent","output":{"next_action":"dispatch_subagent","subagent":"intent",...}}

event: step
data: {"agent":"intent","reasoning":"...","tools_called":[...],"output":{"service":{"category_id":"ac_technician"},...}}

event: step
data: {"agent":"orchestrator", ...}

event: step
data: {"agent":"discovery","output":{"candidates":[...11 candidates...]}}

...

event: step
data: {"agent":"booking","output":{"booking_id":"bk_xxxxx","status":"confirmed"}}

event: step
data: {"agent":"followup","output":{"scheduled_jobs":[...3 jobs...]}}

event: run_complete
data: {"run_id":"run_xxx","booking_id":"bk_xxxxx","status":"complete","steps":7,"total_ms":15234}
```

Then fetch the trace:
```bash
curl http://localhost:8080/traces/run_xxx | jq .
```

## Outstanding for Day 2+

1. **Mobile app** — Flutter chat + voice + trace panel (prompt scaffolded in `mobile/README.md`)
2. **Real Places API** — flip `USE_REAL_PLACES=true`; implementations in `tools/index.ts::impl_places_*`
3. **Multi-turn conversation** — accept follow-up messages on the same `conversation_id`, persist state across runs
4. **Cloud Run deployment** — `Dockerfile` + `cloud-run-service.yaml`
5. **Authentication** — HMAC-signed user IDs

## How this artifact maps to deliverable #6

The submission requires *"Antigravity agent traces or logs that explicitly show the IDE's reasoning steps, task plans, tool calls, decision rationale, action execution, and fallback/recovery behavior."*

- **Reasoning steps** — D1–D8 above
- **Task plans** — see [20260516-01-backend-impl-plan.md](./20260516-01-backend-impl-plan.md)
- **Tool calls** — Antigravity invoked `read_file` × 9 (context loading), `write_file` × 8 (each new module), `grep` × 2 (anti-monolith verification)
- **Decision rationale** — each D# entry above
- **Action execution** — the 8 files now present in `backend/src/`
- **Fallback/recovery** — D2 (in-memory fallback), D8 (retry on capacity errors)
