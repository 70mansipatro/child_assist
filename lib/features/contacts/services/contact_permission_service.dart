import '../../../core/permissions/permission_service.dart';
import '../../permissions/services/permission_sync_service.dart';

/// Whether Child Assist may read the phone's contacts right now, as the OS reports it.
enum ContactAccess {
  granted,

  /// Not allowed yet; the user can allow it from Permissions.
  denied,

  /// Blocked: the OS will not ask again, only the phone's Settings can change it.
  blocked,

  /// Restricted by the device, or no contacts on this platform.
  unavailable,
}

/// The Contacts permission as the OS sees it. The OS is authoritative: the status saved to the
/// account is only a record and never grants access. Chat only *checks* it; the system dialog is
/// shown from onboarding or the Permissions screen, after the user taps a button.
class ContactPermissionService {
  ContactPermissionService({required PermissionService permissionService, PermissionSyncService? syncService})
    : _permissions = permissionService,
      _sync = syncService;

  final PermissionService _permissions;
  final PermissionSyncService? _sync;

  /// The current OS state, without any dialog. Also reports a real change to the account.
  Future<ContactAccess> check() async {
    final state = await _permissions.status(AppPermission.contacts);
    try {
      await _sync?.report(AppPermission.contacts, state, fromRequest: false);
    } catch (_) {
      // Best effort: the OS answer is what counts here.
    }
    return accessFor(state);
  }

  Future<bool> openSettings() => _permissions.openSettings();

  static ContactAccess accessFor(PermissionState state) => switch (state) {
    PermissionState.granted || PermissionState.limited => ContactAccess.granted,
    PermissionState.denied => ContactAccess.denied,
    PermissionState.permanentlyDenied => ContactAccess.blocked,
    PermissionState.restricted || PermissionState.unavailable => ContactAccess.unavailable,
  };
}
