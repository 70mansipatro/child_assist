import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';
import '../../contacts/services/contact_service.dart';
import '../../documents/services/document_service.dart';
import '../../documents/widgets/document_share.dart' show ShareDocument;
import '../../photos/services/photo_gallery_service.dart';
import '../models/chat_message.dart';
import '../services/chat_session.dart';
import 'contact_result_card.dart';
import 'document_result_cards.dart';
import 'photo_result_cards.dart';

export 'document_result_cards.dart';
export 'photo_result_cards.dart';

/// Sets an action's recipient; returns an error to show, or null on success.
typedef ChooseRecipient = Future<String?> Function(String actionId, {required String address, String? name});

/// Sets whose number an action shares; returns an error to show, or null on success.
typedef ChooseSharedContact = Future<String?> Function(String actionId, {required String name, required String phone});

/// Sets which document an action shares; returns an error to show, or null on success.
typedef ChooseDocument = Future<String?> Function(String actionId, DocumentItem document);


/// What the result cards need from the screen: the on-device services and navigation.
class ChatResultContext {
  const ChatResultContext({
    required this.session,
    required this.documentService,
    required this.galleryService,
    required this.contactService,
    required this.onOpenPermissions,
    required this.onOpenSettings,
    required this.onOpenDocuments,
    required this.onOpenDocument,
    required this.onOpenPhoto,
    required this.onChooseRecipient,
    required this.onChooseSharedContact,
    required this.onChooseDocument,
    required this.onShareDocument,
    required this.onConfirmAction,
    required this.onCancelAction,
    required this.onShareInstead,
  });

  /// The conversation: documents read for questions, and the document being talked about.
  final ChatSession session;
  final DocumentService documentService;
  final PhotoGalleryService galleryService;

  /// Searches the phone's contacts locally; nothing found is uploaded.
  final ContactService contactService;
  final VoidCallback onOpenPermissions;

  /// This app's page in the phone's Settings, for a permission that is blocked.
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenDocuments;
  final ValueChanged<DocumentItem> onOpenDocument;
  final ValueChanged<PhotoItem> onOpenPhoto;
  final ChooseRecipient onChooseRecipient;
  final ChooseSharedContact onChooseSharedContact;
  final ChooseDocument onChooseDocument;
  final ShareDocument onShareDocument;

  /// Confirms an action. A document share shares the document the server recorded for it.
  final ValueChanged<String> onConfirmAction;
  final ValueChanged<String> onCancelAction;

  /// After WhatsApp turned out to be unavailable: the share sheet instead.
  final ValueChanged<String> onShareInstead;
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
    (ChatToolKind.documentText, ChatToolStatus.deviceLookup) when event.requestId != null => DocumentReadCard(
      key: ValueKey('read-${event.requestId}'),
      requestId: event.requestId!,
      query: event.query,
      results: context,
    ),
    (ChatToolKind.photos, ChatToolStatus.deviceLookup) when event.requestId != null && event.photoSearch != null =>
      PhotoSearchCard(
        key: ValueKey('photos-${event.requestId}'),
        requestId: event.requestId!,
        query: event.photoSearch!,
        results: context,
      ),
    (ChatToolKind.photos, ChatToolStatus.success) when event.photoId != null =>
      ShownPhotoCard(photoId: event.photoId!, results: context),
    (ChatToolKind.photoAnalysis, ChatToolStatus.deviceLookup) when event.requestId != null && event.photoId != null =>
      PhotoAnalysisCard(
        key: ValueKey('analysis-${event.requestId}'),
        requestId: event.requestId!,
        photoId: event.photoId!,
        results: context,
      ),
    (ChatToolKind.photoShare, ChatToolStatus.confirmationRequired) when event.photoId != null =>
      PhotoShareCard(photoId: event.photoId!, toWhatsApp: event.shareToWhatsApp, results: context),
    (ChatToolKind.contacts, ChatToolStatus.deviceLookup) => ContactLookupCard(
      query: event.query,
      contactService: context.contactService,
      onOpenPermissions: context.onOpenPermissions,
      onOpenSettings: context.onOpenSettings,
    ),
    _ => null,
  };
}

ChatPermission _permissionFor(ChatToolKind kind) => switch (kind) {
      ChatToolKind.locationHistory || ChatToolKind.currentLocation => ChatPermission.location,
      ChatToolKind.photos || ChatToolKind.photoAnalysis || ChatToolKind.photoShare => ChatPermission.photos,
      ChatToolKind.documents || ChatToolKind.documentText => ChatPermission.documents,
      ChatToolKind.contacts => ChatPermission.contacts,
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
        ChatToolKind.photos || ChatToolKind.photoAnalysis || ChatToolKind.photoShare =>
          "I can't access your photos because Photos permission is turned off.",
        ChatToolKind.documents || ChatToolKind.documentText =>
          "I can't access your documents because Documents access is turned off.",
        _ when permission == ChatPermission.contacts => 'I need Contacts permission to search your phone contacts.',
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
