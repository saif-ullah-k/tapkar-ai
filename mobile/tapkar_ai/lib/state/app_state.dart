import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/types.dart' show ChatMessage, TraceStep, BookingResult, ScheduledJob, ProviderOption;
import '../services/api.dart';
import '../services/notifications.dart';
import '../services/user_api.dart';
import 'auth_state.dart';

/// One entry in the cross-screen unread-chat list. Powers the Inbox tab
/// + the cross-screen notification poller.
class ChatThreadSummary {
  final String bookingId;
  final String? counterpartName;
  final String? lastMessageText;
  final String? lastMessageFrom;
  final String? lastMessageTs;
  final int unreadCount;
  const ChatThreadSummary({
    required this.bookingId,
    this.counterpartName,
    this.lastMessageText,
    this.lastMessageFrom,
    this.lastMessageTs,
    this.unreadCount = 0,
  });
}

enum RunStatus { idle, running, complete, failed }

/// Stages of the booking pipeline that produce a friendly bot chat message.
enum _ProgressStage { finding, picking, booking, waiting, confirmed }

/// Single source of truth for the chat session — held by `MyApp` and
/// observed by widgets via `AnimatedBuilder` / `ListenableBuilder`.
class AppState extends ChangeNotifier {
  final ApiClient _api = ApiClient();
  final UserApi _userApi = UserApi();
  final AuthState auth;

  AppState({required this.auth}) {
    // Restore chat history from disk so a force-close doesn't lose the
    // conversation. Fire-and-forget — UI will rebuild via notifyListeners.
    _restoreFromDisk();
    _startGlobalMessagePoll();
  }

  /// Cached chat threads (one entry per booking that has messages).
  /// Refreshed by the global poller; consumed by InboxScreen.
  List<ChatThreadSummary> chatThreads = const [];
  /// Last-seen message id per booking — when a newer one appears in the
  /// poll and it's from the OTHER party, fires a notification AND bumps
  /// the unread counter that the inbox shows.
  final Map<String, String> _lastSeenChatIdByBooking = {};
  final Map<String, int> _unreadCountByBooking = {};

  /// Sum across all bookings — drives the unread badge on the Inbox
  /// bottom-nav icon.
  int get totalUnreadChatCount =>
      _unreadCountByBooking.values.fold<int>(0, (a, b) => a + b);

  /// Mark a booking's chat as read (called from BookingChatScreen so the
  /// inbox badge disappears when the user opens the thread).
  void markChatRead(String bookingId) {
    if (_unreadCountByBooking.remove(bookingId) != null) {
      // Update the in-memory thread list so the inbox redraws without
      // waiting for the next 5s poll tick.
      chatThreads = chatThreads
          .map((t) => t.bookingId == bookingId
              ? ChatThreadSummary(
                  bookingId: t.bookingId,
                  counterpartName: t.counterpartName,
                  lastMessageText: t.lastMessageText,
                  lastMessageFrom: t.lastMessageFrom,
                  lastMessageTs: t.lastMessageTs,
                  unreadCount: 0,
                )
              : t)
          .toList();
      notifyListeners();
    }
  }

  Timer? _messagePollTimer;
  /// Polls user's bookings + per-booking messages every 5 s so chat
  /// notifications fire on ANY screen, not just Inbox/Bookings. Also
  /// powers the inbox thread list.
  void _startGlobalMessagePoll() {
    _messagePollTimer?.cancel();
    _messagePollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _pollChatThreads();
    });
    // Kick once immediately so the inbox isn't empty on app open.
    Future.microtask(_pollChatThreads);
  }

  static const _apiUrl = String.fromEnvironment(
    'API_URL',
    defaultValue: 'https://tapkar-ai-backend-d56rhra4sa-uc.a.run.app',
  );

  Future<void> _pollChatThreads() async {
    final uid = auth.userId;
    if (uid.isEmpty) return;
    try {
      final bookings = await _userApi.myBookings(uid);
      final threadsForInbox = <ChatThreadSummary>[];
      for (final b in bookings) {
        final id = b['id'] as String?;
        if (id == null) continue;
        try {
          final r = await http.get(Uri.parse('$_apiUrl/bookings/$id/messages'))
              .timeout(const Duration(seconds: 4));
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
          final previous = _lastSeenChatIdByBooking[id];
          _lastSeenChatIdByBooking[id] = latestId;
          // Fire notification + bump unread when the OTHER party (provider)
          // sent something new. Skip on first hydration.
          if (previous != null && previous != latestId && latest['from'] == 'provider') {
            final providerName = (b['provider_name'] as String?) ?? 'provider';
            final preview = (latest['text'] as String?) ?? '';
            Notifications.instance.chatMessage(
              fromLabel: providerName.split(' ').first,
              preview: preview,
            );
            _unreadCountByBooking[id] = (_unreadCountByBooking[id] ?? 0) + 1;
          }
          threadsForInbox.add(ChatThreadSummary(
            bookingId: id,
            counterpartName: b['provider_name'] as String?,
            lastMessageText: latest['text'] as String?,
            lastMessageFrom: latest['from'] as String?,
            lastMessageTs: latest['ts'] as String?,
            unreadCount: _unreadCountByBooking[id] ?? 0,
          ));
        } catch (_) {/* per-booking transient */}
      }
      // Newest first.
      threadsForInbox.sort((a, b) =>
          (b.lastMessageTs ?? '').compareTo(a.lastMessageTs ?? ''));
      chatThreads = threadsForInbox;
      notifyListeners();
    } catch (_) {/* whole poll transient */}
  }

  static const _kMessagesKey = 'chat.messages';
  Timer? _persistDebounce;

  final List<ChatMessage> messages = [];
  final List<TraceStep> traceSteps = [];
  BookingResult? lastBooking;

  /// Resolved from auth — falls back to "u_demo" for anonymous flows.
  String get userId => auth.userId.isNotEmpty ? auth.userId : 'u_demo';
  String? currentRunId;
  RunStatus status = RunStatus.idle;
  String? errorMessage;

  /// True when the last run ended with a clarification question. The next user
  /// message will be combined with the previous user input so the pipeline has
  /// the full context.
  bool awaitingClarification = false;

  /// Messages typed by the user WHILE a run was in flight. When the run finishes
  /// we immediately fire another run that includes all of these joined together.
  final List<String> _queuedInputs = [];

  /// True when the current run is locked to a specific provider (user picked
  /// from the options card). Orchestrator skips discovery/ranking in this case,
  /// so we should NOT inject "Finding providers…" progress chat for it.
  bool _lockedMode = false;

  /// Cached intent from the most recent run. When the user taps a provider
  /// from the picker, we echo this back to the backend so the orchestrator
  /// can skip the intent agent entirely (saves ~10s on the booking flow).
  Map<String, dynamic>? _lastIntent;

  /// Agents we've already announced this run — prevents duplicate progress
  /// messages if a step fires multiple times for the same agent.
  final Set<String> _announcedAgents = {};

  Future<void> sendMessage(String text) async {
    final userText = text.trim();
    if (userText.isEmpty) return;
    _cancelFollowUpReminder(); // user is responding — stop any pending nudges

    // Always append to the visible chat so typing feels live, even mid-run.
    messages.add(ChatMessage(text: userText, fromUser: true));
    notifyListeners();

    // If a run is already in flight, queue this message — it'll be sent as
    // soon as the current run completes (combined with any other queued msgs).
    if (status == RunStatus.running) {
      _queuedInputs.add(userText);
      return;
    }

    await _runWithInput(userText);

    // Drain anything the user typed while we were running.
    while (_queuedInputs.isNotEmpty) {
      final batch = _queuedInputs.join('. ');
      _queuedInputs.clear();
      await _runWithInput(batch);
    }
  }

  // Track each user-turn separately so we can pass them as explicit turns
  // (instead of mashing them into one sentence with ". " separators, which
  // Gemini was treating as a single fuzzy utterance and dropping context).
  final List<String> _turnHistory = [];

  Future<void> _runWithInput(String userText, {
    String? selectedProviderId,
    String? selectedTimeIso,
    Map<String, dynamic>? priorIntent,
  }) async {
    // If this is the first turn of a new conversation (no clarification in
    // flight), reset history.
    if (!awaitingClarification) {
      _turnHistory.clear();
    }
    _turnHistory.add(userText);

    // Build an explicit turn-marked input. Just two layers now:
    //  1. Turn-N markers when inside a clarification flow — the intent agent
    //     uses these to merge facts across the same request.
    //  2. The user's latest message as the core input.
    //
    // We deliberately do NOT prepend the prior conversation history here:
    // the intent agent kept treating it as active context (asking "plumber
    // or AC?" because BOTH were in the preamble). Chat history still
    // persists locally for the UI — but each request to the backend is
    // fresh so the agent asks correctly for missing fields.
    final composedInput = _turnHistory.length == 1
        ? userText
        : _turnHistory
            .asMap()
            .entries
            .map((e) => 'Turn ${e.key + 1}: ${e.value}')
            .join('\n');
    awaitingClarification = false;

    traceSteps.clear();
    lastBooking = null;
    status = RunStatus.running;
    errorMessage = null;
    _lockedMode = selectedProviderId != null;
    _announcedAgents.clear();
    notifyListeners();

    try {
      final uid = userId;
      await for (final evt in _api.run(
        userId: uid,
        userInput: composedInput,
        language: auth.language,
        selectedProviderId: selectedProviderId,
        selectedTimeIso: selectedTimeIso,
        priorIntent: priorIntent,
        userGender: auth.gender,
        // Name + phone flow through to the backend so the admin
        // dashboard shows real names instead of Firebase UIDs.
        userName: auth.displayName,
        userPhone: auth.phone,
      )) {
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

  /// Called when the user taps a provider tile in the chat picker. Locks the
  /// choice and fires a follow-up run that books that specific provider.
  Future<void> pickProvider(ProviderOption option) async {
    if (status == RunStatus.running) return;
    // Strip the alternatives from the message that produced this pick so the
    // picker collapses to a single non-interactive bubble.
    for (int i = messages.length - 1; i >= 0; i--) {
      if (messages[i].alternatives != null) {
        final m = messages[i];
        messages[i] = ChatMessage(
          text: m.text,
          fromUser: false,
          language: m.language,
          ts: m.ts,
        );
        break;
      }
    }
    // Echo the user's choice in the chat so the conversation reads naturally.
    final lang = auth.language;
    final echoText = lang == 'ur'
        ? 'منتخب کیا: ${option.providerName}'
        : lang == 'roman_ur'
            ? 'Select kiya: ${option.providerName}'
            : 'Selected: ${option.providerName}';
    messages.add(ChatMessage(text: echoText, fromUser: true));
    notifyListeners();

    await _runWithInput(
      echoText,
      selectedProviderId: option.providerId,
      selectedTimeIso: option.iso,
      // Forward the cached intent so the backend skips re-parsing it.
      priorIntent: _lastIntent,
    );
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
          _maybeCacheIntent(evt.data);
          _maybeAnnouncePipelineProgress(evt.data);
        } catch (_) {/* ignore malformed */}
        break;
      case 'user_message':
        final txt = evt.data['text'] as String?;
        final lang = evt.data['language'] as String?;
        // Parse alternatives if present — used by both "show_options" (top-3
        // picker after ranking) and "needs_user_choice" (booking fallback).
        final altsRaw = evt.data['alternatives'] as List?;
        final alts = altsRaw
            ?.whereType<Map<String, dynamic>>()
            .where((m) => m['provider_id'] != null)
            .map(ProviderOption.fromJson)
            .toList();
        if (txt != null && txt.isNotEmpty) {
          messages.add(ChatMessage(
            text: txt,
            fromUser: false,
            language: lang,
            alternatives: alts != null && alts.isNotEmpty ? alts : null,
          ));
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
          // Don't fire the "still there?" reminder when the latest message is
          // a picker — the user has visible tiles to tap. Reminders are for
          // open-ended clarification questions where the user might be stuck.
          final latest = messages.isNotEmpty ? messages.last : null;
          final isPicker = latest?.alternatives != null && latest!.alternatives!.isNotEmpty;
          if (!isPicker) {
            _armFollowUpReminder();
          }
        } else if (completionStatus == 'failed' || completionStatus == 'aborted') {
          // Pipeline ended without a booking. Drop any intent-stashed
          // placeholder so we don't strand a PENDING card forever.
          awaitingClarification = false;
          _turnHistory.clear();
          _cancelFollowUpReminder();
          lastBooking = null;
        } else {
          awaitingClarification = false;
          _turnHistory.clear();
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
      // Use the booking agent's raw status verbatim — do NOT collapse
      // 'requested' into 'confirmed'. The booking is only confirmed after
      // the provider explicitly accepts in their app.
      final rawStatus = (out['status'] as String?) ?? '';
      final id = out['booking_id'] as String?;
      final normalized = rawStatus.isNotEmpty
          ? rawStatus
          : (id != null ? 'requested' : 'pending');
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
    }
    // NOTE: we deliberately do NOT stash a placeholder booking card from the
    // intent step. The card stays hidden until the booking agent actually
    // runs — during discovery/ranking the user sees progress chat messages
    // instead, which feels less like the system has already booked something.
  }

  /// Inject a friendly bot chat message at each pipeline stage transition so
  /// the user knows *what's happening* instead of staring at a silent trace
  /// panel. Localized to the user's language. Skipped in locked-mode runs
  /// (user already picked a provider — orchestrator goes straight to booking).
  void _maybeAnnouncePipelineProgress(Map<String, dynamic> step) {
    final agent = step['agent'] as String?;
    if (agent == null) return;
    if (_announcedAgents.contains(agent)) return;
    _announcedAgents.add(agent);

    // Skip during the second run after a picker choice — orchestrator only
    // runs intent + booking, and the user already knows what's happening.
    if (_lockedMode && agent != 'booking') return;

    final out = step['output'] as Map<String, dynamic>?;
    final lang = auth.language;
    String? text;

    // Extract the service category from the intent so progress messages
    // can reference what we're actually looking for ("AC technician",
    // "plumber") instead of the generic "providers".
    final intentOut = traceSteps
        .lastWhere(
          (s) => s.agent == 'intent' && s.output != null,
          orElse: () => TraceStep(agent: '', reasoning: '', toolsCalled: const [], output: const {}, ms: 0, ts: ''),
        )
        .output;
    final intentCat = (intentOut?['service'] as Map<String, dynamic>?)?['category_id'] as String?;
    final stepCat = (out?['service'] as Map<String, dynamic>?)?['category_id'] as String?;
    final activeCategory = stepCat ?? intentCat ?? lastBooking?.category;

    switch (agent) {
      case 'intent':
        // Don't announce after intent if it ended in clarification — the
        // clarification question itself is the user-facing message.
        final needsClarif = out?['needs_clarification'] == true;
        if (needsClarif) return;
        text = _progressMsg(lang, _ProgressStage.finding, categoryId: activeCategory);
        break;
      case 'discovery':
        text = _progressMsg(lang, _ProgressStage.picking, categoryId: activeCategory);
        break;
      case 'ranking':
        // If ranking produced options for the user to pick, the picker UI
        // is enough — no extra chat noise. Otherwise (auto-book path),
        // announce that we're proceeding to book.
        final hasOptions = (out?['alternatives'] as List?)?.isNotEmpty ?? false;
        if (hasOptions) return;
        text = _progressMsg(lang, _ProgressStage.booking, categoryId: activeCategory);
        break;
      case 'booking':
        // Booking just placed. If status is requested, we're waiting for
        // provider acceptance — surface that explicitly in chat AND fire a
        // local notification so the user knows even from another screen.
        final bStatus = (out?['status'] as String?) ?? '';
        final providerName = lastBooking?.providerName ?? '';
        final categoryId = lastBooking?.category;
        if (bStatus == 'requested' || bStatus == 'matched') {
          text = _progressMsg(lang, _ProgressStage.waiting,
              providerName: providerName, categoryId: categoryId);
          if (providerName.isNotEmpty) {
            Notifications.instance.bookingRequested(providerName: providerName);
          }
        }
        break;
    }

    if (text != null && text.isNotEmpty) {
      messages.add(ChatMessage(text: text, fromUser: false, language: lang));
    }
  }

  /// Stash the intent agent's full output so we can echo it back on the next
  /// /run (when the user picks a provider). Skipping the intent re-parse in
  /// locked mode saves ~10 s.
  void _maybeCacheIntent(Map<String, dynamic> step) {
    if (step['agent'] != 'intent') return;
    final out = step['output'] as Map<String, dynamic>?;
    if (out == null) return;
    // Only cache fully-resolved intents (skip clarification asks).
    if (out['needs_clarification'] == true) return;
    _lastIntent = Map<String, dynamic>.from(out);
  }

  /// Build a "Previous conversation:" preamble from the last N messages BEFORE
  /// the current request. This is what gives the bot memory of earlier in the
  /// session — without it, every new request is treated as a fresh user with
  /// no history, which is what the user noticed.
  ///
  /// Excludes the user messages that are already represented in `_turnHistory`
  /// (those are the CURRENT request being built). Keeps it short — last 8
  /// messages — to avoid bloating the prompt.
  // ignore: unused_element
  String _conversationMemoryPreamble_dead() {
    final excludeCount = _turnHistory.length;
    int seenUser = 0;
    int cutoff = messages.length;
    for (int i = messages.length - 1; i >= 0; i--) {
      if (messages[i].fromUser) {
        seenUser++;
        if (seenUser >= excludeCount) {
          cutoff = i;
          break;
        }
      }
    }
    if (cutoff <= 0) return '';
    final prior = messages.sublist(0, cutoff);
    if (prior.isEmpty) return '';
    final window = prior.length > 8
        ? prior.sublist(prior.length - 8)
        : prior;
    final body = window
        .map((m) => '${m.fromUser ? "User" : "Bot"}: ${m.text}')
        .join('\n');
    return 'Previous conversation (context only — do not re-merge into current request):\n$body\n---';
  }

  /// Human-friendly service-category label per language. Maps the internal
  /// taxonomy id (e.g. "ac_technician") to what a user would actually say
  /// ("AC technician" / "اے سی ٹیکنیشن" / "AC technician").
  String _categoryLabel(String? categoryId, String lang) {
    if (categoryId == null || categoryId.isEmpty) {
      return {'en': 'service', 'ur': 'سروس', 'roman_ur': 'service'}[lang] ?? 'service';
    }
    const labels = {
      'plumber': {'en': 'plumber', 'ur': 'پلمبر', 'roman_ur': 'plumber'},
      'electrician': {'en': 'electrician', 'ur': 'الیکٹریشن', 'roman_ur': 'electrician'},
      'ac_technician': {'en': 'AC technician', 'ur': 'اے سی ٹیکنیشن', 'roman_ur': 'AC technician'},
      'carpenter': {'en': 'carpenter', 'ur': 'بڑھئی', 'roman_ur': 'carpenter'},
      'painter': {'en': 'painter', 'ur': 'پینٹر', 'roman_ur': 'painter'},
      'locksmith': {'en': 'locksmith', 'ur': 'لوہار', 'roman_ur': 'locksmith'},
      'welder': {'en': 'welder', 'ur': 'ویلڈر', 'roman_ur': 'welder'},
      'mason': {'en': 'mason', 'ur': 'مزدور', 'roman_ur': 'mason'},
      'pest_control': {'en': 'pest control', 'ur': 'پیسٹ کنٹرول', 'roman_ur': 'pest control'},
      'cctv_installer': {'en': 'CCTV installer', 'ur': 'سی سی ٹی وی', 'roman_ur': 'CCTV installer'},
      'internet_tech': {'en': 'internet technician', 'ur': 'انٹرنیٹ ٹیکنیشن', 'roman_ur': 'internet technician'},
      'mobile_repair': {'en': 'mobile repair', 'ur': 'موبائل ریپیئر', 'roman_ur': 'mobile repair'},
      'laptop_repair': {'en': 'laptop repair', 'ur': 'لیپ ٹاپ ریپیئر', 'roman_ur': 'laptop repair'},
      'auto_mechanic': {'en': 'mechanic', 'ur': 'مکینک', 'roman_ur': 'mechanic'},
      'mehndi_artist': {'en': 'mehndi artist', 'ur': 'مہندی آرٹسٹ', 'roman_ur': 'mehndi artist'},
      'photographer': {'en': 'photographer', 'ur': 'فوٹوگرافر', 'roman_ur': 'photographer'},
      'event_planner': {'en': 'event planner', 'ur': 'ایونٹ پلانر', 'roman_ur': 'event planner'},
      'beautician': {'en': 'beautician', 'ur': 'بیوٹیشن', 'roman_ur': 'beautician'},
      'tutor': {'en': 'tutor', 'ur': 'ٹیوٹر', 'roman_ur': 'tutor'},
      'quran_teacher': {'en': 'Quran teacher', 'ur': 'قرآن ٹیچر', 'roman_ur': 'Quran teacher'},
      'cook': {'en': 'cook', 'ur': 'باورچی', 'roman_ur': 'cook'},
      'cleaner': {'en': 'cleaner', 'ur': 'صفائی والا', 'roman_ur': 'cleaner'},
      'driver': {'en': 'driver', 'ur': 'ڈرائیور', 'roman_ur': 'driver'},
      'personal_trainer': {'en': 'personal trainer', 'ur': 'ٹرینر', 'roman_ur': 'trainer'},
      'yoga_instructor': {'en': 'yoga instructor', 'ur': 'یوگا انسٹرکٹر', 'roman_ur': 'yoga instructor'},
      'gardener': {'en': 'gardener', 'ur': 'مالی', 'roman_ur': 'mali'},
      'babysitter': {'en': 'babysitter', 'ur': 'بے بی سیٹر', 'roman_ur': 'babysitter'},
      'eldercare': {'en': 'eldercare', 'ur': 'بزرگوں کی دیکھ بھال', 'roman_ur': 'eldercare'},
      'laundry': {'en': 'laundry service', 'ur': 'لانڈری', 'roman_ur': 'laundry'},
      'tailor': {'en': 'tailor', 'ur': 'درزی', 'roman_ur': 'tailor'},
      'packer_mover': {'en': 'packer & mover', 'ur': 'پیکر اینڈ موور', 'roman_ur': 'packer mover'},
      'massage_therapist': {'en': 'massage therapist', 'ur': 'مساج تھیراپسٹ', 'roman_ur': 'massage therapist'},
    };
    final entry = labels[categoryId];
    if (entry == null) {
      // Unknown taxonomy id — best-effort prettify ("ac_technician" → "ac technician").
      return categoryId.replaceAll('_', ' ');
    }
    return entry[lang] ?? entry['en']!;
  }

  String _progressMsg(String lang, _ProgressStage stage,
      {String providerName = '', String? categoryId}) {
    final p = providerName.isNotEmpty ? providerName : 'provider';
    final cat = _categoryLabel(categoryId, lang);
    // Bot's grammatical gender mirrors the bot's voice gender, which mirrors
    // the user's gender. In Urdu/Roman Urdu, first-person verbs change form
    // by speaker gender ("dhond raha hoon" male vs "dhond rahi hoon" female).
    final isFemale = auth.gender == 'female';
    switch (stage) {
      case _ProgressStage.finding:
        return {
          'en': 'Got it. Searching for a $cat nearby…',
          'ur': isFemale
              ? 'ٹھیک ہے۔ قریب میں $cat تلاش کر رہی ہوں…'
              : 'ٹھیک ہے۔ قریب میں $cat تلاش کر رہا ہوں…',
          'roman_ur': isFemale
              ? 'Theek hai. Aas paas $cat dhoond rahi hoon…'
              : 'Theek hai. Aas paas $cat dhoond raha hoon…',
        }[lang] ?? 'Got it. Searching for a $cat nearby…';
      case _ProgressStage.picking:
        return {
          'en': 'Found a few options — picking the best $cat for you…',
          'ur': isFemale
              ? 'کچھ آپشن ملے — آپ کے لیے بہترین $cat چن رہی ہوں…'
              : 'کچھ آپشن ملے — آپ کے لیے بہترین $cat چن رہا ہوں…',
          'roman_ur': isFemale
              ? 'Kuch options mil gaye — aap ke liye best $cat select kar rahi hoon…'
              : 'Kuch options mil gaye — aap ke liye best $cat select kar raha hoon…',
        }[lang] ?? 'Found a few options — picking the best $cat for you…';
      case _ProgressStage.booking:
        return {
          'en': 'Booking the $cat now…',
          'ur': isFemale ? '$cat کی بکنگ کر رہی ہوں…' : '$cat کی بکنگ کر رہا ہوں…',
          'roman_ur': isFemale
              ? '$cat ki booking kar rahi hoon…'
              : '$cat ki booking kar raha hoon…',
        }[lang] ?? 'Booking the $cat now…';
      case _ProgressStage.waiting:
        // Reference the SERVICE category (e.g. "AC technician") plus a
        // first-person gendered verb so it reads as the assistant speaking
        // in the bot's voice.
        return {
          'en': 'Booking sent. Waiting for the $cat to confirm…',
          'ur': isFemale
              ? '$cat کی تصدیق کا انتظار کر رہی ہوں…'
              : '$cat کی تصدیق کا انتظار کر رہا ہوں…',
          'roman_ur': isFemale
              ? '$cat ki confirmation ka intezaar kar rahi hoon…'
              : '$cat ki confirmation ka intezaar kar raha hoon…',
        }[lang] ?? 'Booking sent. Waiting for the $cat to confirm…';
      case _ProgressStage.confirmed:
        return {
          'en': '$p confirmed your booking! They\'ll be on their way.',
          'ur': '$p نے $cat کی بکنگ منظور کر لی! وہ آ رہے ہیں۔',
          'roman_ur': '$p ne $cat ki booking confirm kar di! Aa rahe hain.',
        }[lang] ?? '$p confirmed your booking!';
    }
  }

  void _finalizeBooking(Map<String, dynamic> data) {
    // The run_complete event carries the PIPELINE status ('complete'/'failed'),
    // not the booking's own lifecycle status. Don't let it overwrite the
    // 'requested'/'confirmed' value that _maybeExtractBookingFromStep already
    // set from the booking agent's actual output.
    final id = data['booking_id'] as String?;
    if (id != null && lastBooking != null && lastBooking!.bookingId == null) {
      // Only fill in a missing booking_id; keep the status set by the booking step.
      lastBooking = BookingResult(
        bookingId: id,
        providerName: lastBooking?.providerName,
        category: lastBooking?.category,
        whenIso: lastBooking?.whenIso,
        location: lastBooking?.location,
        estimatedPricePkr: lastBooking?.estimatedPricePkr,
        followUps: lastBooking?.followUps ?? const [],
        status: lastBooking?.status ?? 'requested',
      );
    }
    // If the booking is awaiting provider acceptance, poll until it flips
    // to confirmed (or terminal). The provider taps Accept in their Jobs tab,
    // and the customer's card animates from WAITING → CONFIRMED live.
    final actualStatus = lastBooking?.status ?? '';
    if (id != null &&
        (actualStatus == 'requested' || actualStatus == 'matched')) {
      _startBookingPoll(id);
    }
  }

  // ─── Live booking-status polling ────────────────────────────────────────
  Timer? _pollTimer;

  void _startBookingPoll(String bookingId) {
    _pollTimer?.cancel();
    // 2s poll keeps booking-status updates feeling real-time (status
    // flips from "requested" to "confirmed" within ~2s of the provider
    // accepting). Cheap: single GET /bookings/:id per tick.
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (t) async {
      if (lastBooking?.bookingId != bookingId) {
        t.cancel();
        return;
      }
      try {
        final fresh = await _userApi.fetchBooking(bookingId);
        if (fresh == null) {
          t.cancel();
          return;
        }
        final newStatus = fresh['status'] as String? ?? '';
        if (newStatus == lastBooking?.status) return;
        final oldStatus = lastBooking?.status ?? '';
        // Status changed — update the card and notify listeners
        final providerName = lastBooking?.providerName ?? (fresh['provider_name'] as String?);
        lastBooking = BookingResult(
          bookingId: bookingId,
          providerName: providerName,
          category: lastBooking?.category,
          whenIso: lastBooking?.whenIso,
          location: lastBooking?.location,
          estimatedPricePkr: lastBooking?.estimatedPricePkr,
          followUps: lastBooking?.followUps ?? const [],
          status: newStatus,
        );

        // Inform the user in chat AND via local push notification when
        // notable status transitions happen. Chat keeps the conversation
        // coherent; notifications surface updates even if the user is on
        // another screen.
        final pName = providerName ?? 'provider';
        final lang = auth.language;
        if (newStatus == 'confirmed' && oldStatus != 'confirmed') {
          messages.add(ChatMessage(
            text: _progressMsg(lang, _ProgressStage.confirmed,
                providerName: pName, categoryId: lastBooking?.category),
            fromUser: false,
            language: lang,
          ));
          Notifications.instance.bookingConfirmed(
            providerName: pName,
            category: lastBooking?.category,
          );
        } else if (newStatus == 'completed' && oldStatus != 'completed') {
          Notifications.instance.bookingCompleted(providerName: pName);
        }

        notifyListeners();
        // Stop polling on terminal status
        if (newStatus == 'confirmed' ||
            newStatus == 'cancelled' ||
            newStatus == 'completed' ||
            newStatus == 'in_progress' ||
            newStatus == 'reminded') {
          t.cancel();
        }
      } catch (_) {
        // transient — keep polling
      }
    });
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

  Future<void> _fireFollowUp(int n) async {
    if (!awaitingClarification) return; // user already responded
    final lang = messages.isNotEmpty
        ? (messages.last.language ?? auth.language)
        : auth.language;
    // Ask the backend for a context-aware nudge based on the actual
    // conversation. Falls back to a soft hardcoded line if the call fails so
    // we never leave the user hanging.
    final text = await _userApi.followUpNudge(
          language: lang,
          transcript: _transcriptForNudge(),
          attempt: n,
          userGender: auth.gender,
        ) ??
        _followUpFallback(n, lang);
    if (!awaitingClarification) return; // user replied while we were waiting
    messages.add(ChatMessage(text: text, fromUser: false, language: lang));
    notifyListeners();
  }

  /// Send the last few turns (user + bot) to the nudge endpoint so the AI
  /// can write a message that REFERENCES what the user was trying to do.
  List<Map<String, String>> _transcriptForNudge() {
    final tail = messages.length > 8 ? messages.sublist(messages.length - 8) : messages;
    return tail.map((m) => {
          'role': m.fromUser ? 'user' : 'bot',
          'text': m.text,
        }).toList();
  }

  /// Last-resort fallback only — the backend usually generates a better
  /// message via _userApi.followUpNudge. Kept short, language-aware, and
  /// gender-aware (bot's grammatical gender matches its voice gender).
  String _followUpFallback(int n, String lang) {
    final isFemale = auth.gender == 'female';
    final messagesByLang = {
      'en': [
        'Still there? Happy to keep helping when you\'re ready.',
        "I'll close this for now — message me anytime to pick it back up.",
      ],
      'ur': [
        'کیا آپ موجود ہیں؟ جب تیار ہوں بتا دیجیے۔',
        isFemale
            ? 'فی الحال یہ بند کر رہی ہوں — جب چاہیں دوبارہ پیغام بھیج دیں۔'
            : 'فی الحال یہ بند کر رہا ہوں — جب چاہیں دوبارہ پیغام بھیج دیں۔',
      ],
      'roman_ur': [
        'Aap hain? Jab ready hon batadein.',
        isFemale
            ? 'Filhal ye close kar rahi hoon — jab chahein message kar dijiye.'
            : 'Filhal ye close kar raha hoon — jab chahein message kar dijiye.',
      ],
    };
    final pool = messagesByLang[lang] ?? messagesByLang['en']!;
    return pool[(n - 1).clamp(0, pool.length - 1)];
  }

  /// Called by the Live voice screen when the Gemini Live bridge streams an
  /// agent_step event from the wrapped 5-agent orchestrator. Updates the
  /// trace panel + booking card ONLY — does NOT add to chat messages or
  /// trigger chat TTS. Live is already narrating the result over its own
  /// audio channel; running chat TTS in parallel causes double-voice.
  void handleVoiceLiveStep(Map<String, dynamic> sseEvent) {
    final ev = sseEvent['event'] as String?;
    final data = sseEvent['data'] as Map<String, dynamic>? ?? const {};
    if (ev == null) return;
    switch (ev) {
      case 'run_started':
        currentRunId = data['run_id'] as String?;
        break;
      case 'step':
        // Trace panel + booking-card extraction. No chat-message side
        // effects, no TTS.
        try {
          traceSteps.add(TraceStep.fromJson(data));
          _maybeExtractBookingFromStep(data);
          _maybeCacheIntent(data);
        } catch (_) {/* ignore malformed */}
        break;
      case 'run_complete':
        currentRunId = data['run_id'] as String? ?? currentRunId;
        break;
      // user_message intentionally skipped — Live is already speaking
      // the equivalent over its own audio path.
    }
    notifyListeners();
  }

  // ─── Persistence ─────────────────────────────────────────────────────────
  // Chat messages survive app restarts so a stray swipe-away doesn't wipe
  // the conversation. We persist on every notifyListeners (debounced) and
  // restore in the constructor.

  Future<void> _restoreFromDisk() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kMessagesKey);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw) as List;
      messages
        ..clear()
        ..addAll(list.whereType<Map<String, dynamic>>().map(ChatMessage.fromJson));
      if (messages.isNotEmpty) notifyListeners();
    } catch (_) {
      // Corrupt cache — ignore, start fresh.
    }
  }

  void _persistToDisk() {
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 400), () async {
      try {
        // Cap stored history at 100 most-recent messages so SharedPreferences
        // doesn't grow unbounded over many sessions.
        final tail = messages.length > 100
            ? messages.sublist(messages.length - 100)
            : messages;
        final json = jsonEncode(tail.map((m) => m.toJson()).toList());
        final p = await SharedPreferences.getInstance();
        await p.setString(_kMessagesKey, json);
      } catch (_) {/* best-effort */}
    });
  }

  /// Wipe the on-disk chat history (used by signOut / "clear chat" actions).
  Future<void> clearPersistedChat() async {
    messages.clear();
    lastBooking = null;
    traceSteps.clear();
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_kMessagesKey);
    } catch (_) {}
  }

  @override
  void notifyListeners() {
    super.notifyListeners();
    _persistToDisk();
  }

  @override
  void dispose() {
    _cancelFollowUpReminder();
    _pollTimer?.cancel();
    _persistDebounce?.cancel();
    super.dispose();
  }
}
