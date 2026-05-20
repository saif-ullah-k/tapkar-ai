import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../i18n.dart';
import '../services/user_api.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Inbox — combines notifications (sent) + scheduled reminders (upcoming).
class InboxScreen extends StatefulWidget {
  final AppState state;
  const InboxScreen({super.key, required this.state});

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  final UserApi _api = UserApi();
  List<Map<String, dynamic>> _messages = [];
  List<Map<String, dynamic>> _scheduled = [];
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
      final r = await _api.myInbox(widget.state.userId);
      if (!mounted) return;
      setState(() {
        _messages = r.messages;
        _scheduled = r.scheduled;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state.auth,
      builder: (_, __) {
        final t = T(widget.state.auth.language);
        return Scaffold(
          backgroundColor: AppColors.bg,
          appBar: AppBar(
            backgroundColor: AppColors.bg,
            elevation: 0,
            title: Text(t.inboxTitle,
                style: AppFonts.base(size: 17, weight: FontWeight.w700)),
            actions: [
              IconButton(
                  icon: const Icon(Icons.refresh, color: Colors.white60),
                  onPressed: _load),
            ],
          ),
          body: SafeArea(child: _body(t)),
        );
      },
    );
  }

  Widget _body(T t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(28),
        child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 36),
          const SizedBox(height: 8),
          Text(t.inboxLoadFailed,
              style: AppFonts.base(size: 14, weight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(_error!,
              textAlign: TextAlign.center,
              style: AppFonts.base(size: 11, color: Colors.white60)),
          const SizedBox(height: 12),
          ElevatedButton(onPressed: _load, child: Text(t.retry)),
        ])),
      );
    }
    if (_messages.isEmpty && _scheduled.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.mark_email_read_outlined, color: Colors.white30, size: 38),
              const SizedBox(height: 12),
              Text(t.inboxEmptyTitle,
                  style: AppFonts.base(size: 16, weight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(t.inboxEmptySubtitle,
                  textAlign: TextAlign.center,
                  style: AppFonts.base(size: 12, color: Colors.white60)),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (_scheduled.isNotEmpty) ...[
            _sectionLabel('Upcoming reminders · ${_scheduled.length}'),
            ..._scheduled.map((s) => _ScheduledRow(job: s)),
            const SizedBox(height: 8),
          ],
          if (_messages.isNotEmpty) ...[
            _sectionLabel('Messages · ${_messages.length}'),
            ..._messages.map((m) => _MessageRow(msg: m)),
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
}

class _ScheduledRow extends StatelessWidget {
  final Map<String, dynamic> job;
  const _ScheduledRow({required this.job});

  @override
  Widget build(BuildContext context) {
    final type = job['type'] as String? ?? '';
    final fireAt = job['fire_at_iso'] as String?;
    final preview = job['message_preview'] as String? ?? '';
    final lang = job['language'] as String? ?? 'en';
    final dir = directionFor(preview);
    final isUrdu = lang == 'ur' || dir == TextDirection.rtl;
    final color = _color(type);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(
              color: color.withOpacity(0.18),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(_icon(type), color: color, size: 16),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(type.replaceAll('_', ' ').toUpperCase(),
                        style: AppFonts.mono(size: 10, color: color).copyWith(letterSpacing: 1.2, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    if (fireAt != null)
                      Text(_when(fireAt),
                          style: AppFonts.mono(size: 10, color: Colors.white54)),
                  ],
                ),
                const SizedBox(height: 4),
                Directionality(
                  textDirection: dir,
                  child: Text(preview,
                      style: isUrdu
                          ? AppFonts.urdu(size: 13)
                          : AppFonts.base(size: 12.5, color: Colors.white.withOpacity(0.92))),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _icon(String type) {
    switch (type) {
      case 'reminder':
        return Icons.alarm_rounded;
      case 'status_check':
        return Icons.fact_check_outlined;
      case 'survey':
        return Icons.rate_review_outlined;
      default:
        return Icons.notifications;
    }
  }

  Color _color(String type) {
    switch (type) {
      case 'reminder':
        return AppColors.followup;
      case 'status_check':
        return AppColors.discovery;
      case 'survey':
        return AppColors.intent;
      default:
        return Colors.white60;
    }
  }

  String _when(String iso) {
    try {
      final d = DateTime.parse(iso).toLocal();
      return DateFormat('EEE h:mm a').format(d);
    } catch (_) {
      return iso;
    }
  }
}

class _MessageRow extends StatelessWidget {
  final Map<String, dynamic> msg;
  const _MessageRow({required this.msg});

  @override
  Widget build(BuildContext context) {
    final text = msg['message'] as String? ?? '';
    final lang = msg['language'] as String? ?? 'en';
    final ts = msg['ts'] as String?;
    final dir = directionFor(text);
    final isUrdu = lang == 'ur' || dir == TextDirection.rtl;

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
          Directionality(
            textDirection: dir,
            child: Text(text,
                style: isUrdu
                    ? AppFonts.urdu(size: 14)
                    : AppFonts.base(size: 13, color: Colors.white)),
          ),
          if (ts != null) ...[
            const SizedBox(height: 6),
            Text(_when(ts),
                style: AppFonts.mono(size: 9, color: Colors.white38)),
          ],
        ],
      ),
    );
  }

  String _when(String iso) {
    try {
      final d = DateTime.parse(iso).toLocal();
      final now = DateTime.now();
      final diff = now.difference(d);
      if (diff.inMinutes < 1) return 'just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24) return '${diff.inHours}h ago';
      return DateFormat('d MMM h:mm a').format(d);
    } catch (_) {
      return iso;
    }
  }
}
