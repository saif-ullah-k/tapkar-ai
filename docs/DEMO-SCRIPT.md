# Demo Video Scripts (Day 4 deliverables)

Two videos required for the submission:
1. **Solution demo** (3–5 min) — show the working app + booking + follow-ups
2. **Antigravity usage** (2–5 min) — show Antigravity native Manager in action

---

## Video 1 — Solution Demo (3–5 min)

### Setup checklist (before recording)

- [ ] OBS Studio installed and tested with screen + audio capture
- [ ] Android emulator running (or physical phone connected via USB + `adb tcpip` for screen mirror)
- [ ] Cloud Run backend warm — run `curl https://tapkar-ai-backend-d56rhra4sa-uc.a.run.app/ping-gemini` 30s before recording so first request isn't cold
- [ ] App installed and on the welcome screen
- [ ] Mic working (Win+Shift+S → audio test)
- [ ] Notepad with the URL examples open for reference

### Storyboard

| Time | Visual | Voiceover |
|---|---|---|
| **0:00–0:15** | `flow-explainer.html` playing (animated agent topology) | *"In Pakistan, finding a plumber, a tutor, a maid — it happens on WhatsApp. Messy, slow, no record. TapKar AI is an agentic system that turns 'plumber Gulshan kal subah' into a confirmed booking in 60 seconds."* |
| **0:15–0:25** | App splash screen → chat welcome | *"This is a real Flutter app on real Android, talking to a real backend on Google Cloud Run, using Gemini 2.5 Flash via Vertex AI."* |
| **0:25–0:50** | Tap mic icon → speak **"kal subah Gulshan mein plumber chahiye, paani leak ho raha hai"** | *"I'm speaking Roman Urdu — the way Pakistanis actually talk. The app uses native Android speech recognition with Urdu locale."* |
| **0:50–1:30** | Live SSE stream — 5 agent trace cards animate in: Intent → Discovery → Ranking → Booking → Follow-up | *"Five specialized agents run in sequence. Watch:*<br>*• Intent: extracts plumber, leakage, Gulshan, tomorrow 8 AM*<br>*• Discovery: filters 7 plumbers within 5km*<br>*• Ranking: judges them by user preferences — 'paani leak' triggers leakage-specialist priority*<br>*• Booking: re-checks availability, writes the booking*<br>*• Follow-up: schedules reminders in the user's language"* |
| **1:30–2:00** | Booking confirmation card slides in — `bk_xxxxx` + Roman Urdu reminders | *"Booking confirmed. Receipt generated. Four reminders scheduled — all in Roman Urdu because that's what I spoke. 30-min reminder, status check, post-service survey."* |
| **2:00–2:30** | Tap **⇄ swap** icon → role picker → tap a provider (e.g. Ahmed Plumbing) | *"This is a two-sided marketplace. As a provider, I see incoming bookings."* |
| **2:30–2:50** | Provider mode — booking visible → tap **Accept** → status changes | *"I accept the booking. Customer gets a notification. I can mark En-route, Arrived, Completed."* |
| **2:50–3:30** | Back to customer view → trigger a clarification flow: type only "tutor chahiye" → AI asks for class/days/time | *"The AI is conversational. If I give incomplete info — 'tutor chahiye' — it asks for what's missing. It knows tutors need a recurring schedule, not a single time. Plumbers need a one-time visit. Different categories, different questions."* |
| **3:30–4:00** | Show repo on github.com + Cloud Run console (Vertex AI metrics chart) | *"All open source on GitHub. Backend running on Cloud Run with Vertex AI billing — you can see real API traffic. Everything reproducible from one `deploy.sh` script."* |
| **4:00–4:30** | Close with brand frame + tagline | *"TapKar AI. Bas tap karo — AI sab kar dega. Built for AI SEEKHO Phase 2 with Google Antigravity."* |

### Recording tips

- Record at 1080p, 30fps
- Mic on (your voice carries the demo)
- Don't pause the live trace — let judges see real latency. ~60-90s is fine; you can speed up that section in post (1.5x) if needed
- One take, raw is best. Edit only to trim dead air

### Output

- File: `recordings/final/01-solution-demo.mp4`
- Length: aim for 3:30–4:00 (within the 3–5 min window)

---

## Video 2 — Antigravity Usage (2–5 min)

### Setup checklist

- [ ] Antigravity open with `google_challange2` folder loaded
- [ ] Manager / Agent panel visible
- [ ] OBS recording the whole screen (high res — Antigravity UI must be readable)
- [ ] `[Dev] GCP Project ID` set to `fcmapp-30770` (so it's billed against your hackathon credits, not preview)
- [ ] Pick a model with full quota — **Gemini 3.1 Pro (High)** is best

### Storyboard

| Time | Visual | Voiceover |
|---|---|---|
| **0:00–0:15** | Show Antigravity IDE, Manager panel, `google_challange2` workspace | *"This is Google Antigravity — the IDE we used to build TapKar AI. Throughout the build, Antigravity's native agent orchestrated the major planning and execution phases."* |
| **0:15–0:45** | Open the file tree → highlight `antigravity-artifacts/` folder, show the 7 markdown artifacts inside | *"Every major phase produced an Antigravity-authored artifact: the original implementation plan, the build walkthrough, Day 1, Day 2, and Day 3 success documents. These are all in our repo — completely reproducible."* |
| **0:45–1:15** | Open `antigravity-artifacts/20260516-01-backend-impl-plan.md` in editor | *"Here's the Day 1 plan Antigravity produced — file layout, dependency choices, the orchestrator loop design, even the bug-risk register. We followed this plan to build the 5-agent backend."* |
| **1:15–2:30** | Paste new prompt into Antigravity Manager:<br>`Read backend/src/agents/intent.agent.md and analyze whether the booking-type-awareness section is complete. Suggest 2 categories I might have missed.` <br><br> Let it run live | *"Now I'll show Antigravity native at work — live. I'm asking it to review my own work."* <br><br>(Wait for response, ~30s) <br><br> *"It reads the file, analyzes, suggests improvements. This is what 'main orchestrator' means: Antigravity drives the work, picks the tools, executes."* |
| **2:30–3:30** | Switch tab → show `Settings → Models` page (quotas), then `Settings → Agent` showing the `[Dev] GCP Project ID = fcmapp-30770` | *"Antigravity is wired to our hackathon GCP project — every LLM call is billed against our project credits, traceable in Vertex AI metrics."* <br><br>Then show Cloud Console → Vertex AI → Metrics tab with the traffic spikes |
| **3:30–4:00** | Quick montage — flip through 2-3 more Antigravity artifacts in `/antigravity-artifacts/` | *"Seven Antigravity-authored artifacts across the build. The backend implementation plan, the mobile app spec, the deployment plan — all produced through Antigravity native."* |
| **4:00–4:30** | Final frame — README open in Antigravity showing the architecture diagram | *"Antigravity orchestrated development. The deployed product is plain TypeScript on Cloud Run — zero Antigravity runtime dependency, per the hackathon brief. Best of both worlds."* |

### Output

- File: `recordings/final/02-antigravity-usage.mp4`
- Length: aim for 3:00–4:00

---

## Submission package checklist

Before submitting the AI SEEKHO form:

| # | Deliverable | Asset / URL |
|---|---|---|
| 1 | Mobile App link | https://github.com/saif-ullah-k/tapkar-ai/releases/download/v0.1.0/app-release.apk |
| 2 | GitHub repository | https://github.com/saif-ullah-k/tapkar-ai |
| 3 | Demo video (3–5 min) | upload `recordings/final/01-solution-demo.mp4` to YouTube unlisted → paste link |
| 4 | Antigravity-usage video (2–5 min) | upload `recordings/final/02-antigravity-usage.mp4` to YouTube unlisted → paste link |
| 5 | README / Documentation | in repo + this DEMO-SCRIPT.md + ROADMAP.md |
| 6 | Antigravity traces / logs | the 7 markdown files in `/antigravity-artifacts/` (already in repo) |

Optional but recommended for the submission form's "anything else?" field:
- **Public Cloud Run URL**: https://tapkar-ai-backend-d56rhra4sa-uc.a.run.app
- **Live `/status` check**: https://tapkar-ai-backend-d56rhra4sa-uc.a.run.app/status

---

## Backup plans

If anything goes wrong on demo day:

- **Backend down?** → mention it'll wake up on first request (Cloud Run cold start); pre-warm with curl
- **Mic not working in OBS?** → fall back to text input, narrate over recording
- **Flutter emulator slow?** → use the physical phone instead (mirror to PC via `scrcpy`)
- **Antigravity quota exhausted?** → switch to Gemini 3 Flash (separate quota pool)
- **Demo prompt fails?** → use the verified prompt: `plumber Gulshan kal subah 9 baje` — that's the one with the cleanest result we've tested
