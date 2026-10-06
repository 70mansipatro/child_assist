import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart' show Geocoding, Placemark;
import 'package:geolocator/geolocator.dart';

import '../../../core/permissions/permission_service.dart';
import '../models/device_location.dart';

export '../models/device_location.dart';

/// Why a location could not be read.
enum LocationFailure {
  servicesDisabled,
  permissionDenied,
  permissionPermanentlyDenied,
  permissionRestricted,
  unavailable,
  timeout,
}

/// Outcome of [LocationService.getCurrentLocation]: either [location] or [failure] is set.
class LocationResult {
  const LocationResult.success(DeviceLocation this.location, {required this.permission})
      : failure = null;

  const LocationResult.failure(LocationFailure this.failure, {required this.permission})
      : location = null;

  final DeviceLocation? location;
  final LocationFailure? failure;

  /// The OS permission state seen during this attempt, or null if it was never checked
  /// (location services were off).
  final PermissionState? permission;

  bool get isSuccess => location != null;
}

/// Access to the location hardware. Separated out so tests never need real GPS.
abstract class LocationProvider {
  Future<bool> isServiceEnabled();

  /// Reads the current position. May throw [TimeoutException] or a geolocator exception.
  Future<DeviceLocation> currentPosition({required Duration timeLimit});

  /// Opens the device's location settings page. Returns false if that is not possible.
  Future<bool> openLocationSettings();
}

class GeolocatorLocationProvider implements LocationProvider {
  @override
  Future<bool> isServiceEnabled() => Geolocator.isLocationServiceEnabled();

  @override
  Future<DeviceLocation> currentPosition({required Duration timeLimit}) async {
    final position = await Geolocator.getCurrentPosition(
      locationSettings: !kIsWeb && defaultTargetPlatform == TargetPlatform.android
          // The platform LocationManager rather than Play services' fused provider, which shows
          // an extra "Location Accuracy" prompt and fails outright if the user declines it.
          ? AndroidSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: timeLimit,
              forceLocationManager: true,
            )
          : LocationSettings(accuracy: LocationAccuracy.high, timeLimit: timeLimit),
    );
    return DeviceLocation(
      latitude: position.latitude,
      longitude: position.longitude,
      // Geolocator reports 0 when the platform gives no accuracy.
      accuracy: position.accuracy > 0 ? position.accuracy : null,
      capturedAt: position.timestamp.toUtc(),
    );
  }

  @override
  Future<bool> openLocationSettings() async {
    try {
      return await Geolocator.openLocationSettings();
    } catch (_) {
      return false;
    }
  }
}

/// Turns coordinates into a place using the platform's own geocoder (Android Geocoder,
/// iOS CLGeocoder). No external service or API key is involved.
abstract class PlaceLookup {
  /// The best match for the coordinates, or null if there is none. May throw.
  Future<Placemark?> placemarkAt(double latitude, double longitude);
}

class NativePlaceLookup implements PlaceLookup {
  // Created on first use: the constructor throws on platforms without a geocoder plugin,
  // and that must surface as a failed lookup, not as a crash while the app starts.
  Geocoding? _geocoding;

  @override
  Future<Placemark?> placemarkAt(double latitude, double longitude) async {
    final geocoding = _geocoding ??= Geocoding();
    // Sorted by relevance: the first entry is nearest to the coordinates.
    final placemarks = await geocoding.placemarkFromCoordinates(latitude, longitude);
    return placemarks.isEmpty ? null : placemarks.first;
  }
}

/// Reads the device's current location, foreground only and only when asked.
///
/// Permission checks and requests go through the shared [PermissionService], so the
/// OS dialog is shown only from [getCurrentLocation], which the UI calls when the user
/// taps a button. Never throws: every problem is reported as a [LocationFailure].
class LocationService {
  LocationService({
    required PermissionService permissionService,
    LocationProvider? provider,
    PlaceLookup? placeLookup,
    this.timeLimit = const Duration(seconds: 20),
    this.placeTimeLimit = const Duration(seconds: 10),
  })  : _permissions = permissionService,
        _provider = provider ?? GeolocatorLocationProvider(),
        _places = placeLookup ?? NativePlaceLookup();

  final PermissionService _permissions;
  final LocationProvider _provider;
  final PlaceLookup _places;
  final Duration timeLimit;
  final Duration placeTimeLimit;

  /// Current OS permission state, without showing any dialog.
  Future<PermissionState> permissionStatus() => _permissions.locationStatus();

  Future<bool> isServiceEnabled() async {
    try {
      return await _provider.isServiceEnabled();
    } catch (e) {
      debugPrint('Location service check failed: $e');
      return false;
    }
  }

  /// Checks location services, requests the permission if the OS still allows asking,
  /// reads one position, then looks up the place it is in.
  Future<LocationResult> getCurrentLocation() async {
    if (!await isServiceEnabled()) {
      return const LocationResult.failure(LocationFailure.servicesDisabled, permission: null);
    }

    final permission = await _permissions.requestLocationPermission();
    final denied = switch (permission) {
      PermissionState.granted || PermissionState.limited => null,
      PermissionState.denied => LocationFailure.permissionDenied,
      PermissionState.permanentlyDenied => LocationFailure.permissionPermanentlyDenied,
      PermissionState.restricted => LocationFailure.permissionRestricted,
      PermissionState.unavailable => LocationFailure.unavailable,
    };
    if (denied != null) return LocationResult.failure(denied, permission: permission);

    final DeviceLocation location;
    try {
      location = await _provider.currentPosition(timeLimit: timeLimit);
    } on TimeoutException {
      return LocationResult.failure(LocationFailure.timeout, permission: permission);
    } on LocationServiceDisabledException {
      return LocationResult.failure(LocationFailure.servicesDisabled, permission: permission);
    } on PermissionDeniedException {
      return LocationResult.failure(LocationFailure.permissionDenied, permission: permission);
    } catch (e) {
      debugPrint('Reading location failed: $e');
      return LocationResult.failure(LocationFailure.unavailable, permission: permission);
    }
    return LocationResult.success(await _withPlace(location), permission: permission);
  }

  /// Adds the place to [location]. A failed or empty lookup is not an error: the
  /// coordinates are still valid and are returned without a place.
  Future<DeviceLocation> _withPlace(DeviceLocation location) async {
    try {
      final placemark =
          await _places.placemarkAt(location.latitude, location.longitude).timeout(placeTimeLimit);
      return placemark == null ? location : location.withPlacemark(placemark);
    } catch (e) {
      // Only the error type: the message may contain the coordinates.
      debugPrint('Place lookup failed: ${e.runtimeType}');
      return location;
    }
  }

  Future<bool> openLocationSettings() => _provider.openLocationSettings();

  Future<bool> openAppSettings() => _permissions.openSettings();
}
