/**
 * Tool registry for TapKar AI agents.
 *
 * ╔═══════════════════════════════════════════════════════════════════════╗
 * ║  CONTRACT — read before editing                                       ║
 * ║  Tools are DUMB I/O wrappers. Each tool does ONE thing and contains   ║
 * ║  ZERO business logic. No `if (category === ...)`, no scoring, no     ║
 * ║  ranking, no decisioning. All decisions live in agent prompts.        ║
 * ╚═══════════════════════════════════════════════════════════════════════╝
 *
 * This file:
 *   1. Defines each tool's implementation
 *   2. Declares it as a Gemini function declaration
 *   3. Declares which agents have access to each tool
 *   4. Exposes executeTool() and allToolsForAgent() to the Gemini runner
 */

import { randomUUID } from 'node:crypto';
import { Type, type FunctionDeclaration } from '@google/genai';
import { config } from '../config.js';
import { loadProviders, loadTaxonomy } from '../data.js';
import {
  putTrace,
  appendTraceStep,
  endTraceInStore,
  putBooking,
  getBookingFromStore,
  listBookingsForProvider,
  updateBookingStatusInStore,
  putJob,
  cancelJobsForBooking,
  putInboxMessage,
} from '../store.js';
import type {
  AgentName,
  Booking,
  BookingStatus,
  JobType,
  Language,
  LatLng,
  Location,
  Provider,
  ProviderCandidate,
  Receipt,
  ScheduledJob,
  Trace,
  TraceStep,
} from '../types.js';

// ─────────────────────────────────────────────────────────────────────────────
//  Pure helpers (NOT tools — internal math/utilities)
// ─────────────────────────────────────────────────────────────────────────────

function haversineKm(a: LatLng, b: LatLng): number {
  const R = 6371;
  const dLat = ((b.lat - a.lat) * Math.PI) / 180;
  const dLng = ((b.lng - a.lng) * Math.PI) / 180;
  const sinDLat = Math.sin(dLat / 2);
  const sinDLng = Math.sin(dLng / 2);
  const lat1 = (a.lat * Math.PI) / 180;
  const lat2 = (b.lat * Math.PI) / 180;
  const h = sinDLat * sinDLat + sinDLng * sinDLng * Math.cos(lat1) * Math.cos(lat2);
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

function dayKey(iso: string): keyof Provider['availability'] {
  const d = new Date(iso).getUTCDay(); // 0=Sun..6=Sat
  return (['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'] as const)[
    d
  ];
}

function timeWithinRange(iso: string, range: string): boolean {
  const [start, end] = range.split('-');
  const [sh, sm] = start.split(':').map(Number);
  const [eh, em] = end.split(':').map(Number);
  const d = new Date(iso);
  const mins = d.getHours() * 60 + d.getMinutes();
  return mins >= sh * 60 + sm && mins <= eh * 60 + em;
}

function isAvailable(provider: Provider, atIso: string): boolean {
  const ranges = provider.availability[dayKey(atIso)] ?? [];
  return ranges.some((r) => timeWithinRange(atIso, r));
}

// ─────────────────────────────────────────────────────────────────────────────
//  Tool implementations  (each one is thin I/O — no business decisions)
// ─────────────────────────────────────────────────────────────────────────────

async function impl_detect_language(args: { text: string }): Promise<{ language: Language }> {
  // Cheap heuristic — agents can re-classify with LLM judgment if needed.
  const t = args.text || '';
  if (/[؀-ۿ]/.test(t)) return { language: 'ur' };
  if (
    /\b(yaar|chahiye|karwana|karwado|jaldi|hai|bhejo|achha|bandobast|kal|abhi|subah|shaam)\b/i.test(
      t
    )
  ) {
    return { language: 'roman_ur' };
  }
  return { language: 'en' };
}

async function impl_geocode(args: { text: string }): Promise<Location | null> {
  const tax = loadTaxonomy();
  const t = (args.text || '').toLowerCase();
  // Pakistani neighborhood lookup — static map from taxonomy
  for (const n of tax.neighborhoods_karachi) {
    if (t.includes(n.name.toLowerCase()) || (n.ur && args.text?.includes(n.ur))) {
      return { lat: n.lat, lng: n.lng, label: n.name, neighborhood: n.name };
    }
  }
  // No fallback to real geocoding in Day 1 (no GCP key required)
  return null;
}

async function impl_distance_km(args: { a: LatLng; b: LatLng }): Promise<{ km: number }> {
  return { km: Number(haversineKm(args.a, args.b).toFixed(2)) };
}

async function impl_read_taxonomy(): Promise<{ categories: any[]; neighborhoods: any[] }> {
  const tax = loadTaxonomy();
  return { categories: tax.categories, neighborhoods: tax.neighborhoods_karachi };
}

async function impl_search_taxonomy(args: {
  category_id?: string;
  query?: string;
}): Promise<{ match: any | null; candidates: any[] }> {
  const tax = loadTaxonomy();
  if (args.category_id) {
    const found = tax.categories.find((c) => c.id === args.category_id) ?? null;
    return { match: found, candidates: found ? [found] : [] };
  }
  if (args.query) {
    const q = args.query.toLowerCase();
    const candidates = tax.categories.filter((c) => {
      const all = [...c.names.en, ...c.names.ur, ...c.names.roman_ur].map((s) => s.toLowerCase());
      return all.some((n) => q.includes(n) || n.includes(q));
    });
    return { match: candidates[0] ?? null, candidates };
  }
  return { match: null, candidates: [] };
}

async function impl_search_providers(args: {
  category_id?: string;
  free_text?: string;
  near: LatLng;
  radius_km: number;
  specializations?: string[];
}): Promise<ProviderCandidate[]> {
  const providers = loadProviders();
  return providers
    .filter((p) => !args.category_id || p.category === args.category_id)
    .filter((p) => {
      if (!args.specializations || args.specializations.length === 0) return true;
      return args.specializations.some((s) => p.specializations.includes(s));
    })
    .map<ProviderCandidate>((p) => ({
      ...p,
      distance_km: Number(haversineKm(args.near, { lat: p.lat, lng: p.lng }).toFixed(2)),
      source: 'mock',
    }))
    .filter((p) => (p.distance_km ?? 0) <= args.radius_km)
    .sort((a, b) => (a.distance_km ?? 0) - (b.distance_km ?? 0));
}

async function impl_places_nearby_search(_args: any): Promise<ProviderCandidate[]> {
  if (!config.features.useRealPlaces) return [];
  // Real implementation gated until Day 2+
  return [];
}

async function impl_places_text_search(_args: any): Promise<ProviderCandidate[]> {
  if (!config.features.useRealPlaces) return [];
  return [];
}

async function impl_get_availability(args: {
  provider_id: string;
  at_iso: string;
}): Promise<{ available: boolean; reason?: string }> {
  const provider = loadProviders().find((p) => p.id === args.provider_id);
  if (!provider) return { available: false, reason: 'provider_not_found' };
  if (!isAvailable(provider, args.at_iso)) {
    return { available: false, reason: 'closed_at_requested_time' };
  }
  const conflicts = await listBookingsForProvider(provider.id, args.at_iso);
  if (conflicts.length > 0) return { available: false, reason: 'already_booked' };
  return { available: true };
}

async function impl_filter_by_availability(args: {
  providers: ProviderCandidate[];
  at_iso: string;
}): Promise<ProviderCandidate[]> {
  const out: ProviderCandidate[] = [];
  for (const p of args.providers) {
    const avail = await impl_get_availability({ provider_id: p.id, at_iso: args.at_iso });
    if (avail.available) out.push({ ...p, availability_at_request: 'available' });
  }
  return out;
}

async function impl_filter_by_constraints(args: {
  providers: ProviderCandidate[];
  verified_only?: boolean;
  female_only?: boolean;
}): Promise<ProviderCandidate[]> {
  // NB: gender is not modelled in seed data; the female_only filter is a no-op for Day 1
  // and reported as "passed_through" so the agent knows. No business decision here —
  // exact-match filtering only.
  return args.providers.filter((p) => !args.verified_only || p.verified);
}

async function impl_get_reviews(args: {
  provider_id: string;
  limit?: number;
}): Promise<Array<{ rating: number; text: string; ts: string }>> {
  // Day 1: no synthetic review text — return empty list; ranking agent uses rating/review_count instead
  return [];
}

async function impl_check_provider_capacity(args: {
  provider_id: string;
  time_iso: string;
}): Promise<{ available: boolean; conflicting_booking_id?: string }> {
  const conflicts = await listBookingsForProvider(args.provider_id, args.time_iso);
  if (conflicts.length > 0) {
    return { available: false, conflicting_booking_id: conflicts[0].id };
  }
  const avail = await impl_get_availability({
    provider_id: args.provider_id,
    at_iso: args.time_iso,
  });
  return { available: avail.available };
}

async function impl_create_booking(args: {
  user_id: string;
  provider_id: string;
  service_category_id: string;
  specializations?: string[];
  time_iso: string;
  location: Location;
  language: Language;
  estimated_price_pkr: [number, number];
  notes?: string;
}): Promise<{ booking_id: string; status: BookingStatus }> {
  const id = `bk_${Math.floor(Math.random() * 90000) + 10000}`;
  const booking: Booking = {
    id,
    user_id: args.user_id,
    provider_id: args.provider_id,
    service_category_id: args.service_category_id,
    specializations: args.specializations,
    time_iso: args.time_iso,
    location: args.location,
    status: 'confirmed',
    language: args.language,
    estimated_price_pkr: args.estimated_price_pkr,
    notes: args.notes,
    created_at: new Date().toISOString(),
    confirmed_at: new Date().toISOString(),
  };
  await putBooking(booking);
  return { booking_id: id, status: 'confirmed' };
}

async function impl_get_booking(args: { booking_id: string }): Promise<Booking | null> {
  return getBookingFromStore(args.booking_id);
}

async function impl_update_booking_status(args: {
  booking_id: string;
  status: BookingStatus;
}): Promise<{ ok: true }> {
  await updateBookingStatusInStore(args.booking_id, args.status);
  return { ok: true };
}

async function impl_generate_receipt(args: { booking_id: string }): Promise<Receipt> {
  const b = await getBookingFromStore(args.booking_id);
  if (!b) throw new Error(`Booking ${args.booking_id} not found`);
  const provider = loadProviders().find((p) => p.id === b.provider_id);
  const summary = `${provider?.name ?? b.provider_id} — ${b.service_category_id} on ${b.time_iso}, ~PKR ${b.estimated_price_pkr[0]}–${b.estimated_price_pkr[1]}`;
  return {
    booking_id: b.id,
    url: `/receipts/${b.id}.json`,
    summary,
    generated_at: new Date().toISOString(),
  };
}

async function impl_send_notification(args: {
  to: 'user' | 'provider' | 'both';
  booking_id: string;
  message: string;
  language: Language;
  channel?: 'in_app' | 'sms';
}): Promise<{ message_id: string }> {
  const message_id = `m_${randomUUID().slice(0, 8)}`;
  await putInboxMessage({
    message_id,
    to: args.to,
    booking_id: args.booking_id,
    message: args.message,
    language: args.language,
    channel: args.channel ?? 'in_app',
    ts: new Date().toISOString(),
  });
  return { message_id };
}

async function impl_send_user_message(args: {
  user_id: string;
  text: string;
  language: Language;
}): Promise<{ message_id: string }> {
  const message_id = `m_${randomUUID().slice(0, 8)}`;
  await putInboxMessage({
    message_id,
    to: 'user',
    user_id: args.user_id,
    message: args.text,
    language: args.language,
    channel: 'in_app',
    ts: new Date().toISOString(),
  });
  return { message_id };
}

async function impl_schedule_job(args: {
  booking_id: string;
  type: JobType;
  fire_at_iso: string;
  purpose: string;
  language: Language;
  message_preview: string;
}): Promise<{ job_id: string }> {
  const job_id = `j_${randomUUID().slice(0, 8)}`;
  const job: ScheduledJob = {
    id: job_id,
    booking_id: args.booking_id,
    type: args.type,
    fire_at_iso: args.fire_at_iso,
    purpose: args.purpose,
    language: args.language,
    message_preview: args.message_preview,
    status: 'pending',
  };
  await putJob(job);
  return { job_id };
}

async function impl_cancel_scheduled_jobs(args: {
  booking_id: string;
}): Promise<{ cancelled_count: number }> {
  const n = await cancelJobsForBooking(args.booking_id);
  return { cancelled_count: n };
}

// Trace tools — provided to agents but most trace writes happen in orchestrator
async function impl_write_trace_step(args: any, ctx: { runId?: string }): Promise<{ ok: true }> {
  if (!ctx.runId) return { ok: true };
  const step: TraceStep = {
    agent: args.agent ?? 'orchestrator',
    reasoning: args.reasoning ?? '',
    tools_called: args.tools_called ?? [],
    output: args.output ?? null,
    ms: 0,
    ts: new Date().toISOString(),
  };
  await appendTraceStep(ctx.runId, step);
  return { ok: true };
}

// ─────────────────────────────────────────────────────────────────────────────
//  Registry — name → (declaration, handler, agents allowlist)
// ─────────────────────────────────────────────────────────────────────────────

interface ToolDef {
  description: string;
  parameters: any; // Gemini OpenAPI subset
  agents: AgentName[];
  handler: (args: any, ctx: { runId?: string }) => Promise<unknown>;
}

const LATLNG_SCHEMA = {
  type: Type.OBJECT,
  properties: { lat: { type: Type.NUMBER }, lng: { type: Type.NUMBER } },
  required: ['lat', 'lng'],
};

const REGISTRY: Record<string, ToolDef> = {
  detect_language: {
    description: 'Detect the language of a piece of text. Returns en, ur, or roman_ur.',
    parameters: {
      type: Type.OBJECT,
      properties: { text: { type: Type.STRING } },
      required: ['text'],
    },
    agents: ['intent'],
    handler: impl_detect_language,
  },
  geocode: {
    description:
      'Geocode a free-text location string (e.g. neighborhood name) to lat/lng. Returns null if unknown.',
    parameters: {
      type: Type.OBJECT,
      properties: { text: { type: Type.STRING } },
      required: ['text'],
    },
    agents: ['intent'],
    handler: impl_geocode,
  },
  distance_km: {
    description: 'Haversine distance in km between two lat/lng points.',
    parameters: {
      type: Type.OBJECT,
      properties: { a: LATLNG_SCHEMA, b: LATLNG_SCHEMA },
      required: ['a', 'b'],
    },
    agents: ['intent', 'discovery', 'ranking'],
    handler: impl_distance_km,
  },
  read_taxonomy: {
    description:
      'Read the full service-category taxonomy and Karachi neighborhood reference data.',
    parameters: { type: Type.OBJECT, properties: {} },
    agents: ['intent', 'discovery', 'ranking'],
    handler: impl_read_taxonomy,
  },
  search_taxonomy: {
    description:
      'Look up a service category by id or by a multilingual query phrase. Returns the best match and other candidates.',
    parameters: {
      type: Type.OBJECT,
      properties: {
        category_id: { type: Type.STRING },
        query: { type: Type.STRING },
      },
    },
    agents: ['intent', 'discovery'],
    handler: impl_search_taxonomy,
  },
  search_providers: {
    description:
      'Find providers matching the given filters. Reads mock dataset and (optionally) Firestore. Returns candidates sorted by distance.',
    parameters: {
      type: Type.OBJECT,
      properties: {
        category_id: { type: Type.STRING },
        free_text: { type: Type.STRING },
        near: LATLNG_SCHEMA,
        radius_km: { type: Type.NUMBER },
        specializations: { type: Type.ARRAY, items: { type: Type.STRING } },
      },
      required: ['near', 'radius_km'],
    },
    agents: ['discovery'],
    handler: impl_search_providers,
  },
  places_nearby_search: {
    description:
      'Google Places nearby search. Returns [] in Day 1 mock-only mode (USE_REAL_PLACES=false).',
    parameters: {
      type: Type.OBJECT,
      properties: {
        location: LATLNG_SCHEMA,
        type: { type: Type.STRING },
        keyword: { type: Type.STRING },
        radius: { type: Type.NUMBER },
      },
      required: ['location', 'radius'],
    },
    agents: ['discovery'],
    handler: impl_places_nearby_search,
  },
  places_text_search: {
    description:
      'Google Places text search (open-domain). Returns [] in Day 1 mock-only mode.',
    parameters: {
      type: Type.OBJECT,
      properties: {
        query: { type: Type.STRING },
        location: LATLNG_SCHEMA,
        radius: { type: Type.NUMBER },
      },
      required: ['query', 'location', 'radius'],
    },
    agents: ['discovery'],
    handler: impl_places_text_search,
  },
  get_availability: {
    description:
      'Check if a provider is available at a given ISO timestamp. Considers weekly hours + existing bookings.',
    parameters: {
      type: Type.OBJECT,
      properties: {
        provider_id: { type: Type.STRING },
        at_iso: { type: Type.STRING },
      },
      required: ['provider_id', 'at_iso'],
    },
    agents: ['discovery', 'ranking', 'booking'],
    handler: impl_get_availability,
  },
  filter_by_availability: {
    description:
      'Given a list of candidates, return only those available at the requested ISO timestamp.',
    parameters: {
      type: Type.OBJECT,
      properties: {
        providers: { type: Type.ARRAY, items: { type: Type.OBJECT } },
        at_iso: { type: Type.STRING },
      },
      required: ['providers', 'at_iso'],
    },
    agents: ['discovery'],
    handler: impl_filter_by_availability,
  },
  filter_by_constraints: {
    description:
      'Apply exact-match constraints to a candidate list. verified_only is honored; female_only is currently a passthrough (not modelled in seed data).',
    parameters: {
      type: Type.OBJECT,
      properties: {
        providers: { type: Type.ARRAY, items: { type: Type.OBJECT } },
        verified_only: { type: Type.BOOLEAN },
        female_only: { type: Type.BOOLEAN },
      },
      required: ['providers'],
    },
    agents: ['discovery'],
    handler: impl_filter_by_constraints,
  },
  get_reviews: {
    description: 'Fetch recent review snippets for a provider. Day 1 returns [].',
    parameters: {
      type: Type.OBJECT,
      properties: {
        provider_id: { type: Type.STRING },
        limit: { type: Type.NUMBER },
      },
      required: ['provider_id'],
    },
    agents: ['ranking'],
    handler: impl_get_reviews,
  },
  check_provider_capacity: {
    description:
      'Re-check (at booking time) that the provider has no conflicting booking. Returns conflicting_booking_id if a clash exists.',
    parameters: {
      type: Type.OBJECT,
      properties: {
        provider_id: { type: Type.STRING },
        time_iso: { type: Type.STRING },
      },
      required: ['provider_id', 'time_iso'],
    },
    agents: ['booking'],
    handler: impl_check_provider_capacity,
  },
  create_booking: {
    description: 'Persist a new booking. Returns the new booking_id.',
    parameters: {
      type: Type.OBJECT,
      properties: {
        user_id: { type: Type.STRING },
        provider_id: { type: Type.STRING },
        service_category_id: { type: Type.STRING },
        specializations: { type: Type.ARRAY, items: { type: Type.STRING } },
        time_iso: { type: Type.STRING },
        location: {
          type: Type.OBJECT,
          properties: {
            lat: { type: Type.NUMBER },
            lng: { type: Type.NUMBER },
            label: { type: Type.STRING },
          },
          required: ['lat', 'lng', 'label'],
        },
        language: { type: Type.STRING },
        estimated_price_pkr: { type: Type.ARRAY, items: { type: Type.NUMBER } },
        notes: { type: Type.STRING },
      },
      required: [
        'user_id',
        'provider_id',
        'service_category_id',
        'time_iso',
        'location',
        'language',
        'estimated_price_pkr',
      ],
    },
    agents: ['booking'],
    handler: impl_create_booking,
  },
  get_booking: {
    description: 'Read a booking by id. Used by orchestrator when user references a prior booking.',
    parameters: {
      type: Type.OBJECT,
      properties: { booking_id: { type: Type.STRING } },
      required: ['booking_id'],
    },
    agents: ['orchestrator', 'followup'],
    handler: impl_get_booking,
  },
  update_booking_status: {
    description: 'Update a booking status (e.g. matched → confirmed, confirmed → cancelled).',
    parameters: {
      type: Type.OBJECT,
      properties: {
        booking_id: { type: Type.STRING },
        status: { type: Type.STRING },
      },
      required: ['booking_id', 'status'],
    },
    agents: ['booking', 'followup'],
    handler: impl_update_booking_status,
  },
  generate_receipt: {
    description: 'Render a structured receipt for a confirmed booking.',
    parameters: {
      type: Type.OBJECT,
      properties: { booking_id: { type: Type.STRING } },
      required: ['booking_id'],
    },
    agents: ['booking'],
    handler: impl_generate_receipt,
  },
  send_notification: {
    description:
      'Send an in-app or SMS notification to user/provider/both. Writes to mock_inbox (simulation per challenge brief).',
    parameters: {
      type: Type.OBJECT,
      properties: {
        to: { type: Type.STRING },
        booking_id: { type: Type.STRING },
        message: { type: Type.STRING },
        language: { type: Type.STRING },
        channel: { type: Type.STRING },
      },
      required: ['to', 'booking_id', 'message', 'language'],
    },
    agents: ['booking', 'followup'],
    handler: impl_send_notification,
  },
  send_user_message: {
    description:
      'Send a chat-style message to the user (e.g. recommendation, confirmation prompt). Used by orchestrator.',
    parameters: {
      type: Type.OBJECT,
      properties: {
        user_id: { type: Type.STRING },
        text: { type: Type.STRING },
        language: { type: Type.STRING },
      },
      required: ['user_id', 'text', 'language'],
    },
    agents: ['orchestrator'],
    handler: impl_send_user_message,
  },
  schedule_job: {
    description: 'Schedule a future job (reminder, status_check, or survey) tied to a booking.',
    parameters: {
      type: Type.OBJECT,
      properties: {
        booking_id: { type: Type.STRING },
        type: { type: Type.STRING },
        fire_at_iso: { type: Type.STRING },
        purpose: { type: Type.STRING },
        language: { type: Type.STRING },
        message_preview: { type: Type.STRING },
      },
      required: [
        'booking_id',
        'type',
        'fire_at_iso',
        'purpose',
        'language',
        'message_preview',
      ],
    },
    agents: ['followup'],
    handler: impl_schedule_job,
  },
  cancel_scheduled_jobs: {
    description: 'Cancel all pending follow-up jobs for a booking (e.g. on user cancellation).',
    parameters: {
      type: Type.OBJECT,
      properties: { booking_id: { type: Type.STRING } },
      required: ['booking_id'],
    },
    agents: ['followup'],
    handler: impl_cancel_scheduled_jobs,
  },
  // NOTE: write_trace_step is intentionally NOT exposed to any agent. The
  // orchestrator and pipeline code auto-log every step. Exposing this tool to
  // the orchestrator caused unnecessary extra Gemini rounds (one per decision).
  // Keeping the implementation around in case we need it for manual instrumentation.
  _write_trace_step_unused: {
    description: 'Internal — not exposed to agents.',
    parameters: { type: Type.OBJECT, properties: {} },
    agents: [] as any,
    handler: impl_write_trace_step,
  },
};

// ─────────────────────────────────────────────────────────────────────────────
//  Public exports used by gemini.ts
// ─────────────────────────────────────────────────────────────────────────────

export interface BoundTool {
  name: string;
  description: string;
  parameters: any;
}

export function allToolsForAgent(agent: AgentName): BoundTool[] {
  return Object.entries(REGISTRY)
    .filter(([, def]) => def.agents.includes(agent))
    .map(([name, def]) => ({ name, description: def.description, parameters: def.parameters }));
}

export async function executeTool(
  name: string,
  args: Record<string, unknown>,
  ctx: { runId?: string } = {}
): Promise<unknown> {
  const def = REGISTRY[name];
  if (!def) throw new Error(`Tool not registered: ${name}`);
  return def.handler(args, ctx);
}

// ─────────────────────────────────────────────────────────────────────────────
//  Trace-lifecycle helpers — called directly by orchestrator, not by agents
// ─────────────────────────────────────────────────────────────────────────────

export function startTrace(args: {
  user_id: string;
  user_input: string;
}): { run_id: string } {
  // Synchronous — write goes to in-memory store immediately; Firestore write
  // (if configured) is fire-and-forget so we never block the SSE stream.
  const run_id = `run_${randomUUID().slice(0, 8)}`;
  const trace: Trace = {
    run_id,
    user_id: args.user_id,
    user_input: args.user_input,
    started_at: new Date().toISOString(),
    ended_at: null,
    status: 'running',
    steps: [],
  };
  putTrace(trace).catch((e) => console.error('[trace] putTrace failed (ignored):', e?.message));
  return { run_id };
}

export async function endTrace(args: {
  run_id: string;
  result: { booking_id?: string; status: string };
}): Promise<void> {
  await endTraceInStore(args.run_id, args.result);
}

export async function appendStep(run_id: string, step: TraceStep): Promise<void> {
  await appendTraceStep(run_id, step);
}
