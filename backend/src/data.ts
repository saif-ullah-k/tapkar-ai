/**
 * Static data loaders.
 *
 * Reads taxonomy.json and providers.karachi.json once at boot and caches in memory.
 * These files are the source of truth for service categories and seed providers.
 * NO code references them directly for decisioning — only via tools the agents call.
 */

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import type { Taxonomy, Provider } from './types.js';

const DATA_DIR = join(process.cwd(), '..', 'data');
const DATA_DIR_ALT = join(process.cwd(), 'data'); // when run from repo root

let _taxonomy: Taxonomy | null = null;
let _providers: Provider[] | null = null;

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

export function loadProviders(): Provider[] {
  if (!_providers) {
    const file = readData<{ providers: Provider[] }>('providers.karachi.json');
    _providers = file.providers;
    console.log(`[data] Loaded providers: ${_providers.length} seed providers`);
  }
  return _providers;
}

/** Reset caches — used in tests. */
export function resetDataCache(): void {
  _taxonomy = null;
  _providers = null;
}
