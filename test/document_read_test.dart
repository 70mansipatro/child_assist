// The Documents screen showing what Child Assist can already access (without opening the
// picker), and the assistant answering questions about what is INSIDE one document: the document
// is found among the user's own documents, checked, read on the phone, and only its text is sent.
// Every document name and text here is generated: nothing depends on a fixed document.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/app_services.dart';
import 'package:child_assist/features/documents/services/document_service.dart';
import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

final _random = Random();
String _word([int length = 7]) => String.fromCharCodes(List.generate(length, (_) => 97 + _random.nextInt(26)));
String _cap(String w) => '${w[0].toUpperCase()}${w.substring(1)}';

/// Generated document text: a first line naming the topic, then a few sentences.
String _content(String topic) => [
      '${_cap(topic)} ${_word()} overview',
      for (var i = 0; i < 4; i++) 'Section $i explains ${_word()} and ${_word()} in detail.',
    ].join('\n');

const _pdf = 'application/pdf';
const _docx = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  late FakeBackend backend;
  late FakeDocumentPlatform device;
  late FakeMessageHandoff handoff;
  late AppServices services;

  Future<void> startApp(WidgetTester tester) async {
    backend = FakeBackend();
    device = FakeDocumentPlatform();
    handoff = FakeMessageHandoff();
    services = backend.services(FakePermissionService(), documentPlatform: device, messageHandoff: handoff);
    await services.authService.restoreSession();
    await tester.pumpWidget(MyApp(services: services));
    await tester.pumpAndSettle();
    await logIn(tester, 'mansi@example.com');
  }

  Future<List<DocumentItem>> addDocuments(List<FakeDocumentFile> files) async {
    device.willPick(files);
    return (await services.documentService.addDocuments()).added;
  }

  FakeDocumentFile pdf(String name, {String content = '', bool encrypted = false}) => device.addFile(
        name,
        mimeType: _pdf,
        size: 245760,
        modifiedAt: DateTime(2026, 9, 14, 10, 30),
        content: content,
        encrypted: encrypted,
      );
  FakeDocumentFile docx(String name, {String content = ''}) =>
      device.addFile(name, mimeType: _docx, size: 1258291, modifiedAt: DateTime(2026, 9, 13), content: content);

  Future<void> tapIt(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).last, text);
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
  }

  var nextRead = 1;

  /// What the server returns for a question about a document: a read request for the phone.
  void respondWithRead(String? words, {String? type}) {
    backend.chatResponder = (_) => FakeChatReply(
          'Let me read that document.',
          toolEvents: [
            {
              'kind': 'document_text',
              'status': 'device_lookup',
              'data': {
                'query': {'text': words, 'type': type},
                'requestId': 'read${nextRead++}',
              },
            },
          ],
        );
  }

  Finder sentClaim() => find.textContaining(RegExp(r'\b(sent|delivered)\b', caseSensitive: false));

  // -------------------------------------------------------------------------------------------
  group('Documents screen', () {
    testWidgets('the list shows existing documents straight away; it never opens the picker by itself',
        (tester) async {
      await startApp(tester);
      final names = ['${_cap(_word())} Notes.pdf', '${_cap(_word())} Project.docx'];
      await addDocuments([pdf(names[0]), docx(names[1])]);
      final pickerBefore = device.pickerShown;

      await openDocumentsList(tester, services);
      expect(device.pickerShown, pickerBefore, reason: 'opening the list must not open the picker');
      for (final name in names) {
        expect(find.text(name), findsOneWidget);
      }
      expect(find.textContaining('240 KB'), findsOneWidget);
      expect(find.textContaining('1.2 MB'), findsOneWidget);
      expect(find.text('Open'), findsNWidgets(2));
      expect(find.text('Share'), findsNWidgets(2));
      expect(find.text('WhatsApp'), findsNWidgets(2));

      // Adding more is only on request, from the Add menu.
      await tester.tap(find.byTooltip('Add documents'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pick files'));
      await tester.pumpAndSettle();
      expect(device.pickerShown, pickerBefore + 1);
    });

    testWidgets('WhatsApp asks first, then opens WhatsApp with that document; never says sent', (tester) async {
      await startApp(tester);
      final file = pdf('${_word()}.pdf');
      await addDocuments([file]);
      await openDocumentsList(tester, services);

      await tapIt(tester, find.text('WhatsApp'));
      expect(find.text('Send on WhatsApp?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(handoff.calls, isEmpty);

      await tapIt(tester, find.text('WhatsApp'));
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
      await tester.pumpAndSettle();
      expect(handoff.calls, ['whatsapp-document null: ${file.reference}']);
      expect(find.text('WhatsApp opened. Choose the chat, then tap Send to send the document.'), findsOneWidget);
      expect(sentClaim(), findsNothing);
    });

    testWidgets('Share opens the share sheet with that document', (tester) async {
      await startApp(tester);
      final file = docx('${_word()}.docx');
      await addDocuments([file]);
      await openDocumentsList(tester, services);
      await tapIt(tester, find.text('Share'));
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
      await tester.pumpAndSettle();
      expect(handoff.calls, ['share-document: ${file.reference}']);
    });

    testWidgets('a missing document is flagged after Refresh and cannot be shared', (tester) async {
      await startApp(tester);
      final file = pdf('${_word()}.pdf');
      await addDocuments([file]);
      await openDocumentsList(tester, services);
      expect(find.text('No longer available'), findsNothing);

      device.deleteFile(file);
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();
      expect(find.text('No longer available'), findsOneWidget);
      expect(find.text('WhatsApp'), findsNothing);
      expect(find.text('Share'), findsNothing);
    });
  });

  // -------------------------------------------------------------------------------------------
  group('Chat: reading a document', () {
    setUp(() => nextRead = 1);

    testWidgets('"<X> notes me kya hai?": reads that one document and answers from its text', (tester) async {
      await startApp(tester);
      final kw = _word();
      final text = _content(kw);
      final name = '${_cap(kw)} Notes.pdf';
      final added = await addDocuments([pdf(name, content: text), pdf('${_word()} notes.pdf', content: _content(_word()))]);
      await openTab(tester, 'Chat');
      respondWithRead('$kw notes');
      await send(tester, '$kw notes me kya hai?');

      // Only the matching document was read, and only its text was sent.
      expect(device.extracted, hasLength(1));
      expect(device.extracted.single, startsWith(added.first.reference));
      expect(backend.documentReadCalls, ['answer read1']);
      final body = backend.documentReadBodies.single;
      expect(body.keys, unorderedEquals(['documentId', 'name', 'type', 'text', 'truncated', 'conversationId']));
      expect(body['documentId'], added.first.id);
      expect(body['text'], text);
      expect(body['truncated'], false);
      expect(body.values.whereType<String>().any((v) => v.startsWith('content://')), isFalse, reason: 'no URI');

      // The answer, from the document's real first line, is in the chat; the card names the document.
      expect(find.text('This document starts with: ${text.split('\n').first}'), findsOneWidget);
      expect(find.text(name), findsOneWidget);
      expect(find.text('Answered from this document.'), findsOneWidget);
      expect(handoff.calls, isEmpty, reason: 'reading never shares');
      expect(backend.chatActions, isEmpty);
    });

    testWidgets('several matches: the user chooses; nothing is read before that', (tester) async {
      await startApp(tester);
      final kw = _word();
      final texts = [_content(kw), _content(kw)];
      await addDocuments([pdf('${kw}_one.pdf', content: texts[0]), docx('$kw two.docx', content: texts[1])]);
      await openTab(tester, 'Chat');
      respondWithRead(kw);
      await send(tester, 'What is in the $kw document?');

      expect(find.text('I found 2 documents matching "$kw". Which one do you want?'), findsOneWidget);
      expect(device.extracted, isEmpty);
      expect(backend.documentReadCalls, isEmpty);

      await tapIt(tester, find.text('$kw two.docx'));
      expect(device.extracted.single, contains('DOCX'));
      expect(backend.documentReadBodies.single['text'], texts[1]);
    });

    testWidgets('"summarize it" and topic questions follow up on the same document', (tester) async {
      await startApp(tester);
      final kw = _word();
      final text = _content(kw);
      final added = await addDocuments([docx('$kw.docx', content: text), pdf('${_word()}.pdf', content: _content(_word()))]);
      await openTab(tester, 'Chat');
      respondWithRead(kw);
      await send(tester, 'Summarize $kw notes');
      expect(backend.documentReadBodies.last['documentId'], added.first.id);

      for (final question in ['Summarize it', 'What does it say about loops?']) {
        respondWithRead(null);
        await send(tester, question);
        expect(backend.documentReadBodies.last['documentId'], added.first.id, reason: question);
        expect(backend.documentReadBodies.last['text'], text);
      }
      expect(backend.documentReadCalls, ['answer read1', 'answer read2', 'answer read3']);
    });

    testWidgets('Summarize on a found document asks without sending its name', (tester) async {
      await startApp(tester);
      final kw = _word();
      final added = await addDocuments([pdf('${_cap(kw)} Report.pdf', content: _content(kw))]);
      await openTab(tester, 'Chat');
      backend.chatResponder = (_) => FakeChatReply('Let me look for that document on your phone.', toolEvents: [
            {
              'kind': 'documents',
              'status': 'device_lookup',
              'data': {
                'query': {'text': kw, 'type': null, 'limit': 10},
              },
            },
          ]);
      await send(tester, 'Send me the $kw report');

      respondWithRead(null);
      await tapIt(tester, find.text('Summarize'));
      expect(backend.chatRequests.last['message'], 'Summarize this document');
      expect(backend.chatRequests.last['message'], isNot(contains(kw)));
      expect(backend.documentReadBodies.single['documentId'], added.single.id);
    });

    testWidgets('a document that is no longer available is not read', (tester) async {
      await startApp(tester);
      final kw = _word();
      final file = pdf('$kw.pdf', content: _content(kw));
      await addDocuments([file]);
      device.deleteFile(file);
      await openTab(tester, 'Chat');
      respondWithRead(kw);
      await send(tester, 'What is in $kw?');
      expect(find.text('This document is no longer available.'), findsOneWidget);
      expect(device.extracted, isEmpty);
      expect(backend.documentReadCalls, ['fail read1 unavailable']);
    });

    testWidgets('unsupported DOC, scanned PDF and password-protected PDF: said plainly, nothing invented',
        (tester) async {
      await startApp(tester);
      final kws = [_word(), _word(), _word()];
      await addDocuments([
        device.addFile('${kws[0]}.doc', mimeType: 'application/msword', size: 100, content: _content(kws[0])),
        pdf('${kws[1]}.pdf', content: '  \n \f '),
        pdf('${kws[2]}.pdf', content: _content(kws[2]), encrypted: true),
      ]);
      await openTab(tester, 'Chat');

      for (final (kw, reason, shown) in [
        (kws[0], 'unsupported', "I can't read the text of this type of document yet. You can still open it."),
        (kws[1], 'no_text', "I couldn't find any readable text in this document. It may be a scanned image, so I can't tell what it says."),
        (kws[2], 'encrypted', "This document is password-protected, so I couldn't read it."),
      ]) {
        respondWithRead(kw);
        await send(tester, 'What is in $kw?');
        expect(find.text(shown), findsOneWidget, reason: reason);
        expect(backend.documentReadCalls.last, endsWith(reason));
      }
      expect(backend.documentReadCalls.where((c) => c.startsWith('answer')), isEmpty, reason: 'no text was sent');
    });

    testWidgets('a large document is cut to the limit and marked as cut', (tester) async {
      await startApp(tester);
      final kw = _word();
      final big = '${_content(kw)}\n${List.filled(20000, 'more text here').join(' ')}';
      expect(big.length, greaterThan(DocumentService.maxContentChars));
      await addDocuments([pdf('$kw.pdf', content: big)]);
      await openTab(tester, 'Chat');
      respondWithRead(kw);
      await send(tester, 'Summarize $kw');
      final body = backend.documentReadBodies.single;
      expect((body['text'] as String).length, DocumentService.maxContentChars);
      expect(body['truncated'], true);
    });

    testWidgets("no match, and another account's documents, are never read", (tester) async {
      await startApp(tester);
      final kw = _word();
      await addDocuments([pdf('$kw.pdf', content: _content(kw))]);
      await openTab(tester, 'Chat');
      final missing = _word();
      respondWithRead(missing);
      await send(tester, 'What is in $missing?');
      expect(find.text("I couldn't find a matching $missing in the documents Child Assist can access."), findsOneWidget);
      expect(backend.documentReadCalls, ['fail read1 not_found']);

      await logOut(tester);
      await logIn(tester, 'ravi@example.com');
      await openTab(tester, 'Chat');
      respondWithRead(kw);
      await send(tester, 'What is in $kw?');
      expect(find.textContaining("I couldn't find a matching"), findsOneWidget);
      expect(device.extracted, isEmpty, reason: "another account's document is never opened");
    });

    testWidgets('choosing nothing and cancelling reads nothing', (tester) async {
      await startApp(tester);
      final kw = _word();
      await addDocuments([pdf('${kw}_a.pdf', content: _content(kw)), pdf('${kw}_b.pdf', content: _content(kw))]);
      await openTab(tester, 'Chat');
      respondWithRead(kw);
      await send(tester, 'What is in $kw?');
      await tapIt(tester, find.widgetWithText(OutlinedButton, 'Cancel'));
      expect(device.extracted, isEmpty);
      expect(backend.documentReadCalls, ['fail read1 cancelled']);
    });
  });
}
