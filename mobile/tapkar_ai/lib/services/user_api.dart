import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api.dart' show ApiException;

/// Customer-side API: bookings, inbox, scheduled reminders, AI follow-up
/// nudge generation.
class UserApi {
  static const String baseUrl =
      String.fromEnvironment('API_URL', defaultValue: 'https://tapkar-ai-backend-d56rhra4sa-uc.a.run.app');

  Future<Map<String, dynamic>?> fetchBooking(String bookingId) async {
    final r = await http
        .get(Uri.parse('$baseUrl/bookings/$bookingId'))
        .timeout(const Duration(seconds: 8));
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) throw ApiException('HTTP ${r.statusCode}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> myBookings(String userId) async {
    final r = await http
        .get(Uri.parse('$baseUrl/users/$userId/bookings'))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw ApiException('HTTP ${r.statusCode}');
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(body['bookings'] as List? ?? []);
  }

  Future<({List<Map<String, dynamic>> messages, List<Map<String, dynamic>> scheduled})>
      myInbox(String userId) async {
    final r = await http
        .get(Uri.parse('$baseUrl/users/$userId/inbox'))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw ApiException('HTTP ${r.statusCode}');
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return (
      messages: List<Map<String, dynamic>>.from(body['messages'] as List? ?? []),
      scheduled: List<Map<String, dynamic>>.from(body['scheduled'] as List? ?? []),
    );
  }

  /// Ask the backend to generate a context-aware "still there?" nudge based
  /// on the recent conversation. Returns null on any failure — caller falls
  /// back to its hardcoded line. `attempt` is 1 (soft) or 2 (closing).
  Future<String?> followUpNudge({
    required String language,
    required List<Map<String, String>> transcript,
    required int attempt,
    String userGender = 'female',
  }) async {
    try {
      final r = await http
          .post(
            Uri.parse('$baseUrl/followup-nudge'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'language': language,
              'transcript': transcript,
              'attempt': attempt,
              'user_gender': userGender,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      final msg = body['message'] as String?;
      return (msg == null || msg.trim().isEmpty) ? null : msg.trim();
    } catch (_) {
      return null;
    }
  }
}
