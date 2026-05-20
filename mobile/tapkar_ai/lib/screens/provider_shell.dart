import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../i18n.dart';
import '../services/notifications.dart';
import '../services/provider_api.dart';
import '../state/auth_state.dart';
import '../theme.dart';
import '../utils/time.dart';
import 'booking_chat_screen.dart';
import 'provider_chat_setup_screen.dart';
import 'provider_onboarding_screen.dart';
import 'voice_live_screen.dart';

/// Top-level shell shown when the user is signed in as a provider.
/// 3 tabs: Jobs (incoming bookings), Messages, Profile (switch back from here).
class ProviderShell extends StatefulWidget {
  final AuthState auth;
  const ProviderShell({super.key, required this.auth});

  @override
  State<ProviderShell> createState() => _ProviderShellState();
}

class _ProviderShellState extends State<ProviderShell> {
  int _index = 0;
  late final List<Widget> _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = [
      _ProviderJobsTab(auth: widget.auth),
      _ProviderMessagesTab(auth: widget.auth),
      _ProviderAssistTab(auth: widget.auth),
      _ProviderProfileTab(auth: widget.auth),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.auth,
      builder: (_, __) {
        final t = T(widget.auth.language);
        return Scaffold(
          backgroundColor: AppColors.bg,
          body: IndexedStack(index: _index, children: _tabs),
          bottomNavigationBar: _BottomNav(
            index: _index,
            onTap: (i) => setState(() => _index = i),
            t: t,
          ),
        );
      },
    );
  }
}

class _BottomNav extends StatelessWidget {
  final int index;
  final ValueChanged<int> onTap;
  final T t;
  const _BottomNav({required this.index, required this.onTap, required this.t});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(
            children: [
              _NavItem(
                label: t.navJobs,
                icon: Icons.work_outline_rounded,
                activeIcon: Icons.work_rounded,
                selected: index == 0,
                onTap: () => onTap(0),
                accent: AppColors.followup,
              ),
              _NavItem(
                label: t.navMessages,
                icon: Icons.notifications_none_rounded,
                activeIcon: Icons.notifications_rounded,
                selected: index == 1,
                onTap: () => onTap(1),
                accent: AppColors.followup,
              ),
              _NavCenterItem(
                label: t.navAskAi,
                selected: index == 2,
                onTap: () => onTap(2),
              ),
              _NavItem(
                label: t.navProfile,
                icon: Icons.person_outline_rounded,
                activeIcon: Icons.person_rounded,
                selected: index == 3,
                onTap: () => onTap(3),
                accent: AppColors.followup,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final String label;
  final IconData icon;
  final IconData activeIcon;
  final bool selected;
  final VoidCallback onTap;
  final Color accent;
  const _NavItem({
    required this.label,
    required this.icon,
    required this.activeIcon,
    required this.selected,
    required this.onTap,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? accent : Colors.white60;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(selected ? activeIcon : icon, color: color, size: 22),
              const SizedBox(height: 3),
              Text(
                label,
                style: AppFonts.base(
                  size: 10,
                  color: color,
                  weight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Highlighted center tab — gradient orb. Same visual treatment as the
/// customer-side Ask AI button so providers get the same affordance.
class _NavCenterItem extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _NavCenterItem({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 38, height: 38,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppColors.violet, AppColors.booking],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  shape: BoxShape.circle,
                  boxShadow: selected
                      ? [BoxShadow(color: AppColors.violet.withOpacity(0.5), blurRadius: 16)]
                      : null,
                ),
                child: const Icon(Icons.auto_awesome, color: Colors.white, size: 20),
              ),
              const SizedBox(height: 2),
              Text(label,
                  style: AppFonts.base(
                    size: 10,
                    color: selected ? AppColors.violet : Colors.white70,
                    weight: FontWeight.w700,
                  )),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── Jobs tab ─────────────────────────

class _ProviderJobsTab extends StatefulWidget {
  final AuthState auth;
  const _ProviderJobsTab({required this.auth});

  @override
  State<_ProviderJobsTab> createState() => _ProviderJobsTabState();
}

class _ProviderJobsTabState extends State<_ProviderJobsTab> {
  final ProviderApi _api = ProviderApi();
  List<Map<String, dynamic>> _bookings = [];
  bool _loading = true;
  String? _error;
  /// Provider's "online — accepting jobs" flag. Default ON. Persisted to
  /// the backend; discovery filters out OFF providers.
  bool _availableNow = true;
  bool _togglingAvailability = false;
  /// Auto-refresh while the tab is visible. 3 s tick — keeps the jobs
  /// list real-time-ish so providers see new bookings without manual
  /// pull-to-refresh. Tracked id-set so we can fire a notification when
  /// a brand-new booking lands.
  Timer? _pollTimer;
  Set<String> _knownBookingIds = const {};
  /// Map of bookingId → last-seen-chat-message-id. After each booking
  /// poll we fetch /bookings/:id/messages for each active job and look
  /// for entries newer than what's here. Any new message from='user'
  /// fires a notification.
  final Map<String, String> _lastSeenMsgIdByBooking = {};

  @override
  void initState() {
    super.initState();
    _load();
    _hydrateAvailability();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) _load(silent: true);
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _hydrateAvailability() async {
    try {
      final result = await _api.findProviderByUser(widget.auth.userId);
      final p = result?['provider'] as Map<String, dynamic>?;
      final flag = p?['available_now'] as bool?;
      if (flag != null && mounted) setState(() => _availableNow = flag);
    } catch (_) {/* default ON */}
  }

  Future<void> _toggleAvailability(bool next) async {
    setState(() {
      _availableNow = next; // optimistic
      _togglingAvailability = true;
    });
    try {
      final confirmed = await _api.setAvailability(
        providerId: widget.auth.providerId!,
        userId: widget.auth.userId,
        availableNow: next,
      );
      if (mounted) setState(() => _availableNow = confirmed);
    } catch (e) {
      if (mounted) {
        setState(() => _availableNow = !next); // revert
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not update: $e')));
      }
    } finally {
      if (mounted) setState(() => _togglingAvailability = false);
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final bookings = await _api.listMyBookings(widget.auth.providerId!);
      // Fire a local notification for any booking we haven't seen before
      // (skip the very first load — that's just hydration, not "new").
      if (_knownBookingIds.isNotEmpty) {
        for (final b in bookings) {
          final id = b['id'] as String?;
          if (id != null && !_knownBookingIds.contains(id)) {
            final cat = (b['service_category_id'] as String?) ?? 'service';
            final time = (b['time_iso'] as String?) ?? '';
            Notifications.instance.newJobReceived(
              category: cat,
              timeIso: time,
            );
          }
        }
      }
      _knownBookingIds = bookings
          .map((b) => b['id'] as String?)
          .whereType<String>()
          .toSet();
      if (mounted) {
        setState(() {
          _bookings = bookings;
          _loading = false;
        });
      }
      // Background chat-poll: for each active booking, check for new
      // messages from the customer. Skips terminal states (cancelled /
      // completed) to keep request count bounded.
      _pollMessagesForBookings(bookings);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _pollMessagesForBookings(List<Map<String, dynamic>> bookings) async {
    const apiUrl = String.fromEnvironment(
      'API_URL',
      defaultValue: 'https://tapkar-ai-backend-d56rhra4sa-uc.a.run.app',
    );
    for (final b in bookings) {
      final id = b['id'] as String?;
      if (id == null) continue;
      final st = (b['status'] as String?) ?? '';
      if (st == 'cancelled' || st == 'completed' || st == 'no_show') continue;
      try {
        final r = await http.get(Uri.parse('$apiUrl/bookings/$id/messages'))
            .timeout(const Duration(seconds: 5));
        if (r.statusCode != 200) continue;
        final data = jsonDecode(r.body) as Map<String, dynamic>;
        final msgs = (data['messages'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .toList() ??
            const <Map<String, dynamic>>[];
        if (msgs.isEmpty) continue;
        final latest = msgs.last;
        final latestId = latest['id'] as String?;
        if (latestId == null) continue;
        final previous = _lastSeenMsgIdByBooking[id];
        _lastSeenMsgIdByBooking[id] = latestId;
        // First observation = hydrate, don't notify (old history would
        // ping a flood on app open).
        if (previous == null) continue;
        if (latestId == previous) continue;
        if (latest['from'] != 'user') continue; // ignore our own messages
        Notifications.instance.chatMessage(
          fromLabel: 'customer',
          preview: (latest['text'] as String?) ?? '',
        );
      } catch (_) {/* transient — try again next tick */}
    }
  }

  Future<void> _act(String bookingId, String action) async {
    try {
      await _api.updateBooking(
        providerId: widget.auth.providerId!,
        bookingId: bookingId,
        action: action,
      );
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Booking marked: $action')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = T(widget.auth.language);
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.followup.withOpacity(0.2),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(t.providerBadge,
                style: AppFonts.mono(size: 9, color: AppColors.followup)
                    .copyWith(letterSpacing: 1.2, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(widget.auth.providerName ?? 'Provider',
                style: AppFonts.base(size: 15, weight: FontWeight.w700),
                overflow: TextOverflow.ellipsis),
          ),
        ]),
        actions: [
          // "Online / Off" availability toggle — drives backend discovery
          // filtering. When OFF, this provider is invisible in customer
          // searches even during their normal working hours.
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Row(children: [
              Text(
                _availableNow ? 'Online' : 'Off',
                style: AppFonts.base(
                  size: 11,
                  weight: FontWeight.w700,
                  color: _availableNow ? Colors.greenAccent : Colors.white38,
                ),
              ),
              Transform.scale(
                scale: 0.75,
                child: Switch(
                  value: _availableNow,
                  onChanged: _togglingAvailability ? null : _toggleAvailability,
                  activeColor: Colors.greenAccent,
                ),
              ),
            ]),
          ),
          // "Ask AI" — opens conversational profile editor. Provider
          // says "kal 10-12 nahi mein" / "price update karo" → AI
          // patches the draft. Mirrors the customer Ask-AI button.
          IconButton(
            icon: const Icon(Icons.auto_awesome, color: AppColors.violet, size: 20),
            tooltip: 'Ask AI to edit profile',
            onPressed: () async {
              final api = ProviderApi();
              Map<String, dynamic>? existing;
              try {
                final r = await api.findProviderByUser(widget.auth.userId);
                existing = r?['provider'] as Map<String, dynamic>?;
              } catch (_) {}
              if (!context.mounted) return;
              await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ProviderChatSetupScreen(
                  auth: widget.auth,
                  mode: 'edit',
                  existing: existing,
                ),
              ));
              if (mounted) _load();
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white60, size: 18),
            onPressed: _load,
          ),
        ],
      ),
      body: SafeArea(child: _body(t)),
    );
  }

  Widget _body(T t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
          const SizedBox(height: 12),
          Text(t.bookingsLoadFailed,
              style: AppFonts.base(size: 15, weight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(_error!,
              textAlign: TextAlign.center,
              style: AppFonts.base(size: 12, color: Colors.white60)),
          const SizedBox(height: 16),
          ElevatedButton(onPressed: _load, child: Text(t.retry)),
        ]),
      );
    }
    if (_bookings.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.inbox_outlined, size: 40, color: Colors.white30),
            const SizedBox(height: 12),
            Text(t.providerNoJobsTitle,
                style: AppFonts.base(size: 16, weight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              t.providerNoJobsSubtitle,
              textAlign: TextAlign.center,
              style: AppFonts.base(size: 12, color: Colors.white60),
            ),
          ]),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: _bookings.length,
        itemBuilder: (_, i) => _BookingCard(
          booking: _bookings[i],
          onAction: _act,
          providerOwnerId: widget.auth.providerId,
        ),
      ),
    );
  }
}

// ───────────────────────── Messages tab ─────────────────────────

/// Provider-side "Ask AI" tab — landing screen for the AI assistant.
/// Two big affordances: voice talk (Gemini Live) and AI chat (text-based
/// profile editor). Mirrors the customer side's ChatScreen but for the
/// provider's own profile-management needs.
class _ProviderAssistTab extends StatelessWidget {
  final AuthState auth;
  const _ProviderAssistTab({required this.auth});

  Future<void> _openChat(BuildContext context) async {
    final api = ProviderApi();
    Map<String, dynamic>? existing;
    try {
      final r = await api.findProviderByUser(auth.userId);
      existing = r?['provider'] as Map<String, dynamic>?;
    } catch (_) {}
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ProviderChatSetupScreen(
        auth: auth,
        mode: 'edit',
        existing: existing,
      ),
    ));
  }

  void _openVoice(BuildContext context) {
    // Reuses the customer voice screen — same Gemini Live bridge.
    // Plumbing for a provider-specific tool (edit_profile) is on the
    // backlog; for now this gives the provider the same booking-aware
    // assistant the customer has.
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => VoiceLiveScreen.forProvider(auth: auth),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: Text('Ask AI', style: AppFonts.base(size: 15, weight: FontWeight.w700)),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Kis tarah madad chahiye?',
                  style: AppFonts.base(size: 18, weight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('Voice se baat karein ya likh ke. Profile update karna ho, "kal off" mark karna ho, ya kuch bhi.',
                  style: AppFonts.base(size: 12, color: Colors.white60)),
              const SizedBox(height: 28),
              // Voice option — large gradient card, dominant.
              _AssistCard(
                title: 'Voice se baat karein',
                subtitle: 'Live mein bolo — AI sun raha hai.',
                icon: Icons.graphic_eq,
                gradient: const LinearGradient(
                  colors: [AppColors.violet, AppColors.booking],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                onTap: () => _openVoice(context),
              ),
              const SizedBox(height: 14),
              // Text chat option.
              _AssistCard(
                title: 'Likh ke chat karein',
                subtitle: 'Profile edit, off-day mark, prices update.',
                icon: Icons.chat_bubble_outline_rounded,
                gradient: const LinearGradient(
                  colors: [AppColors.booking, AppColors.ranking],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                onTap: () => _openChat(context),
              ),
              const Spacer(),
              Text(
                'Examples to say:\n'
                '• "Kal 10 se 12 nahi mein"\n'
                '• "Price update karo 2000 se 5000"\n'
                '• "Saturday off kar do"',
                style: AppFonts.base(size: 11, color: Colors.white38),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssistCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Gradient gradient;
  final VoidCallback onTap;
  const _AssistCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.gradient,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              width: 48, height: 48,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.18),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: Colors.white, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: AppFonts.base(size: 16, weight: FontWeight.w700, color: Colors.white)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: AppFonts.base(size: 12, color: Colors.white.withOpacity(0.85))),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white70, size: 22),
          ],
        ),
      ),
    );
  }
}

class _ProviderMessagesTab extends StatefulWidget {
  final AuthState auth;
  const _ProviderMessagesTab({required this.auth});

  @override
  State<_ProviderMessagesTab> createState() => _ProviderMessagesTabState();
}

class _ProviderMessagesTabState extends State<_ProviderMessagesTab> {
  final ProviderApi _api = ProviderApi();
  List<Map<String, dynamic>> _msgs = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final m = await _api.listMyInbox(widget.auth.providerId!);
      setState(() {
        _msgs = m;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = T(widget.auth.language);
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: Text(t.navMessages,
            style: AppFonts.base(size: 17, weight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white60, size: 18),
            onPressed: _load,
          ),
        ],
      ),
      body: SafeArea(child: _body(t)),
    );
  }

  Widget _body(T t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!,
              textAlign: TextAlign.center,
              style: AppFonts.base(size: 12, color: Colors.white60)),
        ),
      );
    }
    if (_msgs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.mark_email_read_outlined, size: 40, color: Colors.white30),
            const SizedBox(height: 12),
            Text(t.providerNoMessagesTitle,
                style: AppFonts.base(size: 16, weight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(t.providerNoMessagesSubtitle,
                textAlign: TextAlign.center,
                style: AppFonts.base(size: 12, color: Colors.white60)),
          ]),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: _msgs.length,
        itemBuilder: (_, i) {
          final m = _msgs[i];
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(m['text'] as String? ?? '?',
                style: AppFonts.base(size: 13)),
          );
        },
      ),
    );
  }
}

// ───────────────────────── Profile tab ─────────────────────────

class _ProviderProfileTab extends StatefulWidget {
  final AuthState auth;
  const _ProviderProfileTab({required this.auth});

  @override
  State<_ProviderProfileTab> createState() => _ProviderProfileTabState();
}

class _ProviderProfileTabState extends State<_ProviderProfileTab> {
  Map<String, dynamic>? _profile;
  bool _loading = true;

  AuthState get auth => widget.auth;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await ProviderApi().findProviderByUser(auth.userId);
      if (!mounted) return;
      setState(() {
        _profile = r?['provider'] as Map<String, dynamic>?;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _openEdit(BuildContext context) async {
    final api = ProviderApi();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    Map<String, dynamic>? existing;
    try {
      final r = await api.findProviderByUser(auth.userId);
      existing = r?['provider'] as Map<String, dynamic>?;
    } catch (_) {
      existing = null;
    }
    if (!context.mounted) return;
    Navigator.of(context).pop(); // close loader
    if (existing == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not load your profile')),
      );
      return;
    }
    // Edit profile via AI chat — same conversational flow as signup but in
    // 'edit' mode, pre-seeded with the existing profile.
    final updated = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => ProviderChatSetupScreen(
        auth: auth,
        mode: 'edit',
        existing: existing,
      ),
    ));
    // If the chat-edit returned true (saved), refresh the details panel.
    if (updated == true && mounted) await _load();
  }

  // Power-user fallback: open the old form-based editor.
  // ignore: unused_element
  Future<void> _openFormEditor(BuildContext context, Map<String, dynamic> existing) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ProviderOnboardingScreen(auth: auth, existing: existing),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = T(auth.language);
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: Text(t.profileTitle,
            style: AppFonts.base(size: 17, weight: FontWeight.w700)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: AppColors.followup.withOpacity(0.18),
                  child: Text(
                    _initials(auth.providerName ?? '?'),
                    style: AppFonts.base(size: 16, weight: FontWeight.w800, color: AppColors.followup),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(auth.providerName ?? 'Provider',
                          style: AppFonts.base(size: 17, weight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Text(_titleCase((auth.providerCategory ?? '').replaceAll('_', ' ')),
                          style: AppFonts.base(size: 12, color: Colors.white60)),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.followup.withOpacity(0.18),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          t.profileProviderMode,
                          style: AppFonts.mono(size: 9, color: AppColors.followup)
                              .copyWith(letterSpacing: 1.3, fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            // ─── Your details (loaded from backend) ─────────────────────
            _detailsCard(),
            const SizedBox(height: 12),
            // ─── Edit profile entry ──────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Material(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  onTap: () => _openEdit(context),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    child: Row(children: [
                      const Icon(Icons.edit_outlined, color: AppColors.followup, size: 18),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Edit profile via chat',
                                style: AppFonts.base(size: 14, weight: FontWeight.w700)),
                            const SizedBox(height: 2),
                            Text(
                              'Just tell the AI what to change — price, hours, areas, anything',
                              style: AppFonts.base(size: 11, color: Colors.white60),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.arrow_forward_ios, size: 12, color: Colors.white38),
                    ]),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      AppColors.violet.withOpacity(0.18),
                      AppColors.booking.withOpacity(0.12),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.violet.withOpacity(0.4)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Icon(Icons.swap_horiz, color: AppColors.violet, size: 18),
                      const SizedBox(width: 8),
                      Text(t.providerSwitchBackTitle,
                          style: AppFonts.base(size: 14, weight: FontWeight.w700)),
                    ]),
                    const SizedBox(height: 6),
                    Text(
                      t.providerSwitchBackSubtitle,
                      style: AppFonts.base(size: 12, color: Colors.white.withOpacity(0.8)),
                    ),
                    const SizedBox(height: 10),
                    ElevatedButton.icon(
                      onPressed: () => auth.switchToCustomer(),
                      icon: const Icon(Icons.arrow_back_rounded, size: 14),
                      label: Text(t.providerSwitchBackCta),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.violet,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(42),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
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
          ],
        ),
      ),
    );
  }

  String _initials(String name) {
    if (name.isEmpty) return '?';
    final parts = name.trim().split(RegExp(r'\s+'));
    return parts.take(2).map((p) => p.isEmpty ? '' : p[0].toUpperCase()).join();
  }

  /// Read-only card that surfaces all the fields the provider has captured
  /// so far — category, areas, hours, price, languages, gender, phone, bio.
  /// Loaded from `_profile` (refreshed after every successful chat-edit).
  Widget _detailsCard() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 18),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final p = _profile;
    if (p == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: Text(
          'Tap "Edit profile" below to set up your details.',
          style: AppFonts.base(size: 12, color: Colors.white60),
        ),
      );
    }

    final rows = <Widget>[];

    void addRow(IconData icon, String label, String value) {
      if (value.trim().isEmpty) return;
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: Colors.white54),
            const SizedBox(width: 10),
            SizedBox(
              width: 90,
              child: Text(label,
                  style: AppFonts.base(size: 11, color: Colors.white54, weight: FontWeight.w600)),
            ),
            Expanded(
              child: Text(value,
                  style: AppFonts.base(size: 13, color: Colors.white, weight: FontWeight.w500)),
            ),
          ],
        ),
      ));
    }

    final category = (p['category'] as String? ?? '').replaceAll('_', ' ');
    final extra = (p['additional_categories'] as List?)?.cast<String>() ?? const [];
    addRow(Icons.work_outline, 'Service',
        _titleCase('${category}${extra.isNotEmpty ? ' (+${extra.length} more)' : ''}'));

    final hood = (p['neighborhood'] as String?) ?? '';
    final areas = (p['service_areas'] as List?)?.cast<String>() ?? const [];
    final allAreas = [hood, ...areas].where((s) => s.isNotEmpty).toSet().join(', ');
    addRow(Icons.location_on_outlined, 'Areas', allAreas);

    final price = p['price_range_pkr'] as List?;
    if (price != null && price.length == 2) {
      addRow(Icons.currency_rupee, 'Price',
          'PKR ${price[0]} – ${price[1]}');
    }

    final hours = p['availability'] as Map?;
    if (hours != null) {
      final openDays = <String>[];
      const order = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];
      for (final d in order) {
        final ranges = (hours[d] as List?)?.cast<String>() ?? const [];
        if (ranges.isNotEmpty) {
          openDays.add('${d.substring(0, 3).toUpperCase()} ${ranges.join(', ')}');
        }
      }
      if (openDays.isNotEmpty) {
        addRow(Icons.schedule, 'Hours', openDays.join('\n'));
      }
    }

    // Date-specific availability exceptions (e.g. "kal 10-12 off").
    // Hidden if the provider hasn't set any.
    final overrides = (p['availability_overrides'] as List?) ?? const [];
    if (overrides.isNotEmpty) {
      final lines = overrides.map<String>((o) {
        if (o is! Map) return '';
        final date = o['date']?.toString() ?? '';
        final note = o['note']?.toString();
        final ovHours = (o['hours'] as List?)?.cast<String>() ?? const [];
        final hoursLabel =
            ovHours.isEmpty ? 'CLOSED ALL DAY' : ovHours.join(', ');
        return note != null && note.isNotEmpty
            ? '$date · $hoursLabel  ($note)'
            : '$date · $hoursLabel';
      }).where((s) => s.isNotEmpty).join('\n');
      if (lines.isNotEmpty) {
        addRow(Icons.event_busy, 'Date exceptions', lines);
      }
    }

    final langs = (p['languages'] as List?)?.cast<String>() ?? const [];
    if (langs.isNotEmpty) {
      final pretty = langs.map((l) {
        switch (l) {
          case 'ur':
            return 'Urdu';
          case 'roman_ur':
            return 'Roman Urdu';
          case 'en':
            return 'English';
          default:
            return l;
        }
      }).join(', ');
      addRow(Icons.translate, 'Languages', pretty);
    }

    final gender = (p['gender'] as String? ?? '').toLowerCase();
    if (gender.isNotEmpty) {
      addRow(Icons.person_outline, 'Gender', _titleCase(gender));
    }

    final phone = (p['phone'] as String?) ?? '';
    if (phone.isNotEmpty) addRow(Icons.phone_outlined, 'Phone', phone);

    final bio = (p['bio'] as String?) ?? '';
    if (bio.isNotEmpty) addRow(Icons.notes, 'Bio', bio);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.account_box_outlined, size: 16, color: AppColors.followup),
              const SizedBox(width: 6),
              Text('Your details',
                  style: AppFonts.base(size: 12, weight: FontWeight.w800, color: AppColors.followup)
                      .copyWith(letterSpacing: 1.2)),
              const Spacer(),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                icon: const Icon(Icons.refresh, size: 16, color: Colors.white54),
                onPressed: _load,
              ),
            ]),
            const SizedBox(height: 6),
            ...rows,
          ],
        ),
      ),
    );
  }

  String _titleCase(String s) =>
      s.split(' ').map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');

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

// ───────────────────────── Booking card (provider) ─────────────────────────

class _BookingCard extends StatelessWidget {
  final Map<String, dynamic> booking;
  final Future<void> Function(String bookingId, String action) onAction;
  /// Provider's own id from AuthState — fallback for the chat button
  /// when the booking record didn't include a provider_id (rare, but
  /// the chat POST schema rejects empty sender_id).
  final String? providerOwnerId;

  const _BookingCard({
    required this.booking,
    required this.onAction,
    this.providerOwnerId,
  });

  @override
  Widget build(BuildContext context) {
    final id = booking['id'] as String;
    final status = (booking['status'] as String?) ?? 'pending';
    final timeIso = booking['time_iso'] as String?;
    final category = booking['service_category_id'] as String?;
    final location = (booking['location'] as Map?)?['label'] as String?;
    final notes = booking['notes'] as String?;
    final price = (booking['estimated_price_pkr'] as List?)?.cast<int>();

    final accent = _accentForStatus(status);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: accent.withOpacity(0.45)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: accent.withOpacity(0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(status.toUpperCase(),
                  style: AppFonts.mono(size: 9, color: accent).copyWith(
                      letterSpacing: 1.2, fontWeight: FontWeight.w700)),
            ),
            const Spacer(),
            Text(id, style: AppFonts.mono(size: 10, color: Colors.white38)),
          ]),
          const SizedBox(height: 10),
          if (category != null)
            Text(
              '${_titleCase(category.replaceAll('_', ' '))}'
              '${location != null ? '  ·  $location' : ''}',
              style: AppFonts.base(size: 14, weight: FontWeight.w600),
            ),
          if (timeIso != null) ...[
            const SizedBox(height: 3),
            Text(_formatWhen(timeIso), style: AppFonts.base(size: 13, color: Colors.white70)),
          ],
          if (price != null && price.length == 2) ...[
            const SizedBox(height: 3),
            Text('Estimated: PKR ${price[0]}–${price[1]}',
                style: AppFonts.base(size: 12, color: Colors.white60)),
          ],
          if (notes != null && notes.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(notes,
                  style: AppFonts.base(size: 12, color: Colors.white.withOpacity(0.85))),
            ),
          ],
          const SizedBox(height: 10),
          _actionRow(status, id),
          // Chat with the customer about this specific booking. Prefer
          // the provider_id baked into the booking, fall back to the
          // logged-in provider's own id (passed from the Jobs tab).
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                final pid =
                    (booking['provider_id'] as String?) ?? providerOwnerId ?? '';
                if (pid.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Provider id unavailable — try refreshing')),
                  );
                  return;
                }
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => BookingChatScreen(
                    bookingId: id,
                    myRole: 'provider',
                    mySenderId: pid,
                    counterpartName: 'Customer',
                  ),
                ));
              },
              icon: const Icon(Icons.chat_bubble_outline_rounded, size: 16),
              label: const Text('Chat with customer'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.violet,
                side: BorderSide(color: AppColors.violet.withOpacity(0.5)),
                padding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionRow(String status, String id) {
    final actions = _nextActions(status);
    if (actions.isEmpty) {
      return Text(_terminalLabel(status),
          style: AppFonts.base(size: 11, color: Colors.white38));
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: actions.map((a) {
        return ElevatedButton(
          onPressed: () => onAction(id, a.action),
          style: ElevatedButton.styleFrom(
            backgroundColor: a.color,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            minimumSize: const Size(0, 36),
          ),
          child: Text(a.label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
        );
      }).toList(),
    );
  }

  List<_Action> _nextActions(String status) {
    switch (status) {
      case 'requested':
      case 'matched':
        return [
          _Action('accept', 'Accept', AppColors.intent),
          _Action('decline', 'Decline', Colors.redAccent),
        ];
      case 'confirmed':
        // Already accepted by booking flow — provider's next step is to
        // depart for the job, then mark it started on arrival.
        return [
          _Action('en_route', 'On the way', AppColors.followup),
          _Action('cancelled', 'Cancel', Colors.redAccent),
        ];
      case 'reminded':
        return [
          _Action('arrived', 'Start job', AppColors.booking),
          _Action('cancelled', 'Cancel', Colors.redAccent),
        ];
      case 'in_progress':
        return [_Action('completed', 'Mark complete', AppColors.intent)];
      default:
        return [];
    }
  }

  String _terminalLabel(String s) => switch (s) {
        'completed' => '✓ Completed',
        'cancelled' => '✗ Cancelled',
        'no_show' => '✗ No-show',
        _ => s,
      };

  Color _accentForStatus(String s) => switch (s) {
        'completed' => AppColors.intent,
        'cancelled' || 'no_show' => Colors.redAccent,
        'in_progress' => AppColors.booking,
        'reminded' => AppColors.followup,
        _ => AppColors.violet,
      };

  String _titleCase(String s) =>
      s.split(' ').map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');

  String _formatWhen(String iso) => formatBookingWhen(iso);
}

class _Action {
  final String action;
  final String label;
  final Color color;
  _Action(this.action, this.label, this.color);
}
