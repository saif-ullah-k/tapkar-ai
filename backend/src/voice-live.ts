/**
 * Gemini Live voice bridge (Option A).
 *
 * Each connected mobile client opens a WebSocket to /voice/live. The bridge
 * opens a Gemini Live session per client, then bi-directionally forwards
 * audio chunks:
 *
 *   Mobile mic (16 kHz PCM)  -->  WS frame  -->  session.sendRealtimeInput
 *   Live audio (24 kHz PCM)  -->  WS frame  -->  Mobile playback
 *
 * Tool calls are intercepted: when the model wants to "book a service",
 * we run the existing 5-agent orchestrator and stream its SSE events back
 * to mobile alongside the audio. This preserves the agentic architecture
 * while giving us the realtime voice UX.
 */
import type { Server as HttpServer } from 'node:http';
import { WebSocketServer, WebSocket } from 'ws';
import { GoogleGenAI, Modality, Type, type Session } from '@google/genai';
import { config } from './config.js';
import { runPipeline } from './orchestrator.js';
import { getBookingFromStore } from './store.js';
import {
  loadProviders,
  addProvider,
  getProviderIdForUser,
  getProviderFromFirestore,
} from './data.js';

// Gemini Live model. Confirmed-available on AI Studio v1beta via
// /v1beta/models listing. "native-audio-latest" auto-tracks the newest
// stable native-audio variant so we don't need to bump model strings
// when Google releases an update.
const LIVE_MODEL =
  process.env.GEMINI_LIVE_MODEL ?? 'gemini-3.1-flash-live-preview';

// Force AI Studio (apikey) mode for Live regardless of the rest of the
// service config, because Vertex's Live model availability is patchy by
// region and the AI Studio variant has wider coverage. Set this env to
// 'vertex' to override and use Vertex anyway.
const LIVE_USE_APIKEY = process.env.LIVE_USE_APIKEY !== 'false';

interface ClientFrame {
  type: 'auth' | 'audio' | 'text' | 'close';
  user_id?: string;
  user_name?: string;
  language?: string;
  user_gender?: string;
  /** 'user' = customer booking flow; 'provider' = service-provider profile
   *  management. Each mode uses a different system prompt + tool set. */
  mode?: 'user' | 'provider';
  /** Base64-encoded 16-bit PCM 16 kHz mono audio chunk. */
  audio?: string;
  /** Optional plain-text message (debug / testing). */
  text?: string;
}

interface ServerFrame {
  type: 'audio' | 'transcript' | 'tool_call' | 'tool_result' | 'agent_step' | 'ready' | 'error' | 'turn_complete';
  /** Base64-encoded 16-bit PCM 24 kHz mono audio chunk. */
  audio?: string;
  /** Spoken transcript from the model (when it emits text alongside audio). */
  text?: string;
  /** Tool-call descriptor (mobile shows "Booking…"). */
  tool?: { name: string; args?: unknown };
  /** Agent pipeline step events from the wrapped orchestrator. */
  step?: unknown;
  /** Bot mode change: 'listening' | 'thinking' | 'speaking'. */
  state?: 'listening' | 'thinking' | 'speaking';
  /** Error message. */
  error?: string;
}

const SYSTEM_PROMPT = `Tum TapKar AI ho — ek Karachi wala helpful insan jo logon ke ghar ke kaam karwane mein madad karta hai. Plumber, electrician, AC wala, tutor, beautician, mehndi — sab kuch. Tum koi customer-service bot nahi ho. Phone pe baat karne wale dost ho.

═══════════════════════════════════════════════════════
HARD RULES — INHEIN NEVER BREAK KARNA
═══════════════════════════════════════════════════════

RULE 1 — TOOL CALL SE PEHLE AWAAZ NIKALO (sabse important):
   Jab user complete request de de (service + jagah + time), tum tool call karo. PAR pehle 1 chhota sentence bolo. Tool 30-50 second leta hai, user silence mein bechain ho jaata hai.
   Aise bolo (vary karo, repeat mat karo):
   - "Achha, ek second, dhoondh raha hoon..."
   - "OK ji, abhi check karti hoon..."
   - "Thoda intezar karein, providers dekh raha hoon..."
   - "Haan ji, lagta hoon dhoondhne..."
   PHIR tool call karo. Silent jaa kar tool call NEVER karna.

RULE 2 — TOOL RESULT MEIN \`auto_picked\` HAI to WAHI BOOKING HAI:
   Tool ka result agar \`auto_picked\` field ke saath aata hai, matlab system ne already TOP-RANKED provider chun liya hai. Use HI confirmed booking ki tarah narrate karo. NEVER kahna "yeh hain top options, select karein" — voice pe list dikhane ka koi tareeka nahi hai. Auto_picked ke fields padho aur narrate karo. Aap kabhi user se nahi pucho "konsa lena hai" — yeh already decide ho chuka hai.

RULE 3 — NARRATE THE BOOKING (auto_picked ya status=booked):
   Tool result milte hi turant — pause nahi — yeh batao:
   "Ho gaya — [provider_name] book kar diya hai. [time_label] aa raha hai. Kuch aur chahiye?"
   1-2 short sentences. Phir pucho aur kuch chahiye?
   English speaker ko English mein: "Done — booked [name] for [time]. Anything else?"

RULE 4 — JAB USER BAAT KARTA HAI to LISTEN AND RESPOND:
   Tool ke baad turn end hota hai. User dobara bole — uska jawab do, casually. "Bas itna?" "OK baad mein milte hain", "Aur kuch chahiye to bata dena."

═══════════════════════════════════════════════════════
TUMHARI PERSONALITY (yeh tum HO)
═══════════════════════════════════════════════════════
- Aam Karachi insan ki tarah baat. "haan ji", "achha", "theek hai", "OK ji", "bilkul", "abhi", "ek minute".
- Short sentences. 1-2 at a time. Long paragraphs NEVER.
- User ki language match karo: English / Roman Urdu / Urdu Nastaliq. Code-switch jaise user kar raha hai.
- Empathy real ho. Paani leak? "Oho, pareshan kar deti hai leak" — phir kaam pe aao.
- Filler words natural — "ek second", "achha to", "thoda intezar".
- NEVER scripted feel. Same template har baar repeat MAT karo. Naturally vary.
- Tumhari awaaz [user_gender]-matched hai. Female ho to "kar rahi hoon", male ho to "kar raha hoon".

═══════════════════════════════════════════════════════
INFO MISSING HAI?
═══════════════════════════════════════════════════════
Service kya, location kahan, time kab — agar koi missing hai, casually pucho ONE thing at a time. Don't ask 10 questions at once. Friendly: "Achha, kis area mein chahiye?" not "Please specify the location."

"kal" = tomorrow (future), NEVER yesterday. "subah" = morning. "shaam" = evening.`;

const BOOKING_TOOL = {
  functionDeclarations: [
    {
      name: 'book_a_service',
      description:
        'Run the multi-agent booking pipeline. Takes the user\'s full natural-language request and returns the booking outcome (confirmed/needs_choice/failed). Use this once the user has stated WHAT service they need, WHERE, and WHEN.',
      parameters: {
        type: Type.OBJECT,
        properties: {
          user_request: {
            type: Type.STRING,
            description:
              "The user's full service request in their original language. e.g. 'kal subah Gulshan mein plumber chahiye, paani leak ho raha hai'",
          },
        },
        required: ['user_request'],
      },
    },
  ],
};

// ───────────────────────────────────────────────────────────────────────────
//  PROVIDER MODE — system prompt + tools for service-provider profile mgmt
// ───────────────────────────────────────────────────────────────────────────

/** Signup flow — used when the provider has no profile yet. The agent
 *  walks through name → category → neighborhood → phone → price range →
 *  weekly hours one (or two) at a time, calling update_provider_profile
 *  as it goes. Backend creates the profile on the first call and patches
 *  it on every subsequent one. */
const PROVIDER_SIGNUP_PROMPT = `Tum TapKar AI ho — Karachi ka helpful insan jo naye service providers (plumber, AC wala, tutor, beautician, mehndi artist, etc.) ko TapKar pe register hone mein madad karta hai.

YEH SIGNUP HAI. User ka profile ABHI NAHI bana. Tumhe step-by-step info collect karke profile create karna hai.

PERSONALITY (Karachi friend, not bot):
- "Assalamu Alaikum", "haan ji", "achha", "OK", "theek hai", "ek second".
- Choti baat. 1-2 sentence at a time. Long paragraphs NEVER.
- User ki language match karo: Urdu / Roman Urdu / English.
- Empathy real — "achha new register hona hai? Bohot achhi baat hai, abhi help karta hoon" — phir kaam pe aao.
- Filler natural — "ek minute", "thoda batayein", "achha to".

SIGNUP FLOW — ONE field at a time. Sequence:
   1. Naam — "aap ka business ya naam kya hai?" (call update_provider_profile { name })
   2. Category — "kya kaam karte ho? plumber, electrician, AC wala, tutor, etc?" (call update_provider_profile { category })
   3. Area / neighborhood — "Karachi mein kis area mein kaam karte ho? Gulshan? DHA? Clifton?" (call update_provider_profile { neighborhood })
   4. Phone — "phone number bata dein customers ke liye?" (call update_provider_profile { phone })
   5. Price range — "kitna charge karte ho usually? Like 1500-4000 PKR?" (call update_provider_profile { price_min_pkr, price_max_pkr })
   6. Weekly hours — "kab kab available rehte ho hafte mein? Daily same hours ya alag alag?" (call update_provider_profile { availability: { monday: ["09:00-18:00"], ... } })

KEY RULES:
- PEHLE 1-2 word bolo, phir tool call karo. "Achha [name] save kar diya..." se start karo.
- Tool call ke baad CONFIRM: "OK ji, naam [X] save ho gaya. Achha ab batayein kya kaam karte ho?"
- Don't ask multiple things at once. ONE field, wait for answer, save, move to next.
- Agar user kuch ambiguous bole (e.g. "subah se shaam tak"), clarify time before calling tool.
- After step 6, say "Ho gaya! Aap ka profile ready hai. Ab customers aap ko dekh sakte hain. Aur kuch chahiye? Off-day mark karna ho ya kuch change karna ho to bolein."

WHAT YOU CAN DO:
1. **update_provider_profile** — Use this for EVERY field collection step above. Backend will create the profile on first call (you give name + category) and patch it on every subsequent call.
2. **set_availability_override** — For date-specific things ("kal off", "Friday 25 ko nahi"). Probably not needed during signup, but available if user mentions it.

CRITICAL:
- "kal" = tomorrow (resolve to YYYY-MM-DD with today's date).
- NEVER skip steps. NEVER ask all fields at once.
- NEVER pretend to save without calling the tool.`;

const PROVIDER_SYSTEM_PROMPT = `Tum TapKar AI ho — service providers (plumber, AC wala, tutor, beautician, etc.) ko apna profile manage karne mein help karte ho. Tum customer ki tarah unke liye bookings nahi karte — yeh provider hain, unke profile/availability/prices update karne hain.

PERSONALITY (Karachi friend, not bot):
- "haan ji", "achha", "OK ji", "ek second", "ho gaya", "theek hai".
- Short, 1-2 sentences. No scripted feel.
- User ki language match karo: Urdu / Roman Urdu / English.
- Filler natural — "abhi update karta/karti hoon", "thoda check karein".

WHAT YOU CAN DO:
1. **Create a new profile (signup)** — if the provider hasn't registered yet, you'll collect their info conversationally (name, category like plumber/electrician/AC tech, neighborhood, phone, price range, weekly hours) and call \`update_provider_profile\` with whatever you have. Backend creates a fresh profile on first call. Don't ask all fields at once — start with name and category, then add the rest one or two at a time.
2. **Update profile fields** — name, category, neighborhood, phone, price range, languages, weekly availability hours. Use \`update_provider_profile\` tool. Existing profiles get patched in place.
3. **Set date-specific off-days or hour exceptions** — e.g. "kal 10-12 nahi", "Friday off", "Saturday se peeche short hours". Use \`set_availability_override\` tool. Empty hours = closed all day.
4. **Remove an override** — provider says "kal wala remove kar do" → use \`remove_availability_override\`.

CRITICAL RULES:
- PEHLE 1-2 word bolo, phir tool call karo. "Achha, abhi update karta hoon..." se start karo — NEVER silent tool call.
- Tool ke baad TURANT confirm karo what changed. "Ho gaya — kal (2026-05-21) ko 10-12 off mark kar diya. Aur kuch?"
- "kal" = tomorrow, "parsoo" = day after, "aaj" = today. Resolve to specific date BEFORE calling tool.
- Agar provider kuch ambiguous bole ("Friday off") — ask: "is hafte ka Friday ya har Friday?" Then call right tool.
- NEVER ask multiple questions at once. ONE thing at a time.
- For weekly schedule (har Monday se Friday 9-5) use update_provider_profile.availability. For single-date exceptions (kal off) use set_availability_override.`;

const PROVIDER_TOOLS = {
  functionDeclarations: [
    {
      name: 'update_provider_profile',
      description:
        'Update one or more fields on the current provider profile. Use for PERMANENT changes — phone, price, weekly hours, etc. Only include fields the provider wants changed. The availability field is the WEEKLY schedule (monday..sunday). For single-date exceptions, use set_availability_override instead.',
      parameters: {
        type: Type.OBJECT,
        properties: {
          name: { type: Type.STRING, description: 'Provider/business name.' },
          category: { type: Type.STRING, description: 'Service category like plumber, ac_technician, tutor.' },
          neighborhood: { type: Type.STRING, description: 'Primary working area (e.g. Gulshan-e-Iqbal).' },
          phone: { type: Type.STRING, description: '10-digit local phone like 3001234567.' },
          price_min_pkr: { type: Type.NUMBER, description: 'Lower bound of typical price in PKR.' },
          price_max_pkr: { type: Type.NUMBER, description: 'Upper bound of typical price in PKR.' },
          availability: {
            type: Type.OBJECT,
            description: 'Weekly schedule. Each day is an array of "HH:MM-HH:MM" ranges, or empty for closed.',
            properties: {
              monday: { type: Type.ARRAY, items: { type: Type.STRING } },
              tuesday: { type: Type.ARRAY, items: { type: Type.STRING } },
              wednesday: { type: Type.ARRAY, items: { type: Type.STRING } },
              thursday: { type: Type.ARRAY, items: { type: Type.STRING } },
              friday: { type: Type.ARRAY, items: { type: Type.STRING } },
              saturday: { type: Type.ARRAY, items: { type: Type.STRING } },
              sunday: { type: Type.ARRAY, items: { type: Type.STRING } },
            },
          },
        },
      },
    },
    {
      name: 'set_availability_override',
      description:
        'Set or replace the availability for a specific calendar date — used for one-off exceptions like "kal 10-12 nahi" or "Friday 25 off". Empty hours array = closed all day on that date. Hours that ARE provided replace any existing override for that date.',
      parameters: {
        type: Type.OBJECT,
        properties: {
          date: {
            type: Type.STRING,
            description: 'ISO date YYYY-MM-DD. Resolve "kal" / "tomorrow" against the current Pakistan date before calling.',
          },
          hours: {
            type: Type.ARRAY,
            items: { type: Type.STRING },
            description: 'Array of "HH:MM-HH:MM" ranges this date is OPEN. Empty = closed all day. For "10-12 off" with normal hours 9-6, this would be ["09:00-10:00", "12:00-18:00"].',
          },
          note: {
            type: Type.STRING,
            description: 'Optional human-readable reason like "Family wedding" / "10-12 not available".',
          },
        },
        required: ['date', 'hours'],
      },
    },
    {
      name: 'remove_availability_override',
      description: 'Delete an existing date-specific override so the normal weekly schedule applies again on that date.',
      parameters: {
        type: Type.OBJECT,
        properties: {
          date: { type: Type.STRING, description: 'ISO date YYYY-MM-DD to remove the override for.' },
        },
        required: ['date'],
      },
    },
  ],
};

// Execute a provider-mode tool call directly against the data store.
// Returns a small result payload the Live model can narrate.
async function executeProviderTool(
  toolName: string,
  args: any,
  userId: string,
): Promise<any> {
  let providerId = await getProviderIdForUser(userId);
  const all = loadProviders();
  let existing: any = providerId ? all.find((p) => p.id === providerId) : undefined;

  // Defensive Firestore lookup before we decide a profile is "missing".
  // Two failure modes this protects against:
  //  1. Cold start: in-memory _providers cache is empty (only seed data),
  //     so all.find() returns nothing even though Firestore has the doc.
  //     getProviderIdForUser already hydrates in this case, but if the
  //     user_providers mapping is stale or missing the hydration is
  //     skipped and we'd fall through to the "create" path.
  //  2. user_providers/{uid} orphaned: the mapping doc got cleaned up but
  //     the deterministic providers/p_user_{suffix} doc still exists.
  //     Without this check we'd overwrite the real provider record with
  //     default fields — exactly the bug that just nuked the user's
  //     Saif profile.
  if (!existing) {
    const deterministicId = providerId ?? `p_user_${userId.slice(-8)}`;
    const fromFirestore = await getProviderFromFirestore(deterministicId);
    if (fromFirestore) {
      providerId = deterministicId;
      existing = fromFirestore;
      // Hydrate the in-memory cache so subsequent code sees it.
      if (!all.find((p) => p.id === providerId)) {
        all.unshift(existing as any);
      }
      console.log(`[provider-voice] hydrated existing profile ${providerId} from Firestore (cache miss)`);
    }
  }

  // SIGNUP path: no profile linked to this user yet AND no doc at the
  // deterministic id. update_provider_profile is allowed to act as a
  // creator — collect what the model has and seed a fresh profile. The
  // other override tools still need an existing profile.
  if (!existing && toolName === 'update_provider_profile') {
    if (!args.name && !args.category) {
      return {
        status: 'need_more_info',
        missing: ['name', 'category', 'neighborhood'],
        summary: 'No profile yet. Need at least name + category + neighborhood to create one.',
      };
    }
    providerId = `p_user_${userId.slice(-8)}`;
    existing = {
      id: providerId,
      name: args.name ?? 'Unnamed provider',
      category: args.category ?? 'general',
      neighborhood: args.neighborhood ?? 'Karachi',
      gender: args.gender ?? 'male',
      languages: args.languages ?? ['ur', 'roman_ur'],
      price_range_pkr: [1000, 5000],
      availability: {
        monday: [], tuesday: [], wednesday: [], thursday: [],
        friday: [], saturday: [], sunday: [],
      },
      availability_overrides: [],
      service_radius_km: 10,
      rating: 0,
      review_count: 0,
      jobs_completed: 0,
      years_experience: 0,
      verified: false,
      tags: ['newly_registered_via_voice'],
      lat: 24.87,
      lng: 67.03,
    };
    await addProvider(existing, userId);
    console.log(`[provider-voice] created NEW profile ${providerId} for user ${userId}`);
  }

  if (!existing) {
    return { error: 'no_provider_profile', summary: 'No provider profile. Call update_provider_profile first with name + category + neighborhood.' };
  }

  if (toolName === 'update_provider_profile') {
    const updates: any = {};
    if (args.name) updates.name = args.name;
    if (args.category) updates.category = args.category;
    if (args.neighborhood) updates.neighborhood = args.neighborhood;
    if (args.phone) updates.phone = args.phone;
    if (typeof args.price_min_pkr === 'number' && typeof args.price_max_pkr === 'number') {
      updates.price_range_pkr = [args.price_min_pkr, args.price_max_pkr];
    }
    if (args.availability && typeof args.availability === 'object') {
      updates.availability = { ...(existing.availability ?? {}), ...args.availability };
    }
    const updated = { ...existing, ...updates };
    await addProvider(updated, userId);
    return {
      status: 'updated',
      provider_id: providerId,
      changed_fields: Object.keys(updates),
      summary: `Updated ${Object.keys(updates).join(', ') || 'profile (created)'}.`,
    };
  }

  if (toolName === 'set_availability_override') {
    const overrides: any[] = Array.isArray(existing.availability_overrides)
      ? [...existing.availability_overrides]
      : [];
    const existingIdx = overrides.findIndex((o) => o?.date === args.date);
    const entry: any = { date: args.date, hours: Array.isArray(args.hours) ? args.hours : [] };
    if (args.note) entry.note = args.note;
    if (existingIdx >= 0) overrides[existingIdx] = entry;
    else overrides.push(entry);
    const updated = { ...existing, availability_overrides: overrides };
    await addProvider(updated, userId);
    return {
      status: 'override_set',
      date: args.date,
      hours: entry.hours,
      summary: entry.hours.length === 0
        ? `${args.date}: closed all day.`
        : `${args.date}: open ${entry.hours.join(', ')}.`,
    };
  }

  if (toolName === 'remove_availability_override') {
    const overrides: any[] = Array.isArray(existing.availability_overrides)
      ? existing.availability_overrides.filter((o: any) => o?.date !== args.date)
      : [];
    const updated = { ...existing, availability_overrides: overrides };
    await addProvider(updated, userId);
    return {
      status: 'override_removed',
      date: args.date,
      summary: `Removed override for ${args.date}.`,
    };
  }

  return { error: 'unknown_tool', summary: `Unknown tool ${toolName}.` };
}

let _ai: GoogleGenAI | null = null;
function getAi(): GoogleGenAI {
  if (_ai) return _ai;
  // Prefer AI Studio (apikey) for Live — Vertex's Live model availability
  // is patchy by region. AI Studio works globally with a single key.
  if (LIVE_USE_APIKEY && config.gemini.apiKey) {
    _ai = new GoogleGenAI({ apiKey: config.gemini.apiKey });
    console.log('[live] using AI Studio (apikey) for Live');
  } else if (config.gemini.useVertex && config.gcp.projectId) {
    _ai = new GoogleGenAI({
      vertexai: true,
      project: config.gcp.projectId,
      location: config.gcp.location,
    });
    console.log('[live] using Vertex AI for Live');
  } else if (config.gemini.apiKey) {
    _ai = new GoogleGenAI({ apiKey: config.gemini.apiKey });
  } else {
    throw new Error('No Gemini auth — set USE_VERTEX_AI + GCP_PROJECT or GEMINI_API_KEY');
  }
  return _ai;
}

/** Run our existing 5-agent orchestrator from a Live tool call. Collects
 *  trace events so we can stream them back to the mobile client (the trace
 *  panel still works during voice mode). Returns a human-readable summary
 *  for the model to narrate. */
async function executeBookingPipeline(
  userRequest: string,
  ctx: { user_id: string; language: string; user_gender: string },
  emitStep: (step: unknown) => void
): Promise<Record<string, unknown>> {
  // Single voice-mode pass: intent + deterministic discovery + auto-pick
  // candidate #1 + booking. Skips the ranking LLM call (15+ s saved).
  // If discovery comes back empty we fall back to the normal pipeline
  // so the user gets a "no providers nearby" reply instead of a crash.
  const first = await drainPipeline(
    {
      user_id: ctx.user_id,
      user_input: userRequest,
      language: ctx.language,
      user_gender: ctx.user_gender,
      voice_mode: true,
    },
    emitStep,
    { earlyReturnOnBooking: true }
  );

  // Voice has no good way to render a picker UI. If the pipeline ended
  // with multiple options, auto-pick the TOP one (it's the ranking
  // agent's #1 recommendation) and re-run with that selection locked,
  // so the model gets a confirmed booking back to narrate — not a
  // "please select" prompt.
  // If a booking landed, look it up by id to get the rich provider
  // details (name, rating, neighborhood, price range, time). The booking
  // agent's own output doesn't carry these fields — they were only on
  // the booking row that the create_booking tool wrote. Without this
  // lookup the Live model gets {provider_name: null} and ends up
  // narrating "booking confirmed with the provider for null".
  if (first.booking_id) {
    const booking = await getBookingFromStore(first.booking_id);
    if (booking) {
      const b: any = booking;
      return {
        status: 'booked',
        booking_id: b.id,
        provider_name: b.provider_name ?? 'the provider',
        provider_rating: b.provider_rating ?? null,
        provider_neighborhood: b.provider_neighborhood ?? null,
        service_category: b.service_category_id ?? null,
        time_iso: b.time_iso ?? null,
        price_range_pkr: b.estimated_price_pkr ?? null,
        summary: `Booked ${b.service_category_id} with ${b.provider_name} (${b.provider_rating ?? '?'}★, ${b.provider_neighborhood ?? 'nearby'}) for ${b.time_iso}. Price ${(b.estimated_price_pkr ?? []).join('-')} PKR.`,
      };
    }
  }

  // Booking didn't land — return a minimal failure shape the model
  // can turn into a graceful "I couldn't find anyone" message.
  return {
    status: first.status,
    booking_id: null,
    summary: first.summary || `No booking — status=${first.status}.`,
  };
}

/** Run runPipeline forward, forwarding step events to the caller. The
 *  promise resolves AS SOON AS we have enough information to talk to the
 *  user — booking-step output OR run_complete OR awaiting_user_input —
 *  whichever comes first. Remaining steps (notably follow-up, which adds
 *  ~10–15 s for no UX benefit in voice mode) drain in the background. */
async function drainPipeline(
  input: {
    user_id: string;
    user_input: string;
    language: string;
    user_gender: string;
    selected_provider_id?: string;
    selected_time_iso?: string;
    prior_intent?: any;
    voice_mode?: boolean;
  },
  emitStep: (step: unknown) => void,
  opts: { earlyReturnOnBooking: boolean } = { earlyReturnOnBooking: false }
): Promise<any> {
  const gen = runPipeline(input);
  const collected: any = {
    booking_id: null,
    status: 'unknown',
    summary: '',
    last_user_message: '',
    options: [],
    intent: null,
    provider: null,
    time_iso: null,
  };
  let returned = false;
  const result: Promise<any> = new Promise(async (resolve) => {
    while (true) {
      const r = await gen.next();
      if (r.done) {
        if (!returned) {
          returned = true;
          collected.summary = collected.last_user_message ||
            `Pipeline finished, status=${collected.status}`;
          resolve(collected);
        }
        return;
      }
      const evt: any = r.value;
      emitStep(evt);
      if (evt.event === 'user_message') {
        const txt = (evt.data?.text as string) ?? '';
        if (txt) collected.last_user_message = txt;
        const alts = evt.data?.alternatives as any[] | undefined;
        if (alts && alts.length > 0) {
          collected.options = alts.map((a) => ({
            provider_id: a.provider_id,
            provider_name: a.provider_name,
            iso: a.iso,
            label: a.label,
          }));
        }
      } else if (evt.event === 'step' && evt.data?.agent === 'intent') {
        collected.intent = evt.data.output;
      } else if (evt.event === 'step' && evt.data?.agent === 'booking') {
        const out = evt.data.output;
        if (out?.booking_id) collected.booking_id = out.booking_id;
        if (out?.status) collected.status = out.status;
        if (out?.provider) collected.provider = out.provider;
        if (out?.time_iso) collected.time_iso = out.time_iso;
        // Voice mode optimization: as soon as the booking step lands,
        // hand the result back so Gemini Live can start narrating. The
        // follow-up agent will continue draining in the background.
        if (opts.earlyReturnOnBooking && !returned && collected.booking_id) {
          returned = true;
          collected.summary = `Booking ${collected.status}, id=${collected.booking_id}`;
          resolve(collected);
        }
      } else if (evt.event === 'run_complete') {
        const s = evt.data?.status as string | undefined;
        if (s === 'awaiting_user_input') collected.status = 'needs_user_input';
        else if (collected.status === 'unknown' && s) collected.status = s;
        if (!returned) {
          returned = true;
          collected.summary = collected.last_user_message ||
            `Pipeline finished, status=${collected.status}`;
          resolve(collected);
        }
        // Keep draining (cheap) so the follow-up agent still runs.
      }
    }
  });
  return result;
}

export function attachLiveVoice(server: HttpServer): void {
  const wss = new WebSocketServer({ noServer: true });

  server.on('upgrade', (req, socket, head) => {
    if (!req.url?.startsWith('/voice/live')) return; // let other ws routes pass
    wss.handleUpgrade(req, socket, head, (ws) => {
      wss.emit('connection', ws, req);
    });
  });

  wss.on('connection', (ws: WebSocket) => {
    console.log('[live] client connected');
    let session: Session | null = null;
    let userId = 'voice_anon';
    let userName = '';
    let language = 'roman_ur';
    let userGender = 'female';
    let mode: 'user' | 'provider' = 'user';
    let closed = false;

    const send = (frame: ServerFrame) => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(frame));
      }
    };

    const closeAll = (reason?: string) => {
      if (closed) return;
      closed = true;
      try {
        session?.close();
      } catch {}
      try {
        ws.close(1000, reason);
      } catch {}
    };

    ws.on('message', async (raw) => {
      let frame: ClientFrame;
      try {
        frame = JSON.parse(raw.toString());
      } catch {
        send({ type: 'error', error: 'invalid_json' });
        return;
      }

      if (frame.type === 'auth') {
        // Open the Live session with the user's profile + tool config.
        try {
          userId = frame.user_id ?? userId;
          userName = (frame.user_name ?? '').trim();
          language = frame.language ?? language;
          userGender = frame.user_gender ?? userGender;
          mode = frame.mode === 'provider' ? 'provider' : 'user';

          // Compute Pakistan-local today / tomorrow so the provider-mode
          // prompt can resolve "kal" / "aaj" before calling tools.
          const nowIsoPK = new Date()
            .toLocaleString('sv-SE', { timeZone: 'Asia/Karachi' })
            .replace(' ', 'T') + '+05:00';
          const todayPK = nowIsoPK.slice(0, 10);
          const [_y, _m, _d] = todayPK.split('-').map((s) => parseInt(s, 10));
          const _tomorrow = new Date(Date.UTC(_y, _m - 1, _d + 1)).toISOString().slice(0, 10);

          // For provider mode, check whether they already have a profile.
          // No profile → use the signup walkthrough prompt that collects
          // fields one at a time. Existing profile → use the regular
          // profile-management prompt.
          let isProviderSignup = false;
          if (mode === 'provider') {
            try {
              const existingPid = await getProviderIdForUser(userId);
              const existingProfile = existingPid
                ? await getProviderFromFirestore(existingPid)
                : null;
              isProviderSignup = !existingProfile;
              console.log(
                `[live] provider mode: ${isProviderSignup ? 'SIGNUP' : 'EDIT'} (pid=${existingPid ?? 'none'})`,
              );
            } catch (e: any) {
              console.warn('[live] provider profile lookup failed (defaulting to edit):', e?.message ?? e);
            }
          }

          const baseSystemPrompt =
            mode === 'provider'
              ? (isProviderSignup ? PROVIDER_SIGNUP_PROMPT : PROVIDER_SYSTEM_PROMPT)
              : SYSTEM_PROMPT;

          const personalSystemPrompt =
            baseSystemPrompt +
            `\n\n═══════════════════════════════════════════════════════\n` +
            `USER INFO\n` +
            `═══════════════════════════════════════════════════════\n` +
            `Name: ${userName || '(unknown)'}\n` +
            `Gender: ${userGender}\n` +
            `Language: ${language}\n` +
            `Mode: ${mode}\n` +
            `Today (Asia/Karachi): ${todayPK}. "kal" / "tomorrow" = ${_tomorrow}.\n` +
            (mode === 'provider'
              ? (isProviderSignup
                ? (userName
                  ? `When the session opens, your VERY FIRST utterance must greet the new provider warmly: "Assalamu Alaikum ${userName}! Aap ka profile setup karne mein madad karta/karti hoon. Pehle batayein — aap ka business ya naam kya hai?" — start the signup flow immediately, don't wait for them to speak first.`
                  : `When the session opens, your VERY FIRST utterance must be: "Assalamu Alaikum! TapKar pe register karne aaye hain? Pehle batayein, aap ka business ya naam kya hai?" — don't wait for the user to speak first.`)
                : (userName
                  ? `When the session opens, your VERY FIRST utterance must be a warm greeting: "Assalamu Alaikum ${userName}! Apne profile mein kya update karna hai?" — don't wait for them to speak first.`
                  : `When the session opens, your VERY FIRST utterance must be: "Assalamu Alaikum! Profile update karne ke liye batayein kya chahiye." — don't wait.`))
              : (userName
                ? `When the session opens, your VERY FIRST utterance must greet ${userName} by name: "Assalamu Alaikum ${userName}!" — warm, friendly, then ask how you can help ("kaisi madad chahiye?" / "kya kaam karwana hai aaj?"). Don't wait for the user to speak first.`
                : `When the session opens, your VERY FIRST utterance must be: "Assalamu Alaikum! TapKar AI mein khush aamdeed. Kya kaam karwana hai aaj?" — don't wait for the user to speak first.`));

          session = await getAi().live.connect({
            model: LIVE_MODEL,
            config: {
              responseModalities: [Modality.AUDIO],
              systemInstruction: {
                parts: [{ text: personalSystemPrompt }],
              },
              tools: [(mode === 'provider' ? PROVIDER_TOOLS : BOOKING_TOOL) as any],
              // Voice picked per user gender (matches our gender-aware
              // TTS strategy elsewhere in the app).
              speechConfig: {
                voiceConfig: {
                  prebuiltVoiceConfig: {
                    voiceName: userGender === 'male' ? 'Puck' : 'Aoede',
                  },
                },
              } as any,
            } as any,
            callbacks: {
              onopen: () => {
                console.log('[live] session opened');
                send({ type: 'ready', state: 'listening' });
              },
              onmessage: async (msg: any) => {
                try {
                  // Audio chunks from the model.
                  const audioInline =
                    msg.serverContent?.modelTurn?.parts?.find(
                      (p: any) => p.inlineData?.mimeType?.startsWith('audio/')
                    );
                  if (audioInline) {
                    send({
                      type: 'audio',
                      audio: audioInline.inlineData.data,
                      state: 'speaking',
                    });
                  }

                  // Text transcript (when present) — shows what the bot is saying.
                  const textPart = msg.serverContent?.modelTurn?.parts?.find(
                    (p: any) => p.text
                  );
                  if (textPart?.text) {
                    send({ type: 'transcript', text: textPart.text });
                  }

                  // Tool call requested by the model.
                  if (msg.toolCall?.functionCalls?.length) {
                    for (const fc of msg.toolCall.functionCalls) {
                      console.log(`[live] tool call: ${fc.name}`);
                      send({
                        type: 'tool_call',
                        tool: { name: fc.name, args: fc.args },
                        state: 'thinking',
                      });
                      const isProviderTool =
                        fc.name === 'update_provider_profile' ||
                        fc.name === 'set_availability_override' ||
                        fc.name === 'remove_availability_override';

                      if (fc.name === 'book_a_service') {
                        try {
                          const result = await executeBookingPipeline(
                            (fc.args?.user_request as string) ?? '',
                            { user_id: userId, language, user_gender: userGender },
                            (step) => send({ type: 'agent_step', step }),
                          );
                          // Send result back to Live so the model can narrate it.
                          session?.sendToolResponse({
                            functionResponses: [
                              {
                                id: fc.id,
                                name: fc.name,
                                response: result,
                              },
                            ],
                          });
                          send({ type: 'tool_result', step: result, state: 'speaking' });
                        } catch (err: any) {
                          session?.sendToolResponse({
                            functionResponses: [
                              {
                                id: fc.id,
                                name: fc.name,
                                response: { error: err?.message ?? String(err) },
                              },
                            ],
                          });
                        }
                      } else if (isProviderTool) {
                        try {
                          const result = await executeProviderTool(fc.name, fc.args ?? {}, userId);
                          console.log(`[live] provider tool ${fc.name} ->`, JSON.stringify(result).slice(0, 120));
                          session?.sendToolResponse({
                            functionResponses: [
                              { id: fc.id, name: fc.name, response: result },
                            ],
                          });
                          send({ type: 'tool_result', step: result, state: 'speaking' });
                        } catch (err: any) {
                          console.error(`[live] provider tool ${fc.name} failed:`, err?.message ?? err);
                          session?.sendToolResponse({
                            functionResponses: [
                              {
                                id: fc.id,
                                name: fc.name,
                                response: { error: err?.message ?? String(err) },
                              },
                            ],
                          });
                        }
                      }
                    }
                  }

                  // Turn complete = bot finished speaking, back to listening.
                  if (msg.serverContent?.turnComplete) {
                    send({ type: 'turn_complete', state: 'listening' });
                  }
                } catch (handlerErr: any) {
                  console.error('[live] onmessage handler error:', handlerErr?.message ?? handlerErr);
                }
              },
              onerror: (err: any) => {
                console.error('[live] session error full:', JSON.stringify(err, Object.getOwnPropertyNames(err) ?? []) || err?.message || err);
                send({ type: 'error', error: err?.message ?? err?.toString?.() ?? String(err) });
              },
              onclose: (e: any) => {
                console.log(`[live] session closed: code=${e?.code} reason=${e?.reason} wasClean=${e?.wasClean}`);
                // Gemini Live sends a GoAway and then closes the session
                // when the per-session duration cap is reached (~10 min by
                // default for audio). Surface a specific error so the
                // client can show "Session ended — tap to reconnect" rather
                // than the generic "Voice unavailable".
                const isSessionTimeout =
                  e?.code === 1008 || /goaway|session durat/i.test(String(e?.reason ?? ''));
                if (isSessionTimeout) {
                  send({ type: 'error', error: 'session_timeout' });
                }
                closeAll('session_closed');
              },
            },
          });

          // Now that `session` is actually assigned (the await above just
          // resolved + onopen has fired), kick the model into producing
          // the Salaam greeting. Without a prompt, Live sits silent
          // until the user speaks first. The greeting trigger MUST live
          // here — not inside the onopen callback — because onopen runs
          // before this await returns, so the `session` reference there
          // is still null and any sendClientContent silently no-ops.
          try {
            session.sendClientContent({
              turns: [
                {
                  role: 'user',
                  parts: [
                    {
                      text:
                        '[SYSTEM] Voice session has just opened. Greet ' +
                        (userName || 'the user') +
                        ' now per your system instructions ("Assalamu Alaikum ...") and ask how you can help. Do not wait for them to speak first.',
                    },
                  ],
                },
              ],
              turnComplete: true,
            });
            console.log('[live] greeting trigger sent');
          } catch (e: any) {
            console.warn('[live] greeting trigger failed:', e?.message ?? e);
          }
        } catch (connectErr: any) {
          console.error('[live] connect failed:', connectErr?.message ?? connectErr);
          send({ type: 'error', error: `live_connect_failed: ${connectErr?.message ?? connectErr}` });
          closeAll('connect_failed');
        }
        return;
      }

      if (!session) {
        send({ type: 'error', error: 'send_auth_first' });
        return;
      }

      if (frame.type === 'audio' && frame.audio) {
        // Forward client mic audio to the Live session.
        // Use `audio` (current API) — `media` is deprecated and the server
        // closes the session with code=1007 if you use it for audio chunks.
        session.sendRealtimeInput({
          audio: {
            data: frame.audio,
            mimeType: 'audio/pcm;rate=16000',
          },
        });
        return;
      }

      if (frame.type === 'text' && frame.text) {
        session.sendClientContent({
          turns: [{ role: 'user', parts: [{ text: frame.text }] }],
          turnComplete: true,
        });
        return;
      }

      if (frame.type === 'close') {
        closeAll('client_close');
      }
    });

    ws.on('close', () => {
      console.log('[live] client disconnected');
      closeAll('client_disconnect');
    });

    ws.on('error', (err) => {
      console.error('[live] ws error:', err?.message ?? err);
      closeAll('ws_error');
    });
  });

  console.log('[live] WebSocket bridge attached at /voice/live');
}
