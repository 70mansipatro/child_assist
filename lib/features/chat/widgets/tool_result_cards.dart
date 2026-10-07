import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';
import '../../documents/services/document_service.dart';
import '../../documents/widgets/document_card.dart' show DocumentTypeBadge, documentDateText;
import '../../photos/services/photo_gallery_service.dart';
import '../../photos/widgets/photo_grid.dart' show PhotoThumbnail;
import '../models/chat_message.dart';

/// What the result cards need from the screen: the on-device services and navigation.
class ChatResultContext {
  const ChatResultContext({
    required this.documentService,
    required this.galleryService,
    required this.onOpenPermissions,
    required this.onOpenDocuments,
    required this.onOpenDocument,
    required this.onOpenPhoto,
    required this.onConfirmAction,
    required this.onCancelAction,
  });

  final DocumentService documentService;
  final PhotoGalleryService galleryService;
  final VoidCallback onOpenPermissions;
  final VoidCallback onOpenDocuments;
  final ValueChanged<DocumentItem> onOpenDocument;
  final ValueChanged<PhotoItem> onOpenPhoto;
  final ValueChanged<String> onConfirmAction;
  final ValueChanged<String> onCancelAction;
}

/// The card to show under a reply for [event], or null when the text says it all.
Widget? toolResultCard(ChatToolEvent event, ChatResultContext context) {
  if (event.status == ChatToolStatus.permissionRequired) {
    return PermissionRequiredCard(
      permission: event.permission ?? _permissionFor(event.kind),
      kind: event.kind,
      onOpenPermissions: context.onOpenPermissions,
    );
  }
  return switch ((event.kind, event.status)) {
    (ChatToolKind.locationHistory, ChatToolStatus.success) when event.locations.isNotEmpty =>
      LocationResultsCard(places: event.locations),
    (ChatToolKind.documents, ChatToolStatus.deviceLookup) => DocumentResultsCard(query: event.query, results: context),
    (ChatToolKind.photos, ChatToolStatus.deviceLookup) => PhotoResultsCard(query: event.query, results: context),
    _ => null,
  };
}

ChatPermission _permissionFor(ChatToolKind kind) => switch (kind) {
      ChatToolKind.locationHistory || ChatToolKind.currentLocation => ChatPermission.location,
      ChatToolKind.photos => ChatPermission.photos,
      ChatToolKind.documents || ChatToolKind.documentText => ChatPermission.documents,
      _ => ChatPermission.other,
    };

/// "Oct 5, 2026 · 6:30 PM" in the device's locale.
String _dateTimeLabel(BuildContext context, DateTime time) {
  final l10n = MaterialLocalizations.of(context);
  final local = time.toLocal();
  return '${l10n.formatMediumDate(local)} · ${l10n.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
}

/// Explains that a permission is off and links to the Permissions screen. Chat never asks for
/// a permission itself.
class PermissionRequiredCard extends StatelessWidget {
  const PermissionRequiredCard({
    super.key,
    required this.permission,
    required this.kind,
    required this.onOpenPermissions,
  });

  final ChatPermission permission;
  final ChatToolKind kind;
  final VoidCallback onOpenPermissions;

  String get _title => switch (kind) {
        ChatToolKind.locationHistory =>
          "I can't access your location history because Location permission is turned off.",
        ChatToolKind.currentLocation => "I can't access your location because Location permission is turned off.",
        ChatToolKind.photos => "I can't access your photos because Photos permission is turned off.",
        ChatToolKind.documents || ChatToolKind.documentText =>
          "I can't access your documents because Documents access is turned off.",
        _ => '${permission.label} permission is turned off.',
      };

  @override
  Widget build(BuildContext context) {
    return InfoBanner(
      tone: BannerTone.warning,
      icon: Icons.lock_outline_rounded,
      title: _title,
      message: Text('${permission.label} permission is currently turned off. You can enable it from Permissions.'),
      actions: [
        FilledButton.icon(
          onPressed: onOpenPermissions,
          icon: const Icon(Icons.verified_user_rounded, size: 18),
          label: const Text('Open Permissions'),
        ),
      ],
    );
  }
}

/// The user's saved places from a location-history lookup: place, date/time and address.
class LocationResultsCard extends StatelessWidget {
  const LocationResultsCard({super.key, required this.places});

  final List<ChatPlace> places;

  static const _shown = 10;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = places.take(_shown).toList();
    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            places.length == 1 ? '1 place' : '${places.length} places',
            style: theme.textTheme.titleSmall,
          ),
          for (final place in shown)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const IconBadge(icon: Icons.place_rounded, gradient: AppGradients.location, size: 34, iconSize: 18),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(place.title, style: theme.textTheme.titleSmall),
                        Text(
                          place.automatic
                              ? '${_dateTimeLabel(context, place.capturedAt)} • Automatic'
                              : _dateTimeLabel(context, place.capturedAt),
                          style: theme.textTheme.bodySmall,
                        ),
                        if (place.subtitle != null) Text(place.subtitle!, style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (places.length > _shown)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('and ${places.length - _shown} more', style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

/// Documents on this phone matching what the user asked for. The search runs locally over the
/// documents the user added (each one granted by the OS file picker); nothing is uploaded.
class DocumentResultsCard extends StatefulWidget {
  const DocumentResultsCard({super.key, required this.query, required this.results});

  final ChatLookupQuery query;
  final ChatResultContext results;

  @override
  State<DocumentResultsCard> createState() => _DocumentResultsCardState();
}

class _DocumentResultsCardState extends State<DocumentResultsCard> {
  late final Future<List<DocumentItem>> _matches = _search();

  Future<List<DocumentItem>> _search() async {
    final documents = await widget.results.documentService.list();
    final type = widget.query.type?.toLowerCase();
    final typed = type == null ? documents : documents.where((d) => d.type.extension == type).toList();
    final words = _words(widget.query.text);
    if (words.isEmpty) return typed.take(widget.query.limit ?? 10).toList();

    String normalize(String name) => name.toLowerCase().replaceAll(RegExp(r'[_\-.]+'), ' ');
    // Prefer files matching every word ("math notes"), else any of them.
    var matches = typed.where((d) => words.every(normalize(d.name).contains)).toList();
    if (matches.isEmpty) matches = typed.where((d) => words.any(normalize(d.name).contains)).toList();
    return matches.take(widget.query.limit ?? 10).toList();
  }

  static const _ignored = {'my', 'the', 'a', 'an', 'all', 'file', 'files', 'document', 'documents', 'doc', 'docs'};

  static List<String> _words(String? text) => (text ?? '')
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.length > 1 && !_ignored.contains(w))
      .toList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<List<DocumentItem>>(
      future: _matches,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator());
        }
        final documents = snapshot.data ?? const <DocumentItem>[];
        if (snapshot.hasError || documents.isEmpty) {
          return InfoBanner(
            icon: Icons.search_off_rounded,
            title: snapshot.hasError ? "I couldn't search your documents." : 'No matching documents on this phone.',
            message: const Text('Child Assist can only see documents you added in Documents.'),
            actions: [
              OutlinedButton(onPressed: widget.results.onOpenDocuments, child: const Text('Open Documents')),
            ],
          );
        }
        return AppCard(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                documents.length == 1 ? '1 document found' : '${documents.length} documents found',
                style: theme.textTheme.titleSmall,
              ),
              for (final document in documents)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      DocumentTypeBadge(type: document.type, size: 40),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(document.name, style: theme.textTheme.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                            Text(document.type.label, style: theme.textTheme.labelSmall),
                            Text(documentDateText(context, document).replaceFirst(' ', ': '), style: theme.textTheme.bodySmall),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: () => widget.results.onOpenDocument(document),
                        child: const Text('Open'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

enum _PhotoOutcome { found, permission, failed }

/// Photos on this phone matching the request, read through the existing gallery service with
/// whatever access the OS gives. Only small thumbnails are shown; nothing is uploaded.
class PhotoResultsCard extends StatefulWidget {
  const PhotoResultsCard({super.key, required this.query, required this.results});

  final ChatLookupQuery query;
  final ChatResultContext results;

  @override
  State<PhotoResultsCard> createState() => _PhotoResultsCardState();
}

class _PhotoResultsCardState extends State<PhotoResultsCard> {
  late final Future<(_PhotoOutcome, List<PhotoItem>)> _matches = _search();

  Future<(_PhotoOutcome, List<PhotoItem>)> _search() async {
    final gallery = widget.results.galleryService;
    // A status check only: chat never shows a permission dialog.
    if (!(await gallery.permissionStatus()).isUsable) return (_PhotoOutcome.permission, const <PhotoItem>[]);

    final start = widget.query.start?.toLocal();
    final end = widget.query.end?.toLocal();
    DateTimeRange? range;
    if (start != null && end != null && end.isAfter(start)) {
      // The gallery's range end is a whole day; the exact bounds are applied below.
      range = DateTimeRange(
        start: start,
        end: DateUtils.dateOnly(end.subtract(const Duration(microseconds: 1))),
      );
    }
    try {
      final page = await gallery.loadPage(0, range: range);
      final text = widget.query.text?.toLowerCase();
      final matches = page.where((p) {
        if (start != null && p.createdAt.isBefore(start)) return false;
        if (end != null && !p.createdAt.isBefore(end)) return false;
        if (text != null && p.name != null && !p.name!.toLowerCase().contains(text)) return false;
        return true;
      });
      return (_PhotoOutcome.found, matches.take(widget.query.limit ?? 12).toList());
    } on PhotoGalleryException {
      return (_PhotoOutcome.failed, const <PhotoItem>[]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder(
      future: _matches,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator());
        }
        final (outcome, photos) = snapshot.data ?? (_PhotoOutcome.failed, const <PhotoItem>[]);
        if (outcome == _PhotoOutcome.permission) {
          return PermissionRequiredCard(
            permission: ChatPermission.photos,
            kind: ChatToolKind.photos,
            onOpenPermissions: widget.results.onOpenPermissions,
          );
        }
        if (outcome == _PhotoOutcome.failed || photos.isEmpty) {
          return InfoBanner(
            icon: Icons.image_search_rounded,
            title: outcome == _PhotoOutcome.failed ? "I couldn't read your photos." : 'No matching photos on this phone.',
            message: const Text('Try a different date or check the Photos screen.'),
          );
        }
        final l10n = MaterialLocalizations.of(context);
        return AppCard(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(photos.length == 1 ? '1 photo found' : '${photos.length} photos found', style: theme.textTheme.titleSmall),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final photo in photos)
                    SizedBox(
                      width: 84,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 84,
                            height: 84,
                            child: PhotoThumbnail(
                              photo: photo,
                              galleryService: widget.results.galleryService,
                              onTap: () => widget.results.onOpenPhoto(photo),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            l10n.formatShortMonthDay(photo.createdAt.toLocal()),
                            style: theme.textTheme.labelSmall,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
