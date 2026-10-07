import '../models/automatic_tracking.dart';

/// Turns a stream of location readings into the places worth saving.
///
/// A reading near the last saved place is the same place and is ignored, so staying at Home all
/// day saves Home once. A reading far enough away starts a possible stop; it becomes a saved place
/// only when the phone stays within [AutomaticTrackingConfig.minimumDistanceMeters] of it for
/// [AutomaticTrackingConfig.minimumStay]. Driving or walking past somewhere therefore saves
/// nothing, and the place is saved with the time the phone arrived there.
///
/// Pure logic with no timers or I/O: the tracking service feeds readings in with [add] and calls
/// [checkStay] when time has passed without new readings (a stationary phone reports nothing).
class TravelPointFilter {
  TravelPointFilter(this.config, {TrackedPoint? lastSaved}) : _anchor = lastSaved;

  final AutomaticTrackingConfig config;

  TrackedPoint? _anchor;
  TrackedPoint? _candidate;
  DateTime? _candidateSince;

  /// The last saved place, which new readings are compared with.
  TrackedPoint? get lastSaved => _anchor;

  /// When the possible stop began, or null if the phone is at the last saved place.
  DateTime? get pendingSince => _candidateSince;

  bool get hasPendingStop => _candidate != null;

  /// How long until the possible stop counts as a place, measured from [now].
  Duration? timeUntilStay(DateTime now) {
    final since = _candidateSince;
    if (since == null) return null;
    final left = config.minimumStay - now.difference(since);
    return left.isNegative ? Duration.zero : left;
  }

  /// Takes one reading; returns the place to save now, or null.
  TrackedPoint? add(TrackedPoint reading) {
    final accuracy = reading.accuracy;
    if (accuracy != null && accuracy > config.maximumAccuracyMeters) return null;

    final anchor = _anchor;
    if (anchor == null) {
      // Where the user is when tracking starts is the first place.
      _anchor = reading;
      _clearCandidate();
      return reading;
    }
    if (distanceBetween(reading, anchor) < config.minimumDistanceMeters) {
      // Still (or back) at the last saved place.
      _clearCandidate();
      return null;
    }

    final candidate = _candidate;
    if (candidate == null || distanceBetween(reading, candidate) >= config.minimumDistanceMeters) {
      // Moved on: a new possible stop starts here.
      _candidate = reading;
      _candidateSince = reading.capturedAt;
    } else if ((reading.accuracy ?? double.infinity) < (candidate.accuracy ?? double.infinity)) {
      // Same stop, better reading: keep the better coordinates but the arrival time.
      _candidate = reading;
    }
    return checkStay(reading.capturedAt);
  }

  /// The pending stop as a place to save, once the phone has stayed there long enough by [now].
  TrackedPoint? checkStay(DateTime now) {
    final candidate = _candidate, since = _candidateSince;
    if (candidate == null || since == null) return null;
    if (now.difference(since) < config.minimumStay) return null;
    final place = candidate.copyWith(capturedAt: since);
    _anchor = place;
    _clearCandidate();
    return place;
  }

  /// Forgets everything, e.g. when tracking stops for another account.
  void reset({TrackedPoint? lastSaved}) {
    _anchor = lastSaved;
    _clearCandidate();
  }

  void _clearCandidate() {
    _candidate = null;
    _candidateSince = null;
  }
}
