import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/provider_api.dart';
import '../services/tts.dart';
import '../services/voice.dart';
import '../state/auth_state.dart';
import '../theme.dart';
import '../widgets/voice_input_button.dart';

/// AI-driven provider setup (or edit) via a conversational chat. The bot
/// asks for each field one at a time, extracts answers from natural-language
/// input (Urdu / Roman Urdu / English), and offers a "Save" action once the
/// draft is complete enough.
class ProviderChatSetupScreen extends StatefulWidget {
  final AuthState auth;

  /// 'signup' = brand-new provider profile. 'edit' = update an existing one.
  final String mode;

  /// For edit mode: the existing profile to seed the draft with.
  final Map<String, dynamic>? existing;
  const ProviderChatSetupScreen({
    super.key,
    required this.auth,
    this.mode = 'signup',
    this.existing,
  });

  @override
  State<ProviderChatSetupScreen> createState() => _ProviderChatSetupScreenState();
}

class _ChatMsg {
  final String text;
  final bool fromUser;
  _ChatMsg(this.text, {this.fromUser = false});
}

class _ProviderChatSetupScreenState extends State<ProviderChatSetupScreen> {
  final ProviderApi _api = ProviderApi();
  final VoiceInput _voice = VoiceInput();
  final Tts _tts = Tts();
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  final List<_ChatMsg> _msgs = [];
  Map<String, dynamic> _draft = {};
  bool _busy = false;
  bool _complete = false;
  bool _listening = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Seed the draft from existing profile when editing, plus any data we
    // already know from auth (name, phone, gender).
    _draft = {
      if (widget.existing != null) ...widget.existing!,
      'name': widget.existing?['name'] ?? widget.auth.name,
      'phone': widget.existing?['phone'] ??
          (widget.auth.phone.isNotEmpty ? widget.auth.phone : null),
      'gender': widget.existing?['gender'] ?? widget.auth.gender,
    }..removeWhere((_, v) => v == null);

    final openingByMode = widget.mode == 'edit'
        ? _t({
            'en': "Hi ${widget.auth.displayName} — tell me what you'd like to change. e.g. \"new price 3000 to 8000\" or \"add Clifton to my service areas\".",
            'ur': "السلام علیکم ${widget.auth.displayName}! بتائیں کیا تبدیل کرنا ہے؟ مثلاً \"نئی قیمت ۳۰۰۰ سے ۸۰۰۰\"۔",
            'roman_ur':
                "Salaam ${widget.auth.displayName}! Bataiye kya badalna hai. Misal: \"price 3000 se 8000\" ya \"Clifton bhi add karein\".",
          })
        : _t({
            'en': "Hi! I'll help you set up your provider profile. What's your business or your name?",
            'ur': "السلام علیکم! میں آپ کی پرووائڈر پروفائل بناؤں گی۔ آپ کے کاروبار یا آپ کا نام کیا ہے؟",
            'roman_ur':
                "Salaam! Main aap ki provider profile setup karoon gi. Aap ke business ya aap ka naam kya hai?",
          });
    _msgs.add(_ChatMsg(openingByMode));
    // Speak the opening line so it feels conversational from the first beat.
    _tts.speak(openingByMode, lang: widget.auth.language, gender: widget.auth.gender);
  }

  String _t(Map<String, String> table) =>
      table[widget.auth.language] ?? table['en']!;

  @override
  void dispose() {
    _tts.stop();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send([String? overrideText]) async {
    final text = (overrideText ?? _input.text).trim();
    if (text.isEmpty || _busy) return;
    _input.clear();
    setState(() {
      _msgs.add(_ChatMsg(text, fromUser: true));
      _busy = true;
    });
    _scrollDown();

    final reply = await _api.providerChat(
      userId: widget.auth.userId,
      message: text,
      draft: _draft,
      mode: widget.mode,
      language: widget.auth.language,
      userGender: widget.auth.gender,
    );

    if (!mounted) return;
    if (reply == null) {
      setState(() {
        _msgs.add(_ChatMsg(_t({
          'en': "Sorry, I didn't catch that. Could you say it again?",
          'ur': "معاف کیجیے، میں نہیں سمجھی۔ دوبارہ بتائیں؟",
          'roman_ur': "Maaf kijiye, main nahi samjhi. Dobara bataiye?",
        })));
        _busy = false;
      });
      _scrollDown();
      return;
    }

    final botText = (reply['reply'] as String?)?.trim() ?? '';
    final newDraft = Map<String, dynamic>.from(reply['draft'] as Map? ?? _draft);
    final draftChanged = _draftDiffers(_draft, newDraft);
    setState(() {
      _draft = newDraft;
      _complete = reply['complete'] == true;
      if (botText.isNotEmpty) _msgs.add(_ChatMsg(botText));
      _busy = false;
    });
    if (botText.isNotEmpty) {
      _tts.speak(botText, lang: widget.auth.language, gender: widget.auth.gender);
    }
    _scrollDown();
    // EDIT mode: auto-save the moment the AI updates any field, so the
    // user doesn't have to remember to tap "Save". Real-time persistence.
    if (widget.mode == 'edit' && draftChanged) {
      _autoSaveEdit();
    }
  }

  /// True if any required field value has changed between two drafts.
  /// Compares by JSON-encoded string for simplicity (handles maps + lists).
  bool _draftDiffers(Map<String, dynamic> a, Map<String, dynamic> b) {
    final keys = {...a.keys, ...b.keys};
    for (final k in keys) {
      final av = a[k];
      final bv = b[k];
      if (av == null && bv == null) continue;
      if (av == null || bv == null) return true;
      // Crude but effective: compare JSON string projections.
      if (av.toString() != bv.toString()) return true;
    }
    return false;
  }

  bool _autoSaving = false;

  /// Auto-save the current draft to the backend in edit mode. Silent
  /// success snackbar, no navigation. If save fails, surface the error so
  /// the user knows their change didn't stick.
  Future<void> _autoSaveEdit() async {
    if (_autoSaving) return;
    _autoSaving = true;
    final id = widget.existing?['id'] as String? ?? widget.auth.providerId;
    if (id == null || id.isEmpty) {
      _autoSaving = false;
      return;
    }
    try {
      final payload = <String, dynamic>{
        'user_id': widget.auth.userId,
        ..._draft,
      };
      await _api.updateProvider(id, payload);
      if (!mounted) return;
      // Subtle "saved" toast — quick, non-intrusive.
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green.shade700,
          duration: const Duration(milliseconds: 1400),
          behavior: SnackBarBehavior.floating,
          content: Row(children: [
            const Icon(Icons.check_circle, size: 16, color: Colors.white),
            const SizedBox(width: 8),
            Text(_t({
              'en': 'Saved',
              'ur': 'محفوظ ہو گیا',
              'roman_ur': 'Save ho gaya',
            }), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ]),
        ),
      );
      // Keep widget.existing in sync so subsequent diffs are correct.
      widget.existing?.addAll(_draft);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red.shade700,
          content: Text('Auto-save failed: $e'),
        ),
      );
    } finally {
      _autoSaving = false;
    }
  }

  Future<void> _toggleVoice() async {
    if (_listening) {
      await _voice.stop();
      setState(() => _listening = false);
      return;
    }
    // Cancel any TTS playing so the mic doesn't pick up the bot's own voice.
    await _tts.stop();
    setState(() => _listening = true);
    try {
      final txt = await _voice.listen(
        appLanguage: widget.auth.language,
        onPartial: (p) {
        _input.text = p;
        _input.selection = TextSelection.collapsed(offset: p.length);
      });
      _input.text = txt;
      _input.selection = TextSelection.collapsed(offset: txt.length);
    } catch (_) {/* ignore */}
    if (mounted) setState(() => _listening = false);
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      // Inject user_id + sensible defaults for any optional fields the
      // backend register schema requires.
      final payload = <String, dynamic>{
        'user_id': widget.auth.userId,
        'specializations': <String>[],
        'service_radius_km': 10,
        ..._draft,
      };
      if (widget.mode == 'signup') {
        final result = await _api.registerProvider(payload);
        final providerId = result['provider_id'] as String?;
        if (providerId != null) {
          await widget.auth.switchToProvider(
            providerId: providerId,
            providerName: (payload['name'] as String?) ?? widget.auth.name,
            providerCategory: payload['category'] as String?,
          );
        }
      } else {
        // EDIT mode — PATCH the existing provider.
        final id = widget.existing?['id'] as String? ??
            widget.auth.providerId; // belt-and-suspenders fallback
        if (id == null || id.isEmpty) {
          throw 'No provider_id to update — please sign out and back in';
        }
        await _api.updateProvider(id, payload);
        await widget.auth.switchToProvider(
          providerId: id,
          providerName: (payload['name'] as String?) ?? widget.auth.displayName,
          providerCategory: payload['category'] as String?,
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green.shade700,
          content: Text(_t({
            'en': widget.mode == 'edit'
                ? 'Profile updated'
                : 'Profile saved — welcome!',
            'ur': widget.mode == 'edit'
                ? 'پروفائل اپڈیٹ ہو گئی'
                : 'پروفائل محفوظ ہو گئی — خوش آمدید!',
            'roman_ur': widget.mode == 'edit'
                ? 'Profile update ho gayi'
                : 'Profile save ho gayi — welcome!',
          })),
          duration: const Duration(seconds: 2),
        ),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
      );
      setState(() => _saving = false);
    }
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: Text(
          widget.mode == 'edit'
              ? _t({'en': 'Edit profile', 'ur': 'پروفائل تبدیل کریں', 'roman_ur': 'Profile edit'})
              : _t({'en': 'Set up your profile', 'ur': 'پروفائل بنائیں', 'roman_ur': 'Profile setup'}),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            icon: Icon(_tts.muted ? Icons.volume_off : Icons.volume_up,
                size: 18, color: Colors.white60),
            tooltip: _tts.muted ? 'Unmute voice' : 'Mute voice',
            onPressed: () => setState(() => _tts.muted = !_tts.muted),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Real-time-save banner — only visible in EDIT mode so the user
            // knows their changes persist as they talk (no need to wait
            // for a Save button).
            if (widget.mode == 'edit')
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                color: Colors.green.withOpacity(0.12),
                child: Row(children: [
                  const Icon(Icons.bolt, size: 14, color: Colors.greenAccent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _t({
                        'en': 'Changes save automatically as you chat.',
                        'ur': 'تبدیلیاں چیٹ کرتے وقت خود بخود محفوظ ہو رہی ہیں۔',
                        'roman_ur': 'Aap chat karte hi changes auto-save ho rahi hain.',
                      }),
                      style: const TextStyle(fontSize: 11.5, color: Colors.white70),
                    ),
                  ),
                ]),
              ),
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.symmetric(vertical: 12),
                itemCount: _msgs.length,
                itemBuilder: (_, i) => _bubble(_msgs[i]),
              ),
            ),
            if (_busy) const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(children: [
                SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
                SizedBox(width: 8),
                Text('…', style: TextStyle(color: Colors.white60, fontSize: 12)),
              ]),
            ),
            // Save button:
            //  - SIGNUP mode: only when the AI says all required fields are
            //    in the draft (complete=true).
            //  - EDIT mode: ALWAYS visible — the user shouldn't need to
            //    negotiate with the AI to save their change. Style softens
            //    when there's nothing actually changed.
            if (!_saving && (_complete || widget.mode == 'edit'))
              Container(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.check_circle_outline, size: 18),
                    onPressed: _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.violet,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    label: Text(_t({
                      'en': widget.mode == 'edit' ? 'Done' : 'Save profile',
                      'ur': widget.mode == 'edit' ? 'مکمل' : 'پروفائل محفوظ کریں',
                      'roman_ur': widget.mode == 'edit' ? 'Done' : 'Profile save karein',
                    })),
                  ),
                ),
              ),
            if (_saving) const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Center(child: CircularProgressIndicator()),
            ),
            _composer(),
          ],
        ),
      ),
    );
  }

  Widget _bubble(_ChatMsg m) {
    final align = m.fromUser ? Alignment.centerRight : Alignment.centerLeft;
    final bg = m.fromUser ? AppColors.violet : AppColors.surface;
    final fg = m.fromUser ? Colors.white : Colors.white.withOpacity(0.92);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      alignment: align,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(14),
            border: m.fromUser ? null : Border.all(color: AppColors.border),
          ),
          child: Text(m.text, style: TextStyle(color: fg, fontSize: 14, height: 1.35)),
        ),
      ),
    );
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
                hintText: _t({
                  'en': 'Type your answer…',
                  'ur': 'جواب لکھیں…',
                  'roman_ur': 'Apna jawab likhein…',
                }),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
              ),
              inputFormatters: [LengthLimitingTextInputFormatter(400)],
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            onPressed: _busy ? null : _send,
            icon: Container(
              width: 32,
              height: 32,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [AppColors.violet, AppColors.booking]),
              ),
              child: const Icon(Icons.send, color: Colors.white, size: 16),
            ),
          ),
        ],
      ),
    );
  }
}
