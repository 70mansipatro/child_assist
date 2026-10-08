import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show DateTimeRange;
// The plugin has its own PermissionState; the app's (from PermissionService) is used instead.
import 'package:photo_manager/photo_manager.dart' hide PermissionState;

import '../../../core/permissions/permission_service.dart';
import '../models/photo_item.dart';

export '../models/photo_item.dart';

/// The gallery could not be read. [message] is safe to show to the user.
class PhotoGalleryException implements Exception {
  const PhotoGalleryException([this.message = 'Unable to load photos.']);

  final String message;

  @override
  String toString() => 'PhotoGalleryException: $message';
}

/// Access to the device photo library. Separated out so tests never need a real gallery.
abstract class PhotoLibrary {
  /// Photos newest first, [pageSize] per page. [range] limits them by creation date.
  /// May throw.
  Future<List<PhotoItem>> page(int page, int pageSize, {DateTimeRange? range});

  /// A JPEG of the photo scaled to fit [width] x [height], or null if unavailable. May throw.
  Future<Uint8List?> image(String id, int width, int height);

  /// The photo's metadata including name, type and size, or null if it no longer exists.
  Future<PhotoItem?> details(String id);

  /// The GPS position stored in the photo itself, or null when it has none (or the OS hides it).
  /// Never guessed: a missing or 0,0 position means "unknown". May throw.
  Future<PhotoPosition?> location(String id);

  /// The platform's private reference to the photo (an Android content URI), used only on this
  /// device to hand the photo to WhatsApp or the share sheet. Never sent anywhere. May throw.
  Future<String?> shareReference(String id);

  /// Lets the user change a "selected photos only" grant where the OS has a picker for it.
  /// Returns false if this platform has none.
  Future<bool> changeLimitedSelection();

  /// Forgets cached gallery entries, e.g. after the selection or permission changed.
  void reset();
}

/// [PhotoLibrary] backed by `photo_manager`, read-only. Permission is handled by the app's
/// [PermissionService], so the plugin's own permission prompt is switched off.
class DevicePhotoLibrary implements PhotoLibrary {
  final Map<String, AssetEntity> _assets = {};
  bool _configured = false;

  Future<void> _configure() async {
    if (_configured) return;
    await PhotoManager.setIgnorePermissionCheck(true);
    _configured = true;
  }

  @override
  Future<List<PhotoItem>> page(int page, int pageSize, {DateTimeRange? range}) async {
    await _configure();
    final assets = await PhotoManager.getAssetListPaged(
      page: page,
      pageCount: pageSize,
      type: RequestType.image,
      filterOption: FilterOptionGroup(
        imageOption: const FilterOption(
          needTitle: true,
          sizeConstraint: SizeConstraint(ignoreSize: true),
        ),
        createTimeCond: range == null
            ? DateTimeCond.def().copyWith(ignore: true)
            // The range end is a whole day: include everything up to its last moment.
            : DateTimeCond(min: range.start, max: range.end.add(const Duration(days: 1))),
        orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
      ),
    );
    for (final asset in assets) {
      _assets[asset.id] = asset;
    }
    return assets.map(_toItem).toList();
  }

  @override
  Future<Uint8List?> image(String id, int width, int height) async {
    final asset = await _asset(id);
    return asset?.thumbnailDataWithSize(ThumbnailSize(width, height), quality: 90);
  }

  @override
  Future<PhotoItem?> details(String id) async {
    final asset = await _asset(id);
    if (asset == null) return null;
    final name = asset.title?.isNotEmpty == true ? asset.title : await asset.titleAsync;
    return _toItem(asset).withDetails(
      name: name?.isNotEmpty == true ? name : null,
      mimeType: asset.mimeType ?? await asset.mimeTypeAsync,
      fileSize: await asset.fileSize,
    );
  }

  @override
  Future<PhotoPosition?> location(String id) async {
    final asset = await _asset(id);
    if (asset == null) return null;
    // Android 10+ hides photo GPS unless ACCESS_MEDIA_LOCATION is granted; the plugin then fails
    // or reports 0,0. Both mean "no GPS", never a made-up position.
    final latLng = await asset.latlngAsync();
    return PhotoPosition.tryCreate(latLng?.latitude, latLng?.longitude);
  }

  @override
  Future<String?> shareReference(String id) async {
    final asset = await _asset(id);
    return asset?.getMediaUrl();
  }

  @override
  Future<bool> changeLimitedSelection() async {
    // Only iOS has a selection picker here; on Android the permission request shows it.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return false;
    await _configure();
    await PhotoManager.presentLimited(type: RequestType.image);
    return true;
  }

  @override
  void reset() => _assets.clear();

  Future<AssetEntity?> _asset(String id) async {
    final cached = _assets[id];
    if (cached != null) return cached;
    await _configure();
    final asset = await AssetEntity.fromId(id);
    if (asset != null) _assets[id] = asset;
    return asset;
  }

  static PhotoItem _toItem(AssetEntity asset) => PhotoItem(
        id: asset.id,
        name: asset.title?.isNotEmpty == true ? asset.title : null,
        width: asset.orientatedWidth,
        height: asset.orientatedHeight,
        createdAt: asset.createDateTime,
        modifiedAt: asset.modifiedDateTime,
        mimeType: asset.mimeType,
      );
}

/// Reads the device gallery for the Photos feature: metadata, thumbnails and previews.
///
/// Photos are never uploaded or copied anywhere; images are read on demand at the size they
/// are shown. Permission checks and requests go through the shared [PermissionService].
class PhotoGalleryService {
  PhotoGalleryService({
    required PermissionService permissionService,
    PhotoLibrary? library,
    this.pageSize = 60,
  })  : _permissions = permissionService,
        _library = library ?? DevicePhotoLibrary();

  final PermissionService _permissions;
  final PhotoLibrary _library;
  final int pageSize;

  /// Pixel size of grid thumbnails; large enough for ~3 columns on a high-density phone.
  static const thumbnailSize = 300;

  /// Longest side of the image shown in the viewer: sharp on a phone screen, far smaller
  /// than a camera original.
  static const previewSize = 2048;

  // Recently shown thumbnails, so scrolling back does not decode them again (~10 MB at most).
  static const _thumbnailCacheSize = 400;
  final _thumbnails = <String, Uint8List>{}; // insertion-ordered: oldest first

  /// Current OS permission state, without showing any dialog.
  Future<PermissionState> permissionStatus() => _permissions.photoStatus();

  /// Shows the system dialog if the OS still allows asking; otherwise returns the state as is.
  Future<PermissionState> requestPermission() => _permissions.requestPhotoPermission();

  Future<bool> openSettings() => _permissions.openSettings();

  /// With "selected photos only" access, lets the user pick a different set.
  /// Returns the permission state afterwards.
  Future<PermissionState> changeLimitedSelection() async {
    try {
      if (!await _library.changeLimitedSelection()) {
        return await _permissions.requestAgainIfLimited(AppPermission.photos);
      }
    } catch (e) {
      debugPrint('Changing the photo selection failed: ${e.runtimeType}');
    }
    return _permissions.photoStatus();
  }

  /// One page of photos, newest first. [page] starts at 0. Throws [PhotoGalleryException].
  Future<List<PhotoItem>> loadPage(int page, {DateTimeRange? range}) async {
    try {
      return await _library.page(page, pageSize, range: range);
    } catch (e) {
      // Only the error type: messages can contain file paths.
      debugPrint('Loading photos failed: ${e.runtimeType}');
      throw const PhotoGalleryException();
    }
  }

  /// Drops cached entries so the next load reflects the gallery as it is now.
  void reset() {
    _thumbnails.clear();
    _library.reset();
  }

  /// A small square-ish JPEG for the grid, or null if it cannot be read.
  Future<Uint8List?> thumbnail(PhotoItem photo) async {
    final cached = _thumbnails.remove(photo.id);
    if (cached != null) return _thumbnails[photo.id] = cached;
    final bytes = await _read(photo.id, thumbnailSize, thumbnailSize);
    if (bytes != null) {
      _thumbnails[photo.id] = bytes;
      if (_thumbnails.length > _thumbnailCacheSize) _thumbnails.remove(_thumbnails.keys.first);
    }
    return bytes;
  }

  /// Longest side of the image sent for AI analysis: enough to read signs and see details, far
  /// smaller (and cheaper) than a camera original.
  static const analysisSize = 1536;

  /// The photo scaled down to at most [previewSize] on its longest side, for the viewer.
  Future<Uint8List?> preview(PhotoItem photo) => _scaled(photo, previewSize);

  /// A JPEG of the photo at most [analysisSize] on its longest side, for the ONE photo the user
  /// asked the assistant about. Null if it can no longer be read.
  Future<Uint8List?> analysisImage(PhotoItem photo) => _scaled(photo, analysisSize);

  /// Whether the photo is still on the device (it may have been deleted since it was listed).
  Future<bool> exists(PhotoItem photo) async {
    try {
      return await _library.details(photo.id) != null;
    } catch (e) {
      debugPrint('Checking a photo failed: ${e.runtimeType}');
      return false;
    }
  }

  /// The GPS position stored in the photo, or null when it has none. Never logged.
  Future<PhotoPosition?> location(PhotoItem photo) async {
    try {
      return await _library.location(photo.id);
    } catch (e) {
      debugPrint('Reading a photo position failed: ${e.runtimeType}');
      return null;
    }
  }

  /// The private reference used to share [photo] from this device, or null if it is gone.
  Future<String?> shareReference(PhotoItem photo) async {
    try {
      return await _library.shareReference(photo.id);
    } catch (e) {
      debugPrint('Reading a photo reference failed: ${e.runtimeType}');
      return null;
    }
  }

  Future<Uint8List?> _scaled(PhotoItem photo, int longest) {
    var width = longest, height = longest;
    if (photo.hasDimensions) {
      final scale = longest / (photo.width > photo.height ? photo.width : photo.height);
      if (scale < 1) {
        width = (photo.width * scale).round();
        height = (photo.height * scale).round();
      } else {
        width = photo.width;
        height = photo.height;
      }
    }
    return _read(photo.id, width, height);
  }

  /// [photo] with its file name, type and size filled in where the platform knows them.
  Future<PhotoItem> details(PhotoItem photo) async {
    try {
      return await _library.details(photo.id) ?? photo;
    } catch (e) {
      debugPrint('Reading photo details failed: ${e.runtimeType}');
      return photo;
    }
  }

  Future<Uint8List?> _read(String id, int width, int height) async {
    try {
      return await _library.image(id, width, height);
    } catch (e) {
      debugPrint('Reading a photo failed: ${e.runtimeType}');
      return null;
    }
  }
}
