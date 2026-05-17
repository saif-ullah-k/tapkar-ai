import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/voice.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/booking_card.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/trace_panel.dart';
import '../widgets/voice_input_button.dart';
import 'role_picker_screen.dart';

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
  bool _listening = false;
  bool _showTrace = true;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onStateChange);
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChange);
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
      await _voice.stop();
      setState(() => _listening = false);
      return;
    }
    setState(() => _listening = true);
    try {
      final txt = await _voice.listen(onPartial: (p) {
        _input.text = p;
        _input.selection = TextSelection.collapsed(offset: p.length);
      });
      _input.text = txt;
      _input.selection = TextSelection.collapsed(offset: txt.length);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Voice unavailable: $e')),
        );
      }
    }
    setState(() => _listening = false);
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
            Container(
              width: 28, height: 28,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.violet, AppColors.booking],
                ),
                borderRadius: BorderRadius.circular(7),
              ),
              alignment: Alignment.center,
              child: const Text('⚡', style: TextStyle(fontSize: 14)),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('TapKar AI',
                    style: AppFonts.base(size: 15, weight: FontWeight.w700)),
                Text('Bas tap karo — AI sab kar dega',
                    style: AppFonts.base(size: 10, color: Colors.white54)),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(_showTrace ? Icons.visibility : Icons.visibility_off,
                size: 18, color: Colors.white60),
            tooltip: 'Toggle agent trace',
            onPressed: () => setState(() => _showTrace = !_showTrace),
          ),
          IconButton(
            icon: const Icon(Icons.swap_horiz, size: 20, color: Colors.white60),
            tooltip: 'Switch to provider mode',
            onPressed: () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => RolePickerScreen(
                  onCancel: () => Navigator.of(context).pop(),
                ),
              ));
            },
          ),
        ],
      );

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
                      return ChatBubble(message: s.messages[i]);
                    }
                    return BookingCard(booking: s.lastBooking!);
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
              widget.state.traceSteps.isEmpty
                  ? 'Connecting…'
                  : 'Agent ${widget.state.traceSteps.last.agent} thinking…',
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
                hintText: 'Type or tap mic…',
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
          IconButton(
            onPressed: widget.state.status == RunStatus.running ? null : _send,
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
