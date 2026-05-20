import WebSocket from 'ws';
const ws = new WebSocket('wss://tapkar-ai-backend-d56rhra4sa-uc.a.run.app/voice/live');
let audioBytes = 0;
let firstAudioAt = null;
const start = Date.now();
const t = () => ((Date.now() - start) / 1000).toFixed(1);
ws.on('open', () => {
  console.log(`[+${t()}s] socket open — sending auth with name=Keith`);
  ws.send(JSON.stringify({ type: 'auth', user_id: 'tester', user_name: 'Keith', language: 'roman_ur', user_gender: 'male' }));
});
ws.on('message', (raw) => {
  let f; try { f = JSON.parse(raw.toString()); } catch { return; }
  if (f.type === 'audio') {
    audioBytes += Buffer.from(f.audio, 'base64').length;
    if (firstAudioAt === null) { firstAudioAt = t(); console.log(`[+${firstAudioAt}s] FIRST AUDIO (greeting?)`); }
    return;
  }
  console.log(`[+${t()}s] <- ${f.type}${f.state?' ['+f.state+']':''}${f.text?': '+f.text.slice(0,60):''}`);
  if (f.type === 'turn_complete') {
    setTimeout(() => { console.log(`\n=== Greeting played ${audioBytes} audio bytes, first chunk at +${firstAudioAt}s ===`); ws.close(); process.exit(0); }, 800);
  }
});
setTimeout(() => { console.log('TIMEOUT'); ws.close(); process.exit(1); }, 30000);
