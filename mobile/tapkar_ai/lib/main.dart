import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'firebase_options.dart';
import 'screens/auth_screen.dart';
import 'screens/main_shell.dart';
import 'screens/provider_chat_setup_screen.dart';
import 'screens/provider_shell.dart';
import 'services/notifications.dart';
import 'services/provider_api.dart';
import 'state/app_state.dart';
import 'state/auth_state.dart';
import 'theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Fire-and-forget — notifications are an enhancement, not blocking.
  // Permission prompt happens on first init on Android 13+.
  Notifications.instance.init();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.bg,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const TapKarApp());
}

class TapKarApp extends StatefulWidget {
  const TapKarApp({super.key});

  @override
  State<TapKarApp> createState() => _TapKarAppState();
}

class _TapKarAppState extends State<TapKarApp> {
  late final AuthState _auth;
  late final AppState _state;
  final ProviderApi _providerApi = ProviderApi();

  /// Per-user-id resolution of: does this Firebase user already have a
  /// registered provider profile? null = unknown / not signed in.
  bool? _hasProviderProfile;
  String? _resolvingForUserId;

  @override
  void initState() {
    super.initState();
    _auth = AuthState();
    _state = AppState(auth: _auth);
    _auth.load();
    _auth.addListener(_maybeResolveProviderProfile);
  }

  @override
  void dispose() {
    _auth.removeListener(_maybeResolveProviderProfile);
    _state.dispose();
    _auth.dispose();
    super.dispose();
  }

  /// When a provider-role user signs in, look up their existing profile so
  /// returning providers skip onboarding and jump to the provider shell.
  Future<void> _maybeResolveProviderProfile() async {
    if (!_auth.signedIn) {
      _hasProviderProfile = null;
      _resolvingForUserId = null;
      return;
    }
    if (_auth.signupRole != 'provider') return; // customer — no lookup
    if (_auth.providerId != null) return; // already wired into provider mode
    if (_resolvingForUserId == _auth.userId) return; // in flight
    _resolvingForUserId = _auth.userId;
    try {
      final result = await _providerApi.findProviderByUser(_auth.userId);
      if (result == null) {
        _hasProviderProfile = false;
      } else {
        final p = result['provider'] as Map<String, dynamic>?;
        if (p != null) {
          await _auth.switchToProvider(
            providerId: p['id'] as String,
            providerName: p['name'] as String? ?? '?',
            providerCategory: p['category'] as String?,
          );
          _hasProviderProfile = true;
        }
      }
      if (mounted) setState(() {});
    } catch (_) {
      // Network issue — let the user retry; show onboarding for now since
      // sign-up said role=provider.
      _hasProviderProfile = false;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TapKar AI',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: AnimatedBuilder(
        animation: _auth,
        builder: (_, __) {
          if (!_auth.loaded) {
            // First-tick splash while we read SharedPreferences
            return const Scaffold(
              backgroundColor: AppColors.bg,
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (!_auth.signedIn) {
            return AuthScreen(
              auth: _auth,
              onAuthed: () {/* AnimatedBuilder rebuilds on notifyListeners */},
            );
          }
          // Provider-role signup but no profile yet → onboarding wizard.
          if (_auth.signupRole == 'provider' &&
              _auth.providerId == null) {
            if (_hasProviderProfile == null) {
              return const Scaffold(
                backgroundColor: AppColors.bg,
                body: Center(child: CircularProgressIndicator()),
              );
            }
            return ProviderChatSetupScreen(auth: _auth, mode: 'signup');
          }
          // Provider mode → 3-tab provider shell. Customer → 5-tab main shell.
          if (_auth.isProviderMode) {
            return ProviderShell(auth: _auth);
          }
          return MainShell(state: _state);
        },
      ),
    );
  }
}
