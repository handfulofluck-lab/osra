import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:url_launcher/url_launcher.dart' show launchUrl, LaunchMode;

import '../../api/permission_errors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../rules/rules_behind_banner.dart';
import '../../theme/app_tokens.dart';
import '../children/child_detail_screen.dart' show AlertTile;
import '../coach/coach_card_section.dart';
import '../coach/coach_content.dart';
import '../map/family_map_screen.dart'
    show FamilyMapScreen, MapFocus, mapIsAvailable;
import '../../push/sos_fix_text.dart';

/// Alerts feed: grouped by day, severity-colored, swipe-to-acknowledge with
/// optimistic removal, detail dialog per category, and paged "load more".
class AlertsScreen extends ConsumerStatefulWidget {
  const AlertsScreen({super.key});

  @override
  ConsumerState<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends ConsumerState<AlertsScreen> {
  final List<Alert> _items = [];
  int _page = 0;
  bool _hasMore = true;
  bool _loading = false;
  String? _error;

  /// A read this guardian's invite does not cover (ADR-0014 amendment, decision 7). Kept apart
  /// from [_error] so the screen names the fix instead of printing "failed to load".
  ReadPermissionRequired? _refused;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() {
      _loading = true;
      _error = null;
      _refused = null;
    });
    try {
      final res = await ref
          .read(apiClientProvider)
          .raw
          .get('/v1/alerts', queryParameters: {'page': _page + 1, 'limit': 20});
      final pageData = AlertsPage.fromJson(res.data);
      setState(() {
        _page++;
        // De-dupe in case a live refresh raced us.
        final known = _items.map((a) => a.id).toSet();
        _items.addAll(pageData.items.where((a) => !known.contains(a.id)));
        _hasMore = pageData.items.isNotEmpty && _items.length < pageData.total;
      });
    } on DioException catch (e) {
      final refused = ReadPermissionRequired.from(e);
      setState(() {
        _refused = refused;
        // `e.message` is null for a rejected response that carried no message — the fake in the tests
        // does exactly that — and a null `_error` renders the EMPTY state, so a 500 looked like "no
        // alerts yet". Name the status instead of trusting the message to exist.
        _error = refused == null
            ? (e.message ?? 'HTTP ${e.response?.statusCode ?? e.type.name}')
            : null;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _ack(Alert alert, int index) async {
    // Optimistic removal; reinsert on failure.
    setState(() => _items.removeAt(index));
    try {
      await ref.read(apiClientProvider).raw.post('/v1/alerts/${alert.id}/ack');
      ref.invalidate(unacknowledgedCountProvider);
    } on DioException catch (e) {
      setState(() => _items.insert(index, alert));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(context.l10n.acknowledgeFailed('${e.message}'))));
      }
    }
  }

  /// Feature #8: an install_request alert offers Block (append a block
  /// appRule to the child's ruleset) and Allow (just dismiss) actions.
  void _showDetail(Alert alert) {
    // Feature #16: conversation-coach card for AI/social alert categories.
    final coachCard = coachCardFor(alert.category, _concernTypesOf(alert));
    showDialog(
      context: context,
      builder: (dialogContext) {
        final l10n = dialogContext.l10n;
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.circle,
                  size: 12,
                  color:
                      AlertTile.severityColor(alert.severity, dialogContext)),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                  child: Text(
                      l10n.alertTitleFor(alert.category, alert.title,
                          isEnglish: dialogContext.localeName.startsWith('en'),
                          tamperType: alert.metadata['type']?.toString()),
                      style: Theme.of(dialogContext).textTheme.titleMedium)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Issue #475 follow-up (Claude's ruling): the line is scoped to THIS alert's child, in the
                // dialog a parent opens later to ask "did my last change land?". The feed itself is
                // family-wide, so it carries no line; the Block path already refetches the family.
                RulesBehindBanner(childId: alert.childId),
                if (alert.body.isNotEmpty) Text(alert.body),
                // #672: where, in words and in the Bureau's sentence, in the alert the parent opened
                // deliberately — the lock screen carries neither. The coordinates are isolated (LRI/PDI)
                // so they keep their order in Arabic; the accuracy clause only when the fix has one.
                if (alert.category == 'sos' && alert.location != null) ...[
                  const SizedBox(height: AppSpace.sm),
                  Builder(builder: (_) {
                    final fix = alert.location!;
                    final text = SosFixText.of(alert, fix, DateTime.now());
                    final accuracy = text.accuracyClause(l10n, fix);
                    return Column(
                      key: const ValueKey('alert-sos-location'),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          text.locationLine(l10n, fix.isolatedCoords),
                          style: Theme.of(dialogContext).textTheme.bodySmall,
                        ),
                        if (accuracy != null)
                          Text(accuracy,
                              style:
                                  Theme.of(dialogContext).textTheme.bodySmall),
                      ],
                    );
                  }),
                ],
                // #444: the agent cannot end another app's VoIP call, so this alert must say the call
                // kept going rather than let the parent assume the block ended it. Only for the call
                // layout: a split-screen or PiP bypass already reads correctly from the body.
                if (alert.category == 'tamper' &&
                    alert.metadata['type']?.toString() == 'block_bypass' &&
                    alert.metadata['layout']?.toString() == 'call') ...[
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    l10n.alertCallBypassNote,
                    key: const ValueKey('alert-call-bypass-note'),
                    style:
                        Theme.of(dialogContext).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(dialogContext).colorScheme.error,
                            ),
                  ),
                ],
                const SizedBox(height: AppSpace.sm),
                Text(
                    '${l10n.categoryLabel(l10n.alertCategory(alert.category))} · '
                    '${l10n.severityLabel(l10n.severityName(alert.severity))}'),
                if (alert.createdAt != null)
                  Text(l10n.timeLabel(DateFormat.yMMMd(dialogContext.localeName)
                      .add_Hms()
                      .format(alert.createdAt!.toLocal()))),
                if (alert.metadata.isNotEmpty) ...[
                  const Divider(),
                  for (final entry in alert.metadata.entries)
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: AppSpace.xxs),
                      child: Text('${entry.key}: ${entry.value}',
                          style: Theme.of(dialogContext).textTheme.bodySmall),
                    ),
                ],
                const Divider(),
                CoachCardSection(card: coachCard),
              ],
            ),
          ),
          actions: [
            if (alert.category == 'install_request') ...[
              OutlinedButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(l10n.allowedSnack)));
                },
                child: Text(l10n.allowAction),
              ),
              FilledButton(
                onPressed: () => _blockRequestedApp(dialogContext, alert),
                child: Text(l10n.blockThisApp),
              ),
            ],
            // #672 UI/UX: an SOS that carried a fix gets one tap to the place, on the same family map the
            // tab shows. One **filled** button, and it is the one that works (#743 UI/UX review): on a build
            // whose in-app map cannot draw (#598/#707) "Show on map" would lead a parent in an emergency to
            // a screen that says "Not available", so it is not shown at all and the phone's own maps app
            // takes the filled slot. The quiet actions follow, then Close — the stacked order at 360 px is
            // set here on purpose rather than left to whatever the action row produces.
            if (alert.category == 'sos' && alert.location != null) ...[
              if (mapIsAvailable(Theme.of(dialogContext).platform))
                FilledButton.icon(
                  key: const ValueKey('alert-show-on-map'),
                  onPressed: () {
                    final fix = alert.location!;
                    final text = SosFixText.of(alert, fix, DateTime.now());
                    final title = l10n.alertTitleFor(
                      alert.category,
                      alert.title,
                      isEnglish: dialogContext.localeName.startsWith('en'),
                    );
                    Navigator.of(dialogContext).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => FamilyMapScreen(
                          focus: MapFocus.fromFix(
                            fix,
                            label: text.pinCaption(l10n, title),
                            accuracyM: fix.accuracyM,
                          ),
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.place),
                  label: Text(l10n.alertShowOnMap),
                )
              else
                FilledButton.icon(
                  key: const ValueKey('alert-open-in-maps'),
                  onPressed: () => _openInMaps(alert),
                  icon: const Icon(Icons.map_outlined),
                  label: Text(l10n.alertOpenInMaps),
                ),
              TextButton.icon(
                key: const ValueKey('alert-copy-coordinates'),
                onPressed: () async {
                  await Clipboard.setData(
                      ClipboardData(text: alert.location!.copyText));
                  if (!dialogContext.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.alertCoordinatesCopied)),
                  );
                },
                icon: const Icon(Icons.copy, size: 18),
                label: Text(l10n.alertCopyCoordinates),
              ),
            ],
            TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(l10n.close)),
          ],
        );
      },
    );
  }

  /// #672 UI/UX: hand the fix to the phone's own maps app. `geo:` is Android's, `maps.apple.com` is iOS's,
  /// and both render a place name we cannot — which is the point of the fallback.
  Future<void> _openInMaps(Alert alert) async {
    final fix = alert.location;
    if (fix == null) return;
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final label = Uri.encodeComponent(fix.copyText);
    final uri = isAndroid
        ? Uri.parse('geo:${fix.lat},${fix.lng}?q=${fix.lat},${fix.lng}($label)')
        : Uri.parse(
            'https://maps.apple.com/?ll=${fix.lat},${fix.lng}&q=$label');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // A phone with no maps app: the copy button above is the remaining route, and it is always there.
    }
  }

  /// Metadata `concernTypes` of a social_concern alert, normalized to strings.
  List<String> _concernTypesOf(Alert alert) {
    final raw = alert.metadata['concernTypes'];
    if (raw is List) return [for (final t in raw) '$t'];
    return const [];
  }

  /// Appends `{packageId, appName, action: 'block'}` to the child's appRules
  /// (preserving everything else the ruleset carries, incl. always-allowed).
  Future<void> _blockRequestedApp(
      BuildContext dialogContext, Alert alert) async {
    final l10n = context.l10n;
    final api = ref.read(apiClientProvider).raw;
    try {
      final res = await api.get('/v1/rules/${alert.childId}');
      final ruleSet =
          RuleSet.fromJson(Map<String, dynamic>.from(res.data as Map));
      final body = ruleSet.toJson();
      final pkg = '${alert.metadata['packageId'] ?? ''}'.trim();
      if (pkg.isEmpty)
        throw StateError('install_request alert has no packageId');
      (body['appRules'] as List).add({
        'packageId': pkg,
        'appName': '${alert.metadata['appName'] ?? pkg}',
        'action': 'block',
      });
      await api.put('/v1/rules/${alert.childId}', data: body);
      ref.invalidate(alertsProvider);
      ref.invalidate(rulesProvider(alert.childId));
      // Issue #475 follow-up: this screen writes rules, so the family snapshot must be refetched —
      // otherwise right after a save the app believes `applied == rules` and the "not picked up yet"
      // line never appears at the moment it is earned (#501 review).
      ref.invalidate(familyProvider);
      if (!dialogContext.mounted) return;
      Navigator.of(dialogContext).pop();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.appBlockedSnack)));
    } catch (e) {
      if (dialogContext.mounted) {
        ScaffoldMessenger.of(dialogContext)
            .showSnackBar(SnackBar(content: Text(l10n.blockFailed('$e'))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // Group by local day, most recent first.
    final groups = <String, List<Alert>>{};
    final order = <String>[];
    for (final a in _items) {
      final day = a.createdAt == null
          ? 'Unknown'
          : DateFormat('yyyy-MM-dd').format(a.createdAt!.toLocal());
      if (!groups.containsKey(day)) {
        groups[day] = [];
        order.add(day);
      }
      groups[day]!.add(a);
    }
    order.sort((a, b) => b.compareTo(a));

    return Scaffold(
      appBar: AppBar(title: Text(l10n.alertsTitle)),
      body: _refused != null && _items.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(l10n.readPermissionRequired,
                    textAlign: TextAlign.center),
              ),
            )
          : _error != null && _items.isEmpty
              ? Center(child: Text(l10n.alertsLoadFailed('$_error')))
              : RefreshIndicator(
                  onRefresh: () async {
                    setState(() {
                      _items.clear();
                      _page = 0;
                      _hasMore = true;
                    });
                    await _loadMore();
                  },
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: AppSpace.xl),
                    children: [
                      // NOTE: explicit empty state — without it an empty feed was a blank screen.
                      // 200 is a deliberate vertical centring offset, not a gap on the scale.
                      if (_items.isEmpty && !_loading)
                        Padding(
                          padding: const EdgeInsets.only(top: 200),
                          child: Center(child: Text(l10n.noAlertsYet)),
                        ),
                      for (final day in order)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsetsDirectional.fromSTEB(
                                  AppSpace.lg,
                                  AppSpace.lg,
                                  AppSpace.lg,
                                  AppSpace.xs),
                              child: Text(
                                _dayLabel(context, day),
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                            for (var i = 0; i < groups[day]!.length; i++)
                              Builder(builder: (_) {
                                final alert = groups[day]![i];
                                final index = _items.indexOf(alert);
                                return Dismissible(
                                  key: ValueKey(alert.id),
                                  background: Container(
                                    color: context.tokens.ok,
                                    alignment: AlignmentDirectional.centerStart,
                                    padding: const EdgeInsetsDirectional.only(
                                        start: AppSpace.xl),
                                    child: Icon(Icons.check,
                                        color: context.tokens.onOk),
                                  ),
                                  onDismissed: (_) => _ack(alert, index),
                                  child: AlertTile(
                                      alert: alert,
                                      onTap: () => _showDetail(alert)),
                                );
                              }),
                          ],
                        ),
                      if (_loading)
                        const Padding(
                            padding: EdgeInsets.all(AppSpace.lg),
                            child: Center(child: CircularProgressIndicator())),
                      if (!_loading && _hasMore)
                        Center(
                          child: TextButton(
                              onPressed: _loadMore, child: Text(l10n.loadMore)),
                        ),
                    ],
                  ),
                ),
    );
  }

  String _dayLabel(BuildContext context, String key) {
    if (key == 'Unknown') return context.l10n.unknown;
    final d = DateTime.tryParse(key);
    if (d == null) return key;
    return DateFormat('EEEE, MMM d, yyyy', context.localeName).format(d);
  }
}
