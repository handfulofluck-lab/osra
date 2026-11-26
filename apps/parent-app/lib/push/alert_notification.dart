import 'package:flutter/foundation.dart';

import '../api/models.dart';

/// Keep explicit delivery IDs separate from the legacy alert IDs persisted by
/// earlier Parent builds. The alert ID still opens the alert's detail.
String pushNotificationKey(String alertId, String? deliveryId) =>
    deliveryId == null ? alertId : 'delivery:$alertId:$deliveryId';

@immutable
class NotificationDelivery {
  final Alert alert;
  final String? deliveryId;
  final DateTime? createdAt;
  final int sequence;

  const NotificationDelivery({
    required this.alert,
    this.deliveryId,
    this.createdAt,
    this.sequence = 0,
  });

  String get key => pushNotificationKey(alert.id, deliveryId);

  String get rememberKey =>
      sequence == 0 ? key : '$_deliveryProgressPrefix$sequence:${alert.id}';
}

/// What one authenticated alert wake should put on the lock screen.
@immutable
class NotificationPlan {
  /// Oldest first, so the newest delivery ends up on top.
  final List<NotificationDelivery> toShow;

  /// Every fresh key, even those dropped by the display cap.
  final List<String> remember;

  const NotificationPlan({required this.toShow, required this.remember});

  bool get isEmpty => toShow.isEmpty;
}

/// Identifies a grouped push already assigned to the native iOS presenter.
bool isNativeGroupedWakeData(Map<String, dynamic> data) => data['g'] == '1';

bool hasGroupedDeliveryMetadata(Alert alert) =>
    alert.metadata.containsKey('pushDeliveryId') ||
    alert.metadata.containsKey('pushDeliverySeq') ||
    alert.metadata.containsKey('pushDeliveries');

/// New grouped alerts carry a sequence even when no notification was sent.
/// Older alerts without delivery metadata keep one notification per alert.
Iterable<NotificationDelivery> _deliveriesFor(Alert alert) sync* {
  final metadata = alert.metadata;
  final history = metadata['pushDeliveries'];
  final latestId = _nonEmptyString(metadata['pushDeliveryId']);
  if (metadata['pushDeliverySeq'] == 0) return;
  final latestSeq = _sequence(metadata['pushDeliverySeq']);
  if (history is List) {
    for (final entry in history) {
      if (entry is! Map) continue;
      final id = _nonEmptyString(entry['id']);
      final sequence = _sequence(entry['seq']);
      if (id == null || sequence == 0) continue;
      yield NotificationDelivery(
        alert: alert,
        deliveryId: id,
        createdAt:
            DateTime.tryParse(_nonEmptyString(entry['createdAt']) ?? '') ??
                alert.createdAt,
        sequence: sequence,
      );
    }
  }
  if (latestId != null) {
    yield NotificationDelivery(
      alert: alert,
      deliveryId: latestId,
      createdAt: alert.updatedAt ?? alert.createdAt,
      sequence: latestSeq,
    );
  } else if (!hasGroupedDeliveryMetadata(alert)) {
    yield NotificationDelivery(alert: alert, createdAt: alert.createdAt);
  }
}

String? _nonEmptyString(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

int _sequence(Object? value) => value is int && value > 0 ? value : 0;

const _deliveryProgressPrefix = 'delivery-seq:';
const _maxRememberedSequencesPerAlert = 64;

({String alertId, Iterable<int> sequences})? _storedProgress(String key) {
  if (!key.startsWith(_deliveryProgressPrefix)) return null;
  final end = key.indexOf(':', _deliveryProgressPrefix.length);
  if (end < 0 || end == key.length - 1) return null;
  final sequences = key
      .substring(_deliveryProgressPrefix.length, end)
      .split(',')
      .map(int.tryParse)
      .whereType<int>()
      .where((sequence) => sequence > 0);
  return (alertId: key.substring(end + 1), sequences: sequences);
}

Map<String, Set<int>> _deliveryProgress(Iterable<String> keys) {
  final progress = <String, Set<int>>{};
  for (final key in keys) {
    final item = _storedProgress(key);
    if (item != null) {
      (progress[item.alertId] ??= {}).addAll(item.sequences);
    }
  }
  return progress;
}

/// Compact several shown entries for an alert into one store row. Keep the
/// individual sequences so a failed lower delivery can retry even if a
/// concurrent wake already presented a higher sequence.
Set<String> compactShownNotificationKeys(Set<String> keys,
    {required int limit}) {
  final progress = _deliveryProgress(keys);
  final newestFirst = <String>[];
  for (final key in keys.toList().reversed) {
    final item = _storedProgress(key);
    if (item == null) {
      newestFirst.add(key);
      continue;
    }
    final seen = progress.remove(item.alertId);
    if (seen == null) continue;
    final retained = seen.toList()..sort((a, b) => b.compareTo(a));
    final sequences = retained.take(_maxRememberedSequencesPerAlert).join(',');
    newestFirst.add('$_deliveryProgressPrefix$sequences:${item.alertId}');
  }
  return newestFirst.take(limit).toList().reversed.toSet();
}

int _compareDeliveries(NotificationDelivery a, NotificationDelivery b) {
  final at = a.createdAt;
  final bt = b.createdAt;
  if (at == null && bt != null) return -1;
  if (bt == null && at != null) return 1;
  if (at != null && bt != null) {
    final order = at.compareTo(bt);
    if (order != 0) return order;
  }
  final alertOrder = a.alert.id.compareTo(b.alert.id);
  if (alertOrder != 0) return alertOrder;
  final sequenceOrder = a.sequence.compareTo(b.sequence);
  return sequenceOrder == 0 ? a.key.compareTo(b.key) : sequenceOrder;
}

/// Plan notifications from one authenticated snapshot. Acknowledged alerts
/// stay quiet. Repeated wakes and silent updates to a grouped alert must not
/// replay a delivery. The history lets one coalesced wake recover several
/// deliveries from the same alert without making several alert cards.
NotificationPlan planNotifications({
  required List<Alert> alerts,
  required Set<String> alreadyShown,
  bool presentGroupedDeliveries = true,
  int max = 5,
}) {
  final fresh = <NotificationDelivery>[];
  final progress = _deliveryProgress(alreadyShown);
  final seen = <String>{};
  for (final alert in alerts) {
    if (alert.acknowledged ||
        (!presentGroupedDeliveries && hasGroupedDeliveryMetadata(alert))) {
      continue;
    }
    for (final delivery in _deliveriesFor(alert)) {
      if (alreadyShown.contains(delivery.key) ||
          (progress[alert.id]?.contains(delivery.sequence) ?? false) ||
          !seen.add(delivery.key)) {
        continue;
      }
      fresh.add(delivery);
    }
  }
  fresh.sort(_compareDeliveries);

  final keep = fresh.length <= max ? fresh : fresh.sublist(fresh.length - max);
  return NotificationPlan(
    toShow: List.unmodifiable(keep),
    remember: List.unmodifiable(fresh.map((delivery) => delivery.rememberKey)),
  );
}
