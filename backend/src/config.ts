/**
 * Environment configuration.
 *
 * Day 1 must run without any GCP/Firestore setup — if env vars are missing,
 * we fall back to in-memory storage and mock-only Places. The deployed product
 * needs only GEMINI_API_KEY to be functional.
 */

export const config = {
  port: Number(process.env.PORT ?? 8080),

  gemini: {
    // AI Studio API key (fallback path when not using Vertex AI)
    apiKey: process.env.GEMINI_API_KEY ?? '',
    defaultModel: process.env.GEMINI_MODEL ?? 'gemini-2.5-flash',
    flashModel: process.env.GEMINI_FLASH_MODEL ?? 'gemini-2.5-flash',
    // Use Vertex AI instead of AI Studio. Authenticates via Application
    // Default Credentials (gcloud auth application-default login) and bills
    // against your GCP project — same hackathon credits work.
    useVertex: process.env.USE_VERTEX_AI === 'true',
  },

  gcp: {
    projectId: process.env.GCP_PROJECT ?? '',
    location: process.env.GCP_LOCATION ?? 'us-central1',
    mapsApiKey: process.env.GOOGLE_MAPS_API_KEY ?? '',
  },

  features: {
    // When false, places_*_search return [] and discovery relies on mock providers only.
    useRealPlaces: process.env.USE_REAL_PLACES === 'true',
    // When true, traces also stream to stdout for local debugging
    debugTraces: process.env.DEBUG_TRACES !== 'false',
  },

  limits: {
    maxOrchestratorSteps: Number(process.env.MAX_STEPS ?? 12),
    perAgentTimeoutMs: Number(process.env.AGENT_TIMEOUT_MS ?? 30_000),
    runTimeoutMs: Number(process.env.RUN_TIMEOUT_MS ?? 90_000),
  },

  /**
   * True only if Firestore is explicitly opted in. Setting GCP_PROJECT alone
   * (e.g., for Vertex AI) does NOT enable Firestore — that requires
   * USE_FIRESTORE=true in addition.
   */
  get useFirestore(): boolean {
    return process.env.USE_FIRESTORE === 'true' && Boolean(this.gcp.projectId);
  },
};

export function validateConfig(): void {
  if (config.gemini.useVertex) {
    if (!config.gcp.projectId) {
      console.warn(
        '[config] USE_VERTEX_AI=true but GCP_PROJECT is not set. /run will fail. ' +
          'Set GCP_PROJECT=your-project-id and run `gcloud auth application-default login`.'
      );
    } else {
      console.log(
        `[config] Vertex AI enabled · project=${config.gcp.projectId} · location=${config.gcp.location}`
      );
    }
  } else if (!config.gemini.apiKey) {
    console.warn(
      '[config] GEMINI_API_KEY is not set. /run requests will return 500. ' +
        'Get a key at https://aistudio.google.com/apikey or set USE_VERTEX_AI=true.'
    );
  } else {
    console.log('[config] Using AI Studio Gemini API with API key.');
  }
  if (!config.useFirestore) {
    console.log('[config] No GCP_PROJECT set — using in-memory store (Day 1 mode).');
  }
  if (!config.features.useRealPlaces) {
    console.log('[config] USE_REAL_PLACES=false — Discovery uses mock providers only.');
  }
}

/** Resolve the model for a given agent name, with env-var override support. */
export function modelForAgent(agentName: string): string {
  const envKey = `MODEL_${agentName.toUpperCase()}`;
  return process.env[envKey] ?? config.gemini.defaultModel;
}
