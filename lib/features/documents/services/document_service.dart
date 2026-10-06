import 'dart:convert';
import 'dart:io' hide BytesBuilder;
import 'dart:math';
import 'dart:typed_data';

import 'package:android_file_picker/android_file_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../auth/services/auth_service.dart';
import '../models/document_item.dart';

export '../models/document_item.dart';

/// A document operation failed. [message] is safe to show to the user.
class DocumentException implements Exception {
  const DocumentException([this.message = 'Unable to open this document.']);

  final String message;

  @override
  String toString() => 'DocumentException: $message';
}

/// The document was moved, renamed or deleted outside Child Assist, or access to it was revoked.
class DocumentUnavailableException extends DocumentException {
  const DocumentUnavailableException() : super('This document is no longer available.');
}

/// What the platform reports about a document. Null fields are unknown, never guessed.
class DocumentInfo {
  const DocumentInfo({this.name, this.mimeType, this.size, this.modifiedAt});

  final String? name;
  final String? mimeType;
  final int? size;
  final DateTime? modifiedAt;
}

/// A document the user chose in the system picker.
class PickedDocument {
  const PickedDocument({required this.reference, required this.name, required this.info});

  final String reference;
  final String name;
  final DocumentInfo info;
}

enum DocumentOpenResult {
  /// Handed to another app (a viewer, or the app the user chose).
  opened,

  /// No installed app can show this document.
  noViewer,

  /// The document is no longer available.
  unavailable,
}

/// Access to documents on the device. Separated out so tests never need a real file picker.
abstract class DocumentPlatform {
  /// Shows the system file picker limited to [extensions], allowing several files.
  /// Returns an empty list if the user cancels. May throw.
  Future<List<PickedDocument>> pick(List<String> extensions);

  /// Current metadata, or null if the document can no longer be accessed. May throw.
  Future<DocumentInfo?> info(String reference);

  /// Opens the document in another app. With [anyApp] the user chooses from every app that
  /// accepts files, not only viewers registered for [mimeType]. May throw.
  Future<DocumentOpenResult> open(String reference, {required String mimeType, bool anyApp = false});

  /// Up to [maxBytes] from the start of the document, or null if it can no longer be accessed.
  /// May throw.
  Future<Uint8List?> read(String reference, int maxBytes);

  /// Gives up Child Assist's access to the document. Never throws.
  Future<void> release(String reference);
}

/// [DocumentPlatform] backed by `file_picker` and, on Android, a small native channel.
///
/// Android: the picker is the Storage Access Framework (`ACTION_OPEN_DOCUMENT`). Child Assist
/// keeps a persistable read grant on each picked document's content URI and reads the original
/// through it, so a document deleted or moved on the device shows as unavailable. No storage
/// permission is needed.
///
/// iOS (and other platforms): the system document picker hands the app a copy of the file in
/// its own sandbox, and that copy is the reference. Opening in another app is not wired up there.
class DeviceDocumentPlatform implements DocumentPlatform {
  DeviceDocumentPlatform({bool? isAndroid})
      : _android = isAndroid ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  final bool _android;

  static const _channel = MethodChannel('child_assist/documents');

  @override
  Future<List<PickedDocument>> pick(List<String> extensions) async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: extensions,
      androidOptions: const FilePickerAndroidOptions(
        safOptions: AndroidSAFOptions(grant: AndroidSAFGrant.lifetime),
      ),
    );
    if (!_android) {
      return [
        for (final file in files)
          if (file.path != null)
            PickedDocument(
              reference: file.path!,
              name: file.name,
              info: await info(file.path!) ?? DocumentInfo(size: file.lengthSync()),
            ),
      ];
    }
    try {
      final picked = <PickedDocument>[];
      for (final file in files) {
        final uri = file is AndroidPlatformFile ? file.safHandle?.uri : null;
        if (uri == null) continue;
        final reference = uri.toString();
        picked.add(PickedDocument(
          reference: reference,
          name: file.name,
          info: await info(reference) ?? DocumentInfo(size: file.lengthSync()),
        ));
      }
      return picked;
    } finally {
      // The plugin also copies every picked file into the app cache. Child Assist reads the
      // originals through their content URIs, so those copies are deleted straight away.
      try {
        await FilePicker.clearTemporaryFiles();
      } catch (e) {
        debugPrint('Clearing picker copies failed: ${e.runtimeType}');
      }
    }
  }

  @override
  Future<DocumentInfo?> info(String reference) async {
    if (!_android) {
      final stat = await File(reference).stat();
      if (stat.type != FileSystemEntityType.file) return null;
      return DocumentInfo(
        name: reference.substring(reference.lastIndexOf('/') + 1),
        size: stat.size,
        modifiedAt: stat.modified,
      );
    }
    final map = await _channel.invokeMapMethod<String, Object?>('info', {'uri': reference});
    if (map == null) return null;
    final modified = map['modifiedAt'] as int?;
    return DocumentInfo(
      name: map['name'] as String?,
      mimeType: map['mimeType'] as String?,
      size: map['size'] as int?,
      modifiedAt: modified == null ? null : DateTime.fromMillisecondsSinceEpoch(modified),
    );
  }

  @override
  Future<DocumentOpenResult> open(String reference, {required String mimeType, bool anyApp = false}) async {
    if (!_android) {
      return await File(reference).exists() ? DocumentOpenResult.noViewer : DocumentOpenResult.unavailable;
    }
    final result = await _channel.invokeMethod<String>('open', {
      'uri': reference,
      'mimeType': mimeType,
      'anyApp': anyApp,
    });
    return switch (result) {
      'opened' => DocumentOpenResult.opened,
      'unavailable' => DocumentOpenResult.unavailable,
      _ => DocumentOpenResult.noViewer,
    };
  }

  @override
  Future<Uint8List?> read(String reference, int maxBytes) async {
    if (!_android) {
      final file = File(reference);
      if (!await file.exists()) return null;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in file.openRead(0, maxBytes)) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    }
    return _channel.invokeMethod<Uint8List>('read', {'uri': reference, 'maxBytes': maxBytes});
  }

  @override
  Future<void> release(String reference) async {
    if (!_android) return;
    try {
      await _channel.invokeMethod<void>('release', {'uri': reference});
    } catch (e) {
      debugPrint('Releasing document access failed: ${e.runtimeType}');
    }
  }
}

/// Keeps each user's document list in encrypted platform storage, on this device only.
class DocumentStorage {
  DocumentStorage({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
            );

  static const _prefix = 'documents_';

  final FlutterSecureStorage _storage;

  Future<List<DocumentItem>> read(String userId) async => _decode(await _storage.read(key: _key(userId)));

  Future<void> write(String userId, List<DocumentItem> documents) => _storage.write(
        key: _key(userId),
        value: jsonEncode([for (final d in documents) d.toStorage()]),
      );

  /// Whether another account on this device has also added the document at [reference].
  Future<bool> usedByOtherUser(String userId, String reference) async {
    final all = await _storage.readAll();
    return all.entries.any((entry) =>
        entry.key.startsWith(_prefix) &&
        entry.key != _key(userId) &&
        _decode(entry.value).any((d) => d.reference == reference));
  }

  static String _key(String userId) => '$_prefix$userId';

  static List<DocumentItem> _decode(String? raw) {
    if (raw == null) return [];
    final list = jsonDecode(raw);
    if (list is! List) return [];
    return [
      for (final entry in list)
        if (entry is Map<String, dynamic>) ?DocumentItem.fromStorage(entry),
    ];
  }
}

/// The outcome of one trip to the file picker.
class AddDocumentsResult {
  const AddDocumentsResult({this.added = const [], this.alreadyAdded = 0, this.unsupported = 0});

  final List<DocumentItem> added;

  /// Picked files that were already in the list (their details were refreshed).
  final int alreadyAdded;

  /// Picked files whose type Child Assist does not support (they were not added).
  final int unsupported;

  bool get cancelled => added.isEmpty && alreadyAdded == 0 && unsupported == 0;
}

/// The start of a text document, decoded for display.
class DocumentText {
  const DocumentText(this.text, {required this.truncated});

  final String text;

  /// True if the document is longer than [DocumentService.maxTextPreviewBytes].
  final bool truncated;
}

/// The Documents feature: picking documents with the system file picker, remembering them
/// for the signed-in user, and reading or opening them on request.
///
/// Documents never leave the device. Only metadata and a reference are stored, encrypted and
/// per user; contents are read only when the user opens a document, and only the part shown.
class DocumentService {
  DocumentService({
    required AuthService authService,
    DocumentPlatform? platform,
    DocumentStorage? storage,
  })  : _auth = authService,
        _platform = platform ?? DeviceDocumentPlatform(),
        _storage = storage ?? DocumentStorage();

  final AuthService _auth;
  final DocumentPlatform _platform;
  final DocumentStorage _storage;

  static const supportedTypes = DocumentType.values;

  /// How much of a text document is read for the in-app preview.
  static const maxTextPreviewBytes = 200 * 1024;

  final _random = Random();

  /// Serialises read-modify-write of the stored list.
  Future<void> _lock = Future.value();

  /// The signed-in user's documents, most recently added first. Metadata only.
  /// Throws [DocumentException].
  Future<List<DocumentItem>> list() => _guard('Loading documents', () async {
        final documents = await _storage.read(_userId());
        return documents..sort((a, b) => b.addedAt.compareTo(a.addedAt));
      }, 'Unable to load your documents.');

  /// One document's metadata, or null if the user has not added it.
  Future<DocumentItem?> find(String id) async => (await list()).where((d) => d.id == id).firstOrNull;

  /// Shows the system file picker and adds what the user picks. Cancelling returns a result
  /// with [AddDocumentsResult.cancelled] set. Throws [DocumentException].
  Future<AddDocumentsResult> addDocuments() async {
    final userId = _userId();
    final picked = await _guard(
      'Picking documents',
      () => _platform.pick([for (final t in supportedTypes) t.extension]),
      'Unable to add documents.',
    );
    if (picked.isEmpty) return const AddDocumentsResult();

    return _serial(() => _guard('Saving documents', () async {
          final documents = await _storage.read(userId);
          final added = <DocumentItem>[];
          var alreadyAdded = 0, unsupported = 0;
          final now = DateTime.now();
          for (final file in picked) {
            final name = file.info.name ?? file.name;
            final type = DocumentType.detect(name, mimeType: file.info.mimeType);
            if (type == null) {
              unsupported++;
              await _platform.release(file.reference);
              continue;
            }
            final existing = documents.indexWhere((d) => d.reference == file.reference);
            if (existing >= 0) {
              alreadyAdded++;
              documents[existing] = _withInfo(documents[existing], file.info);
              continue;
            }
            final document = DocumentItem(
              id: _newId(now),
              name: name,
              type: type,
              reference: file.reference,
              addedAt: now,
              mimeType: file.info.mimeType,
              size: file.info.size,
              modifiedAt: file.info.modifiedAt,
            );
            documents.add(document);
            added.add(document);
          }
          await _storage.write(userId, documents);
          return AddDocumentsResult(added: added, alreadyAdded: alreadyAdded, unsupported: unsupported);
        }, 'Unable to add documents.'));
  }

  /// Checks [document] is still there and returns it with up-to-date metadata.
  /// Throws [DocumentUnavailableException] if it is gone, [DocumentException] on other errors.
  Future<DocumentItem> refresh(DocumentItem document) async {
    final userId = _userId();
    final info = await _guard('Checking a document', () => _platform.info(document.reference));
    if (info == null) throw const DocumentUnavailableException();
    final updated = _withInfo(document, info);
    await _serial(() => _guard('Saving document details', () async {
          final documents = await _storage.read(userId);
          final index = documents.indexWhere((d) => d.id == document.id);
          if (index < 0) return;
          documents[index] = updated;
          await _storage.write(userId, documents);
        }));
    return updated;
  }

  /// The IDs of [documents] that can no longer be accessed. Documents that could not be
  /// checked are assumed to still be there.
  Future<Set<String>> findUnavailable(List<DocumentItem> documents) async {
    final missing = <String>{};
    await Future.wait(documents.map((d) async {
      try {
        if (await _platform.info(d.reference) == null) missing.add(d.id);
      } catch (e) {
        debugPrint('Checking a document failed: ${e.runtimeType}');
      }
    }));
    return missing;
  }

  /// Opens [document] in the device's viewer app, or with [anyApp] lets the user choose any
  /// app. Throws [DocumentException].
  Future<DocumentOpenResult> open(DocumentItem document, {bool anyApp = false}) =>
      _guard('Opening a document', () async {
        // Check first, so a deleted document is reported here rather than by the other app.
        if (await _platform.info(document.reference) == null) return DocumentOpenResult.unavailable;
        return _platform.open(
          document.reference,
          mimeType: document.mimeType ?? document.type.mimeType,
          anyApp: anyApp,
        );
      });

  /// The start of a TXT document for the in-app preview (at most [maxTextPreviewBytes]).
  /// Throws [DocumentUnavailableException] if it is gone, [DocumentException] on other errors.
  Future<DocumentText> readText(DocumentItem document) async {
    if (document.type != DocumentType.txt) {
      throw const DocumentException('This document cannot be previewed on this device.');
    }
    final bytes = await _guard('Reading a document', () => _platform.read(document.reference, maxTextPreviewBytes + 1));
    if (bytes == null) throw const DocumentUnavailableException();
    final truncated = bytes.length > maxTextPreviewBytes;
    final text = utf8.decode(truncated ? bytes.sublist(0, maxTextPreviewBytes) : bytes, allowMalformed: true);
    return DocumentText(text, truncated: truncated);
  }

  /// Removes [document] from Child Assist. The file itself is not touched.
  Future<void> remove(DocumentItem document) async {
    final userId = _userId();
    await _serial(() => _guard('Removing a document', () async {
          final documents = await _storage.read(userId);
          documents.removeWhere((d) => d.id == document.id);
          await _storage.write(userId, documents);
          if (!documents.any((d) => d.reference == document.reference) &&
              !await _storage.usedByOtherUser(userId, document.reference)) {
            await _platform.release(document.reference);
          }
        }, 'Unable to remove this document.'));
  }

  String _userId() {
    final id = _auth.currentUser?.id;
    if (id == null) throw const DocumentException('Please log in again.');
    return id;
  }

  String _newId(DateTime now) =>
      'doc_${now.microsecondsSinceEpoch.toRadixString(36)}${_random.nextInt(1 << 30).toRadixString(36)}';

  static DocumentItem _withInfo(DocumentItem document, DocumentInfo info) => document.copyWith(
        name: info.name,
        mimeType: info.mimeType,
        size: info.size,
        modifiedAt: info.modifiedAt,
      );

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
    _lock = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// Runs [action], turning any failure into a [DocumentException] that is safe to show.
  /// Only the error type is logged: messages can contain file names or paths.
  static Future<T> _guard<T>(String what, Future<T> Function() action, [String? message]) async {
    try {
      return await action();
    } on DocumentException {
      rethrow;
    } catch (e) {
      debugPrint('$what failed: ${e.runtimeType}');
      throw message == null ? const DocumentException() : DocumentException(message);
    }
  }
}
