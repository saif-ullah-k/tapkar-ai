/**
 * Static data loaders.
 *
 * Reads taxonomy.json and providers.karachi.json once at boot and caches in memory.
 * These files are the source of truth for service categories and seed providers.
 * NO code references them directly for decisioning — only via tools the agents call.
 *
 * Newly-registered providers (from the mobile onboarding wizard) are layered
 * on TOP of the seed file via the in-memory `_providers` array. When Firestore
 * is enabled, they're also persisted to the `providers/` collection so they
 * survive Cloud Run container cycles.
 */

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { config } from './config.js';
import type { Taxonomy, Provider } from './types.js';

const DATA_DIR = join(process.cwd(), '..', 'data');
const DATA_DIR_ALT = join(process.cwd(), 'data'); // when run from repo root

let _taxonomy: Taxonomy | null = null;
let _providers: Provider[] | null = null;
let _firestoreHydrated = false;

// ─────────────────────────────────────────────────────────────────────────────
// Lazy Firestore client (shared with store.ts conceptually but kept separate
// to avoid a circular import).
// ─────────────────────────────────────────────────────────────────────────────
let _firestore: any = null;
async function getFirestore(): Promise<any> {
  if (_firestore) return _firestore;
  if (!config.useFirestore) return null;
  try {
    const { Firestore } = await import('@google-cloud/firestore');
    _firestore = new Firestore({ projectId: config.gcp.projectId });
    return _firestore;
  } catch (e: any) {
    console.warn('[data] Firestore init failed (ignored):', e?.message ?? e);
    return null;
  }
}

function readData<T>(filename: string): T {
  for (const dir of [DATA_DIR, DATA_DIR_ALT]) {
    try {
      const raw = readFileSync(join(dir, filename), 'utf-8');
      return JSON.parse(raw) as T;
    } catch (e) {
      // try next location
    }
  }
  throw new Error(
    `[data] Could not find ${filename} in ${DATA_DIR} or ${DATA_DIR_ALT}. ` +
      `Run from backend/ or repo root.`
  );
}

export function loadTaxonomy(): Taxonomy {
  if (!_taxonomy) {
    _taxonomy = readData<Taxonomy>('taxonomy.json');
    console.log(`[data] Loaded taxonomy: ${_taxonomy.categories.length} categories`);
  }
  return _taxonomy;
}

// Categories where seed providers should default to FEMALE when gender is
// missing. Everything else defaults to male. This is a pragmatic fix —
// future onboarded providers carry their own `gender` field set by the
// provider themselves on signup.
const _FEMALE_DEFAULT_CATEGORIES = new Set([
  'beautician',
  'mehndi_artist',
  'babysitter',
  'eldercare',
]);

function inferGender(p: any): 'female' | 'male' {
  const explicit = (p?.gender as string | undefined)?.toLowerCase();
  if (explicit === 'female' || explicit === 'male') return explicit as any;
  // Names ending in "Hina", "Aisha", "Maria", "Sara", "Sania" → female heuristic
  if (typeof p?.name === 'string' && /\b(Hina|Aisha|Maria|Sara|Sania|Fatima|Ayesha)\b/i.test(p.name)) {
    return 'female';
  }
  if (_FEMALE_DEFAULT_CATEGORIES.has(p?.category)) return 'female';
  return 'male';
}

export function loadProviders(): Provider[] {
  if (!_providers) {
    const file = readData<{ providers: Provider[] }>('providers.karachi.json');
    // Back-fill `gender` on seed rows — the JSON file doesn't currently
    // carry one. This makes `female_provider_required` actually filter
    // (was a no-op before).
    _providers = file.providers.map((p) => ({
      ...p,
      gender: (p as any).gender ?? inferGender(p),
    } as Provider));
    console.log(`[data] Loaded providers: ${_providers.length} seed providers (gender back-filled)`);
  }
  return _providers;
}

// ─── Runtime provider registration ──────────────────────────────────────────
// Maps Firebase user_id → provider_id so a provider's login resumes their
// existing profile rather than asking them to onboard again.
//
// Providers persist to Firestore when enabled. On first lookup after a cold
// start, we lazily hydrate the in-memory cache from Firestore so registrations
// survive Cloud Run container cycles.
const _userIdToProviderId = new Map<string, string>();

/** Add a newly-registered provider to the in-memory store AND Firestore. */
export async function addProvider(provider: Provider, ownerUserId: string): Promise<void> {
  const all = loadProviders();
  const idx = all.findIndex((p) => p.id === provider.id);
  if (idx >= 0) {
    all[idx] = provider;
  } else {
    all.unshift(provider);
  }
  _userIdToProviderId.set(ownerUserId, provider.id);
  console.log(`[data] Provider registered: ${provider.id} (${provider.name}) for user ${ownerUserId}`);

  // Best-effort Firestore write — never let it crash the registration call.
  // Firestore rejects `undefined` values, so we strip them recursively first.
  try {
    const fs = await getFirestore();
    if (fs) {
      const safe = JSON.parse(JSON.stringify({ ...provider, owner_user_id: ownerUserId }));
      await fs.doc(`providers/${provider.id}`).set(safe);
      await fs.doc(`user_providers/${ownerUserId}`).set({ provider_id: provider.id });
      console.log(`[data] Persisted to Firestore: providers/${provider.id}`);
    }
  } catch (e: any) {
    console.warn('[data] Firestore write failed (ignored):', e?.message ?? e);
  }
}

/** Fetch a provider record straight from Firestore by id. Returns null if
 *  not found. Used by hot paths that can't trust the in-memory cache (which
 *  may be empty after a Cloud Run restart). Does NOT mutate the in-memory
 *  store — call addProvider separately if you want that. */
export async function getProviderFromFirestore(providerId: string): Promise<Provider | null> {
  try {
    const fs = await getFirestore();
    if (!fs) return null;
    const snap = await fs.doc(`providers/${providerId}`).get();
    if (!snap.exists) return null;
    const data = snap.data() as any;
    delete data.owner_user_id;
    return data as Provider;
  } catch (e: any) {
    console.warn('[data] getProviderFromFirestore failed (ignored):', e?.message ?? e);
    return null;
  }
}

/** Look up the provider_id owned by a given Firebase user, if any. */
export async function getProviderIdForUser(userId: string): Promise<string | undefined> {
  const cached = _userIdToProviderId.get(userId);
  if (cached) return cached;
  // Fall back to Firestore on cold-start
  try {
    const fs = await getFirestore();
    if (!fs) return undefined;
    const snap = await fs.doc(`user_providers/${userId}`).get();
    if (!snap.exists) return undefined;
    const providerId = snap.data()?.provider_id as string | undefined;
    if (providerId) {
      _userIdToProviderId.set(userId, providerId);
      // Also hydrate the provider record into the in-memory list if missing
      const all = loadProviders();
      if (!all.find((p) => p.id === providerId)) {
        const pSnap = await fs.doc(`providers/${providerId}`).get();
        if (pSnap.exists) {
          const data = pSnap.data() as any;
          delete data.owner_user_id;
          all.unshift(data as Provider);
          console.log(`[data] Hydrated provider ${providerId} from Firestore`);
        }
      }
    }
    return providerId;
  } catch (e: any) {
    console.warn('[data] Firestore read failed (ignored):', e?.message ?? e);
    return undefined;
  }
}

/** Hydrate all registered providers from Firestore. Called once on first
 *  provider-search after a cold start so newly-registered providers from
 *  prior container lifetimes are visible to discovery. */
export async function hydrateProvidersFromFirestore(): Promise<void> {
  if (_firestoreHydrated) return;
  _firestoreHydrated = true; // guard against parallel calls
  try {
    const fs = await getFirestore();
    if (!fs) return;
    const all = loadProviders();
    const existingIds = new Set(all.map((p) => p.id));
    const snap = await fs.collection('providers').get();
    let added = 0;
    snap.forEach((doc: any) => {
      const data = doc.data();
      if (!data?.id || existingIds.has(data.id)) return;
      delete data.owner_user_id;
      all.unshift(data as Provider);
      added++;
      // Also populate the user mapping if owner_user_id was set
      if (data.owner_user_id) _userIdToProviderId.set(data.owner_user_id, data.id);
    });
    if (added > 0) {
      console.log(`[data] Hydrated ${added} provider(s) from Firestore`);
    }
  } catch (e: any) {
    console.warn('[data] Firestore hydrate failed (ignored):', e?.message ?? e);
    _firestoreHydrated = false; // allow retry
  }
}

/** Reset caches — used in tests. */
export function resetDataCache(): void {
  _taxonomy = null;
  _providers = null;
  _userIdToProviderId.clear();
  _firestoreHydrated = false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Admin helpers
// ─────────────────────────────────────────────────────────────────────────────

/** Delete a provider from memory + Firestore (Admin). */
export async function deleteProviderAdmin(id: string): Promise<boolean> {
  const all = loadProviders();
  const idx = all.findIndex((p) => p.id === id);
  let removed = false;
  
  if (idx >= 0) {
    // Also remove from user mapping if present
    for (const [uid, pid] of _userIdToProviderId.entries()) {
      if (pid === id) {
        _userIdToProviderId.delete(uid);
      }
    }
    all.splice(idx, 1);
    removed = true;
  }
  
  try {
    const fs = await getFirestore();
    if (fs) {
      await fs.doc(`providers/${id}`).delete();
      // Try to clean up user_providers mappings as well
      const upSnap = await fs.collection('user_providers').where('provider_id', '==', id).get();
      const batch = fs.batch();
      upSnap.forEach((doc: any) => {
        batch.delete(doc.ref);
      });
      await batch.commit();
    }
  } catch (e: any) {
    console.warn('[data] deleteProviderAdmin Firestore delete failed (ignored):', e?.message ?? e);
  }
  
  return removed;
}
