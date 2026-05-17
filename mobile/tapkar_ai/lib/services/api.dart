import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Backend API client. Streams `/run` events as parsed SSE blocks.
class ApiClient {
  /// Override at build time: --dart-define=API_URL=http://10.0.2.2:8080
  static const String baseUrl =
      String.fromEnvironment('API_URL', defaultValue: 'http://10.0.2.2:8080');

  /// Stream POST /run as Server-Sent Events.
  /// Yields a stream of {event, data} maps as the backend emits them.
  Stream<SseEvent> run({
    required String userId,
    required String userInput,
    String? conversationId,
  }) async* {
    final req = http.Request('POST', Uri.parse('$baseUrl/run'));
    req.headers['Content-Type'] = 'application/json';
    req.headers['Accept'] = 'text/event-stream';
    req.body = jsonEncode({
      'user_id': userId,
      'user_input': userInput,
      if (conversationId != null) 'conversation_id': conversationId,
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
