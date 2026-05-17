import 'package:flutter/material.dart';
import '../theme.dart';

/// Animated mic button. Shows a pulsing ring while listening.
class VoiceInputButton extends StatefulWidget {
  final bool listening;
  final VoidCallback onTap;

  const VoiceInputButton({super.key, required this.listening, required this.onTap});

  @override
  State<VoiceInputButton> createState() => _VoiceInputButtonState();
}

class _VoiceInputButtonState extends State<VoiceInputButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: SizedBox(
        width: 44, height: 44,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (widget.listening)
              AnimatedBuilder(
                animation: _ctrl,
                builder: (_, __) {
                  final t = _ctrl.value;
                  return Container(
                    width: 28 + 24 * t,
                    height: 28 + 24 * t,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.userBubble.withOpacity(0.6 * (1 - t)),
                        width: 2,
                      ),
                    ),
                  );
                },
              ),
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.listening
                    ? AppColors.userBubble.withOpacity(0.25)
                    : Colors.white.withOpacity(0.06),
                border: Border.all(
                  color: widget.listening
                      ? AppColors.userBubble
                      : Colors.white.withOpacity(0.18),
                ),
              ),
              child: Icon(
                widget.listening ? Icons.mic : Icons.mic_none,
                size: 16,
                color: widget.listening ? AppColors.userBubble : Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
