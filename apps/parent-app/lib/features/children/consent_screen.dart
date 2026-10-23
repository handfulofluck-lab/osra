import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart' show apiClientProvider;
import '../../providers/family_provider.dart';
import '../../theme/app_tokens.dart';

/// Result of a completed withdrawal, carried back from the confirmation
/// screen so the status screen can report what the server actually did.
@immutable
class ConsentRevokeResult {
  final int count;
  final int devicesNotified;

  const ConsentRevokeResult(
      {required this.count, required this.devicesNotified});
}

String formatConsentTime(BuildContext context, DateTime? at) => at == null
    ? context.l10n.timeUnknown
    : DateFormat.yMMMd(context.localeName).add_Hm().format(at.toLocal());

/// Roadmap 3.7: the consent record the server holds for one child, with a
/// deliberately slow withdrawal flow. Revocation is a real server action
/// (ADR-0008); this screen never offers it for a state the server would not
/// actually change (no record, already withdrawn, expired).
class ConsentScreen extends ConsumerWidget {
  final String childId;
  const ConsentScreen({super.key, required this.childId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final status = ref.watch(consentStatusProvider(childId));
    final overview = ref.watch(familyProvider).valueOrNull;
    final child = overview?.children.where((c) => c.id == childId).firstOrNull;
    final role = overview?.parent.role;
    // Unknown role (the overview has not loaded) is not treated as a refusal;
    // a known non-owner is, because the API returns 403 for them.
    final isOwner = role == null || role == 'owner';

    return Scaffold(
      appBar: AppBar(title: Text(l10n.parentalConsent)),
      body: status.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ConsentError(
          message: l10n.consentLoadFailed,
          detail: '$e',
          onRetry: () => ref.invalidate(consentStatusProvider(childId)),
        ),
        data: (data) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(consentStatusProvider(childId));
            try {
              await ref.read(consentStatusProvider(childId).future);
            } catch (_) {
              // The error state above reports it; pull-to-refresh must settle.
            }
          },
          child: ListView(
            padding: const EdgeInsets.all(AppSpace.lg),
            children: [
              if (child != null)
                Text(
                  l10n.consentStatusSubtitle(child.displayName),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: AppSpace.sm),
              _StateCard(status: data),
              const SizedBox(height: AppSpace.sm),
              _CurrentRecordCard(status: data),
              if (data.records
                  .where((r) => r.id != data.current?.id)
                  .isNotEmpty) ...[
                const SizedBox(height: AppSpace.sm),
                _HistoryCard(status: data),
              ],
              const SizedBox(height: AppSpace.sm),
              _WithdrawCard(
                status: data,
                childId: childId,
                childName: child?.displayName ?? '',
                isOwner: isOwner,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _stateLabel(AppLocalizations l10n, ConsentState state) =>
    switch (state) {
      ConsentState.active => l10n.consentStateActive,
      ConsentState.expiring => l10n.consentStateExpiring,
      ConsentState.expired => l10n.consentStateExpired,
      ConsentState.revoked => l10n.consentStateRevoked,
      ConsentState.jurisdictionMismatch => l10n.consentStateMismatch,
      ConsentState.none => l10n.consentStateNone,
    };

String _stateDetail(
    BuildContext context, ConsentStatus status, ConsentState state) {
  final l10n = context.l10n;
  final record = status.current;
  final at = switch (state) {
    ConsentState.expiring => record?.expiresAt,
    ConsentState.expired => record?.expiresAt,
    ConsentState.revoked => record?.revokedAt,
    _ => null,
  };
  return switch (state) {
    ConsentState.active => l10n.consentStateActiveDetail,
    ConsentState.expiring =>
      l10n.consentStateExpiringDetail(formatConsentTime(context, at)),
    ConsentState.expired =>
      l10n.consentStateExpiredDetail(formatConsentTime(context, at)),
    ConsentState.revoked =>
      l10n.consentStateRevokedDetail(formatConsentTime(context, at)),
    ConsentState.jurisdictionMismatch => l10n.consentStateMismatchDetail(
        record?.jurisdiction ?? '', status.jurisdiction),
    ConsentState.none => l10n.consentStateNoneDetail,
  };
}

IconData _stateIcon(ConsentState state) => switch (state) {
      ConsentState.active => Icons.verified_user_outlined,
      ConsentState.expiring => Icons.schedule,
      ConsentState.expired => Icons.timer_off_outlined,
      ConsentState.revoked => Icons.block,
      ConsentState.jurisdictionMismatch => Icons.public_off,
      ConsentState.none => Icons.help_outline,
    };

Color _stateColor(BuildContext context, ConsentState state) => switch (state) {
      ConsentState.active => context.tokens.ok,
      ConsentState.expiring => context.tokens.warn,
      ConsentState.expired || ConsentState.revoked => context.tokens.danger,
      ConsentState.jurisdictionMismatch ||
      ConsentState.none =>
        context.tokens.onSurfaceVariant,
    };

class _StateCard extends StatelessWidget {
  final ConsentStatus status;
  const _StateCard({required this.status});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = status.state;
    final color = _stateColor(context, state);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(_stateIcon(state), color: color, size: 22),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _stateLabel(l10n, state),
                    key: const ValueKey('consentState'),
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(color: color),
                  ),
                  const SizedBox(height: AppSpace.xxs),
                  Text(_stateDetail(context, status, state),
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CurrentRecordCard extends StatelessWidget {
  final ConsentStatus status;
  const _CurrentRecordCard({required this.status});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final record = status.current;
    if (record == null) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.consentCurrentRecord,
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpace.sm),
            _Detail(
              label: l10n.consentMethodLabel,
              value: l10n.consentMethod(record.method),
            ),
            _Detail(
              label: l10n.consentJurisdictionLabel,
              value: record.jurisdiction.isEmpty
                  ? status.jurisdiction
                  : record.jurisdiction,
            ),
            _Detail(
              label: l10n.consentGrantedLabel,
              value: formatConsentTime(context, record.grantedAt),
            ),
            _Detail(
              label: l10n.consentExpiryLabel,
              value: record.expiresAt == null
                  ? l10n.consentNoExpiry
                  : formatConsentTime(context, record.expiresAt),
            ),
            _Detail(
              label: l10n.consentThirdPartyLabel,
              value: record.thirdPartySharing
                  ? l10n.consentSharingOn
                  : l10n.consentSharingOff,
            ),
            _Detail(
              label: l10n.consentRevokedLabel,
              value: record.revokedAt == null
                  ? l10n.consentNotRevoked
                  : formatConsentTime(context, record.revokedAt),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  final ConsentStatus status;
  const _HistoryCard({required this.status});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final earlier = [
      for (final r in status.records)
        if (r.id != status.current?.id) r
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.consentHistorySection,
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpace.sm),
            for (final record in earlier) ...[
              Text(
                l10n.consentHistoryGranted(
                  l10n.consentMethod(record.method),
                  formatConsentTime(context, record.grantedAt),
                ),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              Padding(
                padding: const EdgeInsetsDirectional.only(
                    start: AppSpace.md, bottom: AppSpace.sm),
                child: Text(_historyState(context, record),
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _historyState(BuildContext context, ConsentRecord record) {
    final l10n = context.l10n;
    if (record.revokedAt != null) {
      return l10n
          .consentHistoryRevoked(formatConsentTime(context, record.revokedAt));
    }
    final expiresAt = record.expiresAt;
    if (expiresAt != null && !expiresAt.isAfter(DateTime.now())) {
      return l10n.consentHistoryExpired(formatConsentTime(context, expiresAt));
    }
    return l10n.consentHistoryActive;
  }
}

class _WithdrawCard extends ConsumerWidget {
  final ConsentStatus status;
  final String childId;
  final String childName;
  final bool isOwner;
  const _WithdrawCard({
    required this.status,
    required this.childId,
    required this.childName,
    required this.isOwner,
  });

  bool get _withdrawable {
    final record = status.current;
    if (record == null || record.revokedAt != null) return false;
    final state = status.state;
    return state == ConsentState.active ||
        state == ConsentState.expiring ||
        state == ConsentState.jurisdictionMismatch;
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final result = await context.push<ConsentRevokeResult>(
      '/child/$childId/consent/revoke',
      extra: childName,
    );
    if (result == null || !context.mounted) return;
    ref.invalidate(consentStatusProvider(childId));
    final message = result.count == 0
        ? l10n.consentRevokeNoActive
        : '${l10n.consentRevokeDone} ${l10n.consentRevokeDevices(result.devicesNotified)}';
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.consentWithdrawAction,
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpace.xs),
            if (!isOwner)
              Text(l10n.consentWithdrawOnlyOwner,
                  style: Theme.of(context).textTheme.bodySmall)
            else if (!_withdrawable)
              Text(l10n.consentWithdrawUnavailable,
                  style: Theme.of(context).textTheme.bodySmall)
            else ...[
              Text(l10n.consentWithdrawNote,
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: AppSpace.sm),
              FilledButton.icon(
                key: const ValueKey('consentRevokeButton'),
                style: FilledButton.styleFrom(
                  backgroundColor: context.tokens.danger,
                  foregroundColor: context.tokens.onDanger,
                ),
                onPressed: () => _open(context, ref),
                icon: const Icon(Icons.block, size: 18),
                label: Text(l10n.consentWithdrawAction),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  final String label;
  final String value;
  const _Detail({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    // Aligned label/value pair: the label stays on the start side and the
    // value wraps on the end side instead of truncating at narrow widths.
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

class _ConsentError extends StatelessWidget {
  final String message;
  final String detail;
  final VoidCallback onRetry;
  const _ConsentError(
      {required this.message, required this.detail, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 32),
            const SizedBox(height: AppSpace.sm),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: AppSpace.xs),
            Text(detail,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: AppSpace.md),
            OutlinedButton(onPressed: onRetry, child: Text(l10n.retry)),
          ],
        ),
      ),
    );
  }
}

/// The confirmation step of withdrawal. It states in plain language what
/// stops and what happens to existing data, then requires the child's name to
/// be typed before it enables the button that calls the API.
class ConsentRevokeScreen extends ConsumerStatefulWidget {
  final String childId;

  /// Passed by the status screen so the confirmation is available even if the
  /// family overview has not loaded; falls back to `GET /v1/family/me`.
  final String? childName;

  const ConsentRevokeScreen({super.key, required this.childId, this.childName});

  @override
  ConsumerState<ConsentRevokeScreen> createState() =>
      _ConsentRevokeScreenState();
}

class _ConsentRevokeScreenState extends ConsumerState<ConsentRevokeScreen> {
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String get _childName {
    final passed = widget.childName?.trim() ?? '';
    if (passed.isNotEmpty) return passed;
    final overview = ref.read(familyProvider).valueOrNull;
    return overview?.children
            .where((c) => c.id == widget.childId)
            .firstOrNull
            ?.displayName ??
        '';
  }

  bool get _matches {
    final name = _childName;
    return name.isNotEmpty && _name.text.trim() == name;
  }

  Future<void> _submit() async {
    if (_busy || !_matches) return;
    final l10n = context.l10n;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ref.read(apiClientProvider).raw.post(
            '/v1/family/children/${widget.childId}/consent/revoke',
          );
      final data = res.data is Map
          ? Map<String, dynamic>.from(res.data as Map)
          : const <String, dynamic>{};
      final result = ConsentRevokeResult(
        count: (data['count'] is num) ? (data['count'] as num).toInt() : 0,
        devicesNotified: (data['devicesNotified'] is num)
            ? (data['devicesNotified'] as num).toInt()
            : 0,
      );
      if (mounted) Navigator.of(context).pop(result);
    } on DioException catch (e) {
      final forbidden = e.response?.statusCode == 403;
      if (mounted) {
        setState(() {
          _error = forbidden
              ? l10n.consentRevokeForbidden
              : l10n.consentRevokeFailed;
          _busy = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = l10n.consentRevokeFailed;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final name = _childName;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.consentRevokeTitle)),
      body: name.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.xl),
                child: Text(l10n.consentChildNameMissing,
                    textAlign: TextAlign.center),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(AppSpace.lg),
              children: [
                Card(
                  color: context.tokens.surfaceVariant,
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpace.md),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.warning_amber_rounded,
                            color: context.tokens.danger),
                        const SizedBox(width: AppSpace.sm),
                        Expanded(
                          child: Text(
                            l10n.consentRevokeWarning(name),
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: AppSpace.lg),
                _SectionTitle(l10n.consentRevokeStopsTitle),
                _Bullet(l10n.consentRevokeStopsCollection),
                _Bullet(l10n.consentRevokeStopsAlerts),
                _Bullet(l10n.consentRevokeStopsRules),
                _Bullet(l10n.consentRevokeKeepsSafe),
                const SizedBox(height: AppSpace.lg),
                _SectionTitle(l10n.consentRevokeDataTitle),
                Text(l10n.consentRevokeDataRetained,
                    style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: AppSpace.xs),
                Text(l10n.consentRevokeDataRetention,
                    style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: AppSpace.xs),
                Text(l10n.consentRevokeDataErase,
                    style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: AppSpace.xl),
                TextField(
                  key: const ValueKey('consentRevokeName'),
                  controller: _name,
                  enabled: !_busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: l10n.consentRevokeTypePrompt(name),
                    helperText: l10n.consentRevokeTypeHint,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _submit(),
                ),
                if (_name.text.trim().isNotEmpty && !_matches) ...[
                  const SizedBox(height: AppSpace.xs),
                  Text(
                    l10n.consentRevokeMismatch(name),
                    key: const ValueKey('consentRevokeMismatch'),
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: context.tokens.danger),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    _error!,
                    key: const ValueKey('consentRevokeError'),
                    style: TextStyle(color: context.tokens.danger),
                  ),
                ],
                const SizedBox(height: AppSpace.lg),
                FilledButton(
                  key: const ValueKey('consentRevokeConfirm'),
                  style: FilledButton.styleFrom(
                    backgroundColor: context.tokens.danger,
                    foregroundColor: context.tokens.onDanger,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: (_busy || !_matches) ? null : _submit,
                  child: Text(_busy
                      ? l10n.consentRevokeBusy
                      : l10n.consentRevokeSubmit),
                ),
                const SizedBox(height: AppSpace.xs),
                TextButton(
                  key: const ValueKey('consentRevokeCancel'),
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: Text(l10n.consentRevokeCancel),
                ),
              ],
            ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpace.xs),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );
}

class _Bullet extends StatelessWidget {
  final String text;
  const _Bullet(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsetsDirectional.only(bottom: AppSpace.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.xxs),
              child: Icon(Icons.circle,
                  size: 6, color: context.tokens.onSurfaceVariant),
            ),
            const SizedBox(width: AppSpace.sm),
            Expanded(
                child:
                    Text(text, style: Theme.of(context).textTheme.bodyMedium)),
          ],
        ),
      );
}
