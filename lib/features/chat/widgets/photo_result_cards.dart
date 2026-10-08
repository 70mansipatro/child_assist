import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';
import '../../photos/services/photo_gallery_service.dart';
import '../../photos/widgets/photo_grid.dart' show PhotoThumbnail;
import '../models/chat_message.dart';
import '../services/chat_session.dart';
import 'tool_result_cards.dart' show ChatResultContext, PermissionRequiredCard;

// Photos in chat. Every search runs on the phone over the photos the OS lets Child Assist see;
// only the metadata of the photos shown goes to the server, and only the ONE photo the user asks
// about is sent (scaled down) to be looked at. No path or content URI is ever shown or sent.
// Nothing is shared without the user confirming it, and Child Assist only ever *opens* WhatsApp or
// the share sheet: the user sends the photo there.

String photoDateLabel(BuildContext context, DateTime time) {
  final l10n = MaterialLocalizations.of(context);
  final local = time.toLocal();
  return '${l10n.formatMediumDate(local)} · ${l10n.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
}

/// The answer to "show me the photo from where I went today": one strong match with its details
/// and actions; several to choose from; or a clear "not found". Never invented.
class PhotoSearchCard extends StatefulWidget {
  const PhotoSearchCard({super.key, required this.requestId, required this.query, required this.results});

  final String requestId;
  final PhotoSearchQuery query;
  final ChatResultContext results;

  @override
  State<PhotoSearchCard> createState() => _PhotoSearchCardState();
}

class _PhotoSearchCardState extends State<PhotoSearchCard> {
  bool _choosingAgain = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Idempotent: a rebuilt card never searches or reports twice.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.results.session.startPhotoSearch(widget.requestId, widget.query);
    });
  }

  Future<void> _choose(ChatPhoto photo) async {
    final error = await widget.results.session.choosePhoto(widget.requestId, photo);
    if (!mounted) return;
    setState(() {
      _error = error;
      if (error == null) _choosingAgain = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.results.session;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final state = session.photoSearch(widget.requestId);
        final theme = Theme.of(context);
        switch (state?.phase) {
          case null || PhotoSearchPhase.searching:
            return _Progress(text: 'Finding your photo...');
          case PhotoSearchPhase.permission:
            return PermissionRequiredCard(
              permission: ChatPermission.photos,
              kind: ChatToolKind.photos,
              onOpenPermissions: widget.results.onOpenPermissions,
            );
          case PhotoSearchPhase.none || PhotoSearchPhase.failed:
            final none = state!.phase == PhotoSearchPhase.none;
            final detail = (state.message ?? '').replaceFirst(ChatSession.photoNotFoundMessage, '').trim();
            return InfoBanner(
              icon: Icons.image_search_rounded,
              title: none ? ChatSession.photoNotFoundMessage : (state.message ?? "I couldn't read your photos."),
              message: Text(none && detail.isNotEmpty ? detail : 'Try a different day or place, or check the Photos screen.'),
            );
          case PhotoSearchPhase.found:
            break;
        }
        final found = state!;
        final selected = _choosingAgain ? null : found.photos.where((p) => p.id == found.selectedId).firstOrNull;
        if (selected != null) {
          final analysisId = found.analyses[selected.id];
          return PhotoDetailsCard(
            key: ValueKey('photo-${selected.id}'),
            photo: selected,
            results: widget.results,
            analysisRequestId: analysisId,
            note: found.contentHint && found.photos.length == 1 && analysisId == null
                ? "I can't search inside photos, so check this is the one. Tap Analyze and I'll look at it."
                : null,
            onChooseAnother: found.photos.length > 1 ? () => setState(() => _choosingAgain = true) : null,
          );
        }
        final count = found.total > found.photos.length ? found.total : found.photos.length;
        return AppCard(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('I found $count matching photos. Which one would you like?', style: theme.textTheme.titleSmall),
              if (widget.query.analyze)
                Text("Tap the one you mean and I'll look at it.", style: theme.textTheme.bodySmall),
              if (count > found.photos.length)
                Text('Showing the ${found.photos.length} best matches.', style: theme.textTheme.bodySmall),
              if (found.contentHint)
                Text(
                  "I can't search inside photos, so pick one and I can check what's in it.",
                  style: theme.textTheme.bodySmall,
                ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final photo in found.photos)
                    SizedBox(
                      key: ValueKey('choose-photo-${photo.id}'),
                      width: 96,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 96,
                            height: 96,
                            child: PhotoThumbnail(
                              photo: photo.item,
                              galleryService: widget.results.galleryService,
                              onTap: () => _choose(photo),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(photo.item.createdAt.toLocal())),
                            style: theme.textTheme.labelSmall,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              if (found.limited) ...[
                const SizedBox(height: 8),
                Text('Child Assist can only see the photos you allowed it to access.', style: theme.textTheme.bodySmall),
              ],
              if (_error != null) ...[
                const SizedBox(height: 6),
                Text(_error!, style: TextStyle(color: AppColors.danger)),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// One photo from this phone: the photo itself, its date and time, the saved place it matched (and
/// how), with Open Photo, Analyze, Share and WhatsApp. Share and WhatsApp ask first. When the user
/// already asked about the photo, it is being looked at ([analysisRequestId]) and that progress
/// shows instead of the Analyze button.
class PhotoDetailsCard extends StatefulWidget {
  const PhotoDetailsCard({
    super.key,
    required this.photo,
    required this.results,
    this.onChooseAnother,
    this.note,
    this.analysisRequestId,
  });

  final ChatPhoto photo;
  final ChatResultContext results;
  final VoidCallback? onChooseAnother;
  final String? note;
  final String? analysisRequestId;

  @override
  State<PhotoDetailsCard> createState() => _PhotoDetailsCardState();
}

class _PhotoDetailsCardState extends State<PhotoDetailsCard> {
  String? _status;
  bool _sharing = false;

  Future<void> _share({required bool toWhatsApp}) async {
    final confirmed = await confirmPhotoShare(context, toWhatsApp: toWhatsApp);
    if (!mounted) return;
    if (!confirmed) {
      setState(() => _status = "Okay, I didn't share the photo.");
      return;
    }
    setState(() => _sharing = true);
    final message = await widget.results.session.sharePhoto(widget.photo, toWhatsApp: toWhatsApp);
    if (!mounted) return;
    setState(() {
      _sharing = false;
      _status = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.results.session;
    return PhotoSummaryTile(
      photo: widget.photo,
      results: widget.results,
      footer: [
        if (widget.note != null) Text(widget.note!, style: Theme.of(context).textTheme.bodySmall),
        if (widget.analysisRequestId != null) PhotoAnalysisStatus(requestId: widget.analysisRequestId!, session: session),
        if (_status != null) Text(_status!, style: Theme.of(context).textTheme.bodyMedium),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            OutlinedButton.icon(
              onPressed: () => widget.results.onOpenPhoto(widget.photo.item),
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: const Text('Open Photo'),
            ),
            if (widget.photo.id != null && widget.analysisRequestId == null)
              ListenableBuilder(
                listenable: session,
                builder: (context, _) => FilledButton.icon(
                  onPressed: session.isSending ? null : () => session.analyzePhoto(widget.photo),
                  icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                  label: const Text('Analyze'),
                ),
              ),
            OutlinedButton.icon(
              onPressed: _sharing ? null : () => _share(toWhatsApp: false),
              icon: const Icon(Icons.share_rounded, size: 18),
              label: const Text('Share'),
            ),
            OutlinedButton.icon(
              onPressed: _sharing ? null : () => _share(toWhatsApp: true),
              icon: const Icon(Icons.chat_rounded, size: 18),
              label: const Text('WhatsApp'),
            ),
            if (widget.onChooseAnother != null)
              TextButton(onPressed: widget.onChooseAnother, child: const Text('Choose another photo')),
          ],
        ),
      ],
    );
  }
}

/// Where looking at a photo for the user's question is: "Analyzing image...", answered (the answer
/// is the next message), or why it could not be looked at. Never a guess.
class PhotoAnalysisStatus extends StatelessWidget {
  const PhotoAnalysisStatus({super.key, required this.requestId, required this.session});

  final String requestId;
  final ChatSession session;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final state = session.photoAnalysis(requestId);
        final (String text, bool busy, bool failed) = switch (state?.phase) {
          null || PhotoAnalysisPhase.analyzing => ('Analyzing image...', true, false),
          PhotoAnalysisPhase.answered => ('Answered from this photo.', false, false),
          PhotoAnalysisPhase.failed => (state!.message ?? "I couldn't look at the photo.", false, true),
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: failed ? AppColors.danger : null),
            ),
            if (busy) ...[const SizedBox(height: 6), const LinearProgressIndicator()],
          ],
        );
      },
    );
  }
}

/// Asks before a photo leaves the phone. True only when the user tapped Confirm.
Future<bool> confirmPhotoShare(BuildContext context, {required bool toWhatsApp}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(toWhatsApp ? 'Do you want to share it on WhatsApp?' : 'Share this photo?'),
      content: Text(
        toWhatsApp
            ? 'WhatsApp will open with this photo attached. Choose the chat, then tap Send in WhatsApp. Nothing is sent until you do.'
            : 'Your share options will open. Nothing is sent until you send it from the app you choose.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Confirm')),
      ],
    ),
  );
  return confirmed == true;
}

/// A photo's image (tap to open it in the viewer), date and time, optional file name and the
/// saved place it matched, with [footer] below.
class PhotoSummaryTile extends StatelessWidget {
  const PhotoSummaryTile({super.key, required this.photo, required this.results, this.footer = const []});

  final ChatPhoto photo;
  final ChatResultContext results;
  final List<Widget> footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final place = photo.placeLine;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: AspectRatio(
              aspectRatio: photo.item.hasDimensions ? (photo.item.width / photo.item.height).clamp(0.6, 1.8) : 4 / 3,
              child: _ChatPhotoImage(photo: photo.item, gallery: results.galleryService, onTap: () => results.onOpenPhoto(photo.item)),
            ),
          ),
          const SizedBox(height: 8),
          if (photo.item.name != null)
            Text(photo.item.name!, style: theme.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(photoDateLabel(context, photo.item.createdAt), style: theme.textTheme.bodySmall),
          if (place != null)
            Row(
              children: [
                Icon(photo.evidence == PhotoEvidence.gps ? Icons.place_rounded : Icons.schedule_rounded, size: 16),
                const SizedBox(width: 4),
                Flexible(child: Text(place, style: theme.textTheme.labelMedium)),
              ],
            ),
          for (final widget in footer) ...[const SizedBox(height: 8), widget],
        ],
      ),
    );
  }
}

/// The photo at chat size (a thumbnail-sized read, never the original).
class _ChatPhotoImage extends StatefulWidget {
  const _ChatPhotoImage({required this.photo, required this.gallery, required this.onTap});

  final PhotoItem photo;
  final PhotoGalleryService gallery;
  final VoidCallback onTap;

  @override
  State<_ChatPhotoImage> createState() => _ChatPhotoImageState();
}

class _ChatPhotoImageState extends State<_ChatPhotoImage> {
  late final Future<Uint8List?> _bytes = widget.gallery.thumbnail(widget.photo);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Photo from ${MaterialLocalizations.of(context).formatMediumDate(widget.photo.createdAt.toLocal())}',
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: colors.surfaceContainerHighest),
          FutureBuilder<Uint8List?>(
            future: _bytes,
            builder: (context, snapshot) {
              final bytes = snapshot.data;
              if (bytes != null) {
                return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true, excludeFromSemantics: true);
              }
              if (snapshot.connectionState == ConnectionState.done) {
                return Center(child: Icon(Icons.broken_image_outlined, color: colors.outline));
              }
              return const Center(child: CircularProgressIndicator(strokeWidth: 2));
            },
          ),
          Material(type: MaterialType.transparency, child: InkWell(onTap: widget.onTap)),
        ],
      ),
    );
  }
}

/// A photo found earlier in this chat, shown again ("show me that photo again").
class ShownPhotoCard extends StatelessWidget {
  const ShownPhotoCard({super.key, required this.photoId, required this.results});

  final String photoId;
  final ChatResultContext results;

  @override
  Widget build(BuildContext context) {
    final photo = results.session.photo(photoId);
    if (photo == null) {
      return const InfoBanner(
        icon: Icons.image_not_supported_outlined,
        title: ChatSession.photoUnavailableMessage,
        message: Text('Ask me to find it again.'),
      );
    }
    return PhotoDetailsCard(photo: photo, results: results);
  }
}

/// "What is in this photo?": the one photo being talked about is checked to still be on the phone
/// and sent, scaled down, for Gemini vision; the answer from the real image appears as the next
/// message. Every failure is said plainly: nothing about the photo is ever guessed.
class PhotoAnalysisCard extends StatefulWidget {
  const PhotoAnalysisCard({super.key, required this.requestId, required this.photoId, required this.results});

  final String requestId;
  final String photoId;
  final ChatResultContext results;

  @override
  State<PhotoAnalysisCard> createState() => _PhotoAnalysisCardState();
}

class _PhotoAnalysisCardState extends State<PhotoAnalysisCard> {
  @override
  void initState() {
    super.initState();
    // Idempotent: a rebuilt card never sends the photo twice.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.results.session.startPhotoAnalysis(widget.requestId, widget.photoId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.results.session;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final state = session.photoAnalysis(widget.requestId);
        final photo = state?.photo;
        final thumb = photo == null
            ? null
            : SizedBox(
                width: 56,
                height: 56,
                child: PhotoThumbnail(
                  photo: photo.item,
                  galleryService: widget.results.galleryService,
                  onTap: () => widget.results.onOpenPhoto(photo.item),
                ),
              );
        return AppCard(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ?thumb,
              if (thumb != null) const SizedBox(width: 12),
              Expanded(child: PhotoAnalysisStatus(requestId: widget.requestId, session: session)),
            ],
          ),
        );
      },
    );
  }
}

/// "Share this photo on WhatsApp": asks first; only after Confirm does WhatsApp (or the share
/// sheet) open with the photo, and the user sends it there.
class PhotoShareCard extends StatefulWidget {
  const PhotoShareCard({super.key, required this.photoId, required this.toWhatsApp, required this.results});

  final String photoId;
  final bool toWhatsApp;
  final ChatResultContext results;

  @override
  State<PhotoShareCard> createState() => _PhotoShareCardState();
}

class _PhotoShareCardState extends State<PhotoShareCard> {
  bool _busy = false;
  String? _outcome;

  Future<void> _confirm(ChatPhoto photo) async {
    setState(() => _busy = true);
    final message = await widget.results.session.sharePhoto(photo, toWhatsApp: widget.toWhatsApp);
    if (mounted) {
      setState(() {
        _busy = false;
        _outcome = message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.results.session.photo(widget.photoId);
    if (photo == null) {
      return const InfoBanner(
        icon: Icons.image_not_supported_outlined,
        title: ChatSession.photoUnavailableMessage,
        message: Text('Nothing was shared.'),
      );
    }
    if (_outcome != null) {
      return InfoBanner(icon: Icons.info_outline_rounded, message: Text(_outcome!));
    }
    final theme = Theme.of(context);
    return PhotoSummaryTile(
      photo: photo,
      results: widget.results,
      footer: [
        Text(
          widget.toWhatsApp ? 'Do you want to share this photo on WhatsApp?' : 'Do you want to share this photo?',
          style: theme.textTheme.titleSmall,
        ),
        Text(
          widget.toWhatsApp
              ? 'WhatsApp will open with this photo. You choose the chat and tap Send there.'
              : 'Your share options will open. Nothing is sent until you send it.',
          style: theme.textTheme.bodySmall,
        ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          children: [
            OutlinedButton(
              onPressed: _busy ? null : () => setState(() => _outcome = "Okay, I didn't share the photo."),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: _busy ? null : () => _confirm(photo),
              child: _busy ? ButtonSpinner(size: 16, color: theme.colorScheme.onPrimary) : const Text('Confirm'),
            ),
          ],
        ),
      ],
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(text, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 6),
            const LinearProgressIndicator(),
          ],
        ),
      );
}
