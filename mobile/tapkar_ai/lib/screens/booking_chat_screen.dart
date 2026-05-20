import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../theme.dart';

/// One-to-one chat tied to a specific booking. Either side (customer or
/// provider) can open it and message the other party. Backed by
/// /bookings/:id/messages on the server — Firestore-stored. Polls every
/// 2 s while the screen is open so messages feel real-time without
/// needing WebSockets.
class BookingChatScreen extends StatefulWidget {
  /// The booking the chat is tied to.
  final String bookingId;
  /// 'user' or 'provider' — drives bubble alignment + the POST `from` field.
  final String myRole;
  /// Firebase UID (customer) or provider id, matching what's stored on the
  /// booking record. Backend checks the sender_id is a party to the booking.
  final String mySenderId;
  /// Friendly name for the OTHER party — shown in the app bar.
  final String? counterpartName;
  const BookingChatScreen({
    super.key,
    required this.bookingId,
    required this.myRole,
    required this.mySenderId,
    this.counterpartName,
  });

  @override
  State<BookingChatScreen> createState() => _BookingChatScreenState();
}

class _BookingChatScreenState extends State<BookingChatScreen> {
  static String get _baseUrl => const String.fromEnvironment(
        'API_URL',
        defaultValue: 'https://tapkar-ai-backend-d56rhra4sa-uc.a.run.app',
      );

  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  List<Map<String, dynamic>> _msgs = [];
  Timer? _pollTimer;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await http
          .get(Uri.parse('$_baseUrl/bookings/${widget.bookingId}/messages'))
          .timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return;
      final data = jsonDecode(r.body) as Map<String, dynamic>;
      final list = (data['messages'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          const <Map<String, dynamic>>[];
      if (!mounted) return;
      final hadFewer = list.length > _msgs.length;
      setState(() => _msgs = list);
      if (hadFewer) _scrollToEnd();
    } catch (_) {/* ignore transient failures, next tick will retry */}
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _sending = true;
    });
    final body = {
      'from': widget.myRole,
      'sender_id': widget.mySenderId,
      'text': text,
    };
    try {
      final r = await http
          .post(
            Uri.parse('$_baseUrl/bookings/${widget.bookingId}/messages'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        _input.clear();
        await _load(); // grab the persisted version (includes ts)
      } else {
        // Surface the actual error so silent failures aren't a mystery.
        // 400 = bad sender_id / empty text; 403 = not a party to this
        // booking; 404 = booking gone; 500 = persist failure.
        final body = r.body.length > 200 ? r.body.substring(0, 200) : r.body;
        _toast('Send failed (${r.statusCode}): $body');
      }
    } catch (e) {
      _toast('Network error: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.counterpartName?.isNotEmpty == true
        ? widget.counterpartName!
        : (widget.myRole == 'provider' ? 'Customer' : 'Provider');
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            Text('Booking · ${widget.bookingId}',
                style: const TextStyle(fontSize: 10, color: Colors.white54)),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _msgs.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          widget.myRole == 'provider'
                              ? 'No messages yet. Say hi to your customer to coordinate the visit.'
                              : 'No messages yet. Say hi to your provider to coordinate the visit.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white54, fontSize: 13),
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      itemCount: _msgs.length,
                      itemBuilder: (_, i) {
                        final m = _msgs[i];
                        final from = m['from'] as String? ?? '';
                        final mine = from == widget.myRole;
                        final txt = m['text'] as String? ?? '';
                        final ts = m['ts'] as String? ?? '';
                        return Align(
                          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            constraints: BoxConstraints(
                              maxWidth: MediaQuery.of(context).size.width * 0.75,
                            ),
                            decoration: BoxDecoration(
                              gradient: mine
                                  ? const LinearGradient(
                                      colors: [AppColors.violet, AppColors.booking],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    )
                                  : null,
                              color: mine ? null : AppColors.surface,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(txt,
                                    style: const TextStyle(color: Colors.white, fontSize: 14)),
                                if (ts.length >= 16) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    ts.substring(11, 16),
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.55),
                                      fontSize: 9,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: AppColors.border)),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    maxLines: 4,
                    minLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: widget.myRole == 'provider'
                          ? 'Type to customer…'
                          : 'Type to provider…',
                      hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      filled: true,
                      fillColor: AppColors.surface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: const BorderSide(color: AppColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: const BorderSide(color: AppColors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide:
                            BorderSide(color: AppColors.violet.withOpacity(0.6)),
                      ),
                    ),
                    style: const TextStyle(fontSize: 14, color: Colors.white),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  onPressed: _sending ? null : _send,
                  icon: Container(
                    width: 36, height: 36,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [AppColors.violet, AppColors.booking],
                      ),
                    ),
                    child: const Icon(Icons.send, color: Colors.white, size: 18),
                  ),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}
