import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/api/api_client.dart';
import '../../../core/permissions/permission_service.dart';
import '../../auth/services/auth_service.dart';
import '../../permissions/services/permission_sync_service.dart';
import '../data/location_api.dart';
import '../data/tracking_store.dart';
import '../models/automatic_tracking.dart';
import '../models/location_record.dart';
import 'background_location_source.dart';
import 'location_service.dart' show DeviceLocation, NativePlaceLookup, PlaceLookup;
import 'travel_point_filter.dart';

export '../models/automatic_tracking.dart';

/// Automatic Location History: while the user has it switched on and the OS allows background
/// location, saves the significant places they stay at, so "Where did I go today?" has answers
/// without tapping "Get Current Location" everywhere.
///
/// Transparent and user-controlled:
/// - It only starts after the user switches it on and the OS grants background location. Status
///   checks never show a permission dialog; only [enable] (a user tap) does.
/// - On Android it runs as a foreground service with a persistent notification for as long as it
///   collects anything. [status] is worked out from the OS, never just from the saved preference.
/// - It stops when the user switches it off, logs out, or the OS permission is revoked.
///
/// Separate from [LocationService] ("Get Current Location"), which stays manual and foreground.
/// Places are uploaded with the same JWT as everything else; the server decides whose they are.
class AutomaticLocationTrackingService extends ChangeNotifier {
  AutomaticLocationTrackingService({
    required AuthService authService,
    required LocationApi api,
    required PermissionService permissionService,
    PermissionSyncService? permissionSyncService,
    BackgroundLocationSource? source,
    PlaceLookup? placeLookup,
    TrackingStore? store,
    this.config = const AutomaticTrackingConfig(),
    DateTime Function()? clock,
  })  : _auth = authService,
        _api = api,
        _permissions = permissionService,
        _permissionSync = permissionSyncService,
        _source = source ?? GeolocatorBackgroundLocationSource(),
        _places = placeLookup ?? NativePlaceLookup(),
        _store = store ?? TrackingStore(),
        _clock = clock ?? DateTime.now {
    _filter = TravelPointFilter(config);
    _auth.addListener(_onAuthChanged);
    _onAuthChanged();
  }

  final AuthService _auth;
  final LocationApi _api;
  final PermissionService _permissions;
  final PermissionSyncService? _permissionSync;
  final BackgroundLocationSource _source;
  final PlaceLookup _places;
  final TrackingStore _store;
  final DateTime Function() _clock;
  final AutomaticTrackingConfig config;

  /// The account everything below belongs to.
  String? _owner;

  /// Bumped whenever tracking stops or the account changes, so work started earlier (a pending
  /// upload, a timer, a permission check) never acts on the new state or another account.
  int _generation = 0;

  bool _enabled = false;
  bool _restoring = false;
  bool _enabling = false;
  AutomaticTrackingStatus _status = AutomaticTrackingStatus.off;
  TrackingIssue? _issue;
  bool _notificationsBlocked = false;

  late TravelPointFilter _filter;
  StreamSubscription<TrackedPoint>? _subscription;
  Timer? _stayTimer;
  Timer? _retryTimer;

  List<TrackedPoint> _queue = [];
  bool _flushing = false;
  bool _uploadFailed = false;
  int _savedCount = 0;
  LocationRecord? _lastSaved;

  /// The user's choice: switched on or off. Not the same as collecting; see [status].
  bool get enabled => _enabled;

  AutomaticTrackingStatus get status => _status;

  /// True only while places are really being collected.
  bool get isActive => _status == AutomaticTrackingStatus.active;

  /// Why tracking is paused, needs permission or failed. Null while active or off.
  TrackingIssue? get issue => _issue;

  /// Loading the saved preference, or asking for permissions after a tap.
  bool get busy => _restoring || _enabling;

  /// Notifications are blocked (Android 13+), so the tracking notification is not shown in the
  /// notification shade (Android still lists the app under active apps).
  bool get notificationsBlocked => _notificationsBlocked;

  bool get isSupported => _source.isSupported;

  /// Places collected but not uploaded yet (offline, server unavailable).
  int get pendingUploads => _queue.length;

  /// The last upload attempt failed; places wait in the queue for a retry.
  bool get uploadFailed => _uploadFailed;

  /// Goes up each time a place is stored on the server, so screens know to reload history.
  int get savedCount => _savedCount;

  /// The most recent place stored on the server in this session.
  LocationRecord? get lastSaved => _lastSaved;

  // ---------------------------------------------------------------------------------------------
  // User actions

  /// Switches Automatic Location History on. Call only from a user tap, after explaining what is
  /// collected: this shows the OS permission dialogs (location, then background location, then
  /// notifications on Android 13+). Tracking starts only if the OS grants background location;
  /// otherwise [status] is [AutomaticTrackingStatus.permissionRequired]. Never throws.
  Future<void> enable() async {
    final owner = _owner;
    if (owner == null || _enabling) return;
    _enabling = true;
    final generation = ++_generation;
    _stopCollecting();
    _enabled = true;
    _setStatus(AutomaticTrackingStatus.starting);
    try {
      if (!_source.isSupported) {
        _enabled = false;
        return _setStatus(AutomaticTrackingStatus.error, TrackingIssue.unsupported);
      }
      await _store.setEnabled(owner, true);
      // A fresh start: where the user is now becomes the first saved place.
      await _store.setLastPlace(owner, null);
      _filter.reset();

      final foreground = await _permissions.requestLocationPermission();
      unawaited(_report(AppPermission.location, foreground));
      if (generation != _generation) return;
      if (!foreground.isUsable) {
        return _setStatus(
          AutomaticTrackingStatus.permissionRequired,
          foreground == PermissionState.restricted ? TrackingIssue.restricted : TrackingIssue.locationPermission,
        );
      }

      final background = await _permissions.requestBackgroundLocationPermission();
      if (generation != _generation) return;
      if (!background.isUsable) {
        return _setStatus(AutomaticTrackingStatus.permissionRequired, TrackingIssue.backgroundPermission);
      }

      // Android 13+: lets the tracking notification show in the notification shade.
      final notifications = await _permissions.requestNotificationPermission();
      unawaited(_report(AppPermission.notifications, notifications));
      _notificationsBlocked = !notifications.isUsable && notifications != PermissionState.unavailable;
      if (generation != _generation) return;

      await _startIfAllowed(generation);
    } finally {
      _enabling = false;
      notifyListeners();
    }
  }

  /// Switches Automatic Location History off: stops collecting at once. Places already saved stay
  /// in the history until the user clears it; places still waiting to upload are still sent.
  Future<void> disable() async {
    final owner = _owner;
    if (owner == null) return;
    _generation++;
    _stopCollecting();
    _enabled = false;
    _filter.reset();
    _setStatus(AutomaticTrackingStatus.off);
    await _store.setEnabled(owner, false);
    await _store.setLastPlace(owner, null);
    unawaited(flush());
  }

  /// Re-checks the OS after the app returns to the foreground: stops if a permission was revoked
  /// or location was turned off, starts again if the user fixed it in Settings, and retries
  /// unsent places. Never shows a dialog.
  Future<void> recheck() async {
    if (_owner == null || busy) return;
    final generation = _generation;
    if (_enabled) {
      if (isActive) {
        if (!await _stillAllowed(generation)) return;
      } else {
        await _startIfAllowed(generation);
      }
    }
    if (generation == _generation) unawaited(flush());
  }

  Future<bool> openAppSettings() => _permissions.openSettings();

  // ---------------------------------------------------------------------------------------------
  // Starting and stopping

  /// Starts collecting if the OS allows it; otherwise records why not. Status checks only.
  Future<void> _startIfAllowed(int generation) async {
    final problem = await _whyNotAllowed();
    if (generation != _generation) return;
    if (problem != null) return _setProblem(problem);

    _setStatus(AutomaticTrackingStatus.starting);
    try {
      _subscription = _source.positions(config).listen(
        _onReading,
        onError: (Object error) => _onStreamError(error, generation),
        cancelOnError: true,
      );
      _setStatus(AutomaticTrackingStatus.active);
    } catch (e) {
      debugPrint('Automatic location could not start: ${e.runtimeType}');
      _stopCollecting();
      _setStatus(AutomaticTrackingStatus.error, TrackingIssue.startFailed);
    }
  }

  /// Null if everything needed for background collection is in place.
  Future<TrackingIssue?> _whyNotAllowed() async {
    if (!_source.isSupported) return TrackingIssue.unsupported;
    final foreground = await _permissions.locationStatus();
    if (foreground == PermissionState.restricted) return TrackingIssue.restricted;
    if (!foreground.isUsable) return TrackingIssue.locationPermission;
    if (!(await _permissions.backgroundLocationStatus()).isUsable) return TrackingIssue.backgroundPermission;
    if (!await _serviceEnabled()) return TrackingIssue.servicesDisabled;
    return null;
  }

  /// While active: stops collecting if the OS no longer allows it.
  Future<bool> _stillAllowed(int generation) async {
    final problem = await _whyNotAllowed();
    if (generation != _generation) return false;
    if (problem == null) return true;
    _stopCollecting();
    _setProblem(problem);
    return false;
  }

  void _setProblem(TrackingIssue problem) => _setStatus(switch (problem) {
    TrackingIssue.servicesDisabled => AutomaticTrackingStatus.paused,
    TrackingIssue.startFailed || TrackingIssue.unsupported => AutomaticTrackingStatus.error,
    _ => AutomaticTrackingStatus.permissionRequired,
  }, problem);

  Future<bool> _serviceEnabled() async {
    try {
      return await _source.isServiceEnabled();
    } catch (_) {
      return false;
    }
  }

  // The platform stopped the stream: permission revoked, location turned off, or the service
  // failed. Work out which from the OS, without dialogs.
  Future<void> _onStreamError(Object error, int generation) async {
    debugPrint('Automatic location stream stopped: ${error.runtimeType}');
    if (generation != _generation) return;
    _subscription = null;
    _stopCollecting();
    final problem = await _whyNotAllowed();
    if (generation != _generation) return;
    _setProblem(problem ?? TrackingIssue.startFailed);
  }

  void _stopCollecting() {
    _subscription?.cancel();
    _subscription = null;
    _stayTimer?.cancel();
    _stayTimer = null;
  }

  void _setStatus(AutomaticTrackingStatus status, [TrackingIssue? issue]) {
    _status = status;
    _issue = issue;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------------------------
  // Readings → places

  void _onReading(TrackedPoint reading) {
    if (!isActive) return;
    final place = _filter.add(reading);
    if (place != null) unawaited(_recordPlace(place));
    _scheduleStayCheck();
  }

  /// A stationary phone reports nothing, so a timer decides when a stop has lasted long enough.
  void _scheduleStayCheck() {
    _stayTimer?.cancel();
    _stayTimer = null;
    final wait = _filter.timeUntilStay(_clock());
    if (wait == null) return;
    _stayTimer = Timer(wait + const Duration(seconds: 1), () => unawaited(_onStayTimer(_generation)));
  }

  Future<void> _onStayTimer(int generation) async {
    _stayTimer = null;
    if (generation != _generation || !isActive || !_filter.hasPendingStop) return;
    // The OS may have taken the permission away while the app was in the background.
    if (!await _stillAllowed(generation)) return;

    // One fresh reading confirms the phone is really still there (and not back home, or moving).
    TrackedPoint? place;
    try {
      final fresh = await _source.currentPosition(config);
      if (generation != _generation) return;
      place = _filter.add(fresh);
    } catch (e) {
      debugPrint('Confirming a stop failed: ${e.runtimeType}');
    }
    if (generation != _generation) return;
    place ??= _filter.checkStay(_clock());
    if (place != null) await _recordPlace(place);
    if (generation == _generation) _scheduleStayCheck();
  }

  Future<void> _recordPlace(TrackedPoint place) async {
    final owner = _owner;
    if (owner == null) return;
    final generation = _generation;
    _queue = [..._queue, place];
    if (_queue.length > config.maxQueueLength) _queue = _queue.sublist(_queue.length - config.maxQueueLength);
    await _store.setQueue(owner, _queue);
    await _store.setLastPlace(owner, place);
    if (generation != _generation) return;
    notifyListeners();
    await flush();
  }

  // ---------------------------------------------------------------------------------------------
  // Uploading

  /// Uploads waiting places, oldest first, for the signed-in account only. Stops at the first
  /// network or server problem and retries later; a duplicate answer counts as delivered.
  Future<void> flush() async {
    final owner = _owner;
    if (owner == null || _flushing) return;
    _flushing = true;
    final generation = _generation;
    bool stillOwner() => generation == _generation && _owner == owner && _auth.currentUser?.id == owner;
    try {
      while (_queue.isNotEmpty && stillOwner()) {
        final point = _queue.first;
        if (_clock().toUtc().difference(point.capturedAt) > config.maxQueuedAge) {
          await _dropFirst(owner);
          continue;
        }
        final location = await _describe(point);
        // Checked right before sending, with no wait in between: a place is never sent with
        // another account's token after a logout or account switch.
        if (!stillOwner()) return;
        try {
          final result = await _auth.authorized((token) => _api.saveAutomaticLocation(token, location));
          _uploadFailed = false;
          if (!result.duplicate) {
            _savedCount++;
            _lastSaved = result.record;
          }
          if (!stillOwner()) return;
          await _dropFirst(owner);
        } on ApiException catch (e) {
          if (e.statusCode == 400) {
            // The server refused the point itself (e.g. too old); retrying cannot help.
            await _dropFirst(owner);
            continue;
          }
          // Offline, server unavailable, rate limited or signed out: keep it for later.
          _uploadFailed = true;
          break;
        }
      }
    } finally {
      _flushing = false;
      if (stillOwner()) {
        if (_queue.isEmpty) {
          _retryTimer?.cancel();
          _retryTimer = null;
        } else {
          _scheduleRetry();
        }
        notifyListeners();
      }
    }
  }

  Future<void> _dropFirst(String owner) async {
    _queue = _queue.sublist(1);
    await _store.setQueue(owner, _queue);
    notifyListeners();
  }

  void _scheduleRetry() {
    if (_queue.isEmpty || _retryTimer != null) return;
    final generation = _generation;
    _retryTimer = Timer(config.retryInterval, () {
      _retryTimer = null;
      if (generation == _generation) unawaited(flush());
    });
  }

  /// The place name from the device's own geocoder. Any failure leaves just the coordinates.
  Future<DeviceLocation> _describe(TrackedPoint point) async {
    final location = DeviceLocation(latitude: point.latitude, longitude: point.longitude, capturedAt: point.capturedAt);
    try {
      final placemark = await _places.placemarkAt(point.latitude, point.longitude).timeout(config.placeTimeLimit);
      return placemark == null ? location : location.withPlacemark(placemark);
    } catch (e) {
      // Only the error type: the message may contain the coordinates.
      debugPrint('Place lookup failed: ${e.runtimeType}');
      return location;
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Accounts

  // Login, logout, session expiry and account switches all arrive here. Tracking never carries
  // over from one account to the next.
  void _onAuthChanged() {
    final userId = _auth.currentUser?.id;
    if (userId == _owner) return;
    final previous = _owner;
    _generation++;
    _stopCollecting();
    _retryTimer?.cancel();
    _retryTimer = null;
    _owner = userId;
    _enabled = false;
    _restoring = false;
    _status = AutomaticTrackingStatus.off;
    _issue = null;
    _notificationsBlocked = false;
    _queue = [];
    _uploadFailed = false;
    _savedCount = 0;
    _lastSaved = null;
    _filter.reset();
    // Logging out switches it off and forgets that account's unsent places: signing in again
    // means switching it on again.
    if (previous != null) unawaited(_store.clear(previous));
    if (userId != null) unawaited(_restore(userId, _generation));
    notifyListeners();
  }

  /// After sign-in or an app restart: resumes tracking if this account switched it on and the OS
  /// still allows it; otherwise shows that it needs attention. Never asks for a permission.
  Future<void> _restore(String userId, int generation) async {
    _restoring = true;
    try {
      final enabled = await _store.isEnabled(userId);
      final queue = await _store.queue(userId);
      final lastPlace = await _store.lastPlace(userId);
      if (generation != _generation) return;
      _enabled = enabled;
      _queue = queue;
      _filter.reset(lastSaved: lastPlace);
      if (enabled) await _startIfAllowed(generation);
    } finally {
      if (_owner == userId) {
        _restoring = false;
        notifyListeners();
      }
    }
    if (generation == _generation && _queue.isNotEmpty) unawaited(flush());
  }

  /// Mirrors an OS permission result to the account, as the Permissions screen does.
  Future<void> _report(AppPermission permission, PermissionState state) async {
    try {
      await _permissionSync?.report(permission, state, fromRequest: true);
    } catch (_) {
      // A sync failure must never affect tracking.
    }
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    _generation++;
    _stopCollecting();
    _retryTimer?.cancel();
    super.dispose();
  }
}
