# TapKar AI — Product Roadmap

> *"Bas tap karo — AI sab kar dega."*

This is **not just a hackathon entry**. It's the v0.1 of a market product. This doc separates what we ship for the AI SEEKHO Phase 2 deadline (May 20) from what comes after.

---

## Phase 0 — Hackathon submission (May 17–20)

The MVP that lands the AI SEEKHO win and produces a polished public demo.

### Already done (Day 1–2)
- ✅ 5-agent pipeline (intent → discovery → ranking → booking → followup) on Vertex AI
- ✅ Flutter Android app with chat + voice + live trace
- ✅ Multilingual (Urdu / Roman Urdu / English) end-to-end
- ✅ Conversational clarification — AI asks when info missing
- ✅ Follow-up reminders if user doesn't reply (in-app, 2 + 5 min)
- ✅ Trace artifacts in `/antigravity-artifacts/`

### Day 3 priorities (May 18)
- **Server-side conversation memory** — backend keeps per-`conversation_id` history so multi-turn isn't client-side concatenation hack
- **Booking agent: alternate-time suggestions** — instead of just "unavailable", say *"10 AM nahin, magar 2 PM ya kal subah 8 AM mil sakta hai"*
- **Ranking: option mode** — when top-3 scores are close, show all three and let user pick instead of auto-picking
- **Cloud Run deployment** — backend public, accessible by anyone
- **Firebase App Distribution** — public install link for the APK
- **GitHub repo public** — code visible
- **Release APK** built with deployed URL — submission deliverable #1

### Day 4 priorities (May 19–20)
- **Demo video** (3–5 min) showing end-to-end flow
- **Antigravity-usage video** (2–5 min) showing the IDE in action
- **README polish** + final architecture diagram
- **Stress test** 30 multilingual prompts; fix worst 3 failures
- **Final submission** packed

---

## Phase 1 — Public beta (Q3 2026, post-hackathon)

What turns this from a polished demo into a real product real Pakistanis can use.

### Authentication & users
- Firebase Auth with phone OTP (Pakistani SIM friendly)
- User profile: name, default location, preferred language
- Saved addresses (home, office)

### Two-sided marketplace
- Provider onboarding flow (separate Flutter app or web)
- Provider availability calendar (real, not mock JSON)
- Provider receives booking notifications via FCM + WhatsApp Business API
- Provider can accept / counter-propose / decline
- Multi-provider request fan-out (e.g. ranking sends to top 3 simultaneously, first to accept wins)

### Real provider sourcing
- Google Places API integration (already wired, gated behind `USE_REAL_PLACES`)
- Partnership with existing aggregators (Mr. Mechanic, MaidEasy, etc.) for inventory
- User-generated reviews & ratings (write back to Firestore)
- Verification badge system (CNIC, references, training)

### Booking lifecycle
- Cancellation (user-initiated, provider-initiated)
- Reschedule
- Status tracking (provider en route → arrived → in progress → completed)
- Photo upload during/after service
- Post-service rating + review

### Payments
- JazzCash / Easypaisa integration (Pakistan's dominant mobile money)
- Stripe / Mastercard for card payments
- Hold + release flow (escrow until service completion)
- Tipping
- Refunds for cancellations

### Notifications
- FCM push for booking confirmations, reminders, provider en route, ratings due
- SMS fallback for users without push enabled
- WhatsApp Business for high-confidence handoffs

### Polish
- Skeleton loaders
- Optimistic UI updates
- Offline mode (queue requests)
- Better error states (network failure, agent error, etc.)
- Animations + micro-interactions
- Dark/light theme toggle
- Accessibility (screen reader support)

---

## Phase 2 — Scale (Q1 2027)

### AI improvements
- Per-user preference learning (this user prefers female beauticians, that user prefers cheaper options)
- Time-of-day-aware urgency inference (10 PM "AC theek karwana" = emergency, 10 AM = normal)
- Multi-step bookings (plumber + carpenter for a renovation)
- Predictive booking (recurring services suggested before user asks)
- Reasoning explainability — "I picked this provider because…" shown to user, not just judges

### Geographic expansion
- Lahore, Islamabad, Faisalabad, Multan
- City-specific taxonomies (rural vs urban services)
- Dialect handling (Punjabi mixed with Urdu, Sindhi mixed)

### B2B
- Office maintenance contracts
- Property manager bulk bookings
- Apartment-complex onboarding

### Provider tooling
- Dashboard for booking management
- Earnings analytics
- Training content
- Insurance integration (provider liability)

---

## Engineering principles

1. **No hardcoded business logic** — the anti-monolithic rule from Day 1 stays forever. Decisions belong in agent prompts, not `if/else`.
2. **Multilingual is a first-class concern** — every user-facing string supports Urdu / Roman Urdu / English. Never an "English first, translate later" pattern.
3. **Agentic by default** — when in doubt, let an agent decide rather than encoding a heuristic.
4. **The trace IS the product** — users (and judges, and devs debugging) can always see *why* the AI made a choice.
5. **Real provider trust matters more than pretty UI** — investment in verification > investment in animations.

---

## Risk register

| Risk | Mitigation |
|---|---|
| Gemini API cost scales with users | Per-tenant rate limiting, switch to flash for non-critical agents |
| Provider quality varies wildly | Verification system + rating-weighted ranking |
| Pakistani phone numbers + WhatsApp adoption | Firebase OTP, fallback to manual phone confirmation |
| Internet patchiness in some areas | Offline queue + retry, SMS-only fallback for booking confirms |
| Provider no-shows | Surety system: small deposit, lost on no-show, refunded on completion |
| AI hallucinates unavailable provider | Re-check capacity at booking time (already implemented) |
| Multi-turn conversations drift off-topic | Server-side conversation summarization every N messages |

---

## What we are NOT building (focus discipline)

- ❌ A "ChatGPT for everything" — we are a **service booking platform** that uses AI
- ❌ Voice synthesis (text-to-speech replies) — chat is fine
- ❌ Video calls between user and provider
- ❌ Generic chat / general-purpose assistant features
- ❌ Crypto / blockchain (no reason for it)
- ❌ NFT loyalty / token rewards
