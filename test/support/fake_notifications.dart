import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:child_assist/core/notifications/notification_service.dart';

/// The /api/notifications endpoints (and /api/location/tracking-status) of the fake server. Like
/// the real one, everything is keyed by the user from the bearer token, never from the request.
class FakeNotificationsBackend {
  /// userId -> notifications (JSON as the server returns them), newest first.
  final Map<String, List<Map<String, dynamic>>> notifications = {};

  /// FCM token -> registration ({'id', 'userId', 'platform', 'appVersion'}).
  final Map<String, Map<String, dynamic>> devices = {};

  /// Every devices call, e.g. "register fcm-1 (u1)" or "unregister dev1 (u1)".
  final List<String> deviceCalls = [];

  /// Every body POSTed to /api/notifications/devices.
  final List<Map<String, dynamic>> deviceBodies = [];

  /// userId -> preferences as stored (missing keys mean on).
  final Map<String, Map<String, bool>> preferences = {};

  /// Every tracking state reported, e.g. "STARTED (u1)".
  final List<String> trackingReports = [];

  /// Every "mark read" call, e.g. "n1 (u1)".
  final List<String> readCalls = [];

  /// When set, every /api/notifications call fails with this status.
  int? failureStatus;

  int _nextId = 1;
  int _nextDevice = 1;
  DateTime clock = DateTime.now().toUtc();

  /// Adds a notification for [userId] as if the server had sent it; returns its id.
  String seed(
    String userId, {
    String type = 'GENERAL',
    String title = 'Child Assist test notification',
    String body = 'Notifications are working on this device.',
    String deepLink = 'childassist://notifications',
    DateTime? createdAt,
    bool read = false,
  }) {
    final id = 'n${_nextId++}';
    final at = (createdAt ?? clock).toUtc();
    (notifications[userId] ??= []).insert(0, {
      'id': id,
      'type': type,
      'title': title,
      'body': body,
      'deepLink': deepLink,
      'read': read,
      'readAt': read ? at.toIso8601String() : null,
      'createdAt': at.toIso8601String(),
    });
    notifications[userId]!.sort((a, b) => (b['createdAt'] as String).compareTo(a['createdAt'] as String));
    return id;
  }

  int unread(String userId) => (notifications[userId] ?? []).where((n) => n['readAt'] == null).length;

  /// The user each FCM token is registered to.
  String? ownerOf(String fcmToken) => devices[fcmToken]?['userId'] as String?;

  http.Response tracking(http.Request req, String userId) {
    final state = (jsonDecode(req.body) as Map<String, dynamic>)['state'];
    if (state is! String || !const ['STARTED', 'STOPPED', 'PAUSED'].contains(state)) {
      return _json(400, {'message': 'Validation failed'});
    }
    trackingReports.add('$state ($userId)');
    return _json(200, {'notified': true});
  }

  http.Response handle(http.Request req, String userId) {
    if (failureStatus != null) return _json(failureStatus!, {'message': 'Service unavailable'});
    final path = req.url.path;
    final mine = notifications[userId] ??= [];
    // Like the real server: a userId (or anything unexpected) in the query is refused.
    if (req.url.queryParameters.keys.any((k) => !const {'limit', 'before', 'unread'}.contains(k))) {
      return _json(400, {'message': 'Validation failed'});
    }

    if (path == '/api/notifications/devices' && req.method == 'POST') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      deviceBodies.add(body);
      if (body.containsKey('userId') || body['token'] is! String || !const ['ANDROID', 'IOS'].contains(body['platform'])) {
        return _json(400, {'message': 'Validation failed'});
      }
      final token = body['token'] as String;
      deviceCalls.add('register $token ($userId)');
      final existing = devices[token];
      final device = existing ?? {'id': 'dev${_nextDevice++}'};
      device
        ..['userId'] = userId
        ..['platform'] = body['platform']
        ..['appVersion'] = body['appVersion'];
      devices[token] = device;
      return _json(200, {
        'device': {'id': device['id'], 'platform': device['platform'], 'appVersion': device['appVersion'], 'enabled': true},
      });
    }
    if (path.startsWith('/api/notifications/devices/') && req.method == 'DELETE') {
      final id = path.substring('/api/notifications/devices/'.length);
      deviceCalls.add('unregister $id ($userId)');
      final match = devices.entries.where((e) => e.value['id'] == id && e.value['userId'] == userId).firstOrNull;
      if (match == null) return _json(404, {'message': 'Device not found'});
      devices.remove(match.key);
      return _json(200, {'deleted': 1});
    }
    if (path == '/api/notifications' && req.method == 'GET') {
      final limit = int.tryParse(req.url.queryParameters['limit'] ?? '') ?? 30;
      final before = req.url.queryParameters['before'];
      var start = 0;
      if (before != null) {
        final i = mine.indexWhere((n) => n['id'] == before);
        if (i < 0) return _json(400, {'message': 'Invalid cursor'});
        start = i + 1;
      }
      final page = mine.skip(start).take(limit).toList();
      return _json(200, {
        'notifications': page,
        'hasMore': mine.length > start + page.length,
        'unreadCount': unread(userId),
      });
    }
    if (path == '/api/notifications/unread-count' && req.method == 'GET') {
      return _json(200, {'unreadCount': unread(userId)});
    }
    if (path == '/api/notifications/read-all' && req.method == 'PATCH') {
      var updated = 0;
      for (final n in mine) {
        if (n['readAt'] == null) {
          n['readAt'] = clock.toIso8601String();
          n['read'] = true;
          updated++;
        }
      }
      return _json(200, {'updated': updated});
    }
    if (path == '/api/notifications/preferences') {
      final stored = preferences[userId] ??= {};
      if (req.method == 'PATCH') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        if (body.containsKey('userId') || body.isEmpty) return _json(400, {'message': 'Validation failed'});
        if (body['securityEnabled'] == false) {
          return _json(400, {'message': "Security alerts can't be turned off.", 'code': 'MANDATORY_CATEGORY'});
        }
        body.forEach((k, v) => stored[k] = v as bool);
      }
      return _json(200, {
        'preferences': {
          for (final c in NotificationCategory.values) c.preferenceKey: c.mandatory || (stored[c.preferenceKey] ?? true),
          'mandatory': ['SECURITY'],
        },
      });
    }
    final read = RegExp(r'^/api/notifications/([^/]+)/read$').firstMatch(path);
    if (read != null && req.method == 'PATCH') {
      final id = read.group(1)!;
      readCalls.add('$id ($userId)');
      final n = mine.where((n) => n['id'] == id).firstOrNull;
      if (n == null) return _json(404, {'message': 'Notification not found'});
      n['readAt'] ??= clock.toIso8601String();
      n['read'] = true;
      return _json(200, {'notification': n});
    }
    return _json(404, {'message': 'Not found'});
  }

  static http.Response _json(int status, Object body) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
}

/// Stands in for Firebase Messaging and the notification shade.
class FakePushPlatform implements PushPlatform {
  FakePushPlatform({this.isSupported = true});

  @override
  final bool isSupported;

  bool initialized = false;
  int _tokenNumber = 1;
  String? _token;

  /// What getToken returns; deleteToken makes the next call return a new one.
  String? get currentToken => _token;

  /// Notifications shown in the shade by the app (pushes that arrived while it was open).
  final List<PushMessage> shown = [];
  int cancelAllCalls = 0;
  int deleteTokenCalls = 0;

  /// The notification whose tap "launched" the app.
  PushMessage? launchMessage;

  final _foreground = StreamController<PushMessage>.broadcast();
  final _opened = StreamController<PushMessage>.broadcast();
  final _tokenRefresh = StreamController<String>.broadcast();

  @override
  Future<void> initialize() async => initialized = true;

  /// The next this many getToken calls return null (token not ready yet).
  int nullTokens = 0;

  /// The next this many getToken calls throw, like FirebaseMessaging when registration fails.
  int tokenFailures = 0;

  /// While set and not completed, deleteToken waits for it.
  Completer<void>? deleteGate;

  /// getToken calls made while a deleteToken was still running (must stay 0).
  int tokenReadsDuringDelete = 0;
  bool _deleting = false;
  int getTokenCalls = 0;

  @override
  Future<String?> getToken() async {
    getTokenCalls++;
    if (_deleting) tokenReadsDuringDelete++;
    if (tokenFailures > 0) {
      tokenFailures--;
      throw Exception('[firebase_messaging/unknown] FCM Registration failed!');
    }
    if (nullTokens > 0) {
      nullTokens--;
      return null;
    }
    return _token ??= 'fcm-token-${_tokenNumber++}-AAAAAAAAAAAAAAAAAAAA';
  }

  @override
  Future<void> deleteToken() async {
    deleteTokenCalls++;
    _deleting = true;
    await deleteGate?.future;
    _token = null;
    _deleting = false;
  }

  @override
  Stream<String> get onTokenRefresh => _tokenRefresh.stream;

  @override
  Stream<PushMessage> get onForegroundMessage => _foreground.stream;

  @override
  Stream<PushMessage> get onOpened => _opened.stream;

  @override
  Future<PushMessage?> takeLaunchMessage() async {
    final m = launchMessage;
    launchMessage = null;
    return m;
  }

  @override
  Future<void> show(PushMessage message) async => shown.add(message);

  @override
  Future<void> cancelAll() async {
    cancelAllCalls++;
    shown.clear();
  }

  /// FCM delivers a push while the app is open.
  void deliver(PushMessage message) => _foreground.add(message);

  /// The user taps a notification while the app is running (open or in the background).
  void tap(PushMessage message) => _opened.add(message);

  /// FCM rotates this phone's token.
  void rotateToken() {
    _token = 'fcm-token-${_tokenNumber++}-BBBBBBBBBBBBBBBBBBBB';
    _tokenRefresh.add(_token!);
  }
}

/// A push as the server sends it for the history entry [id].
PushMessage pushFor(String id, {String type = 'GENERAL', String category = 'SYSTEM', String deepLink = 'childassist://notifications', String title = 'Child Assist test notification', String body = 'Notifications are working on this device.'}) =>
    PushMessage.fromData({'notificationId': id, 'type': type, 'category': category, 'deepLink': deepLink}, title: title, body: body);
