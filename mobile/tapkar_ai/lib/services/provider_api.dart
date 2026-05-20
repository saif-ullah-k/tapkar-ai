import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api.dart' show ApiException;

/// Lightweight client for the provider-side endpoints.
class ProviderApi {
  static const String baseUrl =
      String.fromEnvironment('API_URL', defaultValue: 'https://tapkar-ai-backend-d56rhra4sa-uc.a.run.app');

  Future<List<Map<String, dynamic>>> listProviders() async {
    final r = await http
        .get(Uri.parse('$baseUrl/providers'))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) throw ApiException('HTTP ${r.statusCode}');
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(body['providers'] as List? ?? []);
  }

  Future<List<Map<String, dynamic>>> listMyBookings(String providerId) async {
    final r = await http
        .get(Uri.parse('$baseUrl/providers/$providerId/bookings'))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) throw ApiException('HTTP ${r.statusCode}');
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(body['bookings'] as List? ?? []);
  }

  Future<List<Map<String, dynamic>>> listMyInbox(String providerId) async {
    final r = await http
        .get(Uri.parse('$baseUrl/providers/$providerId/inbox'))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) throw ApiException('HTTP ${r.statusCode}');
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(body['messages'] as List? ?? []);
  }

  Future<void> updateBooking({
    required String providerId,
    required String bookingId,
    required String action,
  }) async {
    final r = await http
        .post(
          Uri.parse('$baseUrl/providers/$providerId/bookings/$bookingId/action'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'action': action}),
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw ApiException('HTTP ${r.statusCode}: ${r.body}');
    }
  }

  /// Look up an existing provider profile by Firebase user_id. Returns the
  /// provider object (or null if this user hasn't registered as a provider).
  Future<Map<String, dynamic>?> findProviderByUser(String userId) async {
    final r = await http
        .get(Uri.parse('$baseUrl/providers/by-user/$userId'))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) throw ApiException('HTTP ${r.statusCode}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Register a new provider from the onboarding wizard.
  Future<Map<String, dynamic>> registerProvider(Map<String, dynamic> body) async {
    final r = await http
        .post(
          Uri.parse('$baseUrl/providers/register'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) {
      throw ApiException('HTTP ${r.statusCode}: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// AI-driven provider setup: send the user's latest chat message + the
  /// current draft, get back the next question, an updated draft, and a
  /// `complete` flag when enough fields have been collected to save.
  Future<Map<String, dynamic>?> providerChat({
    required String userId,
    required String message,
    required Map<String, dynamic> draft,
    required String mode, // 'signup' or 'edit'
    required String language,
    required String userGender,
  }) async {
    try {
      final r = await http
          .post(
            Uri.parse('$baseUrl/provider/chat'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'user_id': userId,
              'message': message,
              'draft': draft,
              'mode': mode,
              'language': language,
              'user_gender': userGender,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) {
        throw ApiException('HTTP ${r.statusCode}: ${r.body}');
      }
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Toggle the provider's "online / accepting jobs right now" flag.
  /// Backend uses this in discovery — providers with available_now=false are
  /// filtered out even if their weekly hours cover the requested time.
  Future<bool> setAvailability({
    required String providerId,
    required String userId,
    required bool availableNow,
  }) async {
    final r = await http
        .post(
          Uri.parse('$baseUrl/providers/$providerId/availability'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'user_id': userId, 'available_now': availableNow}),
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw ApiException('HTTP ${r.statusCode}: ${r.body}');
    }
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return (body['available_now'] as bool?) ?? availableNow;
  }

  /// Update an existing provider profile (provider-side edit screen).
  /// Server preserves rating / review_count / jobs_completed.
  Future<Map<String, dynamic>> updateProvider(
    String providerId,
    Map<String, dynamic> body,
  ) async {
    final r = await http
        .patch(
          Uri.parse('$baseUrl/providers/$providerId'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) {
      throw ApiException('HTTP ${r.statusCode}: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }
}
