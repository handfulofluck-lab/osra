import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/localized_list.dart';
import '../../providers/auth_provider.dart';
import '../../providers/world_class_provider.dart';
import '../../api/models.dart' show DigestRecipientStatus;
import '../../api/permission_errors.dart';
import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/error_retry_view.dart';
import 'timezone_catalog.dart';

/// Feature #5: digest notification preferences — daily/weekly email and push
/// switches, a comma-separated recipient list, plus a dev 'send now' button
/// that renders the digest in-app (the test build has no SMTP — see SPEC).
///
/// Roadmap 2.7 (osra-security#2): a recipient that is not a parent of the family
/// receives nothing until it uses the confirmation link mailed to it, so the
/// screen marks each address `confirmed` or `pending` and says when a
/// confirmation was sent.
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
  /// Per-address confirmation state from the server (roadmap 2.7): a pending address
  /// receives no digest until its link is used.
  List<DigestRecipientStatus> _recipients = const [];
  // ADR-0020 / #101: the family's timezone decides the local hour the digest is sent at.
  String? _timezone;
  bool _timezoneSaving = false;

  /// The fixed local send hour (see `digestPrefsSendHour`); shown as its own
  /// field so the explanation and this value are no longer one run-on line.
  static const _sendHour = '18:00';

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
      if (mounted) {
        setState(() => _timezone = (tz != null && tz.isNotEmpty) ? tz : defaultDeviceTimezone());
      }
    } catch (e) {
      logParentError(e);
      if (mounted && _timezone == null) {
        setState(() => _timezone = defaultDeviceTimezone());
      }
    }
  }

  Future<void> _saveTimezone(String tz) async {
    final previous = _timezone;
    setState(() {
      _timezone = tz;
      _timezoneSaving = true;
    });
    try {
      await ref.read(apiClientProvider).raw.patch('/v1/family/me', data: {'timezone': tz});
      if (mounted) {
        final lang = Localizations.localeOf(context).languageCode;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.digestPrefsTimezoneSet(formatTimezoneLabel(tz, languageCode: lang)))),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _timezone = previous);
        showErrorSnackBar(
          context,
          friendlyErrorText(context.l10n, e, () => context.l10n.digestPrefsTimezoneFailed),
          onRetry: () => _saveTimezone(tz),
        );
      }
    } finally {
      if (mounted) setState(() => _timezoneSaving = false);
    }
  }

  Future<void> _pickTimezone() async {
    final l10n = context.l10n;
    final options = orderedTimezones(_timezone ?? defaultDeviceTimezone());
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => _TimezonePickerSheet(
        title: l10n.digestPrefsTimezonePickerTitle,
        searchHint: l10n.digestPrefsTimezoneSearchHint,
        emptyText: l10n.digestPrefsTimezoneEmpty,
        currentId: _timezone,
        options: options,
      ),
    );
    if (picked != null && picked != _timezone && mounted) {
      await _saveTimezone(picked);
    }
  }

  List<String> get _emailList => splitLocalizedList(_emails.text);

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final res = await ref.read(apiClientProvider).raw.put('/v1/digests/prefs', data: {
        'dailyEmail': _daily,
        'weeklyEmail': _weekly,
        'pushEnabled': _push,
        'emails': _emailList,
      });
      // The PUT answers each address `confirmed` or `pending` (roadmap 2.7); take that answer, so a
      // freshly added address shows that its confirmation was sent without a reload.
      final data = res.data is Map ? Map<String, dynamic>.from(res.data as Map) : const <String, dynamic>{};
      final recipients = [
        for (final r in (data['recipients'] is List ? data['recipients'] as List : const []))
          if (r is Map) DigestRecipientStatus.fromJson(Map<String, dynamic>.from(r)),
      ];
      if (mounted && recipients.isNotEmpty) setState(() => _recipients = recipients);
      ref.invalidate(digestPrefsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.digestPrefsSaved)));
      }
    } catch (e) {
      if (mounted) {
        showErrorSnackBar(
          context,
          friendlyErrorText(context.l10n, e, () => context.l10n.digestPrefsSaveFailed),
          onRetry: _save,
        );
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
        final name = d['displayName']?.toString() ?? context.l10n.digestPrefsChildFallback;
        buffer.writeln('# $name');
        buffer.writeln(d['markdown']?.toString() ?? '');
        buffer.writeln();
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true,
          title: Text(context.l10n.digestPrefsTestTitle),
          content: SelectableText(
            buffer.toString().trim().isEmpty ? ctx.l10n.digestPrefsNoDigests : buffer.toString().trim(),
            key: const ValueKey('digestMarkdown'),
          ),
          actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(ctx.l10n.digestPrefsClose))],
        ),
      );
    } on DioException catch (e) {
      if (mounted) {
        showErrorSnackBar(
          context,
          friendlyErrorText(context.l10n, e, () => context.l10n.digestPrefsSendFailed),
          onRetry: _sendNow,
        );
      }
    } catch (e) {
      if (mounted) {
        showErrorSnackBar(
          context,
          friendlyErrorText(context.l10n, e, () => context.l10n.digestPrefsSendFailed),
          onRetry: _sendNow,
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(digestPrefsProvider);
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.digestPrefsTitle)),
      body: prefs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorRetryView(
          message: friendlyErrorText(l10n, e, () => l10n.digestPrefsLoadFailed),
          onRetry: () => ref.invalidate(digestPrefsProvider),
        ),
        data: (data) {
          // NOTE: copy server state into the editors once, then edit locally.
          if (!_initialized) {
            _daily = data.dailyEmail;
            _weekly = data.weeklyEmail;
            _push = data.pushEnabled;
            _emails.text = data.emails.join(', ');
            _recipients = data.recipients;
            _initialized = true;
          }
          return ListView(
            padding: const EdgeInsets.all(AppSpace.lg),
            children: [
              SwitchListTile(
                title: Text(l10n.digestPrefsDailyTitle),
                subtitle: Text(l10n.digestPrefsDailyBody),
                value: _daily,
                onChanged: (v) => setState(() => _daily = v),
              ),
              SwitchListTile(
                title: Text(l10n.digestPrefsWeeklyTitle),
                subtitle: Text(l10n.digestPrefsWeeklyBody),
                value: _weekly,
                onChanged: (v) => setState(() => _weekly = v),
              ),
              SwitchListTile(
                title: Text(l10n.digestPrefsPushTitle),
                subtitle: Text(l10n.digestPrefsPushBody),
                value: _push,
                onChanged: (v) => setState(() => _push = v),
              ),
              const SizedBox(height: AppSpace.md),
              TextField(
                controller: _emails,
                decoration: InputDecoration(
                  labelText: l10n.digestPrefsEmailsLabel,
                  helperText: l10n.digestPrefsEmailsHelper,
                  border: const OutlineInputBorder(),
                ),
              ),
              // Roadmap 2.7: an address that is not a parent of the family is not a recipient yet.
              // A pending one says the confirmation went out; an `unsent` one says it did not and to save
              // again — so neither ever looks like an address that will actually be mailed.
              if (_recipients.isNotEmpty) ...[
                const SizedBox(height: AppSpace.sm),
                for (final r in _recipients)
                  Padding(
                    key: ValueKey('digestRecipient-${r.email}'),
                    padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          r.isConfirmed
                              ? Icons.check_circle
                              : (r.isUnsent ? Icons.error_outline : Icons.schedule),
                          size: 18,
                          color: r.isConfirmed
                              ? context.tokens.ok
                              : (r.isUnsent ? context.tokens.danger : context.tokens.warn),
                        ),
                        const SizedBox(width: AppSpace.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(r.email, style: Theme.of(context).textTheme.bodyMedium),
                              if (r.isUnsent)
                                Text(
                                  l10n.digestPrefsNotSent,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(color: context.tokens.danger),
                                )
                              else if (r.isLimited)
                                Text(
                                  l10n.digestPrefsConfirmationLimited,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(color: context.tokens.warn),
                                )
                              else if (r.isPending)
                                Text(
                                  l10n.digestPrefsConfirmationSent,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(color: context.tokens.warn),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: AppSpace.lg),
              // ADR-0020: the family's local hour. A parent who picks a zone here owns it: the API marks
              // the source as `parent`, and no device login can move it again (#101, #105).
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpace.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.digestPrefsTimezoneTitle, style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: AppSpace.xs),
                      // The explanation, the fixed send hour and the zone are
                      // three separate fields — the old single line crammed
                      // "18:00" and the saving suffix into the explanation.
                      Text(l10n.digestPrefsSendHour, style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: AppSpace.sm),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(l10n.digestPrefsSendHourLabel, style: Theme.of(context).textTheme.bodySmall),
                          ),
                          const SizedBox(width: AppSpace.md),
                          Expanded(
                            child: Text(
                              _sendHour,
                              style: Theme.of(context).textTheme.bodyMedium,
                              textAlign: TextAlign.end,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpace.sm),
                      if (_timezone == null) ...[
                        Text(l10n.digestPrefsTimezoneLoading, style: Theme.of(context).textTheme.bodySmall),
                        const SizedBox(height: AppSpace.sm),
                      ],
                      InkWell(
                        key: const ValueKey('digestTimezone'),
                        onTap: _timezoneSaving ? null : _pickTimezone,
                        borderRadius: BorderRadius.circular(4),
                        child: InputDecorator(
                          decoration: InputDecoration(
                            border: const OutlineInputBorder(),
                            labelText: l10n.digestPrefsTimezoneLabel,
                            suffixIcon: const Icon(Icons.arrow_drop_down),
                          ),
                          child: Text(
                            formatTimezoneLabel(
                              _timezone ?? defaultDeviceTimezone(),
                              languageCode: Localizations.localeOf(context).languageCode,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      if (_timezoneSaving) ...[
                        const SizedBox(height: AppSpace.xs),
                        Text(l10n.digestPrefsSavingSuffix, style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.lg),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save),
                label: Text(_saving ? l10n.digestPrefsSaving : l10n.digestPrefsSave),
              ),
              const SizedBox(height: AppSpace.sm),
              OutlinedButton.icon(
                onPressed: _sending ? null : _sendNow,
                icon: const Icon(Icons.send),
                label: Text(_sending ? l10n.digestPrefsRendering : l10n.digestPrefsSendNow),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TimezonePickerSheet extends StatefulWidget {
  final String title;
  final String searchHint;
  final String emptyText;
  final String? currentId;
  final List<TimezoneOption> options;

  const _TimezonePickerSheet({
    required this.title,
    required this.searchHint,
    required this.emptyText,
    required this.currentId,
    required this.options,
  });

  @override
  State<_TimezonePickerSheet> createState() => _TimezonePickerSheetState();
}

class _TimezonePickerSheetState extends State<_TimezonePickerSheet> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = [
      for (final tz in widget.options)
        if (tz.matches(_query)) tz,
    ];
    final maxHeight = MediaQuery.sizeOf(context).height * 0.75;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.lg, AppSpace.lg, AppSpace.sm),
              child: Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
              child: TextField(
                key: const ValueKey('digestTimezoneSearch'),
                controller: _search,
                autofocus: false,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: widget.searchHint,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            Flexible(
              child: filtered.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(AppSpace.xl),
                      child: Center(child: Text(widget.emptyText)),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: filtered.length,
                      itemBuilder: (_, index) {
                        final opt = filtered[index];
                        final selected = opt.id == widget.currentId;
                        final lang = Localizations.localeOf(context).languageCode;
                        return ListTile(
                          title: Text(opt.labelFor(lang)),
                          trailing: selected ? const Icon(Icons.check) : null,
                          selected: selected,
                          onTap: () => Navigator.of(context).pop(opt.id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
