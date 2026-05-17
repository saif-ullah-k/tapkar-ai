# TapKar AI Backend

Cloud Run service that hosts the Antigravity-orchestrated agent pipeline. **All business logic lives in agent prompts, not in code.** This service is just the wiring.

## Structure

```
backend/
├── src/
│   ├── agents/         # Agent prompt specs (.agent.md files)
│   │                   #   Antigravity reads these to instantiate runtime agents
│   ├── tools/          # Thin I/O wrappers (no business logic)
│   │   └── index.ts    # Tool registry — signatures only, no decisioning
│   ├── types.ts        # Shared data shapes
│   └── index.ts        # Express server entry (created Day 1 via Antigravity)
├── package.json
└── tsconfig.json
```

## Day 1 setup (in Antigravity)

Open this folder in Antigravity. Then prompt:

> Generate an implementation plan for the TapKar AI backend. Read `agents/*.agent.md` for agent specs, `tools/index.ts` for tool contracts, `../docs/architecture.md` for system design, and `../data/taxonomy.json` + `../data/providers.karachi.json` for data shapes. The backend is a Cloud Run Express service that exposes a `/run` endpoint accepting a user message, runs the agent pipeline through Antigravity's orchestrator, and streams the trace to Firestore as SSE.

Save the plan that Antigravity generates to `../antigravity-artifacts/YYYYMMDD-01-backend-bootstrap-plan.md`.

## Local development

```bash
cd backend
npm install
npm run dev
```

Set environment variables:
```
GEMINI_API_KEY=...          # for the LLM
GOOGLE_MAPS_API_KEY=...     # Places + Geocoding
FIRESTORE_PROJECT=...
USE_REAL_PLACES=false       # mock-only mode for offline development
```

## The anti-monolithic rule

Every `if`, `switch`, or for-loop in this codebase should be doing one of:

- **I/O orchestration** (await this DB call, then await that API call)
- **Data transformation** (map a list, filter by an exact agent-provided criterion)
- **Framework wiring** (Express middleware, error handlers)

If you catch yourself writing logic like:

```ts
// ❌ BAD — this is a business decision, belongs in an agent prompt
if (category === 'plumber' && urgency === 'high') {
  weight_distance = 0.6;
}
```

… stop and move it to the relevant agent's prompt instead. The reasoning belongs to the LLM.

## Antigravity workflow

1. Start OBS screen recording
2. Open Antigravity → Manager view
3. Prompt for the feature you want
4. Let Antigravity plan + execute
5. Save the implementation plan, walkthrough, and task list to `../antigravity-artifacts/`
6. Commit
