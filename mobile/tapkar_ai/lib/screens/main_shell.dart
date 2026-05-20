import 'package:flutter/material.dart';
import '../i18n.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'bookings_screen.dart';
import 'chat_screen.dart';
import 'home_screen.dart';
import 'inbox_screen.dart';
import 'profile_screen.dart';

/// Top-level scaffold with the 5-tab bottom nav.
class MainShell extends StatefulWidget {
  final AppState state;
  const MainShell({super.key, required this.state});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;

  // Keep instances alive so chat state etc. doesn't reset on tab switch.
  late final List<Widget> _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = [
      HomeScreen(state: widget.state, onJumpToTab: _jumpTo),
      BookingsScreen(state: widget.state, onJumpToTab: _jumpTo),
      ChatScreen(state: widget.state),
      InboxScreen(state: widget.state),
      ProfileScreen(state: widget.state),
    ];
  }

  void _jumpTo(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    // Listen to AppState (not just auth) so the bottom-nav unread
    // badge updates the moment the global chat poller bumps the
    // unread counter.
    return AnimatedBuilder(
      animation: Listenable.merge([widget.state, widget.state.auth]),
      builder: (_, __) {
        final t = T(widget.state.auth.language);
        return Scaffold(
          backgroundColor: AppColors.bg,
          body: IndexedStack(index: _index, children: _tabs),
          bottomNavigationBar: _BottomNav(
            index: _index,
            onTap: _jumpTo,
            t: t,
            inboxBadgeCount: widget.state.totalUnreadChatCount,
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
  final int inboxBadgeCount;
  const _BottomNav({
    required this.index,
    required this.onTap,
    required this.t,
    this.inboxBadgeCount = 0,
  });

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
                label: t.navHome,
                icon: Icons.home_outlined,
                activeIcon: Icons.home_rounded,
                selected: index == 0,
                onTap: () => onTap(0),
              ),
              _NavItem(
                label: t.navBookings,
                icon: Icons.event_note_outlined,
                activeIcon: Icons.event_note_rounded,
                selected: index == 1,
                onTap: () => onTap(1),
              ),
              _NavCenterItem(
                label: t.navAskAi,
                selected: index == 2,
                onTap: () => onTap(2),
              ),
              _NavItem(
                label: t.navInbox,
                icon: Icons.notifications_none_rounded,
                activeIcon: Icons.notifications_rounded,
                selected: index == 3,
                onTap: () => onTap(3),
                badgeCount: inboxBadgeCount,
              ),
              _NavItem(
                label: t.navProfile,
                icon: Icons.person_outline_rounded,
                activeIcon: Icons.person_rounded,
                selected: index == 4,
                onTap: () => onTap(4),
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
  /// Unread count to render as a small violet badge over the icon's
  /// top-right corner. 0 hides the badge entirely.
  final int badgeCount;
  const _NavItem({
    required this.label,
    required this.icon,
    required this.activeIcon,
    required this.selected,
    required this.onTap,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.violet : Colors.white60;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 30, height: 24,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    Icon(selected ? activeIcon : icon, color: color, size: 22),
                    if (badgeCount > 0)
                      Positioned(
                        top: -2, right: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                          decoration: BoxDecoration(
                            color: AppColors.violet,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.surface, width: 1.5),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            badgeCount > 99 ? '99+' : '$badgeCount',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.w800),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: AppFonts.base(size: 10, color: color, weight: selected ? FontWeight.w600 : FontWeight.w400),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Highlighted "Ask AI" tab — gradient orb in the center, the magic.
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
