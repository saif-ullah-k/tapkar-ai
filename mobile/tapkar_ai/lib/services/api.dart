import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Backend API client. Streams `/run` events as parsed SSE blocks.
class ApiClient {
  /// Override at build time: --dart-define=API_URL=http://10.0.2.2:8080 for local dev.
  static const String baseUrl =
      String.fromEnvironment('API_URL', defaultValue: 'https://tapkar-ai-backend-d56rhra4sa-uc.a.run.app');

  /// Stream POST /run as Server-Sent Events.
  /// Yields a stream of {event, data} maps as the backend emits them.
  Stream<SseEvent> run({
    required String userId,
    required String userInput,
    String? language,
    String? selectedProviderId,
    String? selectedTimeIso,
    Map<String, dynamic>? priorIntent,
    String? userGender,
  }) async* {
    final req = http.Request('POST', Uri.parse('$baseUrl/run'));
    req.headers['Content-Type'] = 'application/json';
    req.headers['Accept'] = 'text/event-stream';
    req.body = jsonEncode({
      'user_id': userId,
      'user_input': userInput,
      if (language != null) 'language': language,
      if (selectedProviderId != null) 'selected_provider_id': selectedProviderId,
      if (selectedTimeIso != null) 'selected_time_iso': selectedTimeIso,
      // Echo the intent from the previous run — backend skips re-parsing
      // intent in locked mode, saving ~10 s on the booking flow.
      if (priorIntent != null) 'prior_intent': priorIntent,
      // User's gender — bot speaks with matching grammatical gender in
      // Urdu/Roman Urdu ("dhond rahi hoon" vs "dhond raha hoon").
      if (userGender != null) 'user_gender': userGender,
    });

    final response = await req.send();
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw ApiException('HTTP ${response.statusCode}: $body');
    }

    // SSE parser: events are separated by blank lines; each line is "key: value".
    String buffer = '';
    String? currentEvent;
    final dataLines = <String>[];

    await for (final chunk in response.stream.transform(utf8.decoder)) {
      buffer += chunk;
      while (true) {
        final newlineIdx = buffer.indexOf('\n');
        if (newlineIdx < 0) break;
        final line = buffer.substring(0, newlineIdx).trimRight();
        buffer = buffer.substring(newlineIdx + 1);

        if (line.isEmpty) {
          // Dispatch accumulated event
          if (currentEvent != null && dataLines.isNotEmpty) {
            final raw = dataLines.join('\n');
            try {
              final parsed = jsonDecode(raw);
              yield SseEvent(event: currentEvent, data: parsed as Map<String, dynamic>);
            } catch (_) {
              yield SseEvent(event: currentEvent, data: {'_raw': raw});
            }
          }
          currentEvent = null;
          dataLines.clear();
          continue;
        }

        if (line.startsWith(':')) continue; // comment / heartbeat
        if (line.startsWith('event: ')) {
          currentEvent = line.substring(7).trim();
        } else if (line.startsWith('data: ')) {
          dataLines.add(line.substring(6));
        }
      }
    }
  }

  /// GET /traces/:run_id
  Future<Map<String, dynamic>?> getTrace(String runId) async {
    final res = await http.get(Uri.parse('$baseUrl/traces/$runId'));
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw ApiException('HTTP ${res.statusCode}: ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// GET /healthz — quick connectivity check.
  Future<Map<String, dynamic>> healthz() async {
    final res = await http.get(Uri.parse('$baseUrl/healthz')).timeout(
          const Duration(seconds: 5),
        );
    if (res.statusCode != 200) {
      throw ApiException('HTTP ${res.statusCode}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
}

class SseEvent {
  final String event;
  final Map<String, dynamic> data;
  SseEvent({required this.event, required this.data});

  @override
  String toString() => 'SseEvent($event, ${data.keys.toList()})';
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => 'ApiException: $message';
}
