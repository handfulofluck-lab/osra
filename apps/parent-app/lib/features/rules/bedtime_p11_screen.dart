import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../api/permission_errors.dart';
import '../../core/ltr_isolate.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/error_retry_view.dart';
import 'app_picker.dart';
import 'rules_behind_banner.dart';
import 'rules_editor_screen.dart' show formatTime, parseTime, walletSuggestions;

/// Build-time switch for the P-11 Bedtime & school redesign (#1179).
/// Defaults to `false` so the legacy `RulesEditorScreen` remains the fallback
/// unless `--dart-define=OSRA_UX_P11=true` or a test overrides [p11BedtimeEnabledProvider].
const bool kP11BedtimeDefault = bool.fromEnvironment('OSRA_UX_P11', defaultValue: false);

/// Feature switch for P-11 Bedtime & school (#1179).
final p11BedtimeEnabledProvider = Provider<bool>((ref) => kP11BedtimeDefault);

/// P-11 Bedtime & school screen (#1179).
///
/// Implements Karim pick 1 (routine cards only, no 24 h strip), G14 (one bedtime
/// with no days; off means `bedtimeStart == bedtimeEnd`; "Skip tonight" and
/// "+30 min tonight" hidden), A27 (payment-apps note + "Add a payment app"),
/// and A4 (Wind down button on the bedtime card).
class BedtimeP11Screen extends ConsumerStatefulWidget {
  final String childId;

  const BedtimeP11Screen({super.key, required this.childId});

  @override
  ConsumerState<BedtimeP11Screen> createState() => _BedtimeP11ScreenState();
}

class _BedtimeP11ScreenState extends ConsumerState<BedtimeP11Screen> {
  RuleSet _draft = const RuleSet();
  RuleSet? _saved;
  bool _saving = false;
  String? _error;

  String _lastBedtimeStart = '21:30';
  String _lastBedtimeEnd = '07:00';
  String _lastSchoolStart = '07:45';
  String _lastSchoolEnd = '14:30';
  List<int> _lastSchoolDays = const [1, 2, 3, 4, 5];

  bool get _bedtimeOn => _draft.screenTime.bedtimeStart != _draft.screenTime.bedtimeEnd;

  bool get _schoolOn =>
      _draft.screenTime.schoolStart != _draft.screenTime.schoolEnd &&
      _draft.screenTime.schoolDays.isNotEmpty;

  String? get _childName {
    final overview = ref.watch(familyProvider).valueOrNull;
    if (overview == null) return null;
    for (final child in overview.children) {
      if (child.id == widget.childId) return child.displayName;
    }
    return null;
  }

  void _applyLoaded(RuleSet ruleSet) {
    if (_saved != null) return;
    _saved = ruleSet;
    _draft = ruleSet;
    final st = ruleSet.screenTime;
    if (st.bedtimeStart != st.bedtimeEnd) {
      _lastBedtimeStart = st.bedtimeStart;
      _lastBedtimeEnd = st.bedtimeEnd;
    }
    if (st.schoolStart != st.schoolEnd && st.schoolDays.isNotEmpty) {
      _lastSchoolStart = st.schoolStart;
      _lastSchoolEnd = st.schoolEnd;
      _lastSchoolDays = List<int>.from(st.schoolDays);
    }
  }

  void _updateScreenTime(ScreenTimeRule Function(ScreenTimeRule) f) {
    final next = f(_draft.screenTime);
    setState(() {
      _draft = _draft.copyWith(screenTime: next);
    });
  }

  void _toggleBedtime(bool enabled) {
    final st = _draft.screenTime;
    if (!enabled) {
      if (st.bedtimeStart != st.bedtimeEnd) {
        _lastBedtimeStart = st.bedtimeStart;
        _lastBedtimeEnd = st.bedtimeEnd;
      }
      // G14: off means start == end.
      _updateScreenTime((s) => ScreenTimeRule(
            dailyLimitMinutes: s.dailyLimitMinutes,
            weekendLimitMinutes: s.weekendLimitMinutes,
            bedtimeStart: s.bedtimeStart,
            bedtimeEnd: s.bedtimeStart,
            schoolStart: s.schoolStart,
            schoolEnd: s.schoolEnd,
            schoolDays: s.schoolDays,
          ));
      return;
    }
    final start = _lastBedtimeStart != _lastBedtimeEnd ? _lastBedtimeStart : '21:30';
    final end = _lastBedtimeStart != _lastBedtimeEnd ? _lastBedtimeEnd : '07:00';
    _updateScreenTime((s) => ScreenTimeRule(
          dailyLimitMinutes: s.dailyLimitMinutes,
          weekendLimitMinutes: s.weekendLimitMinutes,
          bedtimeStart: start,
          bedtimeEnd: end,
          schoolStart: s.schoolStart,
          schoolEnd: s.schoolEnd,
          schoolDays: s.schoolDays,
        ));
  }

  void _toggleSchool(bool enabled) {
    final st = _draft.screenTime;
    if (!enabled) {
      if (st.schoolStart != st.schoolEnd && st.schoolDays.isNotEmpty) {
        _lastSchoolStart = st.schoolStart;
        _lastSchoolEnd = st.schoolEnd;
        _lastSchoolDays = List<int>.from(st.schoolDays);
      }
      _updateScreenTime((s) => ScreenTimeRule(
            dailyLimitMinutes: s.dailyLimitMinutes,
            weekendLimitMinutes: s.weekendLimitMinutes,
            bedtimeStart: s.bedtimeStart,
            bedtimeEnd: s.bedtimeEnd,
            schoolStart: s.schoolStart,
            schoolEnd: s.schoolStart,
            schoolDays: const [],
          ));
      return;
    }
    final start = _lastSchoolStart != _lastSchoolEnd ? _lastSchoolStart : '07:45';
    final end = _lastSchoolStart != _lastSchoolEnd ? _lastSchoolEnd : '14:30';
    final days = _lastSchoolDays.isNotEmpty ? _lastSchoolDays : const [1, 2, 3, 4, 5];
    _updateScreenTime((s) => ScreenTimeRule(
          dailyLimitMinutes: s.dailyLimitMinutes,
          weekendLimitMinutes: s.weekendLimitMinutes,
          bedtimeStart: s.bedtimeStart,
          bedtimeEnd: s.bedtimeEnd,
          schoolStart: start,
          schoolEnd: end,
          schoolDays: List<int>.from(days)..sort(),
        ));
  }

  Future<void> _pickBedtime(bool isStart) async {
    final st = _draft.screenTime;
    final current = parseTime(
      isStart ? st.bedtimeStart : st.bedtimeEnd,
      isStart ? const TimeOfDay(hour: 21, minute: 30) : const TimeOfDay(hour: 7, minute: 0),
    );
    final picked = await showTimePicker(context: context, initialTime: current);
    if (picked == null || !mounted) return;
    final formatted = formatTime(picked);
    _updateScreenTime((s) => ScreenTimeRule(
          dailyLimitMinutes: s.dailyLimitMinutes,
          weekendLimitMinutes: s.weekendLimitMinutes,
          bedtimeStart: isStart ? formatted : s.bedtimeStart,
          bedtimeEnd: isStart ? s.bedtimeEnd : formatted,
          schoolStart: s.schoolStart,
          schoolEnd: s.schoolEnd,
          schoolDays: s.schoolDays,
        ));
    final updated = _draft.screenTime;
    if (updated.bedtimeStart != updated.bedtimeEnd) {
      _lastBedtimeStart = updated.bedtimeStart;
      _lastBedtimeEnd = updated.bedtimeEnd;
    }
  }

  Future<void> _pickSchoolTime(bool isStart) async {
    final st = _draft.screenTime;
    final current = parseTime(
      isStart ? st.schoolStart : st.schoolEnd,
      isStart ? const TimeOfDay(hour: 7, minute: 45) : const TimeOfDay(hour: 14, minute: 30),
    );
    final picked = await showTimePicker(context: context, initialTime: current);
    if (picked == null || !mounted) return;
    final formatted = formatTime(picked);
    _updateScreenTime((s) => ScreenTimeRule(
          dailyLimitMinutes: s.dailyLimitMinutes,
          weekendLimitMinutes: s.weekendLimitMinutes,
          bedtimeStart: s.bedtimeStart,
          bedtimeEnd: s.bedtimeEnd,
          schoolStart: isStart ? formatted : s.schoolStart,
          schoolEnd: isStart ? s.schoolEnd : formatted,
          schoolDays: s.schoolDays,
        ));
    final updated = _draft.screenTime;
    if (updated.schoolStart != updated.schoolEnd && updated.schoolDays.isNotEmpty) {
      _lastSchoolStart = updated.schoolStart;
      _lastSchoolEnd = updated.schoolEnd;
    }
  }

  Future<void> _addPaymentApp() async {
    final l10n = context.l10n;
    var pinned = walletSuggestions;
    try {
      final installed = await ref.read(installedAppsProvider(widget.childId).future);
      final available = installed.apps.map((a) => a.packageId).toSet();
      final onPhone = [
        for (final pkg in walletSuggestions)
          if (available.contains(pkg)) pkg,
      ];
      if (onPhone.isNotEmpty) pinned = onPhone;
    } catch (_) {
      // Offline or unreported phone: keep the default suggestion order.
    }
    if (!mounted) return;
    final chosen = await showAppPicker(
      context,
      childId: widget.childId,
      childName: _childName,
      selected: {..._draft.alwaysAllowedApps},
      pinnedFirst: pinned,
      disabled: {
        for (final pkg in _draft.alwaysAllowedApps) pkg: l10n.alreadyRuled,
      },
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _draft = _draft.copyWith(
        alwaysAllowedApps: [
          ..._draft.alwaysAllowedApps,
          for (final app in chosen)
            if (!_draft.alwaysAllowedApps.contains(app.packageId)) app.packageId,
        ],
      );
    });
  }

  Future<void> _startWindDown() async {
    final l10n = context.l10n;
    final minutes = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(l10n.windDown),
        content: Text(l10n.windDownBody),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(l10n.cancel)),
          for (final m in const [15, 30])
            FilledButton.tonal(
              key: ValueKey('p11-wind-down-$m'),
              onPressed: () => Navigator.of(ctx).pop(m),
              child: Text(l10n.minutesShort(m)),
            ),
        ],
      ),
    );
    if (minutes == null || !mounted) return;
    try {
      await ref.read(apiClientProvider).raw.post(
        '/v1/controls/children/${widget.childId}/wind-down',
        data: {'minutes': minutes},
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.windDownConfirm(minutes))),
        );
      }
    } on DioException catch (e) {
      if (mounted) {
        showErrorSnackBar(context, friendlyErrorText(l10n, e, () => l10n.windDownFailed));
      }
    } catch (e) {
      if (mounted) {
        showErrorSnackBar(context, friendlyErrorText(l10n, e, () => l10n.windDownFailed));
      }
    }
  }

  Future<void> _editRoutine([Routine? existing]) async {
    final result = await showDialog<Routine>(
      context: context,
      builder: (_) => _P11RoutineDialog(existing: existing, childId: widget.childId),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (existing == null) {
        _draft = _draft.copyWith(routines: [..._draft.routines, result]);
      } else {
        _draft = _draft.copyWith(
          routines: [for (final r in _draft.routines) r.id == existing.id ? result : r],
        );
      }
    });
  }

  Future<void> _save() async {
    final saved = _saved;
    if (saved == null || _saving) return;
    final submitted = _draft;
    final l10n = context.l10n;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).raw.patch(
        '/v1/rules/${widget.childId}',
        data: submitted.changesFrom(saved),
      );
      if (!mounted) return;
      _saved = submitted;
      ref.invalidate(rulesProvider(widget.childId));
      ref.invalidate(familyProvider);
      final savedDevices =
          ref.read(familyProvider).valueOrNull?.devicesFor(widget.childId) ?? const <Device>[];
      for (final device in savedDevices) {
        ref.invalidate(deviceCommandHistoryProvider(device.id));
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.rulesSaved)));
      }
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _error = saveErrorText(l10n, e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final rules = ref.watch(rulesProvider(widget.childId));
    ref.listen(rulesProvider(widget.childId), (_, next) => next.whenData(_applyLoaded));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.p11Title, maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
      body: rules.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorRetryView(
          message: friendlyErrorText(l10n, e, () => l10n.rulesLoadFailed),
          onRetry: () => ref.invalidate(rulesProvider(widget.childId)),
        ),
        data: (ruleSet) {
          _applyLoaded(ruleSet);
          return _buildBody(context, l10n);
        },
      ),
      bottomNavigationBar: rules.valueOrNull != null ? _buildSaveFooter(context, l10n) : null,
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final tokens = context.tokens;
    final overview = ref.watch(familyProvider).valueOrNull;
    final childHasIphone =
        overview?.devices.any((d) => d.childId == widget.childId && d.platform == 'ios') ?? false;
    final childHasAndroid =
        overview?.devices.any((d) => d.childId == widget.childId && d.platform == 'android') ??
            false;
    final showAndroidPaymentLine = childHasAndroid || !childHasIphone;

    return Column(
      children: [
        RulesBehindBanner(childId: widget.childId),
        Expanded(
          child: ListView(
            key: const ValueKey('p11-list'),
            padding: const EdgeInsets.all(AppSpace.lg),
            children: [
              _buildBedtimeCard(context, l10n, tokens, showAndroidPaymentLine),
              const SizedBox(height: AppSpace.md),
              _buildSchoolCard(context, l10n, tokens),
              const SizedBox(height: AppSpace.lg),
              Text(
                l10n.p11CustomRoutines,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(color: tokens.onSurface),
              ),
              const SizedBox(height: AppSpace.sm),
              for (final r in _draft.routines) ...[
                _buildRoutineCard(context, l10n, tokens, r),
                const SizedBox(height: AppSpace.sm),
              ],
              OutlinedButton.icon(
                key: const ValueKey('p11-add-routine'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                ),
                icon: const Icon(Icons.add),
                label: Text(l10n.addRoutine),
                onPressed: () => _editRoutine(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBedtimeCard(
    BuildContext context,
    AppLocalizations l10n,
    AppTokens tokens,
    bool showAndroidPaymentLine,
  ) {
    final st = _draft.screenTime;
    return Card(
      key: const ValueKey('p11-bedtime-card'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bedtime_outlined, color: tokens.primary),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    l10n.bedtime,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(color: tokens.onSurface),
                  ),
                ),
                Switch(
                  key: const ValueKey('p11-bedtime-switch'),
                  value: _bedtimeOn,
                  onChanged: _toggleBedtime,
                ),
              ],
            ),
            const SizedBox(height: AppSpace.sm),
            if (_bedtimeOn) ...[
              _TimeRangeRow(
                startKey: const ValueKey('p11-bedtime-start'),
                endKey: const ValueKey('p11-bedtime-end'),
                startLabel: l10n.starts,
                endLabel: l10n.ends,
                startTime: st.bedtimeStart,
                endTime: st.bedtimeEnd,
                onStartTap: () => _pickBedtime(true),
                onEndTap: () => _pickBedtime(false),
              ),
              const SizedBox(height: AppSpace.xs),
              Text(
                l10n.p11BedtimeEveryNight,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
              ),
            ] else
              Text(
                l10n.p11ScheduleOff,
                key: const ValueKey('p11-bedtime-off'),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.onSurfaceVariant),
              ),
            if (showAndroidPaymentLine) ...[
              const Divider(height: AppSpace.xl),
              Text(
                l10n.bedtimeBlocksPayments,
                key: const ValueKey('p11-bedtime-blocks-payments'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpace.xs),
              TextButton.icon(
                key: const ValueKey('p11-add-payment-app'),
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  alignment: AlignmentDirectional.centerStart,
                ),
                icon: const Icon(Icons.credit_card),
                label: Text(l10n.addPaymentApp),
                onPressed: _addPaymentApp,
              ),
            ],
            const Divider(height: AppSpace.xl),
            Text(
              l10n.windDown,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(color: tokens.onSurface),
            ),
            const SizedBox(height: AppSpace.xxs),
            Text(
              l10n.windDownSubtitle,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpace.sm),
            OutlinedButton.icon(
              key: const ValueKey('p11-wind-down-button'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _startWindDown,
              icon: const Icon(Icons.bedtime_outlined),
              label: Text(l10n.windDown),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSchoolCard(
    BuildContext context,
    AppLocalizations l10n,
    AppTokens tokens,
  ) {
    final st = _draft.screenTime;
    return Card(
      key: const ValueKey('p11-school-card'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.school_outlined, color: tokens.primary),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    l10n.schoolHours,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(color: tokens.onSurface),
                  ),
                ),
                Switch(
                  key: const ValueKey('p11-school-switch'),
                  value: _schoolOn,
                  onChanged: _toggleSchool,
                ),
              ],
            ),
            const SizedBox(height: AppSpace.sm),
            if (_schoolOn) ...[
              _TimeRangeRow(
                startKey: const ValueKey('p11-school-start'),
                endKey: const ValueKey('p11-school-end'),
                startLabel: l10n.starts,
                endLabel: l10n.ends,
                startTime: st.schoolStart,
                endTime: st.schoolEnd,
                onStartTap: () => _pickSchoolTime(true),
                onEndTap: () => _pickSchoolTime(false),
              ),
              const SizedBox(height: AppSpace.md),
              Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.xs,
                children: [
                  for (var i = 1; i <= 7; i++)
                    FilterChip(
                      key: ValueKey('p11-school-day-$i'),
                      label: Text(l10n.weekdayShort(i)),
                      selected: st.schoolDays.contains(i),
                      onSelected: (sel) {
                        final days = {...st.schoolDays};
                        sel ? days.add(i) : days.remove(i);
                        final sorted = days.toList()..sort();
                        if (sorted.isNotEmpty) {
                          _lastSchoolDays = List<int>.from(sorted);
                        }
                        _updateScreenTime((s) => ScreenTimeRule(
                              dailyLimitMinutes: s.dailyLimitMinutes,
                              weekendLimitMinutes: s.weekendLimitMinutes,
                              bedtimeStart: s.bedtimeStart,
                              bedtimeEnd: s.bedtimeEnd,
                              schoolStart: s.schoolStart,
                              schoolEnd: s.schoolEnd,
                              schoolDays: sorted,
                            ));
                      },
                    ),
                ],
              ),
            ] else
              Text(
                l10n.p11ScheduleOff,
                key: const ValueKey('p11-school-off'),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRoutineCard(
    BuildContext context,
    AppLocalizations l10n,
    AppTokens tokens,
    Routine r,
  ) {
    final daysLine = r.days.map(l10n.weekdayShort).join(' · ');
    return Card(
      key: ValueKey('p11-routine-${r.id}'),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () => _editRoutine(r),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.schedule, color: tokens.primary),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      firstStrongIsolate(r.name),
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: tokens.onSurface),
                    ),
                    const SizedBox(height: AppSpace.xxs),
                    Text(
                      ltrIsolate('${r.startTime} → ${r.endTime}'),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.onSurface),
                    ),
                    if (daysLine.isNotEmpty) ...[
                      const SizedBox(height: AppSpace.xxs),
                      Text(
                        daysLine,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: tokens.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                key: ValueKey('p11-routine-delete-${r.id}'),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  setState(() {
                    _draft = _draft.copyWith(
                      routines: [..._draft.routines]..remove(r),
                    );
                  });
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSaveFooter(BuildContext context, AppLocalizations l10n) {
    final tokens = context.tokens;
    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: tokens.surface,
          border: Border(top: BorderSide(color: tokens.border)),
        ),
        padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.sm, AppSpace.lg, AppSpace.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              Container(
                key: const ValueKey('p11-save-error'),
                decoration: BoxDecoration(
                  color: tokens.danger.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(color: tokens.danger),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.md,
                  vertical: AppSpace.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _error!,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.onSurface),
                    ),
                    const SizedBox(height: AppSpace.xs),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: AppSpace.sm,
                      children: [
                        TextButton(
                          onPressed: () => setState(() => _error = null),
                          child: Text(l10n.dismiss),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: _saving ? null : _save,
                          icon: const Icon(Icons.refresh, size: 18),
                          label: Text(l10n.retry),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpace.sm),
            ],
            FilledButton(
              key: const ValueKey('p11-save-button'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 52),
              ),
              onPressed: (_saved != null && !_saving) ? _save : null,
              child: _saving
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: tokens.onPrimary,
                      ),
                    )
                  : Text(l10n.save),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimeRangeRow extends StatelessWidget {
  final Key startKey;
  final Key endKey;
  final String startLabel;
  final String endLabel;
  final String startTime;
  final String endTime;
  final VoidCallback onStartTap;
  final VoidCallback onEndTap;

  const _TimeRangeRow({
    required this.startKey,
    required this.endKey,
    required this.startLabel,
    required this.endLabel,
    required this.startTime,
    required this.endTime,
    required this.onStartTap,
    required this.onEndTap,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
      children: [
        OutlinedButton(
          key: startKey,
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: onStartTap,
          child: Semantics(
            label: '$startLabel $startTime',
            child: Text(
              ltrIsolate(startTime),
              style: Theme.of(context).textTheme.titleLarge?.copyWith(color: tokens.onSurface),
            ),
          ),
        ),
        Text(
          '→',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(color: tokens.onSurfaceVariant),
        ),
        OutlinedButton(
          key: endKey,
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: onEndTap,
          child: Semantics(
            label: '$endLabel $endTime',
            child: Text(
              ltrIsolate(endTime),
              style: Theme.of(context).textTheme.titleLarge?.copyWith(color: tokens.onSurface),
            ),
          ),
        ),
      ],
    );
  }
}

class _P11RoutineDialog extends ConsumerStatefulWidget {
  final Routine? existing;
  final String childId;

  const _P11RoutineDialog({this.existing, required this.childId});

  @override
  ConsumerState<_P11RoutineDialog> createState() => _P11RoutineDialogState();
}

class _P11RoutineDialogState extends ConsumerState<_P11RoutineDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.existing?.name ?? '');
  late TimeOfDay _start =
      parseTime(widget.existing?.startTime ?? '17:00', const TimeOfDay(hour: 17, minute: 0));
  late TimeOfDay _end =
      parseTime(widget.existing?.endTime ?? '19:00', const TimeOfDay(hour: 19, minute: 0));
  late final Set<int> _days = {...?widget.existing?.days};
  late final Set<String> _blocked = {...?widget.existing?.blockedApps};
  late final Set<String> _allowed = {...?widget.existing?.allowedApps};

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pick(bool isStart) async {
    final t = await showTimePicker(context: context, initialTime: isStart ? _start : _end);
    if (t != null && mounted) {
      setState(() => isStart ? _start = t : _end = t);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      scrollable: true,
      title: Text(widget.existing == null ? l10n.addRoutine : l10n.editRoutine),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const ValueKey('p11-routine-name-field'),
            controller: _name,
            decoration: InputDecoration(
              labelText: l10n.nameLabel,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpace.md),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            children: [
              OutlinedButton(
                onPressed: () => _pick(true),
                child: Text(l10n.startTimeButton(ltrIsolate(formatTime(_start)))),
              ),
              OutlinedButton(
                onPressed: () => _pick(false),
                child: Text(l10n.endTimeButton(ltrIsolate(formatTime(_end)))),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.xs,
            children: [
              for (var i = 1; i <= 7; i++)
                FilterChip(
                  label: Text(l10n.weekdayShort(i)),
                  selected: _days.contains(i),
                  onSelected: (sel) => setState(() => sel ? _days.add(i) : _days.remove(i)),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.cancel)),
        FilledButton(
          key: const ValueKey('p11-routine-dialog-save'),
          onPressed: () {
            if (_name.text.trim().isEmpty) return;
            Navigator.of(context).pop(Routine(
              id: widget.existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
              name: _name.text.trim(),
              startTime: formatTime(_start),
              endTime: formatTime(_end),
              days: _days.toList()..sort(),
              blockedApps: _blocked.toList()..sort(),
              allowedApps: _allowed.toList()..sort(),
            ));
          },
          child: Text(l10n.save),
        ),
      ],
    );
  }
}
