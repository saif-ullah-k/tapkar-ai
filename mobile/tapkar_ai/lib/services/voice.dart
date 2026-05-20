import 'dart:async';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_recognition_error.dart';

/// Thin wrapper over speech_to_text plugin. Handles permissions, locale picking,
/// and exposes a simple Stream API.
class VoiceInput {
  final SpeechToText _stt = SpeechToText();
  bool _initialized = false;

  /// Callback fired when the system fully stops listening (auto-timeout
  /// or user explicit stop). Chat screen uses this to flip the mic-button
  /// state back off so the UI matches reality.
  void Function()? onAutoStop;

  Future<bool> init() async {
    if (_initialized) return true;
    _initialized = await _stt.initialize(
      onError: (SpeechRecognitionError e) => print('[voice] error: ${e.errorMsg}'),
      onStatus: (s) {
        print('[voice] status: $s');
        // Android emits 'done' or 'notListening' when the recognizer stops.
        if (s == 'done' || s == 'notListening') onAutoStop?.call();
      },
    );
    return _initialized;
  }

  bool get isAvailable => _stt.isAvailable;
  bool get isListening => _stt.isListening;

  /// Map the app's language code to a preferred STT locale order. When the
  /// user picks Urdu in the app, we must force ur_PK / ur for STT — falling
  /// back to en_US produces Roman-Urdu-ish English transliteration of Urdu
  /// sounds, which is what the user complained about.
  static List<String> _preferenceFor(String? appLanguage) {
    switch (appLanguage) {
      case 'ur':
        return const ['ur_PK', 'ur_IN', 'ur', 'en_PK', 'en_US'];
      case 'roman_ur':
        // Roman Urdu is Latin script — English STT is the right backend.
        // en_IN tends to handle Hinglish/Roman-Urdu phonetics best.
        return const ['en_IN', 'en_PK', 'en_US', 'ur_PK'];
      case 'en':
      default:
        return const ['en_US', 'en_PK', 'en_IN'];
    }
  }

  /// Returns the best available locale id for the given app language.
  /// `appLanguage` is the user's chosen language (en | ur | roman_ur).
  /// Falls back across the preference chain until one is installed.
  Future<String> _bestLocale({String? appLanguage}) async {
    final locales = await _stt.locales();
    final available = locales.map((l) => l.localeId).toSet();
    for (final pref in _preferenceFor(appLanguage)) {
      if (available.contains(pref)) return pref;
      // Try with dash separator too (Android sometimes uses 'ur-PK').
      final dashed = pref.replaceAll('_', '-');
      if (available.contains(dashed)) return dashed;
      // Prefix match — pick any locale that starts with our preferred lang code.
      final m = available.firstWhere(
        (l) => l.toLowerCase().startsWith(pref.toLowerCase().split('_').first),
        orElse: () => '',
      );
      if (m.isNotEmpty) return m;
    }
    return 'en_US';
  }

  /// True iff the device has an installed STT locale that matches the
  /// user's app language. Lets the UI warn them when Urdu STT isn't
  /// installed (Android Settings → System → Languages → Speech recognition).
  Future<bool> isInstalledForApp(String appLanguage) async {
    final locales = await _stt.locales();
    final ids = locales.map((l) => l.localeId.toLowerCase()).toSet();
    final code = appLanguage == 'ur' ? 'ur' : appLanguage == 'roman_ur' ? 'en' : 'en';
    return ids.any((id) => id.toLowerCase().startsWith(code));
  }

  /// Start listening in DICTATION mode — the recognizer will NOT auto-stop
  /// on short pauses (which is what was cutting users off mid-thought). It
  /// only stops when:
  ///   1. The user taps the mic again → `stop()` is called
  ///   2. The OS hits the absolute `listenFor` timeout (60s here)
  ///
  /// `onPartial` receives live transcript updates as the user speaks.
  Future<String> listen({
    void Function(String partial)? onPartial,
    Duration listenFor = const Duration(seconds: 60),
    Duration pauseFor = const Duration(seconds: 10),
    String? localeId,
    String? appLanguage,
  }) async {
    if (!await init()) {
      throw Exception('Speech recognition unavailable on this device.');
    }
    final loc = localeId ?? await _bestLocale(appLanguage: appLanguage);
    print('[voice] using STT locale: $loc (appLanguage=$appLanguage)');
    String finalText = '';
    final completer = Completer<String>();
    void finish() {
      if (!completer.isCompleted) completer.complete(finalText);
    }

    // Wire onAutoStop so when the OS recognizer ends (manual stop OR
    // listenFor timeout) we resolve the future with the last transcript.
    onAutoStop = finish;

    await _stt.listen(
      localeId: loc,
      listenFor: listenFor,
      pauseFor: pauseFor,
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: false,
        // ListenMode.dictation = keep listening through pauses. The default
        // (confirmation) stops at the first silence, which is what was
        // cutting users off after one word.
        listenMode: ListenMode.dictation,
        autoPunctuation: true,
      ),
      onResult: (SpeechRecognitionResult r) {
        // In dictation mode, the engine emits multiple results — we treat
        // every result as the latest "best guess" and let `finish()` (from
        // onAutoStop) commit it when listening actually ends.
        finalText = r.recognizedWords;
        onPartial?.call(r.recognizedWords);
      },
    );

    return completer.future;
  }

  Future<void> stop() async {
    if (_stt.isListening) await _stt.stop();
  }

  Future<void> cancel() async {
    if (_stt.isListening) await _stt.cancel();
  }
}
