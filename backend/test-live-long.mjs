import WebSocket from 'ws';
const URL = process.env.WS_URL || 'wss://tapkar-ai-backend-d56rhra4sa-uc.a.run.app/voice/live';
const TEXT = process.env.TEST_TEXT || 'Mujhe kal subah 9 baje Gulshan-e-Iqbal Block 13 mein plumber chahiye, paani leak hai, book kar do.';
const ws = new WebSocket(URL);
const counts = { audio: 0, tool_call: 0, agent_step: 0, transcript: 0, turn_complete: 0, error: 0, ready: 0, tool_result: 0 };
let toolResultSeen = false;
const start = Date.now();
ws.on('open', () => { console.log(`[+0s] open`); ws.send(JSON.stringify({ type: 'auth', user_id: 'wstester', language: 'roman_ur', user_gender: 'female' })); });
ws.on('message', (raw) => {
  let f; try { f = JSON.parse(raw.toString()); } catch { return; }
  if (counts[f.type] != null) counts[f.type]++;
  const elapsed = ((Date.now() - start) / 1000).toFixed(1);
  if (f.type === 'tool_result') {
    toolResultSeen = true;
    console.log(`[+${elapsed}s] <- tool_result keys=`, Object.keys(f.step || {}).join(','));
    console.log(`[+${elapsed}s]   status=${f.step?.status} booking_id=${f.step?.booking_id} auto_picked=${f.step?.auto_picked?.provider_name || 'no'}`);
  }
  if (f.type !== 'audio' && f.type !== 'agent_step') {
    console.log(`[+${elapsed}s] <- ${f.type}${f.state?' ['+f.state+']':''}${f.text?': '+f.text.slice(0,60):''}${f.error?': '+f.error:''}`);
  }
  if (f.type === 'ready') {
    setTimeout(() => { console.log(`[+${((Date.now()-start)/1000).toFixed(1)}s] -> text`); ws.send(JSON.stringify({ type: 'text', text: TEXT })); }, 500);
  }
  if (f.type === 'turn_complete') setTimeout(() => ws.close(), 1500);
});
ws.on('close', () => {
  console.log('\nCounts:', counts);
  console.log('tool_result_seen:', toolResultSeen);
  console.log('elapsed:', ((Date.now()-start)/1000).toFixed(1), 's');
  process.exit(0);
});
setTimeout(() => { console.log('TIMEOUT'); ws.close(); }, 150000);
