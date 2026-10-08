import 'dart:math' as math;

import '../../chat/models/chat_photo.dart';
import '../models/photo_item.dart';

/// Why a search found nothing strong enough to show.
enum PhotoNoMatchReason {
  /// Location matching was asked for, but there are no saved places for that time.
  noVisits,

  /// Only the photo's content was described, and photos are not searched by content.
  contentOnly,

  /// No photo's file name has the words asked for.
  noNameMatch;

  String get wire => switch (this) {
        noVisits => 'no_visits',
        contentOnly => 'content_only',
        noNameMatch => 'no_name_match',
      };
}

class PhotoMatchResult {
  const PhotoMatchResult(this.matches, {this.total = 0, this.reason});

  /// The strong matches to show, strongest first (at most [PhotoMatcher.maxShown]).
  final List<ChatPhoto> matches;

  /// How many strong matches there were in all.
  final int total;
  final PhotoNoMatchReason? reason;
}

/// Ranks the user's photos against a chat request, on the phone. Only strong matches are kept:
/// a photo is never offered just because one weak signal points at it.
///
/// - Date: the photo was taken in the requested period (a hard filter).
/// - Place, with GPS: the photo's own GPS position is within [gpsNearMeters] of a saved place.
///   A photo whose GPS is further away is excluded, even if it was taken at a nearby time.
/// - Place, without GPS: taken within [timeWindow] of a saved place's time. Shown as "around when
///   you were at", never as taken at the place. GPS matches, when there are any, win outright.
/// - File name: every word asked for is in the name.
/// - Content ("the photo with the dog") cannot be matched without looking inside every photo, so
///   it never selects anything by itself.
class PhotoMatcher {
  static const gpsNearMeters = 500.0;
  static const timeWindow = Duration(minutes: 60);
  static const maxShown = 12;

  static const _stopWords = {
    'photo', 'photos', 'pic', 'pics', 'picture', 'pictures', 'image', 'images', 'my', 'the', 'a', //
    'an', 'of', 'from', 'with', 'in', 'at', 'me', 'show', 'send', 'find', 'file', 'named', 'called', 'jpg', 'jpeg', 'png',
  };

  static PhotoMatchResult match(
    List<PhotoItem> photos,
    PhotoSearchQuery query, {
    Map<String, PhotoPosition?> positions = const {},
  }) {
    final hasRange = query.start != null || query.end != null;
    var candidates = photos.where((p) => _inRange(p.createdAt, query)).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    final tokens = nameTokens(query.fileName);
    final narrowed = hasRange || tokens.isNotEmpty || query.locationContext || query.latest;
    if (!narrowed && query.visualHint != null) {
      return const PhotoMatchResult([], reason: PhotoNoMatchReason.contentOnly);
    }

    var evidence = hasRange ? PhotoEvidence.date : PhotoEvidence.recent;
    if (tokens.isNotEmpty) {
      candidates = candidates.where((p) => _nameHas(p.name, tokens)).toList();
      if (candidates.isEmpty) return const PhotoMatchResult([], reason: PhotoNoMatchReason.noNameMatch);
      evidence = PhotoEvidence.name;
    }

    List<ChatPhoto> ranked;
    if (query.locationContext) {
      if (query.visits.isEmpty) return const PhotoMatchResult([], reason: PhotoNoMatchReason.noVisits);
      final byGps = <ChatPhoto>[], byTime = <ChatPhoto>[];
      for (final photo in candidates) {
        final position = positions[photo.id];
        if (position != null) {
          final (visit, meters) = _nearestPlace(position, query.visits);
          // Its own GPS says where it was taken: near a saved place, or not a match at all.
          if (meters <= gpsNearMeters) {
            byGps.add(ChatPhoto(item: photo, evidence: PhotoEvidence.gps, visit: visit, distanceMeters: meters));
          }
        } else {
          final (visit, gap) = _nearestTime(photo.createdAt, query.visits);
          if (gap <= timeWindow) byTime.add(ChatPhoto(item: photo, evidence: PhotoEvidence.time, visit: visit, timeGap: gap));
        }
      }
      byGps.sort((a, b) => a.distanceMeters!.compareTo(b.distanceMeters!));
      byTime.sort((a, b) => a.timeGap!.compareTo(b.timeGap!));
      ranked = byGps.isNotEmpty ? byGps : byTime;
    } else {
      ranked = [for (final p in candidates) ChatPhoto(item: p, evidence: evidence)];
    }

    if (query.latest && ranked.isNotEmpty) {
      ranked.sort((a, b) => b.item.createdAt.compareTo(a.item.createdAt));
      final newest = ranked.first;
      return PhotoMatchResult(
        [ChatPhoto(item: newest.item, evidence: query.locationContext ? newest.evidence : PhotoEvidence.latest, visit: newest.visit, distanceMeters: newest.distanceMeters, timeGap: newest.timeGap)],
        total: 1,
      );
    }
    return PhotoMatchResult(ranked.take(maxShown).toList(), total: ranked.length);
  }

  /// The words of [text] that could be in a file name ("IMG_2041" -> img, 2041).
  static List<String> nameTokens(String? text) {
    if (text == null) return const [];
    return text
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((w) => w.length >= 2 && !_stopWords.contains(w))
        .toList();
  }

  static bool _inRange(DateTime t, PhotoSearchQuery q) {
    if (q.start != null && t.isBefore(q.start!)) return false;
    if (q.end != null && !t.isBefore(q.end!)) return false;
    return true;
  }

  static bool _nameHas(String? name, List<String> tokens) {
    if (name == null) return false;
    final normalized = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
    return tokens.every(normalized.contains);
  }

  static (PhotoVisit, double) _nearestPlace(PhotoPosition p, List<PhotoVisit> visits) {
    var best = visits.first;
    var bestMeters = double.infinity;
    for (final v in visits) {
      final d = distanceMeters(p.latitude, p.longitude, v.latitude, v.longitude);
      if (d < bestMeters) {
        best = v;
        bestMeters = d;
      }
    }
    return (best, bestMeters);
  }

  static (PhotoVisit, Duration) _nearestTime(DateTime t, List<PhotoVisit> visits) {
    var best = visits.first;
    var bestGap = t.difference(best.capturedAt).abs();
    for (final v in visits.skip(1)) {
      final gap = t.difference(v.capturedAt).abs();
      if (gap < bestGap) {
        best = v;
        bestGap = gap;
      }
    }
    return (best, bestGap);
  }

  /// Great-circle distance in metres.
  static double distanceMeters(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
    final a = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
    return 2 * r * math.asin(math.sqrt(a.toDouble()));
  }
}
