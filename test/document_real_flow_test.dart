// The real Android document flow, end to end on the Dart side: the system picker's content URI
// -> the persistable grant -> the account's registry -> a restart -> search -> reading the text
// through ContentResolver. Unlike the other document tests, nothing here replaces
// DeviceDocumentPlatform: the app's real channel code runs against a simulated Android
// ContentResolver behind the "child_assist/documents" channel, so a break between Dart and the
// native side (a dropped URI, a path instead of a URI, a lost grant) fails here.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/app_services.dart';
import 'package:child_assist/features/contacts/services/message_handoff.dart';
import 'package:child_assist/features/documents/services/document_service.dart';

import 'support/fakes.dart';

const _pdf = 'application/pdf';
const _docx = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
const _txt = 'text/plain';

/// One document as an Android DocumentsProvider exposes it.
class _ProviderDocument {
  _ProviderDocument(this.uri, this.name, this.mimeType, {this.text = '', this.persistable = true, this.bytes});

  final String uri;
  final String name;
  final String mimeType;
  final String text;
  final List<int>? bytes;

  /// The provider allows a lasting grant (Downloads, local storage and Drive do; some third-party
  /// file managers do not).
  final bool persistable;

  bool deleted = false;
  bool revoked = false;

  /// The stream cannot be opened right now (e.g. a Drive file while offline).
  bool offline = false;
}

/// What the native side (MainActivity + DocumentAccess.kt + DocumentText.kt) answers, keyed by
/// content URI only, like ContentResolver. Grants that were not persisted are lost on restart.
class _AndroidDevice {
  final Map<String, _ProviderDocument> documents = {};
  final Set<String> persistedGrants = {};
  final Set<String> sessionGrants = {};
  List<String> nextPick = const [];
  final List<MethodCall> calls = [];

  _ProviderDocument add(String uri, String name, String mimeType,
      {String text = '', bool persistable = true, List<int>? bytes}) {
    return documents[uri] = _ProviderDocument(uri, name, mimeType, text: text, persistable: persistable, bytes: bytes);
  }

  /// The app process ends: only persisted grants survive.
  void restart() => sessionGrants.clear();

  bool _granted(String uri) => persistedGrants.contains(uri) || sessionGrants.contains(uri);

  _ProviderDocument? _accessible(String uri) {
    final d = documents[uri];
    if (d == null || d.deleted || d.revoked || !_granted(uri)) return null;
    return d;
  }

  Map<String, Object?> _meta(_ProviderDocument d) =>
      {'name': d.name, 'mimeType': d.mimeType, 'size': (d.bytes ?? utf8.encode(d.text)).length, 'modifiedAt': 1790000000000};

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final args = (call.arguments as Map?) ?? const {};
    final uri = args['uri'] as String?;
    if (call.method != 'pickDocuments' && (uri == null || !uri.startsWith('content://'))) {
      throw PlatformException(code: 'invalid_uri');
    }
    switch (call.method) {
      case 'pickDocuments':
        final picked = nextPick;
        nextPick = const [];
        return [
          for (final u in picked)
            () {
              final d = documents[u]!;
              sessionGrants.add(u);
              if (d.persistable) persistedGrants.add(u);
              return {..._meta(d), 'uri': u, 'persisted': d.persistable, 'readable': !d.offline};
            }(),
        ];
      case 'info':
        final d = _accessible(uri!);
        return d == null ? null : _meta(d);
      case 'read':
        final d = _accessible(uri!);
        if (d == null) return null;
        final bytes = d.bytes ?? utf8.encode(d.text);
        return Uint8List.fromList(bytes.take(args['maxBytes'] as int).toList());
      case 'extractText':
        final d = _accessible(uri!);
        if (d == null) return null;
        return {'status': 'ok', 'text': d.text, 'truncated': false};
      case 'release':
        persistedGrants.remove(uri);
        sessionGrants.remove(uri);
        return null;
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('child_assist/documents');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late _AndroidDevice android;
  late FakeBackend backend;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    android = _AndroidDevice();
    messenger.setMockMethodCallHandler(channel, android.handle);
    backend = FakeBackend();
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// A fresh app process (new services over the same secure storage), signed in as [email].
  Future<AppServices> launch(String email) async {
    if (!backend.users.values.any((u) => u['email'] == email)) backend.addUser('User', email);
    final services = backend.services(FakePermissionService(), documentPlatform: DeviceDocumentPlatform(isAndroid: true));
    await services.authService.login(email: email, password: testPassword);
    return services;
  }

  Future<DocumentItem> pick(AppServices services, String uri) async {
    android.nextPick = [uri];
    final result = await services.documentService.addDocuments(multiple: false);
    return result.documents.single;
  }

  group('Picking through the native SAF picker', () {
    test('1-2. the content URI is kept as is (never a path) and the grant is persisted', () async {
      const uri = 'content://com.android.providers.downloads.documents/document/msf%3A1000001234';
      android.add(uri, 'Python Notes.pdf', _pdf, text: 'Python notes about loops and functions in detail.');
      final services = await launch('a@example.com');

      final document = await pick(services, uri);

      expect(android.calls.first.method, 'pickDocuments');
      expect(android.calls.first.arguments, {'multiple': false});
      expect(document.reference, uri);
      expect(document.persisted, isTrue);
      expect(android.persistedGrants, contains(uri));
      // Metadata comes from the provider (ContentResolver query), not from a path.
      expect(document.name, 'Python Notes.pdf');
      expect(document.type, DocumentType.pdf);
      expect(document.size, isNotNull);
      expect(document.modifiedAt, isNotNull);
    });

    test('3. after an app restart the same document is found and read, without picking again', () async {
      const uri = 'content://com.android.externalstorage.documents/document/primary%3ADocuments%2Fnotes.pdf';
      const text = 'Chapter 1: Python lists, loops and dictionaries explained with examples.';
      android.add(uri, 'Python Notes.pdf', _pdf, text: text);
      await pick(await launch('a@example.com'), uri);

      android.restart();
      android.calls.clear();
      final services = await launch('a@example.com');

      final result = await services.documentService.search('Mujhe Python notes PDF do');
      expect(result.outcome, DocumentSearchOutcome.single);
      expect(result.single!.available, isTrue);
      final content = await services.documentService.readContent(result.single!.document);
      expect(content.text, text);
      expect(android.calls.where((c) => c.method == 'pickDocuments'), isEmpty, reason: 'no re-pick needed');
      final extract = android.calls.singleWhere((c) => c.method == 'extractText');
      expect((extract.arguments as Map)['uri'], uri);
    });

    test('a document the provider cannot open right now is not registered', () async {
      const uri = 'content://com.google.android.apps.docs.storage/document/acc%3D1%3Bdoc%3Dencoded%3Dabc';
      android.add(uri, 'Report.pdf', _pdf).offline = true;
      final services = await launch('a@example.com');
      android.nextPick = [uri];

      final result = await services.documentService.addDocuments(multiple: false);

      expect(result.unreadable, 1);
      expect(result.documents, isEmpty);
      expect(result.cancelled, isFalse);
      expect(await services.documentService.list(), isEmpty);
    });

    test('a provider without lasting grants: flagged, then unavailable after a restart', () async {
      const uri = 'content://com.example.filemanager.provider/root/Notes.txt';
      android.add(uri, 'Notes.txt', _txt, text: 'Some temporary notes with enough words to read.', persistable: false);
      final first = await pick(await launch('a@example.com'), uri);
      expect(first.persisted, isFalse);

      android.restart();
      final services = await launch('a@example.com');
      final stored = (await services.documentService.list()).single;
      expect(stored.persisted, isFalse);
      final result = await services.documentService.search('Notes txt');
      expect(result.matches.single.available, isFalse);
      await expectLater(services.documentService.readContent(stored), throwsA(isA<DocumentUnavailableException>()));
    });

    test('12. a Google Drive URI is used only through the channel, with no path assumed', () async {
      const uri = 'content://com.google.android.apps.docs.storage/document/acc%3D1%3Bdoc%3Dencoded%3DxYz';
      android.add(uri, 'TCS Project.docx', _docx, text: 'TCS project plan: milestones, owners and the delivery schedule.');
      final services = await launch('a@example.com');
      final document = await pick(services, uri);

      final content = await services.documentService.readContent(document);

      expect(content.text, startsWith('TCS project plan'));
      for (final call in android.calls.where((c) => c.method != 'pickDocuments')) {
        expect((call.arguments as Map)['uri'], uri);
      }
    });

    test('a non-content URI from the native side is never accepted', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => [
            {'uri': 'file:///storage/emulated/0/Download/x.pdf', 'name': 'x.pdf', 'persisted': true, 'readable': true},
          ]);
      final services = await launch('a@example.com');
      final result = await services.documentService.addDocuments(multiple: false);
      expect(result.documents, isEmpty);
    });
  });

  group('Reading the real content through ContentResolver', () {
    test('5-7. PDF and DOCX go to native extraction, TXT is read from the stream', () async {
      android
        ..add('content://p/1', 'Python Notes.pdf', _pdf, text: 'Real PDF text about Python generators and decorators.')
        ..add('content://p/2', 'Test.docx', _docx, text: 'Real DOCX text about the quarterly project review.')
        ..add('content://p/3', 'Notes.txt', _txt, text: 'Real TXT text: buy milk, call the school office.');
      final services = await launch('a@example.com');
      final pdf = await pick(services, 'content://p/1');
      final docx = await pick(services, 'content://p/2');
      final txt = await pick(services, 'content://p/3');

      expect((await services.documentService.readContent(pdf)).text, contains('generators'));
      expect((await services.documentService.readContent(docx)).text, contains('quarterly'));
      expect((await services.documentService.readContent(txt)).text, contains('school office'));
      final extracted = [
        for (final c in android.calls.where((c) => c.method == 'extractText')) (c.arguments as Map)['type'],
      ];
      expect(extracted, ['PDF', 'DOCX']);
      expect(android.calls.where((c) => c.method == 'read').map((c) => (c.arguments as Map)['uri']), ['content://p/3']);
    });

    test('TXT in UTF-16 or with a UTF-8 byte-order mark decodes to the real text', () async {
      const text = 'Hindi notes: नमस्ते, this is the real content of the file.';
      final utf16 = [0xFF, 0xFE, for (final u in text.codeUnits) ...[u & 0xFF, u >> 8]];
      android
        ..add('content://p/16', 'a.txt', _txt, bytes: utf16)
        ..add('content://p/8', 'b.txt', _txt, bytes: [0xEF, 0xBB, 0xBF, ...utf8.encode(text)]);
      final services = await launch('a@example.com');
      expect((await services.documentService.readContent(await pick(services, 'content://p/16'))).text, text);
      expect((await services.documentService.readContent(await pick(services, 'content://p/8'))).text, text);
    });

    test('11. a deleted or revoked document becomes unavailable and is never read', () async {
      android
        ..add('content://p/1', 'Python Notes.pdf', _pdf, text: 'Python text that is long enough to be read.')
        ..add('content://p/2', 'Python Loops.pdf', _pdf, text: 'Loops text that is long enough to be read.');
      final services = await launch('a@example.com');
      final notes = await pick(services, 'content://p/1');
      await pick(services, 'content://p/2');

      android.documents['content://p/1']!.revoked = true;
      final result = await services.documentService.search('Python PDF');
      expect(result.documents.map((d) => d.name), ['Python Loops.pdf'], reason: 'the revoked one is left out');
      await expectLater(services.documentService.readContent(notes), throwsA(isA<DocumentUnavailableException>()));

      android.documents['content://p/2']!.deleted = true;
      final gone = await services.documentService.search('Python loops');
      expect(gone.matches.single.available, isFalse);
    });
  });

  group('Account isolation', () {
    test('13. another account never sees, finds or reads the first account\'s documents', () async {
      android.add('content://p/1', 'Python Notes.pdf', _pdf, text: 'Private notes of account A, long enough.');
      final a = await launch('a@example.com');
      final document = await pick(a, 'content://p/1');
      await a.authService.logout();

      final b = await launch('b@example.com');
      expect(await b.documentService.list(), isEmpty);
      expect((await b.documentService.search('Python notes')).outcome, DocumentSearchOutcome.none);
      expect(await b.documentService.find(document.id), isNull);

      await b.authService.logout();
      final again = await launch('a@example.com');
      expect((await again.documentService.list()).single.id, document.id, reason: 'restored after login');
    });

    test('a registry entry tagged with another owner is never returned', () async {
      final storage = DocumentStorage();
      final item = DocumentItem(
        id: 'doc_abcdef',
        name: 'Secret.pdf',
        type: DocumentType.pdf,
        reference: 'content://p/9',
        addedAt: DateTime(2026, 10, 1),
      );
      await const FlutterSecureStorage().write(
        key: 'documents_userA',
        value: jsonEncode([
          {...item.toStorage(), 'owner': 'userB'},
        ]),
      );
      expect(await storage.read('userA'), isEmpty);
      await storage.write('userA', [item]);
      expect((await storage.read('userA')).single.id, item.id);
    });
  });

  group('Sharing and privacy', () {
    test('14. WhatsApp gets the exact content URI from the registry', () async {
      const share = MethodChannel('child_assist/share');
      MethodCall? sent;
      messenger.setMockMethodCallHandler(share, (call) async {
        sent = call;
        return 'opened';
      });
      addTearDown(() => messenger.setMockMethodCallHandler(share, null));
      const uri = 'content://com.android.providers.downloads.documents/document/42';
      android.add(uri, 'Python Notes.pdf', _pdf);
      final document = await pick(await launch('a@example.com'), uri);

      final result = await const NativeMessageHandoff().shareDocument(
        reference: document.reference,
        mimeType: document.mimeType!,
        phone: '9876543210',
        toWhatsApp: true,
      );

      expect(result, HandoffResult.opened);
      expect(sent!.method, 'shareDocument');
      expect((sent!.arguments as Map)['uri'], uri);
      expect((sent!.arguments as Map)['whatsApp'], isTrue);
    });

    test('15. the metadata that can leave the phone has no URI or path', () async {
      android.add('content://p/1', 'Python Notes.pdf', _pdf);
      final document = await pick(await launch('a@example.com'), 'content://p/1');
      final json = jsonEncode(document.toJson());
      expect(json, isNot(contains('content://')));
      expect(json, isNot(contains('reference')));
    });

    test('4. no code converts a content URI into a file path', () {
      final pathFromUri = RegExp(r'File\([^)]*[uU]ri[^)]*\.path|uri\.path|toFilePath\(|getPathFromUri|getRealPath');
      final offenders = <String>[];
      for (final dir in ['lib', 'android/app/src/main/kotlin']) {
        for (final file in Directory(dir).listSync(recursive: true).whereType<File>()) {
          if (!file.path.endsWith('.dart') && !file.path.endsWith('.kt')) continue;
          final lines = file.readAsLinesSync();
          for (var i = 0; i < lines.length; i++) {
            final line = lines[i].trim();
            if (line.startsWith('//') || line.startsWith('*') || line.startsWith('/*')) continue;
            if (pathFromUri.hasMatch(line)) offenders.add('${file.path}:${i + 1}');
          }
        }
      }
      expect(offenders, isEmpty);
    });
  });
}
