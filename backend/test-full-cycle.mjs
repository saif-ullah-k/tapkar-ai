import WebSocket from 'ws';
const ws = new WebSocket('wss://tapkar-ai-backend-d56rhra4sa-uc.a.run.app/voice/live');
const t0 = Date.now();
const t = () => ((Date.now() - t0) / 1000).toFixed(1);
let audioBytes = 0;
let phase = 'pre-greeting';
let phaseChunks = { 'pre-greeting': 0, 'post-tool': 0 };
let toolResultAt = null;

ws.on('open', () => {
  console.log(`[+${t()}s] OPEN`);
  ws.send(JSON.stringify({ type: 'auth', user_id: 'fctest', user_name: 'Keith', language: 'roman_ur', user_gender: 'male' }));
});

ws.on('message', (raw) => {
  let f; try { f = JSON.parse(raw.toString()); } catch { return; }
  if (f.type === 'audio') {
    const bytes = Buffer.from(f.audio, 'base64').length;
    audioBytes += bytes;
    phaseChunks[phase]++;
    return;
  }
  console.log(`[+${t()}s] <- ${f.type}${f.state ? ' ['+f.state+']' : ''}${f.text ? ': ' + f.text.slice(0,80) : ''}`);
  if (f.type === 'tool_call') {
    console.log(`[+${t()}s]   args=${JSON.stringify(f.tool?.args).slice(0,80)}`);
  }
  if (f.type === 'tool_result') {
    toolResultAt = t();
    phase = 'post-tool';
    console.log(`[+${t()}s]   TOOL RESULT: ${JSON.stringify(f.step).slice(0,200)}`);
  }
  if (f.type === 'turn_complete') {
    console.log(`[+${t()}s]   phase=${phase} audio so far=${phaseChunks[phase]} chunks`);
    // After greeting turn completes, send the booking request
    if (toolResultAt === null && phase === 'pre-greeting') {
      console.log(`[+${t()}s] -> sending booking request`);
      ws.send(JSON.stringify({ type: 'text', text: 'Mujhe kal subah 9 baje Gulshan-e-Iqbal Block 13 mein plumber chahiye, paani leak hai, book kar do.' }));
    } else if (toolResultAt !== null) {
      // After post-tool turn completes, close
      setTimeout(() => ws.close(), 800);
    }
  }
});

ws.on('close', () => {
  console.log(`\n=== SUMMARY ===`);
  console.log(`Total audio: ${audioBytes} bytes`);
  console.log(`Pre-greeting (incl. greeting): ${phaseChunks['pre-greeting']} chunks`);
  console.log(`Post-tool (narration): ${phaseChunks['post-tool']} chunks ${phaseChunks['post-tool'] === 0 ? '<-- BUG' : '<-- OK'}`);
  console.log(`Tool result at: ${toolResultAt || 'never'} s`);
  process.exit(0);
});
setTimeout(() => { console.log('TIMEOUT 120s'); ws.close(); process.exit(1); }, 120000);
