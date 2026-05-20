/**
 * TapKar AI backend — Express entry point.
 *
 * POST /run            — Run a request through the agent pipeline, streaming
 *                        reasoning steps as Server-Sent Events.
 * GET  /traces/:run_id — Fetch a completed trace document.
 * GET  /healthz        — Liveness probe (Cloud Run health check).
 *
 * Compliance: this service has zero Antigravity dependency. It needs only a
 * Gemini API key (and optionally GCP credentials for Firestore).
 */

// MUST be the very first import — loads .env into process.env before
// config.ts reads it.
import 'dotenv/config';

import express, { type Request, type Response } from 'express';
import { z } from 'zod';
import { config, validateConfig } from './config.js';
import { runPipeline } from './orchestrator.js';
import {
  getTrace,
  getBookingFromStore,
  updateBookingStatusInStore,
  listAllBookingsForProvider,
  listInboxForProvider,
  listBookingsForUser,
  listInboxForUser,
  listScheduledForUser,
} from './store.js';
import { loadProviders, addProvider, getProviderIdForUser, hydrateProvidersFromFirestore } from './data.js';

const app = express();
app.use(express.json({ limit: '1mb' }));

// ─── CORS for the mobile app & dev tools ─────────────────────────────────────
app.use((req, res, next) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Cache-Control');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});

// ─── Health ──────────────────────────────────────────────────────────────────
// We expose /status (and /, and /healthz) so Cloud Run's frontend doesn't
// intercept the path — Cloud Run reserves some health-check paths and
// returns its own 404 for them.
const healthHandler = (_req: Request, res: Response) => {
  res.json({
    ok: true,
    service: 'tapkar-ai-backend',
    mode: config.gemini.useVertex ? 'vertex' : 'apikey',
    has_gemini_key: Boolean(config.gemini.apiKey),
    vertex_project: config.gcp.projectId || null,
    firestore_enabled: config.useFirestore,
    real_places_enabled: config.features.useRealPlaces,
    uptime_s: Math.round(process.uptime()),
  });
};
app.get('/', healthHandler);
app.get('/status', healthHandler);
app.get('/healthz', healthHandler);
// Lightweight keep-warm probe — returns 200 fast without touching any
// dependencies. Hit this every ~5 min from a cron to keep the Cloud Run
// instance hot during demo recordings.
app.get('/ping', (_req, res) => res.json({ pong: true, t: Date.now() }));

// ─── Run a pipeline (SSE stream) ─────────────────────────────────────────────
const RunBodySchema = z.object({
  user_id: z.string().min(1),
  user_input: z.string().min(1).max(2000),
  language: z.string().optional(),
  /** Set when the user picked a provider from a previous "show_options" turn —
   *  orchestrator skips ranking and books that provider directly. */
  selected_provider_id: z.string().optional(),
  selected_time_iso: z.string().optional(),
  /** Frontend can echo back the intent it captured from the previous /run so
   *  the orchestrator skips re-parsing intent in locked mode. Saves ~10s. */
  prior_intent: z.any().optional(),
  /** User's gender. Bot adopts matching grammatical gender when replying in
   *  Urdu / Roman Urdu (verbs like "kar rahi hoon" vs "kar raha hoon"). */
  user_gender: z.enum(['female', 'male', 'other']).optional(),
});

app.post('/run', async (req: Request, res: Response) => {
  console.log(`[run] POST /run received from ${req.ip}, body keys: ${Object.keys(req.body ?? {}).join(',')}`);
  const parsed = RunBodySchema.safeParse(req.body);
  if (!parsed.success) {
    console.log(`[run] body validation failed:`, parsed.error.flatten());
    return res.status(400).json({ error: 'invalid_body', details: parsed.error.flatten() });
  }
  console.log(`[run] user_input: "${parsed.data.user_input.slice(0, 80)}"`);

  if (!config.gemini.useVertex && !config.gemini.apiKey) {
    return res.status(500).json({
      error: 'gemini_auth_missing',
      hint: 'Set GEMINI_API_KEY (AI Studio) or USE_VERTEX_AI=true + GCP_PROJECT in backend/.env',
    });
  }

  // ─── Start SSE stream ─────────────────────────────────────────────────────
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache, no-transform');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('X-Accel-Buffering', 'no'); // disable proxy buffering
  res.flushHeaders();
  console.log(`[run] SSE headers flushed, starting pipeline...`);

  const writeEvent = (event: string, data: unknown) => {
    const line = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
    res.write(line);
    if ((res as any).flush) (res as any).flush(); // force flush if compression mw added later
    console.log(`[run] → SSE event "${event}" (${line.length} bytes)`);
  };

  // Heartbeat so proxies don't drop the connection
  const heartbeat = setInterval(() => res.write(': ping\n\n'), 15_000);

  // Hard timeout for the whole run
  const timeout = setTimeout(() => {
    writeEvent('error', { error: 'run_timeout', limit_ms: config.limits.runTimeoutMs });
    clearInterval(heartbeat);
    res.end();
  }, config.limits.runTimeoutMs);

  // Detect actual client disconnect via the RESPONSE socket — not req.on('close'),
  // which fires when the body stream is fully consumed (a common Node.js footgun).
  let clientClosed = false;
  res.on('close', () => {
    if (!res.writableEnded) {
      clientClosed = true;
      console.log('[run] response socket closed by client (disconnect)');
    }
  });

  try {
    const gen = runPipeline(parsed.data);
    let iterCount = 0;
    while (true) {
      iterCount++;
      const result = await gen.next();
      if (result.done) break;
      if (clientClosed) {
        console.log('[run] client disconnected, breaking');
        break;
      }
      writeEvent(result.value.event, result.value.data);
      if (result.value.event === 'run_complete' || result.value.event === 'error') break;
    }
    console.log(`[run] iteration finished after ${iterCount} iterations`);
  } catch (err: any) {
    console.error('[run] iteration threw:', err?.message ?? err);
    if (!res.writableEnded) writeEvent('error', { error: err?.message ?? String(err) });
  } finally {
    clearInterval(heartbeat);
    clearTimeout(timeout);
    if (!res.writableEnded) res.end();
  }
});

// (diagnostic endpoints — /ping-sse, /ping-runagent, /ping-gemini,
// /ping-gemini-fc — were removed. They leaked internal Gemini config and
// weren't needed in production.)

// ─── AI-driven provider onboarding / profile editing ────────────────────────
// One-shot LLM endpoint. Frontend sends user's latest message + the draft
// profile built up so far + mode ('signup' | 'edit'); we extract fields,
// produce the next question, and signal when the draft is complete enough
// to save. No forms — pure conversational setup.
const ProviderChatSchema = z.object({
  user_id: z.string().min(1),
  message: z.string().min(1).max(500),
  draft: z.record(z.string(), z.any()).optional().default({}),
  mode: z.enum(['signup', 'edit']).optional().default('signup'),
  language: z.enum(['en', 'ur', 'roman_ur']).optional().default('roman_ur'),
  user_gender: z.enum(['female', 'male', 'other']).optional().default('female'),
});

app.post('/provider/chat', async (req: Request, res: Response) => {
  const parsed = ProviderChatSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: 'invalid_body', details: parsed.error.flatten() });
  }
  const { message, draft, mode, language, user_gender } = parsed.data;

  const langName = language === 'ur' ? 'Urdu (Nastaliq)'
                  : language === 'roman_ur' ? 'Roman Urdu'
                  : 'English';
  const genderTone = user_gender === 'female'
    ? 'Speak in FEMININE first-person ("kar rahi hoon", "poochh rahi hoon") for Roman Urdu / Urdu.'
    : 'Speak in MASCULINE first-person ("kar raha hoon", "poochh raha hoon") for Roman Urdu / Urdu.';

  const REQUIRED = ['name', 'category', 'neighborhood', 'gender', 'price_range_pkr', 'languages', 'phone', 'availability'];
  const filledNow = REQUIRED.filter((k) => {
    const v = (draft as any)[k];
    if (v === null || v === undefined) return false;
    if (Array.isArray(v) && v.length === 0) return false;
    if (typeof v === 'object' && Object.keys(v).length === 0) return false;
    return true;
  });
  const missingNow = REQUIRED.filter((k) => !filledNow.includes(k));

  const signupBody = `MODE: SIGNUP — collect the missing required fields ONE AT A TIME until the draft is complete.

ALREADY FILLED (do NOT re-ask these): ${filledNow.join(', ') || '(none yet)'}
STILL MISSING: ${missingNow.join(', ') || '(all filled — set complete=true)'}

If the user's latest message provides a field that's missing, extract it into the draft and ask for the next missing one. Never ask for a field that's already in the "already filled" list.`;

  const editBody = `MODE: EDIT — the user already has a profile and wants to change something.

CURRENT PROFILE FIELDS: ${filledNow.join(', ')}

Behavior:
- Treat the user's latest message as a change request. Extract what they want changed and update the draft accordingly.
- After applying the change, CONFIRM the change in one short sentence and ask "anything else to change?" in ${langName}.
- If the user says they're done / nothing else / save / "bas itna hi" / "ho gaya" → set complete=true and reply with a one-line confirmation.
- NEVER re-ask for fields that are already in the profile. The user is editing, not signing up — they only mention what they want to change.
- Don't blank out existing values unless the user explicitly says to remove them.`;

  // Pakistan-local "today" + day-of-week for any relative phrases like
  // "aaj se", "kal se", "har Friday". Without this the model has no
  // ground truth for which weekday "today" is and assigns hours to the
  // wrong day.
  const nowIsoPK = new Date()
    .toLocaleString('sv-SE', { timeZone: 'Asia/Karachi' })
    .replace(' ', 'T') + '+05:00';
  const todayPK = nowIsoPK.slice(0, 10);
  const dayNamesPK = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'];
  const [py, pm, pd] = todayPK.split('-').map((s) => parseInt(s, 10));
  const todayDow = dayNamesPK[new Date(Date.UTC(py, pm - 1, pd)).getUTCDay()];
  const tomorrowDow = dayNamesPK[new Date(Date.UTC(py, pm - 1, pd + 1)).getUTCDay()];

  const systemPrompt = `Tum TapKar AI ho — ek Karachi wala seedha-saadha helper jo service providers (plumber, AC wala, tutor, beautician, mehndi, etc.) ka profile setup karne mein madad karta hai. Tum koi formal customer-service bot nahi — tum ek dost ki tarah baat karte ho.

KAISE BAAT KARNI HAI (yeh tumhari personality hai):
- Bilkul aam Karachi insaan ki tarah. "haan ji", "achha", "theek hai", "OK", "samajh gaya/gayi", "bilkul" — natural use karo, robot ki tarah nahi.
- ${langName} mein baat karo, par 1-2 sentence at a time. Short. Friendly.
- Empathy real ho — provider naya hai, samajh raha hai system ko. Patience se ek field ek time pucho.
- Same wording har baar repeat mat karo. Naturally vary karo. Static template avoid karo.
- Provider hi rakh chuka hai jo info, dobara mat poochho — confirm karke aage badho.

CURRENT TIME (Asia/Karachi): ${nowIsoPK}
TODAY is ${todayDow}. "aaj" / "today" = ${todayDow}. "kal" / "tomorrow" = ${tomorrowDow}.
When the provider says "aaj se" / "from today" → apply hours starting from ${todayDow}. When they say "har ${todayDow}" → it means weekly on ${todayDow}. Never guess the day-of-week for relative phrases — these are the source of truth.

${genderTone}

DRAFT (current profile state):
\`\`\`json
${JSON.stringify(draft, null, 2)}
\`\`\`

${mode === 'signup' ? signupBody : editBody}

VALID VALUES:
- category: one of plumber, electrician, ac_technician, carpenter, painter, locksmith, welder, mason, pest_control, cctv_installer, internet_tech, mobile_repair, laptop_repair, auto_mechanic, mehndi_artist, photographer, event_planner, beautician, tutor, quran_teacher, cook, cleaner, driver, personal_trainer, yoga_instructor, gardener, babysitter, eldercare, laundry, tailor, packer_mover, massage_therapist
- neighborhood: Karachi area name (Gulshan-e-Iqbal, DHA Phase 5, Clifton, North Nazimabad, Bahadurabad, Saddar, Korangi, Federal B Area, PECHS, Tariq Road, etc.)
- gender: "female" or "male"
- price_range_pkr: [min, max] integers in PKR
- languages: subset of ["ur", "roman_ur", "en"]
- phone: 10-digit local number like "3001234567"
- availability: object with keys monday..sunday, each an array of "HH:MM-HH:MM" ranges. Empty array = closed that day.

EXTRACTION RULES:
- "5000 se 10000 tak" → price_range_pkr: [5000, 10000]
- "main female hoon" / "I'm male" → gender field
- "Clifton bhi add karein service area mein" → add to service_areas (NOT neighborhood)
- Don't invent fields not mentioned.

AVAILABILITY RULES (READ CAREFULLY — customers complain when this is wrong):

1. The \`availability\` map MUST contain ALL seven keys: monday, tuesday, wednesday, thursday, friday, saturday, sunday. Each value is an array of "HH:MM-HH:MM" ranges, or [] if closed.

2. PRESERVE days the user didn't explicitly mention. If the draft already has availability for Tuesday and the user only mentions Monday, keep Tuesday as-is in your output. Never overwrite an existing day's hours unless the user specifically referenced that day.

3. Generic blanket statements apply to weekdays only (Mon–Sat) and leave Sunday alone unless explicitly mentioned:
   - "subah 9 se shaam 6 tak" → Mon-Sat get ["09:00-18:00"], Sunday stays as-is.
   - "weekend off" → saturday and sunday become [].
   - "Friday short hours" → only Friday changes; others preserved.

4. Per-day customisation must be honored:
   - "Monday Wednesday Friday 5 se 9 baje raat" → only mon/wed/fri get ["17:00-21:00"], others preserved.
   - "Mehndi artist hoon, hafte mein 3 din 4 baje se 9 tak" → ask WHICH 3 days before assigning hours. Don't guess.

5. Multiple ranges per day are valid:
   - "subah 9-12 aur shaam 5-9" on Tuesday → tuesday: ["09:00-12:00", "17:00-21:00"].

6. When asking the user about availability for the FIRST time, ask in a way that invites per-day customization:
   - "Kaam ke aukaat kya hain? Same hours daily ya kuch din different? (e.g. 'subah 9 se shaam 6 har din', ya 'Mon-Fri 9-6, weekend 10-2')"

7. NEVER assign the same single range to every day automatically as a default. If the user says only "10 to 2" with no day reference and no prior context, ASK which days that applies to.

DATE-SPECIFIC EXCEPTIONS (CRITICAL — yeh feature important hai):

The provider has a second field \`availability_overrides\` (array). USE THIS — not the weekly map — whenever the user mentions a SPECIFIC DATE or RELATIVE DATE ("kal", "parsoo", "Friday 25th", "next Monday", "tomorrow", "today").

Shape: \`availability_overrides: [{ date: "YYYY-MM-DD", hours: ["HH:MM-HH:MM", ...], note?: "string" }]\`

Resolve relative dates against today:
- "aaj" / "today" → date: ${todayPK}
- "kal" / "tomorrow" → date: ${dayNamesPK[new Date(Date.UTC(py, pm - 1, pd + 1)).getUTCDay()]} ${(() => { const d = new Date(Date.UTC(py, pm - 1, pd + 1)); return d.toISOString().slice(0, 10); })()}
- "parsoo" / "day after tomorrow" → date: ${(() => { const d = new Date(Date.UTC(py, pm - 1, pd + 2)); return d.toISOString().slice(0, 10); })()}

Examples:
- "Kal 10 se 12 nahi mein" → add override { date: "<kal>", hours: ["00:00-10:00", "12:00-23:59"], note: "10-12 nahi" } (open all day except 10-12).
- "Kal sara din chhutti" / "kal off" → { date: "<kal>", hours: [], note: "off" }.
- "Aaj 5 baje ke baad available" → { date: "<aaj>", hours: ["17:00-23:59"] }.
- User cancels an existing override: remove the entry for that date.

NEVER fold a date-specific exception into the WEEKLY \`availability\` map — that would make the change permanent. Always use \`availability_overrides\` for one-off dates.

After applying, your reply should confirm using the actual date you wrote: "Done — kal (${(() => { const d = new Date(Date.UTC(py, pm - 1, pd + 1)); return d.toISOString().slice(0, 10); })()}) ko 10-12 nahi available, baki sab time available rahega." Match the user's language.

Output STRICT JSON only (no commentary, no markdown fences):
{
  "draft": { ...full draft after merging the user's input — INCLUDE availability_overrides if changed... },
  "reply": "<one short conversational sentence in ${langName}>",
  "complete": <boolean — see MODE rules above>,
  "missing": [<list of required-field names still missing>]
}

USER'S LATEST MESSAGE: "${message}"`;

  try {
    const { GoogleGenAI } = await import('@google/genai');
    const client = config.gemini.useVertex
      ? new GoogleGenAI({ vertexai: true, project: config.gcp.projectId, location: config.gcp.location })
      : new GoogleGenAI({ apiKey: config.gemini.apiKey });
    const resp = await client.models.generateContent({
      model: 'gemini-2.5-flash-lite',
      contents: [{ role: 'user', parts: [{ text: systemPrompt }] }],
      config: { responseMimeType: 'application/json' } as any,
    });
    const text = resp.candidates?.[0]?.content?.parts?.map((p: any) => p.text).join('').trim() ?? '';
    let payload: any;
    try {
      payload = JSON.parse(text);
    } catch {
      // Strip ```json fences if model emitted them despite the mime type.
      const cleaned = text.replace(/^```(?:json)?/i, '').replace(/```\s*$/i, '').trim();
      payload = JSON.parse(cleaned);
    }
    res.json({
      draft: payload.draft ?? draft,
      reply: payload.reply ?? '',
      complete: payload.complete === true,
      missing: Array.isArray(payload.missing) ? payload.missing : [],
    });
  } catch (err: any) {
    console.error('[provider-chat] failed:', err?.message ?? err);
    res.status(500).json({ error: 'provider_chat_failed', message: err?.message ?? String(err) });
  }
});

// ─── AI-generated follow-up nudge ────────────────────────────────────────────
// Replaces the hardcoded "Are you still there?" reminder with a context-aware
// nudge generated from the actual conversation transcript. Frontend hits this
// after the user goes idle following a clarification question.
const FollowUpBodySchema = z.object({
  language: z.enum(['en', 'ur', 'roman_ur']).optional().default('en'),
  // The last few turns of the conversation, alternating user/bot.
  transcript: z.array(z.object({
    role: z.enum(['user', 'bot']),
    text: z.string(),
  })).min(1).max(20),
  // Which nudge attempt this is (1 = soft, 2 = closing). Affects the tone.
  attempt: z.number().int().min(1).max(3).default(1),
  // User's gender — bot speaks with matching grammatical gender in
  // Urdu/Roman Urdu first-person verbs.
  user_gender: z.enum(['female', 'male', 'other']).optional().default('female'),
});

app.post('/followup-nudge', async (req: Request, res: Response) => {
  const parsed = FollowUpBodySchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: 'invalid_body', details: parsed.error.flatten() });
  }
  const { language, transcript, attempt, user_gender } = parsed.data;

  // Build the system + user prompt
  const transcriptText = transcript
    .map((t) => `${t.role === 'user' ? 'User' : 'Bot'}: ${t.text}`)
    .join('\n');

  const langName = language === 'ur' ? 'Urdu (Nastaliq script)'
                  : language === 'roman_ur' ? 'Roman Urdu (Latin script)'
                  : 'English';

  const toneHint = attempt === 1
    ? 'gentle and patient — they may just be busy'
    : attempt === 2
    ? 'slightly firmer — let them know the booking will close soon if they don\'t reply'
    : 'final — explain you\'re closing the request, they can re-open anytime';

  // Bot speaks with the user's grammatical gender in Urdu / Roman Urdu.
  const genderHint = language === 'en'
    ? ''
    : user_gender === 'female'
    ? '\nIMPORTANT: write in FEMININE first-person form (e.g., "kar rahi hoon" / "کر رہی ہوں"), NOT masculine.'
    : '\nIMPORTANT: write in MASCULINE first-person form (e.g., "kar raha hoon" / "کر رہا ہوں").';

  const prompt = `You are a helpful service-booking assistant. The user was in the middle of booking but stopped replying after the bot's last question.

Write ONE short message (max 20 words) in ${langName} asking them to come back. The tone should be ${toneHint}. Reference what they were trying to do — be specific, not generic. Don't sound like a robot. Don't repeat the previous bot question verbatim.${genderHint}

Conversation so far:
${transcriptText}

Respond with ONLY the nudge message text, no quotes or commentary.`;

  try {
    const { GoogleGenAI } = await import('@google/genai');
    const client = config.gemini.useVertex
      ? new GoogleGenAI({ vertexai: true, project: config.gcp.projectId, location: config.gcp.location })
      : new GoogleGenAI({ apiKey: config.gemini.apiKey });
    const resp = await client.models.generateContent({
      // Flash-lite — this is a tiny generation, doesn't need full flash.
      model: 'gemini-2.5-flash-lite',
      contents: [{ role: 'user', parts: [{ text: prompt }] }],
    });
    const text = resp.candidates?.[0]?.content?.parts?.map((p: any) => p.text).join('').trim();
    if (!text) {
      return res.status(500).json({ error: 'empty_response' });
    }
    res.json({ message: text, language });
  } catch (err: any) {
    console.error('[followup-nudge] failed:', err?.message ?? err);
    res.status(500).json({ error: 'nudge_failed', message: err?.message ?? String(err) });
  }
});

// ─── Text-to-Speech (Cloud TTS via Neural2/Wavenet) ─────────────────────────
// Replaces the device's stock TTS engine (robotic) with Google's neural
// voices. Backend reads ADC on Cloud Run; locally needs gcloud ADC login.
const TtsBodySchema = z.object({
  text: z.string().min(1).max(2000),
  lang: z.enum(['en', 'ur', 'roman_ur']).optional().default('en'),
  // User's gender — bot voice matches automatically. No separate "voice
  // gender" toggle; this is the user's actual profile gender.
  gender: z.enum(['female', 'male', 'other']).optional().default('female'),
});

app.post('/tts', async (req: Request, res: Response) => {
  const parsed = TtsBodySchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: 'invalid_body', details: parsed.error.flatten() });
  }
  try {
    const { synthesize } = await import('./tts.js');
    // Treat 'other' as female by default — voice picks aren't binary in
    // practice; this just controls the timbre of the bot's voice.
    const voiceGender = parsed.data.gender === 'male' ? 'male' : 'female';
    const result = await synthesize(parsed.data.text, parsed.data.lang, voiceGender);
    res.setHeader('Content-Type', result.mime);
    res.setHeader('Content-Length', String(result.audio.length));
    // Surface engine + voice in response headers so the client (and curl
    // debug sessions) can verify which path actually rendered.
    res.setHeader('X-TTS-Engine', result.engine);
    res.setHeader('X-TTS-Voice', result.voiceUsed);
    res.setHeader('Access-Control-Expose-Headers', 'X-TTS-Engine, X-TTS-Voice');
    // The same text+lang always renders the same audio — let the mobile
    // client (and any CDN in front of us) cache for an hour.
    res.setHeader('Cache-Control', 'public, max-age=3600');
    res.send(result.audio);
  } catch (err: any) {
    console.error('[tts] synthesize failed:', err?.message ?? err);
    res.status(500).json({ error: 'tts_failed', message: err?.message ?? String(err) });
  }
});

// ─── Fetch a completed trace ─────────────────────────────────────────────────
app.get('/traces/:run_id', async (req, res) => {
  const trace = await getTrace(req.params.run_id);
  if (!trace) return res.status(404).json({ error: 'trace_not_found' });
  res.json(trace);
});

// ─── User-side endpoints (Home / Bookings / Inbox tabs) ─────────────────────

/** All bookings for the customer. */
app.get('/users/:user_id/bookings', async (req, res) => {
  const bookings = await listBookingsForUser(req.params.user_id);
  // Enrich with provider names for the UI
  const providers = loadProviders();
  const enriched = bookings.map((b) => {
    const p = providers.find((x) => x.id === b.provider_id);
    return {
      ...b,
      provider_name: p?.name ?? null,
      provider_phone: p?.phone ?? null,
      provider_rating: p?.rating ?? null,
      provider_neighborhood: p?.neighborhood ?? null,
    };
  });
  res.json({ bookings: enriched, total: enriched.length });
});

/** Inbox: notifications + scheduled reminders for the customer. */
app.get('/users/:user_id/inbox', async (req, res) => {
  const [messages, scheduled] = await Promise.all([
    listInboxForUser(req.params.user_id),
    listScheduledForUser(req.params.user_id),
  ]);
  res.json({
    messages,
    scheduled,
    total: messages.length + scheduled.length,
  });
});

// ─── Provider-mode endpoints (the marketplace's "other side") ───────────────

/** Register a new provider from the mobile onboarding wizard. The provider's
 *  Firebase user_id is recorded so subsequent logins resume their profile. */
const HoursSchema = z.array(z.string());
const RegisterProviderSchema = z.object({
  user_id: z.string().min(1), // Firebase UID owning this provider profile
  name: z.string().min(1),
  category: z.string().min(1), // primary service category
  additional_categories: z.array(z.string()).optional().default([]),
  specializations: z.array(z.string()).optional().default([]),
  // Provider gender — required for jobs that need a female provider
  // (bridal makeup, in-home beautician, female-only tutoring).
  gender: z.enum(['female', 'male', 'other']).optional().default('male'),
  neighborhood: z.string().min(1), // primary working area
  service_areas: z.array(z.string()).optional().default([]), // extra areas served
  lat: z.number().optional(),
  lng: z.number().optional(),
  service_radius_km: z.number().optional().default(10),
  languages: z.array(z.string()).optional().default(['ur']),
  price_range_pkr: z.tuple([z.number(), z.number()]).optional().default([1000, 5000]),
  availability: z.object({
    monday: HoursSchema.optional().default([]),
    tuesday: HoursSchema.optional().default([]),
    wednesday: HoursSchema.optional().default([]),
    thursday: HoursSchema.optional().default([]),
    friday: HoursSchema.optional().default([]),
    saturday: HoursSchema.optional().default([]),
    sunday: HoursSchema.optional().default([]),
  }).optional(),
  // Date-specific overrides to the weekly schedule. Each entry replaces
  // the weekly hours for that one date — e.g. "kal 10-12 nahi mein"
  // becomes { date: "2026-05-21", hours: ["00:00-10:00","12:00-23:59"] }
  // (open everything EXCEPT 10-12 that day). Empty hours = closed all
  // day on that date.
  availability_overrides: z.array(z.object({
    date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
    hours: z.array(z.string()).default([]),
    note: z.string().optional(),
  })).optional().default([]),
  phone: z.string().optional().default(''),
  bio: z.string().optional().default(''),
  profile_image_url: z.string().optional().default(''),
});
app.post('/providers/register', async (req, res) => {
  const parsed = RegisterProviderSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: 'invalid_body', details: parsed.error.flatten() });
  }
  const d = parsed.data;
  // Derive lat/lng from neighborhood if not provided
  let lat = d.lat;
  let lng = d.lng;
  if (lat == null || lng == null) {
    const tax = (await import('./data.js')).loadTaxonomy();
    const n = tax.neighborhoods_karachi.find((x: any) => x.name === d.neighborhood);
    if (n) { lat = n.lat; lng = n.lng; }
  }
  const id = `p_user_${d.user_id.slice(-8)}`;
  const provider: any = {
    id,
    name: d.name,
    category: d.category,
    additional_categories: d.additional_categories,
    specializations: d.specializations,
    gender: d.gender,
    neighborhood: d.neighborhood,
    service_areas: d.service_areas,
    lat: lat ?? 24.87,
    lng: lng ?? 67.03,
    service_radius_km: d.service_radius_km,
    rating: 0,
    review_count: 0,
    jobs_completed: 0,
    years_experience: 0,
    languages: d.languages,
    price_range_pkr: d.price_range_pkr,
    availability: d.availability ?? {},
    availability_overrides: d.availability_overrides ?? [],
    phone: d.phone,
    verified: false,
    tags: ['newly_registered'],
    bio: d.bio,
    profile_image_url: d.profile_image_url,
  };
  await addProvider(provider, d.user_id);
  res.json({ ok: true, provider_id: id, provider });
});

/** Update editable fields on an existing provider profile. Preserves
 *  rating/review_count/jobs_completed/verified — only what the provider
 *  themselves should be able to change. Ownership check: requester's
 *  Firebase user_id must match the provider's owner. */
const UpdateProviderSchema = z.object({
  user_id: z.string().min(1),
  name: z.string().optional(),
  category: z.string().optional(),
  additional_categories: z.array(z.string()).optional(),
  specializations: z.array(z.string()).optional(),
  gender: z.enum(['female', 'male', 'other']).optional(),
  available_now: z.boolean().optional(),
  neighborhood: z.string().optional(),
  service_areas: z.array(z.string()).optional(),
  service_radius_km: z.number().optional(),
  languages: z.array(z.string()).optional(),
  price_range_pkr: z.tuple([z.number(), z.number()]).optional(),
  availability: z.object({
    monday: HoursSchema.optional(),
    tuesday: HoursSchema.optional(),
    wednesday: HoursSchema.optional(),
    thursday: HoursSchema.optional(),
    friday: HoursSchema.optional(),
    saturday: HoursSchema.optional(),
    sunday: HoursSchema.optional(),
  }).optional(),
  // See RegisterProviderSchema — same shape. PATCH lets providers add,
  // edit, or remove one-off date exceptions via the chat assistant.
  availability_overrides: z.array(z.object({
    date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
    hours: z.array(z.string()).default([]),
    note: z.string().optional(),
  })).optional(),
  phone: z.string().optional(),
  bio: z.string().optional(),
  profile_image_url: z.string().optional(),
});
app.patch('/providers/:provider_id', async (req, res) => {
  const parsed = UpdateProviderSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: 'invalid_body', details: parsed.error.flatten() });
  }
  const ownerProviderId = await getProviderIdForUser(parsed.data.user_id);
  if (ownerProviderId !== req.params.provider_id) {
    return res.status(403).json({ error: 'not_your_profile' });
  }
  const existing = loadProviders().find((p) => p.id === req.params.provider_id);
  if (!existing) return res.status(404).json({ error: 'provider_not_found' });

  // If neighborhood changed, re-derive lat/lng from taxonomy
  let lat = existing.lat;
  let lng = existing.lng;
  if (parsed.data.neighborhood && parsed.data.neighborhood !== existing.neighborhood) {
    const tax = (await import('./data.js')).loadTaxonomy();
    const n = tax.neighborhoods_karachi.find((x: any) => x.name === parsed.data.neighborhood);
    if (n) { lat = n.lat; lng = n.lng; }
  }

  // Merge editable fields. Preserve rating/review_count/jobs_completed/years_experience/verified/tags
  const updated: any = {
    ...existing,
    ...(parsed.data.name !== undefined && { name: parsed.data.name }),
    ...(parsed.data.category !== undefined && { category: parsed.data.category }),
    ...(parsed.data.additional_categories !== undefined && { additional_categories: parsed.data.additional_categories }),
    ...(parsed.data.specializations !== undefined && { specializations: parsed.data.specializations }),
    ...(parsed.data.gender !== undefined && { gender: parsed.data.gender }),
    ...(parsed.data.available_now !== undefined && { available_now: parsed.data.available_now }),
    ...(parsed.data.neighborhood !== undefined && { neighborhood: parsed.data.neighborhood, lat, lng }),
    ...(parsed.data.service_areas !== undefined && { service_areas: parsed.data.service_areas }),
    ...(parsed.data.service_radius_km !== undefined && { service_radius_km: parsed.data.service_radius_km }),
    ...(parsed.data.languages !== undefined && { languages: parsed.data.languages }),
    ...(parsed.data.price_range_pkr !== undefined && { price_range_pkr: parsed.data.price_range_pkr }),
    ...(parsed.data.availability !== undefined && {
      availability: { ...existing.availability, ...parsed.data.availability },
    }),
    ...(parsed.data.availability_overrides !== undefined && {
      availability_overrides: parsed.data.availability_overrides,
    }),
    ...(parsed.data.phone !== undefined && { phone: parsed.data.phone }),
    ...(parsed.data.bio !== undefined && { bio: parsed.data.bio }),
    ...(parsed.data.profile_image_url !== undefined && { profile_image_url: parsed.data.profile_image_url }),
  };
  await addProvider(updated, parsed.data.user_id); // upserts in mem + Firestore
  res.json({ ok: true, provider_id: updated.id, provider: updated });
});

/** Provider toggles their "online / accepting jobs right now" flag. */
const AvailabilityToggleSchema = z.object({
  user_id: z.string().min(1),
  available_now: z.boolean(),
});
app.post('/providers/:provider_id/availability', async (req, res) => {
  const parsed = AvailabilityToggleSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: 'invalid_body', details: parsed.error.flatten() });
  }
  const ownerId = await getProviderIdForUser(parsed.data.user_id);
  if (ownerId !== req.params.provider_id) {
    return res.status(403).json({ error: 'not_your_profile' });
  }
  const existing = loadProviders().find((p) => p.id === req.params.provider_id);
  if (!existing) return res.status(404).json({ error: 'provider_not_found' });
  const updated: any = { ...existing, available_now: parsed.data.available_now };
  await addProvider(updated, parsed.data.user_id);
  res.json({ ok: true, available_now: parsed.data.available_now });
});

/** Look up the provider_id (if any) owned by a Firebase user. Used on app
 *  launch to decide whether a returning provider needs onboarding or can
 *  go straight to the provider shell. */
app.get('/providers/by-user/:user_id', async (req, res) => {
  const providerId = await getProviderIdForUser(req.params.user_id);
  if (!providerId) return res.status(404).json({ error: 'no_provider_for_user' });
  const provider = loadProviders().find((p) => p.id === providerId);
  if (!provider) return res.status(404).json({ error: 'provider_record_missing' });
  res.json({ provider_id: providerId, provider });
});

/** List all providers — used by the app's "Log in as provider" selector. */
app.get('/providers', (_req, res) => {
  const providers = loadProviders().map((p) => ({
    id: p.id,
    name: p.name,
    category: p.category,
    neighborhood: p.neighborhood,
    rating: p.rating,
    review_count: p.review_count,
    jobs_completed: p.jobs_completed,
    languages: p.languages,
    verified: p.verified,
    emoji_category: p.category, // for icon mapping
  }));
  res.json({ providers, total: providers.length });
});

/** Per-booking messages — direct chat between the customer and the
 *  provider tied to a specific booking. Stored in Firestore under
 *  `booking_messages/{bookingId}/messages/{msgId}` so both sides can
 *  poll cheaply. */
app.get('/bookings/:id/messages', async (req, res) => {
  try {
    const { Firestore } = await import('@google-cloud/firestore');
    const fs = new Firestore({ projectId: config.gcp.projectId });
    const snap = await fs
      .collection(`booking_messages/${req.params.id}/messages`)
      .orderBy('ts', 'asc')
      .limit(200)
      .get();
    res.json({
      messages: snap.docs.map((d) => ({ id: d.id, ...d.data() })),
    });
  } catch (e: any) {
    console.warn('[messages] read failed:', e?.message ?? e);
    res.json({ messages: [] });
  }
});

const PostBookingMessageSchema = z.object({
  // 'user' or 'provider' — the side that's sending. Avoids us trying
  // to look up auth roles in the request.
  from: z.enum(['user', 'provider']),
  sender_id: z.string().min(1),
  text: z.string().min(1).max(1000),
});
app.post('/bookings/:id/messages', async (req, res) => {
  const parsed = PostBookingMessageSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: 'invalid_body', details: parsed.error.flatten() });
  }
  const booking = await getBookingFromStore(req.params.id);
  if (!booking) return res.status(404).json({ error: 'booking_not_found' });
  // Cheap authorization: sender must be the customer or the provider on
  // this booking. No JWT, just an id match.
  const isOwner =
    (parsed.data.from === 'user' && parsed.data.sender_id === booking.user_id) ||
    (parsed.data.from === 'provider' && parsed.data.sender_id === booking.provider_id);
  if (!isOwner) {
    return res.status(403).json({ error: 'not_a_party_to_this_booking' });
  }
  try {
    const { Firestore } = await import('@google-cloud/firestore');
    const fs = new Firestore({ projectId: config.gcp.projectId });
    const msg = {
      from: parsed.data.from,
      sender_id: parsed.data.sender_id,
      text: parsed.data.text.trim(),
      ts: new Date().toISOString(),
    };
    const ref = await fs
      .collection(`booking_messages/${req.params.id}/messages`)
      .add(msg);
    res.json({ ok: true, id: ref.id, message: msg });
  } catch (e: any) {
    console.error('[messages] write failed:', e?.message ?? e);
    res.status(500).json({ error: 'persist_failed' });
  }
});

/** Single booking lookup — used by the customer chat to poll for the status
 *  transition from "requested" → "confirmed" after the provider accepts. */
app.get('/bookings/:id', async (req, res) => {
  const b = await getBookingFromStore(req.params.id);
  if (!b) return res.status(404).json({ error: 'booking_not_found' });
  const provider = loadProviders().find((p) => p.id === b.provider_id);
  res.json({
    ...b,
    provider_name: provider?.name ?? null,
    provider_phone: provider?.phone ?? null,
    provider_rating: provider?.rating ?? null,
  });
});

/** Single provider profile. */
app.get('/providers/:id', (req, res) => {
  const p = loadProviders().find((x) => x.id === req.params.id);
  if (!p) return res.status(404).json({ error: 'provider_not_found' });
  res.json(p);
});

/** All bookings assigned to this provider (newest first). */
app.get('/providers/:id/bookings', async (req, res) => {
  const bookings = await listAllBookingsForProvider(req.params.id);
  res.json({ bookings, total: bookings.length });
});

/** Provider's incoming notification inbox (user-confirmations, etc.). */
app.get('/providers/:id/inbox', async (req, res) => {
  const messages = await listInboxForProvider(req.params.id);
  res.json({ messages, total: messages.length });
});

/** Provider accepts/declines/completes a booking. */
const ProviderActionSchema = z.object({
  action: z.enum(['accept', 'decline', 'en_route', 'arrived', 'completed', 'cancelled']),
});
app.post('/providers/:provider_id/bookings/:booking_id/action', async (req, res) => {
  const parsed = ProviderActionSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: 'invalid_body', details: parsed.error.flatten() });
  }
  const booking = await getBookingFromStore(req.params.booking_id);
  if (!booking) return res.status(404).json({ error: 'booking_not_found' });
  if (booking.provider_id !== req.params.provider_id) {
    return res.status(403).json({ error: 'not_your_booking' });
  }
  const newStatus =
    parsed.data.action === 'accept'
      ? 'confirmed'
      : parsed.data.action === 'decline'
      ? 'cancelled'
      : parsed.data.action === 'en_route'
      ? 'reminded'
      : parsed.data.action === 'arrived'
      ? 'in_progress'
      : parsed.data.action === 'completed'
      ? 'completed'
      : 'cancelled';
  await updateBookingStatusInStore(booking.id, newStatus as any);
  res.json({ ok: true, booking_id: booking.id, status: newStatus });
});

// ─── Boot ────────────────────────────────────────────────────────────────────
validateConfig();
// Fire-and-forget Firestore hydration — by the time the first /run request
// arrives (a few seconds later when the user opens the app), providers from
// prior container lifetimes are back in memory.
hydrateProvidersFromFirestore().catch((e) =>
  console.warn('[boot] hydrateProvidersFromFirestore failed:', e?.message ?? e)
);
const httpServer = app.listen(config.port, () => {
  console.log(`[tapkar-ai] listening on http://localhost:${config.port}`);
  console.log(`[tapkar-ai] POST /run    — start a pipeline (SSE stream)`);
  console.log(`[tapkar-ai] GET  /traces/:run_id — fetch a trace`);
  console.log(`[tapkar-ai] WS   /voice/live — Gemini Live audio bridge`);
  console.log(`[tapkar-ai] GET  /healthz`);
});

// Attach the Gemini Live voice WebSocket bridge to the HTTP server so we
// can upgrade /voice/live connections.
(async () => {
  try {
    const { attachLiveVoice } = await import('./voice-live.js');
    attachLiveVoice(httpServer);
  } catch (e: any) {
    console.warn('[boot] voice-live attach failed (non-fatal):', e?.message ?? e);
  }
})();
