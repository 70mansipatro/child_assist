import 'dart:math' as math;

/// What Automatic Location History is really doing right now. Always worked out from the OS
/// (permissions, location services, the running location stream), never just from the saved
/// "on" preference.
enum AutomaticTrackingStatus {
  /// Switched off by the user (or never switched on).
  off,

  /// Asking for permissions or starting the location service.
  starting,

  /// Collecting significant places; on Android the "tracking your location history"
  /// notification is showing.
  active,

  /// Switched on, but location services (GPS) are turned off on the device.
  paused,

  /// Switched on, but the OS no longer allows background location. Nothing is collected until
  /// the user allows it again.
  permissionRequired,

  /// The location service could not start or stopped unexpectedly.
  error,
}

/// Why tracking is not active although it is switched on.
enum TrackingIssue {
  /// "While using the app" location access is missing.
  locationPermission,

  /// "Allow all the time" (background) location access is missing.
  backgroundPermission,

  /// Location access is blocked by device policy (e.g. parental controls).
  restricted,

  /// Location services are turned off on the device.
  servicesDisabled,

  /// The platform could not start background location.
  startFailed,

  /// Background location is not available on this platform.
  unsupported,
}

/// The rules that decide which readings become saved places. Kept in one place so they can be
/// tuned without touching the tracking logic. The server repeats the distance and time checks
/// (AUTO_LOCATION_MIN_DISTANCE_METERS / AUTO_LOCATION_MIN_INTERVAL_SECONDS) against duplicates.
class AutomaticTrackingConfig {
  const AutomaticTrackingConfig({
    this.minimumDistanceMeters = 100,
    this.minimumStay = const Duration(minutes: 5),
    this.maximumAccuracyMeters = 150,
    this.streamDistanceFilterMeters = 50,
    this.streamInterval = const Duration(minutes: 1),
    this.confirmTimeLimit = const Duration(seconds: 30),
    this.placeTimeLimit = const Duration(seconds: 10),
    this.retryInterval = const Duration(minutes: 5),
    this.maxQueueLength = 200,
    this.maxQueuedAge = const Duration(days: 7),
  });

  /// Readings closer than this to the last saved place are the same place (GPS drift, moving
  /// around inside a building). Also the radius of a stop.
  final double minimumDistanceMeters;

  /// How long the phone must stay within [minimumDistanceMeters] of a new spot before it is saved
  /// as a place. Passing through (driving, walking) is never saved, and saved places are always at
  /// least this far apart in time.
  final Duration minimumStay;

  /// Readings less accurate than this (e.g. a rough cell-tower fix) are ignored.
  final double maximumAccuracyMeters;

  /// The OS only reports a new reading after the phone moved this far. Stationary phones get no
  /// updates at all, which is what keeps battery use low.
  final double streamDistanceFilterMeters;

  /// The fastest the OS is asked to report readings while moving (Android).
  final Duration streamInterval;

  /// Limit for the one fresh reading taken to confirm a stop.
  final Duration confirmTimeLimit;

  /// Limit for the device geocoder; after it the place is saved with coordinates only.
  final Duration placeTimeLimit;

  /// How often unsent places are retried while the phone is offline or the server is down.
  final Duration retryInterval;

  /// At most this many unsent places are kept on the phone; the oldest are dropped first.
  final int maxQueueLength;

  /// Unsent places older than this are dropped (the server refuses them as well).
  final Duration maxQueuedAge;
}

/// One location reading: just coordinates, time and accuracy. This is all that is kept on the
/// phone while a place waits to be uploaded; the place name is looked up when it is sent.
class TrackedPoint {
  const TrackedPoint({required this.latitude, required this.longitude, required this.capturedAt, this.accuracy});

  final double latitude;
  final double longitude;

  /// UTC.
  final DateTime capturedAt;

  /// Metres, if the device reported it. Not stored in the upload queue.
  final double? accuracy;

  TrackedPoint copyWith({DateTime? capturedAt}) =>
      TrackedPoint(latitude: latitude, longitude: longitude, capturedAt: capturedAt ?? this.capturedAt, accuracy: accuracy);

  /// For the on-device queue: only latitude, longitude and capturedAt (the source is always automatic).
  Map<String, Object> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
    'capturedAt': capturedAt.toUtc().toIso8601String(),
  };

  /// Null for anything malformed.
  static TrackedPoint? fromJson(Object? json) {
    if (json is! Map) return null;
    final lat = json['latitude'], lng = json['longitude'], at = json['capturedAt'];
    final capturedAt = at is String ? DateTime.tryParse(at) : null;
    if (lat is! num || lng is! num || capturedAt == null) return null;
    if (lat.abs() > 90 || lng.abs() > 180) return null;
    return TrackedPoint(latitude: lat.toDouble(), longitude: lng.toDouble(), capturedAt: capturedAt.toUtc());
  }

  @override
  bool operator ==(Object other) =>
      other is TrackedPoint && other.latitude == latitude && other.longitude == longitude && other.capturedAt == capturedAt;

  @override
  int get hashCode => Object.hash(latitude, longitude, capturedAt);

  // Never printed with coordinates, so a stray log line cannot leak a location.
  @override
  String toString() => 'TrackedPoint(at $capturedAt)';
}

/// Great-circle distance in metres (haversine).
double distanceBetween(TrackedPoint a, TrackedPoint b) {
  const earthRadius = 6371008.8;
  double rad(double degrees) => degrees * math.pi / 180;
  final dLat = rad(b.latitude - a.latitude);
  final dLng = rad(b.longitude - a.longitude);
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(a.latitude)) * math.cos(rad(b.latitude)) * math.pow(math.sin(dLng / 2), 2);
  return 2 * earthRadius * math.asin(math.min(1, math.sqrt(h)));
}
