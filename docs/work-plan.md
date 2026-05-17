# 4-Day Work Plan

**Window:** 2026-05-16 → 2026-05-20 (submission)
**Team:** 5 members
**Region:** Karachi

---

## Day 0 — Today · Setup (~2–3 hrs)

Concurrent USER tasks (anyone on the team can do these):
- [ ] Install Google Antigravity, sign in, open this repo
- [ ] Install OBS Studio (record-test 30 seconds to `recordings/raw/`)
- [ ] Create GCP project; enable: Places API, Maps SDK, Geocoding, Cloud Speech-to-Text, Firestore, Cloud Run
- [ ] Redeem all team members' hackathon credit links (QR / link from webinar)
- [ ] Create the GitHub repo (private until ready) and push this scaffolded code
- [ ] Get a Gemini API key + (optional) Anthropic API key for Claude inside Antigravity

Concurrent SCAFFOLDING (already done):
- [x] Repo structure
- [x] README, SUBMISSION.md, architecture.md, work-plan.md
- [x] `data/taxonomy.json` with 26 services × 3 languages
- [x] `data/providers.karachi.json` with seed providers
- [x] Agent prompt specs in `backend/src/agents/`
- [x] Tool contracts in `backend/src/tools/`
- [x] `flow-explainer.html` animated explainer

End-of-day: repo cloned in Antigravity, GCP credits redeemed, OBS records cleanly.

---

## Day 1 — Backend skeleton in Antigravity

### Morning (4 hrs)
- [ ] Start OBS, record session
- [ ] Open Antigravity, prompt: *"Generate an implementation plan for the backend in `backend/`. Read `docs/architecture.md` and `backend/src/agents/*.agent.md` first."* → save plan to `antigravity-artifacts/`
- [ ] Let Antigravity scaffold the Cloud Run TypeScript service
- [ ] Wire up Firestore admin SDK + tool stubs
- [ ] Implement `taxonomy` + `search-providers` (reads JSON for now, Places API behind flag)

### Afternoon (4 hrs)
- [ ] Prompt Antigravity to wire up the Orchestrator → Intent → Discovery flow end-to-end in English
- [ ] Add trace logging to Firestore (write `traces/{run_id}`)
- [ ] Deploy a test instance to Cloud Run (or run locally — brief allows it)
- [ ] Smoke test: POST a JSON request → see traces appear in Firestore

**Acceptance:** End-to-end English text request returns ranked providers + writes a trace.
**Artifacts captured:** 3–5 plans/walkthroughs in `antigravity-artifacts/`.
**Recording:** Save full session clip to `recordings/raw/day1-backend.mp4`.

---

## Day 2 — Mobile app + multilingual

### Morning (4 hrs)
- [ ] Start OBS
- [ ] In Antigravity, prompt: *"Generate impl plan for Flutter chat UI with voice input and live trace panel. Read `docs/architecture.md` first."* → save plan
- [ ] Scaffold Flutter app: `flutter create mobile/tapkar_ai` (Flutter packages use snake_case)
- [ ] Build chat screen + trace panel (mirror `flow-explainer.html` design in Flutter)
- [ ] Wire to backend via HTTPS

### Afternoon (4 hrs)
- [ ] Add Urdu voice input (Cloud Speech-to-Text via Flutter plugin)
- [ ] Roman Urdu + Urdu prompt engineering in Intent agent (few-shot examples)
- [ ] Test 15 multilingual phrases — fix the worst failures
- [ ] Booking + receipt screen in Flutter

**Acceptance:** A real Urdu voice input on a real phone → trace panel lights up → booking confirmed.
**Artifacts:** 3–5 more plans for Flutter scaffolding + multilingual prompts.
**Recording:** `recordings/raw/day2-mobile.mp4`.

---

## Day 3 — Follow-up, polish, edge cases

### Morning (4 hrs)
- [ ] Start OBS
- [ ] Implement Follow-up Agent + scheduled jobs (Firestore TTL / app-side scheduler)
- [ ] Timeline UI in mobile: requested → matched → confirmed → reminded → completed
- [ ] Optional: "provider side" view showing the auto-reply (sells the automation story)

### Afternoon (4 hrs)
- [ ] Error paths: no providers / ambiguous location / mid-flow cancellation — let orchestrator reason, NO `if` statements
- [ ] Category-tuned ranking weights for Tier-1 (taxonomy.json updates only)
- [ ] Urdu Nastaliq font rendering check on Android + iOS
- [ ] Stress-test: 30 multilingual prompts × 3 languages, fix worst 3 failures
- [ ] Seed 3 scripted "Demo Mode" scenarios that always work

**Acceptance:** Full end-to-end works in all 3 languages with follow-ups firing.
**Artifacts:** 3–5 more plans for follow-up + edge cases.
**Recording:** `recordings/raw/day3-polish.mp4`.

---

## Day 4 — Documents, videos, submit

### Morning (4 hrs) — Documentation
- [ ] Finalize README, architecture.md
- [ ] Verify all artifacts in `antigravity-artifacts/` are numbered & dated
- [ ] Final architecture diagram (export to PNG for video B-roll)
- [ ] APK build: `flutter build apk --release` → upload to Firebase App Distribution

### Afternoon (3–4 hrs) — Videos
- [ ] **Solution demo video (3–5 min):**
  - Open with `flow-explainer.html` (20 sec B-roll)
  - Live mobile demo (3 scenarios)
  - Follow-up automation demo
  - Impact close
- [ ] **Antigravity usage video (2–5 min):**
  - Edit montage from Day 1–3 raw recordings
  - Show: prompt → plan generated → execution → trace appearing
  - Show: model picker switching Gemini ↔ Claude
  - Show: artifact files being saved

### Evening (1 hr) — Submission
- [ ] Final GitHub push, repo public
- [ ] Both videos uploaded (Drive / YouTube unlisted)
- [ ] APK link tested on fresh device
- [ ] Submit via official form
- [ ] Celebrate 🎉

---

## Risk register

| Risk | Mitigation |
|---|---|
| Antigravity goes down mid-build | Mock data path always works offline; Claude inside Antigravity as fallback model |
| Urdu STT quality poor on test phone | Fall back to typed Urdu; STT is bonus not core |
| Places API quota exhausted | Aggressive Firestore caching; mock data primary |
| Live demo network failure | Backup recorded video; offline mode replay |
| Team member drops out | 5-person team has slack; replan with remaining 4 |

## What we cut (to protect the deadline)

- Twilio WhatsApp sandbox (user-rejected)
- Web app (mobile is mandatory; web is optional bonus only)
- Real payments (brief says simulate)
- Production deploy hardening
- Automated tests beyond happy-path

## Daily standup template

Take 10 minutes each morning to sync:
- What I did yesterday
- What I'm doing today
- Blockers
- Recording stockpile status
- Artifact count today
