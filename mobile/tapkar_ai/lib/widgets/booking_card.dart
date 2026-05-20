import 'package:flutter/material.dart';
import '../models/types.dart';
import '../theme.dart';
import '../utils/time.dart';

class BookingCard extends StatefulWidget {
  final BookingResult booking;
  const BookingCard({super.key, required this.booking});

  @override
  State<BookingCard> createState() => _BookingCardState();
}

class _BookingCardState extends State<BookingCard> {
  bool _remindersExpanded = false;

  @override
  Widget build(BuildContext context) {
    final b = widget.booking;
    final hasId = b.bookingId != null;
    final hasFollowUps = b.followUps.isNotEmpty;
    final isFailed = b.status == 'failed';
    final notFailed = !isFailed &&
        b.status != 'needs_user_choice' &&
        b.status != 'conflict';
    final isRequested = b.status == 'requested' || b.status == 'matched';
    final confirmed = hasId && notFailed && b.status == 'confirmed';
    final accent = isFailed
        ? Colors.redAccent
        : isRequested
            ? AppColors.followup
            : AppColors.booking;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            accent.withOpacity(0.18),
            (isRequested ? AppColors.violet : AppColors.intent).withOpacity(0.12),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: accent.withOpacity(0.5)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ─── Status row ─────────────────────────────────────────────────
          Row(
            children: [
              if (isRequested)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(accent),
                  ),
                )
              else
                Icon(
                  isFailed
                      ? Icons.error_outline
                      : confirmed
                          ? Icons.check_circle
                          : Icons.pending,
                  color: accent,
                  size: 18,
                ),
              const SizedBox(width: 6),
              Text(
                isFailed
                    ? 'BOOKING FAILED'
                    : isRequested
                        ? 'WAITING FOR PROVIDER'
                        : confirmed
                            ? 'BOOKING CONFIRMED'
                            : 'BOOKING PENDING',
                style: AppFonts.mono(size: 10, color: accent).copyWith(
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              if (b.bookingId != null)
                Text(b.bookingId!,
                    style: AppFonts.mono(size: 10, color: Colors.white38)),
            ],
          ),

          // ─── Provider name (big) ───────────────────────────────────────
          const SizedBox(height: 10),
          if (b.providerName != null) ...[
            Text(b.providerName!,
                style: AppFonts.base(size: 17, weight: FontWeight.w700)),
            const SizedBox(height: 2),
          ],

          // ─── Service · location · time ─────────────────────────────────
          if (b.category != null)
            Text(
              '${_titleCase(b.category!.replaceAll('_', ' '))}'
              '${b.location != null ? '  ·  ${b.location}' : ''}',
              style: AppFonts.base(size: 13.5, color: Colors.white70),
            ),
          if (b.whenIso != null) ...[
            const SizedBox(height: 3),
            Text(_formatWhen(b.whenIso!),
                style: AppFonts.base(size: 13.5, color: Colors.white70)),
          ],

          // ─── Provider notification indicator ──────────────────────────
          if (isRequested) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: accent.withOpacity(0.25)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.hourglass_top, size: 12, color: accent),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      b.providerName != null
                          ? '${b.providerName} ka jawab ka intezaar…'
                          : 'Provider ka jawab ka intezaar…',
                      style: AppFonts.base(size: 11, color: Colors.white.withOpacity(0.85)),
                    ),
                  ),
                ],
              ),
            ),
          ] else if (confirmed) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white.withOpacity(0.08)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.check_circle_outline, size: 12, color: AppColors.intent),
                  const SizedBox(width: 6),
                  Text(
                    b.providerName != null
                        ? '${b.providerName!.split(' ').first} ne accept kiya'
                        : 'Provider accepted',
                    style: AppFonts.base(size: 11, color: Colors.white70),
                  ),
                ],
              ),
            ),
          ],

          // ─── Follow-ups (collapsed by default) ─────────────────────────
          if (hasFollowUps) ...[
            const SizedBox(height: 10),
            Container(height: 1, color: Colors.white.withOpacity(0.06)),
            const SizedBox(height: 4),
            InkWell(
              onTap: () => setState(() => _remindersExpanded = !_remindersExpanded),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(Icons.notifications_active_outlined,
                        size: 13, color: AppColors.followup),
                    const SizedBox(width: 6),
                    Text(
                      '${b.followUps.length} reminders scheduled',
                      style: AppFonts.mono(size: 10, color: AppColors.followup)
                          .copyWith(letterSpacing: 1.2, fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    Icon(
                      _remindersExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: Colors.white60,
                    ),
                  ],
                ),
              ),
            ),
            if (_remindersExpanded)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: b.followUps.map((j) => _FollowUpRow(job: j)).toList(),
                ),
              ),
          ],
        ],
      ),
    );
  }

  String _titleCase(String s) =>
      s.split(' ').map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');

  String _formatWhen(String iso) => formatBookingWhen(iso);
}

class _FollowUpRow extends StatelessWidget {
  final ScheduledJob job;
  const _FollowUpRow({required this.job});

  @override
  Widget build(BuildContext context) {
    final color = _iconForType();
    final dir = directionFor(job.messagePreview);
    final isUrdu = job.language == 'ur' || dir == TextDirection.rtl;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 6, height: 6, margin: const EdgeInsets.only(top: 6, right: 8),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_when(),
                    style: AppFonts.mono(size: 10, color: Colors.white54)),
                const SizedBox(height: 2),
                Directionality(
                  textDirection: dir,
                  child: Text(
                    job.messagePreview,
                    style: isUrdu
                        ? AppFonts.urdu(size: 13, color: Colors.white.withOpacity(0.9))
                        : AppFonts.base(size: 12, color: Colors.white.withOpacity(0.9)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _iconForType() {
    switch (job.type) {
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

  String _when() {
    final when = formatFollowUpWhen(job.fireAtIso);
    return '$when · ${job.type.toUpperCase()}';
  }
}
