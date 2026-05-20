/**
 * Persistence layer.
 *
 * Two backends with identical interface:
 *   - Firestore — when GCP_PROJECT is set
 *   - In-memory  — Day 1 default (no GCP needed)
 *
 * Agents never call this directly — only tools do. This file is pure I/O.
 */

import { config } from './config.js';
import type { Booking, Trace, TraceStep, ScheduledJob } from './types.js';

// ─────────────────────────────────────────────────────────────────────────────
// Lazy Firestore client — only imported when actually needed
// ─────────────────────────────────────────────────────────────────────────────

let _firestore: any = null;
async function getFirestore(): Promise<any> {
  if (_firestore) return _firestore;
  if (!config.useFirestore) return null;
  const { Firestore } = await import('@google-cloud/firestore');
  _firestore = new Firestore({ projectId: config.gcp.projectId });
  return _firestore;
}

/** Recursively strip `undefined` values from an object so Firestore writes
 *  never reject. Firestore allows null but not undefined. */
function stripUndefined<T>(obj: T): T {
  if (obj === null || typeof obj !== 'object') return obj;
  if (Array.isArray(obj)) {
    return obj
      .map((v) => stripUndefined(v))
      .filter((v) => v !== undefined) as unknown as T;
  }
  const out: any = {};
  for (const [k, v] of Object.entries(obj as any)) {
    if (v === undefined) continue;
    out[k] = stripUndefined(v as any);
  }
  return out as T;
}

// ─────────────────────────────────────────────────────────────────────────────
// In-memory backing (Day 1 default)
// ─────────────────────────────────────────────────────────────────────────────

const mem = {
  traces: new Map<string, Trace>(),
  bookings: new Map<string, Booking>(),
  jobs: new Map<string, ScheduledJob>(),
  inbox: new Map<string, any>(),
};

/** Live subscribers for SSE — keyed by run_id. */
const traceSubscribers = new Map<string, Array<(step: TraceStep) => void>>();

// ─────────────────────────────────────────────────────────────────────────────
// Traces
// ─────────────────────────────────────────────────────────────────────────────

export async function putTrace(trace: Trace): Promise<void> {
  mem.traces.set(trace.run_id, trace);
  // Firestore write is best-effort — never let it crash the pipeline.
  try {
    const fs = await getFirestore();
    if (fs) await fs.doc(`traces/${trace.run_id}`).set(stripUndefined(trace));
  } catch (e: any) {
    console.warn(`[store] putTrace Firestore write failed (ignored):`, e?.message ?? e);
  }
}

export async function appendTraceStep(runId: string, step: TraceStep): Promise<void> {
  const existing = mem.traces.get(runId);
  if (existing) {
    existing.steps.push(step);
    mem.traces.set(runId, existing);
  }
  // Firestore write is best-effort — never let it crash the pipeline.
  try {
    const fs = await getFirestore();
    if (fs) {
      const { FieldValue } = await import('@google-cloud/firestore');
      await fs.doc(`traces/${runId}`).set(
        { steps: FieldValue.arrayUnion(stripUndefined(step)) },
        { merge: true }
      );
    }
  } catch (e: any) {
    console.warn(`[store] appendTraceStep Firestore write failed (ignored):`, e?.message ?? e);
  }
  // Fan out to live subscribers (SSE)
  const subs = traceSubscribers.get(runId);
  if (subs) for (const cb of subs) cb(step);
  if (config.features.debugTraces) {
    console.log(`[trace ${runId}] ${step.agent}: ${step.reasoning?.slice(0, 80)}`);
  }
}

export async function endTraceInStore(
  runId: string,
  result: { booking_id?: string; status: string }
): Promise<void> {
  const existing = mem.traces.get(runId);
  if (existing) {
    existing.status = 'complete';
    existing.ended_at = new Date().toISOString();
    existing.result = result;
  }
  try {
    const fs = await getFirestore();
    if (fs) {
      await fs.doc(`traces/${runId}`).set(
        { status: 'complete', ended_at: new Date().toISOString(), result },
        { merge: true }
      );
    }
  } catch (e: any) {
    console.warn(`[store] endTraceInStore Firestore write failed (ignored):`, e?.message ?? e);
  }
}

export async function getTrace(runId: string): Promise<Trace | null> {
  if (mem.traces.has(runId)) return mem.traces.get(runId)!;
  const fs = await getFirestore();
  if (!fs) return null;
  const snap = await fs.doc(`traces/${runId}`).get();
  return snap.exists ? (snap.data() as Trace) : null;
}

export function subscribeTrace(runId: string, cb: (step: TraceStep) => void): () => void {
  const list = traceSubscribers.get(runId) ?? [];
  list.push(cb);
  traceSubscribers.set(runId, list);
  return () => {
    const cur = traceSubscribers.get(runId) ?? [];
    traceSubscribers.set(runId, cur.filter((f) => f !== cb));
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Bookings
// ─────────────────────────────────────────────────────────────────────────────

export async function putBooking(booking: Booking): Promise<void> {
  mem.bookings.set(booking.id, booking);
  try {
    const fs = await getFirestore();
    if (fs) await fs.doc(`bookings/${booking.id}`).set(stripUndefined(booking));
  } catch (e: any) {
    console.warn('[store] putBooking Firestore write failed (ignored):', e?.message ?? e);
  }
}

export async function getBookingFromStore(id: string): Promise<Booking | null> {
  if (mem.bookings.has(id)) return mem.bookings.get(id)!;
  const fs = await getFirestore();
  if (!fs) return null;
  const snap = await fs.doc(`bookings/${id}`).get();
  return snap.exists ? (snap.data() as Booking) : null;
}

/** Merge in-memory + Firestore bookings into a single deduped map. */
async function _allBookings(): Promise<Map<string, Booking>> {
  const out = new Map<string, Booking>(mem.bookings);
  try {
    const fs = await getFirestore();
    if (fs) {
      const snap = await fs.collection('bookings').get();
      snap.forEach((doc: any) => {
        const b = doc.data() as Booking;
        if (b?.id && !out.has(b.id)) out.set(b.id, b);
      });
    }
  } catch (e: any) {
    console.warn('[store] _allBookings Firestore read failed (ignored):', e?.message ?? e);
  }
  return out;
}

export async function listBookingsForProvider(
  providerId: string,
  atIso: string
): Promise<Booking[]> {
  const all = await _allBookings();
  return Array.from(all.values()).filter(
    (b) => b.provider_id === providerId && b.time_iso === atIso && b.status !== 'cancelled'
  );
}

/** All bookings for a provider, newest first. Used by provider-mode screen. */
export async function listAllBookingsForProvider(
  providerId: string
): Promise<Booking[]> {
  const all = await _allBookings();
  return Array.from(all.values())
    .filter((b) => b.provider_id === providerId)
    .sort((a, b) => (b.created_at ?? '').localeCompare(a.created_at ?? ''));
}

/** Merge in-memory + Firestore inbox messages. */
async function _allInboxMessages(): Promise<any[]> {
  const out = new Map<string, any>();
  for (const [k, v] of mem.inbox) out.set(k, v);
  try {
    const fs = await getFirestore();
    if (fs) {
      const snap = await fs.collection('mock_inbox').get();
      snap.forEach((doc: any) => {
        const m = doc.data();
        const key = m.message_id ?? doc.id;
        if (!out.has(key)) out.set(key, m);
      });
    }
  } catch (e: any) {
    console.warn('[store] _allInboxMessages Firestore read failed (ignored):', e?.message ?? e);
  }
  return Array.from(out.values());
}

/** All inbox messages addressed to a provider. */
export async function listInboxForProvider(providerId: string): Promise<any[]> {
  const all = await _allInboxMessages();
  return all
    .filter((m: any) => (m.to === 'provider' || m.to === 'both') &&
      (m.provider_id === providerId || m.provider_id == null))
    .sort((a: any, b: any) => (b.ts ?? '').localeCompare(a.ts ?? ''));
}

/** All bookings for a user (customer side), newest first. */
export async function listBookingsForUser(userId: string): Promise<Booking[]> {
  const all = await _allBookings();
  return Array.from(all.values())
    .filter((b) => b.user_id === userId)
    .sort((a, b) => (b.created_at ?? '').localeCompare(a.created_at ?? ''));
}

/** All inbox messages addressed to a user. */
export async function listInboxForUser(userId: string): Promise<any[]> {
  const all = await _allInboxMessages();
  return all
    .filter(
      (m: any) =>
        (m.to === 'user' || m.to === 'both') &&
        (m.user_id === userId || m.user_id == null)
    )
    .sort((a: any, b: any) => (b.ts ?? '').localeCompare(a.ts ?? ''));
}

/** Merge in-memory + Firestore scheduled jobs. */
async function _allJobs(): Promise<Map<string, ScheduledJob>> {
  const out = new Map<string, ScheduledJob>(mem.jobs);
  try {
    const fs = await getFirestore();
    if (fs) {
      const snap = await fs.collection('scheduled_jobs').get();
      snap.forEach((doc: any) => {
        const j = doc.data() as ScheduledJob;
        if (j?.id && !out.has(j.id)) out.set(j.id, j);
      });
    }
  } catch (e: any) {
    console.warn('[store] _allJobs Firestore read failed (ignored):', e?.message ?? e);
  }
  return out;
}

/** All scheduled jobs (reminders) tied to a user's bookings. */
export async function listScheduledForUser(userId: string): Promise<ScheduledJob[]> {
  const bookings = await _allBookings();
  const userBookingIds = new Set(
    Array.from(bookings.values()).filter((b) => b.user_id === userId).map((b) => b.id)
  );
  const jobs = await _allJobs();
  return Array.from(jobs.values())
    .filter((j) => userBookingIds.has(j.booking_id))
    .sort((a, b) => (a.fire_at_iso ?? '').localeCompare(b.fire_at_iso ?? ''));
}

export async function updateBookingStatusInStore(
  id: string,
  status: Booking['status']
): Promise<void> {
  let b = mem.bookings.get(id);
  // If not in memory (Cloud Run cycled), pull from Firestore first so we can
  // update it and persist the new status.
  if (!b) {
    try {
      const fs = await getFirestore();
      if (fs) {
        const snap = await fs.doc(`bookings/${id}`).get();
        if (snap.exists) {
          b = snap.data() as Booking;
          mem.bookings.set(id, b);
        }
      }
    } catch (_) {}
  }
  if (b) {
    b.status = status;
    if (status === 'completed') b.completed_at = new Date().toISOString();
    mem.bookings.set(id, b);
  }
  try {
    const fs = await getFirestore();
    if (fs) await fs.doc(`bookings/${id}`).set({ status }, { merge: true });
  } catch (e: any) {
    console.warn('[store] updateBookingStatus Firestore write failed (ignored):', e?.message ?? e);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Scheduled jobs
// ─────────────────────────────────────────────────────────────────────────────

export async function putJob(job: ScheduledJob): Promise<void> {
  mem.jobs.set(job.id, job);
  try {
    const fs = await getFirestore();
    if (fs) await fs.doc(`scheduled_jobs/${job.id}`).set(stripUndefined(job));
  } catch (e: any) {
    console.warn('[store] putJob Firestore write failed (ignored):', e?.message ?? e);
  }
}

export async function cancelJobsForBooking(bookingId: string): Promise<number> {
  let n = 0;
  for (const [id, job] of mem.jobs) {
    if (job.booking_id === bookingId && job.status === 'pending') {
      job.status = 'cancelled';
      mem.jobs.set(id, job);
      n++;
    }
  }
  return n;
}

export async function listDueJobs(): Promise<ScheduledJob[]> {
  const now = Date.now();
  const jobs = await _allJobs();
  return Array.from(jobs.values()).filter(
    (j) => j.status === 'pending' && new Date(j.fire_at_iso).getTime() <= now
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Mock inbox (notifications)
// ─────────────────────────────────────────────────────────────────────────────

export async function putInboxMessage(message: any): Promise<void> {
  mem.inbox.set(message.message_id, message);
  try {
    const fs = await getFirestore();
    if (fs) await fs.doc(`mock_inbox/${message.message_id}`).set(stripUndefined(message));
  } catch (e: any) {
    console.warn('[store] putInboxMessage Firestore write failed (ignored):', e?.message ?? e);
  }
}
