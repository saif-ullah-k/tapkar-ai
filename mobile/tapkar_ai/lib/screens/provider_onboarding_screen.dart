import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../services/provider_api.dart';
import '../state/auth_state.dart';
import '../theme.dart';

/// Provider profile form. Two modes:
///   - Register (default): first-run for users who signed up with role=provider.
///     Calls POST /providers/register, then auth.switchToProvider() so main.dart
///     routes to ProviderShell.
///   - Edit: provider opens from their Profile tab to change availability /
///     services / areas. Pre-fills from `existing` and PATCHes on submit.
class ProviderOnboardingScreen extends StatefulWidget {
  final AuthState auth;
  /// When non-null, screen renders in edit mode and pre-fills from this map.
  final Map<String, dynamic>? existing;
  const ProviderOnboardingScreen({super.key, required this.auth, this.existing});

  @override
  State<ProviderOnboardingScreen> createState() =>
      _ProviderOnboardingScreenState();
}

class _ProviderOnboardingScreenState extends State<ProviderOnboardingScreen> {
  final _api = ProviderApi();
  final _scrollCtrl = ScrollController();
  final _nameCtrl = TextEditingController();
  final _bioCtrl = TextEditingController();
  final _priceMinCtrl = TextEditingController(text: '1500');
  final _priceMaxCtrl = TextEditingController(text: '6000');

  String? _profileImageDataUrl;

  // Service categories (taxonomy ids). User picks one primary + optional extras.
  final List<_CategoryOption> _allCategories = const [
    _CategoryOption('plumber', '🔧', 'Plumber'),
    _CategoryOption('electrician', '⚡', 'Electrician'),
    _CategoryOption('ac_technician', '❄️', 'AC Technician'),
    _CategoryOption('carpenter', '🪚', 'Carpenter'),
    _CategoryOption('painter', '🎨', 'Painter'),
    _CategoryOption('tutor', '📚', 'Tutor'),
    _CategoryOption('quran_teacher', '📖', 'Quran Teacher'),
    _CategoryOption('beautician', '💄', 'Beautician'),
    _CategoryOption('mehndi_artist', '🌺', 'Mehndi Artist'),
    _CategoryOption('cleaner', '🧹', 'Cleaner'),
    _CategoryOption('cook', '🍳', 'Cook'),
    _CategoryOption('driver', '🚗', 'Driver'),
    _CategoryOption('photographer', '📸', 'Photographer'),
    _CategoryOption('locksmith', '🔑', 'Locksmith'),
  ];
  String? _primaryCategory;
  final Set<String> _extraCategories = {};

  // Karachi neighborhoods — primary + multi-select extras
  final List<String> _allAreas = const [
    'Gulshan-e-Iqbal',
    'DHA Phase 5',
    'DHA Phase 6',
    'Clifton',
    'North Nazimabad',
    'Bahadurabad',
    'Saddar',
    'Korangi',
    'Malir',
    'Federal B Area',
    'PECHS',
    'Nazimabad',
    'Johar',
    'Defence View',
    'Tariq Road',
  ];
  String? _primaryArea;
  final Set<String> _extraAreas = {};

  final List<String> _allLanguages = const ['ur', 'roman_ur', 'en'];
  final Set<String> _languages = {'ur', 'roman_ur'};

  /// Provider's gender — needed for jobs that require a female provider
  /// (bridal makeup, in-home beautician, female-only tutoring) and for the
  /// ranking agent's `female_provider_required` preference to work.
  String _gender = 'male';

  // Weekly schedule — each day has multiple optional time slots so providers
  // can carve out lunch breaks, split shifts, day-off windows, etc.
  final Map<String, _DaySchedule> _schedule = {
    'monday': _DaySchedule(open: true, ranges: [_HourRange(9, 18)]),
    'tuesday': _DaySchedule(open: true, ranges: [_HourRange(9, 18)]),
    'wednesday': _DaySchedule(open: true, ranges: [_HourRange(9, 18)]),
    'thursday': _DaySchedule(open: true, ranges: [_HourRange(9, 18)]),
    'friday': _DaySchedule(open: true, ranges: [_HourRange(9, 18)]),
    'saturday': _DaySchedule(open: true, ranges: [_HourRange(9, 18)]),
    'sunday': _DaySchedule(open: false, ranges: []),
  };

  bool _submitting = false;
  String? _errMsg;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    if (_isEdit) {
      final p = widget.existing!;
      _nameCtrl.text = (p['name'] as String?) ?? widget.auth.name;
      _bioCtrl.text = (p['bio'] as String?) ?? '';
      _gender = (p['gender'] as String?) ?? 'male';
      final price = p['price_range_pkr'] as List?;
      if (price != null && price.length == 2) {
        _priceMinCtrl.text = '${price[0]}';
        _priceMaxCtrl.text = '${price[1]}';
      }
      final img = p['profile_image_url'] as String?;
      if (img != null && img.startsWith('data:')) _profileImageDataUrl = img;
      _primaryCategory = p['category'] as String?;
      _extraCategories.addAll(
        ((p['additional_categories'] as List?) ?? const []).cast<String>(),
      );
      _primaryArea = p['neighborhood'] as String?;
      _extraAreas.addAll(((p['service_areas'] as List?) ?? const []).cast<String>());
      final langs = (p['languages'] as List?)?.cast<String>();
      if (langs != null && langs.isNotEmpty) {
        _languages
          ..clear()
          ..addAll(langs);
      }
      final avail = p['availability'] as Map?;
      if (avail != null) {
        for (final day in _schedule.keys.toList()) {
          final hours = ((avail[day] as List?) ?? const []).cast<String>();
          if (hours.isEmpty) {
            _schedule[day] = _DaySchedule(open: false, ranges: const []);
          } else {
            int parseH(String s) => int.tryParse(s.split(':').first) ?? 9;
            final ranges = hours.map((h) {
              final parts = h.split('-');
              return _HourRange(parseH(parts.first), parseH(parts.length > 1 ? parts[1] : '18'));
            }).toList();
            _schedule[day] = _DaySchedule(open: true, ranges: ranges);
          }
        }
      }
    } else {
      _nameCtrl.text = widget.auth.name;
    }
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _nameCtrl.dispose();
    _bioCtrl.dispose();
    _priceMinCtrl.dispose();
    _priceMaxCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final picker = ImagePicker();
      final file = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 600,
        maxHeight: 600,
        imageQuality: 75,
      );
      if (file == null) return;
      final bytes = await File(file.path).readAsBytes();
      final b64 = base64Encode(bytes);
      setState(() => _profileImageDataUrl = 'data:image/jpeg;base64,$b64');
    } catch (e) {
      setState(() => _errMsg = 'Could not load image: $e');
    }
  }

  Future<void> _submit() async {
    setState(() => _errMsg = null);
    if (_nameCtrl.text.trim().isEmpty) {
      return setState(() => _errMsg = 'Please enter your business name');
    }
    if (_primaryCategory == null) {
      return setState(() => _errMsg = 'Pick at least one service');
    }
    if (_primaryArea == null) {
      return setState(() => _errMsg = 'Pick your primary working area');
    }
    final priceMin = int.tryParse(_priceMinCtrl.text.trim());
    final priceMax = int.tryParse(_priceMaxCtrl.text.trim());
    if (priceMin == null || priceMax == null || priceMin >= priceMax) {
      return setState(() => _errMsg = 'Enter a valid price range (min < max)');
    }

    setState(() => _submitting = true);
    final availability = <String, List<String>>{};
    _schedule.forEach((day, sched) {
      if (!sched.open || sched.ranges.isEmpty) {
        availability[day] = <String>[];
        return;
      }
      // Sort + merge overlapping ranges to keep the schedule clean.
      final sorted = [...sched.ranges]..sort((a, b) => a.from.compareTo(b.from));
      availability[day] = sorted
          .map((r) => '${_pad(r.from)}:00-${_pad(r.to)}:00')
          .toList();
    });

    final payload = <String, dynamic>{
      'user_id': widget.auth.userId,
      'name': _nameCtrl.text.trim(),
      'category': _primaryCategory,
      'additional_categories': _extraCategories.toList(),
      'specializations': <String>[],
      'gender': _gender,
      'neighborhood': _primaryArea,
      'service_areas': _extraAreas.toList(),
      'languages': _languages.toList(),
      'price_range_pkr': [priceMin, priceMax],
      'availability': availability,
      'phone': '+92${widget.auth.phone}',
      'bio': _bioCtrl.text.trim(),
      'profile_image_url': _profileImageDataUrl ?? '',
    };

    try {
      if (_isEdit) {
        final existingId = widget.existing!['id'] as String;
        await _api.updateProvider(existingId, payload);
        // Keep auth's provider name/category in sync with what was saved
        await widget.auth.switchToProvider(
          providerId: existingId,
          providerName: _nameCtrl.text.trim(),
          providerCategory: _primaryCategory,
        );
        if (!context.mounted) return;
        Navigator.of(context).pop(true); // return to provider profile
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile updated')),
        );
      } else {
        final result = await _api.registerProvider(payload);
        final providerId = result['provider_id'] as String?;
        if (providerId == null) throw 'No provider_id returned';
        await widget.auth.switchToProvider(
          providerId: providerId,
          providerName: _nameCtrl.text.trim(),
          providerCategory: _primaryCategory,
        );
        // main.dart's AnimatedBuilder routes to ProviderShell.
      }
    } catch (e) {
      setState(() {
        _submitting = false;
        _errMsg = e.toString();
      });
    }
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white60),
          onPressed: () => _confirmCancel(context),
        ),
        title: Text(_isEdit ? 'Edit profile' : 'Provider profile',
            style: AppFonts.base(size: 16, weight: FontWeight.w700)),
      ),
      body: SafeArea(
        child: ListView(
          controller: _scrollCtrl,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
          children: [
            _hero(),
            const SizedBox(height: 20),
            _section('Profile photo'),
            _photoPicker(),
            const SizedBox(height: 16),
            _section('Business name'),
            _textField(_nameCtrl, hint: 'e.g. Ali Plumbing Services'),
            const SizedBox(height: 16),
            _section('Gender'),
            _genderRow(),
            const SizedBox(height: 16),
            _section('Short bio (optional)'),
            _textField(_bioCtrl,
                hint: '5+ years experience · emergency calls 24/7',
                maxLines: 3),
            const SizedBox(height: 20),
            _section('Primary service'),
            _categoryGrid(_primaryCategory != null ? {_primaryCategory!} : {},
                (id) => setState(() => _primaryCategory = id),
                single: true),
            const SizedBox(height: 12),
            _section('Additional services (optional)'),
            _categoryGrid(_extraCategories, (id) {
              setState(() {
                if (id == _primaryCategory) return; // can't pick primary as extra
                if (_extraCategories.contains(id)) {
                  _extraCategories.remove(id);
                } else {
                  _extraCategories.add(id);
                }
              });
            }, single: false),
            const SizedBox(height: 20),
            _section('Primary working area'),
            _areaWrap(_primaryArea != null ? {_primaryArea!} : {},
                (a) => setState(() => _primaryArea = a),
                single: true),
            const SizedBox(height: 12),
            _section('Also work in (optional)'),
            _areaWrap(_extraAreas, (a) {
              setState(() {
                if (a == _primaryArea) return;
                if (_extraAreas.contains(a)) {
                  _extraAreas.remove(a);
                } else {
                  _extraAreas.add(a);
                }
              });
            }, single: false),
            const SizedBox(height: 20),
            _section('Weekly schedule'),
            for (final day in _schedule.keys) _scheduleRow(day),
            const SizedBox(height: 20),
            _section('Price range (PKR)'),
            Row(children: [
              Expanded(child: _textField(_priceMinCtrl, hint: 'Min', numeric: true)),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('to', style: AppFonts.base(size: 13, color: Colors.white60)),
              ),
              const SizedBox(width: 10),
              Expanded(child: _textField(_priceMaxCtrl, hint: 'Max', numeric: true)),
            ]),
            const SizedBox(height: 20),
            _section('Languages you speak'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final l in _allLanguages)
                _chip(
                  label: _langLabel(l),
                  selected: _languages.contains(l),
                  onTap: () => setState(() {
                    if (_languages.contains(l)) {
                      if (_languages.length > 1) _languages.remove(l);
                    } else {
                      _languages.add(l);
                    }
                  }),
                ),
            ]),
            if (_errMsg != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withOpacity(0.12),
                  border: Border.all(color: Colors.redAccent.withOpacity(0.5)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(children: [
                  const Icon(Icons.error_outline, color: Colors.redAccent, size: 14),
                  const SizedBox(width: 6),
                  Expanded(
                      child: Text(_errMsg!,
                          style: AppFonts.base(size: 12, color: Colors.redAccent))),
                ]),
              ),
            ],
            const SizedBox(height: 24),
            _submitButton(),
          ],
        ),
      ),
    );
  }

  Widget _hero() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              AppColors.followup.withOpacity(0.22),
              AppColors.violet.withOpacity(0.16),
            ],
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.followup.withOpacity(0.4)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.business_center_rounded,
                color: AppColors.followup, size: 18),
            const SizedBox(width: 8),
            Text('Set up your provider profile',
                style: AppFonts.base(size: 14, weight: FontWeight.w700)),
          ]),
          const SizedBox(height: 6),
          Text(
            'Customers will see this when they book. Add accurate hours and areas so requests reach you at the right time.',
            style: AppFonts.base(size: 12, color: Colors.white.withOpacity(0.78)),
          ),
        ]),
      );

  Widget _section(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
        child: Text(label.toUpperCase(),
            style: AppFonts.mono(size: 10, color: Colors.white60)
                .copyWith(letterSpacing: 1.3, fontWeight: FontWeight.w700)),
      );

  Widget _photoPicker() {
    final hasImage = _profileImageDataUrl != null;
    return Row(children: [
      InkWell(
        onTap: _pickImage,
        borderRadius: BorderRadius.circular(40),
        child: Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            color: AppColors.surface,
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.border),
            image: hasImage
                ? DecorationImage(
                    fit: BoxFit.cover,
                    image: MemoryImage(
                      base64Decode(_profileImageDataUrl!.split(',').last),
                    ),
                  )
                : null,
          ),
          alignment: Alignment.center,
          child: hasImage
              ? null
              : const Icon(Icons.add_a_photo_outlined,
                  color: Colors.white60, size: 26),
        ),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(hasImage ? 'Photo added' : 'Add a photo',
                style: AppFonts.base(size: 13, weight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(
              hasImage
                  ? 'Tap to change'
                  : 'Helps customers recognize you',
              style: AppFonts.base(size: 11, color: Colors.white54),
            ),
          ],
        ),
      ),
      if (hasImage)
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 18, color: Colors.white54),
          onPressed: () => setState(() => _profileImageDataUrl = null),
        ),
    ]);
  }

  Widget _textField(TextEditingController c,
      {String? hint, int maxLines = 1, bool numeric = false}) {
    return TextField(
      controller: c,
      maxLines: maxLines,
      keyboardType: numeric ? TextInputType.number : TextInputType.text,
      inputFormatters: numeric ? [FilteringTextInputFormatter.digitsOnly] : null,
      style: AppFonts.base(size: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: AppFonts.base(size: 13, color: Colors.white38),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: AppColors.border)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: AppColors.border)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.violet)),
      ),
    );
  }

  Widget _genderRow() {
    final opts = [
      {'id': 'female', 'label': 'Female', 'icon': Icons.female},
      {'id': 'male', 'label': 'Male', 'icon': Icons.male},
    ];
    return Row(
      children: [
        for (final o in opts) ...[
          Expanded(
            child: InkWell(
              onTap: () => setState(() => _gender = o['id'] as String),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  color: _gender == o['id']
                      ? AppColors.violet.withOpacity(0.18)
                      : AppColors.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _gender == o['id'] ? AppColors.violet : AppColors.border,
                    width: _gender == o['id'] ? 1.5 : 1,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      o['icon'] as IconData,
                      size: 16,
                      color: _gender == o['id'] ? AppColors.violet : Colors.white60,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      o['label'] as String,
                      style: AppFonts.base(
                        size: 12,
                        weight: FontWeight.w700,
                        color: _gender == o['id'] ? Colors.white : Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (o != opts.last) const SizedBox(width: 8),
        ],
      ],
    );
  }

  Widget _categoryGrid(Set<String> selected, ValueChanged<String> onTap,
      {required bool single}) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final c in _allCategories)
          _chip(
            icon: c.emoji,
            label: c.label,
            selected: selected.contains(c.id),
            onTap: () => onTap(c.id),
          ),
      ],
    );
  }

  Widget _areaWrap(Set<String> selected, ValueChanged<String> onTap,
      {required bool single}) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final a in _allAreas)
          _chip(
            label: a,
            selected: selected.contains(a),
            onTap: () => onTap(a),
          ),
      ],
    );
  }

  Widget _chip({
    String? icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.violet.withOpacity(0.22) : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AppColors.violet : AppColors.border,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Text(icon, style: const TextStyle(fontSize: 14)),
            const SizedBox(width: 6),
          ],
          Text(label,
              style: AppFonts.base(
                size: 12,
                weight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? Colors.white : Colors.white70,
              )),
        ]),
      ),
    );
  }

  Widget _scheduleRow(String day) {
    final s = _schedule[day]!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            SizedBox(
              width: 64,
              child: Text(_dayLabel(day),
                  style: AppFonts.base(size: 13, weight: FontWeight.w600)),
            ),
            Switch(
              value: s.open,
              activeColor: AppColors.intent,
              onChanged: (v) => setState(() {
                if (v && s.ranges.isEmpty) {
                  _schedule[day] = _DaySchedule(open: true, ranges: [_HourRange(9, 18)]);
                } else {
                  _schedule[day] = s.copyWith(open: v);
                }
              }),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: !s.open || s.ranges.isEmpty
                  ? Text('Closed',
                      style: AppFonts.base(size: 12, color: Colors.white38))
                  : Text('${s.ranges.length} slot${s.ranges.length == 1 ? "" : "s"}',
                      style: AppFonts.base(size: 11, color: Colors.white54)),
            ),
            if (s.open)
              IconButton(
                icon: const Icon(Icons.add_circle_outline, size: 18, color: AppColors.intent),
                visualDensity: VisualDensity.compact,
                tooltip: 'Add slot',
                onPressed: () => setState(() {
                  final last = s.ranges.isNotEmpty ? s.ranges.last : _HourRange(8, 12);
                  // New default slot starts after the previous one ends.
                  final newFrom = (last.to + 1).clamp(0, 22);
                  final newTo = (newFrom + 2).clamp(0, 23);
                  _schedule[day] = s.copyWith(ranges: [...s.ranges, _HourRange(newFrom, newTo)]);
                }),
              ),
          ]),
          if (s.open)
            Padding(
              padding: const EdgeInsets.only(left: 70, top: 4),
              child: Column(
                children: [
                  for (int i = 0; i < s.ranges.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: _slotRow(day, s, i),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _slotRow(String day, _DaySchedule s, int i) {
    final r = s.ranges[i];
    return Row(children: [
      _hourBtn(
        label: '${_pad(r.from)}:00',
        onTap: () async {
          final h = await _pickHour(initial: r.from, label: 'Opens at');
          if (h != null) {
            final newRanges = [...s.ranges];
            newRanges[i] = _HourRange(h, r.to);
            setState(() => _schedule[day] = s.copyWith(ranges: newRanges));
          }
        },
      ),
      const SizedBox(width: 6),
      Text('—', style: AppFonts.base(size: 13, color: Colors.white60)),
      const SizedBox(width: 6),
      _hourBtn(
        label: '${_pad(r.to)}:00',
        onTap: () async {
          final h = await _pickHour(initial: r.to, label: 'Closes at');
          if (h != null) {
            final newRanges = [...s.ranges];
            newRanges[i] = _HourRange(r.from, h);
            setState(() => _schedule[day] = s.copyWith(ranges: newRanges));
          }
        },
      ),
      const SizedBox(width: 6),
      IconButton(
        icon: const Icon(Icons.close, size: 16, color: Colors.white54),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        tooltip: 'Remove slot',
        onPressed: () => setState(() {
          final newRanges = [...s.ranges]..removeAt(i);
          _schedule[day] = newRanges.isEmpty
              ? _DaySchedule(open: false, ranges: const [])
              : s.copyWith(ranges: newRanges);
        }),
      ),
    ]);
  }

  Widget _hourBtn({required String label, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.border),
        ),
        child: Text(label, style: AppFonts.mono(size: 12, color: Colors.white)),
      ),
    );
  }

  Future<int?> _pickHour({required int initial, required String label}) async {
    return showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(label,
                style: AppFonts.base(size: 14, weight: FontWeight.w700)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (int h = 0; h < 24; h++)
                  InkWell(
                    onTap: () => Navigator.pop(context, h),
                    child: Container(
                      width: 56,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: h == initial
                            ? AppColors.violet.withOpacity(0.3)
                            : AppColors.surface2,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color:
                              h == initial ? AppColors.violet : AppColors.border,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text('${_pad(h)}:00',
                          style: AppFonts.mono(size: 12, color: Colors.white)),
                    ),
                  ),
              ],
            ),
          ]),
        ),
      ),
    );
  }

  String _dayLabel(String day) => switch (day) {
        'monday' => 'Mon',
        'tuesday' => 'Tue',
        'wednesday' => 'Wed',
        'thursday' => 'Thu',
        'friday' => 'Fri',
        'saturday' => 'Sat',
        'sunday' => 'Sun',
        _ => day,
      };

  String _langLabel(String code) => switch (code) {
        'ur' => 'اردو',
        'roman_ur' => 'Roman Urdu',
        'en' => 'English',
        _ => code,
      };

  Widget _submitButton() {
    return ElevatedButton(
      onPressed: _submitting ? null : _submit,
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.violet,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(52),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: _submitting
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
          : Text(_isEdit ? 'Save changes' : 'Complete registration',
              style: AppFonts.base(size: 15, weight: FontWeight.w800)),
    );
  }

  void _confirmCancel(BuildContext context) {
    if (_isEdit) {
      Navigator.of(context).pop(false);
      return;
    }
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Skip provider setup?'),
        content: const Text(
            "You'll stay as a customer. Sign out and pick 'Offer a service' on Create account to set up later."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Keep setting up'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context); // close dialog
              await widget.auth.switchToCustomer();
            },
            child: const Text('Skip',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }
}

class _CategoryOption {
  final String id;
  final String emoji;
  final String label;
  const _CategoryOption(this.id, this.emoji, this.label);
}

class _DaySchedule {
  final bool open;
  /// Zero or more open time slots for this day. When open=false OR ranges is
  /// empty the day is treated as off. Carve out an off window (e.g. lunch
  /// break, 1-2pm closed) by using two ranges that bracket it.
  final List<_HourRange> ranges;
  const _DaySchedule({required this.open, required this.ranges});
  _DaySchedule copyWith({bool? open, List<_HourRange>? ranges}) =>
      _DaySchedule(open: open ?? this.open, ranges: ranges ?? this.ranges);
}

class _HourRange {
  final int from;
  final int to;
  const _HourRange(this.from, this.to);
}
