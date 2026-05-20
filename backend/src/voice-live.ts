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

          // Personalize the prompt with the user's name + gender so the
          // model can greet them by name and pick gender-matched verbs.
          const personalSystemPrompt =
            SYSTEM_PROMPT +
            `\n\n═══════════════════════════════════════════════════════\n` +
            `USER INFO\n` +
            `═══════════════════════════════════════════════════════\n` +
            `Name: ${userName || '(unknown)'}\n` +
            `Gender: ${userGender}\n` +
            `Language: ${language}\n` +
            (userName
              ? `When the session opens, your VERY FIRST utterance must greet ${userName} by name: "Assalamu Alaikum ${userName}!" — warm, friendly, then ask how you can help ("kaisi madad chahiye?" / "kya kaam karwana hai aaj?"). Don't wait for the user to speak first.`
              : `When the session opens, your VERY FIRST utterance must be: "Assalamu Alaikum! TapKar AI mein khush aamdeed. Kya kaam karwana hai aaj?" — don't wait for the user to speak first.`);

          session = await getAi().live.connect({
            model: LIVE_MODEL,
            config: {
              responseModalities: [Modality.AUDIO],
              systemInstruction: {
                parts: [{ text: personalSystemPrompt }],
              },
              tools: [BOOKING_TOOL as any],
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
