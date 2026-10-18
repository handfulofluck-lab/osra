import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../children/child_detail_screen.dart' show AlertTile;
import '../coach/coach_card_section.dart';
import '../coach/coach_content.dart';

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
    });
    try {
      final res = await ref.read(apiClientProvider).raw.get('/v1/alerts', queryParameters: {'page': _page + 1, 'limit': 20});
      final pageData = AlertsPage.fromJson(res.data);
      setState(() {
        _page++;
        // De-dupe in case a live refresh raced us.
        final known = _items.map((a) => a.id).toSet();
        _items.addAll(pageData.items.where((a) => !known.contains(a.id)));
        _hasMore = pageData.items.isNotEmpty && _items.length < pageData.total;
      });
    } on DioException catch (e) {
      setState(() => _error = e.message);
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Acknowledge failed: ${e.message}')));
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
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.circle, size: 12, color: AlertTile.severityColor(alert.severity, dialogContext)),
            const SizedBox(width: 8),
            Expanded(child: Text(alert.title, style: Theme.of(dialogContext).textTheme.titleMedium)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (alert.body.isNotEmpty) Text(alert.body),
              const SizedBox(height: 8),
              Text('Category: ${alert.category} · Severity: ${alert.severity}'),
              if (alert.createdAt != null)
                Text('Time: ${DateFormat.yMMMd().add_Hms().format(alert.createdAt!.toLocal())}'),
              if (alert.metadata.isNotEmpty) ...[
                const Divider(),
                for (final entry in alert.metadata.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text('${entry.key}: ${entry.value}', style: Theme.of(dialogContext).textTheme.bodySmall),
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
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Allowed')));
              },
              child: const Text('Allow'),
            ),
            FilledButton(
              onPressed: () => _blockRequestedApp(dialogContext, alert),
              child: const Text('Block this app'),
            ),
          ],
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Close')),
        ],
      ),
    );
  }

  /// Metadata `concernTypes` of a social_concern alert, normalized to strings.
  List<String> _concernTypesOf(Alert alert) {
    final raw = alert.metadata['concernTypes'];
    if (raw is List) return [for (final t in raw) '$t'];
    return const [];
  }

  /// Appends `{packageId, appName, action: 'block'}` to the child's appRules
  /// (preserving everything else the ruleset carries, incl. always-allowed).
  Future<void> _blockRequestedApp(BuildContext dialogContext, Alert alert) async {
    final api = ref.read(apiClientProvider).raw;
    try {
      final res = await api.get('/v1/rules/${alert.childId}');
      final ruleSet = RuleSet.fromJson(Map<String, dynamic>.from(res.data as Map));
      final body = ruleSet.toJson();
      final pkg = '${alert.metadata['packageId'] ?? ''}'.trim();
      if (pkg.isEmpty) throw StateError('install_request alert has no packageId');
      (body['appRules'] as List).add({
        'packageId': pkg,
        'appName': '${alert.metadata['appName'] ?? pkg}',
        'action': 'block',
      });
      await api.put('/v1/rules/${alert.childId}', data: body);
      ref.invalidate(alertsProvider);
      ref.invalidate(rulesProvider(alert.childId));
      if (!dialogContext.mounted) return;
      Navigator.of(dialogContext).pop();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('App blocked')));
    } catch (e) {
      if (dialogContext.mounted) {
        ScaffoldMessenger.of(dialogContext).showSnackBar(SnackBar(content: Text('Block failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Group by local day, most recent first.
    final groups = <String, List<Alert>>{};
    final order = <String>[];
    for (final a in _items) {
      final day = a.createdAt == null ? 'Unknown' : DateFormat('yyyy-MM-dd').format(a.createdAt!.toLocal());
      if (!groups.containsKey(day)) {
        groups[day] = [];
        order.add(day);
      }
      groups[day]!.add(a);
    }
    order.sort((a, b) => b.compareTo(a));

    return Scaffold(
      appBar: AppBar(title: const Text('Alerts')),
      body: _error != null && _items.isEmpty
          ? Center(child: Text('Failed to load alerts: $_error'))
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
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  // NOTE: explicit empty state — without it an empty feed was a blank screen.
                  if (_items.isEmpty && !_loading)
                    const Padding(
                      padding: EdgeInsets.only(top: 200),
                      child: Center(child: Text('No alerts yet')),
                    ),
                  for (final day in order)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                          child: Text(
                            _dayLabel(day),
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        for (var i = 0; i < groups[day]!.length; i++)
                          Builder(builder: (_) {
                            final alert = groups[day]![i];
                            final index = _items.indexOf(alert);
                            return Dismissible(
                              key: ValueKey(alert.id),
                              background: Container(color: Colors.green, alignment: Alignment.centerLeft, padding: const EdgeInsets.only(left: 24), child: const Icon(Icons.check, color: Colors.white)),
                              onDismissed: (_) => _ack(alert, index),
                              child: AlertTile(alert: alert, onTap: () => _showDetail(alert)),
                            );
                          }),
                      ],
                    ),
                  if (_loading) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
                  if (!_loading && _hasMore)
                    Center(
                      child: TextButton(onPressed: _loadMore, child: const Text('Load more')),
                    ),
                ],
              ),
            ),
    );
  }

  String _dayLabel(String key) {
    if (key == 'Unknown') return key;
    final d = DateTime.tryParse(key);
    if (d == null) return key;
    return DateFormat('EEEE, MMM d, yyyy').format(d);
  }
}
