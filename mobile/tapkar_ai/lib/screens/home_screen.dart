import 'package:flutter/material.dart';
import '../i18n.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Landing page. Hero + quick service categories + recent activity peek.
class HomeScreen extends StatelessWidget {
  final AppState state;
  final ValueChanged<int> onJumpToTab;
  const HomeScreen({super.key, required this.state, required this.onJumpToTab});

  // Each category has the display tile labels and the profession noun used
  // to build the starter prompt in 3 languages.
  static const _quickCategories = <Map<String, String>>[
    {'id': 'plumber', 'emoji': '🔧', 'label': 'Plumber', 'ur': 'پلمبر',
     'noun_en': 'plumber', 'noun_ru': 'plumber', 'noun_ur': 'پلمبر'},
    {'id': 'electrician', 'emoji': '⚡', 'label': 'Electrician', 'ur': 'الیکٹریشن',
     'noun_en': 'electrician', 'noun_ru': 'electrician', 'noun_ur': 'الیکٹریشن'},
    {'id': 'ac_technician', 'emoji': '❄️', 'label': 'AC Tech', 'ur': 'اے سی',
     'noun_en': 'AC technician', 'noun_ru': 'AC technician', 'noun_ur': 'اے سی ٹیکنیشن'},
    {'id': 'carpenter', 'emoji': '🪚', 'label': 'Carpenter', 'ur': 'بڑھئی',
     'noun_en': 'carpenter', 'noun_ru': 'carpenter', 'noun_ur': 'بڑھئی'},
    {'id': 'tutor', 'emoji': '📚', 'label': 'Tutor', 'ur': 'ٹیوٹر',
     'noun_en': 'tutor', 'noun_ru': 'tutor', 'noun_ur': 'ٹیوٹر'},
    {'id': 'beautician', 'emoji': '💄', 'label': 'Beautician', 'ur': 'بیوٹیشن',
     'noun_en': 'beautician', 'noun_ru': 'beautician', 'noun_ur': 'بیوٹیشن'},
    {'id': 'cleaner', 'emoji': '🧹', 'label': 'Cleaner', 'ur': 'صفائی والا',
     'noun_en': 'cleaner', 'noun_ru': 'cleaner', 'noun_ur': 'صفائی والا'},
    {'id': 'cook', 'emoji': '🍳', 'label': 'Cook', 'ur': 'باورچی',
     'noun_en': 'cook', 'noun_ru': 'cook', 'noun_ur': 'باورچی'},
    {'id': 'mehndi_artist', 'emoji': '🌺', 'label': 'Mehndi', 'ur': 'مہندی',
     'noun_en': 'mehndi artist', 'noun_ru': 'mehndi artist', 'noun_ur': 'مہندی والی'},
    {'id': 'quran_teacher', 'emoji': '📖', 'label': 'Quran', 'ur': 'قرآن',
     'noun_en': 'Quran teacher', 'noun_ru': 'Quran teacher', 'noun_ur': 'قرآن ٹیچر'},
    {'id': 'driver', 'emoji': '🚗', 'label': 'Driver', 'ur': 'ڈرائیور',
     'noun_en': 'driver', 'noun_ru': 'driver', 'noun_ur': 'ڈرائیور'},
    {'id': 'photographer', 'emoji': '📸', 'label': 'Photo', 'ur': 'فوٹو',
     'noun_en': 'photographer', 'noun_ru': 'photographer', 'noun_ur': 'فوٹوگرافر'},
  ];

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state.auth,
      builder: (_, __) {
        final t = T(state.auth.language);
        return Scaffold(
          backgroundColor: AppColors.bg,
          body: SafeArea(
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: _header(t)),
                SliverToBoxAdapter(child: _hero(context, t)),
                SliverToBoxAdapter(child: _sectionLabel(t.homeQuickServices)),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                  sliver: SliverGrid.builder(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 0.95,
                    ),
                    itemCount: _quickCategories.length,
                    itemBuilder: (_, i) => _CategoryTile(
                      data: _quickCategories[i],
                      lang: state.auth.language,
                      onTap: () => _bookCategory(_quickCategories[i]),
                    ),
                  ),
                ),
                SliverToBoxAdapter(child: _sectionLabel(t.homeRecent)),
                SliverToBoxAdapter(child: _recentBookings(context, t)),
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            ),
          ),
        );
      },
    );
  }

  void _bookCategory(Map<String, String> cat) {
    // Pre-fill chat with a starter message in the user's preferred language,
    // using the proper profession noun (not the short tile label).
    final lang = state.auth.language;
    final starter = switch (lang) {
      'ur' => 'مجھے ${cat['noun_ur']} چاہیے',
      'roman_ur' => 'Mujhe ${cat['noun_ru']} chahiye',
      _ => 'I need a ${cat['noun_en']}',
    };
    state.sendMessage(starter);
    onJumpToTab(2); // Ask AI tab
  }

  Widget _header(T t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(
          children: [
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.violet, AppColors.booking],
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: const Text('⚡', style: TextStyle(fontSize: 16)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('TapKar AI',
                      style: AppFonts.base(size: 17, weight: FontWeight.w800)),
                  Text(t.appTagline,
                      style: AppFonts.base(size: 11, color: Colors.white54)),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.notifications_none_rounded, color: Colors.white60),
              onPressed: () => onJumpToTab(3),
            ),
          ],
        ),
      );

  Widget _hero(BuildContext context, T t) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: InkWell(
        onTap: () => onJumpToTab(2),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppColors.violet.withOpacity(0.4),
                AppColors.booking.withOpacity(0.25),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.violet.withOpacity(0.45)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.bg.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.auto_awesome, size: 10, color: AppColors.intent),
                        const SizedBox(width: 4),
                        Text(t.homePoweredByAi,
                            style: AppFonts.mono(size: 9, color: AppColors.intent)
                                .copyWith(letterSpacing: 1)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(t.homeHeroTitle,
                  style: AppFonts.base(size: 22, weight: FontWeight.w800, height: 1.15)),
              const SizedBox(height: 8),
              Text(
                t.homeHeroSubtitle,
                style: AppFonts.base(size: 12, color: Colors.white.withOpacity(0.75)),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.mic, size: 14, color: AppColors.bg),
                        const SizedBox(width: 6),
                        Text(t.homeTapToAsk,
                            style: AppFonts.base(
                                size: 12, weight: FontWeight.w700, color: AppColors.bg)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Text(text.toUpperCase(),
            style: AppFonts.mono(size: 10, color: Colors.white54).copyWith(letterSpacing: 1.4)),
      );

  Widget _recentBookings(BuildContext context, T t) {
    return AnimatedBuilder(
      animation: state,
      builder: (_, __) {
        final b = state.lastBooking;
        if (b == null || b.bookingId == null) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  Icon(Icons.history, color: Colors.white30, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(t.homeNoBookings,
                        style: AppFonts.base(size: 12, color: Colors.white54)),
                  ),
                ],
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: InkWell(
            onTap: () => onJumpToTab(1),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.booking.withOpacity(0.35)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.booking.withOpacity(0.18),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: const Icon(Icons.check_rounded, color: AppColors.booking, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(b.providerName ?? (b.category ?? 'Booking') ,
                            style: AppFonts.base(size: 13, weight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text('${b.bookingId}  ·  ${b.status.toUpperCase()}',
                            style: AppFonts.mono(size: 10, color: Colors.white54)),
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_forward_ios, size: 12, color: Colors.white38),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CategoryTile extends StatelessWidget {
  final Map<String, String> data;
  final String lang;
  final VoidCallback onTap;
  const _CategoryTile({required this.data, required this.lang, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // Show Urdu label when user is in Urdu mode; English label otherwise
    // (Roman Urdu speakers commonly read English category names).
    final label = lang == 'ur' ? data['ur']! : data['label']!;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(data['emoji']!, style: const TextStyle(fontSize: 26)),
            const SizedBox(height: 6),
            Text(label,
                style: lang == 'ur'
                    ? AppFonts.urdu(size: 12, weight: FontWeight.w600)
                    : AppFonts.base(size: 11, weight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}
