import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/types.dart';
import '../theme.dart';

/// Stack of selectable provider tiles shown when the backend yields
/// `mode: show_options`. User taps one → callback fires with the chosen option.
class PickerCard extends StatelessWidget {
  final List<ProviderOption> options;
  final ValueChanged<ProviderOption> onPick;
  final bool disabled;

  const PickerCard({
    super.key,
    required this.options,
    required this.onPick,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (int i = 0; i < options.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _Tile(
                rank: i + 1,
                option: options[i],
                disabled: disabled,
                onTap: () => onPick(options[i]),
              ),
            ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final int rank;
  final ProviderOption option;
  final bool disabled;
  final VoidCallback onTap;

  const _Tile({
    required this.rank,
    required this.option,
    required this.disabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final medal = rank == 1 ? '🥇' : rank == 2 ? '🥈' : '🥉';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: disabled ? null : onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(
              color: rank == 1
                  ? AppColors.violet.withOpacity(0.5)
                  : AppColors.border,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text(medal, style: const TextStyle(fontSize: 18)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    option.providerName,
                    style: AppFonts.base(size: 14, weight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (option.verified)
                  const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Icon(Icons.verified,
                        size: 14, color: AppColors.booking),
                  ),
              ]),
              const SizedBox(height: 6),
              Wrap(
                spacing: 10,
                runSpacing: 4,
                children: [
                  if (option.rating != null)
                    _chip(
                      Icons.star,
                      '${option.rating!.toStringAsFixed(1)}'
                      '${option.reviewCount != null ? " (${option.reviewCount})" : ""}',
                      Colors.amber,
                    ),
                  if (option.distanceKm != null)
                    _chip(
                      Icons.place_outlined,
                      '${option.distanceKm!.toStringAsFixed(1)} km',
                      Colors.white60,
                    ),
                  if (option.priceRangePkr != null &&
                      option.priceRangePkr!.length == 2)
                    _chip(
                      Icons.payments_outlined,
                      'PKR ${option.priceRangePkr![0]}–${option.priceRangePkr![1]}',
                      Colors.white60,
                    ),
                  if (option.iso != null)
                    _chip(
                      Icons.schedule,
                      _formatWhen(option.iso!),
                      Colors.white60,
                    ),
                ],
              ),
              if (option.reasoning.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  option.reasoning,
                  style: AppFonts.base(size: 11, color: Colors.white.withOpacity(0.78)),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [AppColors.violet, AppColors.booking],
                    ),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'Select',
                    style: AppFonts.base(
                      size: 12,
                      weight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(IconData icon, String text, Color color) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
          Text(text, style: AppFonts.mono(size: 10, color: Colors.white70)),
        ],
      );

  String _formatWhen(String iso) {
    try {
      final d = DateTime.parse(iso).toLocal();
      return DateFormat('EEE, d MMM · h:mm a').format(d);
    } catch (_) {
      return iso;
    }
  }
}
