// Documents from folders the user connected once in the system folder picker: listed live every
// time Documents opens (no picker), new files appear on their own, lost access is reported, and
// chat finds, reads and shares them like any other document. Folders are kept per account.
// Every folder, file name and text here is generated: nothing depends on a fixed file or path.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/app_services.dart';
import 'package:child_assist/core/permissions/permission_service.dart';
import 'package:child_assist/features/contacts/models/contact_item.dart';
import 'package:child_assist/features/documents/services/document_service.dart';
import 'package:child_assist/features/documents/widgets/document_card.dart';
import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

final _random = Random();
String _word([int length = 7]) => String.fromCharCodes(List.generate(length, (_) => 97 + _random.nextInt(26)));
String _cap(String w) => '${w[0].toUpperCase()}${w.substring(1)}';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  late FakeBackend backend;
  late FakePermissionService os;
  late FakeDocumentPlatform device;
  late FakeMessageHandoff handoff;
  late AppServices services;

  Future<void> startApp(WidgetTester tester, {FakeDocumentPlatform? reuseDevice, FakeBackend? reuseBackend, List<ContactItem> book = const []}) async {
    backend = reuseBackend ?? FakeBackend();
    os = FakePermissionService();
    os.os[AppPermission.contacts] = PermissionState.granted;
    device = reuseDevice ?? FakeDocumentPlatform();
    handoff = FakeMessageHandoff();
    services = backend.services(
      os,
      documentPlatform: device,
      messageHandoff: handoff,
      contactsSource: FakeContactsSource(List.of(book)),
    );
    await services.authService.restoreSession();
    await tester.pumpWidget(MyApp(services: services));
    await tester.pumpAndSettle();
    if (find.text('Log in').evaluate().isNotEmpty) await logIn(tester, 'mansi@example.com');
  }

  /// A folder on the phone holding a few generated documents (and one unsupported file).
  ({FakeFolder folder, List<FakeDocumentFile> files}) folderWithFiles({String? name}) {
    final folder = device.addFolder(name ?? _cap(_word()));
    final files = [
      device.addFileTo(folder, '${_cap(_word())} Notes.pdf',
          mimeType: 'application/pdf', size: 245760, modifiedAt: DateTime(2026, 9, 14), content: 'PDF ${_word()} text ${_word()} more words here'),
      device.addFileTo(folder, '${_cap(_word())}.docx',
          mimeType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
          size: 1258291,
          modifiedAt: DateTime(2026, 9, 12),
          content: 'DOCX ${_word()} text ${_word()} more words here'),
      device.addFileTo(folder, '${_word()}.txt',
          mimeType: 'text/plain', size: 1200, modifiedAt: DateTime(2026, 9, 10), content: 'TXT ${_word()} text ${_word()} more words here'),
    ];
    device.addFileTo(folder, '${_word()}.jpg', mimeType: 'image/jpeg', size: 10);
    return (folder: folder, files: files);
  }

  Future<void> openDocuments(WidgetTester tester) => openDocumentsList(tester, services);

  Future<void> connect(WidgetTester tester, FakeFolder folder) async {
    device.willPickFolder(folder);
    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();
  }

  Future<void> backToHome(WidgetTester tester) async {
    await tester.pageBack();
    await tester.pumpAndSettle();
    // Let the "Showing documents from ..." message time out, as it would for the user.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  }

  group('Documents screen with a connected folder', () {
    testWidgets('choosing a folder once shows its documents; later visits show them at once, no picker',
        (tester) async {
      await startApp(tester);
      final (:folder, :files) = folderWithFiles();
      await openDocuments(tester);
      expect(find.text('Show your documents here'), findsOneWidget);

      // Cancelling the folder picker changes nothing.
      await tester.tap(find.text('Choose folder'));
      await tester.pumpAndSettle();
      expect(find.text('Show your documents here'), findsOneWidget);

      await connect(tester, folder);
      for (final f in files) {
        expect(find.text(f.name), findsOneWidget);
      }
      expect(find.byType(DocumentCard), findsNWidgets(3), reason: 'only PDF, DOC, DOCX and TXT');
      expect(find.text('Showing documents from ${folder.name}'), findsOneWidget);
      expect(find.text('In ${folder.name}'), findsNWidgets(3));

      // Next time: straight to the list, with no picker of any kind.
      await backToHome(tester);
      final pickers = (device.pickerShown, device.folderPickerShown);
      await openDocuments(tester);
      expect(find.text('Show your documents here'), findsNothing);
      expect(find.byType(DocumentCard), findsNWidgets(3));
      expect((device.pickerShown, device.folderPickerShown), pickers);

      // And after the app is restarted.
      await tester.pumpWidget(const SizedBox());
      await startApp(tester, reuseDevice: device, reuseBackend: backend);
      await openDocuments(tester);
      expect(find.byType(DocumentCard), findsNWidgets(3));
      expect((device.pickerShown, device.folderPickerShown), pickers);
    });

    testWidgets('files saved to the folder later appear; deleted ones disappear', (tester) async {
      await startApp(tester);
      final (:folder, :files) = folderWithFiles();
      await openDocuments(tester);
      await connect(tester, folder);

      final later = device.addFileTo(folder, '${_cap(_word())}.pdf', mimeType: 'application/pdf', size: 5000);
      device.deleteFile(files.first);
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();
      expect(find.text(later.name), findsOneWidget);
      expect(find.text(files.first.name), findsNothing);
      expect(device.pickerShown, 0);
    });

    testWidgets('lost folder access is explained, and the folder can be removed', (tester) async {
      await startApp(tester);
      final (:folder, :files) = folderWithFiles();
      await openDocuments(tester);
      await connect(tester, folder);

      device.revokeFolder(folder);
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();
      expect(find.text('Child Assist can no longer see "${folder.name}".'), findsOneWidget);
      expect(find.text(files.first.name), findsNothing);

      await tester.tap(find.text('Remove folder'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Remove folder')));
      await tester.pumpAndSettle();
      expect(find.text('Show your documents here'), findsOneWidget);
      expect(device.releasedFolders, [folder.reference]);
    });

    testWidgets('documents from a folder have Open, Share and WhatsApp but no single Remove', (tester) async {
      await startApp(tester);
      final (:folder, :files) = folderWithFiles();
      await openDocuments(tester);
      await connect(tester, folder);
      expect(find.text('WhatsApp'), findsNWidgets(3));
      expect(find.byTooltip('More options for ${files.first.name}'), findsNothing);

      await tester.tap(find.text('WhatsApp').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
      await tester.pumpAndSettle();
      expect(handoff.calls, ['whatsapp-document null: ${files.first.reference}'], reason: 'the newest one, listed first');
    });

    testWidgets("another account does not see this account's folder", (tester) async {
      await startApp(tester);
      final (:folder, files: _) = folderWithFiles();
      await openDocuments(tester);
      await connect(tester, folder);
      await backToHome(tester);
      await logOut(tester);
      await logIn(tester, 'ravi@example.com');
      await openDocuments(tester);
      expect(find.text('Show your documents here'), findsOneWidget);
      expect(find.byType(DocumentCard), findsNothing);
    });

    testWidgets('removing a folder another account still uses keeps its access', (tester) async {
      await startApp(tester);
      final (:folder, files: _) = folderWithFiles();
      await openDocuments(tester);
      await connect(tester, folder);
      await backToHome(tester);
      await logOut(tester);
      await logIn(tester, 'ravi@example.com');
      await openDocuments(tester);
      await connect(tester, folder);

      await tester.tap(find.byTooltip('Remove ${folder.name}'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Remove folder')));
      await tester.pumpAndSettle();
      expect(device.releasedFolders, isEmpty, reason: 'Mansi still uses it');
    });
  });

  test('a folder document id is stable, opaque and valid for the server', () {
    final reference = 'content://com.android.externalstorage.documents/tree/x/document/${_word()}';
    final id = DocumentService.folderDocumentId(reference);
    expect(id, DocumentService.folderDocumentId(reference));
    expect(id, matches(RegExp(r'^doc_[a-z0-9]{4,60}$')));
    expect(id, isNot(contains('content')));
    expect(DocumentService.folderDocumentId('$reference/2'), isNot(id));
  });

  group('Chat with folder documents', () {
    var next = 1;
    setUp(() => next = 1);

    Future<void> send(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField).last, text);
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
    }

    testWidgets('a folder document is found, read and shared like any other', (tester) async {
      final recipient = _cap(_word());
      final phone = '+91${List.generate(10, (_) => _random.nextInt(10)).join()}';
      await startApp(tester, book: [ContactItem(id: 'c1', displayName: recipient, phoneNumbers: [phone])]);
      final (:folder, :files) = folderWithFiles();
      await openDocuments(tester);
      await connect(tester, folder);
      await backToHome(tester);
      await openTab(tester, 'Chat');

      final pdf = files.first;
      final kw = pdf.name.split(' ').first.toLowerCase();

      // Reading: only that file's text is extracted and sent.
      backend.chatResponder = (_) => FakeChatReply('Let me read that document.', toolEvents: [
            {
              'kind': 'document_text',
              'status': 'device_lookup',
              'data': {
                'query': {'text': '$kw notes', 'type': null},
                'requestId': 'read${next++}',
              },
            },
          ]);
      await send(tester, '$kw notes me kya hai?');
      expect(device.extracted.single, startsWith(pdf.reference));
      expect(backend.documentReadBodies.single['text'], pdf.content);
      expect(backend.documentReadBodies.single['documentId'], DocumentService.folderDocumentId(pdf.reference));

      // Sharing: the same document goes to WhatsApp after confirmation.
      backend.chatResponder = (_) => FakeChatReply('Please confirm.', toolEvents: const [
            {'kind': 'send_action', 'status': 'confirmation_required'},
          ], pendingActions: [
            {
              'id': 'act1',
              'status': 'PENDING',
              'toolName': 'prepare_whatsapp',
              'type': 'SHARE_DOCUMENT',
              'channel': 'WHATSAPP',
              'summary': 'Do you want to share this document with $recipient on WhatsApp?',
              'contactQuery': recipient,
              'documentQuery': '$kw notes',
            },
          ]);
      await send(tester, 'Send $kw notes to $recipient on WhatsApp');
      final confirm = find.widgetWithText(FilledButton, 'Confirm');
      await tester.ensureVisible(confirm);
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(handoff.calls, ['whatsapp-document $phone: ${pdf.reference}']);
      expect(find.text('WhatsApp opened. Please tap Send to send the document.'), findsOneWidget);
    });
  });
}
