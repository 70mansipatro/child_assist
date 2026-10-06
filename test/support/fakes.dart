import 'dart:async';
import 'dart:convert';

import 'package:geocoding/geocoding.dart' show Placemark;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show DateTimeRange;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:child_assist/app_services.dart';
import 'package:child_assist/core/api/api_client.dart';
import 'package:child_assist/core/permissions/permission_service.dart';
import 'package:child_assist/features/auth/data/token_storage.dart';
import 'package:child_assist/features/documents/services/document_service.dart';
import 'package:child_assist/features/location/services/location_service.dart';
import 'package:child_assist/features/photos/services/photo_gallery_service.dart';

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
    PhotoLibrary? photoLibrary,
    DocumentPlatform? documentPlatform,
  }) =>
      AppServices.create(
        apiClient: ApiClient(baseUrl: 'http://test', httpClient: client),
        tokenStorage: TokenStorage(),
        permissionService: permissionService,
        locationProvider: locationProvider ?? FakeLocationProvider(),
        placeLookup: placeLookup ?? FakePlaceLookup(),
        photoLibrary: photoLibrary ?? FakePhotoLibrary(),
        documentPlatform: documentPlatform ?? FakeDocumentPlatform(),
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

  /// What the user picks when the dialog is shown again for a limited grant.
  PermissionState onRequestAgain = PermissionState.granted;

  @override
  Future<PermissionState> requestAgainIfLimited(AppPermission permission) async {
    calls.add('requestAgain ${permission.name}');
    if (os[permission] != PermissionState.limited) return os[permission]!;
    dialogsShown.add(permission);
    return os[permission] = onRequestAgain;
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

/// Stands in for the device gallery. [photos] are newest first, like the real query.
class FakePhotoLibrary implements PhotoLibrary {
  FakePhotoLibrary([List<PhotoItem>? photos]) : photos = photos ?? [];

  /// [count] photos named IMG_0001.jpg (newest), IMG_0002.jpg, ..., one per day back from
  /// 6 Oct 2026.
  factory FakePhotoLibrary.withPhotos(int count) => FakePhotoLibrary([
        for (var i = 1; i <= count; i++)
          PhotoItem(
            id: 'p$i',
            name: 'IMG_${i.toString().padLeft(4, '0')}.jpg',
            width: 4032,
            height: 3024,
            createdAt: DateTime.utc(2026, 10, 6, 10, 30).subtract(Duration(days: i - 1)),
            modifiedAt: DateTime.utc(2026, 10, 6, 10, 30).subtract(Duration(days: i - 1)),
            mimeType: 'image/jpeg',
          ),
      ]);

  final List<PhotoItem> photos;

  /// Every page query, e.g. "page 0" or "page 0 2026-10-01..2026-10-03".
  final List<String> queries = [];

  /// Every image read as "id WxH".
  final List<String> imageReads = [];

  /// When > 0, that many of the next page queries throw.
  int pageFailures = 0;

  /// When set, the next page query waits for this.
  Completer<void>? pending;

  int resets = 0;
  int selectionPickerShown = 0;

  /// Whether this fake behaves like iOS (has its own limited-selection picker).
  bool hasSelectionPicker = false;

  static final Uint8List _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
  );

  @override
  Future<List<PhotoItem>> page(int page, int pageSize, {DateTimeRange? range}) async {
    queries.add(range == null
        ? 'page $page'
        : 'page $page ${_day(range.start)}..${_day(range.end)}');
    final wait = pending;
    pending = null;
    if (wait != null) await wait.future;
    if (pageFailures > 0) {
      pageFailures--;
      throw Exception('gallery unavailable');
    }
    final matching = range == null
        ? photos
        : photos
            .where((p) =>
                !p.createdAt.isBefore(range.start) &&
                p.createdAt.isBefore(range.end.add(const Duration(days: 1))))
            .toList();
    return matching.skip(page * pageSize).take(pageSize).toList();
  }

  @override
  Future<Uint8List?> image(String id, int width, int height) async {
    imageReads.add('$id ${width}x$height');
    return _png;
  }

  @override
  Future<PhotoItem?> details(String id) async {
    final photo = photos.where((p) => p.id == id).firstOrNull;
    return photo?.withDetails(fileSize: 2457600);
  }

  @override
  Future<bool> changeLimitedSelection() async {
    if (!hasSelectionPicker) return false;
    selectionPickerShown++;
    return true;
  }

  @override
  void reset() => resets++;

  static String _day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// A file on the fake device.
class FakeDocumentFile {
  FakeDocumentFile({
    required this.reference,
    required this.name,
    this.mimeType,
    this.size,
    this.modifiedAt,
    this.content = '',
  });

  final String reference;
  final String name;
  final String? mimeType;
  final int? size;
  final DateTime? modifiedAt;
  final String content;
}

/// Stands in for the system file picker and the documents on the device.
///
/// Put files on the device with [addFile], choose what the user will pick next with
/// [willPick] (nothing set = the user cancels), and delete files with [deleteFile].
class FakeDocumentPlatform implements DocumentPlatform {
  final Map<String, FakeDocumentFile> files = {};
  int _nextFile = 1;

  /// References the user picks the next time the picker opens; null = they cancel.
  List<String>? _nextPick;

  /// When set, the next pick throws it.
  Object? pickError;

  /// When set, the next pick waits for this before returning (the picker is "open").
  Completer<void>? pendingPick;

  /// When > 0, that many of the next info / read / open calls throw.
  int infoFailures = 0;
  int readFailures = 0;
  int openFailures = 0;

  /// Whether a viewer app for the document's type is installed, and whether any app at all
  /// accepts files.
  bool hasViewer = true;
  bool hasAnyApp = true;

  int pickerShown = 0;
  final List<List<String>> pickedExtensions = [];

  /// Every open, e.g. "content://fake/1 application/pdf" or "content://fake/1 any app".
  final List<String> opened = [];

  /// Every byte read: "reference maxBytes".
  final List<String> reads = [];
  final List<String> released = [];

  FakeDocumentFile addFile(
    String name, {
    String? mimeType,
    int? size,
    DateTime? modifiedAt,
    String content = '',
  }) {
    final reference = 'content://fake/${_nextFile++}';
    return files[reference] = FakeDocumentFile(
      reference: reference,
      name: name,
      mimeType: mimeType,
      size: size,
      modifiedAt: modifiedAt,
      content: content,
    );
  }

  void willPick(List<FakeDocumentFile> picked) => _nextPick = [for (final f in picked) f.reference];

  void deleteFile(FakeDocumentFile file) => files.remove(file.reference);

  @override
  Future<List<PickedDocument>> pick(List<String> extensions) async {
    pickerShown++;
    pickedExtensions.add(extensions);
    final wait = pendingPick;
    pendingPick = null;
    if (wait != null) await wait.future;
    final error = pickError;
    pickError = null;
    if (error != null) throw error;
    final picked = _nextPick ?? [];
    _nextPick = null;
    return [
      for (final reference in picked)
        PickedDocument(reference: reference, name: files[reference]!.name, info: _info(files[reference]!)),
    ];
  }

  @override
  Future<DocumentInfo?> info(String reference) async {
    if (infoFailures > 0) {
      infoFailures--;
      throw Exception('provider crashed');
    }
    final file = files[reference];
    return file == null ? null : _info(file);
  }

  @override
  Future<DocumentOpenResult> open(String reference, {required String mimeType, bool anyApp = false}) async {
    if (openFailures > 0) {
      openFailures--;
      throw Exception('activity crashed');
    }
    if (!files.containsKey(reference)) return DocumentOpenResult.unavailable;
    if (!(anyApp ? hasAnyApp : hasViewer)) return DocumentOpenResult.noViewer;
    opened.add(anyApp ? '$reference any app' : '$reference $mimeType');
    return DocumentOpenResult.opened;
  }

  @override
  Future<Uint8List?> read(String reference, int maxBytes) async {
    if (readFailures > 0) {
      readFailures--;
      throw Exception('read failed');
    }
    reads.add('$reference $maxBytes');
    final file = files[reference];
    if (file == null) return null;
    final bytes = utf8.encode(file.content);
    return Uint8List.fromList(bytes.take(maxBytes).toList());
  }

  @override
  Future<void> release(String reference) async => released.add(reference);

  static DocumentInfo _info(FakeDocumentFile f) =>
      DocumentInfo(name: f.name, mimeType: f.mimeType, size: f.size, modifiedAt: f.modifiedAt);
}
