import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/world_class_provider.dart';

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

  @override
  void dispose() {
    _emails.dispose();
    super.dispose();
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
            padding: const EdgeInsets.all(16),
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
              const SizedBox(height: 12),
              TextField(
                controller: _emails,
                decoration: const InputDecoration(
                  labelText: 'Digest emails (comma separated)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save),
                label: Text(_saving ? 'Saving…' : 'Save preferences'),
              ),
              const SizedBox(height: 8),
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
