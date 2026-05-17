import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/provider_api.dart';
import '../theme.dart';

/// Provider-mode home: shows incoming bookings and lets the provider
/// Accept / Decline / mark En route / Arrived / Completed.
class ProviderScreen extends StatefulWidget {
  final String providerId;
  final String providerName;
  final String? category;
  final VoidCallback onSwitchBackToCustomer;

  const ProviderScreen({
    super.key,
    required this.providerId,
    required this.providerName,
    required this.onSwitchBackToCustomer,
    this.category,
  });

  @override
  State<ProviderScreen> createState() => _ProviderScreenState();
}

class _ProviderScreenState extends State<ProviderScreen> {
  final ProviderApi _api = ProviderApi();
  List<Map<String, dynamic>> _bookings = [];
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
      final bookings = await _api.listMyBookings(widget.providerId);
      setState(() {
        _bookings = bookings;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _act(String bookingId, String action) async {
    try {
      await _api.updateBooking(
        providerId: widget.providerId,
        bookingId: bookingId,
        action: action,
      );
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Booking $bookingId marked as $action')),
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
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.swap_horiz, color: Colors.white70),
          tooltip: 'Switch to customer mode',
          onPressed: widget.onSwitchBackToCustomer,
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.followup.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('PROVIDER',
                      style: AppFonts.mono(size: 9, color: AppColors.followup)
                          .copyWith(letterSpacing: 1.2, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(widget.providerName,
                      style: AppFonts.base(size: 15, weight: FontWeight.w700),
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            if (widget.category != null)
              Text(_titleCase(widget.category!.replaceAll('_', ' ')),
                  style: AppFonts.base(size: 10, color: Colors.white54)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white60, size: 18),
            onPressed: _load,
          ),
        ],
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
            const SizedBox(height: 12),
            Text('Failed to load bookings',
                style: AppFonts.base(size: 15, weight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(_error!,
                textAlign: TextAlign.center,
                style: AppFonts.base(size: 12, color: Colors.white60)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_bookings.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.inbox_outlined, size: 40, color: Colors.white30),
              const SizedBox(height: 12),
              Text('No bookings yet',
                  style: AppFonts.base(size: 16, weight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                'Your incoming jobs will appear here.\nSwitch to customer mode and book yourself to see how it looks.',
                textAlign: TextAlign.center,
                style: AppFonts.base(size: 12, color: Colors.white60),
              ),
            ],
          ),
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
        ),
      ),
    );
  }

  String _titleCase(String s) =>
      s.split(' ').map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');
}

class _BookingCard extends StatelessWidget {
  final Map<String, dynamic> booking;
  final Future<void> Function(String bookingId, String action) onAction;

  const _BookingCard({required this.booking, required this.onAction});

  @override
  Widget build(BuildContext context) {
    final id = booking['id'] as String;
    final status = (booking['status'] as String?) ?? 'pending';
    final timeIso = booking['time_iso'] as String?;
    final category = booking['service_category_id'] as String?;
    final location = (booking['location'] as Map?)?['label'] as String?;
    final notes = booking['notes'] as String?;
    final lang = booking['language'] as String?;
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
          Row(
            children: [
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
              Text(id,
                  style: AppFonts.mono(size: 10, color: Colors.white38)),
            ],
          ),
          const SizedBox(height: 10),
          if (category != null)
            Text(
              '${_titleCase(category.replaceAll('_', ' '))}'
              '${location != null ? '  ·  $location' : ''}',
              style: AppFonts.base(size: 14, weight: FontWeight.w600),
            ),
          if (timeIso != null) ...[
            const SizedBox(height: 3),
            Text(_formatWhen(timeIso),
                style: AppFonts.base(size: 13, color: Colors.white70)),
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
        ],
      ),
    );
  }

  Widget _actionRow(String status, String id) {
    // Map booking status → next actions a provider can take
    final actions = _nextActions(status);
    if (actions.isEmpty) {
      return Text(
        _terminalLabel(status),
        style: AppFonts.base(size: 11, color: Colors.white38),
      );
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
      case 'confirmed':
        return [
          _Action('accept', 'Accept', AppColors.intent),
          _Action('decline', 'Decline', Colors.redAccent),
        ];
      case 'reminded': // post-accept, before going
        return [
          _Action('en_route', 'En route', AppColors.followup),
          _Action('cancelled', 'Cancel', Colors.redAccent),
        ];
      case 'in_progress':
        return [_Action('completed', 'Mark complete', AppColors.booking)];
      default:
        return [];
    }
  }

  String _terminalLabel(String status) {
    switch (status) {
      case 'completed':
        return '✓ Completed';
      case 'cancelled':
        return '✗ Cancelled';
      case 'no_show':
        return '✗ No-show';
      default:
        return status;
    }
  }

  Color _accentForStatus(String status) {
    switch (status) {
      case 'completed':
        return AppColors.intent;
      case 'cancelled':
      case 'no_show':
        return Colors.redAccent;
      case 'in_progress':
        return AppColors.booking;
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

  String _formatWhen(String iso) {
    try {
      final d = DateTime.parse(iso).toLocal();
      return DateFormat('EEE, d MMM · h:mm a').format(d);
    } catch (_) {
      return iso;
    }
  }
}

class _Action {
  final String action;
  final String label;
  final Color color;
  _Action(this.action, this.label, this.color);
}
