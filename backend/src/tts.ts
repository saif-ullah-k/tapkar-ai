/**
 * Text-to-Speech wrapper. Two engines in priority order:
 *
 *   1. Gemini native speech generation (PRIMARY) — same voice roster as
 *      Chirp3-HD but supports prompt-driven STYLE control ("Say warmly,
 *      naturally, like a real human assistant: …"). That style prefix is
 *      what makes the output sound conversational instead of robotic. The
 *      Cloud TTS Chirp3-HD API ignores style hints — it can only render
 *      plain SSML.
 *
 *   2. Cloud TTS Chirp3-HD (FALLBACK) — same voice timbre but no style
 *      control. Used when Gemini TTS preview model returns a 500 (which
 *      happens occasionally per Google's own docs).
 *
 * Output: Gemini returns raw PCM 24 kHz 16-bit mono — we wrap it in a WAV
 * header so the mobile audioplayers package can play it directly. Cloud
 * TTS returns MP3 bytes.
 *
 * Auth on Cloud Run: ADC via the runtime service account; needs the Cloud
 * Text-to-Speech API enabled. Locally: `gcloud auth application-default
 * login` or set GOOGLE_APPLICATION_CREDENTIALS.
 */

import { TextToSpeechClient } from '@google-cloud/text-to-speech';
import { GoogleGenAI } from '@google/genai';
import { config } from './config.js';

type Lang = 'en' | 'ur' | 'roman_ur';
type Gender = 'female' | 'male';

// ─── Gemini TTS ──────────────────────────────────────────────────────────────

// Gender-keyed Gemini voice picks. Aoede / Leda are warm female; Puck and
// Charon are male — same Chirp3 roster.
const GEMINI_VOICE_BY_GENDER: Record<Gender, string> = {
  female: 'Aoede',
  male: 'Puck',
};

// Per-language style preamble. The model treats this as instruction to the
// reader ("speak like this"), not as part of the spoken output.
function styleDirective(lang: Lang): string {
  switch (lang) {
    case 'ur':
      return 'Pakistani Urdu mein dheere, garmjoshi se, aur insan ki tarah aaram se boliye, jaise aap kisi achay dost ki madad kar rahe ho:';
    case 'roman_ur':
      return 'Roman Urdu mein dheere, naturally, warm aur friendly tone mein boliye, jaise aap ek real assistant ho, robot nahi:';
    case 'en':
    default:
      return 'Speak naturally and warmly, like a real human friend helping out — relaxed pace, with feeling, not robotic at all:';
  }
}

let _geminiClient: GoogleGenAI | null = null;
function getGeminiClient(): GoogleGenAI {
  if (_geminiClient) return _geminiClient;
  if (config.gemini.useVertex && config.gcp.projectId) {
    _geminiClient = new GoogleGenAI({
      vertexai: true,
      project: config.gcp.projectId,
      location: config.gcp.location,
    });
  } else if (config.gemini.apiKey) {
    _geminiClient = new GoogleGenAI({ apiKey: config.gemini.apiKey });
  } else {
    throw new Error('gemini_auth_missing');
  }
  return _geminiClient;
}

const GEMINI_TTS_MODELS = [
  'gemini-2.5-flash-preview-tts',
  'gemini-2.5-pro-preview-tts',
];

/** Wrap raw 24 kHz / 16-bit / mono PCM in a minimal WAV header so any audio
 *  player can decode it. 44 bytes prepended to the sample data. */
function pcmToWav(pcm: Buffer, sampleRate = 24000, channels = 1, bitsPerSample = 16): Buffer {
  const byteRate = sampleRate * channels * (bitsPerSample / 8);
  const blockAlign = channels * (bitsPerSample / 8);
  const header = Buffer.alloc(44);
  header.write('RIFF', 0);
  header.writeUInt32LE(36 + pcm.length, 4);
  header.write('WAVE', 8);
  header.write('fmt ', 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20); // PCM
  header.writeUInt16LE(channels, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(byteRate, 28);
  header.writeUInt16LE(blockAlign, 32);
  header.writeUInt16LE(bitsPerSample, 34);
  header.write('data', 36);
  header.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([header, pcm]);
}

async function synthesizeGemini(text: string, lang: Lang, gender: Gender): Promise<{ audio: Buffer; voice: string }> {
  const prompt = `${styleDirective(lang)} ${text}`;
  const voice = GEMINI_VOICE_BY_GENDER[gender];
  let lastErr: unknown = null;
  for (const model of GEMINI_TTS_MODELS) {
    try {
      const response = await getGeminiClient().models.generateContent({
        model,
        contents: [{ role: 'user', parts: [{ text: prompt }] }],
        config: {
          responseModalities: ['AUDIO'] as any,
          speechConfig: {
            voiceConfig: {
              prebuiltVoiceConfig: { voiceName: voice },
            },
          },
        } as any,
      });
      const parts = response.candidates?.[0]?.content?.parts ?? [];
      const audioPart = parts.find((p: any) => p.inlineData?.mimeType?.startsWith('audio/'));
      const b64 = (audioPart as any)?.inlineData?.data;
      if (!b64) throw new Error('gemini_tts_no_audio');
      const pcm = Buffer.from(b64, 'base64');
      console.log(`[tts] engine=gemini model=${model} voice=${voice} gender=${gender} chars=${text.length} pcm_bytes=${pcm.length}`);
      return { audio: pcmToWav(pcm), voice };
    } catch (err: any) {
      lastErr = err;
      console.warn(`[tts] gemini model=${model} failed: ${err?.message ?? err}`);
    }
  }
  throw lastErr ?? new Error('gemini_tts_all_models_failed');
}

// ─── Cloud TTS fallback (Chirp3-HD) ─────────────────────────────────────────

interface VoiceConfig {
  languageCode: string;
  speakingRate: number;
  pitch: number;
}

const VOICE_PROSODY: Record<Lang, VoiceConfig> = {
  en: { languageCode: 'en-US', speakingRate: 1.0, pitch: 0 },
  ur: { languageCode: 'ur-PK', speakingRate: 0.92, pitch: 0 },
  roman_ur: { languageCode: 'en-IN', speakingRate: 0.95, pitch: 0 },
};

// Per-language voice fallback chain, keyed by gender. Female: Aoede/Kore/A
// (warm). Male: Puck/Charon/B. Wavenet/Standard suffixes "A" / "B" =
// female / male in Google's voice catalogue convention.
const FALLBACKS_BY_GENDER: Record<Gender, Record<Lang, string[]>> = {
  female: {
    en: [
      'en-US-Chirp3-HD-Aoede',
      'en-US-Chirp3-HD-Kore',
      'en-US-Chirp3-HD-Achernar',
      'en-US-Neural2-F',
      'en-US-Wavenet-F',
      'en-US-Standard-F',
    ],
    ur: ['ur-PK-Wavenet-A', 'ur-PK-Standard-A'],
    roman_ur: [
      'en-IN-Chirp3-HD-Aoede',
      'en-IN-Chirp3-HD-Kore',
      'en-IN-Chirp3-HD-Achernar',
      'en-IN-Wavenet-A',
      'en-IN-Standard-A',
    ],
  },
  male: {
    en: [
      'en-US-Chirp3-HD-Puck',
      'en-US-Chirp3-HD-Charon',
      'en-US-Chirp3-HD-Fenrir',
      'en-US-Neural2-D',
      'en-US-Wavenet-D',
      'en-US-Standard-D',
    ],
    ur: ['ur-PK-Wavenet-B', 'ur-PK-Standard-B'],
    roman_ur: [
      'en-IN-Chirp3-HD-Puck',
      'en-IN-Chirp3-HD-Charon',
      'en-IN-Chirp3-HD-Fenrir',
      'en-IN-Wavenet-B',
      'en-IN-Standard-B',
    ],
  },
};

let _ttsClient: TextToSpeechClient | null = null;
function getTtsClient(): TextToSpeechClient {
  if (!_ttsClient) _ttsClient = new TextToSpeechClient();
  return _ttsClient;
}

async function synthesizeCloudTts(
  text: string,
  lang: Lang,
  gender: Gender,
): Promise<{ audio: Buffer; voiceUsed: string }> {
  const cfg = VOICE_PROSODY[lang];
  let lastErr: unknown = null;
  const candidates = FALLBACKS_BY_GENDER[gender][lang];
  for (const voiceName of candidates) {
    try {
      const isChirp3 = voiceName.includes('Chirp3');
      const [response] = await getTtsClient().synthesizeSpeech({
        input: { text },
        voice: { languageCode: cfg.languageCode, name: voiceName },
        audioConfig: {
          audioEncoding: 'MP3',
          speakingRate: cfg.speakingRate,
          ...(isChirp3 ? {} : { pitch: cfg.pitch, effectsProfileId: ['handset-class-device'] }),
        },
      });
      if (!response.audioContent) throw new Error('tts_empty_audio');
      console.log(`[tts] engine=cloud voice=${voiceName} chars=${text.length}`);
      return { audio: Buffer.from(response.audioContent as Uint8Array), voiceUsed: voiceName };
    } catch (err: any) {
      lastErr = err;
      console.warn(`[tts] cloud voice "${voiceName}" failed: ${err?.message ?? err}`);
    }
  }
  throw lastErr ?? new Error('cloud_tts_all_voices_failed');
}

// ─── Public API ──────────────────────────────────────────────────────────────

function normalizeLang(input?: string): Lang {
  if (input === 'ur' || input === 'roman_ur') return input;
  return 'en';
}

function normalizeGender(input?: string): Gender {
  if (input === 'male') return 'male';
  return 'female';
}

export interface SynthResult {
  audio: Buffer;
  voiceUsed: string;
  engine: 'gemini' | 'cloud';
  mime: 'audio/wav' | 'audio/mpeg';
}

export async function synthesize(text: string, langInput?: string, genderInput?: string): Promise<SynthResult> {
  const lang = normalizeLang(langInput);
  const gender = normalizeGender(genderInput);
  // Cloud TTS Chirp3-HD returns in ~3 s (vs Gemini preview's ~12 s cold
  // start). Voices share the same roster so timbre is comparable; we lose
  // prompt-driven style control vs Gemini, which wasn't worth a 4× latency
  // hit for a live chat.
  try {
    const cloud = await synthesizeCloudTts(text, lang, gender);
    return { audio: cloud.audio, voiceUsed: cloud.voiceUsed, engine: 'cloud', mime: 'audio/mpeg' };
  } catch (err: any) {
    console.warn(`[tts] cloud tts failed, falling back to gemini: ${err?.message ?? err}`);
  }
  // Fallback: Gemini speech generation (with style preamble).
  const result = await synthesizeGemini(text, lang, gender);
  return { audio: result.audio, voiceUsed: `gemini:${result.voice}`, engine: 'gemini', mime: 'audio/wav' };
}
