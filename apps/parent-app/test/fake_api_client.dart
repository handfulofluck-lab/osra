import 'package:dio/dio.dart';

import 'package:familyshield_parent/api/client.dart';

/// One HTTP request recorded by [FakeApiClient].
class RecordedRequest {
  final String method;
  final String path;
  final dynamic data;
  final Map<String, dynamic> query;
  final Map<String, dynamic> headers;

  RecordedRequest({
    required this.method,
    required this.path,
    this.data,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  })  : query = query ?? const {},
        headers = headers ?? const {};

  /// Request body as a map (empty map for non-map bodies).
  Map<String, dynamic> get body => data is Map ? Map<String, dynamic>.from(data as Map) : const {};
}

/// Non-2xx canned response a route can return.
class FakeHttpError {
  final int status;
  final Object? body;
  const FakeHttpError(this.status, [this.body = const {'error': 'boom'}]);
}

/// A transport failure (no response), for the "cannot reach the server" paths.
class FakeNetworkError {
  const FakeNetworkError();
}

/// Handler for one fake route; return the JSON body or a [FakeHttpError].
typedef FakeRoute = Object? Function(RecordedRequest request);

/// Network-free [ApiClient]: the Dio interceptor short-circuits every request
/// against a route table keyed `'METHOD /path'` and records it in [requests].
class FakeApiClient extends ApiClient {
  FakeApiClient(Map<String, FakeRoute> routes) : _routes = Map.of(routes);

  final Map<String, FakeRoute> _routes;
  final List<RecordedRequest> requests = [];

  late final Dio _dio = _buildDio();

  Dio _buildDio() {
    final dio = Dio(BaseOptions(baseUrl: 'http://testserver'));
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      final record = RecordedRequest(
        method: options.method,
        path: options.path,
        data: options.data,
        query: Map<String, dynamic>.from(options.queryParameters),
        headers: Map<String, dynamic>.from(options.headers),
      );
      requests.add(record);
      final route = _routes['${options.method} ${options.path}'];
      if (route == null) {
        handler.reject(DioException(
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: 404, data: {'error': 'no_fake_route'}),
          type: DioExceptionType.badResponse,
        ));
        return;
      }
      final result = route(record);
      if (result is FakeHttpError) {
        handler.reject(DioException(
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: result.status, data: result.body),
          type: DioExceptionType.badResponse,
        ));
      } else if (result is FakeNetworkError) {
        handler.reject(DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          error: 'connection refused',
          message: 'The connection errored: Connection refused',
        ));
      } else {
        handler.resolve(Response(requestOptions: options, data: result));
      }
    }));
    return dio;
  }

  @override
  Dio get raw => _dio;

  /// Recorded requests matching [method] + [path], in call order.
  List<RecordedRequest> calls(String method, String path) =>
      [for (final r in requests) if (r.method == method && r.path == path) r];
}

/// Canned GET /v1/family/me with two children: Alex's device is online at 55%
/// battery (lastSeen now); Sam's device is at 0% with a stale lastSeen (2h).
Map<String, dynamic> familyMeTwoChildren({
  String alexName = 'Alex',
  String alexModel = 'Pixel 7a',
}) {
  final now = DateTime.now().toUtc();
  return {
    'family': {'id': 'fam-1', 'name': 'QA Family', 'region': 'US', 'createdAt': now.toIso8601String()},
    'parent': {
      'id': 'par-1',
      'familyId': 'fam-1',
      'email': 'qa@familyshield.dev',
      'displayName': 'QA Parent',
      'role': 'owner',
      'mfaEnabled': false,
    },
    'children': [
      {'id': 'child-1', 'familyId': 'fam-1', 'displayName': alexName, 'birthYear': 2013, 'screenTimeTodayMinutes': 45},
      {'id': 'child-2', 'familyId': 'fam-1', 'displayName': 'Sam', 'birthYear': 2016, 'screenTimeTodayMinutes': 10},
    ],
    'devices': [
      {
        'id': 'dev-1',
        'childId': 'child-1',
        'platform': 'android',
        'model': alexModel,
        'osVersion': '14',
        'status': 'online',
        'batteryPct': 55,
        'lastSeen': now.toIso8601String(),
      },
      {
        'id': 'dev-2',
        'childId': 'child-2',
        'platform': 'android',
        'model': 'Galaxy A14',
        'osVersion': '13',
        'status': 'online',
        'batteryPct': 0,
        'lastSeen': now.subtract(const Duration(hours: 2)).toIso8601String(),
      },
    ],
  };
}

/// Canned GET /v1/rules/:childId (daily limit 120, SafeSearch on, one app rule).
/// [blockedCategories] overrides the web-filter categories (default is the
/// partial single-category fixture); [socialMonitoring] and [contactAllowlist]
/// feed the Feature #2 sections (both default to absent/empty).
Map<String, dynamic> ruleSetPayload(
  String childId, {
  List<String>? blockedCategories,
  Map<String, bool>? socialMonitoring,
  List<String>? contactAllowlist,
  List<String>? alwaysAllowedApps,
  Map<String, dynamic>? webFilter,
}) => {
      'id': 'rules-$childId',
      'childId': childId,
      'screenTime': {
        'dailyLimitMinutes': 120,
        'weekendLimitMinutes': 240,
        'bedtimeStart': '21:00',
        'bedtimeEnd': '07:00',
        'schoolHours': {
          'start': '08:00',
          'end': '15:00',
          'days': [1, 2, 3, 4, 5],
        },
      },
      'webFilter': webFilter ?? {
        'blockedCategories': blockedCategories ?? ['pornography'],
        'allowedDomains': ['khanacademy.org'],
        'blockedDomains': <String>[],
        'safeSearchEnforced': true,
        'youtubeRestrictedMode': 'strict',
      },
      'appRules': [
        {'packageId': 'com.example.game', 'appName': 'Game', 'action': 'time_limit', 'dailyLimitMinutes': 60},
      ],
      'routines': [
        {
          'id': 'r1',
          'name': 'Homework',
          'startTime': '17:00',
          'endTime': '19:00',
          'days': [1, 2, 3],
          'blockedApps': ['com.example.game'],
          'allowedApps': <String>[],
        },
      ],
      if (socialMonitoring != null) 'socialMonitoring': socialMonitoring,
      if (contactAllowlist != null) 'contactAllowlist': contactAllowlist,
      if (alwaysAllowedApps != null) 'alwaysAllowedApps': alwaysAllowedApps,
    };

/// One alert JSON object.
Map<String, dynamic> alertJson(String id, String severity, String category, String title, DateTime at) => {
      'id': id,
      'childId': 'child-1',
      'deviceId': 'dev-1',
      'severity': severity,
      'category': category,
      'title': title,
      'body': '$title body',
      'metadata': <String, dynamic>{},
      'createdAt': at.toUtc().toIso8601String(),
      'acknowledged': false,
    };

/// One durable device command JSON object (`GET /v1/devices/:id/commands/history`).
/// [status] is pending / delivered / acked / failed / expired.
Map<String, dynamic> commandJson(
  String id,
  String type,
  String status,
  DateTime createdAt, {
  String deviceId = 'dev-1',
  DateTime? deliveredAt,
  DateTime? ackedAt,
  int attempts = 1,
}) =>
    {
      'id': id,
      'deviceId': deviceId,
      'type': type,
      'payload': <String, dynamic>{},
      'status': status,
      'requestedBy': 'par-1',
      'attempts': attempts,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'expiresAt': createdAt.add(const Duration(hours: 1)).toUtc().toIso8601String(),
      if (deliveredAt != null) 'deliveredAt': deliveredAt.toUtc().toIso8601String(),
      if (ackedAt != null) 'ackedAt': ackedAt.toUtc().toIso8601String(),
    };

/// Default alert feed: one critical + one warning today, one info yesterday.
/// Deltas chosen so the day split survives midnight runs (time-bomb fix).
List<Map<String, dynamic>> defaultAlerts() {
  final now = DateTime.now();
  return [
    alertJson('a3', 'critical', 'sos', 'SOS pressed', now.subtract(const Duration(minutes: 30))),
    alertJson('a2', 'warning', 'web_filter', 'Blocked site visited', now.subtract(const Duration(minutes: 10))),
    alertJson('a1', 'info', 'screen_time', 'Daily limit reached', now.subtract(const Duration(days: 1, hours: 2))),
  ];
}

/// Full route table for the two-child fixture. Covers auth, family, rules,
/// location, alerts (feed + ack=false count + acks), device commands, pairing
/// and child creation. Login succeeds with password 'good-password'.
Map<String, FakeRoute> standardRoutes({
  Map<String, dynamic>? familyMe,
  List<Map<String, dynamic>>? alerts,
  int unacked = 3,
  List<String>? blockedCategories,
}) {
  final alertItems = alerts ?? defaultAlerts();
  return {
    'POST /v1/auth/login': (req) => req.body['password'] == 'good-password'
        ? {'token': 'jwt-token'}
        : const FakeHttpError(401, {'error': 'invalid_credentials'}),
    'POST /v1/auth/register': (_) => {'token': 'jwt-token'},
    'GET /v1/family/me': (_) => familyMe ?? familyMeTwoChildren(),
    'POST /v1/family/children': (req) => {'child': req.body, 'id': 'child-new'},
    'GET /v1/rules/child-1': (_) => ruleSetPayload('child-1', blockedCategories: blockedCategories),
    'GET /v1/rules/child-2': (_) => ruleSetPayload('child-2', blockedCategories: blockedCategories),
    'PUT /v1/rules/child-1': (_) => {'ok': true},
    'PUT /v1/rules/child-2': (_) => {'ok': true},
    'GET /v1/location/child-1/latest': (_) => {'latest': null},
    'GET /v1/location/child-2/latest': (_) => {'latest': null},
    'GET /v1/alerts': (req) => req.query['ack'] == 'false'
        ? {
            'items': <dynamic>[],
            'meta': {'total': unacked, 'page': 1, 'limit': 1},
          }
        : {'items': alertItems, 'total': alertItems.length, 'page': 1, 'limit': 20},
    'POST /v1/alerts/a1/ack': (_) => {'ok': true},
    'POST /v1/alerts/a2/ack': (_) => {'ok': true},
    'POST /v1/alerts/a3/ack': (_) => {'ok': true},
    'POST /v1/devices/dev-1/command': (_) => {'ok': true},
    'POST /v1/devices/dev-2/command': (_) => {'ok': true},
    // Plan 3.6: device cards read the durable queue; default to no commands.
    'GET /v1/devices/dev-1/commands/history': (_) => {'items': <dynamic>[]},
    'GET /v1/devices/dev-2/commands/history': (_) => {'items': <dynamic>[]},
    'POST /v1/devices/pair': (_) => {
          'code': '482916',
          'expiresAt': DateTime.now().toUtc().add(const Duration(minutes: 10)).toIso8601String(),
        },
    // Feature #2/#24 + #6: default to empty feeds so the child-detail Social
    // tab renders its empty states instead of error text.
    'GET /v1/social/events': (_) => {
          'items': <dynamic>[],
          'meta': {'total': 0},
        },
    'GET /v1/reports/activity': (_) => {
          'items': <dynamic>[],
          'meta': {'total': 0},
        },
  };
}
