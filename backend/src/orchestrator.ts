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
import type { AgentName, TraceStep } from './types.js';

export interface RunInput {
  user_id: string;
  user_input: string;
  conversation_id?: string;
}

export interface StreamEvent {
  event: 'run_started' | 'step' | 'user_message' | 'run_complete' | 'error';
  data: Record<string, unknown>;
}

const PIPELINE: AgentName[] = ['intent', 'discovery', 'ranking', 'booking', 'followup'];

export async function* runPipeline(input: RunInput): AsyncGenerator<StreamEvent> {
  console.log('[pipeline] starting deterministic agent sequence');
  const t0 = Date.now();
  const { run_id } = startTrace({
    user_id: input.user_id,
    user_input: input.user_input,
  });

  yield {
    event: 'run_started',
    data: { run_id, user_input: input.user_input, started_at: new Date().toISOString() },
  };

  const state: Record<string, unknown> = {
    user_id: input.user_id,
    user_input: input.user_input,
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

  try {
    for (const agentName of PIPELINE) {
      const stepT0 = Date.now();
      console.log(`[pipeline] dispatching ${agentName}...`);

      const result = await runAgent(agentName, compactState(state, agentName), {
        runId: run_id,
      });

      state[agentName] = result.output;

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

      // Capture booking_id for the final result event
      if (agentName === 'booking') {
        const b = result.output as any;
        if (b?.booking_id) lastBookingId = b.booking_id;
        if (b?.status && b.status !== 'confirmed') {
          console.warn(`[pipeline] booking returned status=${b.status}`);
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
  return {
    ...d,
    candidates: d.candidates.map((c: any) => ({
      id: c.id,
      name: c.name,
      category: c.category,
      specializations: c.specializations,
      neighborhood: c.neighborhood,
      lat: c.lat,
      lng: c.lng,
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
