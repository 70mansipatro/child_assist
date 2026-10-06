import 'package:flutter/foundation.dart';

import '../../../core/permissions/permission_service.dart';
import '../../auth/services/auth_service.dart';
import '../data/permissions_api.dart';

/// Mirrors the OS permission results to the backend for the signed-in user.
///
/// Flow: the app asks the OS first, then reports the OS result here; this never asks the OS
/// for anything. Only changes are sent, so refreshing the screen does not spam the API.
class PermissionSyncService extends ChangeNotifier {
  PermissionSyncService({required PermissionsApi api, required AuthService authService})
      : _api = api,
        _auth = authService {
    _auth.addListener(_onAuthChanged);
  }

  final PermissionsApi _api;
  final AuthService _auth;
  String? _loadedForUserId;

  Map<AppPermission, SyncedPermissionStatus> _server = {};

  /// What the backend currently has stored for each permission.
  Map<AppPermission, SyncedPermissionStatus> get serverStatuses => Map.unmodifiable(_server);

  /// Fetches the stored statuses for the current user.
  Future<void> load() async {
    final statuses = await _auth.authorized(_api.list);
    _server = statuses;
    _loadedForUserId = _auth.currentUser?.id;
    notifyListeners();
  }

  /// Stores [state] for [permission] if it differs from what the backend has.
  ///
  /// Pass [fromRequest] = true when [state] came from showing the user a permission dialog.
  /// A plain status check returning "denied" is not stored over UNKNOWN, because the OS
  /// reports "denied" for permissions that were simply never requested.
  ///
  /// Returns true if the backend was updated.
  Future<bool> report(AppPermission permission, PermissionState state, {required bool fromRequest}) async {
    final target = SyncedPermissionStatus.fromDevice(state);
    if (target == null) return false;

    if (_loadedForUserId != _auth.currentUser?.id) await load();
    final current = _server[permission] ?? SyncedPermissionStatus.unknown;

    if (target == current) return false;
    if (!fromRequest &&
        target == SyncedPermissionStatus.denied &&
        current == SyncedPermissionStatus.unknown) {
      return false;
    }

    final stored = await _auth.authorized((token) => _api.update(token, permission, target));
    _server = {..._server, permission: stored};
    notifyListeners();
    return true;
  }

  // Never carry one user's statuses over to the next account on this device.
  void _onAuthChanged() {
    if (_auth.currentUser?.id != _loadedForUserId) {
      _server = {};
      _loadedForUserId = null;
    }
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    super.dispose();
  }
}
