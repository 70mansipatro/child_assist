import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/app_services.dart';
import 'package:child_assist/core/permissions/permission_service.dart';
import 'package:child_assist/core/widgets/widgets.dart';
import 'package:child_assist/features/documents/screens/document_viewer_screen.dart';
import 'package:child_assist/features/documents/screens/documents_screen.dart';
import 'package:child_assist/features/documents/services/document_service.dart';
import 'package:child_assist/features/documents/widgets/document_card.dart';
import 'package:child_assist/features/location/screens/location_screen.dart';
import 'package:child_assist/features/permissions/models/permission_onboarding.dart';
import 'package:child_assist/features/photos/screens/photos_screen.dart';
import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  late FakeBackend backend;
  late FakePermissionService os;
  late FakeDocumentPlatform device;
  late AppServices services;

  final sep14 = DateTime(2026, 9, 14, 10, 30);

  /// Starts the app and logs in as [email]. Reuse [reuseBackend]/[reuseDevice] to simulate the
  /// app being closed and reopened (secure storage keeps its values between pumps).
  Future<void> startApp(
    WidgetTester tester, {
    String email = 'mansi@example.com',
    FakeBackend? reuseBackend,
    FakeDocumentPlatform? reuseDevice,
  }) async {
    backend = reuseBackend ?? FakeBackend();
    os = FakePermissionService();
    device = reuseDevice ?? FakeDocumentPlatform();
    services = backend.services(os, documentPlatform: device);
    await services.authService.restoreSession();
    await tester.pumpWidget(MyApp(services: services));
    await tester.pumpAndSettle();
    if (find.text('Log in').evaluate().isNotEmpty) await logIn(tester, email);
  }

  Future<void> openDocuments(WidgetTester tester) => tapVisible(tester, find.text('Documents'));

  FakeDocumentFile pdf([String name = 'school_notes.pdf']) =>
      device.addFile(name, mimeType: 'application/pdf', size: 245760, modifiedAt: sep14);
  FakeDocumentFile docx([String name = 'assignment.docx']) => device.addFile(
        name,
        mimeType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        size: 87040,
        modifiedAt: sep14.subtract(const Duration(days: 1)),
      );
  FakeDocumentFile txt([String name = 'reading.txt', String content = 'Chapter 1\nThe quick brown fox.']) =>
      device.addFile(name, mimeType: 'text/plain', size: 1200, modifiedAt: sep14, content: content);

  /// Taps "Add Documents" with the user picking [files] (none = Cancel).
  Future<void> addDocuments(WidgetTester tester, [List<FakeDocumentFile> files = const []]) async {
    if (files.isNotEmpty) device.willPick(files);
    await tester.tap(find.text('Add Documents'));
    await tester.pumpAndSettle();
  }

  Future<void> openDocument(WidgetTester tester, String name) async {
    await tester.tap(find.text(name));
    await tester.pumpAndSettle();
  }

  Future<void> resumeApp(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  }

  Finder card(String name) => find.ancestor(of: find.text(name), matching: find.byType(DocumentCard));

  group('Documents screen', () {
    testWidgets('1. opens from Home without any permission dialog', (tester) async {
      await startApp(tester);
      expect(find.text('Documents'), findsOneWidget);
      expect(find.text('Find your notes and files'), findsOneWidget);

      await openDocuments(tester);
      expect(find.byType(DocumentsScreen), findsOneWidget);
      expect(os.calls, isEmpty, reason: 'documents use the system picker, not a runtime permission');
      expect(os.dialogsShown, isEmpty);
    });

    testWidgets('2. empty state', (tester) async {
      await startApp(tester);
      await openDocuments(tester);
      expect(find.text('No documents yet'), findsOneWidget);
      expect(find.text('Add a document from your device to see it here.'), findsOneWidget);
      expect(find.widgetWithText(GradientButton, 'Add Documents'), findsOneWidget);
      expect(device.pickerShown, 0, reason: 'the picker opens only when asked');
    });

    testWidgets('3, 23. Add Documents opens the system picker for supported types, with a loading state',
        (tester) async {
      await startApp(tester);
      await openDocuments(tester);
      final file = pdf();
      device.willPick([file]);
      final picking = device.pendingPick = Completer<void>();

      await tester.tap(find.text('Add Documents'));
      await tester.pump();
      expect(device.pickerShown, 1);
      expect(device.pickedExtensions.single, ['pdf', 'doc', 'docx', 'txt']);
      expect(find.text('Adding documents...'), findsOneWidget);
      final button = tester.widget<GradientButton>(find.byType(GradientButton));
      expect(button.onPressed, isNull, reason: 'cannot open a second picker meanwhile');

      picking.complete();
      await tester.pumpAndSettle();
      expect(find.text('Adding documents...'), findsNothing);
      expect(find.text('school_notes.pdf'), findsOneWidget);
    });

    testWidgets('4, 6. picking one document adds it', (tester) async {
      await startApp(tester);
      await openDocuments(tester);
      await addDocuments(tester, [pdf()]);

      expect(find.text('Added 1 document'), findsOneWidget);
      expect(find.byType(DocumentCard), findsOneWidget);
      expect(find.text('Recent Documents'), findsOneWidget);
      expect(find.text('1 document'), findsOneWidget);
    });

    testWidgets('5. cancelling the picker changes nothing and shows no error', (tester) async {
      await startApp(tester);
      await openDocuments(tester);
      await addDocuments(tester); // cancelled

      expect(device.pickerShown, 1);
      expect(find.text('No documents yet'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(DocumentCard), findsNothing);
      expect(await services.documentService.list(), isEmpty);
    });

    testWidgets('7. picking several documents adds them all, newest added first', (tester) async {
      await startApp(tester);
      await openDocuments(tester);
      await addDocuments(tester, [pdf(), docx(), txt()]);

      expect(find.text('Added 3 documents'), findsOneWidget);
      expect(find.byType(DocumentCard), findsNWidgets(3));
      for (final name in ['school_notes.pdf', 'assignment.docx', 'reading.txt']) {
        expect(find.text(name), findsOneWidget);
      }

      await addDocuments(tester, [device.addFile('later.pdf', size: 10)]);
      final names = tester.widgetList<DocumentCard>(find.byType(DocumentCard)).map((c) => c.document.name);
      expect(names.first, 'later.pdf');
    });

    testWidgets('8. PDF metadata: type, name, size and date', (tester) async {
      await startApp(tester);
      await openDocuments(tester);
      await addDocuments(tester, [pdf()]);

      expect(find.descendant(of: card('school_notes.pdf'), matching: find.text('PDF')), findsOneWidget);
      expect(find.text('240 KB · Modified Sep 14, 2026'), findsOneWidget);
      // The badge's label is read together with the card's text, as one item.
      expect(find.bySemanticsLabel(RegExp(r'^PDF document\nschool_notes\.pdf')), findsOneWidget);

      await openDocument(tester, 'school_notes.pdf');
      expect(find.text('PDF document'), findsOneWidget);
      expect(find.text('240 KB'), findsOneWidget);
      expect(find.text('Modified'), findsOneWidget);
      expect(find.text('Sep 14, 2026'), findsOneWidget);
      expect(find.text('Added'), findsOneWidget);
    });

    testWidgets('9. DOCX metadata', (tester) async {
      await startApp(tester);
      await openDocuments(tester);
      await addDocuments(tester, [docx()]);

      expect(find.descendant(of: card('assignment.docx'), matching: find.text('DOCX')), findsOneWidget);
      expect(find.text('85 KB · Modified Sep 13, 2026'), findsOneWidget);
      final stored = (await services.documentService.list()).single;
      expect(stored.type, DocumentType.docx);
      expect(stored.mimeType, 'application/vnd.openxmlformats-officedocument.wordprocessingml.document');
      expect(stored.size, 87040);
    });

    testWidgets('10. TXT metadata', (tester) async {
      await startApp(tester);
      await openDocuments(tester);
      await addDocuments(tester, [txt()]);

      expect(find.descendant(of: card('reading.txt'), matching: find.text('TXT')), findsOneWidget);
      expect(find.text('1 KB · Modified Sep 14, 2026'), findsOneWidget);
    });

    testWidgets('15. details the platform did not report are left out, not invented', (tester) async {
      await startApp(tester);
      await openDocuments(tester);
      await addDocuments(tester, [device.addFile('scan.pdf')]);

      final added = (await services.documentService.list()).single;
      final today = MaterialLocalizations.of(tester.element(find.byType(DocumentsScreen)));
      final label = '${today.formatShortMonthDay(added.addedAt)}, ${today.formatYear(added.addedAt)}';
      expect(find.text('Added $label'), findsOneWidget, reason: 'no size, no modified date');

      await openDocument(tester, 'scan.pdf');
      expect(find.text('Size'), findsNothing);
      expect(find.text('Modified'), findsNothing);
      expect(find.text('Added'), findsOneWidget);
    });

    testWidgets('a document picked again is not duplicated', (tester) async {
      await startApp(tester);
      await openDocuments(tester);
      final file = pdf();
      await addDocuments(tester, [file]);
      await addDocuments(tester, [file]);

      expect(find.text('1 document was already in your list'), findsOneWidget);
      expect(find.byType(DocumentCard), findsOneWidget);
    });

    testWidgets('an unsupported file is skipped and its access released', (tester) async {
      await startApp(tester);
      await openDocuments(tester);
      final sheet = device.addFile('marks.xlsx', mimeType: 'application/vnd.ms-excel');
      await addDocuments(tester, [pdf(), sheet]);

      expect(
        find.text('Added 1 document. 1 file was skipped: only PDF, DOC, DOCX and TXT are supported'),
        findsOneWidget,
      );
      expect(find.text('marks.xlsx'), findsNothing);
      expect(device.released, [sheet.reference]);
    });

    testWidgets('a picker failure shows a friendly message with Retry', (tester) async {
      await startApp(tester);
      await openDocuments(tester);
      device.pickError = Exception('/storage/emulated/0/secret.pdf: picker crashed');
      await addDocuments(tester);

      expect(find.text('Unable to add documents. Please try again.'), findsOneWidget);
      expect(find.textContaining('secret'), findsNothing, reason: 'no raw error details');
      device.willPick([pdf()]);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(device.pickerShown, 2);
      expect(find.text('school_notes.pdf'), findsOneWidget);
    });
  });

  group('Search and filters', () {
    Future<void> withThree(WidgetTester tester) async {
      await startApp(tester);
      await openDocuments(tester);
      await addDocuments(tester, [
        pdf('math_notes.pdf'),
        docx('math_assignment.docx'),
        txt('history.txt'),
      ]);
    }

    testWidgets('11. search by file name and by type', (tester) async {
      await withThree(tester);

      await tester.enterText(find.byType(TextField), 'math');
      await tester.pumpAndSettle();
      expect(find.text('math_notes.pdf'), findsOneWidget);
      expect(find.text('math_assignment.docx'), findsOneWidget);
      expect(find.text('history.txt'), findsNothing);
      expect(find.text('2 of 3 match'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'TXT');
      await tester.pumpAndSettle();
      expect(find.byType(DocumentCard), findsOneWidget);
      expect(find.text('history.txt'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'geography');
      await tester.pumpAndSettle();
      expect(find.text('No matching documents'), findsOneWidget);
      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(find.byType(DocumentCard), findsNWidgets(3));
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    });

    testWidgets('12. date filter', (tester) async {
      await startApp(tester);
      await openDocuments(tester);
      final now = DateTime.now();
      await addDocuments(tester, [
        device.addFile('today.pdf', modifiedAt: now),
        device.addFile('this_week.pdf', modifiedAt: now.subtract(const Duration(days: 3))),
        device.addFile('this_month.pdf', modifiedAt: now.subtract(const Duration(days: 20))),
        device.addFile('old.pdf', modifiedAt: now.subtract(const Duration(days: 100))),
      ]);

      Future<void> pick(String label) async {
        await tester.tap(find.byTooltip('Filter by date'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      Iterable<String> shown() =>
          tester.widgetList<DocumentCard>(find.byType(DocumentCard)).map((c) => c.document.name);

      await pick('Today');
      expect(shown(), ['today.pdf']);
      await pick('Last 7 days');
      expect(shown(), unorderedEquals(['today.pdf', 'this_week.pdf']));
      await pick('Last 30 days');
      expect(shown(), unorderedEquals(['today.pdf', 'this_week.pdf', 'this_month.pdf']));
      await pick('All dates');
      expect(shown(), hasLength(4));
    });

    testWidgets('13. type filter', (tester) async {
      await withThree(tester);

      await tester.tap(find.widgetWithText(ChoiceChip, 'DOCX'));
      await tester.pumpAndSettle();
      expect(find.byType(DocumentCard), findsOneWidget);
      expect(find.text('math_assignment.docx'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'DOC'));
      await tester.pumpAndSettle();
      expect(find.text('No matching documents'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
      await tester.pumpAndSettle();
      expect(find.byType(DocumentCard), findsNWidgets(3));
    });
  });

  group('Viewer', () {
    testWidgets('14. a PDF opens in the device viewer with its own type', (tester) async {
      await startApp(tester);
      await openDocuments(tester);
      final file = pdf();
      await addDocuments(tester, [file]);
      await openDocument(tester, 'school_notes.pdf');

      expect(find.byType(DocumentViewerScreen), findsOneWidget);
      expect(device.reads, isEmpty, reason: 'PDF contents are never read by the app');
      await tester.tap(find.text('Open document'));
      await tester.pumpAndSettle();
      expect(device.opened, ['${file.reference} application/pdf']);
    });

    testWidgets('14. a TXT document is shown in the app', (tester) async {
      await startApp(tester);
      await openDocuments(tester);
      await addDocuments(tester, [txt()]);
      expect(device.reads, isEmpty, reason: 'the list shows metadata only');

      await openDocument(tester, 'reading.txt');
      expect(find.text('Preview'), findsOneWidget);
      expect(find.textContaining('The quick brown fox.'), findsOneWidget);
      expect(device.reads.single, endsWith(' ${DocumentService.maxTextPreviewBytes + 1}'));
    });

    testWidgets('15. no viewer installed: friendly message, Open with another app, Close', (tester) async {
      await startApp(tester);
      await openDocuments(tester);
      final file = docx();
      await addDocuments(tester, [file]);
      await openDocument(tester, 'assignment.docx');
      device.hasViewer = false;

      await tester.tap(find.text('Open document'));
      await tester.pumpAndSettle();
      expect(find.text('This document cannot be previewed on this device.'), findsOneWidget);
      expect(find.text('No app that opens DOCX files was found.'), findsOneWidget);

      await tester.ensureVisible(find.text('Open with another app'));
      await tester.tap(find.text('Open with another app'));
      await tester.pumpAndSettle();
      expect(device.opened, ['${file.reference} any app']);

      // Not even "any app" could take it: only Close is offered.
      device.hasAnyApp = false;
      device.opened.clear();
      await tester.tap(find.text('Open document'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Open with another app'));
      await tester.tap(find.text('Open with another app'));
      await tester.pumpAndSettle();
      expect(find.text('No app on this device can open it.'), findsOneWidget);
      expect(find.text('Open with another app'), findsNothing);
      await tester.ensureVisible(find.text('Close'));
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(DocumentsScreen), findsOneWidget);
    });

    testWidgets('16, 18. a deleted document: flagged in the list, explained, and removable', (tester) async {
      await startApp(tester);
      await openDocuments(tester);
      final file = pdf();
      await addDocuments(tester, [file, docx()]);

      device.deleteFile(file);
      await resumeApp(tester); // e.g. back from the Files app
      expect(find.descendant(of: card('school_notes.pdf'), matching: find.text('No longer available')),
          findsOneWidget);
      expect(find.descendant(of: card('assignment.docx'), matching: find.text('No longer available')),
          findsNothing);

      await openDocument(tester, 'school_notes.pdf');
      expect(find.text('This document is no longer available.'), findsOneWidget);
      expect(device.files, isNot(contains(file.reference)), reason: 'nothing is recreated');

      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(find.byType(DocumentsScreen), findsOneWidget);
      expect(find.text('school_notes.pdf'), findsNothing);
      expect(find.byType(DocumentCard), findsOneWidget);
      expect(device.released, [file.reference]);
      expect((await services.documentService.list()).map((d) => d.name), ['assignment.docx']);
    });

    testWidgets('16. a document deleted while its viewer is open is caught when opening', (tester) async {
      await startApp(tester);
      await openDocuments(tester);
      final file = pdf();
      await addDocuments(tester, [file]);
      await openDocument(tester, 'school_notes.pdf');

      device.deleteFile(file);
      await tester.tap(find.text('Open document'));
      await tester.pumpAndSettle();
      expect(find.text('This document is no longer available.'), findsOneWidget);
      expect(device.opened, isEmpty);
    });

    testWidgets('17. open failure: "Unable to open this document." then Retry works', (tester) async {
      await startApp(tester);
      await openDocuments(tester);
      final file = pdf();
      await addDocuments(tester, [file]);
      await openDocument(tester, 'school_notes.pdf');

      device.openFailures = 1;
      await tester.tap(find.text('Open document'));
      await tester.pumpAndSettle();
      expect(find.text('Unable to open this document.'), findsOneWidget);
      expect(find.text('Please try again.'), findsOneWidget);
      expect(find.textContaining('Exception'), findsNothing);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(device.opened, ['${file.reference} application/pdf']);
      expect(find.text('Open document'), findsOneWidget);
    });

    testWidgets('17. failure checking the document, and reading text, both retry', (tester) async {
      await startApp(tester);
      await openDocuments(tester);
      await addDocuments(tester, [txt()]);

      device.infoFailures = 1;
      await openDocument(tester, 'reading.txt');
      expect(find.text('Unable to open this document.'), findsOneWidget);
      device.readFailures = 1;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Unable to open this document.'), findsOneWidget, reason: 'text read failed');
      expect(find.textContaining('quick brown fox'), findsNothing);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.textContaining('quick brown fox'), findsOneWidget);
    });

    testWidgets('19. back navigation: viewer -> list -> Home', (tester) async {
      await startApp(tester);
      await openDocuments(tester);
      await addDocuments(tester, [pdf()]);
      await openDocument(tester, 'school_notes.pdf');

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(DocumentViewerScreen), findsNothing);
      expect(find.byType(DocumentCard), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(DocumentsScreen), findsNothing);
      expect(dashboard(), findsOneWidget);
    });
  });

  group('Removing, storage and privacy', () {
    testWidgets('remove from the list asks first and never deletes the file', (tester) async {
      await startApp(tester);
      await openDocuments(tester);
      final file = pdf();
      await addDocuments(tester, [file]);

      await tester.tap(find.byTooltip('More options for school_notes.pdf'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from Child Assist'));
      await tester.pumpAndSettle();
      expect(find.text('Remove from Child Assist?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(DocumentCard), findsOneWidget);

      await tester.tap(find.byTooltip('More options for school_notes.pdf'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from Child Assist'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(find.text('Removed from Child Assist'), findsOneWidget);
      expect(find.text('No documents yet'), findsOneWidget);
      expect(device.files, contains(file.reference), reason: 'the file stays on the device');
      expect(device.released, [file.reference]);
    });

    testWidgets('documents persist across restarts and are kept per user', (tester) async {
      await startApp(tester);
      await openDocuments(tester);
      final file = txt('diary.txt', 'private words');
      await addDocuments(tester, [file]);

      // Stored encrypted on the device as metadata + reference only: no contents.
      final stored = await const FlutterSecureStorage().readAll();
      expect(stored.keys, contains('documents_u1'));
      expect(stored['documents_u1'], isNot(contains('private words')));
      expect(backend.patches, isEmpty, reason: 'nothing about documents is sent to the server');

      // Restart: the session is restored and the document is still listed.
      await tester.pumpWidget(const SizedBox());
      await startApp(tester, reuseBackend: backend, reuseDevice: device);
      await openDocuments(tester);
      expect(find.text('diary.txt'), findsOneWidget);

      // Another account on the same phone does not see it.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await logOut(tester);
      await logIn(tester, 'ravi@example.com');
      await openDocuments(tester);
      expect(find.text('No documents yet'), findsOneWidget);

      // Ravi adds the same file, then removes it: Mansi still uses it, so access is kept.
      await addDocuments(tester, [file]);
      await tester.tap(find.byTooltip('More options for diary.txt'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from Child Assist'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(device.released, isEmpty);
    });

    test('metadata JSON for later features carries no reference, path or contents', () {
      final document = DocumentItem(
        id: 'doc_1',
        name: 'school_notes.pdf',
        type: DocumentType.pdf,
        reference: 'content://com.android.providers.downloads.documents/document/msf%3A42',
        addedAt: DateTime.utc(2026, 10, 6, 10, 30),
        mimeType: 'application/pdf',
        size: 245760,
      );
      expect(document.toJson(), {
        'id': 'doc_1',
        'name': 'school_notes.pdf',
        'extension': '.pdf',
        'type': 'PDF',
        'mimeType': 'application/pdf',
        'size': 245760,
        'addedAt': '2026-10-06T10:30:00.000Z',
      });
      expect(jsonEncode(document.toJson()), isNot(contains('content://')));
      final restored = DocumentItem.fromStorage(jsonDecode(jsonEncode(document.toStorage())) as Map<String, dynamic>)!;
      expect(restored.reference, document.reference);
      expect(restored.toJson(), document.toJson());
    });

    test('types are recognised by extension, then MIME type', () {
      expect(DocumentType.detect('A.PDF'), DocumentType.pdf);
      expect(DocumentType.detect('essay.docx'), DocumentType.docx);
      expect(DocumentType.detect('old.doc'), DocumentType.doc);
      expect(DocumentType.detect('notes', mimeType: 'text/plain'), DocumentType.txt);
      expect(DocumentType.detect('sheet.xlsx'), isNull);
      expect(DocumentType.detect('README'), isNull);
    });

    test('date filters', () {
      final now = DateTime(2026, 10, 6, 9);
      expect(DocumentDateFilter.today.matches(DateTime(2026, 10, 6, 0, 1), now), isTrue);
      expect(DocumentDateFilter.today.matches(DateTime(2026, 10, 5, 23, 59), now), isFalse);
      expect(DocumentDateFilter.last7Days.matches(DateTime(2026, 9, 30), now), isTrue);
      expect(DocumentDateFilter.last7Days.matches(DateTime(2026, 9, 29, 23), now), isFalse);
      expect(DocumentDateFilter.last30Days.matches(DateTime(2026, 9, 7), now), isTrue);
      expect(DocumentDateFilter.last30Days.matches(DateTime(2026, 9, 6), now), isFalse);
      expect(DocumentDateFilter.all.matches(DateTime(1990), now), isTrue);
    });

    testWidgets('long text is previewed only up to the limit', (tester) async {
      await startApp(tester);
      final big = txt('big.txt', 'a' * (DocumentService.maxTextPreviewBytes + 10));
      device.willPick([big]);
      await services.documentService.addDocuments();
      final document = (await services.documentService.list()).single;
      final preview = await services.documentService.readText(document);
      expect(preview.truncated, isTrue);
      expect(preview.text.length, DocumentService.maxTextPreviewBytes);
    });
  });

  group('Theme and other features', () {
    testWidgets('20. follows dark mode', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await startApp(tester);
      await openDocuments(tester);
      await addDocuments(tester, [pdf(), txt()]);

      final context = tester.element(find.byType(DocumentsScreen));
      expect(Theme.of(context).brightness, Brightness.dark);
      final scaffold = tester.widget<Scaffold>(
          find.descendant(of: find.byType(DocumentsScreen), matching: find.byType(Scaffold)));
      expect(scaffold.backgroundColor ?? Theme.of(context).scaffoldBackgroundColor, AppColors.darkBackground);

      await openDocument(tester, 'reading.txt');
      expect(Theme.of(tester.element(find.byType(DocumentViewerScreen))).brightness, Brightness.dark);
      expect(tester.takeException(), isNull);
    });

    test('21. Documents is not part of the permission walkthrough', () {
      expect(permissionOnboardingSteps.map((s) => s.permission), [
        AppPermission.location,
        AppPermission.camera,
        AppPermission.microphone,
        AppPermission.photos,
        AppPermission.notifications,
        AppPermission.contacts,
      ]);
    });

    testWidgets('22, 23. Photos and Location still open after using Documents', (tester) async {
      await startApp(tester);
      await openDocuments(tester);
      await addDocuments(tester, [pdf()]);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await openFromHome(tester, 'Photos');
      expect(find.byType(PhotosScreen), findsOneWidget);
      expect(find.text('Photo access is needed to show your gallery.'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await openFromHome(tester, 'Location');
      expect(find.byType(LocationScreen), findsOneWidget);
      expect(os.calls.where((c) => c.contains('documents')), isEmpty);
    });
  });
}
