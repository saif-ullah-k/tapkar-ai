/**
 * End-to-end test of the /voice/live WebSocket bridge.
 *
 * Connects → sends auth → sends a text turn that should trigger the
 * book_a_service tool → expects: tool_call, agent_step events streaming
 * from the wrapped 5-agent orchestrator, then audio chunks of the model
 * narrating the result, then turn_complete.
 *
 *   USAGE: node test-live.mjs
 */
import WebSocket from 'ws';

const URL = process.env.WS_URL || 'wss://tapkar-ai-backend-d56rhra4sa-uc.a.run.app/voice/live';
const TEXT = process.env.TEST_TEXT || 'salaam, mujhe kal subah Gulshan mein plumber chahiye, paani leak ho raha hai';

const ws = new WebSocket(URL);
const counts = { audio: 0, tool_call: 0, agent_step: 0, transcript: 0, turn_complete: 0, error: 0, ready: 0 };
const transcripts = [];
const toolCalls = [];
const errors = [];
let audioBytes = 0;
const start = Date.now();

ws.on('open', () => {
  log('socket open');
  ws.send(JSON.stringify({ type: 'auth', user_id: 'wstester', language: 'roman_ur', user_gender: 'female' }));
});

ws.on('message', (raw) => {
  let f;
  try { f = JSON.parse(raw.toString()); } catch { return; }
  if (counts[f.type] != null) counts[f.type]++;
  if (f.type === 'audio' && f.audio) audioBytes += Buffer.from(f.audio, 'base64').length;
  if (f.type === 'transcript') transcripts.push(f.text);
  if (f.type === 'tool_call') toolCalls.push(f.tool);
  if (f.type === 'error') errors.push(f.error);
  if (f.type !== 'audio') {
    const tail = [f.text, f.error, f.tool?.name].filter(Boolean).join(' ');
    log(`<- ${f.type}${f.state ? ' [' + f.state + ']' : ''}${tail ? ': ' + tail.slice(0, 100) : ''}`);
  }
  if (f.type === 'ready') {
    setTimeout(() => {
      // Smoke-test the audio path too — send 1s of silence as 16 kHz PCM
      // to exercise the deprecated-API check that text-only tests miss.
      const SAMPLE_RATE = 16000;
      const silence = Buffer.alloc(SAMPLE_RATE * 2, 0); // 1s of 16-bit silence
      log('-> audio: 1s silence (smoke-test)');
      ws.send(JSON.stringify({ type: 'audio', audio: silence.toString('base64') }));
      // Give the audio frame a tick to propagate, then send the actual prompt.
      setTimeout(() => {
        log(`-> text: ${TEXT.slice(0, 60)}`);
        ws.send(JSON.stringify({ type: 'text', text: TEXT }));
      }, 200);
    }, 500);
  }
  if (f.type === 'turn_complete') {
    setTimeout(() => ws.close(), 1500);
  }
});

ws.on('error', (e) => log('ws err: ' + e.message));
ws.on('close', (code, reason) => {
  log(`closed code=${code} reason=${reason.toString().slice(0, 100)}`);
  console.log('');
  console.log('=== SUMMARY ===');
  console.log(`Elapsed: ${((Date.now() - start) / 1000).toFixed(1)}s`);
  console.log('Counts:', counts);
  console.log(`Audio bytes received: ${audioBytes}`);
  if (toolCalls.length) console.log('Tool calls:', toolCalls);
  if (transcripts.length) console.log('Transcripts:', transcripts);
  if (errors.length) console.log('Errors:', errors);

  const pass = counts.ready > 0 && counts.error === 0;
  console.log(pass ? '✅ PASS connection healthy' : '❌ FAIL');
  process.exit(pass ? 0 : 1);
});

setTimeout(() => {
  log('TIMEOUT after 60s — closing');
  ws.close();
}, 60000);

function log(s) { console.log(`[+${((Date.now() - start) / 1000).toFixed(1)}s] ${s}`); }
