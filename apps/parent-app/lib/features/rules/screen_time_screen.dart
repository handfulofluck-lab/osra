import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/models.dart';
import '../../api/permission_errors.dart';
import '../../core/ltr_isolate.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/clock_provider.dart';
import '../../providers/controls_provider.dart';
import '../../providers/family_provider.dart';
import '../../providers/world_class_provider.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/error_retry_view.dart';
import 'app_display.dart';
import 'rules_behind_banner.dart';

/// "1 h 20 min", "40 min", "2 h": the way people say a length of screen time.
String formatScreenMinutes(AppLocalizations l10n, int minutes) {
  final m = minutes < 0 ? 0 : minutes;
  final h = m ~/ 60;
  final r = m % 60;
  if (h == 0) return l10n.minutesShort(r);
  if (r == 0) return l10n.hoursShort(h);
  return l10n.stHoursMinutes(l10n.hoursShort(h), l10n.minutesShort(r));
}

/// The limit the child's phone applies today, matching `RuleEngine.kt` on Android: no limit when the
/// school-day limit is 0; on Saturday and Sunday the weekend limit when it is set, otherwise the
/// school-day one. Today-only extra time is held on the phone, so it is not added here.
int limitForToday(ScreenTimeRule st, DateTime now) {
  if (st.dailyLimitMinutes <= 0) return 0;
  final weekend = now.weekday == DateTime.saturday || now.weekday == DateTime.sunday;
  if (weekend && st.weekendLimitMinutes > 0) return st.weekendLimitMinutes;
  return st.dailyLimitMinutes;
}

/// P-10 Screen time (UX final decisions, part 2 page 13): today's ring, today-only extra time and
/// pause, the two weekly limits, the apps that never count, and where today's time went.
///
/// Left out on purpose (Karim 26 Nov): banked minutes, sliders, "Weekend +1 h" and a time-zone line.
/// "Edit days" is left out too: the Android child treats Saturday and Sunday as the weekend.
class ScreenTimeScreen extends ConsumerStatefulWidget {
  final String childId;
  const ScreenTimeScreen({super.key, required this.childId});

  @override
  ConsumerState<ScreenTimeScreen> createState() => _ScreenTimeScreenState();
}

class _ScreenTimeScreenState extends ConsumerState<ScreenTimeScreen> {
  static const _step = 15;
  static const _max = 720;

  late String _childId = widget.childId;
  bool _granting = false;
  bool _saving = false;
  bool _pausing = false;

  /// Shown while a limit change is on its way, so the stepper answers the tap at once.
  int? _pendingDaily;
  int? _pendingWeekend;

  Future<void> _grant(int minutes) async {
    final l10n = context.l10n;
    final childId = _childId;
    setState(() => _granting = true);
    try {
      await ref.read(apiClientProvider).raw.post(
        '/v1/controls/children/$childId/bonus',
        data: {'minutes': minutes},
      );
      ref.invalidate(rulesProvider(childId));
      ref.invalidate(familyProvider);
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(l10n.bonusGranted(minutes))));
      }
    } catch (e) {
      if (mounted) {
        showErrorSnackBar(context, friendlyErrorText(l10n, e, () => l10n.bonusFailed),
            onRetry: () => _grant(minutes));
      }
    } finally {
      if (mounted) setState(() => _granting = false);
    }
  }

  Future<void> _togglePause(bool paused) async {
    final l10n = context.l10n;
    setState(() => _pausing = true);
    try {
      if (paused) {
        await resumeInternet(ref, _childId);
      } else {
        await pauseInternet(ref, _childId);
      }
    } on ControlsRefusal catch (r) {
      if (mounted) showErrorSnackBar(context, friendlyErrorText(l10n, r.error, () => l10n.commandFailed));
    } catch (e) {
      if (mounted) showErrorSnackBar(context, friendlyErrorText(l10n, e, () => l10n.commandFailed));
    } finally {
      if (mounted) setState(() => _pausing = false);
    }
  }

  Future<void> _saveLimit({int? daily, int? weekend}) async {
    final l10n = context.l10n;
    final childId = _childId;
    setState(() {
      _saving = true;
      _pendingDaily = daily ?? _pendingDaily;
      _pendingWeekend = weekend ?? _pendingWeekend;
    });
    try {
      // A partial screenTime patch: the server merges it into the stored rules (`rules.ts`), so bedtime,
      // school hours and the other limit stay as they are.
      await ref.read(apiClientProvider).raw.patch('/v1/rules/$childId', data: {
        'screenTime': {
          if (daily != null) 'dailyLimitMinutes': daily,
          if (weekend != null) 'weekendLimitMinutes': weekend,
        },
      });
      ref.invalidate(rulesProvider(childId));
      ref.invalidate(familyProvider);
      // Keep showing the new value until the refetched rules arrive, so the stepper does not flick back.
      try {
        await ref.read(rulesProvider(childId).future);
      } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(l10n.stSaved)));
      }
    } catch (e) {
      if (mounted) {
        showErrorSnackBar(context, friendlyErrorText(l10n, e, () => l10n.stSaveFailed),
            onRetry: () => _saveLimit(daily: daily, weekend: weekend));
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _pendingDaily = null;
          _pendingWeekend = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final overviewAsync = ref.watch(familyProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.screenTime)),
      body: overviewAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => ErrorRetryView(
          key: const ValueKey('screenTimeLoadFailed'),
          message: l10n.stLoadFailed,
          onRetry: () => ref.invalidate(familyProvider),
        ),
        data: (overview) {
          final child = overview.children.where((c) => c.id == _childId).firstOrNull;
          if (child == null) {
            return ErrorRetryView(
              key: const ValueKey('screenTimeLoadFailed'),
              message: l10n.stLoadFailed,
              onRetry: () => ref.invalidate(familyProvider),
            );
          }
          final hasIphone = overview.devicesFor(_childId).any((d) => d.platform == 'ios');
          return ListView(
            padding: const EdgeInsets.all(AppSpace.lg),
            children: [
              if (overview.children.length > 1) ...[
                _ChildChips(
                  children: overview.children,
                  selectedId: _childId,
                  onSelected: (id) => setState(() {
                    _childId = id;
                    _pendingDaily = null;
                    _pendingWeekend = null;
                  }),
                ),
                const SizedBox(height: AppSpace.md),
              ],
              if (hasIphone) ...[
                Card(
                  key: const ValueKey('screenTimeIphoneNote'),
                  child: ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: Text(l10n.stIphoneNotYet),
                  ),
                ),
                const SizedBox(height: AppSpace.sm),
              ],
              ..._rulesSection(context, child),
              const SizedBox(height: AppSpace.sm),
              _WhereTimeWent(childId: _childId),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _rulesSection(BuildContext context, Child child) {
    final l10n = context.l10n;
    final rulesAsync = ref.watch(rulesProvider(_childId));
    final rules = rulesAsync.valueOrNull;
    if (rules == null) {
      if (rulesAsync.hasError) {
        return [
          ErrorRetryView(
            key: const ValueKey('screenTimeRulesFailed'),
            message: l10n.stLoadFailed,
            onRetry: () => ref.invalidate(rulesProvider(_childId)),
          ),
        ];
      }
      return [const Padding(padding: EdgeInsets.all(AppSpace.xl), child: Center(child: CircularProgressIndicator()))];
    }
    final st = rules.screenTime;
    final daily = _pendingDaily ?? st.dailyLimitMinutes;
    final weekendStored = _pendingWeekend ?? st.weekendLimitMinutes;
    final weekend = weekendStored > 0 ? weekendStored : daily;
    final limit = limitForToday(
      ScreenTimeRule(dailyLimitMinutes: daily, weekendLimitMinutes: weekendStored),
      ref.watch(clockProvider)(),
    );
    final paused = ref.watch(internetPausedProvider(_childId)).valueOrNull ?? false;
    final buttonStyle = OutlinedButton.styleFrom(minimumSize: const Size(48, 48));

    return [
      _TodayRing(used: child.screenTimeTodayMinutes, limit: limit),
      const SizedBox(height: AppSpace.sm),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.stAddTimeHeader, style: Theme.of(context).textTheme.titleMedium),
              RulesBehindBanner(childId: _childId),
              const SizedBox(height: AppSpace.sm),
              Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.sm,
                children: [
                  for (final minutes in const [15, 30, 60])
                    OutlinedButton(
                      key: ValueKey('screenTimeAdd$minutes'),
                      style: buttonStyle,
                      onPressed: _granting ? null : () => _grant(minutes),
                      child: Text(ltrIsolate('+$minutes')),
                    ),
                  OutlinedButton.icon(
                    key: const ValueKey('screenTimePause'),
                    style: buttonStyle,
                    onPressed: _pausing ? null : () => _togglePause(paused),
                    icon: Icon(paused ? Icons.wifi : Icons.wifi_off),
                    label: Text(paused ? l10n.commandResumeInternet : l10n.commandPauseInternet),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: AppSpace.sm),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.stEveryWeekHeader, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpace.xs),
              _LimitStepper(
                keyName: 'schoolDays',
                label: l10n.stSchoolDays,
                range: l10n.stSchoolDaysRange,
                value: daily == 0 ? l10n.stNoLimit : formatScreenMinutes(l10n, daily),
                onLess: _saving || daily <= 0 ? null : () => _saveLimit(daily: (daily - _step).clamp(0, _max)),
                onMore: _saving || daily >= _max ? null : () => _saveLimit(daily: (daily + _step).clamp(0, _max)),
              ),
              const Divider(),
              _LimitStepper(
                keyName: 'weekend',
                label: l10n.stWeekend,
                range: daily == 0
                    ? l10n.stWeekendNeedsSchool
                    : weekendStored > 0
                        ? l10n.stWeekendRange
                        : '${l10n.stWeekendRange} · ${l10n.stSameAsSchoolDays}',
                value: daily == 0 ? l10n.stNoLimit : formatScreenMinutes(l10n, weekend),
                onLess: _saving || daily == 0 || weekend <= _step
                    ? null
                    : () => _saveLimit(weekend: (weekend - _step).clamp(_step, _max)),
                onMore: _saving || daily == 0 || weekend >= _max
                    ? null
                    : () => _saveLimit(weekend: (weekend + _step).clamp(_step, _max)),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: AppSpace.sm),
      Card(
        child: ListTile(
          key: const ValueKey('screenTimeNeverCounted'),
          leading: const Icon(Icons.all_inclusive),
          title: Text(l10n.stNeverCounted),
          subtitle: Text(rules.alwaysAllowedApps.isEmpty
              ? l10n.stNeverCountedNone
              : l10n.stNeverCountedCount(rules.alwaysAllowedApps.length)),
          trailing: TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => context.push('/child/$_childId/rules?tab=apps'),
            child: Text(l10n.stView),
          ),
        ),
      ),
    ];
  }
}

class _ChildChips extends StatelessWidget {
  final List<Child> children;
  final String selectedId;
  final ValueChanged<String> onSelected;
  const _ChildChips({required this.children, required this.selectedId, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
      children: [
        for (final c in children)
          ChoiceChip(
            key: ValueKey('screenTimeChild-${c.id}'),
            label: Text(firstStrongIsolate(c.displayName)),
            selected: c.id == selectedId,
            onSelected: (_) => onSelected(c.id),
          ),
      ],
    );
  }
}

class _TodayRing extends StatelessWidget {
  final int used;
  final int limit;
  const _TodayRing({required this.used, required this.limit});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final String headline;
    final String detail;
    if (limit <= 0) {
      headline = l10n.stUsedToday(formatScreenMinutes(l10n, used));
      detail = l10n.stNoLimitSet;
    } else if (used <= limit) {
      headline = l10n.stLeftToday(formatScreenMinutes(l10n, limit - used));
      detail = l10n.stUsedOf(formatScreenMinutes(l10n, used), formatScreenMinutes(l10n, limit));
    } else {
      headline = l10n.stOverLimit(formatScreenMinutes(l10n, used - limit));
      detail = l10n.stUsedOf(formatScreenMinutes(l10n, used), formatScreenMinutes(l10n, limit));
    }
    final progress = limit > 0 ? (used / limit).clamp(0.0, 1.0) : 0.0;
    final over = limit > 0 && used > limit;
    return Card(
      key: const ValueKey('screenTimeToday'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          children: [
            ExcludeSemantics(
              child: SizedBox(
                width: 112,
                height: 112,
                child: CircularProgressIndicator(
                  value: limit > 0 ? progress : 0,
                  strokeWidth: 10,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  color: over ? theme.colorScheme.error : theme.colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(height: AppSpace.md),
            Text(headline, textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
            const SizedBox(height: AppSpace.xxs),
            Text(detail, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

class _LimitStepper extends StatelessWidget {
  final String keyName;
  final String label;
  final String range;
  final String value;
  final VoidCallback? onLess;
  final VoidCallback? onMore;
  const _LimitStepper({
    required this.keyName,
    required this.label,
    required this.range,
    required this.value,
    required this.onLess,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.titleSmall),
                Text(range, style: theme.textTheme.bodySmall),
                const SizedBox(height: AppSpace.xxs),
                Text(value, key: ValueKey('screenTimeValue-$keyName'), style: theme.textTheme.bodyLarge),
              ],
            ),
          ),
          IconButton(
            key: ValueKey('screenTimeLess-$keyName'),
            tooltip: l10n.stLess(label),
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: onLess,
            icon: const Icon(Icons.remove_circle_outline),
          ),
          IconButton(
            key: ValueKey('screenTimeMore-$keyName'),
            tooltip: l10n.stMore(label),
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: onMore,
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
    );
  }
}

/// Today's top apps from the usage rollup (`GET /v1/reports/usage?days=1`), named from the child's
/// installed-apps report so a parent never reads a package id.
class _WhereTimeWent extends ConsumerWidget {
  final String childId;
  const _WhereTimeWent({required this.childId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final usage = ref.watch(usageReportProvider((childId: childId, days: 1)));
    final installed = ref.watch(installedAppsProvider(childId)).valueOrNull;
    final names = {for (final a in installed?.apps ?? const <InstalledApp>[]) a.packageId: a};
    final apps = [...?usage.valueOrNull?.series.lastOrNull?.apps.where((a) => a.minutes > 0)]
      ..sort((a, b) => b.minutes.compareTo(a.minutes));
    final top = apps.take(5).toList();
    final most = top.isEmpty ? 1 : top.first.minutes;
    return Card(
      key: const ValueKey('screenTimeWhere'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.stWhereTimeWent, style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpace.sm),
            if (usage.isLoading && top.isEmpty)
              const LinearProgressIndicator()
            else if (top.isEmpty)
              Text(l10n.stNoUseYet, style: theme.textTheme.bodyMedium)
            else
              for (final a in top)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              firstStrongIsolate(appDisplayName(
                                context,
                                names,
                                a.app,
                                savedName: a.app.contains('.') ? null : a.app,
                                reportKnown: names.isNotEmpty,
                              )),
                              style: theme.textTheme.bodyLarge,
                            ),
                          ),
                          const SizedBox(width: AppSpace.sm),
                          Text(formatScreenMinutes(l10n, a.minutes), style: theme.textTheme.bodyMedium),
                        ],
                      ),
                      const SizedBox(height: AppSpace.xxs),
                      ExcludeSemantics(
                        child: LinearProgressIndicator(value: a.minutes / most, minHeight: 6),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
