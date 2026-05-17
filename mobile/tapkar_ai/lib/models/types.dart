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

  ChatMessage({
    required this.text,
    required this.fromUser,
    this.language,
    DateTime? ts,
  }) : ts = ts ?? DateTime.now();
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
