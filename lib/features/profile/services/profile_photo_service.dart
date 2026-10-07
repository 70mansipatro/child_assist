import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../auth/services/auth_service.dart';

/// Where profile photos come from and are kept. Swappable in tests.
abstract class ProfilePhotoPlatform {
  /// Lets the user choose one image; null if they cancel.
  Future<Uint8List?> pickImage();

  Future<Uint8List?> read(String userId);
  Future<void> write(String userId, Uint8List bytes);
  Future<void> delete(String userId);
}

/// Picks with the system photo picker and keeps each account's photo in the app's private
/// folder on this device. Photos are never uploaded.
class DeviceProfilePhotoPlatform implements ProfilePhotoPlatform {
  Future<File> _file(String userId) async {
    final dir = await getApplicationDocumentsDirectory();
    // Only a safe file name derived from the account ID, one photo per account.
    final safeId = userId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return File('${dir.path}${Platform.pathSeparator}profile_photos${Platform.pathSeparator}$safeId');
  }

  @override
  Future<Uint8List?> pickImage() async {
    final file = await FilePicker.pickFile(type: FileType.image);
    if (file == null) return null;
    try {
      // Checked before reading, so a huge file is never loaded into memory.
      if ((file.lengthSync() ?? 0) > ProfilePhotoService.maxBytes) {
        throw const ProfilePhotoException('Please choose a photo smaller than 10 MB.');
      }
      return await file.readAsBytes();
    } finally {
      // The plugin copies the pick into the app cache; the photo is saved separately below.
      try {
        await FilePicker.clearTemporaryFiles();
      } catch (e) {
        debugPrint('Clearing picker copies failed: ${e.runtimeType}');
      }
    }
  }

  @override
  Future<Uint8List?> read(String userId) async {
    final file = await _file(userId);
    return await file.exists() ? file.readAsBytes() : null;
  }

  @override
  Future<void> write(String userId, Uint8List bytes) async {
    final file = await _file(userId);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<void> delete(String userId) async {
    final file = await _file(userId);
    if (await file.exists()) await file.delete();
  }
}

/// The signed-in user's profile photo (DP), kept only on this device. Follows the signed-in
/// account: switching or signing out never shows another account's photo.
class ProfilePhotoService extends ChangeNotifier {
  ProfilePhotoService({required AuthService authService, ProfilePhotoPlatform? platform})
      : _auth = authService,
        _platform = platform ?? DeviceProfilePhotoPlatform() {
    _auth.addListener(_onAuthChanged);
    _onAuthChanged();
  }

  /// Larger files are refused rather than kept in memory.
  static const maxBytes = 10 * 1024 * 1024;

  final AuthService _auth;
  final ProfilePhotoPlatform _platform;

  String? _userId;
  Uint8List? _photo;

  /// The current account's photo, or null to show initials / a placeholder.
  Uint8List? get photo => _photo;

  /// Lets the user choose a new photo. Returns false if they cancelled; throws
  /// [ProfilePhotoException] if the image cannot be used.
  Future<bool> choosePhoto() async {
    final userId = _userId;
    if (userId == null) return false;
    final bytes = await _platform.pickImage();
    if (bytes == null) return false;
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const ProfilePhotoException('Please choose a photo smaller than 10 MB.');
    }
    await _platform.write(userId, bytes);
    if (_userId != userId) return false;
    _photo = bytes;
    notifyListeners();
    return true;
  }

  Future<void> removePhoto() async {
    final userId = _userId;
    if (userId == null) return;
    await _platform.delete(userId);
    if (_userId != userId) return;
    _photo = null;
    notifyListeners();
  }

  Future<void> _onAuthChanged() async {
    final userId = _auth.status == AuthStatus.authenticated ? _auth.currentUser?.id : null;
    if (userId == _userId) return; // e.g. a name change
    _userId = userId;
    _photo = null;
    notifyListeners();
    if (userId == null) return;
    try {
      final bytes = await _platform.read(userId);
      if (_userId != userId) return;
      _photo = bytes;
      notifyListeners();
    } catch (_) {
      // An unreadable photo just shows the placeholder.
    }
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    super.dispose();
  }
}

class ProfilePhotoException implements Exception {
  const ProfilePhotoException(this.message);

  final String message;

  @override
  String toString() => message;
}
