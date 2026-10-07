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
import 'document_search.dart';

export '../models/document_item.dart';
export 'document_search.dart';

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

/// Why a document's text could not be read for the assistant. [reason] is what the server is told.
enum DocumentTextProblem {
  /// The format cannot be read on this device (e.g. old DOC files).
  unsupported('unsupported', "I can't read the text of this type of document yet. You can still open it."),

  /// No readable text, e.g. a scanned PDF made of images.
  noText(
    'no_text',
    "I couldn't find any readable text in this document. It may be a scanned image, so I can't tell what it says.",
  ),
  encrypted('encrypted', 'This document is password-protected, so I couldn\'t read it.'),
  unreadable('unreadable', "I couldn't read this document. You can still open it.");

  const DocumentTextProblem(this.reason, this.message);

  final String reason;
  final String message;
}

/// The document is there, but its text cannot be read. [message] is safe to show.
class DocumentTextException extends DocumentException {
  DocumentTextException(this.problem) : super(problem.message);

  final DocumentTextProblem problem;
}

/// The readable text of one document, for one question to the assistant. Never stored.
class DocumentContent {
  const DocumentContent(this.text, {required this.truncated});

  final String text;

  /// Only the start of a longer document (see [DocumentService.maxContentChars]).
  final bool truncated;
}

/// What the platform extracted from a PDF or DOCX.
class ExtractedText {
  const ExtractedText.ok(String this.text, {this.truncated = false}) : problem = null;
  const ExtractedText.failed(DocumentTextProblem this.problem)
      : text = null,
        truncated = false;

  final String? text;
  final bool truncated;
  final DocumentTextProblem? problem;
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
  /// Shows the system file picker limited to [extensions], allowing several files, or only one
  /// unless [multiple]. Returns an empty list if the user cancels. May throw.
  Future<List<PickedDocument>> pick(List<String> extensions, {bool multiple = true});

  /// Current metadata, or null if the document can no longer be accessed. May throw.
  Future<DocumentInfo?> info(String reference);

  /// Opens the document in another app. With [anyApp] the user chooses from every app that
  /// accepts files, not only viewers registered for [mimeType]. May throw.
  Future<DocumentOpenResult> open(String reference, {required String mimeType, bool anyApp = false});

  /// Up to [maxBytes] from the start of the document, or null if it can no longer be accessed.
  /// May throw.
  Future<Uint8List?> read(String reference, int maxBytes);

  /// The readable text of a PDF or DOCX, up to [maxChars], extracted on the device. Null if the
  /// document can no longer be accessed. May throw.
  Future<ExtractedText?> extractText(String reference, DocumentType type, int maxChars);

  /// Gives up Child Assist's access to the document. Never throws.
  Future<void> release(String reference);

  /// Whether folders can be granted on this platform (Android's folder picker).
  bool get supportsFolders;

  /// Shows the system folder picker, so the user can grant read access to one folder. Returns
  /// null if they cancel. May throw.
  Future<PickedFolder?> pickFolder();

  /// The supported documents in a granted folder and its subfolders, or null if the folder is
  /// gone or its access was removed. May throw.
  Future<FolderListing?> listFolder(String reference);

  /// Gives up access to a folder. Never throws.
  Future<void> releaseFolder(String reference);
}

/// A folder the user granted in the system folder picker.
class PickedFolder {
  const PickedFolder({required this.reference, this.name});

  final String reference;
  final String? name;
}

/// What a granted folder holds right now.
class FolderListing {
  const FolderListing({required this.documents, this.truncated = false, this.folderName});

  final List<PickedDocument> documents;

  /// It held more documents than were listed.
  final bool truncated;
  final String? folderName;
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
  Future<List<PickedDocument>> pick(List<String> extensions, {bool multiple = true}) async {
    const androidOptions = FilePickerAndroidOptions(
      safOptions: AndroidSAFOptions(grant: AndroidSAFGrant.lifetime),
    );
    final files = multiple
        ? await FilePicker.pickFiles(
            type: FileType.custom,
            allowedExtensions: extensions,
            androidOptions: androidOptions,
          )
        : [
            ?await FilePicker.pickFile(
              type: FileType.custom,
              allowedExtensions: extensions,
              androidOptions: androidOptions,
            ),
          ];
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
  Future<ExtractedText?> extractText(String reference, DocumentType type, int maxChars) async {
    // PDF and DOCX text is extracted natively on Android only.
    if (!_android) return const ExtractedText.failed(DocumentTextProblem.unsupported);
    final map = await _channel.invokeMapMethod<String, Object?>('extractText', {
      'uri': reference,
      'type': type.label,
      'maxChars': maxChars,
    });
    if (map == null) return null;
    return switch (map['status']) {
      'ok' => ExtractedText.ok(map['text'] as String? ?? '', truncated: map['truncated'] == true),
      'encrypted' => const ExtractedText.failed(DocumentTextProblem.encrypted),
      'unsupported' => const ExtractedText.failed(DocumentTextProblem.unsupported),
      _ => const ExtractedText.failed(DocumentTextProblem.unreadable),
    };
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

  // Folders: Android's folder picker (ACTION_OPEN_DOCUMENT_TREE) grants read access to one folder
  // that lasts until the user removes it. It is the only way, without "all files access", for an
  // app to list documents saved by other apps. Other platforms have no folder grants.

  @override
  bool get supportsFolders => _android;

  @override
  Future<PickedFolder?> pickFolder() async {
    if (!_android) return null;
    final map = await _channel.invokeMapMethod<String, Object?>('pickFolder');
    final uri = map?['uri'];
    if (uri is! String) return null;
    return PickedFolder(reference: uri, name: map!['name'] as String?);
  }

  /// Subfolder levels and documents listed per folder, so a huge folder stays quick to open.
  static const _maxDepth = 4;
  static const _maxFiles = 1000;

  @override
  Future<FolderListing?> listFolder(String reference) async {
    if (!_android) return null;
    final map = await _channel.invokeMapMethod<String, Object?>('listFolder', {
      'tree': reference,
      'maxDepth': _maxDepth,
      'maxFiles': _maxFiles,
    });
    if (map == null) return null;
    return FolderListing(
      truncated: map['truncated'] == true,
      folderName: map['folderName'] as String?,
      documents: [
        for (final raw in (map['documents'] as List? ?? const []))
          if (raw is Map && raw['uri'] is String && raw['name'] is String)
            PickedDocument(
              reference: raw['uri'] as String,
              name: raw['name'] as String,
              info: DocumentInfo(
                name: raw['name'] as String,
                mimeType: raw['mimeType'] as String?,
                size: raw['size'] as int?,
                modifiedAt: raw['modifiedAt'] == null
                    ? null
                    : DateTime.fromMillisecondsSinceEpoch(raw['modifiedAt'] as int),
              ),
            ),
      ],
    );
  }

  @override
  Future<void> releaseFolder(String reference) async {
    if (!_android) return;
    try {
      await _channel.invokeMethod<void>('releaseFolder', {'tree': reference});
    } catch (e) {
      debugPrint('Releasing folder access failed: ${e.runtimeType}');
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

  // Connected folders, also per user: another account on the phone does not see them.
  static const _folderPrefix = 'document_folders_';

  Future<List<DocumentFolder>> readFolders(String userId) async {
    final raw = await _storage.read(key: '$_folderPrefix$userId');
    if (raw == null) return [];
    final list = jsonDecode(raw);
    if (list is! List) return [];
    return [
      for (final entry in list)
        if (entry is Map<String, dynamic>) ?DocumentFolder.fromStorage(entry),
    ];
  }

  Future<void> writeFolders(String userId, List<DocumentFolder> folders) => _storage.write(
        key: '$_folderPrefix$userId',
        value: jsonEncode([for (final f in folders) f.toStorage()]),
      );

  /// Whether another account on this device has also connected the folder at [reference].
  Future<bool> folderUsedByOtherUser(String userId, String reference) async {
    final all = await _storage.readAll();
    for (final entry in all.entries) {
      if (!entry.key.startsWith(_folderPrefix) || entry.key == '$_folderPrefix$userId') continue;
      final list = jsonDecode(entry.value);
      if (list is List && list.any((f) => f is Map && f['reference'] == reference)) return true;
    }
    return false;
  }

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
  const AddDocumentsResult({
    this.added = const [],
    this.alreadyAdded = 0,
    this.unsupported = 0,
    this.documents = const [],
  });

  final List<DocumentItem> added;

  /// Every supported document picked, newly added or already in the list, in the order picked.
  final List<DocumentItem> documents;

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

  /// The signed-in user's documents: those picked one by one, and those in the folders they
  /// connected (listed live from the phone). Most recent first. Metadata only.
  /// Throws [DocumentException].
  Future<List<DocumentItem>> list({bool refresh = false}) async => (await library(refresh: refresh)).documents;

  /// How long a folder listing is reused by searches before the folder is listed again.
  static const folderListingMaxAge = Duration(seconds: 30);

  /// The last folder listing per user: listing a big folder takes a moment, and chat searches
  /// several times in a row. The Documents screen always lists afresh.
  final Map<String, ({DateTime at, List<DocumentItem> documents, List<FolderStatus> folders})> _folderCache = {};

  /// Everything the Documents screen shows: the documents, and how each connected folder looked.
  /// [refresh] lists the folders again even if they were listed moments ago.
  /// Throws [DocumentException].
  Future<DocumentLibrary> library({bool refresh = false}) => _guard('Loading documents', () async {
        final userId = _userId();
        final picked = await _storage.read(userId);
        final listing = await _listFolders(userId, refresh: refresh);
        // A file picked on its own and also inside a connected folder is shown once.
        final seen = {for (final d in picked) _sameFileKey(d)};
        final documents = [
          ...picked,
          for (final d in listing.documents)
            if (!seen.contains(_sameFileKey(d))) d,
        ]..sort((a, b) => b.addedAt.compareTo(a.addedAt));
        return DocumentLibrary(documents: documents, folders: listing.folders);
      }, 'Unable to load your documents.');

  static String _sameFileKey(DocumentItem d) => '${d.name}|${d.size}|${d.modifiedAt?.millisecondsSinceEpoch}';

  Future<({DateTime at, List<DocumentItem> documents, List<FolderStatus> folders})> _listFolders(
    String userId, {
    required bool refresh,
  }) async {
    final cached = _folderCache[userId];
    if (!refresh && cached != null && DateTime.now().difference(cached.at) < folderListingMaxAge) return cached;

    final documents = <DocumentItem>[];
    final statuses = <FolderStatus>[];
    for (final folder in await _storage.readFolders(userId)) {
      FolderListing? listing;
      try {
        listing = await _platform.listFolder(folder.reference);
      } catch (e) {
        debugPrint('Listing a folder failed: ${e.runtimeType}');
      }
      if (listing == null) {
        statuses.add(FolderStatus(folder: folder, available: false));
        continue;
      }
      var count = 0;
      for (final file in listing.documents) {
        final name = file.info.name ?? file.name;
        final type = DocumentType.detect(name, mimeType: file.info.mimeType);
        if (type == null) continue;
        count++;
        documents.add(DocumentItem(
          id: folderDocumentId(file.reference),
          name: name,
          type: type,
          reference: file.reference,
          // Not added one by one: sorted by when the file last changed, or when the folder was added.
          addedAt: file.info.modifiedAt ?? folder.addedAt,
          mimeType: file.info.mimeType,
          size: file.info.size,
          modifiedAt: file.info.modifiedAt,
          folderId: folder.id,
          folderName: listing.folderName ?? folder.name,
        ));
      }
      statuses.add(FolderStatus(folder: folder, available: true, count: count, truncated: listing.truncated));
    }
    final result = (at: DateTime.now(), documents: documents, folders: statuses);
    _folderCache[userId] = result;
    return result;
  }

  /// The id of a document in a connected folder: the same every time it is listed, opaque, and
  /// in the same "doc_..." form as other document ids. Derived from the private reference with a
  /// one-way hash (64-bit FNV-1a), so it reveals nothing about the file's location.
  static String folderDocumentId(String reference) {
    var hash = 0xcbf29ce4_84222325; // FNV-1a offset basis
    for (final unit in utf8.encode(reference)) {
      hash ^= unit;
      hash *= 0x100_000001b3; // FNV prime
    }
    return 'doc_f${BigInt.from(hash).toUnsigned(64).toRadixString(36)}';
  }

  /// The folders the signed-in user connected. Throws [DocumentException].
  Future<List<DocumentFolder>> folders() =>
      _guard('Loading folders', () => _storage.readFolders(_userId()), 'Unable to load your folders.');

  /// Shows the system folder picker; the folder the user chooses is connected, so its documents
  /// show every time Documents opens. Returns null if they cancel. Throws [DocumentException].
  Future<DocumentFolder?> connectFolder() async {
    final userId = _userId();
    final picked = await _guard('Picking a folder', _platform.pickFolder, 'Unable to connect this folder.');
    if (picked == null) return null;
    return _serial(() => _guard('Saving a folder', () async {
          final folders = await _storage.readFolders(userId);
          final existing = folders.where((f) => f.reference == picked.reference).firstOrNull;
          if (existing != null) return existing;
          final folder = DocumentFolder(
            id: 'fld_${_newId(DateTime.now()).substring(4)}',
            name: picked.name ?? 'Folder',
            reference: picked.reference,
            addedAt: DateTime.now(),
          );
          await _storage.writeFolders(userId, [...folders, folder]);
          _folderCache.remove(userId);
          return folder;
        }, 'Unable to connect this folder.'));
  }

  /// Stops showing [folder]'s documents. The files themselves are not touched.
  Future<void> disconnectFolder(DocumentFolder folder) async {
    final userId = _userId();
    await _serial(() => _guard('Removing a folder', () async {
          final folders = await _storage.readFolders(userId)
            ..removeWhere((f) => f.id == folder.id);
          await _storage.writeFolders(userId, folders);
          _folderCache.remove(userId);
          if (!folders.any((f) => f.reference == folder.reference) &&
              !await _storage.folderUsedByOtherUser(userId, folder.reference)) {
            await _platform.releaseFolder(folder.reference);
          }
        }, 'Unable to remove this folder.'));
  }

  /// Whether folders can be connected on this device.
  bool get supportsFolders => _platform.supportsFolders;

  /// One document's metadata, or null if the signed-in user has not added it. Only ever looks in
  /// that user's own list, so an id from anywhere else (another account, the server, a crafted
  /// message) can never reach someone else's document.
  Future<DocumentItem?> find(String id) async => (await list()).where((d) => d.id == id).firstOrNull;

  /// Searches the signed-in user's documents by name, e.g. "Python PDF" (see [DocumentSearch]),
  /// and checks whether each match is still on the device. Metadata only: nothing is read from
  /// the files and nothing leaves the phone. Throws [DocumentException].
  ///
  /// Documents Android no longer grants access to (deleted, moved or revoked) are left out when
  /// any match is still there; only when every match is gone are they returned, marked
  /// unavailable, so the user is told rather than shown "not found".
  Future<DocumentSearchResult> search(String? text, {DocumentType? type, int limit = 10}) async {
    final result = DocumentSearch.search(await list(), text, type: type, limit: limit);
    if (result.matches.isEmpty) return result;
    final missing = await findUnavailable(result.documents);
    final checked = [for (final m in result.matches) m.withAvailability(!missing.contains(m.document.id))];
    final available = checked.where((m) => m.available).toList();
    return DocumentSearchResult(
      words: result.words,
      type: result.type,
      matches: available.isNotEmpty ? available : checked,
    );
  }

  /// Shows the system file picker and adds what the user picks (only one file unless
  /// [multiple]). Cancelling returns a result with [AddDocumentsResult.cancelled] set.
  /// Throws [DocumentException].
  Future<AddDocumentsResult> addDocuments({bool multiple = true}) async {
    final userId = _userId();
    final picked = await _guard(
      'Picking documents',
      () => _platform.pick([for (final t in supportedTypes) t.extension], multiple: multiple),
      'Unable to add documents.',
    );
    if (picked.isEmpty) return const AddDocumentsResult();

    return _serial(() => _guard('Saving documents', () async {
          final documents = await _storage.read(userId);
          final added = <DocumentItem>[];
          final all = <DocumentItem>[];
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
              all.add(documents[existing]);
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
            all.add(document);
          }
          await _storage.write(userId, documents);
          return AddDocumentsResult(
            added: added,
            alreadyAdded: alreadyAdded,
            unsupported: unsupported,
            documents: all,
          );
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

  /// The most text read from one document for the assistant (the server accepts no more).
  static const maxContentChars = 150000;

  /// Fewer letters or digits than this is not meaningful text (e.g. a scanned PDF's stray marks).
  static const _minMeaningfulChars = 20;

  /// The readable text of [document], extracted on this phone, for ONE question the user asked
  /// the assistant about it. Checks the document is still there first. TXT is read directly; PDF
  /// and DOCX are extracted by the platform; DOC is not supported. Nothing is stored.
  ///
  /// Throws [DocumentUnavailableException] if it is gone, [DocumentTextException] if its text
  /// cannot be read, [DocumentException] on other errors.
  Future<DocumentContent> readContent(DocumentItem document) async {
    _userId();
    final info = await _guard('Checking a document', () => _platform.info(document.reference));
    if (info == null) throw const DocumentUnavailableException();

    final DocumentContent content;
    switch (document.type) {
      case DocumentType.doc:
        throw DocumentTextException(DocumentTextProblem.unsupported);
      case DocumentType.txt:
        // UTF-8 uses at most 4 bytes per character.
        final bytes = await _guard('Reading a document', () => _platform.read(document.reference, maxContentChars * 4 + 1));
        if (bytes == null) throw const DocumentUnavailableException();
        final text = utf8.decode(bytes, allowMalformed: true);
        content = text.length > maxContentChars
            ? DocumentContent(text.substring(0, maxContentChars), truncated: true)
            : DocumentContent(text, truncated: bytes.length > maxContentChars * 4);
      case DocumentType.pdf || DocumentType.docx:
        final extracted = await _guard(
          'Extracting document text',
          () => _platform.extractText(document.reference, document.type, maxContentChars),
        );
        if (extracted == null) throw const DocumentUnavailableException();
        if (extracted.problem != null) throw DocumentTextException(extracted.problem!);
        final text = extracted.text!;
        content = DocumentContent(
          text.length > maxContentChars ? text.substring(0, maxContentChars) : text,
          truncated: extracted.truncated || text.length > maxContentChars,
        );
    }
    final meaningful = RegExp(r'[\p{L}\p{N}]', unicode: true).allMatches(content.text).length;
    if (meaningful < _minMeaningfulChars) throw DocumentTextException(DocumentTextProblem.noText);
    return content;
  }

  /// Removes [document] from Child Assist. The file itself is not touched.
  Future<void> remove(DocumentItem document) async {
    final userId = _userId();
    if (document.inFolder) {
      throw const DocumentException('This document is shown from a folder you connected. Remove the folder instead.');
    }
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
