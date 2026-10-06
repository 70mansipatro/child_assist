import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:child_assist/app_services.dart';
import 'package:child_assist/core/api/api_client.dart';
import 'package:child_assist/core/permissions/permission_service.dart';
import 'package:child_assist/features/auth/data/token_storage.dart';

const testPassword = 'password123';

/// In-memory backend with the auth, profile and permission endpoints. Like the real
/// server, it identifies the user only from the bearer token and keeps data per user.
class FakeBackend {
  final Map<String, Map<String, dynamic>> users = {
    'u1': {'id': 'u1', 'name': 'Mansi', 'email': 'mansi@example.com', 'profileImageUrl': null},
    'u2': {'id': 'u2', 'name': 'Ravi', 'email': 'ravi@example.com', 'profileImageUrl': null},
  };

  /// userId -> permission -> status, as stored by PATCH /api/permissions/:permission.
  final Map<String, Map<String, String>> permissions = {};

  /// Every PATCH received, e.g. "PATCH /api/permissions/LOCATION GRANTED (u1)".
  final List<String> patches = [];

  static const supportedPermissions = [
    'LOCATION', 'MICROPHONE', 'CAMERA', 'PHOTOS', 'NOTIFICATIONS', 'DOCUMENTS', //
  ];
  static const supportedStatuses = ['UNKNOWN', 'GRANTED', 'DENIED', 'RESTRICTED', 'LIMITED'];

  static String tokenFor(String userId) => 'tok-$userId';

  late final MockClient client = MockClient(_handle);

  AppServices services(PermissionService permissionService) => AppServices.create(
        apiClient: ApiClient(baseUrl: 'http://test', httpClient: client),
        tokenStorage: TokenStorage(),
        permissionService: permissionService,
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

    final userId = _userFromToken(req.headers['Authorization']);
    if (userId == null) return _json(401, {'message': 'Invalid or expired token'});
    final user = users[userId]!;

    if (path == '/api/auth/me') return _json(200, {'user': _authUser(user)});
    if (path == '/api/auth/logout') return _json(200, {'message': 'Logout successful'});

    if (path == '/api/profile' && req.method == 'GET') return _json(200, {'user': user});
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
      final permission = path.substring('/api/permissions/'.length);
      final status = (jsonDecode(req.body) as Map<String, dynamic>)['status'];
      if (!supportedPermissions.contains(permission) || !supportedStatuses.contains(status)) {
        return _json(400, {'message': 'Validation failed'});
      }
      patches.add('PATCH /api/permissions/$permission $status ($userId)');
      (permissions[userId] ??= {})[permission] = status as String;
      return _json(200, {'permission': permission, 'status': status});
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
  int settingsOpened = 0;

  @override
  Future<PermissionState> status(AppPermission permission) async => os[permission]!;

  @override
  Future<PermissionState> request(AppPermission permission) async {
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
