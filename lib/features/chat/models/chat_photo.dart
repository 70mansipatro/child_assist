import '../../photos/models/photo_item.dart';

/// One of the user's own saved places, sent by the server so this phone can match photos to
/// "where I went". Already the user's own data; it is only compared, never stored.
class PhotoVisit {
  const PhotoVisit({required this.capturedAt, required this.latitude, required this.longitude, this.placeName});

  final DateTime capturedAt;
  final double latitude;
  final double longitude;
  final String? placeName;

  /// The name to show, falling back to coordinates.
  String get label =>
      placeName?.trim().isNotEmpty == true ? placeName!.trim() : '${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)}';

  static PhotoVisit? tryParse(Map<String, dynamic> json) {
    final at = DateTime.tryParse(json['capturedAt'] as String? ?? '');
    final lat = json['latitude'], lng = json['longitude'];
    if (at == null || lat is! num || lng is! num) return null;
    return PhotoVisit(
      capturedAt: at,
      latitude: lat.toDouble(),
      longitude: lng.toDouble(),
      placeName: json['placeName'] is String ? json['placeName'] as String : null,
    );
  }
}

/// What the assistant asked this phone to search its gallery for. Nothing found is sent back
/// except the metadata of the photos actually shown.
class PhotoSearchQuery {
  const PhotoSearchQuery({
    this.fileName,
    this.visualHint,
    this.start,
    this.end,
    this.locationContext = false,
    this.latest = false,
    this.visits = const [],
  });

  /// Words that should be in the photo's file name.
  final String? fileName;

  /// What the user says is in the photo. Photos are not searched by content; this only explains.
  final String? visualHint;
  final DateTime? start;

  /// Exclusive.
  final DateTime? end;

  /// Match photos to the user's own saved places ([visits]).
  final bool locationContext;
  final bool latest;
  final List<PhotoVisit> visits;

  factory PhotoSearchQuery.fromEvent(Map<String, dynamic> data) {
    final query = data['query'] is Map<String, dynamic> ? data['query'] as Map<String, dynamic> : const <String, dynamic>{};
    String? text(String key) => query[key] is String && (query[key] as String).trim().isNotEmpty ? (query[key] as String).trim() : null;
    final rawVisits = data['visits'];
    return PhotoSearchQuery(
      fileName: text('fileName'),
      visualHint: text('visualHint'),
      start: DateTime.tryParse(query['startDate'] as String? ?? ''),
      end: DateTime.tryParse(query['endDate'] as String? ?? ''),
      locationContext: query['locationContext'] == true,
      latest: query['latest'] == true,
      visits: rawVisits is List
          ? [for (final v in rawVisits.whereType<Map<String, dynamic>>()) ?PhotoVisit.tryParse(v)]
          : const [],
    );
  }
}

/// Why a photo matched. Only [gps] says it was taken AT a place; [time] only says it was taken
/// around the time the user was there.
enum PhotoEvidence { gps, time, date, name, latest, recent }

/// A photo shown in chat: the gallery entry (which never leaves the phone), the server's opaque
/// id for it once reported, and why it matched.
class ChatPhoto {
  const ChatPhoto({required this.item, required this.evidence, this.id, this.visit, this.distanceMeters, this.timeGap});

  /// The server's opaque id (photo_...). Null until the search was reported.
  final String? id;
  final PhotoItem item;
  final PhotoEvidence evidence;

  /// The saved place it was matched to, for [PhotoEvidence.gps] and [PhotoEvidence.time].
  final PhotoVisit? visit;
  final double? distanceMeters;
  final Duration? timeGap;

  ChatPhoto withId(String id) =>
      ChatPhoto(id: id, item: item, evidence: evidence, visit: visit, distanceMeters: distanceMeters, timeGap: timeGap);

  /// "Near Patia" (GPS) or "Around when you were at Patia" (time), or null.
  String? get placeLine => switch (evidence) {
        PhotoEvidence.gps when visit != null => 'Taken near ${visit!.label}',
        PhotoEvidence.time when visit != null => 'Taken around when you were at ${visit!.label}',
        _ => null,
      };

  /// Metadata reported to the server for a shown photo: never a path, URI, device id or file name.
  Map<String, dynamic> toReport() => {
        'capturedAt': item.createdAt.toUtc().toIso8601String(),
        if (item.hasDimensions) 'width': item.width,
        if (item.hasDimensions) 'height': item.height,
        if (visit != null && (evidence == PhotoEvidence.gps || evidence == PhotoEvidence.time))
          'place': {'name': _safePlace(visit!.label), 'evidence': evidence.name},
      };

  static String _safePlace(String name) {
    final clean = name.replaceAll(RegExp(r'[\u0000-\u001f\u007f<>"]'), ' ').trim();
    return clean.length > 120 ? clean.substring(0, 120) : clean;
  }
}
