import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/types.dart';
import '../services/api.dart';

enum RunStatus { idle, running, complete, failed }

/// Single source of truth for the chat session — held by `MyApp` and
/// observed by widgets via `AnimatedBuilder` / `ListenableBuilder`.
class AppState extends ChangeNotifier {
  final ApiClient _api = ApiClient();

  final List<ChatMessage> messages = [];
  final List<TraceStep> traceSteps = [];
  BookingResult? lastBooking;

  String userId = 'u_demo';
  String? currentRunId;
  RunStatus status = RunStatus.idle;
  String? errorMessage;

  /// True when the last run ended with a clarification question. The next user
  /// message will be combined with the previous user input so the pipeline has
  /// the full context.
  bool awaitingClarification = false;
  String _pendingUserInput = '';

  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty || status == RunStatus.running) return;
    _cancelFollowUpReminder(); // user is responding — stop any pending nudges

    final userText = text.trim();
    messages.add(ChatMessage(text: userText, fromUser: true));

    // If we're responding to a clarification, prepend the previous user input
    // so the intent agent has the full context for re-parsing.
    final composedInput = awaitingClarification && _pendingUserInput.isNotEmpty
        ? '$_pendingUserInput. $userText'
        : userText;
    _pendingUserInput = composedInput;
    awaitingClarification = false;

    traceSteps.clear();
    lastBooking = null;
    status = RunStatus.running;
    errorMessage = null;
    notifyListeners();

    try {
      await for (final evt in _api.run(userId: userId, userInput: composedInput)) {
        _handleEvent(evt);
        notifyListeners();
      }
      if (status != RunStatus.failed) {
        status = RunStatus.complete;
      }
    } catch (e) {
      status = RunStatus.failed;
      errorMessage = e.toString();
    }
    notifyListeners();
  }

  void _handleEvent(SseEvent evt) {
    switch (evt.event) {
      case 'run_started':
        currentRunId = evt.data['run_id'] as String?;
        break;
      case 'step':
        try {
          traceSteps.add(TraceStep.fromJson(evt.data));
          _maybeExtractBookingFromStep(evt.data);
        } catch (_) {/* ignore malformed */}
        break;
      case 'user_message':
        final txt = evt.data['text'] as String?;
        final lang = evt.data['language'] as String?;
        if (txt != null && txt.isNotEmpty) {
          messages.add(ChatMessage(text: txt, fromUser: false, language: lang));
        }
        break;
      case 'run_complete':
        currentRunId = evt.data['run_id'] as String? ?? currentRunId;
        final completionStatus = evt.data['status'] as String?;
        if (completionStatus == 'awaiting_user_input') {
          // Pipeline asked for clarification — next message will be combined
          // with the prior context.
          awaitingClarification = true;
          lastBooking = null;
          _armFollowUpReminder();
        } else {
          awaitingClarification = false;
          _pendingUserInput = '';
          _cancelFollowUpReminder();
          _finalizeBooking(evt.data);
        }
        break;
      case 'error':
        status = RunStatus.failed;
        errorMessage = evt.data['error']?.toString() ?? 'Unknown error';
        break;
    }
  }

  void _maybeExtractBookingFromStep(Map<String, dynamic> step) {
    final agent = step['agent'] as String?;
    if (agent == 'booking') {
      final out = step['output'] as Map<String, dynamic>?;
      if (out == null) return;
      // Normalize: any status that isn't a known "in-trouble" state and has a
      // real booking_id should be treated as confirmed.
      final rawStatus = (out['status'] as String?) ?? '';
      final id = out['booking_id'] as String?;
      final normalized = id != null &&
              rawStatus != 'failed' &&
              rawStatus != 'needs_user_choice' &&
              rawStatus != 'conflict'
          ? 'confirmed'
          : (rawStatus.isEmpty ? 'pending' : rawStatus);
      // Preserve any previously-stashed location/category/time/provider
      // (from the intent step) when we update with the booking result.
      lastBooking = BookingResult(
        bookingId: id,
        providerName: lastBooking?.providerName,
        category: lastBooking?.category,
        whenIso: (out['confirmed_time_iso'] as String?) ?? lastBooking?.whenIso,
        location: lastBooking?.location,
        estimatedPricePkr: lastBooking?.estimatedPricePkr,
        followUps: lastBooking?.followUps ?? const [],
        status: normalized,
      );
    } else if (agent == 'followup' && lastBooking != null) {
      final out = step['output'] as Map<String, dynamic>?;
      if (out == null) return;
      final jobs = (out['scheduled_jobs'] as List? ?? [])
          .map((j) => ScheduledJob.fromJson(j as Map<String, dynamic>))
          .toList();
      lastBooking = BookingResult(
        bookingId: lastBooking?.bookingId,
        providerName: lastBooking?.providerName,
        category: lastBooking?.category,
        whenIso: lastBooking?.whenIso,
        location: lastBooking?.location,
        estimatedPricePkr: lastBooking?.estimatedPricePkr,
        followUps: jobs,
        status: lastBooking?.status ?? 'confirmed',
      );
    } else if (agent == 'ranking' && lastBooking == null) {
      // Try to capture provider name from ranking output for richer booking card
      final out = step['output'] as Map<String, dynamic>?;
      final top = (out?['top_3'] as List?)?.cast<Map<String, dynamic>?>().firstOrNull;
      if (top != null) {
        // Will be enriched when booking event fires
      }
    } else if (agent == 'intent' && lastBooking == null) {
      final out = step['output'] as Map<String, dynamic>?;
      if (out == null) return;
      final service = (out['service'] as Map<String, dynamic>?)?['category_id'];
      final loc = (out['location'] as Map<String, dynamic>?)?['label'];
      final time = (out['time'] as Map<String, dynamic>?)?['iso'];
      // Stash partial — booking event will replace
      lastBooking = BookingResult(
        category: service as String?,
        location: loc as String?,
        whenIso: time as String?,
        status: 'pending',
      );
    }
  }

  void _finalizeBooking(Map<String, dynamic> data) {
    final id = data['booking_id'] as String?;
    final status = data['status'] as String? ?? 'complete';
    if (id != null && lastBooking != null) {
      lastBooking = BookingResult(
        bookingId: id,
        providerName: lastBooking?.providerName,
        category: lastBooking?.category,
        whenIso: lastBooking?.whenIso,
        location: lastBooking?.location,
        estimatedPricePkr: lastBooking?.estimatedPricePkr,
        followUps: lastBooking?.followUps ?? const [],
        status: status,
      );
    }
  }

  void clearError() {
    errorMessage = null;
    notifyListeners();
  }

  // ─── Follow-up reminder (no-response nudge) ────────────────────────────
  // If the user doesn't reply within `_followUpDelay` after a clarification
  // question, we push a soft reminder into the chat. Two reminders max.

  Timer? _followUpTimer1;
  Timer? _followUpTimer2;
  static const _followUp1 = Duration(seconds: 120);
  static const _followUp2 = Duration(seconds: 300);

  void _armFollowUpReminder() {
    _cancelFollowUpReminder();
    _followUpTimer1 = Timer(_followUp1, () => _fireFollowUp(1));
    _followUpTimer2 = Timer(_followUp2, () => _fireFollowUp(2));
  }

  void _cancelFollowUpReminder() {
    _followUpTimer1?.cancel();
    _followUpTimer2?.cancel();
    _followUpTimer1 = null;
    _followUpTimer2 = null;
  }

  void _fireFollowUp(int n) {
    if (!awaitingClarification) return; // user already responded
    final lang = messages.isNotEmpty
        ? (messages.last.language ?? 'en')
        : 'en';
    final text = _followUpMessage(n, lang);
    messages.add(ChatMessage(text: text, fromUser: false, language: lang));
    notifyListeners();
  }

  String _followUpMessage(int n, String lang) {
    final messagesByLang = {
      'en': [
        'Still there? Just need a location and time to finish booking.',
        "I'll close this if I don't hear back in a few minutes — text me when you're ready.",
      ],
      'ur': [
        'کیا آپ موجود ہیں؟ بکنگ مکمل کرنے کے لیے صرف جگہ اور وقت چاہیے۔',
        'چند منٹ میں جواب نہ ملا تو میں یہ بکنگ بند کر دوں گا — جب تیار ہوں مجھے بتا دیں۔',
      ],
      'roman_ur': [
        'Aap hain wahan? Bas location aur waqt bata dein — booking ho jayegi.',
        'Agar 5 minute mein reply nahin aaya to main ye booking close kar dunga — jab ready hon batadein.',
      ],
    };
    final pool = messagesByLang[lang] ?? messagesByLang['en']!;
    return pool[(n - 1).clamp(0, pool.length - 1)];
  }

  @override
  void dispose() {
    _cancelFollowUpReminder();
    super.dispose();
  }
}
