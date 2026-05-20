import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../i18n.dart';
import '../services/notifications.dart';
import '../services/user_api.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../utils/time.dart';
import 'booking_chat_screen.dart';

/// Customer's bookings — upcoming + past, with status pills.
class BookingsScreen extends StatefulWidget {
  final AppState state;
  final ValueChanged<int> onJumpToTab;
  const BookingsScreen({super.key, required this.state, required this.onJumpToTab});

  @override
  State<BookingsScreen> createState() => _BookingsScreenState();
}

class _BookingsScreenState extends State<BookingsScreen> {
  final UserApi _api = UserApi();
  List<Map<String, dynamic>> _bookings = [];
  bool _loading = true;
  String? _error;
  Timer? _refreshTimer;
  /// Track latest message id per booking so we can fire a notification
  /// when a provider sends something new while the customer is on this
  /// screen but not inside the chat.
  final Map<String, String> _lastSeenMsgIdByBooking = {};

  @override
  void initState() {
    super.initState();
    _load();
    // Real-time-ish — 3 s polling while the tab is visible. Server-side
    // booking updates land within a few seconds of any status change
    // (provider accepts, completes, etc.) without manual refresh.
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) _load(silent: true);
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final bookings = await _api.myBookings(widget.state.userId);
      if (!mounted) return;
      setState(() {
        _bookings = bookings;
        _loading = false;
      });
      // Notify on new provider-side messages.
      _pollMessagesForBookings(bookings);
    } catch (e) {
      if (!mounted) return;
      if (silent) return; // swallow background refresh errors
      setState(() {
        _error = e.toString();
        _loading = false;
      });
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
        if (previous == null) continue;
        if (latestId == previous) continue;
        if (latest['from'] != 'provider') continue;
        final providerName = (b['provider_name'] as String?) ?? 'provider';
        Notifications.instance.chatMessage(
          fromLabel: providerName.split(' ').first,
          preview: (latest['text'] as String?) ?? '',
        );
      } catch (_) {/* transient */}
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state.auth,
      builder: (_, __) {
        final t = T(widget.state.auth.language);
        final now = DateTime.now();
        final upcoming = <Map<String, dynamic>>[];
        final past = <Map<String, dynamic>>[];
        for (final b in _bookings) {
          final iso = b['time_iso'] as String?;
          final d = iso != null ? DateTime.tryParse(iso) : null;
          if (d != null && d.isAfter(now)) {
            upcoming.add(b);
          } else {
            past.add(b);
          }
        }

        return Scaffold(
          backgroundColor: AppColors.bg,
          appBar: AppBar(
            backgroundColor: AppColors.bg,
            elevation: 0,
            title: Text(t.bookingsTitle,
                style: AppFonts.base(size: 17, weight: FontWeight.w700)),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh, color: Colors.white60),
                onPressed: _load,
              ),
            ],
          ),
          body: SafeArea(child: _body(upcoming, past, t)),
        );
      },
    );
  }

  Widget _body(List<Map<String, dynamic>> up, List<Map<String, dynamic>> past, T t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _errorView(t);
    if (_bookings.isEmpty) return _empty(t);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (up.isNotEmpty) ...[
            _sectionLabel('Upcoming · ${up.length}'),
            ...up.map((b) => _BookingCard(booking: b, state: widget.state)),
            const SizedBox(height: 8),
          ],
          if (past.isNotEmpty) ...[
            _sectionLabel('Past · ${past.length}'),
            ...past.map((b) => _BookingCard(booking: b, state: widget.state)),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Text(text.toUpperCase(),
            style: AppFonts.mono(size: 10, color: Colors.white54).copyWith(letterSpacing: 1.4)),
      );

  Widget _empty(T t) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.event_busy_outlined, color: Colors.white30, size: 38),
              const SizedBox(height: 12),
              Text(t.bookingsEmptyTitle,
                  style: AppFonts.base(size: 16, weight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                t.bookingsEmptySubtitle,
                textAlign: TextAlign.center,
                style: AppFonts.base(size: 12, color: Colors.white60),
              ),
              const SizedBox(height: 18),
              ElevatedButton.icon(
                onPressed: () => widget.onJumpToTab(2),
                icon: const Icon(Icons.auto_awesome, size: 16),
                label: Text(t.bookingsAskAi),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.violet,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );

  Widget _errorView(T t) => Padding(
        padding: const EdgeInsets.all(28),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 36),
              const SizedBox(height: 8),
              Text(t.bookingsLoadFailed,
                  style: AppFonts.base(size: 14, weight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(_error ?? '',
                  textAlign: TextAlign.center,
                  style: AppFonts.base(size: 11, color: Colors.white60)),
              const SizedBox(height: 14),
              ElevatedButton(onPressed: _load, child: Text(t.retry)),
            ],
          ),
        ),
      );
}

class _BookingCard extends StatelessWidget {
  final Map<String, dynamic> booking;
  final AppState state;
  const _BookingCard({required this.booking, required this.state});

  @override
  Widget build(BuildContext context) {
    final id = booking['id'] as String? ?? '';
    final status = (booking['status'] as String?) ?? 'pending';
    final cat = booking['service_category_id'] as String?;
    final loc = (booking['location'] as Map?)?['label'] as String?;
    final when = booking['time_iso'] as String?;
    final providerName = booking['provider_name'] as String?;
    final providerRating = booking['provider_rating'];
    final price = (booking['estimated_price_pkr'] as List?)?.cast<int>();

    final accent = _accentForStatus(status);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(status.toUpperCase(),
                    style: AppFonts.mono(size: 9, color: accent)
                        .copyWith(letterSpacing: 1.2, fontWeight: FontWeight.w700)),
              ),
              const Spacer(),
              Text(id, style: AppFonts.mono(size: 10, color: Colors.white38)),
            ],
          ),
          const SizedBox(height: 10),
          Text(providerName ?? (cat ?? 'Booking'),
              style: AppFonts.base(size: 14, weight: FontWeight.w700)),
          if (cat != null) ...[
            const SizedBox(height: 2),
            Text(
              '${_titleCase(cat.replaceAll('_', ' '))}${loc != null ? '  ·  $loc' : ''}',
              style: AppFonts.base(size: 12, color: Colors.white70),
            ),
          ],
          if (when != null) ...[
            const SizedBox(height: 3),
            Row(children: [
              const Icon(Icons.schedule, size: 12, color: Colors.white54),
              const SizedBox(width: 4),
              Text(_formatWhen(when),
                  style: AppFonts.base(size: 12, color: Colors.white70)),
            ]),
          ],
          if (providerRating != null || (price != null && price.length == 2)) ...[
            const SizedBox(height: 6),
            Row(children: [
              if (providerRating != null) ...[
                const Icon(Icons.star, size: 12, color: Colors.amber),
                const SizedBox(width: 3),
                Text('$providerRating',
                    style: AppFonts.mono(size: 11, color: Colors.white60)),
                const SizedBox(width: 10),
              ],
              if (price != null && price.length == 2)
                Text('PKR ${price[0]}–${price[1]}',
                    style: AppFonts.mono(size: 11, color: Colors.white60)),
            ]),
          ],
          // Chat-with-provider entry. Hidden if we don't have a real
          // provider name (mid-booking-failure cases).
          if (id.isNotEmpty && providerName != null && providerName.isNotEmpty) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => BookingChatScreen(
                      bookingId: id,
                      myRole: 'user',
                      mySenderId: state.userId,
                      counterpartName: providerName,
                    ),
                  ));
                  state.markChatRead(id);
                },
                icon: const Icon(Icons.chat_bubble_outline_rounded, size: 16),
                label: Text('Chat with ${providerName.split(' ').first}'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.violet,
                  side: BorderSide(color: AppColors.violet.withOpacity(0.5)),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color _accentForStatus(String s) {
    switch (s) {
      case 'completed':
        return AppColors.intent;
      case 'cancelled':
      case 'no_show':
        return Colors.redAccent;
      case 'in_progress':
      case 'reminded':
        return AppColors.followup;
      case 'confirmed':
      case 'matched':
      case 'requested':
      default:
        return AppColors.violet;
    }
  }

  String _titleCase(String s) => s
      .split(' ')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');

  String _formatWhen(String iso) => formatBookingWhen(iso);
}
