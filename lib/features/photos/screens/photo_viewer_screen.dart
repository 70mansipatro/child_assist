import 'dart:typed_data';

import 'package:flutter/material.dart';

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
    return Scaffold(
      appBar: AppBar(title: Text(_photo.name ?? 'Photo', overflow: TextOverflow.ellipsis)),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ColoredBox(
                color: Colors.black,
                child: FutureBuilder<Uint8List?>(
                  future: _image,
                  builder: (context, snapshot) {
                    final bytes = snapshot.data;
                    if (bytes != null) {
                      return InteractiveViewer(
                        maxScale: 5,
                        child: Center(
                          child: Image.memory(
                            bytes,
                            fit: BoxFit.contain,
                            semanticLabel: 'Selected photo',
                          ),
                        ),
                      );
                    }
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    return const Center(
                      child: Text(
                        'This photo could not be shown.',
                        style: TextStyle(color: Colors.white, fontSize: 16),
                      ),
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Details', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  for (final (label, value) in _metadata(context))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 100,
                            child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            )),
                          ),
                          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Only the fields the device actually reported.
  List<(String, String)> _metadata(BuildContext context) {
    final l10n = MaterialLocalizations.of(context);
    final created = _photo.createdAt.toLocal();
    return [
      if (_photo.name != null) ('Name', _photo.name!),
      ('Date', l10n.formatFullDate(created)),
      ('Time', l10n.formatTimeOfDay(TimeOfDay.fromDateTime(created))),
      if (_photo.hasDimensions) ('Dimensions', '${_photo.width} × ${_photo.height}'),
      if (_photo.mimeType != null) ('File type', fileTypeLabel(_photo.mimeType!)),
      if (_photo.fileSize != null && _photo.fileSize! > 0)
        ('File size', fileSizeLabel(_photo.fileSize!)),
    ];
  }
}

/// "image/jpeg" -> "JPEG".
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
