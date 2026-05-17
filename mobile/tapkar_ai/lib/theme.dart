import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// TapKar AI design tokens — kept in one place so the app is easy to re-skin.
class AppColors {
  // Brand
  static const violet = Color(0xFFA78BFA);
  static const cyan = Color(0xFF22D3EE);
  static const userBubble = Color(0xFF60A5FA);
  static const assistantBubble = Color(0xFF1E1E2E);

  // Agent accents (matches flow-explainer.html)
  static const orchestrator = Color(0xFFA78BFA);
  static const intent = Color(0xFF34D399);
  static const discovery = Color(0xFFFBBF24);
  static const ranking = Color(0xFFF472B6);
  static const booking = Color(0xFF22D3EE);
  static const followup = Color(0xFFFB923C);

  // Surfaces
  static const bg = Color(0xFF050510);
  static const surface = Color(0xFF12121A);
  static const surface2 = Color(0xFF1A1A2A);
  static const border = Color(0x14FFFFFF);
}

/// Accent for a given agent name.
Color accentForAgent(String name) {
  switch (name) {
    case 'orchestrator':
      return AppColors.orchestrator;
    case 'intent':
      return AppColors.intent;
    case 'discovery':
      return AppColors.discovery;
    case 'ranking':
      return AppColors.ranking;
    case 'booking':
      return AppColors.booking;
    case 'followup':
      return AppColors.followup;
    default:
      return Colors.white70;
  }
}

/// Inter font for English / Roman Urdu, Noto Nastaliq Urdu for Urdu.
class AppFonts {
  static TextStyle base({
    double size = 14,
    FontWeight weight = FontWeight.w400,
    Color? color,
    double? height,
  }) =>
      GoogleFonts.inter(
        fontSize: size,
        fontWeight: weight,
        color: color ?? Colors.white,
        height: height,
      );

  static TextStyle urdu({
    double size = 16,
    FontWeight weight = FontWeight.w400,
    Color? color,
    double? height,
  }) =>
      GoogleFonts.notoNastaliqUrdu(
        fontSize: size,
        fontWeight: weight,
        color: color ?? Colors.white,
        height: height ?? 1.9,
      );

  static TextStyle mono({double size = 11, Color? color}) =>
      GoogleFonts.jetBrainsMono(
        fontSize: size,
        color: color ?? Colors.white70,
      );
}

/// Pick the right text style based on the language code from the backend.
TextStyle styleForLanguage(String? lang,
    {double size = 14, FontWeight weight = FontWeight.w400, Color? color}) {
  if (lang == 'ur') return AppFonts.urdu(size: size + 2, weight: weight, color: color);
  return AppFonts.base(size: size, weight: weight, color: color);
}

/// `TextDirection` for a piece of text. Heuristic: if it contains any Arabic-script
/// characters, treat as RTL.
TextDirection directionFor(String text) {
  for (final r in text.runes) {
    if (r >= 0x0600 && r <= 0x06FF) return TextDirection.rtl;
  }
  return TextDirection.ltr;
}

ThemeData buildAppTheme() => ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.bg,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.violet,
        secondary: AppColors.cyan,
        surface: AppColors.surface,
      ),
      textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
      useMaterial3: true,
    );
