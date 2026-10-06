import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/widgets/motion.dart';
import '../services/photo_gallery_service.dart';

/// A sliver grid of square photo thumbnails. Column count follows the available width, and
/// cells are built lazily, so only visible thumbnails are ever read.
class PhotoGrid extends StatelessWidget {
  const PhotoGrid({
    super.key,
    required this.photos,
    required this.galleryService,
    required this.onTap,
  });

  final List<PhotoItem> photos;
  final PhotoGalleryService galleryService;
  final ValueChanged<PhotoItem> onTap;

  @override
  Widget build(BuildContext context) {
    return SliverGrid.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 130,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: photos.length,
      itemBuilder: (context, index) => PhotoThumbnail(
        key: ValueKey(photos[index].id),
        photo: photos[index],
        galleryService: galleryService,
        onTap: () => onTap(photos[index]),
      ),
    );
  }
}

/// One grid cell: a thumbnail (never the original image) with a placeholder while it loads.
class PhotoThumbnail extends StatefulWidget {
  const PhotoThumbnail({
    super.key,
    required this.photo,
    required this.galleryService,
    required this.onTap,
  });

  final PhotoItem photo;
  final PhotoGalleryService galleryService;
  final VoidCallback onTap;

  @override
  State<PhotoThumbnail> createState() => _PhotoThumbnailState();
}

class _PhotoThumbnailState extends State<PhotoThumbnail> {
  late Future<Uint8List?> _bytes = widget.galleryService.thumbnail(widget.photo);

  @override
  void didUpdateWidget(PhotoThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photo.id != widget.photo.id) {
      _bytes = widget.galleryService.thumbnail(widget.photo);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final date = MaterialLocalizations.of(context).formatMediumDate(widget.photo.createdAt);
    final radius = BorderRadius.circular(14);
    return Semantics(
      button: true,
      label: 'Photo from $date',
      child: PressableScale(
        scale: 0.95,
        child: ClipRRect(
          borderRadius: radius,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: colors.surfaceContainerHighest),
              FutureBuilder<Uint8List?>(
                future: _bytes,
                builder: (context, snapshot) {
                  final bytes = snapshot.data;
                  if (bytes != null) {
                    return Image(
                      image: ResizeImage(
                        MemoryImage(bytes),
                        width: PhotoGalleryService.thumbnailSize,
                        policy: ResizeImagePolicy.fit,
                      ),
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      excludeFromSemantics: true,
                      // Thumbnails fade in as they decode instead of popping in.
                      frameBuilder: (context, child, frame, sync) => sync
                          ? child
                          : AnimatedOpacity(
                              opacity: frame == null ? 0 : 1,
                              duration: const Duration(milliseconds: 280),
                              curve: Curves.easeOut,
                              child: child,
                            ),
                      errorBuilder: (_, _, _) =>
                          Center(child: Icon(Icons.broken_image_outlined, color: colors.outline)),
                    );
                  }
                  if (snapshot.connectionState == ConnectionState.done) {
                    return Center(child: Icon(Icons.broken_image_outlined, color: colors.outline));
                  }
                  return Center(
                    child: Icon(Icons.image_outlined, color: colors.outline.withValues(alpha: 0.6)),
                  );
                },
              ),
              Material(
                type: MaterialType.transparency,
                child: InkWell(onTap: widget.onTap),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
