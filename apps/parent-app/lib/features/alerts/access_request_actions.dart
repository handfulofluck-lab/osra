import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../../theme/app_tokens.dart';
import 'app_alert_presentation.dart';

typedef AccessRequestResolved = void Function(String resolution, DateTime at);

enum _AccessAction { allow, keepBlocked }

class AccessRequestActions extends ConsumerStatefulWidget {
  final Alert alert;
  final AppAlertIdentity identity;
  final AccessRequestResolved? onResolved;
  final DateTime Function()? nowProvider;

  const AccessRequestActions({
    super.key,
    required this.alert,
    required this.identity,
    this.onResolved,
    this.nowProvider,
  });

  @override
  ConsumerState<AccessRequestActions> createState() =>
      _AccessRequestActionsState();
}

class _AccessRequestActionsState extends ConsumerState<AccessRequestActions> {
  bool _saving = false;
  bool _failed = false;
  _AccessAction? _pendingAction;
  _AccessAction? _failedAction;
  String? _resolution;
  String? _resolvedByName;
  DateTime? _resolvedAt;

  @override
  void initState() {
    super.initState();
    _syncResolution();
  }

  @override
  void didUpdateWidget(AccessRequestActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.alert.id != widget.alert.id ||
        oldWidget.alert.acknowledged != widget.alert.acknowledged ||
        oldWidget.alert.metadata['resolution'] !=
            widget.alert.metadata['resolution'] ||
        oldWidget.alert.metadata['resolvedByName'] !=
            widget.alert.metadata['resolvedByName'] ||
        oldWidget.alert.metadata['resolvedAt'] !=
            widget.alert.metadata['resolvedAt']) {
      final keepLocalOutcome = oldWidget.alert.id == widget.alert.id &&
          _resolution != null &&
          widget.alert.metadata['resolution'] == null;
      if (!keepLocalOutcome) _syncResolution();
    }
  }

  void _syncResolution() {
    final metadata = widget.alert.metadata;
    final resolution = metadata['resolution']?.toString();
    _resolution = resolution == 'allowed' || resolution == 'kept_blocked'
        ? resolution
        : null;
    _resolvedByName = metadata['resolvedByName']?.toString();
    _resolvedAt = DateTime.tryParse(metadata['resolvedAt']?.toString() ?? '');
  }

  Future<void> _allow() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _failed = false;
      _pendingAction = _AccessAction.allow;
    });
    try {
      final api = ref.read(apiClientProvider).raw;
      final packageId = appAlertPackageId(widget.alert);
      if (packageId.isEmpty)
        throw StateError('app_blocked alert has no packageId');
      final response = await api.get('/v1/rules/${widget.alert.childId}');
      final saved =
          RuleSet.fromJson(Map<String, dynamic>.from(response.data as Map));
      final appRules = [...saved.appRules];
      final rule = AppRule(
        packageId: packageId,
        appName: widget.identity.name,
        action: 'allow',
      );
      final index = appRules.indexWhere((item) => item.packageId == packageId);
      if (index == -1) {
        appRules.add(rule);
      } else {
        appRules[index] = rule;
      }
      final submitted = saved.copyWith(appRules: appRules);
      await api.patch(
        '/v1/rules/${widget.alert.childId}',
        data: submitted.changesFrom(saved),
      );
      final devices = ref
              .read(familyProvider)
              .valueOrNull
              ?.devicesFor(widget.alert.childId) ??
          const <Device>[];
      ref.invalidate(rulesProvider(widget.alert.childId));
      ref.invalidate(familyProvider);
      for (final device in devices) {
        ref.invalidate(deviceCommandHistoryProvider(device.id));
      }
      await api.post('/v1/alerts/${widget.alert.id}/ack');
      await _complete('allowed');
    } on DioException {
      if (mounted) {
        setState(() {
          _failed = true;
          _failedAction = _AccessAction.allow;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _failedAction = _AccessAction.allow;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _keepBlocked() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _failed = false;
      _pendingAction = _AccessAction.keepBlocked;
    });
    try {
      await ref
          .read(apiClientProvider)
          .raw
          .post('/v1/alerts/${widget.alert.id}/ack');
      await _complete('kept_blocked');
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _failedAction = _AccessAction.keepBlocked;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _complete(String resolution) async {
    final at = widget.nowProvider?.call() ?? DateTime.now();
    ref.read(alertsSeenProvider.notifier).markAcknowledged(widget.alert.id);
    ref.invalidate(alertsProvider);
    ref.invalidate(unacknowledgedAlertsProvider);
    ref.invalidate(unacknowledgedCountProvider);
    if (!mounted) return;
    setState(() {
      _resolution = resolution;
      _resolvedByName = null;
      _resolvedAt = at;
    });
    widget.onResolved?.call(resolution, at);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          accessResolvedSnack(
            localeName: context.localeName,
            resolution: resolution,
            identity: widget.identity,
            resolvedAt: at,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!isAccessRequestAlert(widget.alert)) return const SizedBox.shrink();
    final l10n = context.l10n;
    final localeName = context.localeName;
    final isEnglish = localeName.startsWith('en');
    final theme = Theme.of(context);
    final actionTextStyle =
        theme.textTheme.labelLarge?.copyWith(fontSize: 13, height: 1);
    final tokens = context.tokens;
    final overview = ref.watch(familyProvider).valueOrNull;
    final parent = overview?.parent;
    final role = parent?.role;
    final permissions = parent?.permissions ?? const <String>[];
    final canKeepBlocked = parent != null &&
        (role == 'owner' ||
            (role == 'co-parent' && permissions.contains('alerts')) ||
            (role == 'guardian' &&
                permissions.contains('rules') &&
                permissions.contains('alerts')));
    final canAllow = parent != null &&
        (role == 'owner' ||
            (permissions.contains('rules') && permissions.contains('alerts')));
    final owner = overview?.parents
            .where((item) =>
                item.role == 'owner' && item.displayName.trim().isNotEmpty)
            .firstOrNull
            ?.displayName ??
        l10n.mfaResetRoleOwner;
    final resolved = widget.alert.acknowledged || _resolution != null;

    return Column(
      key: const ValueKey('access-request-actions'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (resolved)
          _ResolvedLine(
            text: accessResolvedLine(
              localeName: localeName,
              resolution: _resolution,
              identity: widget.identity,
              resolvedByName: _resolvedByName,
              resolvedAt: _resolvedAt,
            ),
            allowed: _resolution == 'allowed',
          )
        else if (!canKeepBlocked)
          _IconLine(
            icon: Icons.lock,
            color: tokens.onSurfaceVariant,
            text: accessReadOnlyLine(localeName: localeName, owner: owner),
            textColor: tokens.onSurfaceVariant,
          )
        else ...[
          if (_failed) ...[
            _IconLine(
              icon: Icons.error,
              color: theme.colorScheme.error,
              text: _failedAction == _AccessAction.keepBlocked
                  ? l10n.acknowledgeFailed
                  : accessApproveError(
                      localeName: localeName, identity: widget.identity),
              textColor: theme.colorScheme.error,
            ),
            const SizedBox(height: AppSpace.sm),
          ],
          Row(
            children: [
              if (canAllow) ...[
                Expanded(
                  child: SizedBox(
                    height: 52,
                    child: FilledButton(
                      key: const ValueKey('access-allow'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        minimumSize: const Size(48, 52),
                        textStyle: actionTextStyle,
                      ),
                      onPressed: _saving ? null : _allow,
                      child: _saving && _pendingAction == _AccessAction.allow
                          ? Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  isEnglish ? 'Allowing…' : l10n.saving,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            )
                          : Semantics(
                              label: accessAllowSemantics(
                                localeName: localeName,
                                identity: widget.identity,
                              ),
                              child: Text(
                                isEnglish ? 'Allow' : 'السماح',
                                maxLines: 2,
                                textAlign: TextAlign.center,
                              ),
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
              ],
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: OutlinedButton(
                    key: const ValueKey('access-keep-blocked'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      minimumSize: const Size(48, 52),
                      textStyle: actionTextStyle,
                    ),
                    onPressed: _saving ? null : _keepBlocked,
                    child: Semantics(
                      label: accessDenySemantics(
                        localeName: localeName,
                        identity: widget.identity,
                      ),
                      child: Text(
                        isEnglish ? 'Keep blocked' : l10n.pairClaimDeny,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: AppSpace.sm),
        _IconLine(
          icon: Icons.info_outline,
          color: tokens.onSurfaceVariant,
          text: accessApproveDisclosure(
              localeName: localeName, identity: widget.identity),
          textColor: tokens.onSurfaceVariant,
          muted: true,
        ),
      ],
    );
  }
}

class _ResolvedLine extends StatelessWidget {
  final String text;
  final bool allowed;

  const _ResolvedLine({required this.text, required this.allowed});

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final color = allowed ? tokens.ok : tokens.onSurfaceVariant;
    return _IconLine(
      key: const ValueKey('access-request-resolved'),
      icon: Icons.check_circle_outline,
      color: color,
      text: text,
      textColor: color,
    );
  }
}

class _IconLine extends StatelessWidget {
  final IconData icon;
  final Color color;
  final Color textColor;
  final String text;
  final bool muted;

  const _IconLine({
    super.key,
    required this.icon,
    required this.color,
    required this.text,
    required this.textColor,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 18, color: color),
        ),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: Text(
            text,
            style: (muted
                    ? Theme.of(context).textTheme.bodySmall
                    : Theme.of(context).textTheme.bodyMedium)
                ?.copyWith(color: textColor),
          ),
        ),
      ],
    );
  }
}
