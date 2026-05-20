import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;
import 'api.dart';

/// Speaks bot messages back to the user using the backend's Gemini Speech
/// Generation endpoint (with Cloud TTS Chirp3-HD as automatic fallback).
///
/// Two-phase API so text+voice can land together in the UI:
///   - `prepare(text, lang)` — fetches the MP3/WAV bytes and caches them. App
///     state awaits this BEFORE rendering the bot's message bubble.
///   - `speak(text, lang)`   — plays the cached audio (or fetches first if
///     prepare wasn't called). Called by the chat screen once the bubble is
///     visible so audio + text appear in the same UI tick.
class Tts {
  final AudioPlayer _player = AudioPlayer();
  bool _muted = false;
  // Tiny in-session cache: same phrase + lang → reuse bytes, skip round-trip.
  final Map<String, Uint8List> _cache = {};

  Tts() {
    // MediaPlayer (NOT lowLatency/SoundPool) — SoundPool is for sub-second
    // sound effects and silently fails on multi-second WAVs at 24 kHz, which
    // is what Gemini returns. MediaPlayer handles WAV/MP3 of any length.
    _player.setPlayerMode(PlayerMode.mediaPlayer);
    _player.setReleaseMode(ReleaseMode.stop);
  }

  bool get muted => _muted;
  set muted(bool v) {
    _muted = v;
    if (v) stop();
  }

  /// Pre-fetch and cache the audio for `text` in `lang`. Resolves when the
  /// bytes are ready (or fails silently if the backend doesn't respond in
  /// time). Safe to call multiple times for the same phrase — second call is
  /// a cheap cache hit.
  ///
  /// `gender` controls the bot voice timbre (the USER's profile gender; bot
  /// voice matches). No separate "voice gender" UI toggle — it's just
  /// derived from the user's signup data.
  Future<void> prepare(String text, {String lang = 'en', String gender = 'female'}) async {
    if (_muted) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final cacheKey = '$lang::$gender::$trimmed';
    if (_cache.containsKey(cacheKey)) return;
    try {
      final resp = await http
          .post(
            Uri.parse('${ApiClient.baseUrl}/tts'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'text': trimmed, 'lang': lang, 'gender': gender}),
          )
          // 12 s max — if Gemini TTS preview is having a slow day, we'd
          // rather show text without audio than hang the whole chat.
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) {
        dev.log('[tts] prepare HTTP ${resp.statusCode}: ${resp.body}', name: 'tts');
        return;
      }
      // Bound the cache so a long chat doesn't bloat memory.
      if (_cache.length > 24) _cache.clear();
      _cache[cacheKey] = resp.bodyBytes;
      dev.log(
        '[tts] prepared ${resp.bodyBytes.length}B engine=${resp.headers['x-tts-engine']} voice=${resp.headers['x-tts-voice']}',
        name: 'tts',
      );
    } catch (e) {
      dev.log('[tts] prepare failed: $e', name: 'tts');
    }
  }

  /// Synthesize (if needed) and speak `text` in `lang`. Idempotent w.r.t.
  /// `prepare`: if prepare already cached the audio, this is a near-zero-cost
  /// play — same tick as the text becoming visible.
  Future<void> speak(String text, {String lang = 'en', String gender = 'female'}) async {
    if (_muted) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    // Stop anything currently playing — new bot reply preempts the old one.
    await _player.stop();
    final cacheKey = '$lang::$gender::$trimmed';
    if (!_cache.containsKey(cacheKey)) {
      // Prepare wasn't called or failed — try one more time inline.
      await prepare(trimmed, lang: lang, gender: gender);
    }
    if (_muted) return; // user may have muted while prepare was in flight
    final bytes = _cache[cacheKey];
    if (bytes == null) return;
    try {
      // Default mime is WAV (Gemini); Cloud TTS fallback returns MP3 — both
      // are auto-detected by MediaPlayer so the explicit mime hint is just
      // belt-and-suspenders.
      await _player.play(BytesSource(bytes, mimeType: 'audio/wav'));
    } catch (e, st) {
      dev.log('[tts] play failed: $e', name: 'tts', error: e, stackTrace: st);
    }
  }

  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await _player.dispose();
  }
}
