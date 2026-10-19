import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/world_class_provider.dart';
import '../../theme/app_tokens.dart';

/// Feature #5: digest notification preferences — daily/weekly email and push
/// switches, a comma-separated recipient list, plus a dev 'send now' button
/// that renders the digest in-app (the test build has no SMTP — see SPEC).
class DigestPrefsScreen extends ConsumerStatefulWidget {
  const DigestPrefsScreen({super.key});

  @override
  ConsumerState<DigestPrefsScreen> createState() => _DigestPrefsScreenState();
}

class _DigestPrefsScreenState extends ConsumerState<DigestPrefsScreen> {
  bool _daily = false;
  bool _weekly = false;
  bool _push = true;
  final _emails = TextEditingController();
  bool _initialized = false;
  bool _saving = false;
  bool _sending = false;
  // ADR-0020 / #101: the family's timezone decides the local hour the digest is sent at.
  String? _timezone;
  bool _timezoneSaving = false;

  /// A curated list rather than the full IANA database: these are the markets OSRA ships to, and the
  /// API validates the value anyway (an unknown name is refused with invalid_timezone).
  static const _timezones = <String>[
    'UTC',
    'Asia/Dubai',
    'Asia/Riyadh',
    'Asia/Kuwait',
    'Asia/Qatar',
    'Asia/Bahrain',
    'Asia/Muscat',
    'Asia/Amman',
    'Africa/Cairo',
    'Europe/London',
    'Europe/Berlin',
    'Europe/Paris',
    'America/New_York',
    'America/Chicago',
    'America/Los_Angeles',
    'Asia/Karachi',
    'Asia/Kolkata',
    'Asia/Singapore',
  ];

  @override
  void dispose() {
    _emails.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadTimezone();
  }

  Future<void> _loadTimezone() async {
    try {
      final res = await ref.read(apiClientProvider).raw.get('/v1/family/me');
      final family = (res.data is Map ? res.data['family'] : null);
      final tz = family is Map ? family['timezone']?.toString() : null;
      if (mounted && tz != null) setState(() => _timezone = tz);
    } catch (_) {
      // A failed load leaves the dropdown empty; the parent can still pick a zone.
    }
  }

  Future<void> _saveTimezone(String tz) async {
    setState(() {
      _timezone = tz;
      _timezoneSaving = true;
    });
    try {
      await ref.read(apiClientProvider).raw.patch('/v1/family/me', data: {'timezone': tz});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Digest timezone set to $tz')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Timezone not saved: $e')));
      }
    } finally {
      if (mounted) setState(() => _timezoneSaving = false);
    }
  }

  /// The curated list, plus the family's actual zone when it is not in it (#108). Without this the
  /// control shows `UTC` for a family on, say, Asia/Tokyo while the server keeps the real value - the
  /// PATCH would not lie, but the screen would.
  List<String> get _zoneOptions {
    final tz = _timezone;
    if (tz == null || _timezones.contains(tz)) return _timezones;
    return [tz, ..._timezones];
  }

  List<String> get _emailList => _emails.text
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(apiClientProvider).raw.put('/v1/digests/prefs', data: {
        'dailyEmail': _daily,
        'weeklyEmail': _weekly,
        'pushEnabled': _push,
        'emails': _emailList,
      });
      ref.invalidate(digestPrefsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Digest preferences saved')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _sendNow() async {
    setState(() => _sending = true);
    try {
      final res = await ref.read(apiClientProvider).raw.post('/v1/digests/send-now');
      final data = res.data is Map ? Map<String, dynamic>.from(res.data as Map) : const <String, dynamic>{};
      final digests = data['digests'] is List ? data['digests'] as List : const [];
      final buffer = StringBuffer();
      for (final d in digests) {
        if (d is! Map) continue;
        final name = d['displayName']?.toString() ?? 'Child';
        buffer.writeln('# $name');
        buffer.writeln(d['markdown']?.toString() ?? '');
        buffer.writeln();
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Test digest'),
          content: SingleChildScrollView(
            child: SelectableText(
              buffer.toString().trim().isEmpty ? 'No digests generated' : buffer.toString().trim(),
              key: const ValueKey('digestMarkdown'),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close'))],
        ),
      );
    } on DioException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Send failed: ${e.response?.statusCode ?? e.message}')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(digestPrefsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Digest preferences')),
      body: prefs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to load preferences: $e')),
        data: (data) {
          // NOTE: copy server state into the editors once, then edit locally.
          if (!_initialized) {
            _daily = data.dailyEmail;
            _weekly = data.weeklyEmail;
            _push = data.pushEnabled;
            _emails.text = data.emails.join(', ');
            _initialized = true;
          }
          return ListView(
            padding: const EdgeInsets.all(AppSpace.lg),
            children: [
              SwitchListTile(
                title: const Text('Daily email digest'),
                subtitle: const Text('A short summary every evening'),
                value: _daily,
                onChanged: (v) => setState(() => _daily = v),
              ),
              SwitchListTile(
                title: const Text('Weekly email digest'),
                subtitle: const Text('A deeper summary once a week'),
                value: _weekly,
                onChanged: (v) => setState(() => _weekly = v),
              ),
              SwitchListTile(
                title: const Text('Push notifications'),
                subtitle: const Text('Critical alerts as push messages'),
                value: _push,
                onChanged: (v) => setState(() => _push = v),
              ),
              const SizedBox(height: AppSpace.md),
              TextField(
                controller: _emails,
                decoration: const InputDecoration(
                  labelText: 'Digest emails (comma separated)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppSpace.lg),
              // ADR-0020: the family's local hour. A parent who picks a zone here owns it: the API marks
              // the source as `parent`, and no device login can move it again (#101, #105).
              Text('Digest timezone (local send hour)', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: AppSpace.xs),
              Text(
                _timezone == null
                    ? 'Loading…'
                    : 'The digest is sent at 18:00 your local time${_timezoneSaving ? ' · saving…' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpace.sm),
              DropdownButtonFormField<String>(
                key: const ValueKey('digestTimezone'),
                initialValue: _zoneOptions.contains(_timezone) ? _timezone : 'UTC',
                decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Timezone'),
                items: [
                  for (final tz in _zoneOptions) DropdownMenuItem(value: tz, child: Text(tz)),
                ],
                onChanged: _timezoneSaving ? null : (v) { if (v != null) _saveTimezone(v); },
              ),
              const SizedBox(height: AppSpace.lg),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save),
                label: Text(_saving ? 'Saving…' : 'Save preferences'),
              ),
              const SizedBox(height: AppSpace.sm),
              OutlinedButton.icon(
                onPressed: _sending ? null : _sendNow,
                icon: const Icon(Icons.send),
                label: Text(_sending ? 'Rendering…' : 'Send test digest now'),
              ),
            ],
          );
        },
      ),
    );
  }
}
