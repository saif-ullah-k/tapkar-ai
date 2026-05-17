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
    if (fs) await fs.doc(`traces/${trace.run_id}`).set(trace);
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
        { steps: FieldValue.arrayUnion(step) },
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
  const fs = await getFirestore();
  if (fs) await fs.doc(`bookings/${booking.id}`).set(booking);
}

export async function getBookingFromStore(id: string): Promise<Booking | null> {
  if (mem.bookings.has(id)) return mem.bookings.get(id)!;
  const fs = await getFirestore();
  if (!fs) return null;
  const snap = await fs.doc(`bookings/${id}`).get();
  return snap.exists ? (snap.data() as Booking) : null;
}

export async function listBookingsForProvider(
  providerId: string,
  atIso: string
): Promise<Booking[]> {
  const all = Array.from(mem.bookings.values()).filter(
    (b) => b.provider_id === providerId && b.time_iso === atIso && b.status !== 'cancelled'
  );
  return all;
}

/** All bookings for a provider, newest first. Used by provider-mode screen. */
export async function listAllBookingsForProvider(
  providerId: string
): Promise<Booking[]> {
  return Array.from(mem.bookings.values())
    .filter((b) => b.provider_id === providerId)
    .sort((a, b) => (b.created_at ?? '').localeCompare(a.created_at ?? ''));
}

/** All inbox messages addressed to a provider. */
export async function listInboxForProvider(providerId: string): Promise<any[]> {
  return Array.from(mem.inbox.values())
    .filter((m: any) => m.to === 'provider' || m.to === 'both')
    .sort((a: any, b: any) => (b.ts ?? '').localeCompare(a.ts ?? ''));
}

export async function updateBookingStatusInStore(
  id: string,
  status: Booking['status']
): Promise<void> {
  const b = mem.bookings.get(id);
  if (b) {
    b.status = status;
    if (status === 'completed') b.completed_at = new Date().toISOString();
    mem.bookings.set(id, b);
  }
  const fs = await getFirestore();
  if (fs) await fs.doc(`bookings/${id}`).update({ status });
}

// ─────────────────────────────────────────────────────────────────────────────
// Scheduled jobs
// ─────────────────────────────────────────────────────────────────────────────

export async function putJob(job: ScheduledJob): Promise<void> {
  mem.jobs.set(job.id, job);
  const fs = await getFirestore();
  if (fs) await fs.doc(`scheduled_jobs/${job.id}`).set(job);
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
  return Array.from(mem.jobs.values()).filter(
    (j) => j.status === 'pending' && new Date(j.fire_at_iso).getTime() <= now
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Mock inbox (notifications)
// ─────────────────────────────────────────────────────────────────────────────

export async function putInboxMessage(message: any): Promise<void> {
  mem.inbox.set(message.message_id, message);
  const fs = await getFirestore();
  if (fs) await fs.doc(`mock_inbox/${message.message_id}`).set(message);
}
