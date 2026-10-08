/// A photo in the device gallery, described by metadata only. The image itself stays on the
/// device and is read through `PhotoGalleryService` when it needs to be shown.
class PhotoItem {
  const PhotoItem({
    required this.id,
    required this.width,
    required this.height,
    required this.createdAt,
    required this.modifiedAt,
    this.name,
    this.mimeType,
    this.fileSize,
  });

  /// The platform's identifier for the photo (Android MediaStore ID, iOS localIdentifier).
  final String id;

  /// File name, e.g. "IMG_1234.jpg", when the platform provides one.
  final String? name;

  /// Pixel dimensions; 0 when the platform does not know them.
  final int width;
  final int height;

  final DateTime createdAt;
  final DateTime modifiedAt;

  /// e.g. "image/jpeg"; null when the platform does not report it.
  final String? mimeType;

  /// Size in bytes. Only filled in by `PhotoGalleryService.details`, since it costs a lookup.
  final int? fileSize;

  bool get hasDimensions => width > 0 && height > 0;

  /// The metadata with the per-photo details (name, type, size) filled in where known.
  PhotoItem withDetails({String? name, String? mimeType, int? fileSize}) => PhotoItem(
        id: id,
        width: width,
        height: height,
        createdAt: createdAt,
        modifiedAt: modifiedAt,
        name: name ?? this.name,
        mimeType: mimeType ?? this.mimeType,
        fileSize: fileSize ?? this.fileSize,
      );

  /// Metadata only, for later features (e.g. the assistant listing photos by date or name).
  /// Never contains image data or file paths.
  Map<String, dynamic> toJson() => {
        'id': id,
        if (name != null) 'name': name,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'modifiedAt': modifiedAt.toUtc().toIso8601String(),
        if (hasDimensions) 'width': width,
        if (hasDimensions) 'height': height,
        if (mimeType != null) 'mimeType': mimeType,
        if (fileSize != null) 'fileSize': fileSize,
      };
}

/// A GPS position stored in a photo's own metadata.
class PhotoPosition {
  const PhotoPosition(this.latitude, this.longitude);

  final double latitude;
  final double longitude;

  /// A real position, or null for a missing, out-of-range or 0,0 value (which platforms report
  /// when a photo has no GPS data, or when the OS hides it).
  static PhotoPosition? tryCreate(double? latitude, double? longitude) {
    if (latitude == null || longitude == null) return null;
    if (latitude.isNaN || longitude.isNaN) return null;
    if (latitude.abs() > 90 || longitude.abs() > 180) return null;
    if (latitude == 0 && longitude == 0) return null;
    return PhotoPosition(latitude, longitude);
  }
}
