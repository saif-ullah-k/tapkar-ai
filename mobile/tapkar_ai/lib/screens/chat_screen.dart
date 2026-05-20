import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../i18n.dart';
import '../services/tts.dart';
import '../services/voice.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/booking_card.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/picker_card.dart';
import '../widgets/trace_panel.dart';
import '../widgets/voice_input_button.dart';
import 'voice_live_screen.dart';

class ChatScreen extends StatefulWidget {
  final AppState state;
  const ChatScreen({super.key, required this.state});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _chatScroll = ScrollController();
  final VoiceInput _voice = VoiceInput();
  final Tts _tts = Tts();
  bool _listening = false;
  // User-facing chat should not show internal agent logs by default.
  // Trace is still wired up (intent debugging, judges' demo) but kept
  // off unless someone explicitly toggles it via the eye button.
  bool _showTrace = false;
  /// Track which bot messages we've already spoken so we don't repeat on rebuild.
  int _lastSpokenIdx = -1;
  /// Hash of the last bot text we voiced. Survives screen rebuilds by
  /// also being stamped onto the message list — if the latest message's
  /// text matches this, we skip TTS. Prevents the "refresh re-speaks
  /// the last booking confirmation" bug.
  String? _lastSpokenText;
  /// True once we've finished the initial restore-from-disk hydration.
  /// Suppresses TTS during the first build so the app doesn't say
  /// "Saifullah ne booking confirm kar di" out loud the moment the
  /// user reopens the app.
  bool _ttsArmed = false;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onStateChange);
    widget.state.addListener(_maybeSpeakLatest);
    // Arm TTS after a short delay — long enough for the restored chat
    // history to land, short enough that an actual new bot message
    // arriving within the first second still gets spoken.
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) {
        // Stamp the current latest bot message as "already spoken" so
        // future polls don't re-speak it.
        final msgs = widget.state.messages;
        for (int i = msgs.length - 1; i >= 0; i--) {
          if (!msgs[i].fromUser) {
            _lastSpokenIdx = i;
            _lastSpokenText = msgs[i].text;
            break;
          }
        }
        _ttsArmed = true;
      }
    });
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChange);
    widget.state.removeListener(_maybeSpeakLatest);
    _tts.stop();
    _input.dispose();
    _chatScroll.dispose();
    super.dispose();
  }

  void _onStateChange() {
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_chatScroll.hasClients) {
          _chatScroll.animateTo(
            _chatScroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  Future<void> _toggleVoice() async {
    if (_listening) {
      // User tapped mic to stop dictation. Keep whatever was captured in the
      // text field — they can edit and tap send when ready.
      await _voice.stop();
      setState(() => _listening = false);
      return;
    }
    // Cancel any TTS that might be speaking the previous bot reply so the
    // mic doesn't pick up the bot's own voice.
    await _tts.stop();
    // Warn once when the device doesn't have an STT pack for the user's
    // chosen language. Voice will still work (English fallback) but text
    // will come out Latin-script regardless.
    final lang = widget.state.auth.language;
    if (lang == 'ur') {
      final installed = await _voice.isInstalledForApp('ur');
      if (!installed && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            duration: Duration(seconds: 4),
            content: Text(
              'Urdu speech recognition is not installed on this device. '
              'Settings → System → Languages → Speech recognition → add Urdu.',
              style: TextStyle(fontSize: 12),
            ),
          ),
        );
      }
    }
    setState(() => _listening = true);
    try {
      final txt = await _voice.listen(
        appLanguage: widget.state.auth.language,
        onPartial: (p) {
        _input.text = p;
        _input.selection = TextSelection.collapsed(offset: p.length);
      });
      _input.text = txt;
      _input.selection = TextSelection.collapsed(offset: txt.length);
      // No auto-send — let the user review the transcript, edit it if STT
      // misheard, then explicitly tap the send button. Auto-send used to
      // fire mid-thought after a short pause and was disorienting.
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Voice unavailable: $e')),
        );
      }
    }
    setState(() => _listening = false);
  }

  /// Called on every state change. If the latest message is a NEW bot reply
  /// (text + alternatives-aware) we speak it aloud — but ONLY when:
  ///   • TTS is armed (a short delay after initState lets the restored
  ///     chat history settle without re-voicing).
  ///   • The latest text is different from the last thing we spoke
  ///     (guards against the chat-screen rebuilding after navigation /
  ///     a global poller's notifyListeners and re-firing TTS on the
  ///     same already-voiced message).
  void _maybeSpeakLatest() {
    if (!_ttsArmed) return;
    final msgs = widget.state.messages;
    if (msgs.isEmpty) return;
    final idx = msgs.length - 1;
    if (idx <= _lastSpokenIdx) return;
    final m = msgs[idx];
    if (m.fromUser) {
      _lastSpokenIdx = idx; // skip user msgs but advance pointer
      return;
    }
    if (m.text == _lastSpokenText) {
      // Same text we already voiced — likely a rebuild, not a new reply.
      _lastSpokenIdx = idx;
      return;
    }
    _lastSpokenIdx = idx;
    _lastSpokenText = m.text;
    _tts.speak(
      m.text,
      lang: m.language ?? widget.state.auth.language,
      gender: widget.state.auth.gender,
    );
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    widget.state.sendMessage(text);
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width > 720;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: _appBar(),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: widget.state,
          builder: (_, __) => isWide
              ? Row(
                  children: [
                    Expanded(flex: 7, child: _chatPane()),
                    SizedBox(width: 320, child: TracePanel(
                      steps: widget.state.traceSteps,
                      isRunning: widget.state.status == RunStatus.running,
                    )),
                  ],
                )
              : Column(
                  children: [
                    Expanded(child: _chatPane()),
                    if (_showTrace && widget.state.traceSteps.isNotEmpty)
                      SizedBox(
                        height: MediaQuery.of(context).size.height * 0.35,
                        child: TracePanel(
                          steps: widget.state.traceSteps,
                          isRunning: widget.state.status == RunStatus.running,
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  PreferredSizeWidget _appBar() => AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Square brand mark — same image as the launcher icon. The
            // square already contains orb + wordmark + tagline, but for
            // the AppBar we want a compact preview, so just show the
            // logo at 38px and let the layout breathe.
            Image.asset(
              'assets/brand/logo-square.png',
              height: 38,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
            ),
          ],
        ),
        actions: [
          // (Removed the small graphic_eq voice icon — replaced by a
          // big gradient button next to the send button in _composer.)
          IconButton(
            icon: const Icon(Icons.edit_square, size: 18, color: Colors.white60),
            tooltip: 'New chat',
            onPressed: _confirmNewChat,
          ),
          IconButton(
            icon: Icon(_tts.muted ? Icons.volume_off : Icons.volume_up,
                size: 18, color: Colors.white60),
            tooltip: _tts.muted ? 'Unmute voice replies' : 'Mute voice replies',
            onPressed: () => setState(() => _tts.muted = !_tts.muted),
          ),
          // (Removed the trace-panel visibility toggle — end-users shouldn't
          // see agent logs in the chat. Trace data is still collected and
          // available via the trace API endpoint for judges/demos.)
        ],
      );

  Future<void> _confirmNewChat() async {
    // No prompt if the chat is already empty — just no-op.
    if (widget.state.messages.isEmpty && widget.state.lastBooking == null) return;
    final lang = widget.state.auth.language;
    final title = {
      'en': 'Start a new chat?',
      'ur': 'نئی گفتگو شروع کریں؟',
      'roman_ur': 'Nayi chat shuru karein?',
    }[lang] ?? 'Start a new chat?';
    final body = {
      'en': 'This clears the current conversation. Your bookings stay safe.',
      'ur': 'یہ موجودہ گفتگو ختم کر دے گا۔ آپ کی بکنگز محفوظ رہیں گی۔',
      'roman_ur': 'Ye current chat clear kar dega. Aap ki bookings safe rahein gi.',
    }[lang] ?? 'This clears the current conversation. Your bookings stay safe.';
    final cancel = {'en': 'Cancel', 'ur': 'منسوخ کریں', 'roman_ur': 'Cancel'}[lang] ?? 'Cancel';
    final ok = {'en': 'New chat', 'ur': 'نئی گفتگو', 'roman_ur': 'Nayi chat'}[lang] ?? 'New chat';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(title, style: AppFonts.base(size: 16, weight: FontWeight.w700)),
        content: Text(body, style: AppFonts.base(size: 13, color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(cancel, style: AppFonts.base(size: 13, color: Colors.white60)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(ok,
                style: AppFonts.base(size: 13, weight: FontWeight.w700, color: AppColors.violet)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.state.clearPersistedChat();
    _tts.stop();
    _input.clear();
    _lastSpokenIdx = -1;
  }

  Widget _chatPane() {
    final s = widget.state;
    return Column(
      children: [
        Expanded(
          child: s.messages.isEmpty && s.lastBooking == null
              ? _welcome()
              : ListView.builder(
                  controller: _chatScroll,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  itemCount: s.messages.length + (s.lastBooking != null ? 1 : 0),
                  itemBuilder: (_, i) {
                    if (i < s.messages.length) {
                      final m = s.messages[i];
                      // If this is a show-options message, render the bubble
                      // followed by selectable provider tiles. Tiles stay
                      // tappable until the user picks (which strips
                      // alternatives from the message) — they should NOT be
                      // disabled just because a later reminder bubble arrived.
                      if (m.alternatives != null && m.alternatives!.isNotEmpty) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ChatBubble(message: m),
                              const SizedBox(height: 8),
                              PickerCard(
                                options: m.alternatives!,
                                disabled: s.status == RunStatus.running,
                                onPick: (opt) => widget.state.pickProvider(opt),
                              ),
                            ],
                          ),
                        );
                      }
                      return ChatBubble(message: s.messages[i]);
                    }
                    return BookingCard(booking: s.lastBooking!, state: widget.state);
                  },
                ),
        ),
        if (s.status == RunStatus.running) _runningIndicator(),
        if (s.errorMessage != null) _errorBanner(s.errorMessage!, s.clearError),
        _composer(),
      ],
    );
  }

  Widget _welcome() {
    final examples = [
      'kal subah Gulshan mein plumber chahiye, paani leak ho raha hai',
      'AC theek karwana hai DHA mein',
      'I need a bridal makeup artist for 25 May in Clifton',
      'کل صبح ٹیوٹر چاہیے گلشن میں',
    ];
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('What service do you need?',
                style: AppFonts.base(size: 22, weight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              'Tap the mic or type — Urdu, Roman Urdu, or English.',
              textAlign: TextAlign.center,
              style: AppFonts.base(size: 13, color: Colors.white60),
            ),
            const SizedBox(height: 22),
            ...examples.map((e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: InkWell(
                    onTap: () {
                      _input.text = e;
                      _send();
                    },
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.surface2,
                        border: Border.all(color: AppColors.border),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Directionality(
                        textDirection: directionFor(e),
                        child: Text(
                          e,
                          style: directionFor(e) == TextDirection.rtl
                              ? AppFonts.urdu(size: 14, color: Colors.white.withOpacity(0.85))
                              : AppFonts.base(size: 13, color: Colors.white.withOpacity(0.85)),
                        ),
                      ),
                    ),
                  ),
                )),
          ],
        ),
      ),
    );
  }

  static const _pipelineAgents = ['intent', 'discovery', 'ranking', 'booking', 'followup'];
  /// In locked-mode (user already picked a provider from a prior turn), the
  /// orchestrator skips discovery + ranking and only runs intent + booking.
  /// We can't directly observe orchestrator state from the chat, but the
  /// last user message echoing "Selected: …" is a reliable hint.
  bool get _isLockedMode {
    if (widget.state.messages.isEmpty) return false;
    final last = widget.state.messages.last;
    if (!last.fromUser) return false;
    final t = last.text.toLowerCase();
    return t.startsWith('selected:') ||
        t.startsWith('select kiya:') ||
        t.startsWith('منتخب کیا'); // urdu
  }

  String _currentAgentLabel() {
    final done = widget.state.traceSteps.length;
    if (_isLockedMode) {
      // Locked pipeline: intent → booking only. Followup runs async on the
      // server and won't appear until after run_complete.
      const locked = ['intent', 'booking'];
      if (done >= locked.length) return 'finishing up';
      return locked[done];
    }
    if (done >= _pipelineAgents.length) return 'finishing up';
    return _pipelineAgents[done];
  }

  Widget _runningIndicator() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            const SizedBox(
              width: 12, height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
            const SizedBox(width: 8),
            Text(
              () {
                final total = _isLockedMode ? 2 : 5;
                final done = widget.state.traceSteps.length.clamp(0, total);
                return 'Agent ${_currentAgentLabel()} working… ($done/$total)';
              }(),
              style: AppFonts.base(size: 12, color: Colors.white60),
            ),
          ],
        ),
      );

  Widget _errorBanner(String msg, VoidCallback onDismiss) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        color: Colors.orange.withOpacity(0.15),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(_friendlyError(msg),
                  style: AppFonts.base(size: 13, color: Colors.white, weight: FontWeight.w500)),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 14, color: Colors.white60),
              onPressed: onDismiss,
            ),
          ],
        ),
      );

  /// Translate raw backend errors into something a human reads.
  String _friendlyError(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('429') ||
        lower.contains('resource_exhausted') ||
        lower.contains('rate_limit') ||
        lower.contains('rate-limited') ||
        lower.contains('rate limit')) {
      return 'AI is busy right now — please wait ~30 seconds and try again.';
    }
    if (lower.contains('503') ||
        lower.contains('unavailable') ||
        lower.contains('capacity')) {
      return 'AI server is at capacity. Try again in a minute.';
    }
    if (lower.contains('timeout') || lower.contains('timed out')) {
      return 'That took too long. Try again — it usually completes in 30-60s.';
    }
    if (lower.contains('socketexception') ||
        lower.contains('connection refused') ||
        lower.contains('failed host')) {
      return 'Can\'t reach the server. Check your connection and try again.';
    }
    if (lower.contains('gemini_api_key_missing') ||
        lower.contains('gemini_auth_missing')) {
      return 'Server is misconfigured (missing API key).';
    }
    // Default: trim to one short line
    return raw.length > 120 ? '${raw.substring(0, 120)}…' : raw;
  }

  Widget _composer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          VoiceInputButton(listening: _listening, onTap: _toggleVoice),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _input,
              maxLines: 4,
              minLines: 1,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: T(widget.state.auth.language).chatInputHint,
                hintStyle: AppFonts.base(size: 13, color: Colors.white38),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide(color: AppColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide(color: AppColors.violet.withOpacity(0.6)),
                ),
              ),
              style: AppFonts.base(size: 14),
              inputFormatters: [LengthLimitingTextInputFormatter(2000)],
            ),
          ),
          const SizedBox(width: 6),
          // Gemini Live voice mode — big gradient circle right next to
          // the send button so users actually see and use it. Replaces
          // the easily-missed AppBar icon.
          IconButton(
            tooltip: 'Voice mode (Gemini Live)',
            onPressed: () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => VoiceLiveScreen(state: widget.state),
              ));
            },
            icon: Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  colors: [AppColors.violet, AppColors.booking],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.violet.withOpacity(0.45),
                    blurRadius: 10,
                  ),
                ],
              ),
              child: const Icon(Icons.graphic_eq, color: Colors.white, size: 20),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            // Always enabled — sendMessage queues if a run is in flight.
            onPressed: _send,
            icon: Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  colors: [AppColors.violet, AppColors.booking],
                ),
              ),
              child: const Icon(Icons.send, color: Colors.white, size: 16),
            ),
          ),
        ],
      ),
    );
  }
}
