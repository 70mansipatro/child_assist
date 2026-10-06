import 'dart:async';
import 'dart:convert';

import 'package:geocoding/geocoding.dart' show Placemark;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:child_assist/app_services.dart';
import 'package:child_assist/core/api/api_client.dart';
import 'package:child_assist/core/permissions/permission_service.dart';
import 'package:child_assist/features/auth/data/token_storage.dart';
import 'package:child_assist/features/location/services/location_service.dart';

const testPassword = 'password123';

/// In-memory backend with the auth, profile, permission and location endpoints. Like the real
/// server, it identifies the user only from the bearer token and keeps data per user.
class FakeBackend {
  /// u1 and u2 have already been through the permission walkthrough; accounts created with
  /// POST /api/auth/register (or [addUser]) have not.
  final Map<String, Map<String, dynamic>> users = {
    'u1': {
      'id': 'u1',
      'name': 'Mansi',
      'email': 'mansi@example.com',
      'profileImageUrl': null,
      'permissionOnboardingCompleted': true,
    },
    'u2': {
      'id': 'u2',
      'name': 'Ravi',
      'email': 'ravi@example.com',
      'profileImageUrl': null,
      'permissionOnboardingCompleted': true,
    },
  };
  int _nextUserId = 3;

  /// When > 0, that many of the next GET /api/profile calls fail with 503.
  int profileFailures = 0;

  /// When > 0, that many of the next PATCH /api/permissions/:permission calls fail with 503.
  int permissionFailures = 0;

  /// When > 0, that many of the next PATCH /api/profile/permission-onboarding calls fail with 503.
  int onboardingFailures = 0;

  /// Adds an account (as if it existed before onboarding was introduced) and returns its ID.
  String addUser(String name, String email, {bool onboardingCompleted = false}) {
    final id = 'u${_nextUserId++}';
    users[id] = {
      'id': id,
      'name': name,
      'email': email,
      'profileImageUrl': null,
      'permissionOnboardingCompleted': onboardingCompleted,
    };
    return id;
  }

  /// userId -> permission -> status, as stored by PATCH /api/permissions/:permission.
  final Map<String, Map<String, String>> permissions = {};

  /// Every PATCH received, e.g. "PATCH /api/permissions/LOCATION GRANTED (u1)".
  final List<String> patches = [];

  /// userId -> saved locations (JSON as the server returns them), oldest first.
  final Map<String, List<Map<String, dynamic>>> locations = {};
  int _nextLocationId = 1;

  /// When set, every /api/location call fails with this status.
  int? locationFailureStatus;

  static const placeKeys = [
    'placeName', 'address', 'street', 'locality', 'city', 'state', 'postalCode', 'country', //
  ];

  static const supportedPermissions = [
    'LOCATION', 'MICROPHONE', 'CAMERA', 'PHOTOS', 'NOTIFICATIONS', 'DOCUMENTS', //
  ];
  static const supportedStatuses = ['UNKNOWN', 'GRANTED', 'DENIED', 'RESTRICTED', 'LIMITED'];

  static String tokenFor(String userId) => 'tok-$userId';

  late final MockClient client = MockClient(_handle);

  AppServices services(
    PermissionService permissionService, {
    LocationProvider? locationProvider,
    PlaceLookup? placeLookup,
  }) =>
      AppServices.create(
        apiClient: ApiClient(baseUrl: 'http://test', httpClient: client),
        tokenStorage: TokenStorage(),
        permissionService: permissionService,
        locationProvider: locationProvider ?? FakeLocationProvider(),
        placeLookup: placeLookup ?? FakePlaceLookup(),
      );

  Future<http.Response> _handle(http.Request req) async {
    final path = req.url.path;

    if (path == '/api/auth/login') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final user = users.values.where((u) => u['email'] == body['email']).firstOrNull;
      if (user == null || body['password'] != testPassword) {
        return _json(401, {'message': 'Invalid email or password'});
      }
      return _json(200, {'message': 'Login successful', 'user': _authUser(user), 'token': tokenFor(user['id'])});
    }

    if (path == '/api/auth/register') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      if (users.values.any((u) => u['email'] == body['email'])) {
        return _json(409, {'message': 'Email already registered'});
      }
      final id = addUser(body['name'] as String, body['email'] as String);
      return _json(201, {'message': 'Registered', 'user': _authUser(users[id]!), 'token': tokenFor(id)});
    }

    final userId = _userFromToken(req.headers['Authorization']);
    if (userId == null) return _json(401, {'message': 'Invalid or expired token'});
    final user = users[userId]!;

    if (path == '/api/auth/me') return _json(200, {'user': _authUser(user)});
    if (path == '/api/auth/logout') return _json(200, {'message': 'Logout successful'});

    if (path == '/api/profile' && req.method == 'GET') {
      if (profileFailures > 0) {
        profileFailures--;
        return _json(503, {'message': 'Service unavailable'});
      }
      return _json(200, {'user': user});
    }
    if (path == '/api/profile/permission-onboarding' && req.method == 'PATCH') {
      if (onboardingFailures > 0) {
        onboardingFailures--;
        return _json(503, {'message': 'Service unavailable'});
      }
      final body = jsonDecode(req.body);
      if (body is! Map || body.length != 1 || body['completed'] is! bool) {
        return _json(400, {'message': 'Validation failed'});
      }
      patches.add('PATCH /api/profile/permission-onboarding ${body['completed']} ($userId)');
      user['permissionOnboardingCompleted'] = body['completed'];
      return _json(200, {'user': user});
    }
    if (path == '/api/profile' && req.method == 'PATCH') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final name = (body['name'] as String?)?.trim() ?? '';
      if (name.isEmpty || name.length > 100) {
        return _json(400, {
          'message': 'Validation failed',
          'errors': [
            {'field': 'name', 'message': 'Name cannot be empty'},
          ],
        });
      }
      patches.add('PATCH /api/profile $name ($userId)');
      user['name'] = name;
      return _json(200, {'user': user});
    }

    if (path == '/api/permissions' && req.method == 'GET') {
      final stored = permissions[userId] ?? {};
      return _json(200, {
        'permissions': [
          for (final p in supportedPermissions) {'permission': p, 'status': stored[p] ?? 'UNKNOWN'},
        ],
      });
    }
    if (path.startsWith('/api/permissions/') && req.method == 'PATCH') {
      if (permissionFailures > 0) {
        permissionFailures--;
        return _json(503, {'message': 'Service unavailable'});
      }
      final permission = path.substring('/api/permissions/'.length);
      final status = (jsonDecode(req.body) as Map<String, dynamic>)['status'];
      if (!supportedPermissions.contains(permission) || !supportedStatuses.contains(status)) {
        return _json(400, {'message': 'Validation failed'});
      }
      patches.add('PATCH /api/permissions/$permission $status ($userId)');
      (permissions[userId] ??= {})[permission] = status as String;
      return _json(200, {'permission': permission, 'status': status});
    }

    if (path.startsWith('/api/location')) return _handleLocation(req, userId);

    return _json(404, {'message': 'Not found'});
  }

  http.Response _handleLocation(http.Request req, String userId) {
    if (locationFailureStatus != null) {
      return _json(locationFailureStatus!, {'message': 'Internal server error'});
    }
    final mine = locations[userId] ??= [];
    final path = req.url.path;

    if (path == '/api/location' && req.method == 'POST') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final lat = body['latitude'], lng = body['longitude'];
      if (lat is! num || lat.abs() > 90) return _json(400, {'message': 'Validation failed'});
      if (lng is! num || lng.abs() > 180) return _json(400, {'message': 'Validation failed'});
      final record = {
        'id': 'loc${_nextLocationId++}',
        'latitude': lat,
        'longitude': lng,
        'accuracy': body['accuracy'],
        for (final key in placeKeys) key: body[key],
        'capturedAt': body['capturedAt'],
      };
      mine.add(record);
      return _json(201, {'location': record});
    }
    if (path == '/api/location/history' && req.method == 'GET') {
      final limit = int.tryParse(req.url.queryParameters['limit'] ?? '50') ?? 50;
      return _json(200, {'locations': mine.reversed.take(limit).toList()});
    }
    if (path == '/api/location/history' && req.method == 'DELETE') {
      final deleted = mine.length;
      mine.clear();
      return _json(200, {'deleted': deleted});
    }
    return _json(404, {'message': 'Not found'});
  }

  String? _userFromToken(String? header) {
    final token = header?.replaceFirst('Bearer ', '');
    for (final id in users.keys) {
      if (token == tokenFor(id)) return id;
    }
    return null;
  }

  static Map<String, dynamic> _authUser(Map<String, dynamic> u) =>
      {'id': u['id'], 'name': u['name'], 'email': u['email']};

  static http.Response _json(int status, Object body) => http.Response(jsonEncode(body), status,
      headers: {'content-type': 'application/json'});
}

/// Stands in for the OS: [os] is the current state, [onRequest] is what the user picks
/// in the system dialog. Records every dialog that would have been shown.
class FakePermissionService extends PermissionService {
  FakePermissionService() : super(isWeb: false, platform: TargetPlatform.android);

  final Map<AppPermission, PermissionState> os = {
    for (final p in AppPermission.values) p: PermissionState.denied,
  };
  final Map<AppPermission, PermissionState> onRequest = {};
  final List<AppPermission> dialogsShown = [];

  /// Every status check and request, in order, e.g. "status location", "request camera".
  final List<String> calls = [];
  int settingsOpened = 0;

  @override
  Future<PermissionState> status(AppPermission permission) async {
    calls.add('status ${permission.name}');
    return os[permission]!;
  }

  @override
  Future<PermissionState> request(AppPermission permission) async {
    calls.add('request ${permission.name}');
    if (os[permission] != PermissionState.denied) return os[permission]!;
    dialogsShown.add(permission);
    return os[permission] = onRequest[permission] ?? PermissionState.granted;
  }

  @override
  Future<bool> openSettings() async {
    settingsOpened++;
    return true;
  }
}

/// Stands in for the GPS hardware.
class FakeLocationProvider implements LocationProvider {
  bool serviceEnabled = true;

  /// Returned by the next reads; set [error] to make them throw instead.
  DeviceLocation position = DeviceLocation(
    latitude: 20.2961,
    longitude: 85.8245,
    accuracy: 12.4,
    capturedAt: DateTime.now().toUtc(),
  );
  Object? error;

  /// When set, the next read waits for this instead of answering immediately.
  Completer<DeviceLocation>? pending;

  int reads = 0;
  int settingsOpened = 0;

  @override
  Future<bool> isServiceEnabled() async => serviceEnabled;

  @override
  Future<DeviceLocation> currentPosition({required Duration timeLimit}) async {
    reads++;
    if (error != null) throw error!;
    final wait = pending;
    pending = null;
    return wait?.future ?? position;
  }

  @override
  Future<bool> openLocationSettings() async {
    settingsOpened++;
    return true;
  }
}

/// Stands in for the device geocoder. Returns [placemark] (null = no match) or throws [error].
class FakePlaceLookup implements PlaceLookup {
  Placemark? placemark = const Placemark(
    name: 'Jayadev Vihar',
    street: 'Jayadev Vihar',
    locality: 'Bhubaneswar',
    subAdministrativeArea: 'Khordha',
    administrativeArea: 'Odisha',
    postalCode: '751013',
    country: 'India',
    isoCountryCode: 'IN',
  );
  Object? error;
  int lookups = 0;

  @override
  Future<Placemark?> placemarkAt(double latitude, double longitude) async {
    lookups++;
    if (error != null) throw error!;
    return placemark;
  }
}
