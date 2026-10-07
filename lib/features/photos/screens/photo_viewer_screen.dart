import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/navigation/app_menu.dart';
import '../../../core/widgets/widgets.dart';
import '../services/photo_gallery_service.dart';

/// Shows one photo (zoomable) with the metadata the device reports for it. Read-only: the
/// photo is never edited, moved or deleted.
class PhotoViewerScreen extends StatefulWidget {
  const PhotoViewerScreen({super.key, required this.photo, required this.galleryService});

  final PhotoItem photo;
  final PhotoGalleryService galleryService;

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  late final Future<Uint8List?> _image = widget.galleryService.preview(widget.photo);
  late PhotoItem _photo = widget.photo;

  @override
  void initState() {
    super.initState();
    widget.galleryService.details(widget.photo).then((photo) {
      if (mounted) setState(() => _photo = photo);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final metadata = _metadata(context);
    return Scaffold(
      backgroundColor: const Color(0xFF07070D),
      appBar: AppBar(
        foregroundColor: Colors.white,
        backgroundColor: const Color(0xFF07070D),
        systemOverlayStyle: SystemUiOverlayStyle.light,
        title: Text(
          _photo.name ?? 'Photo',
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium?.copyWith(color: Colors.white),
        ),
        actions: const [AppMenuButton(color: Colors.white)],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: FutureBuilder<Uint8List?>(
                future: _image,
                builder: (context, snapshot) {
                  final bytes = snapshot.data;
                  final Widget child;
                  if (bytes != null) {
                    child = InteractiveViewer(
                      key: const ValueKey('image'),
                      maxScale: 5,
                      child: Center(
                        child: Image.memory(
                          bytes,
                          fit: BoxFit.contain,
                          semanticLabel: 'Selected photo',
                        ),
                      ),
                    );
                  } else if (snapshot.connectionState != ConnectionState.done) {
                    child = const Center(
                      key: ValueKey('loading'),
                      child: CircularProgressIndicator(color: Colors.white),
                    );
                  } else {
                    child = Center(
                      key: const ValueKey('error'),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.broken_image_outlined, size: 48, color: Colors.white.withValues(alpha: 0.6)),
                          const SizedBox(height: 12),
                          const Text(
                            'This photo could not be shown.',
                            style: TextStyle(color: Colors.white, fontSize: 16),
                          ),
                        ],
                      ),
                    );
                  }
                  return AnimatedSwitcher(duration: const Duration(milliseconds: 350), child: child);
                },
              ),
            ),
            FadeSlideIn(
              offset: const Offset(0, 40),
              child: Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                ),
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.outlineVariant,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        const IconBadge(icon: Icons.info_outline_rounded, gradient: AppGradients.photos, size: 34, glow: false),
                        const SizedBox(width: 10),
                        Text('Details', style: theme.textTheme.titleMedium),
                      ],
                    ),
                    const SizedBox(height: 12),
                    LayoutBuilder(builder: (context, constraints) {
                      final columns = constraints.maxWidth >= 520 ? 3 : 2;
                      final width = (constraints.maxWidth - 10 * (columns - 1)) / columns;
                      return Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          for (final (icon, label, value) in metadata)
                            SizedBox(
                              width: label == 'Name' ? constraints.maxWidth : width,
                              child: _DetailTile(icon: icon, label: label, value: value),
                            ),
                        ],
                      );
                    }),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Only the fields the device actually reported.
  List<(IconData, String, String)> _metadata(BuildContext context) {
    final l10n = MaterialLocalizations.of(context);
    final created = _photo.createdAt.toLocal();
    return [
      if (_photo.name != null) (Icons.badge_outlined, 'Name', _photo.name!),
      (Icons.calendar_today_rounded, 'Date', l10n.formatFullDate(created)),
      (Icons.schedule_rounded, 'Time', l10n.formatTimeOfDay(TimeOfDay.fromDateTime(created))),
      if (_photo.hasDimensions) (Icons.aspect_ratio_rounded, 'Dimensions', '${_photo.width} × ${_photo.height}'),
      if (_photo.mimeType != null) (Icons.image_outlined, 'File type', fileTypeLabel(_photo.mimeType!)),
      if (_photo.fileSize != null && _photo.fileSize! > 0)
        (Icons.sd_storage_outlined, 'File size', fileSizeLabel(_photo.fileSize!)),
    ];
  }
}

class _DetailTile extends StatelessWidget {
  const _DetailTile({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.pink),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                Text(value, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
// "image/jpeg" -> "JPEG".
String fileTypeLabel(String mimeType) {
  final slash = mimeType.indexOf('/');
  return (slash >= 0 ? mimeType.substring(slash + 1) : mimeType).toUpperCase();
}

/// 2457600 -> "2.3 MB".
String fileSizeLabel(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
