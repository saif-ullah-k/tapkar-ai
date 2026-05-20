/// Data models mirroring the backend.
/// Source of truth is backend/src/types.ts — keep in sync.

class TraceStep {
  final String agent;
  final String reasoning;
  final List<ToolCall> toolsCalled;
  final dynamic output;
  final int ms;
  final String ts;

  TraceStep({
    required this.agent,
    required this.reasoning,
    required this.toolsCalled,
    required this.output,
    required this.ms,
    required this.ts,
  });

  factory TraceStep.fromJson(Map<String, dynamic> j) => TraceStep(
        agent: j['agent'] ?? '',
        reasoning: j['reasoning'] ?? '',
        toolsCalled: (j['tools_called'] as List? ?? [])
            .map((e) => ToolCall.fromJson(e as Map<String, dynamic>))
            .toList(),
        output: j['output'],
        ms: (j['ms'] ?? 0) as int,
        ts: j['ts'] ?? '',
      );
}

class ToolCall {
  final String name;
  final dynamic input;
  final dynamic output;
  final int ms;

  ToolCall({
    required this.name,
    required this.input,
    required this.output,
    required this.ms,
  });

  factory ToolCall.fromJson(Map<String, dynamic> j) => ToolCall(
        name: j['name'] ?? '',
        input: j['input'],
        output: j['output'],
        ms: (j['ms'] ?? 0) as int,
      );
}

class ChatMessage {
  final String text;
  final bool fromUser;
  final String? language; // 'en' | 'ur' | 'roman_ur'
  final DateTime ts;
  /// When the backend yields a `show_options` user_message, the alternatives
  /// array is carried here so the chat can render a 3-tile picker instead of
  /// a plain text bubble. Cleared once the user picks one.
  final List<ProviderOption>? alternatives;

  ChatMessage({
    required this.text,
    required this.fromUser,
    this.language,
    this.alternatives,
    DateTime? ts,
  }) : ts = ts ?? DateTime.now();

  /// Serialize for SharedPreferences persistence. Picker `alternatives` are
  /// intentionally NOT persisted — they reference a live ranking run; on
  /// reload we treat them as already-resolved so the chat stays clean.
  Map<String, dynamic> toJson() => {
        'text': text,
        'fromUser': fromUser,
        if (language != null) 'language': language,
        'ts': ts.toIso8601String(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        text: (j['text'] as String?) ?? '',
        fromUser: (j['fromUser'] as bool?) ?? false,
        language: j['language'] as String?,
        ts: DateTime.tryParse(j['ts'] as String? ?? '') ?? DateTime.now(),
      );
}

class ProviderOption {
  final String providerId;
  final String providerName;
  final double? rating;
  final int? reviewCount;
  final double? distanceKm;
  final List<int>? priceRangePkr;
  final String? neighborhood;
  final bool verified;
  final String? iso;
  final String reasoning;
  final String tradeoffs;

  ProviderOption({
    required this.providerId,
    required this.providerName,
    this.rating,
    this.reviewCount,
    this.distanceKm,
    this.priceRangePkr,
    this.neighborhood,
    this.verified = false,
    this.iso,
    this.reasoning = '',
    this.tradeoffs = '',
  });

  factory ProviderOption.fromJson(Map<String, dynamic> j) => ProviderOption(
        providerId: j['provider_id'] as String? ?? '',
        providerName: j['provider_name'] as String? ?? 'Unknown',
        rating: (j['rating'] as num?)?.toDouble(),
        reviewCount: j['review_count'] as int?,
        distanceKm: (j['distance_km'] as num?)?.toDouble(),
        priceRangePkr: (j['price_range_pkr'] as List?)
            ?.map((e) => (e as num).toInt())
            .toList(),
        neighborhood: j['neighborhood'] as String?,
        verified: j['verified'] as bool? ?? false,
        iso: j['iso'] as String?,
        reasoning: j['reasoning'] as String? ?? '',
        tradeoffs: j['tradeoffs'] as String? ?? '',
      );
}

class BookingResult {
  final String? bookingId;
  final String? providerName;
  final String? category;
  final String? whenIso;
  final String? location;
  final List<int>? estimatedPricePkr;
  final List<ScheduledJob> followUps;
  final String status;

  BookingResult({
    this.bookingId,
    this.providerName,
    this.category,
    this.whenIso,
    this.location,
    this.estimatedPricePkr,
    this.followUps = const [],
    required this.status,
  });
}

class ScheduledJob {
  final String type;
  final String fireAtIso;
  final String purpose;
  final String language;
  final String messagePreview;

  ScheduledJob({
    required this.type,
    required this.fireAtIso,
    required this.purpose,
    required this.language,
    required this.messagePreview,
  });

  factory ScheduledJob.fromJson(Map<String, dynamic> j) => ScheduledJob(
        type: j['type'] ?? '',
        fireAtIso: j['fire_at_iso'] ?? '',
        purpose: j['purpose'] ?? '',
        language: j['language'] ?? 'en',
        messagePreview: j['message_preview'] ?? '',
      );
}
