import 'package:geocoding/geocoding.dart' show Placemark;

/// A single reading from the device: GPS coordinates plus, when the platform's
/// geocoder found one, the place they are in. Any place field may be null.
class DeviceLocation {
  const DeviceLocation({
    required this.latitude,
    required this.longitude,
    this.accuracy,
    this.name,
    this.street,
    this.subLocality,
    this.locality,
    this.subAdministrativeArea,
    this.administrativeArea,
    this.postalCode,
    this.country,
    this.isoCountryCode,
    this.addressLine,
    required this.capturedAt,
  });

  final double latitude;
  final double longitude;

  /// Horizontal accuracy radius in metres, if the device reported one.
  final double? accuracy;

  final String? name;
  final String? street;
  final String? subLocality;
  final String? locality;
  final String? subAdministrativeArea;
  final String? administrativeArea;
  final String? postalCode;
  final String? country;
  final String? isoCountryCode;

  /// The device's own one-line formatted address, when it gave one (Android reports this
  /// as the placemark's "street").
  final String? addressLine;

  final DateTime capturedAt;

  /// This reading with the place fields taken from [placemark]. Blank values become null.
  DeviceLocation withPlacemark(Placemark placemark) {
    // Android puts the whole formatted address ("12, KIIT Rd, Bhubaneswar, Odisha 751024,
    // India") in `street`; the road itself is in the thoroughfare fields.
    final rawStreet = _clean(placemark.street);
    final isAddressLine = rawStreet != null && rawStreet.contains(',');
    return DeviceLocation(
        latitude: latitude,
        longitude: longitude,
        accuracy: accuracy,
        name: _clean(placemark.name),
        street: isAddressLine
            ? _clean([placemark.subThoroughfare, placemark.thoroughfare].whereType<String>().join(' '))
            : rawStreet,
        addressLine: isAddressLine ? rawStreet : null,
        subLocality: _clean(placemark.subLocality),
        locality: _clean(placemark.locality),
        subAdministrativeArea: _clean(placemark.subAdministrativeArea),
        administrativeArea: _clean(placemark.administrativeArea),
        postalCode: _clean(placemark.postalCode),
        country: _clean(placemark.country),
        isoCountryCode: _clean(placemark.isoCountryCode),
        capturedAt: capturedAt,
      );
  }

  /// City-level name: the locality, or the district when there is no locality.
  String? get city => locality ?? subAdministrativeArea;

  /// State / province.
  String? get state => administrativeArea;

  /// The most specific meaningful place name, or null if the geocoder gave nothing usable.
  String? get placeName => firstMeaningful([name, subLocality, locality, subAdministrativeArea, administrativeArea]);

  /// Area line under the place name, e.g. "Bhubaneswar, Odisha, India", without repeating
  /// the place name itself. Null if there is nothing to add.
  String? get areaLine => joinParts([city, state, country], exclude: [placeName]);

  /// Readable full address with blanks and repeats removed, e.g.
  /// "Jayadev Vihar, Bhubaneswar, Odisha, India". Prefers the device's formatted line,
  /// which already contains city, state and country. Null when no place is known.
  String? get address {
    final line = addressLine;
    if (line != null) {
      final place = placeName;
      return place == null || line.toLowerCase().contains(place.toLowerCase()) ? line : '$place, $line';
    }
    return joinParts([placeName, street, subLocality, city, state, country]);
  }

  bool get hasPlace => placeName != null;

  @override
  String toString() => 'DeviceLocation($latitude, $longitude, ±${accuracy ?? '?'} m, '
      '${placeName ?? 'no place'} at $capturedAt)';

  static String? _clean(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}

/// The first value that reads as a place name. Android often reports a bare house number
/// ("221") or a Plus Code ("7MXF+2Q") as the feature name; those are skipped.
String? firstMeaningful(Iterable<String?> candidates) {
  for (final value in candidates) {
    final v = value?.trim();
    if (v == null || v.isEmpty) continue;
    if (RegExp(r'^[\d\s\-/]+$').hasMatch(v)) continue;
    if (RegExp(r'^[23456789CFGHJMPQRVWX]{2,8}\+[23456789CFGHJMPQRVWX]{0,3}\b', caseSensitive: false).hasMatch(v)) {
      continue;
    }
    return v;
  }
  return null;
}

/// Joins the non-empty [parts] with ", ", dropping repeats (case-insensitive) and anything
/// in [exclude]. Returns null when nothing is left.
String? joinParts(Iterable<String?> parts, {Iterable<String?> exclude = const []}) {
  final seen = <String>{for (final e in exclude) if (e != null) e.trim().toLowerCase()};
  final kept = <String>[];
  for (final part in parts) {
    final p = part?.trim();
    if (p == null || p.isEmpty || !seen.add(p.toLowerCase())) continue;
    kept.add(p);
  }
  return kept.isEmpty ? null : kept.join(', ');
}
