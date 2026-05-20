/**
 * Gemini API wrapper.
 *
 * Single entry point: runAgent(name, state). Loads the .agent.md prompt,
 * binds the agent's tools as Gemini function declarations, runs the
 * function-calling loop until the agent produces a final output, returns
 * the structured output + collected tool-call trace.
 *
 * This is the ReAct primitive that orchestrator.ts composes.
 */

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { GoogleGenAI, Type, type FunctionDeclaration } from '@google/genai';
import { config, modelForAgent } from './config.js';
import { allToolsForAgent, executeTool } from './tools/index.js';
import type { AgentName, ToolCall } from './types.js';

let _client: GoogleGenAI | null = null;
function getClient(): GoogleGenAI {
  if (!_client) {
    if (config.gemini.useVertex) {
      if (!config.gcp.projectId) {
        throw new Error(
          'USE_VERTEX_AI=true but GCP_PROJECT is not set. Run `gcloud auth application-default login` and set GCP_PROJECT.'
        );
      }
      _client = new GoogleGenAI({
        vertexai: true,
        project: config.gcp.projectId,
        location: config.gcp.location,
      });
    } else {
      if (!config.gemini.apiKey) {
        throw new Error(
          'No auth configured. Set GEMINI_API_KEY (AI Studio) or USE_VERTEX_AI=true + GCP_PROJECT.'
        );
      }
      _client = new GoogleGenAI({ apiKey: config.gemini.apiKey });
    }
  }
  return _client;
}

// NO caching — prompts are read fresh on every call. Trivial perf cost
// (~1 KB file read) but means agent.md edits take effect immediately without
// a server restart. Critical for fast iteration.
function loadAgentPrompt(name: AgentName): string {
  const path = join(process.cwd(), 'src', 'agents', `${name}.agent.md`);
  const altPath = join(process.cwd(), 'backend', 'src', 'agents', `${name}.agent.md`);
  try {
    return readFileSync(path, 'utf-8');
  } catch {
    return readFileSync(altPath, 'utf-8');
  }
}

/**
 * Run one agent end-to-end. Returns its final structured output and the
 * full sequence of tool calls it made.
 */
export interface AgentResult {
  output: unknown;
  reasoning: string;
  tool_calls: ToolCall[];
  model: string;
  ms: number;
}

export async function runAgent(
  name: AgentName,
  state: Record<string, unknown>,
  opts: { context?: string; runId?: string } = {}
): Promise<AgentResult> {
  const t0 = Date.now();
  const client = getClient();
  const model = modelForAgent(name);
  const systemPrompt = loadAgentPrompt(name);
  const tools = allToolsForAgent(name);

  const functionDeclarations: FunctionDeclaration[] = tools.map((t) => ({
    name: t.name,
    description: t.description,
    parameters: t.parameters,
  }));

  // ReAct loop — model calls tools, we execute, feed back, repeat until it
  // produces text output (the structured JSON).
  const collectedCalls: ToolCall[] = [];
  const nowIso = new Date().toLocaleString('sv-SE', { timeZone: 'Asia/Karachi' }).replace(' ', 'T') + '+05:00';
  const todayPK = nowIso.slice(0, 10);
  // Compute day-of-week + tomorrow + day-after-tomorrow as PURE CALENDAR
  // dates (no UTC math). Treat YYYY-MM-DD as a calendar value the way
  // humans read it. The previous version used `new Date(iso)` which
  // converted to UTC and gave the wrong day of week.
  const dayNames = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
  const [py, pm, pd] = todayPK.split('-').map((s) => parseInt(s, 10));
  const calendarUtc = (y: number, m: number, d: number) => new Date(Date.UTC(y, m - 1, d));
  const todayCal = calendarUtc(py, pm, pd);
  const tomorrowCal = calendarUtc(py, pm, pd + 1);
  const parsoCal = calendarUtc(py, pm, pd + 2);
  const fmt = (d: Date) => d.toISOString().slice(0, 10);
  const todayDow = dayNames[todayCal.getUTCDay()];
  const tomorrowDow = dayNames[tomorrowCal.getUTCDay()];
  const parsoDow = dayNames[parsoCal.getUTCDay()];
  const tomorrowPK = fmt(tomorrowCal);
  const parsoPK = fmt(parsoCal);

  const contents: any[] = [
    {
      role: 'user',
      parts: [
        {
          text:
            `CURRENT TIME (Asia/Karachi): ${nowIso}\n` +
            `TODAY'S DATE: ${todayPK} (${todayDow})\n` +
            `"kal" / "tomorrow" = ${tomorrowPK} (${tomorrowDow})\n` +
            `"parsoo" / "day after tomorrow" = ${parsoPK} (${parsoDow})\n` +
            `Use these EXACT dates when resolving relative phrases. "kal" in a service-booking conversation is ALWAYS tomorrow (future), never yesterday.\n` +
            `Reject (ask clarification) any time that resolves to BEFORE this current time.\n\n` +
            (opts.context ? opts.context + '\n\n' : '') +
            `CURRENT STATE\n\`\`\`json\n${JSON.stringify(state, null, 2)}\n\`\`\`\n\n` +
            `Produce your output per the schema in your system prompt. ` +
            `Call tools as needed; emit your final structured output as JSON in your last message.`,
        },
      ],
    },
  ];

  const MAX_TOOL_ROUNDS = 4;
  let finalText = '';
  let reasoning = '';

  for (let round = 0; round < MAX_TOOL_ROUNDS; round++) {
    // On the LAST tool round, force JSON output natively — eliminates the
    // separate "coerce" call that was doubling our latency on every agent.
    // Gemini honors responseMimeType only when tools are NOT in this call.
    const isLastRound = round === MAX_TOOL_ROUNDS - 1;
    const hasToolsThisCall = functionDeclarations.length > 0 && !isLastRound;
    const response = await withRetry(() =>
      client.models.generateContent({
        model,
        contents,
        config: {
          systemInstruction: { parts: [{ text: systemPrompt }] },
          tools: hasToolsThisCall ? [{ functionDeclarations }] : undefined,
          temperature: 0.3,
          responseMimeType: hasToolsThisCall ? undefined : 'application/json',
        },
      })
    );

    const candidate = response.candidates?.[0];
    const parts = candidate?.content?.parts ?? [];
    const functionCalls = parts.filter((p: any) => p.functionCall).map((p: any) => p.functionCall);
    const textParts = parts.filter((p: any) => p.text).map((p: any) => p.text as string);

    if (textParts.length > 0) {
      const t = textParts.join('\n').trim();
      reasoning = t.length > 0 ? t : reasoning;
    }

    if (functionCalls.length === 0) {
      // Model is done OR returned nothing — extract JSON from final text.
      finalText = textParts.join('\n');
      break;
    }

    // Execute tool calls in parallel, append results to conversation
    const toolResponseParts: any[] = [];
    for (const fc of functionCalls) {
      const tc0 = Date.now();
      let toolOutput: unknown;
      try {
        toolOutput = await executeTool(fc.name, fc.args ?? {}, { runId: opts.runId });
      } catch (err: any) {
        toolOutput = { error: err.message ?? String(err) };
      }
      const tc: ToolCall = {
        name: fc.name,
        input: fc.args ?? {},
        output: toolOutput,
        ms: Date.now() - tc0,
        ts: new Date().toISOString(),
      };
      collectedCalls.push(tc);
      toolResponseParts.push({
        functionResponse: { name: fc.name, response: { result: toolOutput } },
      });
    }

    contents.push({ role: 'model', parts });
    contents.push({ role: 'user', parts: toolResponseParts });
  }

  // Coerce final JSON output: if the model used tools but never emitted text,
  // make ONE more call WITHOUT tools, forcing it to produce the structured JSON.
  // This is a known quirk of smaller models (flash-lite) after function calling.
  if (!finalText || !extractJson(finalText)) {
    console.log(`[gemini] ${name}: no JSON after ${collectedCalls.length} tool calls — coercing final output`);
    contents.push({
      role: 'user',
      parts: [
        {
          text: 'You have called the necessary tools. Now produce ONLY your final structured JSON output as specified in your system prompt. Do not call any more tools. Output the JSON in a ```json fenced block.',
        },
      ],
    });
    try {
      const coerced = await withRetry(() =>
        client.models.generateContent({
          model,
          contents,
          config: {
            systemInstruction: { parts: [{ text: systemPrompt }] },
            // NO TOOLS in this call — force pure JSON output
            temperature: 0.1,
            responseMimeType: 'application/json',
          },
        })
      );
      const ctext = coerced.candidates?.[0]?.content?.parts
        ?.filter((p: any) => p.text)
        .map((p: any) => p.text)
        .join('\n') ?? '';
      if (ctext) {
        finalText = ctext;
        reasoning = reasoning || ctext.slice(0, 300);
        console.log(`[gemini] ${name}: coerced output: "${ctext.slice(0, 80)}..."`);
      }
    } catch (e: any) {
      console.warn(`[gemini] ${name}: coercion failed:`, e?.message);
    }
  }

  const output = extractJson(finalText) ?? { _raw_text: finalText };
  return {
    output,
    reasoning: reasoning || extractReasoning(finalText) || '',
    tool_calls: collectedCalls,
    model,
    ms: Date.now() - t0,
  };
}

// ─── helpers ─────────────────────────────────────────────────────────────────

function extractJson(text: string): unknown | null {
  if (!text) return null;
  // Try fenced code block first
  const fence = text.match(/```(?:json)?\s*([\s\S]+?)```/);
  if (fence) {
    try {
      return JSON.parse(fence[1].trim());
    } catch {}
  }
  // Try first {...} block
  const brace = text.match(/\{[\s\S]*\}/);
  if (brace) {
    try {
      return JSON.parse(brace[0]);
    } catch {}
  }
  return null;
}

function extractReasoning(text: string): string {
  if (!text) return '';
  // Take prose lines that aren't part of a JSON block
  const before = text.split(/```|\{/)[0]?.trim();
  return before?.slice(0, 600) ?? '';
}

async function withRetry<T>(fn: () => Promise<T>, attempts = 5): Promise<T> {
  let lastErr: unknown;
  for (let i = 0; i < attempts; i++) {
    try {
      return await fn();
    } catch (err: any) {
      lastErr = err;
      const msg = String(err?.message ?? err);
      const isRateLimit = /429|RESOURCE_EXHAUSTED|RATE_LIMIT/i.test(msg);
      const isCapacity = /503|UNAVAILABLE|CAPACITY/i.test(msg);
      const isTransient = isRateLimit || isCapacity || /ECONN|timeout|ETIMED/i.test(msg);
      if (!isTransient || i === attempts - 1) {
        // Rewrite the error to be user-friendly before throwing.
        if (isRateLimit) {
          throw new Error(
            'rate_limited: Vertex AI is busy right now. Please wait ~30 seconds and try again.'
          );
        }
        if (isCapacity) {
          throw new Error(
            'service_unavailable: Vertex AI capacity is full. Try again in a minute.'
          );
        }
        throw err;
      }
      // Longer backoff for rate-limit (Vertex usually says retry-after 12-60s)
      const delay = isRateLimit ? 6000 * Math.pow(2, i) : 800 * Math.pow(2, i);
      console.warn(
        `[gemini] ${isRateLimit ? 'rate-limit' : 'transient'} error, ` +
          `attempt ${i + 1}/${attempts}, backing off ${delay}ms: ${msg.slice(0, 100)}`
      );
      await new Promise((r) => setTimeout(r, delay));
    }
  }
  throw lastErr;
}

// Re-export Type so tool definitions can import enum values
export { Type };
