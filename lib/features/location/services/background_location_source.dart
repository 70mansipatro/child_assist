import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../models/automatic_tracking.dart';

/// Location readings for Automatic Location History. Separated out so tests never need real GPS.
abstract class BackgroundLocationSource {
  /// Whether this platform can collect location in the background at all.
  bool get isSupported;

  Future<bool> isServiceEnabled();

  /// Readings while the app runs, including in the background. On Android, listening starts a
  /// foreground service with a persistent notification; cancelling the subscription stops both.
  /// Errors (permission revoked, location turned off) arrive as stream errors.
  Stream<TrackedPoint> positions(AutomaticTrackingConfig config);

  /// One fresh reading, used to confirm a stop. May throw.
  Future<TrackedPoint> currentPosition(AutomaticTrackingConfig config);
}

/// Uses geolocator's own Android foreground service and iOS background updates; no other
/// location package and no API key. Battery-conscious: balanced accuracy, and the OS only reports
/// a reading after the phone has moved [AutomaticTrackingConfig.streamDistanceFilterMeters].
class GeolocatorBackgroundLocationSource implements BackgroundLocationSource {
  static bool get _isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static bool get _isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  @override
  bool get isSupported => _isAndroid || _isIOS;

  @override
  Future<bool> isServiceEnabled() => Geolocator.isLocationServiceEnabled();

  @override
  Stream<TrackedPoint> positions(AutomaticTrackingConfig config) {
    final LocationSettings settings;
    if (_isAndroid) {
      settings = AndroidSettings(
        // On Android 12+ this is the platform's fused provider at balanced power (Wi-Fi/cell,
        // GPS only when needed), without Play services' extra "Location Accuracy" prompt.
        accuracy: LocationAccuracy.medium,
        distanceFilter: config.streamDistanceFilterMeters.round(),
        intervalDuration: config.streamInterval,
        forceLocationManager: true,
        // Required by Android for location while the app is not open: an OS-visible, ongoing
        // notification for as long as tracking runs. It disappears when tracking stops.
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Automatic Location History is on',
          notificationText: 'Child Assist is tracking your location history. Turn it off in the Location tab.',
          notificationChannelName: 'Automatic Location History',
          setOngoing: true,
          // No wake lock: while the screen is off the OS may deliver readings in batches, which
          // saves battery and is fine for finding places the user stayed at.
          enableWakeLock: false,
        ),
      );
    } else if (_isIOS) {
      settings = AppleSettings(
        accuracy: LocationAccuracy.medium,
        distanceFilter: config.streamDistanceFilterMeters.round(),
        activityType: ActivityType.other,
        pauseLocationUpdatesAutomatically: true,
        allowBackgroundLocationUpdates: true,
        // The blue status-bar indicator while the app uses location in the background.
        showBackgroundLocationIndicator: true,
      );
    } else {
      return Stream.error(UnsupportedError('Background location is not supported on this platform'));
    }
    return Geolocator.getPositionStream(locationSettings: settings).map(_toPoint);
  }

  @override
  Future<TrackedPoint> currentPosition(AutomaticTrackingConfig config) async {
    final position = await Geolocator.getCurrentPosition(
      locationSettings: _isAndroid
          ? AndroidSettings(accuracy: LocationAccuracy.medium, timeLimit: config.confirmTimeLimit, forceLocationManager: true)
          : LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: config.confirmTimeLimit),
    );
    return _toPoint(position);
  }

  static TrackedPoint _toPoint(Position position) => TrackedPoint(
    latitude: position.latitude,
    longitude: position.longitude,
    accuracy: position.accuracy > 0 ? position.accuracy : null,
    capturedAt: position.timestamp.toUtc(),
  );
}
