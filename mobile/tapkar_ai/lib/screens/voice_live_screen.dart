/**
 * Voice Live screen — Gemini Live API integration (Option A).
 *
 * Opens a WebSocket to /voice/live on the backend. Captures mic audio as
 * 16 kHz mono 16-bit PCM, streams it to the server in 250 ms chunks. The
 * server forwards to Gemini Live and streams back 24 kHz audio chunks +
 * tool-call events. Audio is buffered per turn and played as one WAV when
 * the turn completes (gives smooth playback without needing a real-time
 * PCM player). Tool calls fire our existing 5-agent orchestrator behind
 * the scenes — trace events appear in the UI as agents run.
 */
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../state/app_state.dart';

enum _BotState { connecting, listening, thinking, speaking, error }

class VoiceLiveScreen extends StatefulWidget {
  final AppState state;
  const VoiceLiveScreen({super.key, required this.state});

  @override
  State<VoiceLiveScreen> createState() => _VoiceLiveScreenState();
}

class _VoiceLiveScreenState extends State<VoiceLiveScreen>
    with SingleTickerProviderStateMixin {
  // The backend WebSocket URL is derived from the HTTPS API URL.
  static String get _wsUrl {
    const apiUrl = String.fromEnvironment(
      'API_URL',
      defaultValue: 'https://tapkar-ai-backend-d56rhra4sa-uc.a.run.app',
    );
    final ws = apiUrl.replaceFirst(RegExp(r'^http'), 'ws');
    return '$ws/voice/live';
  }

  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _micSub;
  final AudioPlayer _player = AudioPlayer();
  final List<int> _pcmOutBuffer = [];
  _BotState _state = _BotState.connecting;
  String _transcript = '';
  String _lastToolMessage = '';
  bool _muted = false;
  // True while we're playing the bot's audio back to the user. Mic chunks
  // captured during this window MUST NOT be forwarded — otherwise the
  // mic picks up the speaker's own output and we either loop or confuse
  // the model into staying silent on subsequent turns.
  bool _botPlaying = false;
  Timer? _playbackSafetyTimer;
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _player.setReleaseMode(ReleaseMode.stop);
    _player.setPlayerMode(PlayerMode.mediaPlayer);
    // Audio profile for a voice-assistant playback. With the default
    // (USAGE_MEDIA + AUDIOFOCUS_GAIN) the player yanks audio focus from
    // the recorder mid-stream — the mic stops capturing and subsequent
    // turns get no input. voiceCommunication + AudioFocus.none lets the
    // mic keep recording during playback. Speakerphone-on routes output
    // through the loud speaker (matches the recorder's profile).
    // Player goes through the LOUDSPEAKER (USAGE_MEDIA), not the earpiece.
    // The recorder still uses voiceCommunication for echo cancellation,
    // but the player can't share that usage type or audio would route
    // through the small call speaker. focus=none keeps the player from
    // yanking focus away from the recorder. modeNormal is the right
    // partner for USAGE_MEDIA — voiceCommunication/inCommunication
    // would force routing through the earpiece.
    _player.setAudioContext(AudioContext(
      android: const AudioContextAndroid(
        isSpeakerphoneOn: false,
        contentType: AndroidContentType.speech,
        usageType: AndroidUsageType.media,
        audioFocus: AndroidAudioFocus.none,
        audioMode: AndroidAudioMode.normal,
      ),
    ));
    _connect();
  }

  Future<void> _connect() async {
    setState(() => _state = _BotState.connecting);
    try {
      _ws = IOWebSocketChannel.connect(Uri.parse(_wsUrl));
      _wsSub = _ws!.stream.listen(_onServerFrame,
          onError: (e) => _setError('socket: $e'), onDone: () {
        if (mounted && _state != _BotState.error) _setError('socket closed');
      });
      // Send auth frame immediately.
      _send({
        'type': 'auth',
        'user_id': widget.state.userId,
        'user_name': widget.state.auth.displayName,
        'language': widget.state.auth.language,
        'user_gender': widget.state.auth.gender,
      });
    } catch (e) {
      _setError('connect: $e');
    }
  }

  void _send(Map<String, dynamic> frame) {
    final ws = _ws;
    if (ws == null) return;
    try {
      ws.sink.add(jsonEncode(frame));
    } catch (_) {}
  }

  Future<void> _startMic() async {
    if (!await _recorder.hasPermission()) {
      _setError('mic permission denied');
      return;
    }
    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      // Android-specific. The default audio source (`mic`) loses focus the
      // moment audioplayers starts playing the bot's response — the
      // recorder pauses, and subsequent turns get no mic input even
      // though the WS is still alive. `voiceCommunication` + the
      // matching audio-manager mode is the VoIP profile that's expected
      // to record AND play simultaneously, with built-in echo
      // cancellation so the bot's speaker output doesn't loop back.
      androidConfig: AndroidRecordConfig(
        // voiceCommunication audio source gives hardware echo cancellation
        // (so the bot's loudspeaker output doesn't loop back into the mic).
        // BUT keep the audio manager in NORMAL mode — modeInCommunication
        // would force every stream through the earpiece, making the bot's
        // voice sound like it's coming from the call speaker.
        audioSource: AndroidAudioSource.voiceCommunication,
        audioManagerMode: AudioManagerMode.modeNormal,
        speakerphone: false,
        manageBluetooth: false,
      ),
    ));
    _micSub = stream.listen((chunk) {
      // Drop chunks while user has muted OR bot is mid-playback. Otherwise
      // the bot hears itself and either echoes or stops responding.
      if (_muted || _botPlaying) return;
      _send({'type': 'audio', 'audio': base64Encode(chunk)});
    });
  }

  Future<void> _stopMic() async {
    await _micSub?.cancel();
    _micSub = null;
    try {
      await _recorder.stop();
    } catch (_) {}
  }

  void _onServerFrame(dynamic raw) {
    Map<String, dynamic> frame;
    try {
      frame = jsonDecode(raw is String ? raw : raw.toString()) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final type = frame['type'] as String?;
    final newState = frame['state'] as String?;
    if (newState != null) {
      _setStateFromString(newState);
    }
    switch (type) {
      case 'ready':
        _setStateFromString('listening');
        _startMic();
        break;
      case 'audio':
        final b64 = frame['audio'] as String?;
        if (b64 != null && b64.isNotEmpty) {
          final bytes = base64Decode(b64);
          _pcmOutBuffer.addAll(bytes);
          _setStateFromString('speaking');
        }
        break;
      case 'transcript':
        final t = (frame['text'] as String?) ?? '';
        if (t.isNotEmpty) {
          setState(() => _transcript = t);
        }
        break;
      case 'tool_call':
        final tool = frame['tool'] as Map?;
        final name = tool?['name'] as String?;
        setState(() {
          _lastToolMessage = name == 'book_a_service'
              ? 'Running booking pipeline…'
              : 'Calling $name…';
          _state = _BotState.thinking;
        });
        break;
      case 'agent_step':
        // Agent traces stream through the existing app state so the trace
        // panel (when reopened in chat) shows them.
        final step = frame['step'] as Map<String, dynamic>?;
        if (step != null) {
          widget.state.handleVoiceLiveStep(step);
        }
        break;
      case 'tool_result':
        setState(() => _lastToolMessage = '');
        break;
      case 'turn_complete':
        _flushAudio();
        break;
      case 'error':
        final err = frame['error']?.toString() ?? 'unknown';
        // Live API enforces a per-session duration cap (~10 min for audio).
        // When that fires we want a clear "tap to resume" message rather
        // than the generic "Voice unavailable".
        _setError(err == 'session_timeout'
            ? 'Session ended — tap close, then voice again'
            : err);
        break;
    }
  }

  Future<void> _flushAudio() async {
    if (_pcmOutBuffer.isEmpty) {
      _resumeListening();
      return;
    }
    final pcm = Uint8List.fromList(_pcmOutBuffer);
    _pcmOutBuffer.clear();
    final wav = _pcmToWav(pcm, sampleRate: 24000);
    // Estimated playback length (24 kHz, 16-bit mono) + 1 s slack. Used
    // as a safety backstop in case onPlayerComplete never fires.
    final estMs = (pcm.length / (24000 * 2) * 1000).ceil() + 1000;
    _botPlaying = true;
    _playbackSafetyTimer?.cancel();
    _playbackSafetyTimer =
        Timer(Duration(milliseconds: estMs), _resumeListening);
    try {
      await _player.stop();
      await _player.play(BytesSource(wav, mimeType: 'audio/wav'));
      _player.onPlayerComplete.first.then((_) => _resumeListening());
    } catch (_) {
      _resumeListening();
    }
  }

  /// Restore the listening state after a bot turn ends — runs from either
  /// the player-complete callback OR the safety timer, whichever wins.
  void _resumeListening() {
    _playbackSafetyTimer?.cancel();
    _playbackSafetyTimer = null;
    _botPlaying = false;
    if (mounted) _setStateFromString('listening');
  }

  /// Wrap raw 16-bit PCM mono in a minimal RIFF/WAV header so audioplayers
  /// can decode it. Sample rate is the Gemini Live default for output
  /// (24 kHz) unless overridden.
  Uint8List _pcmToWav(Uint8List pcm, {int sampleRate = 24000, int channels = 1, int bitsPerSample = 16}) {
    final byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
    final blockAlign = channels * (bitsPerSample ~/ 8);
    final dataLen = pcm.length;
    final fileLen = 36 + dataLen;
    final b = BytesBuilder();
    void w32(int v) {
      b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
    }

    void w16(int v) {
      b.add([v & 0xff, (v >> 8) & 0xff]);
    }

    b.add(utf8.encode('RIFF'));
    w32(fileLen);
    b.add(utf8.encode('WAVE'));
    b.add(utf8.encode('fmt '));
    w32(16);
    w16(1); // PCM
    w16(channels);
    w32(sampleRate);
    w32(byteRate);
    w16(blockAlign);
    w16(bitsPerSample);
    b.add(utf8.encode('data'));
    w32(dataLen);
    b.add(pcm);
    return b.toBytes();
  }

  void _setStateFromString(String s) {
    if (!mounted) return;
    setState(() {
      switch (s) {
        case 'listening':
          _state = _BotState.listening;
          break;
        case 'thinking':
          _state = _BotState.thinking;
          break;
        case 'speaking':
          _state = _BotState.speaking;
          break;
      }
    });
  }

  void _setError(String msg) {
    if (!mounted) return;
    setState(() {
      _state = _BotState.error;
      _lastToolMessage = msg;
    });
  }

  Future<void> _exit() async {
    await _stopMic();
    try {
      _send({'type': 'close'});
    } catch (_) {}
    await _wsSub?.cancel();
    try {
      await _ws?.sink.close();
    } catch (_) {}
    await _player.stop();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _playbackSafetyTimer?.cancel();
    _pulse.dispose();
    _stopMic();
    _wsSub?.cancel();
    _ws?.sink.close();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar — mute + close
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
              child: Row(children: [
                IconButton(
                  icon: const Icon(Icons.menu, color: Colors.white60, size: 22),
                  onPressed: () {},
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(_muted ? Icons.mic_off : Icons.mic,
                      color: _muted ? Colors.redAccent : Colors.white60, size: 22),
                  tooltip: _muted ? 'Unmute' : 'Mute',
                  onPressed: () => setState(() => _muted = !_muted),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white60, size: 22),
                  tooltip: 'Exit voice mode',
                  onPressed: _exit,
                ),
              ]),
            ),
            // Orb — animated gradient circle that pulses based on state.
            Expanded(child: Center(child: _orb())),
            // Status text
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 36),
              child: Column(children: [
                Text(_statusLabel(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w600)),
                if (_transcript.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(_transcript,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white60, fontSize: 13)),
                ],
                if (_lastToolMessage.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(_lastToolMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.orangeAccent, fontSize: 12)),
                ],
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _orb() {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, __) {
        final t = _pulse.value;
        final scale = _state == _BotState.speaking
            ? 1.0 + 0.18 * t
            : _state == _BotState.thinking
                ? 1.0 + 0.08 * t
                : _state == _BotState.listening
                    ? 1.0 + 0.04 * t
                    : 1.0;
        final colors = _state == _BotState.error
            ? [Colors.redAccent, Colors.red.shade900]
            : [
                const Color(0xFF9c6cff),
                const Color(0xFF5cd4ff),
                const Color(0xFFffb05c),
              ];
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 200,
            height: 200,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: SweepGradient(
                colors: [...colors, colors.first],
                stops: List.generate(
                    colors.length + 1, (i) => i / (colors.length)),
                transform: GradientRotation(t * 6.28),
              ),
              boxShadow: [
                BoxShadow(
                  color: colors.first.withOpacity(0.4),
                  blurRadius: 60,
                  spreadRadius: 10,
                ),
              ],
            ),
            child: Center(
              child: Icon(
                _state == _BotState.error ? Icons.error_outline : Icons.graphic_eq,
                color: Colors.white,
                size: 56,
              ),
            ),
          ),
        );
      },
    );
  }

  String _statusLabel() {
    switch (_state) {
      case _BotState.connecting:
        return 'Connecting…';
      case _BotState.listening:
        return 'Listening — start talking';
      case _BotState.thinking:
        return 'Thinking…';
      case _BotState.speaking:
        return 'Speaking';
      case _BotState.error:
        return 'Voice unavailable';
    }
  }
}
