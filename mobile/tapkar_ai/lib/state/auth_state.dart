import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppMode { customer, provider }

/// Phone-OTP auth via Firebase Phone Auth, with local persistence of the
/// user's name + language preference + mode.
class AuthState extends ChangeNotifier {
  static const _kSignedIn = 'auth.signed_in';
  static const _kName = 'auth.name';
  static const _kPhone = 'auth.phone';
  static const _kUserId = 'auth.user_id';
  static const _kLanguage = 'auth.language';
  static const _kMode = 'auth.mode';
  static const _kProviderId = 'auth.provider_id';
  static const _kProviderName = 'auth.provider_name';
  static const _kProviderCategory = 'auth.provider_category';
  static const _kSignupRole = 'auth.signup_role';
  static const _kGender = 'auth.gender';

  final FirebaseAuth _firebase = FirebaseAuth.instance;

  bool _signedIn = false;
  String _name = '';
  String _phone = '';
  String _userId = '';
  String _language = 'en';
  /// 'female' | 'male' | 'other' — captured at signup. Drives bot TTS voice
  /// gender automatically (no separate "voice gender" toggle in settings).
  String _gender = 'female';
  AppMode _mode = AppMode.customer;
  String? _providerId;
  String? _providerName;
  String? _providerCategory;
  bool _loaded = false;

  // OTP flow state — pending verificationId between "send OTP" and "verify OTP"
  String? _pendingVerificationId;
  String _pendingName = '';
  String _pendingPhoneE164 = '';
  String _pendingLanguage = 'en';
  String _pendingGender = 'female'; // captured on the sign-up form
  String _pendingRole = 'customer'; // 'customer' | 'provider' — chosen on signup
  bool _isSignUp = false;
  /// The role the user picked on their original signup. Drives routing after
  /// login: if 'provider' and no provider profile exists yet, show onboarding.
  String _signupRole = 'customer';

  bool get signedIn => _signedIn;
  bool get loaded => _loaded;
  String get name => _name;
  String get phone => _phone;
  String get userId => _userId;
  String get language => _language;
  String get gender => _gender; // 'female' | 'male' | 'other'
  AppMode get mode => _mode;
  String? get providerId => _providerId;
  String? get providerName => _providerName;
  String? get providerCategory => _providerCategory;
  bool get isProviderMode => _mode == AppMode.provider && _providerId != null;
  String get displayName => isProviderMode ? (_providerName ?? _name) : _name;
  bool get otpInFlight => _pendingVerificationId != null;
  String get pendingPhoneE164 => _pendingPhoneE164;
  String get signupRole => _signupRole; // 'customer' | 'provider'

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _signedIn = p.getBool(_kSignedIn) ?? false;
    _name = p.getString(_kName) ?? '';
    _phone = p.getString(_kPhone) ?? '';
    _userId = p.getString(_kUserId) ?? '';
    _language = p.getString(_kLanguage) ?? 'en';
    _mode = (p.getString(_kMode) == 'provider') ? AppMode.provider : AppMode.customer;
    _providerId = p.getString(_kProviderId);
    _providerName = p.getString(_kProviderName);
    _providerCategory = p.getString(_kProviderCategory);
    _signupRole = p.getString(_kSignupRole) ?? 'customer';
    _gender = p.getString(_kGender) ?? 'female';

    // Cross-check with Firebase — if Firebase says we're signed in but local
    // says no (or vice versa), trust Firebase.
    final fbUser = _firebase.currentUser;
    if (fbUser != null && _signedIn == false) {
      _signedIn = true;
      _userId = fbUser.uid;
      _phone = fbUser.phoneNumber?.replaceFirst('+92', '') ?? _phone;
      await p.setBool(_kSignedIn, true);
      await p.setString(_kUserId, _userId);
    } else if (fbUser == null && _signedIn) {
      _signedIn = false;
      await p.setBool(_kSignedIn, false);
    }

    _loaded = true;
    notifyListeners();
  }

  /// Step 1 of OTP flow: send the SMS code.
  /// `phone10Digit` is the local part (e.g. "3001234567" — we prefix +92).
  /// Returns null on success, or an error message string.
  Future<String?> sendOtp({
    required String phone10Digit,
    required bool isSignUp,
    String name = '',
    String language = 'en',
    String gender = 'female',
    String role = 'customer',
  }) async {
    final phoneE164 = '+92${phone10Digit.replaceAll(RegExp(r'^0'), '').trim()}';
    final completer = Completer<String?>();
    _pendingPhoneE164 = phoneE164;
    _pendingName = name;
    _pendingLanguage = language;
    _pendingGender = gender;
    _pendingRole = role;
    _isSignUp = isSignUp;

    // Bypass Play Integrity (which rejects sideloaded debug APKs with
    // "Invalid app info in play_integrity_token"). Falls back to reCAPTCHA.
    try {
      await _firebase.setSettings(forceRecaptchaFlow: true);
    } catch (_) {}

    await _firebase.verifyPhoneNumber(
      phoneNumber: phoneE164,
      timeout: const Duration(seconds: 60),
      verificationCompleted: (PhoneAuthCredential cred) async {
        // Android auto-retrieval — sign in immediately if SMS code arrived
        try {
          await _firebase.signInWithCredential(cred);
          await _persistAfterSignIn();
          if (!completer.isCompleted) completer.complete(null);
        } catch (e) {
          if (!completer.isCompleted) completer.complete(e.toString());
        }
      },
      verificationFailed: (FirebaseAuthException e) {
        final friendly = _friendlyAuthError(e);
        if (!completer.isCompleted) completer.complete(friendly);
      },
      codeSent: (String verificationId, int? _) {
        _pendingVerificationId = verificationId;
        notifyListeners();
        if (!completer.isCompleted) completer.complete(null);
      },
      codeAutoRetrievalTimeout: (String verificationId) {
        _pendingVerificationId = verificationId;
      },
    );

    return completer.future;
  }

  /// Step 2 of OTP flow: verify the 6-digit code.
  /// Returns null on success, or an error message string.
  Future<String?> verifyOtp(String code) async {
    if (_pendingVerificationId == null) {
      return 'No OTP session in progress. Re-send the code.';
    }
    try {
      final cred = PhoneAuthProvider.credential(
        verificationId: _pendingVerificationId!,
        smsCode: code.trim(),
      );
      await _firebase.signInWithCredential(cred);
      await _persistAfterSignIn();
      return null;
    } on FirebaseAuthException catch (e) {
      return _friendlyAuthError(e);
    } catch (e) {
      return e.toString();
    }
  }

  /// After Firebase sign-in succeeds, write our local profile.
  Future<void> _persistAfterSignIn() async {
    final fbUser = _firebase.currentUser;
    if (fbUser == null) return;
    final p = await SharedPreferences.getInstance();
    _userId = fbUser.uid;
    _phone = _pendingPhoneE164.replaceFirst('+92', '');
    if (_isSignUp && _pendingName.isNotEmpty) {
      _name = _pendingName;
    } else if (_name.isEmpty) {
      _name = p.getString(_kName) ?? '';
    }
    _language = _pendingLanguage.isNotEmpty ? _pendingLanguage : _language;
    if (_isSignUp && _pendingGender.isNotEmpty) _gender = _pendingGender;
    _signedIn = true;
    // Default mode: customer for new sign-ups. main.dart will flip to provider
    // mode (and route through onboarding) when _signupRole == 'provider'.
    _mode = AppMode.customer;
    if (_isSignUp) {
      _signupRole = _pendingRole.isNotEmpty ? _pendingRole : 'customer';
    }
    _pendingVerificationId = null;
    _pendingName = '';
    _pendingPhoneE164 = '';
    await p.setBool(_kSignedIn, true);
    await p.setString(_kUserId, _userId);
    await p.setString(_kName, _name);
    await p.setString(_kPhone, _phone);
    await p.setString(_kLanguage, _language);
    await p.setString(_kGender, _gender);
    await p.setString(_kMode, 'customer');
    await p.setString(_kSignupRole, _signupRole);
    notifyListeners();
  }

  /// Cancel the in-flight OTP session (e.g. user backs out).
  void cancelOtp() {
    _pendingVerificationId = null;
    _pendingPhoneE164 = '';
    _pendingName = '';
    notifyListeners();
  }

  Future<void> signOut() async {
    try {
      await _firebase.signOut();
    } catch (_) {}
    final p = await SharedPreferences.getInstance();
    await p.clear();
    _signedIn = false;
    _name = '';
    _phone = '';
    _userId = '';
    _mode = AppMode.customer;
    _providerId = null;
    _providerName = null;
    _providerCategory = null;
    _pendingVerificationId = null;
    notifyListeners();
  }

  Future<void> setLanguage(String lang) async {
    _language = lang;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kLanguage, lang);
    notifyListeners();
  }

  Future<void> switchToProvider({
    required String providerId,
    required String providerName,
    String? providerCategory,
  }) async {
    _mode = AppMode.provider;
    _providerId = providerId;
    _providerName = providerName;
    _providerCategory = providerCategory;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kMode, 'provider');
    await p.setString(_kProviderId, providerId);
    await p.setString(_kProviderName, providerName);
    if (providerCategory != null) await p.setString(_kProviderCategory, providerCategory);
    notifyListeners();
  }

  Future<void> switchToCustomer() async {
    _mode = AppMode.customer;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kMode, 'customer');
    notifyListeners();
  }

  String _friendlyAuthError(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-phone-number':
        return 'Invalid phone number. Use Pakistani format like 3001234567.';
      case 'too-many-requests':
        return 'Too many attempts. Try again in a minute.';
      case 'invalid-verification-code':
        return 'Wrong code. Check the SMS and try again.';
      case 'session-expired':
        return 'Code expired. Tap "Resend".';
      case 'missing-verification-code':
        return 'Please enter the 6-digit code.';
      case 'quota-exceeded':
        return 'OTP quota reached for today. Try again tomorrow.';
      case 'app-not-authorized':
        return 'App fingerprint not whitelisted in Firebase Console.';
      default:
        return e.message ?? e.code;
    }
  }
}
