import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

/// Device permissions the app uses. Each one is requested only when the user
/// opens the feature that needs it, never at app start.
enum AppPermission {
  location('Location'),
  microphone('Microphone'),
  camera('Camera'),
  photos('Photos'),
  notifications('Notifications');

  const AppPermission(this.label);

  final String label;
}

/// The OS-reported state of a permission. The OS is the source of truth.
enum PermissionState {
  granted,

  /// Not granted, but the app may still ask. On Android this is also what a status check
  /// returns for a permission that was never requested.
  denied,

  /// The user blocked it; the OS will not show a dialog again. Only Settings can change it.
  permanentlyDenied,

  /// Blocked by device policy (e.g. iOS parental controls); the user cannot change it.
  restricted,

  /// Partial access, e.g. only selected photos (iOS 14+, Android 14+) or provisional
  /// notifications (iOS).
  limited,

  /// This platform has no such permission or the plugin does not support it.
  unavailable;

  bool get isUsable => this == granted || this == limited;
}

/// Checks and requests device permissions via `permission_handler`.
///
/// Never throws for unsupported platforms or permissions: those report
/// [PermissionState.unavailable].
class PermissionService {
  PermissionService({
    bool? isWeb,
    TargetPlatform? platform,
    Future<int?> Function()? androidSdkInt,
  })  : _isWeb = isWeb ?? kIsWeb,
        _platform = platform ?? defaultTargetPlatform,
        _androidSdkInt = androidSdkInt ?? _readAndroidSdkInt;

  final bool _isWeb;
  final TargetPlatform _platform;
  final Future<int?> Function() _androidSdkInt;
  int? _cachedSdkInt;

  static const _platformChannel = MethodChannel('child_assist/platform');

  // Convenience wrappers, one per feature.
  Future<PermissionState> requestLocationPermission() => request(AppPermission.location);
  Future<PermissionState> requestMicrophonePermission() => request(AppPermission.microphone);
  Future<PermissionState> requestCameraPermission() => request(AppPermission.camera);
  Future<PermissionState> requestPhotoPermission() => request(AppPermission.photos);
  Future<PermissionState> requestNotificationPermission() => request(AppPermission.notifications);

  Future<PermissionState> locationStatus() => status(AppPermission.location);
  Future<PermissionState> microphoneStatus() => status(AppPermission.microphone);
  Future<PermissionState> cameraStatus() => status(AppPermission.camera);
  Future<PermissionState> photoStatus() => status(AppPermission.photos);
  Future<PermissionState> notificationStatus() => status(AppPermission.notifications);

  /// Current state without showing any dialog.
  Future<PermissionState> status(AppPermission permission) async {
    final native = await _nativePermission(permission);
    if (native == null) return PermissionState.unavailable;
    try {
      return _map(await native.status);
    } catch (e) {
      debugPrint('Permission status check failed for ${permission.name}: $e');
      return PermissionState.unavailable;
    }
  }

  /// Checks the current state and shows the system dialog only if the OS still allows asking.
  Future<PermissionState> request(AppPermission permission) async {
    final native = await _nativePermission(permission);
    if (native == null) return PermissionState.unavailable;
    try {
      final current = _map(await native.status);
      if (current != PermissionState.denied) return current;
      // On Android, a permanently denied permission resolves immediately as permanentlyDenied.
      return _map(await native.request());
    } catch (e) {
      debugPrint('Permission request failed for ${permission.name}: $e');
      return PermissionState.unavailable;
    }
  }

  /// Opens this app's page in the system settings. Returns false if that is not possible.
  Future<bool> openSettings() async {
    if (!_isMobile) return false;
    try {
      return await ph.openAppSettings();
    } catch (_) {
      return false;
    }
  }

  bool get _isMobile =>
      !_isWeb && (_platform == TargetPlatform.android || _platform == TargetPlatform.iOS);

  /// Maps an app permission to the plugin permission for this platform, or null if unsupported.
  Future<ph.Permission?> _nativePermission(AppPermission permission) async {
    if (_isWeb) {
      // The browser exposes these through the Permissions API; there is no photos permission.
      return switch (permission) {
        AppPermission.location => ph.Permission.location,
        AppPermission.microphone => ph.Permission.microphone,
        AppPermission.camera => ph.Permission.camera,
        AppPermission.notifications => ph.Permission.notification,
        AppPermission.photos => null,
      };
    }
    if (!_isMobile) return null;

    return switch (permission) {
      // Foreground ("while using the app") location only.
      AppPermission.location => ph.Permission.locationWhenInUse,
      AppPermission.microphone => ph.Permission.microphone,
      AppPermission.camera => ph.Permission.camera,
      AppPermission.notifications => ph.Permission.notification,
      AppPermission.photos => await _photosPermission(),
    };
  }

  /// Android 13+ has a dedicated photos permission; older versions use storage access.
  Future<ph.Permission> _photosPermission() async {
    if (_platform != TargetPlatform.android) return ph.Permission.photos;
    final sdk = _cachedSdkInt ??= await _androidSdkInt();
    return (sdk != null && sdk < 33) ? ph.Permission.storage : ph.Permission.photos;
  }

  static Future<int?> _readAndroidSdkInt() async {
    try {
      return await _platformChannel.invokeMethod<int>('getSdkInt');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static PermissionState _map(ph.PermissionStatus status) {
    return switch (status) {
      ph.PermissionStatus.granted => PermissionState.granted,
      ph.PermissionStatus.denied => PermissionState.denied,
      ph.PermissionStatus.permanentlyDenied => PermissionState.permanentlyDenied,
      ph.PermissionStatus.restricted => PermissionState.restricted,
      ph.PermissionStatus.limited => PermissionState.limited,
      // iOS provisional notifications: delivered quietly, i.e. partial access.
      ph.PermissionStatus.provisional => PermissionState.limited,
    };
  }
}
