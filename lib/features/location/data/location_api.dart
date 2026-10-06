import '../../../core/api/api_client.dart';
import '../models/location_record.dart';
import '../services/location_service.dart';

/// Raw calls to the backend's /api/location endpoints. The server identifies the user
/// from the token, so no user ID is ever sent.
class LocationApi {
  LocationApi(this._client);

  final ApiClient _client;

  Future<LocationRecord> saveLocation(String token, DeviceLocation location) async {
    final json = await _client.post('/api/location', token: token, body: {
      'latitude': location.latitude,
      'longitude': location.longitude,
      if (location.accuracy != null) 'accuracy': location.accuracy,
      'placeName': _limit(location.placeName, 255),
      'address': _limit(location.address, 1000),
      'street': _limit(location.street, 255),
      'locality': _limit(location.locality, 255),
      'city': _limit(location.city, 255),
      'state': _limit(location.state, 255),
      'postalCode': _limit(location.postalCode, 32),
      'country': _limit(location.country, 255),
      'capturedAt': location.capturedAt.toUtc().toIso8601String(),
    });
    return LocationRecord.fromJson(json['location'] as Map<String, dynamic>);
  }

  /// The user's own locations, newest first.
  Future<List<LocationRecord>> getHistory(String token, {int limit = 50}) async {
    final json = await _client.get('/api/location/history?limit=$limit', token: token);
    final records = json['locations'];
    if (records is! List) return [];
    final result = <LocationRecord>[];
    for (final record in records.whereType<Map<String, dynamic>>()) {
      try {
        result.add(LocationRecord.fromJson(record));
      } on FormatException {
        // Skip a malformed entry rather than hiding the whole history.
      }
    }
    return result;
  }

  /// Deletes all of the user's saved locations; returns how many were removed.
  Future<int> clearHistory(String token) async {
    final json = await _client.delete('/api/location/history', token: token);
    return (json['deleted'] as num?)?.toInt() ?? 0;
  }

  // Geocoder text is device-provided; trim it to the server's limits rather than lose the
  // whole location to a validation error.
  static String? _limit(String? value, int max) =>
      value == null || value.length <= max ? value : value.substring(0, max);
}
