import 'package:flutter/material.dart';
import '../models/types.dart';
import '../theme.dart';

class ChatBubble extends StatelessWidget {
  final ChatMessage message;
  const ChatBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.fromUser;
    final dir = directionFor(message.text);
    final isUrdu = message.language == 'ur' || dir == TextDirection.rtl;
    final bgColor = isUser
        ? AppColors.userBubble.withOpacity(0.18)
        : AppColors.violet.withOpacity(0.12);
    final borderColor = isUser
        ? AppColors.userBubble.withOpacity(0.4)
        : AppColors.violet.withOpacity(0.3);

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: bgColor,
            border: Border.all(color: borderColor),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isUser ? 16 : 4),
              bottomRight: Radius.circular(isUser ? 4 : 16),
            ),
          ),
          child: Directionality(
            textDirection: dir,
            child: Text(
              message.text,
              style: isUrdu
                  ? AppFonts.urdu(size: 16, color: Colors.white)
                  : AppFonts.base(size: 14.5, color: Colors.white, height: 1.4),
            ),
          ),
        ),
      ),
    );
  }
}
