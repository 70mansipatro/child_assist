// AI Chat document requests ("Mujhe Python notes PDF do", "TCS wali PDF do", "Python notes me kya
// hai?", "Python notes TCS ko WhatsApp par bhejo"): every request is searched on the phone over the
// signed-in user's own documents that Android granted Child Assist, never just the document opened
// last. The assistant only ever receives the words of the request; URIs, paths and the document
// list stay on the phone.
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
String _digits(int n) => List.generate(n, (_) => _random.nextInt(10)).join();
String _word([int length = 7]) => String.fromCharCodes(List.generate(length, (_) => 97 + _random.nextInt(26)));
String _cap(String w) => '${w[0].toUpperCase()}${w.substring(1)}';

const _pdf = 'application/pdf';
const _doc = 'application/msword';
const _docx = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
const _txt = 'text/plain';

DocumentItem _item(String name) => DocumentItem(
      id: 'doc_${_word(8)}',
      name: name,
      type: DocumentType.detect(name)!,
      reference: 'content://test/${_word()}',
      addedAt: DateTime(2026, 10, 1),
    );

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  // -------------------------------------------------------------------------------------------
  group('Search rules', () {
    final python = _item('Python Notes.pdf');
    final assignment = _item('Python Assignment.pdf');
    final tcs = _item('TCS_Offer_Letter.pdf');
    final notesDocx = _item('notes.docx');
    final txt = _item('shopping list.txt');
    final all = [python, assignment, tcs, notesDocx, txt];

    test('1. "Mujhe Python notes PDF do" finds Python Notes.pdf', () {
      final result = DocumentSearch.search(all, 'Mujhe Python notes PDF do');
      expect(result.words, ['python', 'notes']);
      expect(result.type, DocumentType.pdf);
      expect(result.outcome, DocumentSearchOutcome.single);
      expect(result.single!.document, python);
    });

    test('2. "Python ka document bhejo" / "TCS wali PDF do" find the matching document', () {
      final docs = [python, tcs, notesDocx];
      expect(DocumentSearch.search(docs, 'Python ka document bhejo').single?.document, python);
      expect(DocumentSearch.search(docs, 'Python document do').single?.document, python);
      expect(DocumentSearch.search(all, 'TCS wali PDF do').single?.document, tcs);
    });

    test('3. an exact file name is matched ("Meri notes.docx do")', () {
      final result = DocumentSearch.search(all, 'Meri notes.docx do');
      expect(result.type, DocumentType.docx);
      expect(result.single?.document, notesDocx);
      expect(DocumentSearch.search(all, 'TCS_Offer_Letter.pdf').single?.document, tcs);
    });

    test('4. matching ignores case', () {
      for (final text in ['PYTHON NOTES', 'python notes', 'PyThOn NoTeS pdf']) {
        expect(DocumentSearch.search(all, text).single?.document, python, reason: text);
      }
    });

    test('5. PDF, DOC, DOCX and TXT filtering', () {
      final kw = _word();
      final pdf = _item('$kw.pdf'), doc = _item('$kw.doc'), docx = _item('$kw.docx'), text = _item('$kw.txt');
      final docs = [pdf, doc, docx, text];
      expect(DocumentSearch.search(docs, '$kw pdf').single?.document, pdf);
      expect(DocumentSearch.search(docs, '$kw docx').single?.document, docx);
      expect(DocumentSearch.search(docs, '$kw txt').single?.document, text);
      // "doc" in speech means "document", so DOC is chosen by the assistant's type, not the word.
      expect(DocumentSearch.search(docs, kw, type: DocumentType.doc).single?.document, doc);
      // "Mujhe woh TXT file do": the only TXT.
      expect(DocumentSearch.search(all, 'Mujhe woh TXT file do').single?.document, txt);
    });

    test('6. several matches need a choice ("Python PDF do")', () {
      final questions = _item('Python Questions.pdf');
      final result = DocumentSearch.search([python, assignment, questions, tcs], 'Python PDF do');
      expect(result.outcome, DocumentSearchOutcome.multiple);
      expect(result.documents, unorderedEquals([python, assignment, questions]));
      expect(result.single, isNull, reason: 'never guessed');
    });

    test('7. no match says so plainly', () {
      final result = DocumentSearch.search(all, 'Give me Java Notes PDF');
      expect(result.outcome, DocumentSearchOutcome.none);
      expect(result.notFoundMessage, "I couldn't find a matching java notes PDF in the documents Child Assist can access.");
    });
  });

  // -------------------------------------------------------------------------------------------
  late FakeBackend backend;
  late FakeDocumentPlatform device;
  late FakeMessageHandoff handoff;
  late AppServices services;

  Future<void> startApp(WidgetTester tester, {List<ContactItem> book = const []}) async {
    backend = FakeBackend();
    device = FakeDocumentPlatform();
    handoff = FakeMessageHandoff();
    final os = FakePermissionService();
    os.os[AppPermission.contacts] = PermissionState.granted;
    services = backend.services(
      os,
      documentPlatform: device,
      messageHandoff: handoff,
      contactsSource: FakeContactsSource(List.of(book)),
    );
    await services.authService.restoreSession();
    await tester.pumpWidget(MyApp(services: services));
    await tester.pumpAndSettle();
    await logIn(tester, 'mansi@example.com');
  }

  Future<List<DocumentItem>> addDocuments(List<FakeDocumentFile> files) async {
    device.willPick(files);
    return (await services.documentService.addDocuments()).added;
  }

  FakeDocumentFile file(String name, {String content = ''}) => device.addFile(
        name,
        mimeType: switch (DocumentType.detect(name)) {
          DocumentType.pdf => _pdf,
          DocumentType.doc => _doc,
          DocumentType.docx => _docx,
          _ => _txt,
        },
        size: 245760,
        modifiedAt: DateTime(2026, 9, 14, 10, 30),
        content: content,
      );

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).last, text);
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
  }

  Future<void> tapIt(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// The server's reply to a document request: the search is handed to the phone.
  void respondWithSearch(String? text, {String? type}) {
    backend.chatResponder = (_) => FakeChatReply(
          'Let me look for that document on your phone.',
          toolEvents: [
            {
              'kind': 'documents',
              'status': 'device_lookup',
              'data': {
                'query': {'text': text, 'type': type, 'limit': 10},
              },
            },
          ],
        );
  }

  void respondWithRead(String? words, {String requestId = 'read1'}) {
    backend.chatResponder = (_) => FakeChatReply(
          'Let me read that document.',
          toolEvents: [
            {
              'kind': 'document_text',
              'status': 'device_lookup',
              'data': {
                'query': {'text': words, 'type': null},
                'requestId': requestId,
              },
            },
          ],
        );
  }

  /// Everything the app sent to the server, which is all the assistant could ever be given.
  String everythingSent() => [
        ...backend.chatRequests,
        ...backend.chatActionBodies,
        ...backend.documentReadBodies.map((b) => {...b}..remove('text')),
      ].toString();

  // -------------------------------------------------------------------------------------------
  group('AI Chat', () {
    testWidgets('1. "Mujhe Python notes PDF do" shows the Python Notes.pdf card', (tester) async {
      await startApp(tester);
      await addDocuments([file('Python Notes.pdf'), file('Python Assignment.pdf'), file('TCS Report.pdf')]);
      await openTab(tester, 'Chat');
      // Even if the assistant passes the whole sentence, the phone still finds the one document.
      respondWithSearch('Mujhe Python notes PDF do');
      await send(tester, 'Mujhe Python notes PDF do');

      expect(find.text('Python Notes.pdf'), findsOneWidget);
      expect(find.text('Available on this phone'), findsOneWidget);
      expect(find.textContaining('240 KB'), findsOneWidget);
      expect(find.textContaining('Modified Sep 14, 2026'), findsOneWidget);
      for (final action in ['Open', 'Share', 'Send on WhatsApp']) {
        expect(find.text(action), findsOneWidget, reason: action);
      }
      expect(find.text('Python Assignment.pdf'), findsNothing);
    });

    testWidgets('a request after another document was opened is a new search, not the old document',
        (tester) async {
      await startApp(tester);
      await addDocuments([file('Python Notes.pdf'), file('TCS Report.pdf')]);
      await openTab(tester, 'Chat');
      respondWithSearch('python notes', type: 'PDF');
      await send(tester, 'Mujhe Python notes PDF do');
      expect(find.text('Python Notes.pdf'), findsOneWidget);

      respondWithSearch('tcs', type: 'PDF');
      await send(tester, 'TCS wali PDF do');
      expect(find.text('TCS Report.pdf'), findsOneWidget);
    });

    testWidgets('6. "Python PDF do" with three matches asks which one; nothing is chosen for the user',
        (tester) async {
      await startApp(tester);
      await addDocuments([file('Python Notes.pdf'), file('Python Assignment.pdf'), file('Python Questions.pdf')]);
      await openTab(tester, 'Chat');
      respondWithSearch('python', type: 'PDF');
      await send(tester, 'Python PDF do');

      expect(find.text('I found 3 documents matching "python PDF". Which one do you want?'), findsOneWidget);
      expect(find.text('Send on WhatsApp'), findsNothing);
      await tapIt(tester, find.text('Python Assignment.pdf'));
      expect(find.text('Send on WhatsApp'), findsOneWidget);
      expect(find.text('Python Notes.pdf'), findsNothing);
    });

    testWidgets('7. "Give me Java Notes PDF" with no such document: not found, nothing invented', (tester) async {
      await startApp(tester);
      await addDocuments([file('Python Notes.pdf')]);
      await openTab(tester, 'Chat');
      respondWithSearch('java notes', type: 'PDF');
      await send(tester, 'Give me Java Notes PDF');

      expect(
        find.text("I couldn't find a matching java notes PDF in the documents Child Assist can access."),
        findsOneWidget,
      );
      expect(find.byType(DocumentTypeBadge), findsNothing);
    });

    testWidgets('8. a document granted before is found after the app restarts', (tester) async {
      await startApp(tester);
      await addDocuments([file('Python Notes.pdf')]);

      // A fresh app on the same phone: same encrypted storage, same Android grant, no picker.
      final restarted = backend.services(FakePermissionService(), documentPlatform: device);
      await restarted.authService.restoreSession();
      final pickerShown = device.pickerShown;
      final result = await restarted.documentService.search('Mujhe Python notes PDF do');
      expect(result.single?.document.name, 'Python Notes.pdf');
      expect(result.single?.available, isTrue);
      expect(device.pickerShown, pickerShown, reason: 'found without asking for the file again');
    });

    testWidgets('9. a revoked or deleted document is not returned as available', (tester) async {
      await startApp(tester);
      final kept = file('Python Notes.pdf');
      final revoked = file('Python Notes old.pdf');
      await addDocuments([kept, revoked]);
      device.deleteFile(revoked); // Android no longer grants access to it.

      final result = await services.documentService.search('python notes');
      expect(result.documents.map((d) => d.name), ['Python Notes.pdf']);
      expect(result.outcome, DocumentSearchOutcome.single, reason: 'the only one still accessible');

      // When the only match is gone, it is reported as unavailable, never offered.
      device.deleteFile(kept);
      final gone = await services.documentService.search('python notes');
      expect(gone.matches.every((m) => !m.available), isTrue);

      await openTab(tester, 'Chat');
      respondWithSearch('python notes');
      await send(tester, 'Python notes do');
      // Both are gone: each is shown as unavailable and neither can be chosen, opened or shared.
      expect(find.text('This document is no longer available.'), findsNWidgets(2));
      for (final tile in tester.widgetList<ListTile>(find.byType(ListTile))) {
        expect(tile.enabled, isFalse);
      }
      expect(find.text('Send on WhatsApp'), findsNothing);
      expect(find.text('Open'), findsNothing);
    });

    testWidgets("10. user B never sees user A's documents", (tester) async {
      await startApp(tester);
      await addDocuments([file('Python Notes.pdf')]);
      await logOut(tester);
      await logIn(tester, 'ravi@example.com');

      expect((await services.documentService.search('python notes')).outcome, DocumentSearchOutcome.none);
      await openTab(tester, 'Chat');
      respondWithSearch('python notes', type: 'PDF');
      await send(tester, 'Mujhe Python notes PDF do');
      expect(find.textContaining("I couldn't find a matching"), findsOneWidget);
      expect(find.text('Python Notes.pdf'), findsNothing);
    });

    testWidgets('11, 12. the server (and so the AI) never gets a URI, path or the document list',
        (tester) async {
      await startApp(tester);
      final others = [for (var i = 0; i < 5; i++) '${_cap(_word())} Secret.pdf'];
      final python = file('Python Notes.pdf', content: 'Python notes: variables, loops and functions explained.');
      await addDocuments([python, for (final name in others) file(name)]);
      await openTab(tester, 'Chat');

      respondWithSearch('python notes', type: 'PDF');
      await send(tester, 'Mujhe Python notes PDF do');
      respondWithRead('python notes');
      await send(tester, 'Python notes me kya hai?');
      expect(backend.documentReadCalls, ['answer read1']);

      final sent = everythingSent();
      expect(sent, isNot(contains('content://')));
      expect(sent, isNot(contains('/storage/')));
      expect(sent, isNot(contains('file://')));
      for (final name in others) {
        expect(sent, isNot(contains(name)), reason: 'other documents are never listed to the server');
      }
      // The read sends exactly one document's text, no reference.
      expect(backend.documentReadBodies.single.keys,
          unorderedEquals(['documentId', 'name', 'type', 'text', 'truncated', 'conversationId']));
    });

    testWidgets('14, 15. "Python notes me kya hai?" answers from that document\'s real text', (tester) async {
      await startApp(tester);
      final text = 'Python ${_word()} overview\nLoops repeat code. Functions group code.';
      final python = file('Python Notes.pdf', content: text);
      await addDocuments([python, file('TCS Report.pdf', content: 'TCS ${_word()} quarterly report text.')]);
      await openTab(tester, 'Chat');
      respondWithRead('python notes');
      await send(tester, 'Python notes me kya hai?');

      expect(device.extracted, hasLength(1), reason: 'only the matching document is read');
      expect(device.extracted.single, startsWith(python.reference));
      expect(backend.documentReadBodies.single['text'], text);
      expect(backend.documentReadBodies.single['name'], 'Python Notes.pdf');
      expect(find.text('This document starts with: ${text.split('\n').first}'), findsOneWidget);
      expect(find.text('Answered from this document.'), findsOneWidget);
      expect(handoff.calls, isEmpty);
    });

    testWidgets('13. "Python notes TCS ko WhatsApp par bhejo": confirm first; WhatsApp opens, never "sent"',
        (tester) async {
      final recipient = 'TCS ${_cap(_word())}';
      final phone = '+91${_digits(10)}';
      await startApp(tester, book: [ContactItem(id: 'c1', displayName: recipient, phoneNumbers: [phone])]);
      final python = file('Python Notes.pdf');
      await addDocuments([python, file('Python Assignment.pdf')]);
      await openTab(tester, 'Chat');
      backend.chatResponder = (_) => FakeChatReply(
            'Please check and confirm.',
            toolEvents: const [
              {'kind': 'send_action', 'status': 'confirmation_required'},
            ],
            pendingActions: [
              {
                'id': 'act1',
                'status': 'PENDING',
                'toolName': 'prepare_whatsapp',
                'type': 'SHARE_DOCUMENT',
                'channel': 'WHATSAPP',
                'summary': 'Do you want to share this document with $recipient on WhatsApp?',
                'contactQuery': recipient,
                'documentQuery': 'python notes',
              },
            ],
          );
      await send(tester, 'Python notes $recipient ko WhatsApp par bhejo');

      expect(find.text('Python Notes.pdf (PDF)'), findsOneWidget);
      expect(handoff.calls, isEmpty, reason: 'nothing opens before Confirm');
      expect(backend.chatActions.where((a) => a.startsWith('confirm')), isEmpty);

      await tapIt(tester, find.widgetWithText(FilledButton, 'Confirm'));
      expect(handoff.calls, ['whatsapp-document $phone: ${python.reference}']);
      expect(find.text('WhatsApp opened. Please tap Send to send the document.'), findsOneWidget);
      expect(find.textContaining(RegExp(r'\b(sent successfully|delivered)\b', caseSensitive: false)), findsNothing);
      expect(everythingSent(), isNot(contains('content://')));
    });
  });
}
