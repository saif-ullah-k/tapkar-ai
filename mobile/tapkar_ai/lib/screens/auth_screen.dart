import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../state/auth_state.dart';
import '../theme.dart';

/// Phone-OTP login / signup. Two-step flow:
///   Step 1: phone (+ name + language if signing up) → send OTP
///   Step 2: enter 6-digit code → verify
class AuthScreen extends StatefulWidget {
  final AuthState auth;
  final VoidCallback onAuthed;
  const AuthScreen({super.key, required this.auth, required this.onAuthed});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> with SingleTickerProviderStateMixin {
  late TabController _tabs;
  final _phoneCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _otpCtrl = TextEditingController();
  String _language = 'roman_ur';
  String _role = 'customer'; // 'customer' | 'provider' — chosen on Create account
  String _gender = 'female'; // 'female' | 'male' — drives bot TTS voice
  bool _busy = false;
  String? _errMsg;

  bool get _otpStep => widget.auth.otpInFlight;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    widget.auth.addListener(_onAuthChange);
  }

  @override
  void dispose() {
    widget.auth.removeListener(_onAuthChange);
    _tabs.dispose();
    _phoneCtrl.dispose();
    _nameCtrl.dispose();
    _otpCtrl.dispose();
    super.dispose();
  }

  void _onAuthChange() {
    if (!mounted) return;
    if (widget.auth.signedIn) widget.onAuthed();
    setState(() {});
  }

  Future<void> _sendOtp({required bool isSignUp}) async {
    final phone = _phoneCtrl.text.trim();
    if (phone.length < 10) {
      setState(() => _errMsg = 'Enter your 10-digit Pakistani number (e.g. 3001234567)');
      return;
    }
    if (isSignUp && _nameCtrl.text.trim().isEmpty) {
      setState(() => _errMsg = 'Please enter your name');
      return;
    }
    setState(() {
      _busy = true;
      _errMsg = null;
    });
    final err = await widget.auth.sendOtp(
      phone10Digit: phone,
      isSignUp: isSignUp,
      name: _nameCtrl.text.trim(),
      language: _language,
      gender: _gender,
      role: isSignUp ? _role : 'customer',
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _errMsg = err;
    });
  }

  Future<void> _verifyOtp() async {
    final code = _otpCtrl.text.trim();
    if (code.length != 6) {
      setState(() => _errMsg = 'Enter the 6-digit code from your SMS');
      return;
    }
    setState(() {
      _busy = true;
      _errMsg = null;
    });
    final err = await widget.auth.verifyOtp(code);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _errMsg = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 28),
              _logo(),
              const SizedBox(height: 24),
              if (_otpStep) ...[
                _otpUI(),
              ] else ...[
                Text('Welcome',
                    style: AppFonts.base(size: 26, weight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text('Bas tap karo — AI sab kar dega.',
                    style: AppFonts.base(size: 13, color: Colors.white60)),
                const SizedBox(height: 24),
                _tabSwitcher(),
                const SizedBox(height: 24),
                Expanded(
                  child: TabBarView(
                    controller: _tabs,
                    children: [_signInForm(), _signUpForm()],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _logo() => Row(
        children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppColors.violet, AppColors.booking],
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: const Text('⚡', style: TextStyle(fontSize: 20)),
          ),
          const SizedBox(width: 10),
          Text('TapKar AI',
              style: AppFonts.base(size: 19, weight: FontWeight.w800)),
        ],
      );

  Widget _tabSwitcher() => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
        ),
        child: TabBar(
          controller: _tabs,
          indicator: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppColors.violet, AppColors.booking],
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          indicatorSize: TabBarIndicatorSize.tab,
          dividerColor: Colors.transparent,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          labelStyle: AppFonts.base(size: 13, weight: FontWeight.w700),
          tabs: const [
            Tab(text: 'Sign in'),
            Tab(text: 'Create account'),
          ],
        ),
      );

  Widget _signInForm() => SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _field(label: 'Phone number', child: _phoneInput()),
            const SizedBox(height: 12),
            _errBox(),
            const SizedBox(height: 12),
            _primaryButton('Send code',
                _busy ? null : () => _sendOtp(isSignUp: false)),
            const SizedBox(height: 12),
            Center(
              child: Text(
                'We\'ll send a 6-digit code via SMS to verify.',
                textAlign: TextAlign.center,
                style: AppFonts.base(size: 11, color: Colors.white54),
              ),
            ),
          ],
        ),
      );

  Widget _signUpForm() => SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _field(label: 'I want to', child: _rolePicker()),
            const SizedBox(height: 16),
            _field(label: 'Your name', child: _textField(_nameCtrl, hint: 'Saifullah')),
            const SizedBox(height: 16),
            _field(label: 'Gender', child: _genderPicker()),
            const SizedBox(height: 16),
            _field(label: 'Phone number', child: _phoneInput()),
            const SizedBox(height: 16),
            _field(label: 'Preferred language', child: _languagePicker()),
            const SizedBox(height: 16),
            _errBox(),
            const SizedBox(height: 12),
            _primaryButton('Send code',
                _busy ? null : () => _sendOtp(isSignUp: true)),
          ],
        ),
      );

  Widget _genderPicker() {
    final opts = [
      {'id': 'female', 'label': 'Female', 'icon': Icons.female},
      {'id': 'male', 'label': 'Male', 'icon': Icons.male},
    ];
    return Row(
      children: [
        for (final o in opts) ...[
          Expanded(
            child: InkWell(
              onTap: () => setState(() => _gender = o['id'] as String),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  color: _gender == o['id']
                      ? AppColors.violet.withOpacity(0.18)
                      : AppColors.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _gender == o['id'] ? AppColors.violet : AppColors.border,
                    width: _gender == o['id'] ? 1.5 : 1,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      o['icon'] as IconData,
                      size: 16,
                      color: _gender == o['id'] ? AppColors.violet : Colors.white60,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      o['label'] as String,
                      style: AppFonts.base(
                        size: 12,
                        weight: FontWeight.w700,
                        color: _gender == o['id'] ? Colors.white : Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (o != opts.last) const SizedBox(width: 8),
        ],
      ],
    );
  }

  Widget _rolePicker() {
    final opts = [
      {'id': 'customer', 'label': 'Book a service', 'icon': Icons.shopping_bag_outlined},
      {'id': 'provider', 'label': 'Offer a service', 'icon': Icons.build_outlined},
    ];
    return Row(
      children: [
        for (final o in opts) ...[
          Expanded(
            child: InkWell(
              onTap: () => setState(() => _role = o['id'] as String),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  color: _role == o['id']
                      ? AppColors.violet.withOpacity(0.18)
                      : AppColors.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _role == o['id'] ? AppColors.violet : AppColors.border,
                    width: _role == o['id'] ? 1.5 : 1,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      o['icon'] as IconData,
                      size: 16,
                      color: _role == o['id'] ? AppColors.violet : Colors.white60,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      o['label'] as String,
                      style: AppFonts.base(
                        size: 12,
                        weight: FontWeight.w700,
                        color: _role == o['id'] ? Colors.white : Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (o != opts.last) const SizedBox(width: 8),
        ],
      ],
    );
  }

  Widget _otpUI() => Expanded(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Verify your number',
                  style: AppFonts.base(size: 24, weight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text(
                'Code sent to ${widget.auth.pendingPhoneE164}',
                style: AppFonts.base(size: 13, color: Colors.white60),
              ),
              const SizedBox(height: 24),
              _field(
                label: '6-digit code',
                child: TextField(
                  controller: _otpCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                  style: AppFonts.mono(size: 22, color: Colors.white).copyWith(
                      letterSpacing: 12, fontWeight: FontWeight.w700),
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    hintText: '••••••',
                    hintStyle: AppFonts.mono(size: 22, color: Colors.white24)
                        .copyWith(letterSpacing: 12),
                    filled: true,
                    fillColor: AppColors.surface,
                    isDense: false,
                    contentPadding: const EdgeInsets.symmetric(vertical: 18),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: AppColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: AppColors.violet),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _errBox(),
              const SizedBox(height: 12),
              _primaryButton('Verify', _busy ? null : _verifyOtp),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () {
                            widget.auth.cancelOtp();
                            _otpCtrl.clear();
                          },
                    child: Text('Change phone number',
                        style: AppFonts.base(size: 12, color: Colors.white60)),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _field({required String label, required Widget child}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(),
              style: AppFonts.mono(size: 10, color: Colors.white54).copyWith(letterSpacing: 1.2)),
          const SizedBox(height: 6),
          child,
        ],
      );

  Widget _errBox() {
    if (_errMsg == null || _errMsg!.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.redAccent.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
      ),
      child: Row(children: [
        const Icon(Icons.error_outline, color: Colors.redAccent, size: 14),
        const SizedBox(width: 6),
        Expanded(
          child: Text(_errMsg!,
              style: AppFonts.base(size: 11.5, color: Colors.white)),
        ),
      ]),
    );
  }

  Widget _phoneInput() => Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: Text('+92',
                style: AppFonts.base(size: 14, weight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _textField(_phoneCtrl,
                hint: '3001234567', keyboard: TextInputType.phone),
          ),
        ],
      );

  Widget _textField(TextEditingController c,
          {String? hint, TextInputType? keyboard}) =>
      TextField(
        controller: c,
        keyboardType: keyboard,
        inputFormatters: [
          if (keyboard == TextInputType.phone) ...[
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(10),
          ],
        ],
        style: AppFonts.base(size: 14),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: AppFonts.base(size: 13, color: Colors.white38),
          filled: true,
          fillColor: AppColors.surface,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: AppColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: AppColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: AppColors.violet),
          ),
        ),
      );

  Widget _languagePicker() {
    const opts = [
      {'id': 'en', 'label': 'English'},
      {'id': 'roman_ur', 'label': 'Roman Urdu'},
      {'id': 'ur', 'label': 'اردو'},
    ];
    return Wrap(
      spacing: 8,
      children: opts.map((o) {
        final selected = _language == o['id'];
        return ChoiceChip(
          label: Text(o['label']!,
              style: AppFonts.base(
                size: 12,
                color: selected ? Colors.white : Colors.white70,
                weight: selected ? FontWeight.w700 : FontWeight.w500,
              )),
          selected: selected,
          onSelected: (_) => setState(() => _language = o['id']!),
          backgroundColor: AppColors.surface,
          selectedColor: AppColors.violet.withOpacity(0.6),
          side: BorderSide(color: selected ? AppColors.violet : AppColors.border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        );
      }).toList(),
    );
  }

  Widget _primaryButton(String label, VoidCallback? onTap) => SizedBox(
        width: double.infinity,
        height: 48,
        child: ElevatedButton(
          onPressed: onTap,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.violet,
            foregroundColor: Colors.white,
            disabledBackgroundColor: AppColors.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            elevation: 0,
          ),
          child: _busy
              ? const SizedBox(
                  width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : Text(label,
                  style: AppFonts.base(size: 14, weight: FontWeight.w700)),
        ),
      );
}
