import 'core/api/api_client.dart';
import 'core/permissions/permission_service.dart';
import 'features/auth/data/auth_api.dart';
import 'features/auth/data/token_storage.dart';
import 'features/auth/services/auth_service.dart';
import 'features/permissions/data/permissions_api.dart';
import 'features/permissions/services/permission_sync_service.dart';
import 'features/profile/data/profile_api.dart';
import 'features/profile/services/profile_service.dart';

/// The app's long-lived services, created once at startup and passed down to screens.
class AppServices {
  AppServices({
    required this.authService,
    required this.profileService,
    required this.permissionService,
    required this.permissionSyncService,
  });

  /// Wires the real implementations. Tests can swap the HTTP client, storage or the
  /// OS permission layer.
  factory AppServices.create({
    ApiClient? apiClient,
    TokenStorage? tokenStorage,
    PermissionService? permissionService,
  }) {
    final client = apiClient ?? ApiClient();
    final authService = AuthService(api: AuthApi(client), storage: tokenStorage ?? TokenStorage());
    return AppServices(
      authService: authService,
      profileService: ProfileService(api: ProfileApi(client), authService: authService),
      permissionService: permissionService ?? PermissionService(),
      permissionSyncService:
          PermissionSyncService(api: PermissionsApi(client), authService: authService),
    );
  }

  final AuthService authService;
  final ProfileService profileService;
  final PermissionService permissionService;
  final PermissionSyncService permissionSyncService;
}
