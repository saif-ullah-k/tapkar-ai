import 'package:flutter/material.dart';
import '../i18n.dart';
import '../state/app_state.dart';
import '../state/auth_state.dart';
import '../theme.dart';
import '../services/provider_api.dart';
import 'provider_onboarding_screen.dart';
import 'role_picker_screen.dart';

/// User profile + settings + mode toggle.
class ProfileScreen extends StatelessWidget {
  final AppState state;
  const ProfileScreen({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state.auth,
      builder: (_, __) {
        final t = T(state.auth.language);
        return Scaffold(
          backgroundColor: AppColors.bg,
          appBar: AppBar(
            backgroundColor: AppColors.bg,
            elevation: 0,
            title: Text(t.profileTitle,
                style: AppFonts.base(size: 17, weight: FontWeight.w700)),
          ),
          body: SafeArea(child: _body(context, t)),
        );
      },
    );
  }

  Widget _body(BuildContext context, T t) {
    final auth = state.auth;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        _header(auth, t),
        const SizedBox(height: 12),
        _modeCard(context, auth, t),
        _section(t.profileSectionAccount),
        _tile(
          icon: Icons.translate,
          label: t.profileLanguage,
          trailing: _langLabel(auth.language),
          onTap: () => _pickLanguage(context, auth),
        ),
        _tile(
          icon: Icons.location_on_outlined,
          label: t.profileSavedAddresses,
          trailing: t.profileComingSoon,
          enabled: false,
        ),
        _tile(
          icon: Icons.payment_outlined,
          label: t.profilePaymentMethods,
          trailing: t.profileComingSoon,
          enabled: false,
        ),
        _section(t.profileSectionApp),
        _tile(
          icon: Icons.notifications_outlined,
          label: t.profileNotifications,
          trailing: t.profileOn,
          enabled: false,
        ),
        _tile(
          icon: Icons.help_outline,
          label: t.profileHelp,
          enabled: false,
        ),
        _tile(
          icon: Icons.info_outline,
          label: t.profileAbout,
          trailing: 'v0.1.0',
        ),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton.icon(
            onPressed: () => _confirmLogout(context, auth, t),
            icon: const Icon(Icons.logout_rounded, size: 16, color: Colors.redAccent),
            label: Text(t.profileLogout,
                style: AppFonts.base(size: 13, weight: FontWeight.w700, color: Colors.redAccent)),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: Colors.redAccent.withOpacity(0.4)),
              minimumSize: const Size.fromHeight(46),
            ),
          ),
        ),
        const SizedBox(height: 24),
        Center(
          child: Text(t.profileFooter,
              style: AppFonts.mono(size: 9, color: Colors.white24)),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _header(AuthState auth, T t) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: AppColors.violet.withOpacity(0.18),
              child: Text(_initials(auth.displayName),
                  style: AppFonts.base(size: 16, weight: FontWeight.w800, color: AppColors.violet)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(auth.displayName.isEmpty ? 'TapKar User' : auth.displayName,
                      style: AppFonts.base(size: 17, weight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(auth.phone.isEmpty ? '+92 ••• ••••••' : '+92 ${auth.phone}',
                      style: AppFonts.base(size: 12, color: Colors.white60)),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: auth.isProviderMode
                          ? AppColors.followup.withOpacity(0.18)
                          : AppColors.violet.withOpacity(0.18),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      auth.isProviderMode ? t.profileProviderMode : t.profileCustomerMode,
                      style: AppFonts.mono(
                        size: 9,
                        color: auth.isProviderMode ? AppColors.followup : AppColors.violet,
                      ).copyWith(letterSpacing: 1.3, fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _modeCard(BuildContext context, AuthState auth, T t) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              AppColors.followup.withOpacity(0.18),
              AppColors.violet.withOpacity(0.12),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.followup.withOpacity(0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.swap_horiz, color: AppColors.followup, size: 18),
              const SizedBox(width: 8),
              Text(t.providerEarnTitle,
                  style: AppFonts.base(size: 14, weight: FontWeight.w700)),
            ]),
            const SizedBox(height: 6),
            Text(
              t.providerEarnSubtitle,
              style: AppFonts.base(size: 12, color: Colors.white.withOpacity(0.8)),
            ),
            const SizedBox(height: 10),
            Row(children: [
              ElevatedButton.icon(
                onPressed: () => _pickProvider(context, auth),
                icon: const Icon(Icons.business_center_outlined, size: 14),
                label: Text(t.providerSwitchTo),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.followup,
                  foregroundColor: Colors.white,
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _section(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
        child: Text(label.toUpperCase(),
            style: AppFonts.mono(size: 10, color: Colors.white54).copyWith(letterSpacing: 1.4)),
      );

  Widget _tile({
    required IconData icon,
    required String label,
    String? trailing,
    VoidCallback? onTap,
    bool enabled = true,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: enabled ? Colors.white70 : Colors.white30, size: 18),
              const SizedBox(width: 12),
              Expanded(
                child: Text(label,
                    style: AppFonts.base(
                      size: 13,
                      weight: FontWeight.w500,
                      color: enabled ? Colors.white : Colors.white38,
                    )),
              ),
              if (trailing != null)
                Text(trailing,
                    style: AppFonts.base(size: 11, color: Colors.white54)),
              if (enabled && onTap != null) ...[
                const SizedBox(width: 6),
                const Icon(Icons.arrow_forward_ios, size: 11, color: Colors.white38),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _langLabel(String l) {
    switch (l) {
      case 'ur':
        return 'اردو';
      case 'roman_ur':
        return 'Roman Urdu';
      case 'en':
      default:
        return 'English';
    }
  }

  String _initials(String name) {
    if (name.isEmpty) return '👤';
    final parts = name.trim().split(RegExp(r'\s+'));
    return parts.take(2).map((p) => p.isEmpty ? '' : p[0].toUpperCase()).join();
  }

  void _pickLanguage(BuildContext context, AuthState auth) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final l in const [
              {'id': 'en', 'label': 'English'},
              {'id': 'roman_ur', 'label': 'Roman Urdu'},
              {'id': 'ur', 'label': 'اردو'},
            ])
              ListTile(
                title: Text(l['label']!),
                trailing: auth.language == l['id']
                    ? const Icon(Icons.check, color: AppColors.intent)
                    : null,
                onTap: () {
                  auth.setLanguage(l['id']!);
                  Navigator.pop(context);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// "Switch to provider" handler. Behavior depends on what's already linked
  /// to this Firebase user:
  ///   1. They already registered a provider → switch into that profile
  ///      directly (main.dart's AnimatedBuilder swaps to ProviderShell).
  ///   2. They haven't registered yet → open the onboarding wizard.
  void _pickProvider(BuildContext context, AuthState auth) async {
    final api = ProviderApi();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    Map<String, dynamic>? existing;
    try {
      existing = await api.findProviderByUser(auth.userId);
    } catch (_) {
      existing = null;
    }
    if (!context.mounted) return;
    Navigator.of(context).pop(); // close loader

    if (existing != null) {
      final p = existing['provider'] as Map<String, dynamic>?;
      if (p != null) {
        await auth.switchToProvider(
          providerId: p['id'] as String,
          providerName: p['name'] as String? ?? '?',
          providerCategory: p['category'] as String?,
        );
        return; // main.dart re-routes to ProviderShell
      }
    }
    // No provider profile yet — open the onboarding wizard
    if (!context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ProviderOnboardingScreen(auth: auth),
    ));
  }

  /// Kept for legacy: old "log in as any provider" test picker. Not wired
  /// to the main Switch-to-provider button anymore, but exposed via
  /// long-press for demo purposes.
  // ignore: unused_element
  void _openLegacyRolePicker(BuildContext context, AuthState auth) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RolePickerScreen(
        auth: auth,
        onCancel: () => Navigator.of(context).pop(),
      ),
    ));
  }

  void _confirmLogout(BuildContext context, AuthState auth, T t) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(t.profileLogoutTitle),
        content: Text(t.profileLogoutSubtitle),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(t.cancel)),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await auth.signOut();
            },
            child: Text(t.profileLogout, style: const TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }
}
