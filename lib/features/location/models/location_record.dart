import 'device_location.dart' show joinParts;

/// How a location was saved.
enum LocationSource {
  /// The user tapped "Get Current Location".
  manual('MANUAL'),

  /// Saved by Automatic Location History.
  automatic('AUTOMATIC');

  const LocationSource(this.apiValue);

  final String apiValue;

  /// Records from before automatic history existed have no source and were all manual.
  static LocationSource fromApi(Object? value) => value == 'AUTOMATIC' ? automatic : manual;
}

/// A saved location from GET/POST /api/location.
class LocationRecord {
  const LocationRecord({
    required this.id,
    required this.latitude,
    required this.longitude,
    this.accuracy,
    this.placeName,
    this.address,
    this.street,
    this.locality,
    this.city,
    this.state,
    this.postalCode,
    this.country,
    required this.capturedAt,
    this.source = LocationSource.manual,
  });

  final String id;
  final double latitude;
  final double longitude;

  /// Accuracy radius in metres, or null if the device did not report one.
  final double? accuracy;

  /// Place details from the device's geocoder at the time; any may be null.
  final String? placeName;
  final String? address;
  final String? street;
  final String? locality;
  final String? city;
  final String? state;
  final String? postalCode;
  final String? country;

  /// When the device took the reading, in local time.
  final DateTime capturedAt;

  final LocationSource source;

  bool get isAutomatic => source == LocationSource.automatic;

  /// Area line under the place name, e.g. "Bhubaneswar, Odisha, India".
  String? get areaLine => joinParts([city, state, country], exclude: [placeName]);

  /// Throws [FormatException] if a required field is missing or malformed.
  factory LocationRecord.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final capturedAt = json['capturedAt'] is String ? DateTime.tryParse(json['capturedAt'] as String) : null;
    final latitude = _toDouble(json['latitude']);
    final longitude = _toDouble(json['longitude']);
    if (id is! String || id.isEmpty || latitude == null || longitude == null || capturedAt == null) {
      throw FormatException('Invalid location record', json);
    }
    return LocationRecord(
      id: id,
      latitude: latitude,
      longitude: longitude,
      accuracy: _toDouble(json['accuracy']),
      placeName: _text(json['placeName']),
      address: _text(json['address']),
      street: _text(json['street']),
      locality: _text(json['locality']),
      city: _text(json['city']),
      state: _text(json['state']),
      postalCode: _text(json['postalCode']),
      country: _text(json['country']),
      capturedAt: capturedAt.toLocal(),
      source: LocationSource.fromApi(json['source']),
    );
  }

  // Accepts numbers, and numeric strings in case decimals are ever serialised as text.
  static double? _toDouble(Object? value) => switch (value) {
        num n => n.toDouble(),
        String s => double.tryParse(s),
        _ => null,
      };

  static String? _text(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  String toString() => 'LocationRecord($id: ${placeName ?? '$latitude, $longitude'} at $capturedAt)';
}
