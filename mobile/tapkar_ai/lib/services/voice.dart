import 'dart:async';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';

/// Thin wrapper over speech_to_text plugin. Handles permissions, locale picking,
/// and exposes a simple Stream API.
class VoiceInput {
  final SpeechToText _stt = SpeechToText();
  bool _initialized = false;

  /// Locales we try in order of preference. Urdu (Pakistan) first.
  static const _preferredLocales = ['ur_PK', 'ur', 'en_PK', 'en_US'];

  Future<bool> init() async {
    if (_initialized) return true;
    _initialized = await _stt.initialize(
      onError: (e) => print('[voice] error: ${e.errorMsg}'),
      onStatus: (s) => print('[voice] status: $s'),
    );
    return _initialized;
  }

  bool get isAvailable => _stt.isAvailable;
  bool get isListening => _stt.isListening;

  /// Returns the best available locale id, or `en_US` as a final fallback.
  Future<String> _bestLocale() async {
    final locales = await _stt.locales();
    final available = locales.map((l) => l.localeId).toSet();
    for (final pref in _preferredLocales) {
      if (available.contains(pref)) return pref;
      // Fallback to base prefix match (e.g. "ur-PK" → "ur")
      final m = available.firstWhere(
        (l) => l.toLowerCase().startsWith(pref.toLowerCase()),
        orElse: () => '',
      );
      if (m.isNotEmpty) return m;
    }
    return 'en_US';
  }

  /// Start listening. Returns a one-shot future with the final transcript.
  /// Calls onPartial as the user is speaking (live transcription).
  Future<String> listen({
    void Function(String partial)? onPartial,
    Duration listenFor = const Duration(seconds: 12),
    Duration pauseFor = const Duration(seconds: 2),
    String? localeId,
  }) async {
    if (!await init()) {
      throw Exception('Speech recognition unavailable on this device.');
    }
    final loc = localeId ?? await _bestLocale();
    String finalText = '';

    final completer = Completer<String>();

    await _stt.listen(
      localeId: loc,
      listenFor: listenFor,
      pauseFor: pauseFor,
      listenOptions: SpeechListenOptions(partialResults: true, cancelOnError: false),
      onResult: (SpeechRecognitionResult r) {
        if (r.finalResult) {
          finalText = r.recognizedWords;
          if (!completer.isCompleted) completer.complete(finalText);
        } else {
          onPartial?.call(r.recognizedWords);
        }
      },
    );

    // Safety: if no final-result fires within listenFor + small buffer, return whatever we have.
    Future.delayed(listenFor + const Duration(seconds: 1), () {
      if (!completer.isCompleted) completer.complete(finalText);
    });

    return completer.future;
  }

  Future<void> stop() async {
    if (_stt.isListening) await _stt.stop();
  }

  Future<void> cancel() async {
    if (_stt.isListening) await _stt.cancel();
  }
}
