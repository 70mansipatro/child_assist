import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/app_services.dart';
import 'package:child_assist/core/permissions/permission_service.dart';
import 'package:child_assist/features/chat/screens/chat_history_screen.dart';
import 'package:child_assist/features/chat/screens/chat_screen.dart';
import 'package:child_assist/features/documents/screens/document_viewer_screen.dart';
import 'package:child_assist/features/permissions/screens/permissions_screen.dart';
import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  late FakeBackend backend;
  late FakePermissionService os;
  late FakeDocumentPlatform device;
  late FakePhotoLibrary photos;
  late AppServices services;

  Future<void> startApp(WidgetTester tester) async {
    backend = FakeBackend();
    os = FakePermissionService();
    device = FakeDocumentPlatform();
    photos = FakePhotoLibrary.withPhotos(5);
    services = backend.services(os, documentPlatform: device, photoLibrary: photos);
    await services.authService.restoreSession();
    await tester.pumpWidget(MyApp(services: services));
    await tester.pumpAndSettle();
    await logIn(tester, 'mansi@example.com');
  }

  Future<void> openChat(WidgetTester tester) async {
    await openTab(tester, 'Chat');
    expect(find.byType(ChatScreen), findsOneWidget);
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
  }

  Future<void> openHistory(WidgetTester tester) async {
    await tester.tap(find.byTooltip('History'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatHistoryScreen), findsOneWidget);
  }

  testWidgets('the bottom bar has exactly Dashboard, Chat, Location and Profile', (tester) async {
    await startApp(tester);
    final bar = find.byType(NavigationBar);
    expect(bar, findsOneWidget);
    expect(find.descendant(of: bar, matching: find.byType(NavigationDestination)), findsNWidgets(4));
    for (final label in ['Dashboard', 'Chat', 'Location', 'Profile']) {
      expect(find.descendant(of: bar, matching: find.text(label)), findsOneWidget, reason: label);
    }
    for (final label in ['Photos', 'Documents', 'Permissions', 'Notifications']) {
      await tester.scrollUntilVisible(find.text(label), 100, scrollable: find.byType(Scrollable).first);
      expect(find.text(label), findsOneWidget, reason: label);
      expect(find.descendant(of: bar, matching: find.text(label)), findsNothing, reason: label);
    }
  });

  testWidgets('1. chat opens on the welcome screen with suggested prompts', (tester) async {
    await startApp(tester);
    await openChat(tester);

    expect(find.text('Your personal assistant'), findsOneWidget);
    expect(find.byTooltip('New Chat'), findsOneWidget);
    expect(find.byTooltip('History'), findsOneWidget);
    expect(find.text('Hey! 👋'), findsOneWidget);
    expect(find.text('How can I help you today?'), findsOneWidget);
    for (final prompt in ChatScreen.suggestions) {
      expect(find.text(prompt), findsOneWidget);
    }
    expect(find.text('Ask Child Assist...'), findsOneWidget);
  });

  testWidgets('2-3. sending a message shows it and the assistant reply; no userId is sent', (tester) async {
    await startApp(tester);
    await openChat(tester);

    await send(tester, 'What is your name?');

    expect(find.text('What is your name?'), findsOneWidget);
    expect(find.text('My name is Child Assist.'), findsOneWidget);
    expect(find.text('Hey! 👋'), findsNothing);

    final body = backend.chatRequests.single;
    expect(body['message'], 'What is your name?');
    expect(body.containsKey('userId'), isFalse);
    expect(body.containsKey('conversationId'), isFalse);
    expect(body['utcOffsetMinutes'], isA<int>());
  });

  testWidgets('a suggested prompt sends straight away', (tester) async {
    await startApp(tester);
    await openChat(tester);
    await tester.tap(find.text('What can you do?'));
    await tester.pumpAndSettle();
    expect(backend.chatRequests.single['message'], 'What can you do?');
  });

  testWidgets('4. shows "Child Assist is thinking..." while waiting', (tester) async {
    await startApp(tester);
    await openChat(tester);
    final pending = backend.chatPending = Completer<void>();

    await tester.enterText(find.byType(TextField), 'Tell me a joke');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Child Assist is thinking...'), findsOneWidget);
    expect(find.text('Tell me a joke'), findsOneWidget);

    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('Child Assist is thinking...'), findsNothing);
    expect(find.text('You said: Tell me a joke'), findsOneWidget);
  });

  testWidgets('5. a failed reply shows an error with Retry, and Retry sends it again', (tester) async {
    await startApp(tester);
    await openChat(tester);
    backend.chatFailures.add(503);

    await send(tester, 'Hello buddy');
    expect(find.text('Something went wrong. Please try again.'), findsOneWidget);
    expect(find.text('Child Assist is unavailable right now.'), findsOneWidget);
    expect(find.text('Not sent'), findsOneWidget);
    expect(find.textContaining('Exception'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong. Please try again.'), findsNothing);
    expect(find.text('Hello buddy'), findsOneWidget, reason: 'no duplicate message after retry');
    expect(find.text('You said: Hello buddy'), findsOneWidget);
    expect(backend.chatRequests, hasLength(2));
  });

  testWidgets('offline and timeout errors also offer Retry', (tester) async {
    await startApp(tester);
    await openChat(tester);
    backend.chatFailures.add(504);
    await send(tester, 'Hi');
    expect(find.text('Something went wrong. Please try again.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('6. New Chat clears the screen but keeps the old conversation', (tester) async {
    await startApp(tester);
    await openChat(tester);
    await send(tester, 'First question');

    await tester.tap(find.byTooltip('New Chat'));
    await tester.pumpAndSettle();
    expect(find.text('Hey! 👋'), findsOneWidget);
    expect(find.text('First question'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus, isTrue);

    await send(tester, 'Second question');
    expect(backend.chatRequests.last.containsKey('conversationId'), isFalse, reason: 'starts a new conversation');
    expect(backend.chats['u1'], hasLength(2), reason: 'the old conversation is not deleted');
  });

  testWidgets('7-8. History lists conversations newest first and reopens one to continue it', (tester) async {
    await startApp(tester);
    await openChat(tester);
    await send(tester, 'Older chat here');
    await tester.tap(find.byTooltip('New Chat'));
    await tester.pumpAndSettle();
    await send(tester, 'Newer chat here');

    await openHistory(tester);
    final older = tester.getTopLeft(find.text('Older chat here'));
    final newer = tester.getTopLeft(find.text('Newer chat here'));
    expect(newer.dy, lessThan(older.dy), reason: 'newest first');

    await tester.tap(find.text('Older chat here'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.text('Older chat here'), findsOneWidget);
    expect(find.text('You said: Older chat here'), findsOneWidget);
    expect(find.text('Newer chat here'), findsNothing);

    await send(tester, 'Continuing');
    final olderId = backend.chats['u1']!.first['id'];
    expect(backend.chatRequests.last['conversationId'], olderId);
  });

  testWidgets('9-10. delete asks for confirmation, Cancel keeps it, Delete removes it', (tester) async {
    await startApp(tester);
    await openChat(tester);
    await send(tester, 'Delete me please');
    await openHistory(tester);

    await tester.tap(find.byTooltip('Delete conversation'));
    await tester.pumpAndSettle();
    expect(find.text('Delete this conversation?'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Delete'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Delete me please'), findsOneWidget);
    expect(backend.chats['u1'], hasLength(1));

    await tester.tap(find.byTooltip('Delete conversation'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete me please'), findsNothing);
    expect(find.text('No conversations yet.'), findsOneWidget);
    expect(backend.chats['u1'], isEmpty);

    // The deleted chat was open: going back shows a fresh chat.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Hey! 👋'), findsOneWidget);
  });

  testWidgets('17. empty history', (tester) async {
    await startApp(tester);
    await openChat(tester);
    await openHistory(tester);
    expect(find.text('No conversations yet.'), findsOneWidget);
  });

  testWidgets('11-12. permission-required reply explains and opens Permissions without asking', (tester) async {
    await startApp(tester);
    await openChat(tester);
    backend.chatResponder = (_) => const FakeChatReply(
          "I can't check your location history right now.",
          toolEvents: [
            {'kind': 'location_history', 'status': 'permission_required', 'permission': 'LOCATION'},
          ],
        );

    await send(tester, 'Where did I go last month?');
    expect(
      find.text("I can't access your location history because Location permission is turned off."),
      findsOneWidget,
    );
    expect(find.text('Location permission is currently turned off. You can enable it from Permissions.'), findsOneWidget);
    expect(os.dialogsShown, isEmpty, reason: 'chat never requests a permission');

    await tester.tap(find.text('Open Permissions'));
    await tester.pumpAndSettle();
    expect(find.byType(PermissionsScreen), findsOneWidget);
  });

  testWidgets('13. tool status and location results use friendly text, never tool names', (tester) async {
    await startApp(tester);
    await openChat(tester);
    backend.chatResponder = (_) => const FakeChatReply(
          'Here are the places you visited last month.',
          toolEvents: [
            {
              'kind': 'location_history',
              'status': 'success',
              'data': {
                'count': 2,
                'hasMore': false,
                'locations': [
                  {
                    'capturedAt': '2026-09-20T10:15:00.000Z',
                    'placeName': 'City Library',
                    'address': '12 Park Street, Bhubaneswar',
                    'city': 'Bhubaneswar',
                    'state': 'Odisha',
                    'country': 'India',
                    'latitude': 20.29,
                    'longitude': 85.82,
                  },
                  {
                    'capturedAt': '2026-09-12T08:00:00.000Z',
                    'placeName': null,
                    'address': null,
                    'city': 'Cuttack',
                    'state': null,
                    'country': 'India',
                    'latitude': 20.46,
                    'longitude': 85.88,
                  },
                ],
              },
            },
          ],
        );

    await send(tester, 'Where did I go last month?');
    expect(find.text('Checked your location history'), findsOneWidget);
    expect(find.text('2 places'), findsOneWidget);
    expect(find.text('City Library'), findsOneWidget);
    expect(find.text('12 Park Street, Bhubaneswar'), findsOneWidget);
    expect(find.text('Cuttack'), findsOneWidget);
    expect(find.textContaining('get_location_history'), findsNothing);
    expect(find.textContaining('location_history'), findsNothing);
  });

  testWidgets('document results are searched on the phone and can be opened', (tester) async {
    await startApp(tester);
    final file = device.addFile('Math Notes.txt', mimeType: 'text/plain', size: 120, modifiedAt: DateTime(2026, 9, 14), content: 'x');
    device.addFile('history.pdf', mimeType: 'application/pdf', size: 900);
    device.willPick([file, device.files.values.last]);
    await services.documentService.addDocuments();

    await openChat(tester);
    backend.chatResponder = (_) => const FakeChatReply(
          "Here's what I found on your phone.",
          toolEvents: [
            {
              'kind': 'documents',
              'status': 'device_lookup',
              'data': {
                'query': {'text': 'math notes', 'type': null, 'limit': 10},
              },
            },
          ],
        );
    await send(tester, 'Find my math notes.');

    expect(find.text('Searched your documents'), findsOneWidget);
    expect(find.text('Math Notes.txt'), findsOneWidget);
    expect(find.text('TXT'), findsWidgets);
    expect(find.textContaining('Modified Sep 14, 2026'), findsOneWidget);
    expect(find.text('Available on this phone'), findsOneWidget);
    expect(find.text('history.pdf'), findsNothing);

    await tester.ensureVisible(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(DocumentViewerScreen), findsOneWidget);
  });

  testWidgets('photo results show the photo from the phone, or a permission note', (tester) async {
    await startApp(tester);
    await openChat(tester);
    var next = 1;
    backend.chatResponder = (_) => FakeChatReply(
          'Let me find that photo.',
          toolEvents: [
            {
              'kind': 'photos',
              'status': 'device_lookup',
              'data': {
                'requestId': 'search${next++}',
                'query': {'startDate': '2026-10-05T00:00:00.000Z', 'endDate': '2026-10-06T00:00:00.000Z'},
                'visits': <Object>[],
              },
            },
          ],
        );

    // Photos access is off: no dialog, just the explanation.
    await send(tester, 'Find photos from yesterday.');
    expect(find.text("I can't access your photos because Photos permission is turned off."), findsOneWidget);
    expect(os.dialogsShown, isEmpty);

    os.os[AppPermission.photos] = PermissionState.granted;
    await send(tester, 'Find photos from yesterday.');
    expect(find.text('Open Photo'), findsOneWidget);
    expect(find.text('Analyze'), findsOneWidget);
    expect(photos.imageReads.every((r) => r.endsWith('300x300')), isTrue, reason: 'thumbnails only');
  });

  testWidgets('14-16. confirmation card: shows exactly what is sent; Cancel sends nothing, Confirm runs it', (tester) async {
    await startApp(tester);
    await openChat(tester);
    var next = 1;
    backend.chatResponder = (_) => FakeChatReply(
          "I've prepared that. Please confirm.",
          toolEvents: const [
            {'kind': 'send_action', 'status': 'confirmation_required'},
          ],
          pendingActions: [
            {
              'id': 'act${next++}',
              'toolName': 'prepare_email',
              'type': 'SHARE_LOCATION',
              'channel': 'EMAIL',
              'summary': 'Share your location with Mansi <mansi@example.com> by email?',
              'recipientName': 'Mansi',
              'recipientAddress': 'mansi@example.com',
              'subject': "Child Assist - Today's Location",
              'message': "Today's location (shared from Child Assist):\n• 10:32 AM — Patia, Bhubaneswar",
              'dataSummary': "Today's location (1 saved location)",
            },
          ],
        );

    await send(tester, 'Mansi ko meri aaj ki location email kar do');
    expect(find.text('Share your location with Mansi <mansi@example.com> by email?'), findsOneWidget);
    // Recipient, subject, the kind of data and the exact message are all shown before confirming.
    expect(find.text('Mansi <mansi@example.com>'), findsOneWidget);
    expect(find.text("Child Assist - Today's Location"), findsOneWidget);
    expect(find.text("Today's location (1 saved location)"), findsOneWidget);
    expect(find.textContaining('Patia, Bhubaneswar'), findsOneWidget);
    expect(find.text('Nothing is sent until you confirm.'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Cancel'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Confirm & Send'), findsOneWidget);
    expect(backend.chatActions, isEmpty, reason: 'nothing runs automatically');

    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(backend.chatActions, ['cancel act1']);
    expect(find.text("Okay, I didn't send anything."), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Confirm & Send'), findsNothing);
    expect(backend.sentEmails, isEmpty);

    await send(tester, 'Mansi ko meri aaj ki location email kar do');
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm & Send'));
    await tester.pumpAndSettle();
    expect(backend.chatActions, ['cancel act1', 'confirm act2']);
    expect(backend.chatActionBodies.last, {'conversationId': backend.chatRequests.last['conversationId']});
    expect(find.text('Email sent to Mansi.'), findsOneWidget);
    expect(backend.sentEmails, hasLength(1));
  });

  testWidgets('18. long, multi-line messages render and scroll without overflow', (tester) async {
    await startApp(tester);
    await openChat(tester);
    final long = List.generate(60, (i) => 'Line ${i + 1} of a very long message about my school day.').join('\n');

    await send(tester, long);
    expect(tester.takeException(), isNull);
    expect(find.text('You said: $long'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('19. dark mode renders the chat', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await startApp(tester);
    await openChat(tester);
    expect(Theme.of(tester.element(find.byType(ChatScreen))).brightness, Brightness.dark);
    await send(tester, 'What is your name?');
    expect(find.text('My name is Child Assist.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('20. opening chat and typing never touches the microphone permission', (tester) async {
    await startApp(tester);
    os.calls.clear();
    await openChat(tester);
    await send(tester, 'What is your name?');
    expect(find.byTooltip('Voice input'), findsOneWidget);

    expect(os.dialogsShown, isEmpty);
    expect(os.calls.where((c) => c.contains('microphone')), isEmpty);
    expect(os.calls.where((c) => c.startsWith('request')), isEmpty);
  });

  testWidgets('a conversation deleted elsewhere starts a new chat instead of failing silently', (tester) async {
    await startApp(tester);
    await openChat(tester);
    await send(tester, 'Hello');
    backend.chats['u1']!.clear();

    await send(tester, 'Are you there?');
    expect(find.text('Something went wrong. Please try again.'), findsOneWidget);
    expect(find.textContaining('a new chat was started'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(backend.chatRequests.last.containsKey('conversationId'), isFalse);
    expect(find.text('You said: Are you there?'), findsOneWidget);
  });
}
