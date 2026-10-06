import '../../../core/api/api_client.dart';
import '../../../core/permissions/permission_service.dart';

/// Permission status as stored by the backend. It records what the device reported;
/// it never grants anything.
enum SyncedPermissionStatus {
  unknown('UNKNOWN'),
  granted('GRANTED'),
  denied('DENIED'),
  restricted('RESTRICTED'),
  limited('LIMITED');

  const SyncedPermissionStatus(this.wireName);

  final String wireName;

  static SyncedPermissionStatus fromWire(String? value) =>
      values.firstWhere((s) => s.wireName == value, orElse: () => unknown);

  /// The status to store for an OS state, or null when there is nothing meaningful to store.
  static SyncedPermissionStatus? fromDevice(PermissionState state) {
    return switch (state) {
      PermissionState.granted => granted,
      PermissionState.limited => limited,
      PermissionState.restricted => restricted,
      PermissionState.denied || PermissionState.permanentlyDenied => denied,
      PermissionState.unavailable => null,
    };
  }
}

extension AppPermissionWire on AppPermission {
  /// Name used by the backend API (`/api/permissions/:permission`).
  String get wireName => switch (this) {
        AppPermission.location => 'LOCATION',
        AppPermission.microphone => 'MICROPHONE',
        AppPermission.camera => 'CAMERA',
        AppPermission.photos => 'PHOTOS',
        AppPermission.notifications => 'NOTIFICATIONS',
      };
}

/// Raw calls to the backend's /api/permissions endpoints. The server identifies the
/// user from the token, so no user ID is ever sent.
class PermissionsApi {
  PermissionsApi(this._client);

  final ApiClient _client;

  Future<Map<AppPermission, SyncedPermissionStatus>> list(String token) async {
    final json = await _client.get('/api/permissions', token: token);
    final result = {for (final p in AppPermission.values) p: SyncedPermissionStatus.unknown};
    final records = json['permissions'];
    if (records is List) {
      for (final record in records.whereType<Map<String, dynamic>>()) {
        final permission = _fromWire(record['permission']);
        if (permission != null) {
          result[permission] = SyncedPermissionStatus.fromWire(record['status'] as String?);
        }
      }
    }
    return result;
  }

  Future<SyncedPermissionStatus> update(
    String token,
    AppPermission permission,
    SyncedPermissionStatus status,
  ) async {
    final json = await _client.patch(
      '/api/permissions/${permission.wireName}',
      token: token,
      body: {'status': status.wireName},
    );
    return SyncedPermissionStatus.fromWire(json['status'] as String?);
  }

  // Ignores server permissions this app version does not use (e.g. DOCUMENTS).
  static AppPermission? _fromWire(Object? value) {
    for (final p in AppPermission.values) {
      if (p.wireName == value) return p;
    }
    return null;
  }
}
