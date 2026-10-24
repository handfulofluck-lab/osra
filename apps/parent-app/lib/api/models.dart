import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color, Colors;

/// Plain Dart models mirroring `packages/shared-types/src/index.ts` field
/// names (displayName, birthYear, batteryPct, lastSeen, blockedCategories,
/// dailyLimitMinutes, bedtimeStart, ...). All `fromJson` factories tolerate
/// missing/extra keys and never throw on absent optional fields.

String _str(dynamic v, [String fallback = '']) => v is String ? v : (v?.toString() ?? fallback);
int _int(dynamic v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

bool _bool(dynamic v, [bool fallback = false]) => v is bool ? v : fallback;
String? _strOrNull(dynamic v) => v == null ? null : _str(v);
int? _intOrNull(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}
List<String> _strList(dynamic v) => v is List ? [for (final e in v) _str(e)] : const <String>[];
List<int> _intList(dynamic v) => v is List ? [for (final e in v) _int(e)] : const <int>[];
List<Map<String, dynamic>> _mapList(dynamic v) =>
    v is List ? [for (final e in v) Map<String, dynamic>.from(e as Map)] : const <Map<String, dynamic>>[];

/// Family account record; `region` is one of US/EU/UK/OTHER.
@immutable
class Family {
  final String id;
  final String name;
  final String region;
  final DateTime? createdAt;

  const Family({required this.id, required this.name, required this.region, this.createdAt});

  factory Family.fromJson(Map<String, dynamic> json) => Family(
        id: _str(json['id']),
        name: _str(json['name']),
        region: _str(json['region'], 'US'),
        createdAt: DateTime.tryParse(_str(json['createdAt'])),
      );
}

/// A parent/guardian account. `role` is owner/co-parent/guardian.
@immutable
class Parent {
  final String id;
  final String familyId;
  final String email;
  final String displayName;
  final String role;
  final bool mfaEnabled;

  const Parent({
    required this.id,
    required this.familyId,
    required this.email,
    required this.displayName,
    this.role = 'owner',
    this.mfaEnabled = false,
  });

  factory Parent.fromJson(Map<String, dynamic> json) => Parent(
        id: _str(json['id']),
        familyId: _str(json['familyId']),
        email: _str(json['email']),
        displayName: _str(json['displayName']),
        role: _str(json['role'], 'owner'),
        mfaEnabled: _bool(json['mfaEnabled']),
      );
}

/// A child profile. `screenTimeTodayMinutes` is a server-side aggregation
/// convenience used by the dashboard progress bar (not in shared-types).
@immutable
class Child {
  final String id;
  final String familyId;
  final String displayName;
  final int birthYear;
  final String? avatarUrl;
  final String consentRecordId;
  final int screenTimeTodayMinutes;

  const Child({
    required this.id,
    required this.familyId,
    required this.displayName,
    required this.birthYear,
    this.avatarUrl,
    this.consentRecordId = '',
    this.screenTimeTodayMinutes = 0,
  });

  factory Child.fromJson(Map<String, dynamic> json) => Child(
        id: _str(json['id']),
        familyId: _str(json['familyId']),
        displayName: _str(json['displayName']),
        birthYear: _int(json['birthYear']),
        avatarUrl: _strOrNull(json['avatarUrl']),
        consentRecordId: _str(json['consentRecordId']),
        screenTimeTodayMinutes: _int(json['screenTimeTodayMinutes']),
      );

  /// First letters of the display name, for avatar initials.
  String get initials {
    final parts = displayName.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }
}

/// A child's enrolled device. `status` is online/offline/locked/sos.
@immutable
class Device {
  final String id;
  final String childId;
  final String platform;
  final String model;
  final String osVersion;
  final String status;
  final int batteryPct;
  final DateTime? lastSeen;
  final String? pushToken;

  const Device({
    required this.id,
    required this.childId,
    required this.platform,
    required this.model,
    required this.osVersion,
    required this.status,
    required this.batteryPct,
    this.lastSeen,
    this.pushToken,
  });

  factory Device.fromJson(Map<String, dynamic> json) => Device(
        id: _str(json['id']),
        childId: _str(json['childId']),
        platform: _str(json['platform']),
        model: _str(json['model']),
        osVersion: _str(json['osVersion']),
        status: _str(json['status'], 'offline'),
        batteryPct: _int(json['batteryPct']),
        lastSeen: DateTime.tryParse(_str(json['lastSeen'])),
        pushToken: _strOrNull(json['pushToken']),
      );
}

/// One durable device command from `GET /v1/devices/:id/commands/history`.
///
/// `status` is one of `pending`, `delivered`, `acked`, `failed`, `expired`
/// (`services/api/src/lib/deviceCommands.ts`). Only `acked` means the child
/// device confirmed it ran the command; `delivered` only means the agent
/// collected the row.
@immutable
class DeviceCommand {
  final String id;
  final String deviceId;
  final String type;
  final String status;
  final DateTime? createdAt;
  final DateTime? expiresAt;
  final DateTime? deliveredAt;
  final DateTime? ackedAt;
  final int attempts;

  /// Issue #231: what the agent reported when it settled the row — `{'reason': ...}` for a
  /// device-side refusal, `{'fix': 'fresh'|'cached'}` for a locate that produced a fix. Null for
  /// rows settled before this contract or by the server (a `locate_now` refused at the POST).
  final Map<String, dynamic>? result;

  const DeviceCommand({
    required this.id,
    required this.deviceId,
    required this.type,
    required this.status,
    this.createdAt,
    this.expiresAt,
    this.deliveredAt,
    this.ackedAt,
    this.attempts = 0,
    this.result,
  });

  factory DeviceCommand.fromJson(Map<String, dynamic> json) => DeviceCommand(
        id: _str(json['id']),
        deviceId: _str(json['deviceId']),
        type: _str(json['type']),
        status: _str(json['status'], 'pending'),
        createdAt: DateTime.tryParse(_str(json['createdAt'])),
        expiresAt: DateTime.tryParse(_str(json['expiresAt'])),
        deliveredAt: DateTime.tryParse(_str(json['deliveredAt'])),
        ackedAt: DateTime.tryParse(_str(json['ackedAt'])),
        attempts: _int(json['attempts']),
        result: json['result'] is Map
            ? Map<String, dynamic>.from(json['result'] as Map)
            : null,
      );

  /// The child device has confirmed it ran the command.
  bool get isAcked => status == 'acked';

  /// The agent's own refusal reason (`lock_screen_unavailable`, `background_location_missing`, …),
  /// or null when the row carries none. Issue #231: a device-side refusal arrives as an ack, long
  /// after the POST returned, so this is the only place the parent can learn why it failed.
  String? get refusalReason =>
      result != null && result!['reason'] is String ? result!['reason'] as String : null;
}

/// Daily screen-time windows. Times are "HH:mm" local strings; `days` is a
/// list of ISO weekday numbers (1=Mon ... 7=Sun).
@immutable
class ScreenTimeRule {
  final int dailyLimitMinutes;
  final int weekendLimitMinutes;
  final String bedtimeStart;
  final String bedtimeEnd;
  final String schoolStart;
  final String schoolEnd;
  final List<int> schoolDays;

  const ScreenTimeRule({
    this.dailyLimitMinutes = 180,
    this.weekendLimitMinutes = 240,
    this.bedtimeStart = '21:00',
    this.bedtimeEnd = '07:00',
    this.schoolStart = '08:00',
    this.schoolEnd = '15:00',
    this.schoolDays = const [1, 2, 3, 4, 5],
  });

  factory ScreenTimeRule.fromJson(Map<String, dynamic> json) {
    final school = json['schoolHours'] is Map ? Map<String, dynamic>.from(json['schoolHours'] as Map) : const <String, dynamic>{};
    return ScreenTimeRule(
      dailyLimitMinutes: _int(json['dailyLimitMinutes'], 180),
      weekendLimitMinutes: _int(json['weekendLimitMinutes'], 240),
      bedtimeStart: _str(json['bedtimeStart'], '21:00'),
      bedtimeEnd: _str(json['bedtimeEnd'], '07:00'),
      schoolStart: _str(school['start'], '08:00'),
      schoolEnd: _str(school['end'], '15:00'),
      schoolDays: _intList(school['days']).isEmpty ? const [1, 2, 3, 4, 5] : _intList(school['days']),
    );
  }

  Map<String, dynamic> toJson() => {
        'dailyLimitMinutes': dailyLimitMinutes,
        'weekendLimitMinutes': weekendLimitMinutes,
        'bedtimeStart': bedtimeStart,
        'bedtimeEnd': bedtimeEnd,
        'schoolHours': {'start': schoolStart, 'end': schoolEnd, 'days': schoolDays},
      };
}

/// The 13 recommended web-filter categories applied by the Feature #1
/// 'Recommended protection' preset. Duplicates `DEFAULT_BLOCKED_CATEGORIES`
/// in packages/shared-types/src/world-class.ts — Dart cannot import the TS
/// package, so this mirror must be kept in sync manually.
const kRecommendedCategories = [
  'pornography',
  'gambling',
  'drugs',
  'violence',
  'weapons',
  'hate',
  'self_harm',
  'dating',
  'social_media_nsfw',
  'chat_random',
  'proxies_vpn',
  'warez',
  'ai_chatbots',
];

/// Web-filtering policy. Categories are free-form strings
/// (e.g. pornography, gambling) matching the server's category list.
@immutable
class WebFilterRule {
  final List<String> blockedCategories;
  final List<String> allowedDomains;
  final List<String> blockedDomains;
  final bool safeSearchEnforced;
  final String youtubeRestrictedMode;

  const WebFilterRule({
    this.blockedCategories = const [],
    this.allowedDomains = const [],
    this.blockedDomains = const [],
    this.safeSearchEnforced = true,
    this.youtubeRestrictedMode = 'strict',
  });

  factory WebFilterRule.fromJson(Map<String, dynamic> json) => WebFilterRule(
        blockedCategories: _strList(json['blockedCategories']),
        allowedDomains: _strList(json['allowedDomains']),
        blockedDomains: _strList(json['blockedDomains']),
        safeSearchEnforced: _bool(json['safeSearchEnforced'], true),
        youtubeRestrictedMode: _str(json['youtubeRestrictedMode'], 'strict'),
      );

  Map<String, dynamic> toJson() => {
        'blockedCategories': blockedCategories,
        'allowedDomains': allowedDomains,
        'blockedDomains': blockedDomains,
        'safeSearchEnforced': safeSearchEnforced,
        'youtubeRestrictedMode': youtubeRestrictedMode,
      };

  WebFilterRule copyWith({
    List<String>? blockedCategories,
    List<String>? allowedDomains,
    List<String>? blockedDomains,
    bool? safeSearchEnforced,
    String? youtubeRestrictedMode,
  }) =>
      WebFilterRule(
        blockedCategories: blockedCategories ?? this.blockedCategories,
        allowedDomains: allowedDomains ?? this.allowedDomains,
        blockedDomains: blockedDomains ?? this.blockedDomains,
        safeSearchEnforced: safeSearchEnforced ?? this.safeSearchEnforced,
        youtubeRestrictedMode: youtubeRestrictedMode ?? this.youtubeRestrictedMode,
      );
}

/// Per-app policy. `action` is allow/block/time_limit; `dailyLimitMinutes`
/// is only meaningful for time_limit.
@immutable
class AppRule {
  final String packageId;
  final String appName;
  final String action;
  final int? dailyLimitMinutes;

  const AppRule({required this.packageId, required this.appName, this.action = 'allow', this.dailyLimitMinutes});

  factory AppRule.fromJson(Map<String, dynamic> json) => AppRule(
        packageId: _str(json['packageId']),
        appName: _str(json['appName']),
        action: _str(json['action'], 'allow'),
        dailyLimitMinutes: json['dailyLimitMinutes'] == null ? null : _int(json['dailyLimitMinutes']),
      );

  Map<String, dynamic> toJson() => {
        'packageId': packageId,
        'appName': appName,
        'action': action,
        if (dailyLimitMinutes != null) 'dailyLimitMinutes': dailyLimitMinutes,
      };
}

/// Roadmap 3.4: one launcher-visible app reported by a child device
/// (`GET /v1/devices/:id/apps`). `isSystem` is the OS system flag; the list
/// carries no usage, launch counts or icons.
@immutable
class InstalledApp {
  final String packageId;
  final String label;
  final bool isSystem;

  const InstalledApp({required this.packageId, required this.label, this.isSystem = false});

  factory InstalledApp.fromJson(Map<String, dynamic> json) {
    final packageId = _str(json['packageId']);
    final label = _str(json['label']).trim();
    return InstalledApp(
      packageId: packageId,
      // The API already falls back to the package id; repeat it so a hand-written
      // fixture cannot render an empty row.
      label: label.isEmpty ? packageId : label,
      isSystem: _bool(json['isSystem']),
    );
  }
}

/// The union of a child's devices' installed-app reports. A child with two
/// devices sees one merged list; the first device that names a package wins.
@immutable
class InstalledAppsReport {
  final List<InstalledApp> apps;
  final int version;
  final DateTime? reportedAt;
  final bool truncated;

  const InstalledAppsReport({
    this.apps = const [],
    this.version = 1,
    this.reportedAt,
    this.truncated = false,
  });

  factory InstalledAppsReport.fromJson(Map<String, dynamic> json) => InstalledAppsReport(
        apps: [for (final m in _mapList(json['apps'])) InstalledApp.fromJson(m)],
        version: _int(json['version'], 1),
        reportedAt: DateTime.tryParse(_str(json['reportedAt'])),
        truncated: _bool(json['truncated']),
      );

  /// Merge another device's report into this one: dedupe by package id, keep
  /// the newest `reportedAt`, and sort by label then package for a stable UI.
  InstalledAppsReport merge(InstalledAppsReport other) {
    final byPackage = <String, InstalledApp>{};
    for (final app in [...apps, ...other.apps]) {
      byPackage.putIfAbsent(app.packageId, () => app);
    }
    final merged = byPackage.values.toList()
      ..sort((a, b) {
        final byLabel = a.label.toLowerCase().compareTo(b.label.toLowerCase());
        return byLabel != 0 ? byLabel : a.packageId.compareTo(b.packageId);
      });
    final a = reportedAt;
    final b = other.reportedAt;
    final newest = a == null ? b : (b == null || !b.isAfter(a) ? a : b);
    return InstalledAppsReport(
      apps: merged,
      version: version >= other.version ? version : other.version,
      reportedAt: newest,
      truncated: truncated || other.truncated,
    );
  }
}

/// A named time window (homework, dinner, ...). Times are "HH:mm"; `days`
/// is ISO weekday numbers (1=Mon ... 7=Sun).
@immutable
class Routine {
  final String id;
  final String name;
  final String startTime;
  final String endTime;
  final List<int> days;
  final List<String> blockedApps;
  final List<String> allowedApps;

  const Routine({
    required this.id,
    required this.name,
    required this.startTime,
    required this.endTime,
    this.days = const [],
    this.blockedApps = const [],
    this.allowedApps = const [],
  });

  factory Routine.fromJson(Map<String, dynamic> json) => Routine(
        id: _str(json['id']),
        name: _str(json['name']),
        startTime: _str(json['startTime']),
        endTime: _str(json['endTime']),
        days: _intList(json['days']),
        blockedApps: _strList(json['blockedApps']),
        allowedApps: _strList(json['allowedApps']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'startTime': startTime,
        'endTime': endTime,
        'days': days,
        'blockedApps': blockedApps,
        'allowedApps': allowedApps,
      };
}

/// Full ruleset for one child (the unit exchanged with `/v1/rules/:childId`).
@immutable
class RuleSet {
  final String id;
  final String childId;
  final ScreenTimeRule screenTime;
  final WebFilterRule webFilter;
  final List<AppRule> appRules;
  final List<Routine> routines;
  final Map<String, bool> socialMonitoring;
  final List<String> contactAllowlist;
  final List<String> alwaysAllowedApps;
  final DateTime? updatedAt;

  const RuleSet({
    this.id = '',
    this.childId = '',
    this.screenTime = const ScreenTimeRule(),
    this.webFilter = const WebFilterRule(),
    this.appRules = const [],
    this.routines = const [],
    this.socialMonitoring = const {},
    this.contactAllowlist = const [],
    this.alwaysAllowedApps = const [],
    this.updatedAt,
  });

  factory RuleSet.fromJson(Map<String, dynamic> json) {
    final root = json['ruleSet'] is Map ? Map<String, dynamic>.from(json['ruleSet'] as Map) : json;
    final social = root['socialMonitoring'] is Map ? Map<String, dynamic>.from(root['socialMonitoring'] as Map) : const <String, dynamic>{};
    return RuleSet(
      id: _str(root['id']),
      childId: _str(root['childId']),
      screenTime: root['screenTime'] is Map ? ScreenTimeRule.fromJson(Map<String, dynamic>.from(root['screenTime'] as Map)) : const ScreenTimeRule(),
      webFilter: root['webFilter'] is Map ? WebFilterRule.fromJson(Map<String, dynamic>.from(root['webFilter'] as Map)) : const WebFilterRule(),
      appRules: [for (final m in _mapList(root['appRules'])) AppRule.fromJson(m)],
      routines: [for (final m in _mapList(root['routines'])) Routine.fromJson(m)],
      // NOTE: apps absent from the map default to ON in the UI (spec #2).
      socialMonitoring: {for (final e in social.entries) e.key: e.value == true},
      contactAllowlist: _strList(root['contactAllowlist']),
      alwaysAllowedApps: _strList(root['alwaysAllowedApps']),
      updatedAt: DateTime.tryParse(_str(root['updatedAt'])),
    );
  }

  /// Full PUT body — the server PATCH-merges, so we always send everything.
  Map<String, dynamic> toJson() => {
        'screenTime': screenTime.toJson(),
        'webFilter': webFilter.toJson(),
        'appRules': [for (final r in appRules) r.toJson()],
        'routines': [for (final r in routines) r.toJson()],
        'socialMonitoring': socialMonitoring,
        'contactAllowlist': contactAllowlist,
        'alwaysAllowedApps': alwaysAllowedApps,
      };
}

/// A flagged social-monitoring event from the encrypted vault (features #2/#24).
/// `severity` is info/warning/critical; `concernTypes` are free-form tags.
@immutable
class SocialConcernEvent {
  final String id;
  final String app;
  final String contact;
  final String severity;
  final String preview;
  final List<String> concernTypes;
  final DateTime? createdAt;

  const SocialConcernEvent({
    required this.id,
    required this.app,
    required this.contact,
    required this.severity,
    required this.preview,
    this.concernTypes = const [],
    this.createdAt,
  });

  factory SocialConcernEvent.fromJson(Map<String, dynamic> json) => SocialConcernEvent(
        id: _str(json['id']),
        app: _str(json['app']),
        contact: _str(json['contact']),
        severity: _str(json['severity'], 'info'),
        preview: _str(json['preview']),
        concernTypes: _strList(json['concernTypes']),
        createdAt: DateTime.tryParse(_str(json['createdAt'])),
      );
}

/// A flagged search query event (Track 1 & 2 content monitoring).
@immutable
class SearchEventItem {
  final String id;
  final String engine;
  final String query;
  final String severity;
  final List<String> concernTypes;
  final DateTime? createdAt;

  const SearchEventItem({
    required this.id,
    required this.engine,
    required this.query,
    required this.severity,
    this.concernTypes = const [],
    this.createdAt,
  });

  factory SearchEventItem.fromJson(Map<String, dynamic> json) => SearchEventItem(
        id: _str(json['id']),
        engine: _str(json['engine'], 'search'),
        query: _str(json['query']),
        severity: _str(json['severity'], 'info'),
        concernTypes: _strList(json['concernTypes']),
        createdAt: DateTime.tryParse(_str(json['createdAt'])),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'engine': engine,
        'query': query,
        'severity': severity,
        'concernTypes': concernTypes,
        if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
      };
}

/// One persisted call/SMS activity entry (feature #6). `payload` holds
/// `{number, durationSec, direction}` for calls and `{number, bodyPreview}`
/// for texts; extra keys are preserved and ignored.
@immutable
class ActivityEvent {
  final String id;
  final String type;
  final Map<String, dynamic> payload;
  final DateTime? ts;

  const ActivityEvent({required this.id, required this.type, this.payload = const {}, this.ts});

  factory ActivityEvent.fromJson(Map<String, dynamic> json) => ActivityEvent(
        id: _str(json['id']),
        type: _str(json['type']),
        payload: json['payload'] is Map ? Map<String, dynamic>.from(json['payload'] as Map) : const {},
        ts: DateTime.tryParse(_str(json['ts'] ?? json['createdAt'])),
      );

  String? get number => payload['number'] is String ? payload['number'] as String : null;
  int get durationSec => _int(payload['durationSec']);
  String get direction => _str(payload['direction']);
  String get bodyPreview => _str(payload['bodyPreview']);
}

/// One location sample from a device.
@immutable
class LocationPing {
  final String deviceId;
  final double lat;
  final double lng;
  final double accuracyM;
  final DateTime? timestamp;

  const LocationPing({required this.deviceId, required this.lat, required this.lng, this.accuracyM = 0, this.timestamp});

  factory LocationPing.fromJson(Map<String, dynamic> json) => LocationPing(
        deviceId: _str(json['deviceId']),
        lat: (json['lat'] as num?)?.toDouble() ?? 0,
        lng: (json['lng'] as num?)?.toDouble() ?? 0,
        accuracyM: (json['accuracyM'] as num?)?.toDouble() ?? 0,
        timestamp: DateTime.tryParse(_str(json['timestamp'])),
      );
}

/// A named geofence circle around a lat/lng point. `routineId` optionally
/// binds a routine that agents auto-apply while the child is inside (#23).
@immutable
class Geofence {
  final String id;
  final String childId;
  final String label;
  final double lat;
  final double lng;
  final double radiusM;
  final bool notifyOnEnter;
  final bool notifyOnExit;
  final String? routineId;

  const Geofence({
    required this.id,
    required this.childId,
    required this.label,
    required this.lat,
    required this.lng,
    this.radiusM = 100,
    this.notifyOnEnter = true,
    this.notifyOnExit = true,
    this.routineId,
  });

  factory Geofence.fromJson(Map<String, dynamic> json) => Geofence(
        id: _str(json['id']),
        childId: _str(json['childId']),
        label: _str(json['label']),
        lat: (json['lat'] as num?)?.toDouble() ?? 0,
        lng: (json['lng'] as num?)?.toDouble() ?? 0,
        radiusM: (json['radiusM'] as num?)?.toDouble() ?? 100,
        notifyOnEnter: _bool(json['notifyOnEnter'], true),
        notifyOnExit: _bool(json['notifyOnExit'], true),
        routineId: _strOrNull(json['routineId']),
      );
}

/// A family invite (feature #13). `status` is pending/accepted/revoked;
/// `permissions` is a subset of rules/location/alerts/social.
@immutable
class FamilyInvite {
  final String id;
  final String email;
  final String role;
  final String status;
  final List<String> permissions;
  final DateTime? createdAt;

  const FamilyInvite({
    required this.id,
    required this.email,
    this.role = 'guardian',
    this.status = 'pending',
    this.permissions = const [],
    this.createdAt,
  });

  factory FamilyInvite.fromJson(Map<String, dynamic> json) => FamilyInvite(
        id: _str(json['id']),
        email: _str(json['email']),
        role: _str(json['role'], 'guardian'),
        status: _str(json['status'], 'pending'),
        permissions: _strList(json['permissions']),
        createdAt: DateTime.tryParse(_str(json['createdAt'])),
      );
}

/// A safety/security alert. `severity` is info/warning/critical;
/// `category` is one of the shared-types Alert categories.
@immutable
class Alert {
  final String id;
  final String childId;
  final String? deviceId;
  final String severity;
  final String category;
  final String title;
  final String body;
  final Map<String, dynamic> metadata;
  final DateTime? createdAt;
  final bool acknowledged;

  const Alert({
    required this.id,
    required this.childId,
    this.deviceId,
    required this.severity,
    required this.category,
    required this.title,
    required this.body,
    this.metadata = const {},
    this.createdAt,
    this.acknowledged = false,
  });

  factory Alert.fromJson(Map<String, dynamic> json) => Alert(
        id: _str(json['id']),
        childId: _str(json['childId']),
        deviceId: _strOrNull(json['deviceId']),
        severity: _str(json['severity'], 'info'),
        category: _str(json['category']),
        title: _str(json['title']),
        body: _str(json['body']),
        metadata: json['metadata'] is Map ? Map<String, dynamic>.from(json['metadata'] as Map) : const {},
        createdAt: DateTime.tryParse(_str(json['createdAt'])),
        acknowledged: _bool(json['acknowledged']),
      );
}

/// One page of alerts from `GET /v1/alerts`.
@immutable
class AlertsPage {
  final List<Alert> items;
  final int total;
  final int page;
  final int limit;

  const AlertsPage({required this.items, required this.total, this.page = 1, this.limit = 20});

  factory AlertsPage.fromJson(dynamic json) {
    if (json is List) {
      return AlertsPage(items: [for (final a in json) Alert.fromJson(Map<String, dynamic>.from(a as Map))], total: json.length);
    }
    final map = json is Map ? Map<String, dynamic>.from(json) : const <String, dynamic>{};
    final items = [for (final a in _mapList(map['items'])) Alert.fromJson(a)];
    final meta = map['meta'] is Map ? Map<String, dynamic>.from(map['meta'] as Map) : const <String, dynamic>{};
    return AlertsPage(
      items: items,
      total: _int(map['total'] ?? meta['total'], items.length),
      page: _int(map['page'] ?? meta['page'], 1),
      limit: _int(map['limit'] ?? meta['limit'], 20),
    );
  }
}

/// Verifiable parental consent record (COPPA/GDPR-K evidence).
@immutable
class ConsentRecord {
  final String id;
  final String childId;
  final String method;
  final String jurisdiction;
  final DateTime? grantedAt;
  final DateTime? expiresAt;
  final DateTime? revokedAt;
  final bool thirdPartySharing;

  const ConsentRecord({
    required this.id,
    required this.childId,
    required this.method,
    required this.jurisdiction,
    this.grantedAt,
    this.expiresAt,
    this.revokedAt,
    this.thirdPartySharing = false,
  });

  factory ConsentRecord.fromJson(Map<String, dynamic> json) => ConsentRecord(
        id: _str(json['id']),
        childId: _str(json['childId']),
        method: _str(json['method']),
        jurisdiction: _str(json['jurisdiction']),
        grantedAt: DateTime.tryParse(_str(json['grantedAt'])),
        expiresAt: DateTime.tryParse(_str(json['expiresAt'])),
        revokedAt: DateTime.tryParse(_str(json['revokedAt'])),
        thirdPartySharing: _bool(json['thirdPartySharing']),
      );
}

/// What the consent screen shows for one child. Derived from the server's
/// active/inactive answer plus the raw `records` history, so a withdrawn or
/// expired record is reported as such instead of as "no record".
enum ConsentState { active, expiring, expired, revoked, jurisdictionMismatch, none }

/// `GET /v1/family/children/:id/consent` (ADR-0008). `records` is newest
/// first and includes revoked/expired rows.
@immutable
class ConsentStatus {
  static const expiringWindow = Duration(days: 14);

  final bool active;
  final String? reason;
  final String jurisdiction;
  final ConsentRecord? consent;
  final List<ConsentRecord> records;

  const ConsentStatus({
    required this.active,
    this.reason,
    this.jurisdiction = '',
    this.consent,
    this.records = const [],
  });

  factory ConsentStatus.fromJson(Map<String, dynamic> json) {
    final consent = json['consent'] is Map
        ? ConsentRecord.fromJson(Map<String, dynamic>.from(json['consent'] as Map))
        : null;
    return ConsentStatus(
      active: _bool(json['active']),
      reason: _strOrNull(json['reason']),
      jurisdiction: _str(json['jurisdiction']),
      consent: consent,
      records: [for (final r in _mapList(json['records'])) ConsentRecord.fromJson(r)],
    );
  }

  /// The record the screen describes: the server's active one, else the
  /// newest row in the history.
  ConsentRecord? get current => consent ?? (records.isEmpty ? null : records.first);

  /// The state at [now]; kept as a function so expiry is testable.
  ConsentState stateAt(DateTime now) {
    final record = current;
    if (active) {
      final expiresAt = record?.expiresAt;
      if (expiresAt != null && !expiresAt.isBefore(now) && expiresAt.difference(now) <= expiringWindow) {
        return ConsentState.expiring;
      }
      return ConsentState.active;
    }
    if (record != null && record.revokedAt != null) return ConsentState.revoked;
    final expiresAt = record?.expiresAt;
    if (expiresAt != null && !expiresAt.isAfter(now)) return ConsentState.expired;
    if (reason == 'consent_jurisdiction_mismatch') return ConsentState.jurisdictionMismatch;
    return ConsentState.none;
  }

  ConsentState get state => stateAt(DateTime.now());
}

/// One entry of `ReportSummary.topApps` (feature #4).
@immutable
class TopApp {
  final String name;
  final int minutes;

  const TopApp({required this.name, required this.minutes});

  factory TopApp.fromJson(Map<String, dynamic> json) => TopApp(
        name: _str(json['name']),
        minutes: _int(json['minutes']),
      );
}

/// One entry of `ReportSummary.topBlockedDomains` (feature #4).
@immutable
class BlockedDomain {
  final String domain;
  final int count;

  const BlockedDomain({required this.domain, required this.count});

  factory BlockedDomain.fromJson(Map<String, dynamic> json) => BlockedDomain(
        domain: _str(json['domain']),
        count: _int(json['count']),
      );
}

/// `GET /v1/reports/summary` aggregate for one child and day range (#4).
@immutable
class ReportSummary {
  final int totalAppMinutes;
  final List<TopApp> topApps;
  final int urlVisits;
  final List<BlockedDomain> topBlockedDomains;
  final int socialConcerns;
  final int calls;
  final int sms;

  const ReportSummary({
    this.totalAppMinutes = 0,
    this.topApps = const [],
    this.urlVisits = 0,
    this.topBlockedDomains = const [],
    this.socialConcerns = 0,
    this.calls = 0,
    this.sms = 0,
  });

  factory ReportSummary.fromJson(Map<String, dynamic> json) => ReportSummary(
        totalAppMinutes: _int(json['totalAppMinutes']),
        topApps: [for (final m in _mapList(json['topApps'])) TopApp.fromJson(m)],
        urlVisits: _int(json['urlVisits']),
        topBlockedDomains: [for (final m in _mapList(json['topBlockedDomains'])) BlockedDomain.fromJson(m)],
        socialConcerns: _int(json['socialConcerns']),
        calls: _int(json['calls']),
        sms: _int(json['sms']),
      );

  /// True when there is nothing to chart or list for the selected range.
  bool get isEmpty =>
      totalAppMinutes == 0 && topApps.isEmpty && urlVisits == 0 && topBlockedDomains.isEmpty && socialConcerns == 0 && calls == 0 && sms == 0;
}

/// One app's minutes inside a [UsageDay] (`GET /v1/reports/usage`).
@immutable
class UsageApp {
  final String app;
  final int minutes;

  const UsageApp({required this.app, this.minutes = 0});

  factory UsageApp.fromJson(Map<String, dynamic> json) => UsageApp(
        app: _str(json['app']),
        minutes: _int(json['minutes']),
      );
}

/// One UTC calendar day of the durable usage rollup (`UsageDay` in
/// `services/api/src/lib/usageModel.ts`). `day` is `YYYY-MM-DD` and `minutes` is
/// the device-reported total when the device sent one, else the per-app sum.
@immutable
class UsageDay {
  final String day;
  final int minutes;
  final List<UsageApp> apps;

  const UsageDay({required this.day, this.minutes = 0, this.apps = const []});

  factory UsageDay.fromJson(Map<String, dynamic> json) => UsageDay(
        day: _str(json['day']),
        minutes: _int(json['minutes']),
        apps: [for (final m in _mapList(json['apps'])) UsageApp.fromJson(m)],
      );
}

/// `GET /v1/reports/usage?childId&days=` — oldest first, one entry per
/// requested day. The API already fills a day with no rows as 0 (see
/// `usageSeries`), so the UI never invents padding; if a shorter series ever
/// arrives, only what was returned is shown.
@immutable
class UsageReport {
  final String childId;
  final int days;
  final int totalMinutes;
  final List<UsageDay> series;

  const UsageReport({required this.childId, this.days = 0, this.totalMinutes = 0, this.series = const []});

  factory UsageReport.fromJson(Map<String, dynamic> json) {
    final series = [for (final m in _mapList(json['series'])) UsageDay.fromJson(m)];
    return UsageReport(
      childId: _str(json['childId']),
      days: _int(json['days'], series.length),
      totalMinutes: _int(json['totalMinutes'], series.fold<int>(0, (n, d) => n + d.minutes)),
      series: series,
    );
  }

  /// Sum of the days actually returned — what the chart, the total and the
  /// per-day list all agree on.
  int get seriesMinutes => series.fold<int>(0, (n, d) => n + d.minutes);
}

/// One `WebVisit` row from `GET /v1/reports/web` (newest first). `blocked` is
/// what the web filter decided at visit time; `ts` is the visit instant.
@immutable
class WebVisit {
  final String id;
  final String domain;
  final String url;
  final String category;
  final bool blocked;
  final DateTime? ts;

  const WebVisit({
    required this.id,
    this.domain = '',
    this.url = '',
    this.category = '',
    this.blocked = false,
    this.ts,
  });

  factory WebVisit.fromJson(Map<String, dynamic> json) => WebVisit(
        id: _str(json['id']),
        domain: _str(json['domain'], 'unknown'),
        url: _str(json['url']),
        category: _str(json['category']),
        blocked: _bool(json['blocked']),
        ts: DateTime.tryParse(_str(json['ts'] ?? json['createdAt'])),
      );
}

/// `GET /v1/reports/wellbeing/:childId` weekly score (feature #28). `breakdown` holds
/// the usage/social/safety sub-scores.
@immutable
class WellbeingScore {
  final String childId;
  final String week;
  final int score;
  final Map<String, int> breakdown;

  const WellbeingScore({required this.childId, this.week = '', this.score = 0, this.breakdown = const {}});

  factory WellbeingScore.fromJson(Map<String, dynamic> json) {
    final raw = json['breakdown'] is Map ? Map<String, dynamic>.from(json['breakdown'] as Map) : const <String, dynamic>{};
    return WellbeingScore(
      childId: _str(json['childId']),
      week: _str(json['week']),
      score: _int(json['score']),
      breakdown: {for (final e in raw.entries) e.key: _int(e.value)},
    );
  }
}

/// One digest recipient and whether it has proved the address (roadmap 2.7, osra-security#2).
/// A parent's own address is `confirmed` as it is; any other address is `pending` until the
/// single-use link in its email is used, and a pending address receives no digest. `unsent` means
/// the confirmation mail itself failed: nothing was delivered, and saving again retries.
@immutable
class DigestRecipientStatus {
  final String email;
  final String status;

  const DigestRecipientStatus({required this.email, this.status = 'pending'});

  bool get isConfirmed => status == 'confirmed';
  bool get isUnsent => status == 'unsent';

  /// Anything that is not confirmed: the address receives no digest either way.
  bool get isPending => !isConfirmed;

  factory DigestRecipientStatus.fromJson(Map<String, dynamic> json) => DigestRecipientStatus(
        email: _str(json['email']),
        status: _str(json['status'], 'pending'),
      );
}

/// `GET/PUT /v1/digests/prefs` notification preferences (feature #5).
@immutable
class DigestPrefs {
  final bool dailyEmail;
  final bool weeklyEmail;
  final bool pushEnabled;
  final List<String> emails;

  /// Per-address confirmation state; empty when the server did not send it.
  final List<DigestRecipientStatus> recipients;

  const DigestPrefs({
    this.dailyEmail = false,
    this.weeklyEmail = false,
    this.pushEnabled = true,
    this.emails = const [],
    this.recipients = const [],
  });

  factory DigestPrefs.fromJson(Map<String, dynamic> json) => DigestPrefs(
        dailyEmail: _bool(json['dailyEmail']),
        weeklyEmail: _bool(json['weeklyEmail']),
        pushEnabled: _bool(json['pushEnabled'], true),
        emails: _strList(json['emails']),
        recipients: [
          for (final r in (json['recipients'] is List ? json['recipients'] as List : const []))
            if (r is Map) DigestRecipientStatus.fromJson(Map<String, dynamic>.from(r)),
        ],
      );

  Map<String, dynamic> toJson() => {
        'dailyEmail': dailyEmail,
        'weeklyEmail': weeklyEmail,
        'pushEnabled': pushEnabled,
        'emails': emails,
      };
}

/// `GET /v1/insights/apps` curated insight (feature #12).
@immutable
class AppInsight {
  final String packageId;
  final String appName;
  final String ageRating;
  final List<String> risks;
  final List<String> alternatives;

  const AppInsight({this.packageId = '', this.appName = '', this.ageRating = '', this.risks = const [], this.alternatives = const []});

  factory AppInsight.fromJson(Map<String, dynamic> json) => AppInsight(
        packageId: _str(json['packageId']),
        appName: _str(json['appName']),
        ageRating: _str(json['ageRating']),
        risks: _strList(json['risks']),
        alternatives: _strList(json['alternatives']),
      );
}

/// One `live_activity` WS payload (feature #29): which app the child is in
/// right now and for how long today.
@immutable
class LiveActivity {
  final String childId;
  final String app;
  final int minutesToday;
  final DateTime? ts;

  const LiveActivity({required this.childId, this.app = '', this.minutesToday = 0, this.ts});

  factory LiveActivity.fromJson(Map<String, dynamic> json) => LiveActivity(
        childId: _str(json['childId']),
        app: _str(json['app']),
        minutesToday: _int(json['minutesToday']),
        ts: DateTime.tryParse(_str(json['ts'])),
      );

  /// Entries older than two minutes are treated as stale and hidden (#29).
  bool isFresh([DateTime? now]) {
    final at = ts;
    if (at == null) return false;
    final ref = now ?? DateTime.now();
    return ref.difference(at) < const Duration(minutes: 2);
  }
}

/// Ring color for a wellbeing score (#28): red under 50, amber under 75, green
/// at 75+.
Color wellbeingColor(int score) => score < 50 ? Colors.red : score < 75 ? Colors.amber : Colors.green;

/// Everything `GET /v1/family/me` returns for the signed-in parent.
@immutable
class FamilyOverview {
  final Family family;
  final Parent parent;
  final List<Child> children;
  final List<Device> devices;
  final List<Parent> parents;

  const FamilyOverview({
    required this.family,
    required this.parent,
    this.children = const [],
    this.devices = const [],
    this.parents = const [],
  });

  factory FamilyOverview.fromJson(Map<String, dynamic> json) {
    final familyJson = json['family'] is Map ? Map<String, dynamic>.from(json['family'] as Map) : <String, dynamic>{'id': '', 'name': '', 'region': 'US'};
    final parentJson = json['parent'] is Map ? Map<String, dynamic>.from(json['parent'] as Map) : <String, dynamic>{'id': '', 'email': ''};
    // NOTE: children/devices/parents may live at the root or nested under `family`.
    final childrenRaw = json['children'] ?? familyJson['children'];
    final devicesRaw = json['devices'] ?? familyJson['devices'];
    final parentsRaw = json['parents'] ?? familyJson['parents'];
    return FamilyOverview(
      family: Family.fromJson(familyJson),
      parent: Parent.fromJson(parentJson),
      children: [for (final c in _mapList(childrenRaw)) Child.fromJson(c)],
      devices: [for (final d in _mapList(devicesRaw)) Device.fromJson(d)],
      parents: [for (final p in _mapList(parentsRaw)) Parent.fromJson(p)],
    );
  }

  /// Devices belonging to one child.
  List<Device> devicesFor(String childId) => devices.where((d) => d.childId == childId).toList();
}

/// `POST /v1/auth/mfa/enroll` — a new TOTP secret and the `otpauth://` URL the
/// enrolment screen renders as a QR. The secret is not persisted by the app:
/// the server stores it (encrypted) on the next `/mfa/verify`.
@immutable
class MfaEnrollment {
  final String secret;
  final String otpauthUrl;

  const MfaEnrollment({required this.secret, required this.otpauthUrl});

  factory MfaEnrollment.fromJson(Map<String, dynamic> json) => MfaEnrollment(
        secret: _str(json['secret']),
        otpauthUrl: _str(json['otpauthUrl']),
      );
}

/// One batch of one-time recovery codes, as returned by `/mfa/verify` and
/// `/mfa/recovery-codes`. This is the only moment the plaintext exists — the
/// API stores hashes and has no route that returns a batch again.
@immutable
class RecoveryCodeBatch {
  final List<String> codes;
  final DateTime? issuedAt;

  const RecoveryCodeBatch({this.codes = const [], this.issuedAt});

  factory RecoveryCodeBatch.fromJson(Map<String, dynamic> json) => RecoveryCodeBatch(
        codes: _strList(json['recoveryCodes']),
        issuedAt: DateTime.tryParse(_str(json['recoveryCodesIssuedAt'])),
      );

  bool get isEmpty => codes.isEmpty;
}

/// `POST /v1/auth/mfa/reset/request` (ADR-0031 decision 2.1–2.2). The mailbox
/// link is the next step; [expiresAt] is its 30-minute deadline. [confirmToken]
/// is echoed only by a development server and is never used by the app.
@immutable
class MfaResetRequestResult {
  final String requestId;
  final DateTime? expiresAt;
  final String? confirmToken;

  const MfaResetRequestResult({required this.requestId, this.expiresAt, this.confirmToken});

  factory MfaResetRequestResult.fromJson(Map<String, dynamic> json) => MfaResetRequestResult(
        requestId: _str(json['requestId']),
        expiresAt: DateTime.tryParse(_str(json['expiresAt'])),
        confirmToken: _strOrNull(json['confirmToken']),
      );
}

/// `POST /v1/auth/mfa/reset/confirm` — the mailbox link was consumed and a
/// `show_reset_code` command went to every paired device. [witness] is
/// `device` (a code appeared on the children's phones) or `parent` (a second
/// owner/co-parent must approve); [codeExpiresAt] exists only for `device`.
@immutable
class MfaResetConfirmResult {
  final String requestId;
  final String witness;
  final DateTime? codeExpiresAt;

  const MfaResetConfirmResult({required this.requestId, required this.witness, this.codeExpiresAt});

  factory MfaResetConfirmResult.fromJson(Map<String, dynamic> json) => MfaResetConfirmResult(
        requestId: _str(json['requestId']),
        witness: _str(json['witness']),
        codeExpiresAt: DateTime.tryParse(_str(json['codeExpiresAt'])),
      );

  bool get usesDeviceCode => witness == 'device';
}

/// `POST /v1/auth/mfa/reset/witness` and `.../approve` — the witness step
/// passed and the 72-hour window opened. [state] is `witness_passed`.
@immutable
class MfaResetWitnessAccepted {
  final String state;
  final DateTime? windowEndsAt;

  const MfaResetWitnessAccepted({required this.state, this.windowEndsAt});

  factory MfaResetWitnessAccepted.fromJson(Map<String, dynamic> json) => MfaResetWitnessAccepted(
        state: _str(json['state']),
        windowEndsAt: DateTime.tryParse(_str(json['windowEndsAt'])),
      );
}

/// `POST /v1/auth/mfa/reset/cancel` — the request's state after the call.
/// Cancelling is idempotent, so [state] can also be a state the request was
/// already in (`completed`, `expired`, ...).
@immutable
class MfaResetCancelResult {
  final String state;

  const MfaResetCancelResult({required this.state});

  factory MfaResetCancelResult.fromJson(Map<String, dynamic> json) =>
      MfaResetCancelResult(state: _str(json['state']));
}

/// `POST /v1/auth/mfa/reset/complete` — the 15-minute `purpose:"mfa_recovery"`
/// token, the same one `/mfa/recover` issues. It is handed to the enrolment
/// screen and never written to the session slot.
@immutable
class MfaResetCompleteResult {
  final String recoveryToken;

  const MfaResetCompleteResult({required this.recoveryToken});

  factory MfaResetCompleteResult.fromJson(Map<String, dynamic> json) =>
      MfaResetCompleteResult(recoveryToken: _str(json['recoveryToken']));
}

/// `POST /v1/auth/mfa/reset/status` — the requester's own request, read-only.
///
/// A derived field that does not apply to [state] is `null` from the API, never
/// stale: [mailboxLinkExpiresAt] exists only while `requested`,
/// [codeExpiresAt] and [attemptsRemaining] only while `mailbox_confirmed`, and
/// [windowEndsAt] only once the witness step passed. [outcomeAt] is set when
/// the request reached a terminal state.
@immutable
class MfaResetStatusView {
  final String requestId;
  final String state;
  final DateTime? createdAt;
  final DateTime? emailConfirmedAt;
  final DateTime? mailboxLinkExpiresAt;
  final DateTime? witnessDeadline;
  final DateTime? codeExpiresAt;
  final int? attemptsRemaining;
  final String? witnessKind;
  final DateTime? witnessAt;
  final DateTime? windowEndsAt;
  final DateTime? outcomeAt;

  const MfaResetStatusView({
    required this.requestId,
    required this.state,
    this.createdAt,
    this.emailConfirmedAt,
    this.mailboxLinkExpiresAt,
    this.witnessDeadline,
    this.codeExpiresAt,
    this.attemptsRemaining,
    this.witnessKind,
    this.witnessAt,
    this.windowEndsAt,
    this.outcomeAt,
  });

  factory MfaResetStatusView.fromJson(Map<String, dynamic> json) => MfaResetStatusView(
        requestId: _str(json['requestId']),
        state: _str(json['state']),
        createdAt: DateTime.tryParse(_str(json['createdAt'])),
        emailConfirmedAt: DateTime.tryParse(_str(json['emailConfirmedAt'])),
        mailboxLinkExpiresAt: DateTime.tryParse(_str(json['mailboxLinkExpiresAt'])),
        witnessDeadline: DateTime.tryParse(_str(json['witnessDeadline'])),
        codeExpiresAt: DateTime.tryParse(_str(json['codeExpiresAt'])),
        attemptsRemaining: _intOrNull(json['attemptsRemaining']),
        witnessKind: _strOrNull(json['witnessKind']),
        witnessAt: DateTime.tryParse(_str(json['witnessAt'])),
        windowEndsAt: DateTime.tryParse(_str(json['windowEndsAt'])),
        outcomeAt: DateTime.tryParse(_str(json['outcomeAt'])),
      );
}

/// One entry of `GET /v1/auth/mfa/reset/pending` — another owner's or
/// co-parent's request that needs a witness.
///
/// [requesterName] and [requesterRole] are what the approval prompt names; the
/// address and `witnessRef` are deliberately absent from the route.
@immutable
class MfaResetPendingRequest {
  final String requestId;
  final String state;
  final String requesterParentId;
  final String requesterName;
  final String requesterRole;
  final DateTime? createdAt;
  final DateTime? emailConfirmedAt;
  final DateTime? witnessDeadline;
  final DateTime? windowEndsAt;

  const MfaResetPendingRequest({
    required this.requestId,
    required this.state,
    this.requesterParentId = '',
    this.requesterName = '',
    this.requesterRole = '',
    this.createdAt,
    this.emailConfirmedAt,
    this.witnessDeadline,
    this.windowEndsAt,
  });

  factory MfaResetPendingRequest.fromJson(Map<String, dynamic> json) {
    final requester = json['requester'] is Map ? Map<String, dynamic>.from(json['requester'] as Map) : const <String, dynamic>{};
    return MfaResetPendingRequest(
      requestId: _str(json['requestId']),
      state: _str(json['state']),
      requesterParentId: _str(requester['parentId']),
      requesterName: _str(requester['displayName']),
      requesterRole: _str(requester['role']),
      createdAt: DateTime.tryParse(_str(json['createdAt'])),
      emailConfirmedAt: DateTime.tryParse(_str(json['emailConfirmedAt'])),
      witnessDeadline: DateTime.tryParse(_str(json['witnessDeadline'])),
      windowEndsAt: DateTime.tryParse(_str(json['windowEndsAt'])),
    );
  }
}
