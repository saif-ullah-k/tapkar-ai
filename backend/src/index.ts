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
} from './store.js';
import { loadProviders } from './data.js';

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

// ─── Run a pipeline (SSE stream) ─────────────────────────────────────────────
const RunBodySchema = z.object({
  user_id: z.string().min(1),
  user_input: z.string().min(1).max(2000),
  conversation_id: z.string().optional(),
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

// ─── Diagnostic: bare SSE stream (no agents, no Gemini) ────────────────────
app.get('/ping-sse', async (_req, res) => {
  console.log('[ping-sse] starting bare SSE stream...');
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache, no-transform');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('X-Accel-Buffering', 'no');
  res.flushHeaders();
  console.log('[ping-sse] headers flushed, writing 3 events');

  res.write(`event: hello\ndata: ${JSON.stringify({ n: 1, ts: Date.now() })}\n\n`);
  console.log('[ping-sse] event 1 written');
  await new Promise((r) => setTimeout(r, 500));

  res.write(`event: tick\ndata: ${JSON.stringify({ n: 2, ts: Date.now() })}\n\n`);
  console.log('[ping-sse] event 2 written');
  await new Promise((r) => setTimeout(r, 500));

  res.write(`event: done\ndata: ${JSON.stringify({ n: 3, ts: Date.now() })}\n\n`);
  console.log('[ping-sse] event 3 written, ending response');
  res.end();
});

// ─── Diagnostic: call runAgent directly with the orchestrator prompt ───────
app.get('/ping-runagent/:name', async (req, res) => {
  const t0 = Date.now();
  const name = req.params.name as any;
  console.log(`[ping-runagent] starting runAgent("${name}")...`);
  try {
    const { runAgent } = await import('./gemini.js');
    const result = await runAgent(
      name,
      { user_input: 'plumber Gulshan', intent: null, discovery: null, ranking: null, booking: null, followup: null, completed: false },
      { runId: 'diag' }
    );
    const ms = Date.now() - t0;
    console.log(`[ping-runagent] ${name} OK in ${ms}ms — tools=${result.tool_calls.length}, model=${result.model}`);
    res.json({ ok: true, ms, agent: name, ...result });
  } catch (err: any) {
    const ms = Date.now() - t0;
    console.error(`[ping-runagent] ${name} FAILED in ${ms}ms:`, err?.message ?? err);
    res.status(500).json({ ok: false, ms, agent: name, error: err?.message ?? String(err), stack: err?.stack?.split('\n').slice(0, 5).join('\n') });
  }
});

// ─── Diagnostic: Gemini call WITH function declarations ─────────────────────
app.get('/ping-gemini-fc', async (_req, res) => {
  const t0 = Date.now();
  console.log('[ping-gemini-fc] starting Gemini call with function declarations...');
  try {
    const { GoogleGenAI, Type } = await import('@google/genai');
    const client = config.gemini.useVertex
      ? new GoogleGenAI({
          vertexai: true,
          project: config.gcp.projectId,
          location: config.gcp.location,
        })
      : new GoogleGenAI({ apiKey: config.gemini.apiKey });
    const response = await client.models.generateContent({
      model: config.gemini.defaultModel,
      contents: [
        {
          role: 'user',
          parts: [{ text: 'Use the get_weather function for location "Karachi".' }],
        },
      ],
      config: {
        tools: [
          {
            functionDeclarations: [
              {
                name: 'get_weather',
                description: 'Get the weather for a location',
                parameters: {
                  type: Type.OBJECT,
                  properties: { location: { type: Type.STRING } },
                  required: ['location'],
                },
              },
            ],
          },
        ],
      },
    });
    const parts = response.candidates?.[0]?.content?.parts ?? [];
    const calls = parts.filter((p: any) => p.functionCall).map((p: any) => p.functionCall);
    const text = parts
      .filter((p: any) => p.text)
      .map((p: any) => p.text)
      .join('');
    const ms = Date.now() - t0;
    console.log(`[ping-gemini-fc] OK in ${ms}ms — calls=${calls.length}, text="${text.slice(0, 50)}"`);
    res.json({ ok: true, ms, function_calls: calls, text });
  } catch (err: any) {
    const ms = Date.now() - t0;
    console.error(`[ping-gemini-fc] FAILED in ${ms}ms:`, err?.message ?? err);
    res.status(500).json({ ok: false, ms, error: err?.message ?? String(err) });
  }
});

// ─── Diagnostic: bare Gemini call (no agents, no tools) ─────────────────────
app.get('/ping-gemini', async (_req, res) => {
  const t0 = Date.now();
  console.log('[ping-gemini] starting bare Gemini call...');
  try {
    const { GoogleGenAI } = await import('@google/genai');
    const client = config.gemini.useVertex
      ? new GoogleGenAI({
          vertexai: true,
          project: config.gcp.projectId,
          location: config.gcp.location,
        })
      : new GoogleGenAI({ apiKey: config.gemini.apiKey });
    const response = await client.models.generateContent({
      model: config.gemini.defaultModel,
      contents: [{ role: 'user', parts: [{ text: 'Say "pong" and nothing else.' }] }],
    });
    const text =
      response.candidates?.[0]?.content?.parts?.map((p: any) => p.text).join('') ?? '<no text>';
    const ms = Date.now() - t0;
    console.log(`[ping-gemini] OK in ${ms}ms — model returned: "${text.slice(0, 100)}"`);
    res.json({ ok: true, ms, model: config.gemini.defaultModel, response: text });
  } catch (err: any) {
    const ms = Date.now() - t0;
    console.error(`[ping-gemini] FAILED in ${ms}ms:`, err?.message ?? err);
    res.status(500).json({ ok: false, ms, error: err?.message ?? String(err), stack: err?.stack });
  }
});

// ─── Fetch a completed trace ─────────────────────────────────────────────────
app.get('/traces/:run_id', async (req, res) => {
  const trace = await getTrace(req.params.run_id);
  if (!trace) return res.status(404).json({ error: 'trace_not_found' });
  res.json(trace);
});

// ─── Provider-mode endpoints (the marketplace's "other side") ───────────────

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
app.listen(config.port, () => {
  console.log(`[tapkar-ai] listening on http://localhost:${config.port}`);
  console.log(`[tapkar-ai] POST /run    — start a pipeline (SSE stream)`);
  console.log(`[tapkar-ai] GET  /traces/:run_id — fetch a trace`);
  console.log(`[tapkar-ai] GET  /healthz`);
});
