import 'core/api/api_client.dart';
import 'core/permissions/permission_service.dart';
import 'features/auth/data/auth_api.dart';
import 'features/auth/data/token_storage.dart';
import 'features/auth/services/auth_service.dart';
import 'features/location/data/location_api.dart';
import 'features/location/services/location_history_service.dart';
import 'features/location/services/location_service.dart';
import 'features/permissions/data/permissions_api.dart';
import 'features/permissions/services/permission_onboarding_service.dart';
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
    required this.permissionOnboardingService,
    required this.locationService,
    required this.locationHistoryService,
  });

  /// Wires the real implementations. Tests can swap the HTTP client, storage, the
  /// OS permission layer, the location hardware or the geocoder.
  factory AppServices.create({
    ApiClient? apiClient,
    TokenStorage? tokenStorage,
    PermissionService? permissionService,
    LocationProvider? locationProvider,
    PlaceLookup? placeLookup,
  }) {
    final client = apiClient ?? ApiClient();
    final authService = AuthService(api: AuthApi(client), storage: tokenStorage ?? TokenStorage());
    final permissions = permissionService ?? PermissionService();
    final profileService = ProfileService(api: ProfileApi(client), authService: authService);
    return AppServices(
      authService: authService,
      profileService: profileService,
      permissionService: permissions,
      permissionSyncService:
          PermissionSyncService(api: PermissionsApi(client), authService: authService),
      permissionOnboardingService:
          PermissionOnboardingService(profileService: profileService, authService: authService),
      locationService: LocationService(
        permissionService: permissions,
        provider: locationProvider,
        placeLookup: placeLookup,
      ),
      locationHistoryService:
          LocationHistoryService(api: LocationApi(client), authService: authService),
    );
  }

  final AuthService authService;
  final ProfileService profileService;
  final PermissionService permissionService;
  final PermissionSyncService permissionSyncService;
  final PermissionOnboardingService permissionOnboardingService;
  final LocationService locationService;
  final LocationHistoryService locationHistoryService;
}
