/**
 * Orchestrator — deterministic pipeline dispatcher.
 *
 * Runs subagents in a fixed sequence: intent → discovery → ranking → booking
 * → followup. Each subagent does ALL the business reasoning for its stage
 * (parse, search, rank, confirm, schedule). The pipeline order itself is an
 * architectural choice, not a business decision, so it lives in code.
 *
 * This file contains zero business logic. No category checks, no scoring,
 * no preference handling — those live entirely in the .agent.md prompts.
 */

import { runAgent } from './gemini.js';
import { startTrace, endTrace, appendStep } from './tools/index.js';
import { loadProviders } from './data.js';
import type { AgentName, TraceStep } from './types.js';

export interface RunInput {
  user_id: string;
  user_input: string;
  /** User's preferred reply language (en | ur | roman_ur). When set, agents
   *  must answer in this language regardless of what the user typed in. */
  language?: string;
  /** Set when the user has explicitly picked a provider from a previous
   *  "show_options" turn. Orchestrator then skips discovery + ranking and
   *  books that specific provider at the locked time. */
  selected_provider_id?: string;
  selected_time_iso?: string;
  /** Echo of intent from the previous /run. When provided in locked mode the
   *  orchestrator skips the intent agent entirely — saves ~10 s per booking. */
  prior_intent?: any;
  /** User's gender. Bot speaks with matching grammatical gender in
   *  Urdu / Roman Urdu. */
  user_gender?: string;
}

export interface StreamEvent {
  event: 'run_started' | 'step' | 'user_message' | 'run_complete' | 'error';
  data: Record<string, unknown>;
}

const PIPELINE: AgentName[] = ['intent', 'discovery', 'ranking', 'booking', 'followup'];

// Cache transliterations so repeat phrases (very common in clarification
// loops) don't re-hit the LLM. Bounded to last 200 entries.
const _translitCache = new Map<string, string>();

async function transliterateRomanUrduToUrdu(text: string): Promise<string> {
  // Strip multi-turn markers so we only translit the actual content.
  const stripped = text.replace(/^Turn\s+\d+:\s*/gim, '').trim();
  const cacheKey = stripped.toLowerCase();
  const cached = _translitCache.get(cacheKey);
  if (cached) return cached;

  try {
    const { GoogleGenAI } = await import('@google/genai');
    const { config } = await import('./config.js');
    const client = config.gemini.useVertex
      ? new GoogleGenAI({ vertexai: true, project: config.gcp.projectId, location: config.gcp.location })
      : new GoogleGenAI({ apiKey: config.gemini.apiKey });
    const resp = await client.models.generateContent({
      model: 'gemini-2.5-flash-lite',
      contents: [{
        role: 'user',
        parts: [{
          text:
            `Convert this Roman Urdu (Latin-script Urdu) to proper Urdu in Nastaliq script. ` +
            `Keep English loanwords (plumber, AC, doctor, etc.) and proper nouns (Gulshan, DHA) as Urdu spellings. ` +
            `Output ONLY the Urdu text, no commentary, no quotes.\n\n` +
            `Roman Urdu: ${stripped}\n\nUrdu:`,
        }],
      }],
      config: {
        temperature: 0,
        maxOutputTokens: 200,
      } as any,
    });
    const urdu = (resp.candidates?.[0]?.content?.parts?.map((p: any) => p.text).join('').trim() ?? '');
    if (urdu) {
      if (_translitCache.size > 200) _translitCache.clear();
      _translitCache.set(cacheKey, urdu);
      return urdu;
    }
  } catch (e: any) {
    console.warn('[pipeline] transliteration failed, using original Roman Urdu:', e?.message ?? e);
  }
  return stripped;
}

export async function* runPipeline(input: RunInput): AsyncGenerator<StreamEvent> {
  console.log('[pipeline] starting deterministic agent sequence');
  const t0 = Date.now();
  const { run_id } = startTrace({
    user_id: input.user_id,
    user_input: input.user_input,
  });

  // Pre-process: when the user's language is Roman Urdu, transliterate to
  // proper Urdu first. LLMs reason MUCH better in Nastaliq than in Roman
  // Urdu (where every word has 4 spelling variants). The transliterated
  // version is appended to the original — agents see BOTH so they can
  // cross-reference. ~1-2s overhead; saves multi-second iteration loss
  // from agents getting confused by spelling.
  let effectiveInput = input.user_input;
  if (input.language === 'roman_ur') {
    const urdu = await transliterateRomanUrduToUrdu(input.user_input);
    if (urdu && urdu !== input.user_input.trim()) {
      effectiveInput = `${input.user_input}\n\n[Urdu equivalent for clarity]: ${urdu}`;
      console.log(`[pipeline] transliterated roman_ur -> ur: "${urdu.slice(0, 80)}"`);
    }
  }
  input = { ...input, user_input: effectiveInput };

  yield {
    event: 'run_started',
    data: { run_id, user_input: input.user_input, started_at: new Date().toISOString() },
  };

  const isLocked = Boolean(input.selected_provider_id);
  const state: Record<string, unknown> = {
    user_id: input.user_id,
    user_input: input.user_input,
    user_language: input.language ?? null,
    user_gender: input.user_gender ?? null,
    user_locked_provider_id: input.selected_provider_id ?? null,
    user_locked_time_iso: input.selected_time_iso ?? null,
    intent: null,
    discovery: null,
    ranking: null,
    booking: null,
    followup: null,
  };

  let lastBookingId: string | undefined;
  let pipelineStatus:
    | 'complete'
    | 'failed'
    | 'aborted'
    | 'awaiting_user_input' = 'complete';

  // When the user has already picked a provider, short-circuit the pipeline:
  // run only intent (for context) → booking (locked). Followup runs as a
  // fire-and-forget side task AFTER booking returns.
  //
  // If the frontend echoed back the prior intent, skip the intent agent
  // entirely — we already have the structured fields it would produce.
  // This shaves ~10s off the locked-mode flow.
  const haveCachedIntent = isLocked && input.prior_intent &&
    typeof input.prior_intent === 'object' &&
    !Array.isArray(input.prior_intent);
  if (haveCachedIntent) {
    state.intent = input.prior_intent;
    console.log('[pipeline] using prior_intent from frontend, skipping intent agent');
  }
  // Discovery is now run DETERMINISTICALLY in code right after intent —
  // search_providers is a pure category+distance filter, no LLM judgment
  // needed. Skipping the discovery agent saves ~6-10s per pipeline run
  // and removes the most common hallucination source.
  const activePipeline: AgentName[] = isLocked
    ? (haveCachedIntent ? ['booking'] : ['intent', 'booking'])
    : ['intent', 'ranking', 'booking'];

  try {
    for (const agentName of activePipeline) {
      const stepT0 = Date.now();
      console.log(`[pipeline] dispatching ${agentName}...`);

      // In locked mode, inject a synthetic ranking output before booking so
      // the booking agent receives the user's chosen provider as the
      // recommendation (instead of running discovery + ranking again).
      if (isLocked && agentName === 'booking' && !state.ranking) {
        state.ranking = {
          top_3: [{
            provider_id: input.selected_provider_id,
            rank: 1,
            score: 1.0,
            reasoning: 'User explicitly selected this provider from the previous options.',
          }],
          recommendation_mode: 'user_selected',
        };
      }

      const result = await runAgent(agentName, compactState(state, agentName), {
        runId: run_id,
      });

      state[agentName] = result.output;

      // After INTENT: deterministic "kal" / "tomorrow" rescue. If the user
      // input contains a future-tomorrow keyword but the agent resolved
      // time.iso to the past, bump it forward by 24h. Flash-lite reads
      // "kal" as yesterday occasionally and we don't want to bother the
      // user about it — fix silently.
      if (agentName === 'intent' && !isLocked) {
        const intentOut = state.intent as any;
        const userText = (input.user_input ?? '').toString().toLowerCase();
        const hasTomorrowWord =
          /\b(kal|tomorrow|aaj\s*raat\s*ke\s*baad)\b/.test(userText) ||
          userText.includes('کل');
        const hasDayAfter = /\b(parso|parsoo|parson|parsoon|day\s+after\s+tomorrow)\b/.test(userText);
        if (intentOut && intentOut.needs_clarification !== true && intentOut.time?.iso) {
          const resolved = new Date(intentOut.time.iso);
          const nowMs = Date.now();
          if (!isNaN(resolved.getTime()) && resolved.getTime() < nowMs - 5 * 60_000) {
            // Resolved time is more than 5 minutes in the past.
            let bumpDays = 0;
            if (hasDayAfter) {
              bumpDays = 2;
            } else if (hasTomorrowWord) {
              bumpDays = 1;
            }
            if (bumpDays > 0) {
              // Bump enough days to land in the future (handles weird agent outputs).
              while (resolved.getTime() < nowMs) {
                resolved.setUTCDate(resolved.getUTCDate() + bumpDays);
              }
              const fixedIso = resolved.toISOString().replace('Z', '+00:00');
              console.warn(
                `[pipeline] "kal"/"parsoo" rescue: ${intentOut.time.iso} -> ${fixedIso}`
              );
              intentOut.time.iso = fixedIso;
              if (intentOut.booking?.occurrence) {
                intentOut.booking.occurrence.iso = fixedIso;
              }
            }
          }
        }
      }

      // After INTENT: deterministic safety net — flash-lite sometimes
      // proceeds to discovery with missing location or time even though
      // its own prompt says to ask for clarification. We validate the
      // intent output here and FORCE a clarification step if critical
      // fields are missing. This guarantees the user always gets asked
      // for what's needed, regardless of the agent's stochastic judgment.
      if (agentName === 'intent' && !isLocked) {
        const intentOut = result.output as any;
        if (intentOut && intentOut.needs_clarification !== true) {
          const hasService = Boolean(
            (intentOut.service?.category_id) ?? intentOut.service?.free_text
          );
          const loc = intentOut.location;
          const hasLocation = Boolean(
            loc && (loc.use_user_default === true || (typeof loc.lat === 'number' && typeof loc.lng === 'number'))
          );
          const timeOk = Boolean(
            intentOut.time?.iso ||
            intentOut.booking?.occurrence?.iso ||
            intentOut.booking?.recurrence?.start_date_iso ||
            intentOut.urgency === 'emergency'
          );
          const missing: string[] = [];
          if (!hasService) missing.push('service');
          if (!hasLocation) missing.push('location');
          if (!timeOk) missing.push('time');
          if (missing.length > 0) {
            console.warn(`[pipeline] intent claimed complete but missing ${missing.join(',')} — forcing clarification`);
            const userLang = (state.user_language as string | null) ??
                             (intentOut.language as string | null) ?? 'en';
            const question = (() => {
              const bothLocTime = missing.includes('location') && missing.includes('time');
              if (missing.includes('service')) {
                return userLang === 'ur'
                  ? 'کون سی سروس چاہیے؟ (پلمبر، الیکٹریشن، ٹیوٹر، بیوٹیشن...)'
                  : userLang === 'roman_ur'
                  ? 'Konsa service chahiye? (plumber, electrician, AC, tutor, beautician...)'
                  : 'What service do you need? (plumber, electrician, AC tech, tutor, beautician...)';
              }
              if (bothLocTime) {
                return userLang === 'ur'
                  ? 'کہاں اور کس وقت چاہیے؟ (علاقہ اور دن/وقت)'
                  : userLang === 'roman_ur'
                  ? 'Kahan aur kis waqt chahiye? (Area aur day/time)'
                  : 'Where and what time would you like the service?';
              }
              if (missing.includes('location')) {
                return userLang === 'ur'
                  ? 'کس علاقے میں چاہیے؟ (مثلاً گلشن، ڈی ایچ اے، کلفٹن)'
                  : userLang === 'roman_ur'
                  ? 'Kis area mein chahiye? (Gulshan, DHA, Clifton, ya kahin aur?)'
                  : 'Which area would you like the service in?';
              }
              // missing time only
              return userLang === 'ur'
                ? 'کس دن اور کس وقت چاہیے؟'
                : userLang === 'roman_ur'
                ? 'Kis din aur kis waqt chahiye?'
                : 'What day and time works for you?';
            })();

            // Replace the intent output with a Case-B clarification before
            // we yield the step event so the rest of the pipeline sees the
            // corrected shape.
            (state.intent as any) = {
              needs_clarification: true,
              language: userLang,
              have: {
                service: intentOut.service?.category_id ?? intentOut.service?.free_text ?? null,
                location: loc?.label ?? null,
                time: intentOut.time?.user_phrase ?? null,
              },
              missing,
              question,
            };

            const fixedStep: TraceStep = {
              agent: 'intent',
              reasoning: `Forced clarification — agent claimed complete but missing: ${missing.join(', ')}.`,
              tools_called: result.tool_calls,
              output: state.intent,
              ms: Date.now() - stepT0,
              ts: new Date().toISOString(),
            };
            await appendStep(run_id, fixedStep);
            yield { event: 'step', data: fixedStep as any };
            yield {
              event: 'user_message',
              data: { text: question, language: userLang },
            };
            pipelineStatus = 'awaiting_user_input';
            break;
          }
        }
      }

      // After INTENT (when not locked): deterministically run discovery in
      // code — search_providers is a category+distance filter, doesn't
      // need an LLM. This replaces what used to be the discovery agent,
      // shaving ~6-10s per pipeline run and eliminating one common
      // hallucination source. Result is written into state.discovery and
      // also emitted as a step event so the trace panel still shows
      // "discovery" activity.
      if (agentName === 'intent' && !isLocked && state.intent) {
        const intentOut = state.intent as any;
        if (intentOut.needs_clarification !== true) {
          try {
            const { executeTool } = await import('./tools/index.js');
            const loc = intentOut.location ?? {};
            const near = (typeof loc.lat === 'number' && typeof loc.lng === 'number')
              ? { lat: loc.lat, lng: loc.lng }
              : { lat: 24.87, lng: 67.03 }; // Karachi center fallback
            const discoveryT0 = Date.now();
            const candidates = (await executeTool(
              'search_providers',
              {
                category_id: intentOut.service?.category_id,
                free_text: intentOut.service?.free_text,
                near,
                radius_km: 15,
                specializations: intentOut.service?.specializations ?? [],
              },
              { runId: run_id }
            )) as any[];
            // Inline availability filter — discovery agent is no longer
            // in the pipeline so its post-step filter never runs.
            const requestedIso = intentOut.time?.iso ??
                                 intentOut.booking?.occurrence?.iso ?? null;
            let filtered = candidates;
            if (requestedIso) {
              const { isAvailable } = await import('./tools/index.js');
              const beforeCount = candidates.length;
              filtered = candidates.filter((c: any) => {
                if (c.available_now === false) return false;
                return isAvailable(c, requestedIso);
              });
              console.log(`[pipeline] availability-filter: ${beforeCount} -> ${filtered.length} for ${requestedIso}`);
            }
            state.discovery = {
              candidates: filtered,
              search_strategy: `Deterministic: category=${intentOut.service?.category_id ?? '?'}, radius=15km${requestedIso ? `, availability-filtered for ${requestedIso}` : ''}`,
              source: 'deterministic',
            };
            const discoveryStep: TraceStep = {
              agent: 'discovery',
              reasoning: `Found ${filtered.length} of ${candidates.length} candidate(s) (no LLM, no hallucination).`,
              tools_called: [
                {
                  name: 'search_providers',
                  input: { category_id: intentOut.service?.category_id, near, radius_km: 15 },
                  output: { count: filtered.length },
                  ms: Date.now() - discoveryT0,
                  ts: new Date().toISOString(),
                },
              ],
              output: state.discovery,
              ms: Date.now() - discoveryT0,
              ts: new Date().toISOString(),
            };
            await appendStep(run_id, discoveryStep);
            yield { event: 'step', data: discoveryStep as any };
            console.log(`[pipeline] discovery (deterministic+filtered): ${filtered.length} candidates in ${Date.now() - discoveryT0}ms`);

            // Empty after filtering → stop with friendly message.
            if (filtered.length === 0 && requestedIso) {
              const userLang = (state.user_language as string | null) ?? 'en';
              const msg = userLang === 'ur'
                ? 'افسوس — اس وقت کوئی سروس فراہم کنندہ دستیاب نہیں۔ کوئی اور وقت آزمائیں؟'
                : userLang === 'roman_ur'
                  ? 'Sorry — is waqt koi provider available nahi. Koi aur time try karein?'
                  : "Sorry — no providers are available at that time. Try a different time?";
              yield { event: 'user_message', data: { text: msg, language: userLang } };
              pipelineStatus = 'awaiting_user_input';
              break;
            }
          } catch (err: any) {
            console.error(`[pipeline] deterministic discovery failed: ${err?.message ?? err}`);
            state.discovery = { candidates: [], error: err?.message ?? String(err) };
          }
        }
      }

      // After INTENT (when not locked): if the user named a specific
      // provider in their utterance ("naam hai Saifullah", "Ahmed ke saath",
      // "with Ali Plumbing"), bias the candidate pool to that provider.
      // Done deterministically here because agents are flaky at name
      // extraction.
      if (agentName === 'intent' && !isLocked) {
        const intentOut = state.intent as any;
        if (intentOut && intentOut.needs_clarification !== true) {
          // Scan ONLY the LATEST turn for a name hint, not the accumulated
          // multi-turn transcript. Otherwise an earlier turn containing a
          // name (e.g. "saifullah") leaks into every subsequent request
          // during a clarification cycle.
          const rawInput = (input.user_input ?? '').toString();
          const turnLines = rawInput
            .split('\n')
            .map((l) => l.trim())
            .filter((l) => l.length > 0);
          const lastLine = turnLines[turnLines.length - 1] ?? rawInput;
          const userText = lastLine.replace(/^Turn\s+\d+:\s*/i, '');

          // Patterns covering Urdu / Roman Urdu / English ways of naming
          // a provider. Cue word (case-insensitive) then up to 3 names.
          const nameMatch = userText.match(
            /(?:naam hai|naam:|ka naam|jiska naam(?: hai)?|named|called|ke saath|with)\s+([a-zA-Z]{2,30}(?:\s+[a-zA-Z]{1,30}){0,2})/i
          );
          const explicitHint =
            (intentOut.service?.provider_name_hint as string | undefined) ?? null;
          const nameHint = (explicitHint || nameMatch?.[1] || '').trim();
          if (nameHint) {
            const { loadProviders } = await import('./data.js');
            const all = loadProviders();
            const needle = nameHint.toLowerCase();
            const matches = all.filter((p) =>
              p.name.toLowerCase().includes(needle)
            );
            console.log(`[pipeline] name-hint="${nameHint}" → ${matches.length} match(es)`);
            if (matches.length > 0) {
              // Inject a synthetic discovery output so discovery agent gets
              // skipped and ranking sees ONLY the named provider(s).
              state.discovery = {
                candidates: matches.map((p) => ({
                  ...p,
                  distance_km: 0,
                  availability_at_request: 'available',
                  matched_by: 'user_named_provider',
                })),
                search_strategy: `User explicitly named "${nameHint}". Surfacing matching provider(s) only.`,
                name_hint: nameHint,
              };
            } else {
              // No provider with that name → surface a friendly miss
              // instead of falling through to a fruitless discovery search.
              const userLang = (state.user_language as string | null) ?? 'en';
              const missMsg = userLang === 'ur'
                ? `"${nameHint}" نام کا کوئی پرووائڈر نہیں ملا۔ کیا میں دوسرے آپشن دکھاؤں؟`
                : userLang === 'roman_ur'
                ? `"${nameHint}" naam ka koi provider nahi mila. Kya main doosre options dikhaun?`
                : `Couldn't find a provider named "${nameHint}". Want me to show other options?`;
              const missStep: TraceStep = {
                agent: 'discovery',
                reasoning: `User named "${nameHint}" but no provider matched.`,
                tools_called: result.tool_calls,
                output: { candidates: [], name_hint: nameHint, miss: true },
                ms: Date.now() - stepT0,
                ts: new Date().toISOString(),
              };
              await appendStep(run_id, missStep);
              yield { event: 'step', data: missStep as any };
              yield {
                event: 'user_message',
                data: { text: missMsg, language: userLang },
              };
              pipelineStatus = 'awaiting_user_input';
              break;
            }
          }
        }
      }

      // After DISCOVERY: deterministically filter candidates by availability
      // at the requested time. This is the safety net — discovery and ranking
      // agents sometimes skip their availability tool calls (and even
      // hallucinate candidates), so we ALWAYS hard-filter here before
      // ranking sees the list. Guarantees the picker only ever surfaces
      // providers who can actually take the booking at the requested time.
      if (agentName === 'discovery') {
        const requestedIso = (state.intent as any)?.time?.iso ??
                             (state.intent as any)?.booking?.occurrence?.iso ??
                             null;
        if (requestedIso) {
          const disc = state.discovery as any;
          const cands = (disc?.candidates ?? []) as any[];
          if (cands.length > 0) {
            const { loadProviders } = await import('./data.js');
            const { isAvailable } = await import('./tools/index.js');
            const allProviders = loadProviders();
            const beforeCount = cands.length;
            const filtered = cands.filter((c: any) => {
              const real = allProviders.find((p) => p.id === c.id || p.id === c.provider_id);
              // If we can't find the provider in our seed data (e.g. the
              // agent hallucinated it), drop it — never expose phantom
              // providers to the picker.
              if (!real) {
                console.warn(`[pipeline] dropping unknown provider from discovery: ${c.id ?? c.provider_id}`);
                return false;
              }
              // Provider explicitly toggled themselves OFF — skip even
              // when their weekly hours cover the requested time.
              if (real.available_now === false) {
                console.log(`[pipeline] dropping offline provider ${real.id}`);
                return false;
              }
              const ok = isAvailable(real, requestedIso);
              if (!ok) {
                console.log(`[pipeline] dropping unavailable provider ${real.id} for time ${requestedIso}`);
              }
              return ok;
            });
            disc.candidates = filtered;
            console.log(`[pipeline] availability-filtered candidates: ${beforeCount} → ${filtered.length} for ${requestedIso}`);

            // ALL filtered out → no providers available at the requested
            // time. Stop the pipeline cleanly with a friendly message
            // instead of letting ranking surface a half-broken picker.
            if (filtered.length === 0) {
              const userLang = (state.user_language as string | null) ?? 'en';
              const noAvailMsg = userLang === 'ur'
                ? 'افسوس — اس وقت کوئی سروس فراہم کنندہ دستیاب نہیں۔ کوئی اور وقت آزمائیں؟'
                : userLang === 'roman_ur'
                  ? 'Sorry — is waqt koi provider available nahi. Koi aur time try karein?'
                  : "Sorry — no providers are available at that time. Try a different time?";
              const step: TraceStep = {
                agent: 'discovery',
                reasoning: `Availability filter removed all candidates for ${requestedIso}.`,
                tools_called: result.tool_calls,
                output: { ...disc, candidates: [], no_availability: true },
                ms: Date.now() - stepT0,
                ts: new Date().toISOString(),
              };
              await appendStep(run_id, step);
              yield { event: 'step', data: step as any };
              yield {
                event: 'user_message',
                data: { text: noAvailMsg, language: userLang },
              };
              pipelineStatus = 'awaiting_user_input';
              break;
            }
          }
        }
      }

      // After INTENT: if the agent says it needs clarification, ask the user
      // and stop the pipeline. The user replies → app sends a follow-up that
      // includes the prior context.
      if (agentName === 'intent') {
        const intentOut = result.output as any;
        if (intentOut?.needs_clarification) {
          const step: TraceStep = {
            agent: 'intent',
            reasoning:
              intentOut.question ??
              'Need more info from the user before booking.',
            tools_called: result.tool_calls,
            output: result.output,
            ms: Date.now() - stepT0,
            ts: new Date().toISOString(),
          };
          await appendStep(run_id, step);
          yield { event: 'step', data: step as any };

          yield {
            event: 'user_message',
            data: {
              text:
                intentOut.question ??
                'Could you tell me where and when you need this service?',
              language: intentOut.language ?? 'en',
              missing: intentOut.missing ?? [],
            },
          };
          pipelineStatus = 'awaiting_user_input';
          break;
        }
      }

      // After RANKING: in normal flow, ALWAYS show the user 3 options and let
      // them pick. Only auto-book when the user has already picked (isLocked).
      // This avoids "AI confirmed me with a provider who hasn't actually agreed".
      if (agentName === 'ranking' && !isLocked) {
        const r = result.output as any;
        const top: any[] = r?.top_3 ?? r?.recommendations ?? [];
        // Empty case — no providers at all
        if (Array.isArray(top) && top.length === 0) {
          const step: TraceStep = {
            agent: 'ranking',
            reasoning: r?.reasoning ?? 'No providers matched the requested time/location.',
            tools_called: result.tool_calls,
            output: result.output,
            ms: Date.now() - stepT0,
            ts: new Date().toISOString(),
          };
          await appendStep(run_id, step);
          yield { event: 'step', data: step as any };

          const userLang = (state.user_language as string | null) ?? 'en';
          const msg = userLang === 'ur'
            ? 'اس وقت یا علاقے میں کوئی پرووائڈر دستیاب نہیں ہے۔ کیا کوئی اور وقت یا قریبی علاقہ آزما سکتے ہیں؟'
            : userLang === 'roman_ur'
              ? 'Is waqt ya area mein koi provider available nahin hai. Koi aur time ya nazdeek area try karein?'
              : 'No providers are available at that time or location. Could you try a different time or a nearby area?';
          yield {
            event: 'user_message',
            data: { text: msg, language: userLang },
          };
          pipelineStatus = 'awaiting_user_input';
          break;
        }

        // Non-empty top_3 → show picker, wait for user choice
        const step: TraceStep = {
          agent: 'ranking',
          reasoning: r?.reasoning ?? r?.auto_pick_rationale ?? `Found ${top.length} candidates — surfacing top ${Math.min(3, top.length)} to user.`,
          tools_called: result.tool_calls,
          output: result.output,
          ms: Date.now() - stepT0,
          ts: new Date().toISOString(),
        };
        await appendStep(run_id, step);
        yield { event: 'step', data: step as any };

        // Enrich top_3 with provider details. Pull from discovery output first
        // (which carries the LLM's runtime view), then fall back to the
        // provider database directly so we always have a real `name` field.
        const candidates = (state.discovery as any)?.candidates ?? [];
        const allProviders = loadProviders();
        const intentObj = state.intent as any;
        const intentTimeIso = intentObj?.time?.iso ?? intentObj?.booking?.occurrence?.iso ?? null;

        const alternatives = top.slice(0, 3).map((t: any) => {
          const fromDiscovery = candidates.find((cand: any) => cand.id === t.provider_id);
          const fromDb = allProviders.find((p: any) => p.id === t.provider_id);
          const c: any = fromDiscovery ?? fromDb ?? {};
          return {
            provider_id: t.provider_id,
            provider_name: c.name ?? fromDb?.name ?? t.provider_id,
            rating: c.rating ?? fromDb?.rating ?? null,
            review_count: c.review_count ?? fromDb?.review_count ?? null,
            distance_km: c.distance_km ?? null,
            price_range_pkr: c.price_range_pkr ?? fromDb?.price_range_pkr ?? null,
            neighborhood: c.neighborhood ?? fromDb?.neighborhood ?? null,
            verified: c.verified ?? fromDb?.verified ?? false,
            iso: intentTimeIso,
            reasoning: t.reasoning ?? '',
            tradeoffs: t.tradeoffs ?? '',
            score: t.score ?? null,
          };
        });

        const userLang = (state.user_language as string | null) ?? intentObj?.language ?? 'en';
        const headerMsg = userLang === 'ur'
          ? 'یہ ہیں آپ کے لیے ٹاپ آپشنز — کسی کو منتخب کریں:'
          : userLang === 'roman_ur'
            ? 'Yeh hain aap ke liye top options — koi select karein:'
            : 'Here are the top options — pick one to confirm:';

        yield {
          event: 'user_message',
          data: {
            text: headerMsg,
            language: userLang,
            alternatives,
            mode: 'show_options',
          },
        };
        pipelineStatus = 'awaiting_user_input';
        break;
      }

      // Capture booking_id for the final result event
      if (agentName === 'booking') {
        const b = result.output as any;

        // Anti-hallucination guard: the agent sometimes emits a fake
        // booking_id (e.g. "bk_12345") without actually calling
        // create_booking. We don't want to bother the user about it — the
        // orchestrator SELF-HEALS by calling create_booking directly with
        // the state we already have (locked provider, time, intent).
        if (b?.booking_id && (b.status === 'requested' || b.status === 'confirmed')) {
          const { getBookingFromStore } = await import('./store.js');
          const real = await getBookingFromStore(b.booking_id);
          if (!real) {
            console.warn(
              `[pipeline] BOOKING HALLUCINATED — agent faked ${b.booking_id}. Self-healing via direct create_booking call.`
            );
            try {
              const { executeTool } = await import('./tools/index.js');
              const intent = state.intent as any;
              const ranking = state.ranking as any;
              const providerId =
                (state.user_locked_provider_id as string | null) ??
                ranking?.top_3?.[0]?.provider_id ??
                null;
              const timeIso =
                (state.user_locked_time_iso as string | null) ??
                intent?.time?.iso ??
                intent?.booking?.occurrence?.iso ??
                null;
              if (!providerId || !timeIso) {
                throw new Error(`missing booking inputs (provider=${providerId} time=${timeIso})`);
              }
              const created = (await executeTool(
                'create_booking',
                {
                  user_id: input.user_id,
                  provider_id: providerId,
                  service_category_id:
                    intent?.service?.category_id ?? intent?.service?.free_text ?? 'unknown',
                  time_iso: timeIso,
                  location: intent?.location ?? { use_user_default: true },
                  language: (state.user_language as string | null) ?? intent?.language ?? 'en',
                  estimated_price_pkr: intent?.service?.estimated_price_pkr ?? [1000, 5000],
                  notes: '',
                },
                { runId: run_id }
              )) as any;
              if (created?.booking_id) {
                b.booking_id = created.booking_id;
                b.status = created.status ?? 'requested';
                b.message_to_user = null;
                b.shifted_from_requested = false;
                console.log(`[pipeline] self-heal OK → real booking_id=${created.booking_id}`);
              } else {
                throw new Error('create_booking returned no booking_id');
              }
            } catch (selfHealErr: any) {
              console.error(`[pipeline] self-heal failed: ${selfHealErr?.message ?? selfHealErr}`);
              b.status = 'failed';
              b.booking_id = null;
              b.message_to_user =
                (state.user_language === 'ur'
                  ? 'بکنگ مکمل نہیں ہو سکی۔ دوبارہ کوشش کریں۔'
                  : state.user_language === 'roman_ur'
                    ? 'Booking complete nahi ho saki. Dobara try karein.'
                    : 'Could not complete the booking. Please try again.');
            }
          }
        }

        if (b?.booking_id) lastBookingId = b.booking_id;
        if (b?.status && b.status !== 'confirmed' && b.status !== 'requested') {
          console.warn(`[pipeline] booking returned status=${b.status}`);
        }
        // If booking failed, surface the agent's message to the user and stop
        // — do NOT run the followup (which would schedule reminders for a
        // booking that never happened).
        if (b?.status === 'failed') {
          const step: TraceStep = {
            agent: 'booking',
            reasoning: b?.reasoning ?? 'Booking failed.',
            tools_called: result.tool_calls,
            output: result.output,
            ms: Date.now() - stepT0,
            ts: new Date().toISOString(),
          };
          await appendStep(run_id, step);
          yield { event: 'step', data: step as any };
          const userLang = (state.user_language as string | null) ?? 'en';
          const fallbackMsg = userLang === 'ur'
            ? 'یہ بکنگ نہیں ہو سکی۔ کوئی اور پرووائڈر یا وقت آزمائیں۔'
            : userLang === 'roman_ur'
              ? 'Yeh booking nahi ho saki. Koi aur provider ya time try karein.'
              : 'This booking could not be completed. Try another provider or time.';
          yield {
            event: 'user_message',
            data: {
              text: b?.message_to_user ?? fallbackMsg,
              language: userLang,
            },
          };
          pipelineStatus = 'failed';
          break;
        }
      }

      const step: TraceStep = {
        agent: agentName,
        reasoning: result.reasoning,
        tools_called: result.tool_calls,
        output: result.output,
        ms: Date.now() - stepT0,
        ts: new Date().toISOString(),
      };
      await appendStep(run_id, step);
      yield { event: 'step', data: step as any };

      // After BOOKING: if the agent needs the user to pick from alternatives,
      // surface that to the user as a chat message and stop the pipeline.
      if (agentName === 'booking') {
        const b = result.output as any;
        if (b?.status === 'needs_user_choice') {
          const alternativesText =
            (b.alternatives as Array<any> | undefined)
              ?.map((a) => '• ' + (a.label ?? a.iso))
              .join('\n') ?? '';
          yield {
            event: 'user_message',
            data: {
              text:
                b.message_to_user ??
                'The provider isn\'t free at that time. Pick one of these:\n' +
                  alternativesText,
              language: b.language ?? 'en',
              alternatives: b.alternatives ?? [],
            },
          };
          pipelineStatus = 'awaiting_user_input';
          break;
        }
      }

      // Early-exit if a stage produced an obviously broken output
      const raw = (result.output as any)?._raw_text;
      if (raw !== undefined && Object.keys(result.output as any).length === 1) {
        console.error(`[pipeline] ${agentName} returned empty output, aborting`);
        pipelineStatus = 'aborted';
        break;
      }
    }
  } catch (err: any) {
    console.error('[pipeline] failed:', err?.message ?? err);
    pipelineStatus = 'failed';
    yield {
      event: 'error',
      data: { run_id, error: err?.message ?? String(err) },
    };
  }

  await endTrace({
    run_id,
    result: { booking_id: lastBookingId, status: pipelineStatus },
  });

  yield {
    event: 'run_complete',
    data: {
      run_id,
      booking_id: lastBookingId,
      status: pipelineStatus,
      total_ms: Date.now() - t0,
    },
  };

  // ── Fire-and-forget follow-up scheduling ──────────────────────────────
  // Only fire when a booking actually succeeded. Runs AFTER run_complete is
  // sent so the customer sees their booking card immediately. Errors are
  // swallowed — reminders are non-critical.
  if (lastBookingId && pipelineStatus === 'complete') {
    (async () => {
      try {
        const t0 = Date.now();
        const result = await runAgent('followup', {
          user_id: input.user_id,
          user_input: input.user_input,
          intent: state.intent,
          booking: state.booking,
        }, { runId: run_id });
        const step: TraceStep = {
          agent: 'followup',
          reasoning: result.reasoning,
          tools_called: result.tool_calls,
          output: result.output,
          ms: Date.now() - t0,
          ts: new Date().toISOString(),
        };
        await appendStep(run_id, step);
        console.log(`[pipeline] async followup completed in ${Date.now() - t0}ms`);
      } catch (e: any) {
        console.warn('[pipeline] async followup failed (ignored):', e?.message ?? e);
      }
    })();
  }
}

/**
 * Trim down what each agent sees of the global state — they only need the
 * outputs of prior pipeline stages, not the whole accumulated blob (which
 * can become large and slow down Gemini calls).
 */
function compactState(
  state: Record<string, unknown>,
  forAgent: AgentName
): Record<string, unknown> {
  const base = {
    user_id: state.user_id,
    user_input: state.user_input,
    user_language: state.user_language,
  };
  switch (forAgent) {
    case 'intent':
      return base;
    case 'discovery':
      return { ...base, intent: state.intent };
    case 'ranking':
      return {
        ...base,
        intent: state.intent,
        discovery: summarizeDiscovery(state.discovery),
      };
    case 'booking':
      return {
        ...base,
        intent: state.intent,
        recommendation: pickTopRanked(state.ranking),
        top_3: pickTop3Ranked(state.ranking),
        // When the user explicitly picked a provider in the prior turn, the
        // booking agent must honor that choice exactly — no shifting time,
        // no swapping to a different provider.
        user_locked_provider_id: state.user_locked_provider_id ?? null,
        user_locked_time_iso: state.user_locked_time_iso ?? null,
      };
    case 'followup':
      return {
        ...base,
        intent: state.intent,
        booking: state.booking,
      };
    default:
      return state;
  }
}

function summarizeDiscovery(d: any): any {
  if (!d?.candidates) return d;
  // Keep just the fields ranking needs — drop the giant nested fields.
  // Cap to top 8 by distance to keep the ranking prompt small + fast.
  // Ranking only ever surfaces 3, so 8 gives the model room to discard 5
  // while keeping the prompt 2-3× smaller than the full set.
  const trimmed = d.candidates
    .slice()
    .sort((a: any, b: any) => (a.distance_km ?? 99) - (b.distance_km ?? 99))
    .slice(0, 8);
  return {
    ...d,
    candidates: trimmed.map((c: any) => ({
      id: c.id,
      name: c.name,
      category: c.category,
      specializations: c.specializations,
      neighborhood: c.neighborhood,
      rating: c.rating,
      review_count: c.review_count,
      jobs_completed: c.jobs_completed,
      years_experience: c.years_experience,
      languages: c.languages,
      price_range_pkr: c.price_range_pkr,
      verified: c.verified,
      tags: c.tags,
      distance_km: c.distance_km,
      availability_at_request: c.availability_at_request,
    })),
  };
}

function pickTopRanked(r: any): any {
  if (!r?.top_3 || r.top_3.length === 0) return null;
  return r.top_3[0];
}

function pickTop3Ranked(r: any): any[] {
  return (r?.top_3 ?? []).slice(0, 3);
}
