// "Send <A>'s number to <B>": A (the contact whose number is shared) and B (the recipient) are
// found on the phone separately, the message carries A's picked number, and B's number is only the
// WhatsApp recipient. Every name and number here is generated: nothing depends on a fixed contact.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/app_services.dart';
import 'package:child_assist/core/permissions/permission_service.dart';
import 'package:child_assist/features/contacts/models/contact_item.dart';
import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

final _random = Random();
String _digits(int n) => List.generate(n, (_) => _random.nextInt(10)).join();
String _tag() => String.fromCharCodes(List.generate(6, (_) => 97 + _random.nextInt(26)));

/// One generated scenario: a contact to share, and a recipient.
class Fixture {
  Fixture()
    : contactName = 'Person ${_tag()}',
      requestedPhone = '+1${_digits(10)}',
      recipientName = 'Receiver ${_tag()}',
      recipientPhone = '+44${_digits(10)}';

  final String contactName;
  final String requestedPhone;
  final String recipientName;
  final String recipientPhone;

  ContactItem get contact => ContactItem(id: 'c-$contactName', displayName: contactName, phoneNumbers: [requestedPhone]);
  ContactItem get recipient =>
      ContactItem(id: 'c-$recipientName', displayName: recipientName, phoneNumbers: [recipientPhone]);

  String get expectedMessage => "Here is $contactName's phone number: $requestedPhone";
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  late FakeBackend backend;
  late FakePermissionService os;
  late FakeContactsSource contacts;
  late FakeMessageHandoff handoff;
  late AppServices services;
  var nextAction = 1;

  Future<void> startApp(WidgetTester tester, List<ContactItem> book) async {
    nextAction = 1;
    backend = FakeBackend();
    os = FakePermissionService();
    os.os[AppPermission.contacts] = PermissionState.granted;
    contacts = FakeContactsSource(book);
    handoff = FakeMessageHandoff();
    services = backend.services(os, contactsSource: contacts, messageHandoff: handoff);
    await services.authService.restoreSession();
    await tester.pumpWidget(MyApp(services: services));
    await tester.pumpAndSettle();
    await logIn(tester, 'mansi@example.com');
    await openTab(tester, 'Chat');
  }

  /// What the server returns for "send <shared>'s number to <recipient>": names only, no numbers.
  void respondWithShare(String shared, String recipient) {
    backend.chatResponder = (_) => FakeChatReply(
      'Please pick the contacts and check the message.',
      toolEvents: const [
        {'kind': 'send_action', 'status': 'confirmation_required'},
      ],
      pendingActions: [
        {
          'id': 'act${nextAction++}',
          'status': 'PENDING',
          'toolName': 'prepare_whatsapp',
          'type': 'SHARE_CONTACT',
          'channel': 'WHATSAPP',
          'summary': 'Send this WhatsApp message to $recipient?',
          'contactQuery': recipient,
          'sharedContactQuery': shared,
        },
      ],
    );
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).last, text);
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
  }

  Map<String, dynamic>? bodyFor(String verb) {
    for (var i = backend.chatActions.length - 1; i >= 0; i--) {
      if (backend.chatActions[i].startsWith('$verb ')) return backend.chatActionBodies[i];
    }
    return null;
  }

  testWidgets('the requested contact\'s number goes in the message; the recipient\'s only addresses it', (tester) async {
    final f = Fixture();
    await startApp(tester, [f.contact, f.recipient]);
    respondWithShare(f.contactName, f.recipientName);
    await send(tester, "Send ${f.contactName}'s number to ${f.recipientName}");

    // Both were found on the phone and kept apart.
    expect(bodyFor('shared-contact'), {'name': f.contactName, 'phone': f.requestedPhone, 'conversationId': 'conv1'});
    expect(bodyFor('recipient'), {'address': f.recipientPhone, 'name': f.recipientName, 'conversationId': 'conv1'});

    expect(find.text('Send this WhatsApp message to ${f.recipientName} (${f.recipientPhone})?'), findsOneWidget);
    expect(find.text('${f.recipientName}\n${f.recipientPhone}'), findsOneWidget);
    expect(find.text(f.expectedMessage), findsOneWidget);
    expect(find.textContaining(RegExp(': .*${RegExp.escape(f.recipientPhone)}')), findsNothing,
        reason: "the recipient's number is never in the message");
    expect(find.text('WhatsApp will open with this ready. You send it from WhatsApp.'), findsOneWidget);
    expect(handoff.calls, isEmpty, reason: 'nothing opens before Continue');

    await tester.tap(find.widgetWithText(FilledButton, 'Continue to WhatsApp'));
    await tester.pumpAndSettle();
    // Exactly the message that was shown, to exactly the recipient.
    expect(handoff.calls, ['whatsapp ${f.recipientPhone}: ${f.expectedMessage}']);
    expect(find.textContaining('Tap Send in WhatsApp'), findsOneWidget);
    expect(find.textContaining(RegExp(r'\bsent\b', caseSensitive: false)), findsNothing);
  });

  testWidgets('different names and numbers work without any code change', (tester) async {
    final fixtures = [Fixture(), Fixture(), Fixture()];
    await startApp(tester, [for (final f in fixtures) ...[f.contact, f.recipient]]);
    for (final f in fixtures) {
      respondWithShare(f.contactName, f.recipientName);
      await send(tester, "${f.contactName} ka number ${f.recipientName} ko WhatsApp karo");
      expect(bodyFor('shared-contact')!['phone'], f.requestedPhone);
      expect(bodyFor('recipient')!['address'], f.recipientPhone);
      final action = backend.chatActionStore['act${nextAction - 1}']!;
      expect(action['message'], f.expectedMessage);
      expect(action['message'], isNot(contains(f.recipientPhone)));
    }
  });

  testWidgets('several matching contacts must be chosen from; nothing is guessed', (tester) async {
    final f = Fixture();
    final tag = _tag();
    final first = ContactItem(id: 'x1', displayName: 'Twin $tag First', phoneNumbers: ['+1${_digits(10)}']);
    final second = ContactItem(id: 'x2', displayName: 'Twin $tag Second', phoneNumbers: ['+1${_digits(10)}']);
    await startApp(tester, [first, second, f.recipient]);
    respondWithShare('Twin $tag', f.recipientName);
    await send(tester, "Send Twin $tag's number to ${f.recipientName}");

    expect(find.text('I found 2 contacts named Twin $tag.'), findsOneWidget);
    expect(bodyFor('shared-contact'), isNull);
    await tester.tap(find.text(second.displayName));
    await tester.pumpAndSettle();
    expect(bodyFor('shared-contact'), containsPair('phone', second.phoneNumbers.single));
    expect(find.text("Here is ${second.displayName}'s phone number: ${second.phoneNumbers.single}"), findsOneWidget);
  });

  testWidgets('several numbers on the contact must be chosen from, with their labels', (tester) async {
    final f = Fixture();
    final numbers = ['+1${_digits(10)}', '+1${_digits(10)}', '+1${_digits(10)}'];
    final multi = ContactItem(
      id: 'm',
      displayName: f.contactName,
      phoneNumbers: numbers,
      phoneLabels: const ['Mobile', 'Home', 'Work'],
    );
    await startApp(tester, [multi, f.recipient]);
    respondWithShare(f.contactName, f.recipientName);
    await send(tester, "Send ${f.contactName}'s number to ${f.recipientName}");

    expect(find.text('Select phone number for ${f.contactName}'), findsOneWidget);
    for (final label in ['Mobile', 'Home', 'Work']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(bodyFor('shared-contact'), isNull, reason: 'no number is picked for the user');

    await tester.tap(find.text(numbers[1]));
    await tester.pumpAndSettle();
    expect(find.text("Here is ${f.contactName}'s phone number: ${numbers[1]}"), findsOneWidget);
    expect(find.textContaining(numbers[0]), findsNothing);
  });

  testWidgets('the recipient is chosen separately when several contacts match it', (tester) async {
    final f = Fixture();
    final tag = _tag();
    final r1 = ContactItem(id: 'r1', displayName: 'Friend $tag A', phoneNumbers: ['+1${_digits(10)}']);
    final r2 = ContactItem(id: 'r2', displayName: 'Friend $tag B', phoneNumbers: ['+1${_digits(10)}']);
    await startApp(tester, [f.contact, r1, r2]);
    respondWithShare(f.contactName, 'Friend $tag');
    await send(tester, "Send ${f.contactName}'s number to Friend $tag");

    expect(bodyFor('shared-contact'), containsPair('phone', f.requestedPhone));
    expect(find.text('I found 2 contacts named Friend $tag.'), findsOneWidget);
    await tester.tap(find.text(r1.displayName));
    await tester.pumpAndSettle();
    expect(bodyFor('recipient'), containsPair('address', r1.phoneNumbers.single));
    expect(find.text(f.expectedMessage), findsOneWidget);
  });

  testWidgets('Cancel opens nothing', (tester) async {
    final f = Fixture();
    await startApp(tester, [f.contact, f.recipient]);
    respondWithShare(f.contactName, f.recipientName);
    await send(tester, "Send ${f.contactName}'s number to ${f.recipientName}");
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(backend.chatActions.last, 'cancel act1');
    expect(handoff.calls, isEmpty);
    expect(find.text("Okay, I didn't send anything."), findsOneWidget);
  });

  testWidgets('without Contacts permission nothing is looked up', (tester) async {
    final f = Fixture();
    await startApp(tester, [f.contact, f.recipient]);
    os.os[AppPermission.contacts] = PermissionState.denied;
    respondWithShare(f.contactName, f.recipientName);
    await send(tester, "Send ${f.contactName}'s number to ${f.recipientName}");
    expect(find.text('I need Contacts permission to search your phone contacts.'), findsOneWidget);
    expect(contacts.reads, 0);
    expect(backend.chatActions, isEmpty);
  });

  testWidgets('a contact that is not found, or has no number, is never given one', (tester) async {
    final f = Fixture();
    final noPhone = ContactItem(id: 'n', displayName: 'Nophone ${_tag()}', emails: const ['someone@example.com']);
    await startApp(tester, [noPhone, f.recipient]);

    respondWithShare('Unknown ${_tag()}', f.recipientName);
    await send(tester, 'Send the unknown number');
    expect(find.textContaining("in your contacts."), findsOneWidget);
    expect(backend.chatActions, isEmpty);

    respondWithShare(noPhone.displayName, f.recipientName);
    await send(tester, "Send ${noPhone.displayName}'s number to ${f.recipientName}");
    expect(find.text("${noPhone.displayName} doesn't have a phone number saved in your contacts."), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Continue to WhatsApp'), findsNothing);
    expect(backend.chatActions, isEmpty);
  });
}
