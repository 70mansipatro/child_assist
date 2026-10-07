import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../features/auth/services/auth_service.dart';
import '../../features/notifications/data/notifications_api.dart';
import '../../features/notifications/models/app_notification.dart';
import '../../features/permissions/data/permissions_api.dart';
import '../../features/permissions/services/permission_sync_service.dart';
import '../api/api_client.dart';
import '../navigation/app_menu.dart';
import '../permissions/permission_service.dart';
import 'notification_types.dart';
import 'push_platform.dart';

export 'notification_types.dart';
export 'push_platform.dart' show PushMessage, PushPlatform;

/// Child Assist's notifications on this phone: push registration, what happens when one arrives
/// or is tapped, the unread badge, and the account's history and preferences.
///
/// - Pushes are registered only for a signed-in account and only once the OS allows
///   notifications; this service never shows a permission dialog (the permission walkthrough and
///   the Permissions screen do).
/// - A push that arrives while the app is open is shown once, unless the screen it is about is
///   already showing (chat results while Chat is open). Security alerts also show in the app.
/// - A tap (app open, in the background, or closed) opens the screen the notification is about,
///   after sign-in and once the app is ready. It never sends, shares or confirms anything.
/// - Logout removes this phone from the account on the server and invalidates its push token, so
///   the next account on this phone never receives the previous one's notifications.
class NotificationService extends ChangeNotifier {
  NotificationService({
    required AuthService authService,
    required NotificationsApi api,
    required PermissionService permissionService,
    PermissionSyncService? permissionSyncService,
    PushPlatform? platform,
    Future<String?> Function()? appVersion,
    TargetPlatform? targetPlatform,
  })  : _auth = authService,
        _api = api,
        _permissions = permissionService,
        _permissionSync = permissionSyncService,
        _platform = platform ?? FirebasePushPlatform(),
        _appVersion = appVersion ?? _readAppVersion,
        _targetPlatform = targetPlatform ?? defaultTargetPlatform {
    _auth.addListener(_onAuthChanged);
    _auth.addLogoutHook(_beforeLogout);
    _permissionSync?.addListener(_onPermissionsSynced);
    _onAuthChanged();
  }

  final AuthService _auth;
  final NotificationsApi _api;
  final PermissionService _permissions;
  final PermissionSyncService? _permissionSync;
  final PushPlatform _platform;
  final Future<String?> Function() _appVersion;
  final TargetPlatform _targetPlatform;

  final List<StreamSubscription<Object?>> _subscriptions = [];
  final _alerts = StreamController<PushMessage>.broadcast();

  Future<void>? _starting;
  bool _pushReady = false;

  /// The signed-in account everything below belongs to.
  String? _owner;

  /// Bumped on every account change so late answers for the previous account are dropped.
  int _generation = 0;

  String? _version;
  String? _deviceId;
  String? _registeredToken;
  bool _registering = false;
  bool _registrationFailed = false;

  /// Another sync was asked for while one was running; it runs again right after.
  bool _resyncRequested = false;

  /// A failed registration is retried with growing delays (per account).
  Timer? _retryTimer;
  int _retryAttempt = 0;
  static const retryDelays = [Duration(seconds: 10), Duration(seconds: 30), Duration(minutes: 2), Duration(minutes: 5)];

  /// The previous account's FCM token being invalidated; a new token is only read after it.
  Future<void>? _tokenReset;

  int _unreadCount = 0;
  NotificationRoute? _pendingRoute;
  String? _pendingReadId;
  AppDestination? _visible;

  /// Notification IDs already shown or handled, so a push delivered twice shows once.
  final _seen = <String>{};

  static const _platformChannel = MethodChannel('child_assist/platform');

  // ---------------------------------------------------------------------------------------------
  // State for the UI

  /// Unread notifications for the signed-in account (the badge).
  int get unreadCount => _unreadCount;

  /// Push delivery could be set up on this phone.
  bool get pushAvailable => _pushReady;

  /// This phone is registered for pushes for the signed-in account.
  bool get registered => _deviceId != null;

  /// The last registration attempt failed (offline, server down). It is retried automatically;
  /// sign-in is never blocked by it.
  bool get registrationFailed => _registrationFailed;

  /// A tapped notification's destination, waiting for the signed-in app to open it.
  NotificationRoute? get pendingRoute => _pendingRoute;

  /// Takes the pending destination, so it is opened exactly once.
  NotificationRoute? takePendingRoute() {
    final route = _pendingRoute;
    _pendingRoute = null;
    return route;
  }

  /// Security alerts that arrived while the app was open, for an in-app banner.
  Stream<PushMessage> get inAppAlerts => _alerts.stream;

  /// What the user is looking at, so a push about it is not shown on top of it.
  void setVisibleDestination(AppDestination? destination) => _visible = destination;

  // ---------------------------------------------------------------------------------------------
  // Start-up and registration

  /// Starts push handling. Safe to call more than once; never throws. Picks up the notification
  /// whose tap launched the app, so it is opened once the user is signed in.
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    if (!_platform.isSupported) return;
    // Looked up once, without holding anything up; registration sends it when known.
    unawaited(_appVersion().then((v) => _version = _validVersion(v), onError: (Object _) => null));
    try {
      await _platform.initialize();
      _subscriptions
        ..add(_platform.onForegroundMessage.listen(_onForegroundMessage))
        ..add(_platform.onOpened.listen(_onOpened))
        ..add(_platform.onTokenRefresh.listen((_) {
          _registeredToken = null;
          unawaited(syncRegistration());
        }));
      _pushReady = true;
      final launch = await _platform.takeLaunchMessage();
      if (launch != null) _onOpened(launch);
    } catch (e) {
      // Without Firebase the app still works; notifications stay available in the history.
      debugPrint('Push notifications unavailable: ${e.runtimeType}');
      _diag('initialisation error: ${describeError(e)}');
      _pushReady = false;
    }
    notifyListeners();
    await syncRegistration();
  }

  /// Registers this phone for the signed-in account if the OS allows notifications. Status checks
  /// only, never a dialog. Never throws.
  Future<void> syncRegistration() async {
    final owner = _owner;
    final generation = _generation;
    if (owner == null) return _diag('sync skipped: not signed in');
    if (!_pushReady) return _diag('sync skipped: push not initialised');
    if (_registering) {
      // Never drop a request (e.g. the permission was just granted): run again afterwards.
      _resyncRequested = true;
      return;
    }
    _registering = true;
    var retry = false;
    try {
      final permission = await _permissions.notificationStatus();
      _diag('notification permission: ${permission.name}');
      if (!permission.isUsable) return;
      await _tokenReset;
      final fcmToken = await _platform.getToken();
      _diag('FCM token received: ${fcmToken == null ? 'no' : 'yes (${maskToken(fcmToken)})'}');
      if (generation != _generation) return;
      if (fcmToken == null) {
        retry = true;
        return;
      }
      if (fcmToken == _registeredToken && _deviceId != null) return _diag('already registered for user $owner');
      final appVersion = _version;
      _diag('registering device for user $owner: POST /api/notifications/devices');
      final device = await _auth.authorized(
        (token) => _api.registerDevice(
          token,
          fcmToken: fcmToken,
          platform: _targetPlatform == TargetPlatform.iOS ? 'IOS' : 'ANDROID',
          appVersion: appVersion,
        ),
      );
      if (generation != _generation) return;
      _deviceId = device.id;
      _registeredToken = fcmToken;
      _registrationFailed = false;
      _retryAttempt = 0;
      _retryTimer?.cancel();
      _diag('registered: device ${device.id} for user $owner');
    } catch (e) {
      if (generation == _generation) {
        _registrationFailed = true;
        // Signed out by a 401: nothing to retry for this account.
        retry = !(e is ApiException && e.isUnauthorized);
      }
      // Always visible (release too), without details that could identify the device.
      debugPrint('Push registration failed: ${e.runtimeType}');
      _diag('registration error: ${describeError(e)}');
    } finally {
      _registering = false;
      if (generation == _generation) {
        if (retry) _scheduleRetry(generation);
        notifyListeners();
        if (_resyncRequested) {
          _resyncRequested = false;
          unawaited(syncRegistration());
        }
      }
    }
  }

  void _scheduleRetry(int generation) {
    if (_retryTimer?.isActive ?? false) return;
    if (_retryAttempt >= retryDelays.length) return _diag('registration retries exhausted; next try on app resume');
    final delay = retryDelays[_retryAttempt++];
    _diag('retrying registration in ${delay.inSeconds}s (attempt $_retryAttempt)');
    _retryTimer = Timer(delay, () {
      if (generation == _generation) unawaited(syncRegistration());
    });
  }

  /// "len=163 abc123…wxyz": enough to tell tokens apart in a log, never the token itself.
  static String maskToken(String token) =>
      token.length < 16 ? 'len=${token.length}' : 'len=${token.length} ${token.substring(0, 6)}…${token.substring(token.length - 4)}';

  /// An error for the development log: the API status/message or the Firebase error code.
  static String describeError(Object e) {
    if (e is ApiException) return 'HTTP ${e.statusCode ?? 'unreachable'} ${e.code ?? ''} ${e.message}'.trim();
    final text = e.toString();
    return '${e.runtimeType}: ${text.length > 300 ? text.substring(0, 300) : text}';
  }

  /// Development-only push diagnostics. Never prints a full token or a JWT.
  static void _diag(String message) {
    if (kDebugMode) debugPrint('[Push] $message');
  }

  void _onPermissionsSynced() {
    final granted = _permissionSync?.serverStatuses[AppPermission.notifications] == SyncedPermissionStatus.granted;
    if (granted && _deviceId == null) unawaited(syncRegistration());
  }

  // ---------------------------------------------------------------------------------------------
  // Arriving and tapped notifications

  void _onForegroundMessage(PushMessage message) {
    if (_owner == null) return;
    final id = message.notificationId;
    if (id != null && !_remember(id)) return;
    unawaited(refreshUnreadCount());
    if (_isAboutVisibleScreen(message)) return;
    unawaited(_platform.show(message).catchError((Object e) => debugPrint('Showing a notification failed: ${e.runtimeType}')));
    if (message.category == NotificationCategory.security) _alerts.add(message);
  }

  /// Chat results while Chat is open are already on screen.
  bool _isAboutVisibleScreen(PushMessage message) {
    final category = message.category;
    return _visible == AppDestination.chat &&
        (category == NotificationCategory.chat || category == NotificationCategory.communication);
  }

  void _onOpened(PushMessage message) {
    final id = message.notificationId;
    if (id != null) {
      _remember(id);
      if (_owner != null) {
        unawaited(markRead(id));
      } else {
        _pendingReadId = id;
      }
    }
    _pendingRoute = message.route;
    notifyListeners();
  }

  /// True if [id] was not seen before.
  bool _remember(String id) {
    if (!_seen.add(id)) return false;
    while (_seen.length > 200) {
      _seen.remove(_seen.first);
    }
    return true;
  }

  // ---------------------------------------------------------------------------------------------
  // History and preferences (always the signed-in account's, via its token)

  Future<void> refreshUnreadCount() async {
    final owner = _owner;
    if (owner == null) return;
    try {
      final count = await _auth.authorized(_api.unreadCount);
      if (_owner != owner) return;
      _unreadCount = count;
      notifyListeners();
    } on ApiException catch (e) {
      debugPrint('Unread count failed: ${e.statusCode}');
    }
  }

  Future<NotificationPage> loadPage({String? before}) async {
    final owner = _owner;
    final page = await _auth.authorized((token) => _api.list(token, before: before));
    if (_owner == owner) {
      _unreadCount = page.unreadCount;
      notifyListeners();
    }
    return page;
  }

  Future<void> markRead(String id) async {
    final owner = _owner;
    if (owner == null) return;
    try {
      await _auth.authorized((token) => _api.markRead(token, id));
    } on ApiException catch (e) {
      // Already gone, or not this account's: nothing to mark.
      debugPrint('Mark read failed: ${e.statusCode}');
    }
    if (_owner == owner) await refreshUnreadCount();
  }

  Future<void> markAllRead() async {
    final owner = _owner;
    await _auth.authorized(_api.markAllRead);
    if (_owner != owner) return;
    _unreadCount = 0;
    notifyListeners();
    unawaited(_platform.cancelAll().catchError((Object _) {}));
  }

  Future<NotificationPreferences> loadPreferences() => _auth.authorized(_api.preferences);

  Future<NotificationPreferences> setPreference(NotificationCategory category, bool enabled) {
    if (category.mandatory && !enabled) {
      throw ApiException("Security alerts can't be turned off.", statusCode: 400, code: 'MANDATORY_CATEGORY');
    }
    return _auth.authorized((token) => _api.updatePreference(token, category, enabled));
  }

  // ---------------------------------------------------------------------------------------------
  // Accounts

  /// Runs during logout while the token is still valid: removes this phone from the account.
  Future<void> _beforeLogout(String token) async {
    final deviceId = _deviceId;
    _deviceId = null;
    _registeredToken = null;
    if (deviceId == null) return;
    try {
      await _api.unregisterDevice(token, deviceId);
    } catch (e) {
      // Offline: the token is invalidated below anyway, so the server drops it on its next push.
      debugPrint('Push unregistration failed: ${e.runtimeType}');
    }
  }

  // Login, logout, session expiry and account switches all arrive here.
  void _onAuthChanged() {
    final userId = _auth.currentUser?.id;
    if (userId == _owner) return;
    final previous = _owner;
    _generation++;
    _owner = userId;
    _unreadCount = 0;
    _registrationFailed = false;
    _retryTimer?.cancel();
    _retryAttempt = 0;
    _seen.clear();
    if (previous != null) {
      // Nothing of the previous account's may stay: no destination, no notifications in the shade,
      // and no push token that could still receive its notifications.
      _pendingRoute = null;
      _pendingReadId = null;
      _deviceId = null;
      _registeredToken = null;
      if (_pushReady) {
        unawaited(_platform.cancelAll().catchError((Object _) {}));
        _tokenReset = _platform.deleteToken().catchError((Object e) => debugPrint('Deleting the push token failed: ${e.runtimeType}'));
      }
    }
    if (userId != null) {
      final readId = _pendingReadId;
      _pendingReadId = null;
      if (readId != null) unawaited(markRead(readId));
      unawaited(refreshUnreadCount());
      unawaited(syncRegistration());
    }
    notifyListeners();
  }

  static String? _validVersion(String? version) =>
      version != null && version.isNotEmpty && version.length <= 40 ? version : null;

  static Future<String?> _readAppVersion() async {
    try {
      return await _platformChannel.invokeMethod<String>('getAppVersion');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    _permissionSync?.removeListener(_onPermissionsSynced);
    _retryTimer?.cancel();
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    unawaited(_alerts.close());
    super.dispose();
  }
}
