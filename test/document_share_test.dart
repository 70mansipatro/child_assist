// Documents in chat: natural-language search over the user's own documents, the document card
// and its actions, and sharing a document with a contact on WhatsApp after explicit confirmation.
// Every document name, contact name and number here is generated at random: nothing in the app
// may depend on a particular one.
import 'dart:io';
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

/// A random lower-case word that is not filler ("python", "tcs" stand-ins).
String _word([int length = 7]) => String.fromCharCodes(List.generate(length, (_) => 97 + _random.nextInt(26)));
String _cap(String w) => '${w[0].toUpperCase()}${w.substring(1)}';

const _pdfMime = 'application/pdf';
const _docxMime = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';

DocumentItem _doc(String name, {DateTime? modified}) => DocumentItem(
      id: 'doc_${_word(8)}',
      name: name,
      type: DocumentType.detect(name)!,
      reference: 'content://test/${_word()}',
      addedAt: DateTime(2026, 10, 1),
      modifiedAt: modified,
    );

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  // -------------------------------------------------------------------------------------------
  group('DocumentSearch', () {
    test('matches file names by whole word, partial word, any case and any separator', () {
      final kw = _word();
      final docs = [
        _doc('${_cap(kw)}_Project.pdf'),
        _doc('notes-$kw-final.docx'),
        _doc('${_cap(kw)}Notes2026.txt'),
        _doc('${_cap(_word())}.pdf'),
      ];
      final names = DocumentSearch.search(docs, kw.toUpperCase()).documents.map((d) => d.name);
      expect(names, unorderedEquals([docs[0].name, docs[1].name, docs[2].name]));

      // Start of a word, and words joined in camelCase.
      expect(DocumentSearch.search(docs, kw.substring(0, 4)).documents, hasLength(3));
      expect(DocumentSearch.search(docs, '$kw notes').documents.map((d) => d.name),
          unorderedEquals([docs[1].name, docs[2].name]));
      expect(DocumentSearch.nameWords('${_cap(kw)}Notes2026.txt'), [kw, 'notes', '2026']);
    });

    test('a type in the request prefers that type ("<X> PDF")', () {
      final kw = _word();
      final pdf = _doc('${kw}_report.pdf');
      final docx = _doc('${kw}_report.docx');
      final result = DocumentSearch.search([pdf, docx, _doc('${_word()}.pdf')], 'send me the $kw pdf');
      expect(result.type, DocumentType.pdf);
      expect(result.words, [kw]);
      expect(result.documents, [pdf]);
      expect(result.outcome, DocumentSearchOutcome.single);
    });

    test('DOCX filtering, and a type alone lists that type', () {
      final docs = [_doc('${_word()}.pdf'), _doc('${_word()}.docx'), _doc('${_word()}.docx')];
      final docx = DocumentSearch.search(docs, 'docx');
      expect(docx.documents.map((d) => d.type), everyElement(DocumentType.docx));
      expect(docx.documents, hasLength(2));
      expect(docx.outcome, DocumentSearchOutcome.multiple);
      expect(DocumentSearch.search(docs, null, type: DocumentType.pdf).outcome, DocumentSearchOutcome.single);
    });

    test('one strong match is single; several are multiple; none is none', () {
      final a = _word(), b = _word();
      final docs = [_doc('$a notes.pdf'), _doc('$a project.pdf'), _doc('$b.txt')];
      expect(DocumentSearch.search(docs, '$b document').outcome, DocumentSearchOutcome.single);
      final several = DocumentSearch.search(docs, 'the $a document');
      expect(several.outcome, DocumentSearchOutcome.multiple);
      expect(several.documents, hasLength(2));
      expect(DocumentSearch.search(docs, _word()).outcome, DocumentSearchOutcome.none);
      // A partial match is never taken on its own: the user is asked.
      final weak = DocumentSearch.search(docs, '$a notes ${_word()}');
      expect(weak.matches.single.complete, isFalse);
      expect(weak.outcome, DocumentSearchOutcome.multiple);
      // Half the words or fewer is not a match at all.
      expect(DocumentSearch.search(docs, '$b ${_word()}').outcome, DocumentSearchOutcome.none);
    });

    test('request filler is ignored in chat but every typed word counts in the search box', () {
      final (words, type) = DocumentSearch.parse("Send me Mansi's TXT file please");
      expect(words, ['mansi']);
      expect(type, DocumentType.txt);
      final docs = [_doc('download.pdf'), _doc('${_word()}.pdf')];
      expect(DocumentSearch.search(docs, 'do', conversational: false).documents, [docs.first]);
    });
  });

  // -------------------------------------------------------------------------------------------
  late FakeBackend backend;
  late FakePermissionService os;
  late FakeDocumentPlatform device;
  late FakeContactsSource contacts;
  late FakeMessageHandoff handoff;
  late AppServices services;

  Future<void> startApp(WidgetTester tester, {List<ContactItem> book = const []}) async {
    backend = FakeBackend();
    os = FakePermissionService();
    os.os[AppPermission.contacts] = PermissionState.granted;
    device = FakeDocumentPlatform();
    contacts = FakeContactsSource(List.of(book));
    handoff = FakeMessageHandoff();
    services = backend.services(os, documentPlatform: device, contactsSource: contacts, messageHandoff: handoff);
    await services.authService.restoreSession();
    await tester.pumpWidget(MyApp(services: services));
    await tester.pumpAndSettle();
    await logIn(tester, 'mansi@example.com');
  }

  /// Puts files on the phone and adds them in Documents (as the picker would).
  Future<List<DocumentItem>> addDocuments(List<FakeDocumentFile> files) async {
    device.willPick(files);
    final result = await services.documentService.addDocuments();
    return result.added;
  }

  FakeDocumentFile pdfFile(String name) =>
      device.addFile(name, mimeType: _pdfMime, size: 245760, modifiedAt: DateTime(2026, 9, 14, 10, 30));
  FakeDocumentFile docxFile(String name) =>
      device.addFile(name, mimeType: _docxMime, size: 87040, modifiedAt: DateTime(2026, 9, 13, 9));

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

  /// What the server returns for "send me / find the <words> document".
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

  var nextAction = 1;

  /// What the server returns for "send the <words> document to <recipient> on WhatsApp".
  void respondWithShare(String? documentQuery, String recipient) {
    backend.chatResponder = (_) => FakeChatReply(
          'Please pick the document and contact, then confirm.',
          toolEvents: const [
            {'kind': 'send_action', 'status': 'confirmation_required'},
          ],
          pendingActions: [
            {
              'id': 'act${nextAction++}',
              'status': 'PENDING',
              'toolName': 'prepare_whatsapp',
              'type': 'SHARE_DOCUMENT',
              'channel': 'WHATSAPP',
              'summary': 'Do you want to share this document with $recipient on WhatsApp?',
              'contactQuery': recipient,
              'documentQuery': ?documentQuery,
            },
          ],
        );
  }

  Map<String, dynamic>? bodyFor(String verb) {
    for (var i = backend.chatActions.length - 1; i >= 0; i--) {
      if (backend.chatActions[i].startsWith('$verb ')) return backend.chatActionBodies[i];
    }
    return null;
  }

  Finder sentClaim() => find.textContaining(RegExp(r'\b(sent|delivered)\b', caseSensitive: false));

  // -------------------------------------------------------------------------------------------
  group('Documents screen', () {
    testWidgets('lists the real metadata and searches by partial file name', (tester) async {
      await startApp(tester);
      final kw = _word();
      await addDocuments([pdfFile('${_cap(kw)}_Project.pdf'), docxFile('${_word()}_plan.docx')]);
      await openDocumentsList(tester, services);

      final card = tester.widget<DocumentCard>(find.byType(DocumentCard).first);
      expect(find.byType(DocumentCard), findsNWidgets(2));
      expect(find.textContaining('240 KB'), findsOneWidget, reason: 'size from the platform');
      expect(card.document.reference, startsWith('content://'));

      await tester.enterText(find.byType(TextField), kw.substring(0, 3));
      await tester.pumpAndSettle();
      expect(find.byType(DocumentCard), findsOneWidget);
      expect(find.text('${_cap(kw)}_Project.pdf'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------------------------
  group('Chat: finding a document', () {
    testWidgets('one match: its details and the supported actions', (tester) async {
      await startApp(tester);
      final kw = _word();
      final name = '${_cap(kw)}_Project.pdf';
      await addDocuments([pdfFile(name), docxFile('${_word()}.docx')]);
      await openTab(tester, 'Chat');
      respondWithSearch(kw, type: 'PDF');
      await send(tester, 'Send me the $kw PDF');

      expect(find.text(name), findsOneWidget);
      expect(find.text('PDF'), findsWidgets);
      expect(find.textContaining('240 KB'), findsOneWidget);
      expect(find.textContaining('Modified Sep 14, 2026'), findsOneWidget);
      expect(find.text('Available on this phone'), findsOneWidget);
      for (final action in ['Open', 'Share', 'Send on WhatsApp']) {
        expect(find.text(action), findsOneWidget, reason: action);
      }
      expect(find.text('Send by Email'), findsNothing, reason: 'documents cannot be attached to email');
      expect(handoff.calls, isEmpty, reason: 'finding a document shares nothing');
    });

    testWidgets('several matches: asks which one, then shows the one chosen', (tester) async {
      await startApp(tester);
      final kw = _word();
      final first = '${kw}_notes.pdf', second = '${_cap(kw)} Project.docx';
      await addDocuments([pdfFile(first), docxFile(second), pdfFile('${_word()}.pdf')]);
      await openTab(tester, 'Chat');
      respondWithSearch(kw);
      await send(tester, 'Send me the $kw document');

      expect(find.text('I found 2 documents matching "$kw". Which one do you want?'), findsOneWidget);
      expect(find.text('Send on WhatsApp'), findsNothing, reason: 'nothing is picked for the user');
      await tapIt(tester, find.text(second));
      expect(find.text('Send on WhatsApp'), findsOneWidget);
      expect(find.text(first), findsNothing);
      expect(find.text('Choose another document'), findsOneWidget);
    });

    testWidgets('no match: says so plainly and invents nothing', (tester) async {
      await startApp(tester);
      await addDocuments([pdfFile('${_word()}.pdf')]);
      await openTab(tester, 'Chat');
      final missing = _word();
      respondWithSearch(missing);
      await send(tester, 'Send me the $missing document');
      expect(find.text("I couldn't find a matching $missing in the documents Child Assist can access."), findsOneWidget);
      expect(find.byType(DocumentTypeBadge), findsNothing);
    });

    testWidgets('a document that is no longer on the phone cannot be shared', (tester) async {
      await startApp(tester);
      final kw = _word();
      final file = pdfFile('$kw.pdf');
      await addDocuments([file]);
      device.deleteFile(file);
      await openTab(tester, 'Chat');
      respondWithSearch(kw);
      await send(tester, 'Send me the $kw document');

      expect(find.text('This document is no longer available.'), findsOneWidget);
      expect(find.text('Send on WhatsApp'), findsNothing);
      expect(find.text('Share'), findsNothing);
    });

    testWidgets('Send on WhatsApp asks first; Cancel shares nothing', (tester) async {
      await startApp(tester);
      final kw = _word();
      await addDocuments([pdfFile('$kw.pdf')]);
      await openTab(tester, 'Chat');
      respondWithSearch(kw);
      await send(tester, 'Send me the $kw document');

      await tapIt(tester, find.text('Send on WhatsApp'));
      expect(find.text('Send on WhatsApp?'), findsOneWidget);
      expect(handoff.calls, isEmpty, reason: 'nothing opens before Confirm');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(handoff.calls, isEmpty);
      expect(find.text("Okay, I didn't share the document."), findsOneWidget);
    });

    testWidgets('confirming opens WhatsApp with that document; it never says sent', (tester) async {
      await startApp(tester);
      final kw = _word();
      final file = pdfFile('$kw.pdf');
      await addDocuments([file]);
      await openTab(tester, 'Chat');
      respondWithSearch(kw);
      await send(tester, 'Send me the $kw document');

      await tapIt(tester, find.text('Send on WhatsApp'));
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
      await tester.pumpAndSettle();
      expect(handoff.calls, ['whatsapp-document null: ${file.reference}']);
      expect(find.text('WhatsApp opened. Choose the chat, then tap Send to send the document.'), findsOneWidget);
      expect(sentClaim(), findsNothing);
    });

    testWidgets("another account's documents are never found", (tester) async {
      await startApp(tester);
      final kw = _word();
      await addDocuments([pdfFile('$kw.pdf')]);
      await logOut(tester);
      await logIn(tester, 'ravi@example.com');
      await openTab(tester, 'Chat');
      respondWithSearch(kw);
      await send(tester, 'Send me the $kw document');
      expect(find.textContaining("I couldn't find a matching"), findsOneWidget);
      expect(find.text('$kw.pdf'), findsNothing);
    });
  });

  // -------------------------------------------------------------------------------------------
  group('Chat: sharing a document with a contact on WhatsApp', () {
    late String recipient;
    late String phone;
    ContactItem person() => ContactItem(id: 'c-$recipient', displayName: recipient, phoneNumbers: [phone]);

    setUp(() {
      nextAction = 1;
      recipient = _cap(_word());
      phone = '+91${_digits(10)}';
    });

    testWidgets('preview shows document, recipient and method; Confirm hands off exactly that document',
        (tester) async {
      await startApp(tester, book: [person()]);
      final kw = _word();
      final name = '${_cap(kw)}_Project.pdf';
      final file = pdfFile(name);
      final added = await addDocuments([file, docxFile('${_word()}.docx')]);
      await openTab(tester, 'Chat');
      respondWithShare('$kw pdf', recipient);
      await send(tester, 'Send the $kw PDF to $recipient on WhatsApp');

      // The one strong match and the one contact were taken; only id, name and type went up.
      expect(bodyFor('document'), {
        'documentId': added.first.id,
        'name': name,
        'type': 'PDF',
        'conversationId': 'conv1',
      });
      expect(bodyFor('recipient'), containsPair('address', phone));

      expect(find.text('Do you want to share this document with $recipient ($phone) on WhatsApp?'), findsOneWidget);
      expect(find.text('$name (PDF)'), findsOneWidget);
      expect(find.text('$recipient\n$phone'), findsOneWidget);
      expect(find.text('Method'), findsOneWidget);
      expect(find.text('WhatsApp'), findsOneWidget);
      expect(handoff.calls, isEmpty, reason: 'nothing opens before Confirm');
      expect(backend.chatActions.where((a) => a.startsWith('confirm')), isEmpty);

      await tapIt(tester, find.widgetWithText(FilledButton, 'Confirm'));
      expect(handoff.calls, ['whatsapp-document $phone: ${file.reference}']);
      expect(backend.chatActions.last, 'handoff act1 whatsapp_opened');
      expect(find.text('WhatsApp opened. Please tap Send to send the document.'), findsOneWidget);
      expect(sentClaim(), findsNothing);
    });

    testWidgets('Cancel prevents sharing', (tester) async {
      await startApp(tester, book: [person()]);
      final kw = _word();
      await addDocuments([pdfFile('$kw.pdf')]);
      await openTab(tester, 'Chat');
      respondWithShare(kw, recipient);
      await send(tester, 'Send the $kw document to $recipient on WhatsApp');

      await tapIt(tester, find.widgetWithText(OutlinedButton, 'Cancel'));
      expect(backend.chatActions.last, 'cancel act1');
      expect(handoff.calls, isEmpty);
      expect(find.text("Okay, I didn't share the document."), findsOneWidget);
    });

    testWidgets('several matching documents: the user chooses; nothing is guessed', (tester) async {
      await startApp(tester, book: [person()]);
      final kw = _word();
      final files = [pdfFile('${kw}_one.pdf'), pdfFile('${kw}_two.pdf')];
      await addDocuments(files);
      await openTab(tester, 'Chat');
      respondWithShare(kw, recipient);
      await send(tester, 'Send the $kw document to $recipient on WhatsApp');

      expect(find.text('I found 2 documents matching "$kw". Which one do you want?'), findsOneWidget);
      expect(bodyFor('document'), isNull);
      expect(find.widgetWithText(FilledButton, 'Confirm'), findsNothing);
      await tapIt(tester, find.text('${kw}_two.pdf'));
      expect(bodyFor('document'), containsPair('name', '${kw}_two.pdf'));
      expect(bodyFor('document')!.keys, unorderedEquals(['documentId', 'name', 'type', 'conversationId']),
          reason: 'never a path, URI or contents');

      await tapIt(tester, find.widgetWithText(FilledButton, 'Confirm'));
      expect(handoff.calls, ['whatsapp-document $phone: ${files[1].reference}']);
    });

    testWidgets('several matching contacts, then several numbers, must be chosen', (tester) async {
      final numbers = ['+91${_digits(10)}', '+91${_digits(10)}'];
      final family = _cap(_word());
      final first = ContactItem(
        id: 'f1',
        displayName: '$family One',
        phoneNumbers: numbers,
        phoneLabels: const ['Mobile', 'Work'],
      );
      final second = ContactItem(id: 'f2', displayName: '$family Two', phoneNumbers: ['+91${_digits(10)}']);
      await startApp(tester, book: [first, second]);
      final kw = _word();
      await addDocuments([pdfFile('$kw.pdf')]);
      await openTab(tester, 'Chat');
      respondWithShare(kw, family);
      await send(tester, 'Send the $kw document to $family on WhatsApp');

      expect(find.text('I found 2 contacts named $family.'), findsOneWidget);
      expect(bodyFor('recipient'), isNull);
      await tapIt(tester, find.text(first.displayName));
      expect(find.text('Select phone number for ${first.displayName}'), findsOneWidget);
      expect(bodyFor('recipient'), isNull, reason: 'no number is picked for the user');
      await tapIt(tester, find.text(numbers[1]));
      expect(bodyFor('recipient'), containsPair('address', numbers[1]));
      expect(find.text('${first.displayName}\n${numbers[1]}'), findsOneWidget);
    });

    testWidgets('a document deleted before Confirm is not shared', (tester) async {
      await startApp(tester, book: [person()]);
      final kw = _word();
      final file = pdfFile('$kw.pdf');
      await addDocuments([file]);
      await openTab(tester, 'Chat');
      respondWithShare(kw, recipient);
      await send(tester, 'Send the $kw document to $recipient on WhatsApp');
      expect(find.widgetWithText(FilledButton, 'Confirm'), findsOneWidget);

      device.deleteFile(file);
      await tapIt(tester, find.widgetWithText(FilledButton, 'Confirm'));
      expect(handoff.calls, isEmpty);
      expect(backend.chatActions.where((a) => a.startsWith('confirm')), isEmpty);
      expect(backend.chatActions.last, 'cancel act1');
      expect(find.text('This document is no longer available. Nothing was shared.'), findsOneWidget);
    });

    testWidgets('no matching document: nothing can be confirmed', (tester) async {
      await startApp(tester, book: [person()]);
      await addDocuments([pdfFile('${_word()}.pdf')]);
      await openTab(tester, 'Chat');
      final missing = _word();
      respondWithShare(missing, recipient);
      await send(tester, 'Send the $missing document to $recipient on WhatsApp');
      expect(find.text("I couldn't find a matching $missing in the documents Child Assist can access."), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Confirm'), findsNothing);
      expect(backend.chatActions, isEmpty);
    });

    testWidgets('"send the document to <name>": every document is offered to choose from', (tester) async {
      await startApp(tester, book: [person()]);
      final names = ['${_word()}.pdf', '${_word()}.docx'];
      await addDocuments([pdfFile(names[0]), docxFile(names[1])]);
      await openTab(tester, 'Chat');
      respondWithShare(null, recipient);
      await send(tester, 'Send the document to $recipient on WhatsApp');
      expect(find.text('Which document do you want?'), findsOneWidget);
      for (final n in names) {
        expect(find.text(n), findsOneWidget);
      }
    });

    testWidgets("an action naming another account's document finds nothing to share", (tester) async {
      await startApp(tester, book: [person()]);
      final kw = _word();
      await addDocuments([pdfFile('$kw.pdf')]);
      await logOut(tester);
      await logIn(tester, 'ravi@example.com');
      await openTab(tester, 'Chat');
      respondWithShare(kw, recipient);
      await send(tester, 'Send the $kw document to $recipient on WhatsApp');
      expect(find.textContaining("I couldn't find a matching"), findsOneWidget);
      expect(backend.chatActions, isEmpty);
      expect(handoff.calls, isEmpty);
    });
  });

  // -------------------------------------------------------------------------------------------
  group('Chat: email', () {
    testWidgets('a document is never emailed: no action, nothing opened, never claimed', (tester) async {
      await startApp(tester);
      final kw = _word();
      await addDocuments([pdfFile('$kw.pdf')]);
      await openTab(tester, 'Chat');
      // What the server answers: prepare_email refuses documents, so nothing is prepared.
      backend.chatResponder = (_) => const FakeChatReply(
            "I can't attach documents to an email from Child Assist. I can share it on WhatsApp instead.",
          );
      await send(tester, "Send the $kw document to ${_cap(_word())}'s email");
      expect(find.widgetWithText(FilledButton, 'Confirm & Send'), findsNothing);
      expect(backend.chatActions, isEmpty);
      expect(handoff.calls, isEmpty);
      expect(backend.sentEmails, isEmpty);
    });
  });

  // -------------------------------------------------------------------------------------------
  group('No hard-coded data', () {
    test('document, chat and contact code contains no fixed file names, numbers or emails', () {
      final files = [
        for (final dir in ['lib/features/documents', 'lib/features/chat', 'lib/features/contacts'])
          ...Directory(dir).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')),
      ];
      expect(files, isNotEmpty);
      final email = RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}');
      final phone = RegExp(r'\+?\d[\d ()-]{7,}\d');
      final fileName = RegExp(r'''['"][^'"\s]+\.(pdf|docx?|txt)['"]''', caseSensitive: false);
      for (final file in files) {
        for (final (i, line) in file.readAsLinesSync().indexed) {
          final code = line.trimLeft();
          if (code.startsWith('//')) continue;
          for (final pattern in [email, phone, fileName]) {
            expect(pattern.hasMatch(code), isFalse, reason: '${file.path}:${i + 1}: $line');
          }
        }
      }
    });
  });
}
