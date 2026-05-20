import 'package:flutter/material.dart';
import '../services/provider_api.dart';
import '../state/auth_state.dart';
import '../theme.dart';

/// Lets the user pick which provider they want to "log in as".
/// In production, this would be a real auth flow.
class RolePickerScreen extends StatefulWidget {
  final VoidCallback onCancel;
  final AuthState? auth;
  const RolePickerScreen({super.key, required this.onCancel, this.auth});

  @override
  State<RolePickerScreen> createState() => _RolePickerScreenState();
}

class _RolePickerScreenState extends State<RolePickerScreen> {
  final ProviderApi _api = ProviderApi();
  List<Map<String, dynamic>> _providers = [];
  bool _loading = true;
  String? _error;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ps = await _api.listProviders();
      setState(() {
        _providers = ps;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _search.isEmpty
        ? _providers
        : _providers.where((p) {
            final name = (p['name'] as String? ?? '').toLowerCase();
            final cat = (p['category'] as String? ?? '').toLowerCase();
            return name.contains(_search.toLowerCase()) ||
                cat.contains(_search.toLowerCase());
          }).toList();

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        leading: IconButton(
            icon: const Icon(Icons.close, color: Colors.white60),
            onPressed: widget.onCancel),
        title: Text('Log in as a provider',
            style: AppFonts.base(size: 15, weight: FontWeight.w700)),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                onChanged: (v) => setState(() => _search = v),
                style: AppFonts.base(size: 14),
                decoration: InputDecoration(
                  hintText: 'Search by name or service…',
                  hintStyle: AppFonts.base(size: 13, color: Colors.white38),
                  prefixIcon: const Icon(Icons.search, size: 18, color: Colors.white60),
                  isDense: true,
                  filled: true,
                  fillColor: AppColors.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: AppColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: AppColors.border),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${filtered.length} providers · tap any to switch into their account',
                  style: AppFonts.base(size: 11, color: Colors.white54),
                ),
              ),
            ),
            Expanded(child: _body(filtered)),
          ],
        ),
      ),
    );
  }

  Widget _body(List<Map<String, dynamic>> filtered) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 36),
              const SizedBox(height: 8),
              Text('Failed to load providers',
                  style: AppFonts.base(size: 14, weight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: AppFonts.base(size: 11, color: Colors.white60)),
              const SizedBox(height: 12),
              ElevatedButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: filtered.length,
      itemBuilder: (_, i) {
        final p = filtered[i];
        return ListTile(
          dense: true,
          leading: CircleAvatar(
            backgroundColor: AppColors.surface2,
            child: Text(_iconForCategory(p['category'] as String?),
                style: const TextStyle(fontSize: 18)),
          ),
          title: Text(p['name'] as String? ?? '?',
              style: AppFonts.base(size: 13, weight: FontWeight.w600)),
          subtitle: Text(
            '${_titleCase((p['category'] as String? ?? '').replaceAll('_', ' '))}  ·  '
            '${p['neighborhood'] ?? '?'}  ·  '
            '⭐ ${p['rating'] ?? '?'}  ·  '
            '${p['jobs_completed'] ?? 0} jobs',
            style: AppFonts.base(size: 11, color: Colors.white60),
          ),
          trailing: const Icon(Icons.arrow_forward_ios, size: 12, color: Colors.white38),
          onTap: () async {
            // Persist provider identity into AuthState. main.dart's AnimatedBuilder
            // sees isProviderMode flip and swaps the shell — no manual navigation.
            await widget.auth?.switchToProvider(
              providerId: p['id'] as String,
              providerName: p['name'] as String? ?? '?',
              providerCategory: p['category'] as String?,
            );
            if (!context.mounted) return;
            Navigator.of(context).pop();
          },
        );
      },
    );
  }

  String _titleCase(String s) => s
      .split(' ')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');

  String _iconForCategory(String? cat) {
    switch (cat) {
      case 'plumber':
        return '🔧';
      case 'electrician':
        return '⚡';
      case 'ac_technician':
        return '❄️';
      case 'carpenter':
        return '🪚';
      case 'tutor':
        return '📚';
      case 'beautician':
        return '💄';
      case 'mehndi_artist':
        return '🌺';
      case 'quran_teacher':
        return '📖';
      case 'cook':
        return '🍳';
      case 'driver':
        return '🚗';
      case 'cleaner':
        return '🧹';
      default:
        return '👤';
    }
  }
}
