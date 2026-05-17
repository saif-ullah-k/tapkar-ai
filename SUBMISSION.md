# Submission Checklist — AI SEEKHO Phase 2, Challenge 2

**Deadline:** 2026-05-20
**Regional round:** Karachi

Six mandatory deliverables. Track capture status here continuously — do not leave anything for the last day.

| # | Deliverable | Status | Path / Link | Capture during |
|---|---|---|---|---|
| 1 | **Mobile App Link** | ⬜ Pending | (APK upload / Play Store internal / Firebase App Distribution link) | Day 3–4 |
| 2 | **GitHub Repository** | ⬜ Pending | (public URL) | Continuous |
| 3 | **Demo video — solution walkthrough** (3–5 min) | ⬜ Pending | `recordings/final/demo-solution.mp4` | Day 4 |
| 4 | **Video of Antigravity usage** (2–5 min) | ⬜ Pending | `recordings/final/antigravity-build.mp4` | **Daily clips → Day 4 edit** |
| 5 | **README / Documentation** | 🟡 In progress | `README.md` + `docs/architecture.md` + `docs/work-plan.md` | Continuous |
| 6 | **Antigravity Trace / Logs** | ⬜ Pending | `antigravity-artifacts/` | **Every Antigravity session** |

---

## Per-deliverable detail

### 1 · Mobile App Link
- Flutter Android APK as primary
- Hosted on Firebase App Distribution OR direct download link
- Must be installable and **fully functional** (not just UI mockup)
- Test on a fresh device before final submission

### 2 · GitHub Repository
- Public, MIT or Apache-2.0 licensed
- All code, taxonomy, docs, artifacts in one repo
- Recordings folder gitignored (too large) — link to Drive instead
- Final commit BEFORE May 20 deadline; do not push after

### 3 · Demo video — solution walkthrough
- **Real screen recording of the mobile app** (Gemini-generated videos detected & disqualified)
- 3–5 minutes, single take preferred
- Script outline:
  - 0:00–0:20 — Open with `flow-explainer.html` auto-playing (B-roll)
  - 0:20–2:30 — Live mobile demo: voice in Urdu → trace panel lights up → booking confirmed
  - 2:30–3:30 — Show 2 more scenarios (Roman Urdu + English, different services)
  - 3:30–4:30 — Show follow-up automation (reminder firing)
  - 4:30–5:00 — Impact framing: who this helps, scale potential

### 4 · Video of Antigravity usage
- **Screen recording showing YOU building in Antigravity**
- Proves the project was authored in Antigravity, not dropped in
- Capture continuously — every meaningful session gets recorded to `recordings/raw/`
- Day 4: edit best 2–5 minutes into final cut
- Show:
  - Antigravity IDE open with project loaded
  - Prompting an agent for an implementation plan
  - Plan being generated + executed
  - Multi-agent runs in the Manager view
  - Trace panel showing agentic activity
  - Model picker (showing Gemini / Claude switch)

### 5 · README / Documentation
- Top-level `README.md` (this repo)
- `docs/architecture.md` — system design + anti-monolith guarantee
- `docs/work-plan.md` — 4-day execution plan
- Should read like a high-quality engineering README — judges scan this first

### 6 · Antigravity Trace / Logs
- Every implementation plan, walkthrough, task list, task plan Antigravity generates
- Saved to `antigravity-artifacts/` immediately after each session
- Filename: `YYYYMMDD-{feature-name}-{plan|walkthrough|tasks|trace}.md`
- Numbered so reviewers read in order
- Treat as a first-class deliverable, not an afterthought — 50% of evaluation hinges on Antigravity usage depth

---

## Daily capture habits (Days 1–3)

Every working day:

- [ ] Start OBS recording before each Antigravity prompt session
- [ ] After session, export any Antigravity-generated artifacts → `antigravity-artifacts/`
- [ ] Commit + push to GitHub
- [ ] Update this checklist's status column

## Day 4 final-day checklist

- [ ] Edit Antigravity-usage video (2–5 min) from stockpiled raw clips
- [ ] Record solution demo video (3–5 min) on real phone
- [ ] Final pass on README + architecture doc
- [ ] Verify all artifacts in `antigravity-artifacts/` are numbered & dated
- [ ] APK uploaded, link tested on fresh device
- [ ] GitHub repo public, final commit, no `.env` or secrets
- [ ] Submit via official form before deadline
