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

const SYSTEM_PROMPT = `You are TapKar AI's voice assistant for Pakistan's informal-economy service marketplace. Users speak to you in Urdu, Roman Urdu, or English to book services like plumbers, electricians, AC technicians, tutors, beauticians, mehndi artists, and so on.

YOUR JOB:
- Listen to what the user wants.
- When they describe a service they need, EXTRACT the request and call the \`book_a_service\` tool with their full request as text. The tool runs a deterministic 5-agent pipeline (intent, discovery, ranking, booking, follow-up) which finds matching providers and books one.
- While the tool is running, briefly say something like "thoda intezar karein, providers dhoond rahi/raha hoon" (gender-matched).
- When the tool returns, naturally narrate what happened — booking confirmed / awaiting provider / options to choose / etc.
- If the user asks something off-topic, gently steer them back.

CRITICAL RULES:
- Always speak in the SAME language the user is using. Urdu → Urdu, Roman Urdu → Roman Urdu, English → English.
- Be warm and natural, not robotic. You're a human assistant, not a form.
- If the user gives incomplete info ("kal plumber chahiye" without location), ask conversationally for what's missing BEFORE calling the tool. Don't call the tool with incomplete data.
- After booking succeeds, ask if they need anything else.
- "kal" in service-booking ALWAYS means tomorrow (future), never yesterday.`;

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
  const gen = runPipeline({
    user_id: ctx.user_id,
    user_input: userRequest,
    language: ctx.language,
    user_gender: ctx.user_gender,
  });
  const collected: any = {
    booking_id: null,
    status: 'unknown',
    summary: '',
    last_user_message: '',
    options: [],
  };
  while (true) {
    const r = await gen.next();
    if (r.done) break;
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
    } else if (evt.event === 'step' && evt.data?.agent === 'booking') {
      const out = evt.data.output;
      if (out?.booking_id) collected.booking_id = out.booking_id;
      if (out?.status) collected.status = out.status;
    } else if (evt.event === 'run_complete') {
      const s = evt.data?.status as string | undefined;
      if (s === 'awaiting_user_input') collected.status = 'needs_user_input';
      else if (collected.status === 'unknown' && s) collected.status = s;
    }
  }
  collected.summary = collected.last_user_message || `Pipeline finished, status=${collected.status}`;
  return collected;
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
          language = frame.language ?? language;
          userGender = frame.user_gender ?? userGender;

          session = await getAi().live.connect({
            model: LIVE_MODEL,
            config: {
              responseModalities: [Modality.AUDIO],
              systemInstruction: {
                parts: [{ text: SYSTEM_PROMPT }],
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
                closeAll('session_closed');
              },
            },
          });
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
