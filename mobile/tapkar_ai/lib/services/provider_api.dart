import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api.dart' show ApiException;

/// Lightweight client for the provider-side endpoints.
class ProviderApi {
  static const String baseUrl =
      String.fromEnvironment('API_URL', defaultValue: 'http://10.0.2.2:8080');

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
}
