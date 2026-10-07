import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/app_services.dart';
import 'package:child_assist/core/permissions/permission_service.dart';
import 'package:child_assist/features/chat/screens/chat_screen.dart';
import 'package:child_assist/features/contacts/models/contact_item.dart';
import 'package:child_assist/features/contacts/services/contact_permission_service.dart';
import 'package:child_assist/features/contacts/services/contact_service.dart';
import 'package:child_assist/features/permissions/screens/permissions_screen.dart';
import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

const mansi = ContactItem(
  id: 'c1',
  displayName: 'Mansi Patro',
  phoneNumbers: ['98765 43210'],
  emails: ['mansi@example.com'],
);
const rahulSharma = ContactItem(id: 'c2', displayName: 'Rahul Sharma', phoneNumbers: ['98111 11111']);
const rahulPatnaik = ContactItem(
  id: 'c3',
  displayName: 'Rahul Patnaik',
  phoneNumbers: ['97222 22222'],
  emails: ['rahul.p@example.com'],
);
const papa = ContactItem(id: 'c4', displayName: 'Papa', phoneNumbers: ['+91 99887 76655']);
const papaji = ContactItem(id: 'c5', displayName: 'Papaji Uncle', phoneNumbers: ['90000 00000']);
const noPhone = ContactItem(id: 'c6', displayName: 'Neha Email Only', emails: ['neha@example.com']);
const noEmail = ContactItem(id: 'c7', displayName: 'Dadi', phoneNumbers: ['94444 44444']);
const priya = ContactItem(id: 'c8', displayName: 'प्रिया', phoneNumbers: ['93333 33333']);

List<ContactItem> allContacts() => [mansi, rahulSharma, rahulPatnaik, papa, papaji, noPhone, noEmail, priya];

void main() {
  group('contact search', () {
    List<String> names(String query) => [for (final c in matchContacts(allContacts(), query)) c.displayName];

    test('exact, case-insensitive and spacing-insensitive names', () {
      expect(names('Mansi Patro'), ['Mansi Patro']);
      expect(names('mansi patro'), ['Mansi Patro']);
      expect(names('MANSi   PATRO'), ['Mansi Patro']);
      expect(names('MansiPatro'), ['Mansi Patro']);
      expect(names("Mansi's"), ['Mansi Patro']);
    });

    test('partial names match the start of a word', () {
      expect(names('Mansi'), ['Mansi Patro']);
      expect(names('Rah'), ['Rahul Patnaik', 'Rahul Sharma']);
      expect(names('rahul s'), ['Rahul Sharma']);
      expect(names('Patn'), ['Rahul Patnaik']);
    });

    test('several matches are all returned, never guessed', () {
      expect(names('Rahul'), ['Rahul Patnaik', 'Rahul Sharma']);
    });

    test('an exact name wins over longer names that start with it', () {
      expect(names('Papa'), ['Papa']);
      expect(names('papaji'), ['Papaji Uncle']);
    });

    test('any name and any script works; nothing is hard-coded', () {
      expect(names('प्रिया'), ['प्रिया']);
      expect(names('Dadi'), ['Dadi']);
      final custom = [const ContactItem(id: 'x', displayName: 'Zyx Qwertyson', phoneNumbers: ['91234 56789'])];
      expect(matchContacts(custom, 'zyx').single.displayName, 'Zyx Qwertyson');
      expect(matchContacts(custom, 'Mansi'), isEmpty);
    });

    test('no match and empty queries return nothing', () {
      expect(names('Somebody Else'), isEmpty);
      expect(names('   '), isEmpty);
    });
  });

  group('ContactService permission', () {
    late FakePermissionService os;
    late FakeContactsSource source;
    late ContactService service;

    setUp(() {
      os = FakePermissionService();
      source = FakeContactsSource(allContacts());
      service = ContactService(permission: ContactPermissionService(permissionService: os), source: source);
    });

    test('granted: the phone is searched', () async {
      os.os[AppPermission.contacts] = PermissionState.granted;
      final result = await service.searchContacts('Mansi');
      expect(result.status, ContactSearchStatus.done);
      expect(result.matches.single.phoneNumbers, ['98765 43210']);
      expect(source.reads, 1);
    });

    test('denied: contacts are never read and no dialog is shown', () async {
      os.os[AppPermission.contacts] = PermissionState.denied;
      expect((await service.searchContacts('Mansi')).status, ContactSearchStatus.permissionDenied);
      expect(source.reads, 0);
      expect(os.dialogsShown, isEmpty);
    });

    test('permanently denied: reported as blocked, nothing read', () async {
      os.os[AppPermission.contacts] = PermissionState.permanentlyDenied;
      expect((await service.searchContacts('Mansi')).status, ContactSearchStatus.permissionBlocked);
      expect(source.reads, 0);
    });

    test('a failing read is reported, not thrown', () async {
      os.os[AppPermission.contacts] = PermissionState.granted;
      source.error = Exception('provider crashed');
      expect((await service.searchContacts('Mansi')).status, ContactSearchStatus.failed);
    });

    test('the OS state is authoritative', () {
      expect(ContactPermissionService.accessFor(PermissionState.limited), ContactAccess.granted);
      expect(ContactPermissionService.accessFor(PermissionState.restricted), ContactAccess.unavailable);
    });
  });

  group('chat', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    late FakeBackend backend;
    late FakePermissionService os;
    late FakeContactsSource contacts;
    late FakeMessageHandoff handoff;
    late FakeVoiceInput voice;
    late AppServices services;
    var nextAction = 1;

    Future<void> startApp(WidgetTester tester, {List<ContactItem>? book}) async {
      nextAction = 1;
      backend = FakeBackend();
      os = FakePermissionService();
      os.os[AppPermission.contacts] = PermissionState.granted;
      os.os[AppPermission.microphone] = PermissionState.granted;
      contacts = FakeContactsSource(book ?? allContacts());
      handoff = FakeMessageHandoff();
      voice = FakeVoiceInput();
      services = backend.services(os, contactsSource: contacts, messageHandoff: handoff, voiceInput: voice);
      await services.authService.restoreSession();
      await tester.pumpWidget(MyApp(services: services));
      await tester.pumpAndSettle();
      await logIn(tester, 'mansi@example.com');
      await openTab(tester, 'Chat');
      expect(find.byType(ChatScreen), findsOneWidget);
    }

    Future<void> send(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField).last, text);
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
    }

    Future<void> speak(WidgetTester tester, String words) async {
      await tester.tap(find.byTooltip('Voice input'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      voice.finish(words);
      await tester.pumpAndSettle();
    }

    FakeChatReply lookup(String name, String field) => FakeChatReply(
      "I'm checking your contacts for $name.",
      toolEvents: [
        {
          'kind': 'contacts',
          'status': 'device_lookup',
          'data': {
            'query': {'name': name, 'field': field},
          },
        },
      ],
    );

    FakeChatReply action(Map<String, dynamic> fields) => FakeChatReply(
      'Please check the details and confirm.',
      toolEvents: const [
        {'kind': 'send_action', 'status': 'confirmation_required'},
      ],
      pendingActions: [
        {'id': 'act${nextAction++}', 'status': 'PENDING', ...fields},
      ],
    );

    FakeChatReply emailTo(String name, {String message = 'Maths homework is page 42.'}) => action({
      'toolName': 'prepare_email',
      'type': 'SEND_EMAIL',
      'channel': 'EMAIL',
      'summary': 'Send an email to $name with the subject "Homework"?',
      'contactQuery': name,
      'subject': 'Homework',
      'message': message,
    });

    FakeChatReply whatsAppTo(String name, {String message = 'I will be late today.', Map<String, dynamic> extra = const {}}) =>
        action({
          'toolName': 'prepare_whatsapp',
          'type': 'SEND_WHATSAPP',
          'channel': 'WHATSAPP',
          'summary': 'Send this WhatsApp message to $name?',
          'contactQuery': name,
          'message': message,
          ...extra,
        });

    /// Nothing about the address book went to the server: only the one picked address, ever.
    void expectNoAddressBookUploaded() {
      final everything = jsonEncode([backend.chatRequests, backend.chatActionBodies]);
      for (final c in allContacts()) {
        for (final phone in c.phoneNumbers) {
          if (backend.chatActionBodies.any((b) => b['address'] == phone)) continue;
          expect(everything.contains(phone), isFalse, reason: '${c.displayName} leaked');
        }
      }
      for (final body in backend.chatRequests) {
        expect(body.keys.toSet().difference({'message', 'conversationId', 'utcOffsetMinutes'}), isEmpty);
      }
    }

    testWidgets('"Mansi ka number do" shows the number from the phone, prioritising the number', (tester) async {
      await startApp(tester);
      backend.chatResponder = (_) => lookup('Mansi', 'phone');
      await send(tester, 'Mansi ka number do');

      expect(find.text('Mansi Patro'), findsOneWidget);
      expect(find.text('98765 43210'), findsOneWidget);
      expect(find.text('mansi@example.com'), findsNothing, reason: 'only the number was asked for');
      expect(contacts.reads, 1);
      expectNoAddressBookUploaded();
    });

    testWidgets('an email lookup shows the email; any contact name works', (tester) async {
      await startApp(tester);
      backend.chatResponder = (_) => lookup('Rahul Patnaik', 'email');
      await send(tester, 'Rahul Patnaik ka email kya hai');
      expect(find.text('rahul.p@example.com'), findsOneWidget);

      backend.chatResponder = (_) => lookup('प्रिया', 'phone');
      await send(tester, 'प्रिया ka number do');
      expect(find.text('93333 33333'), findsOneWidget);
    });

    testWidgets('missing fields are stated plainly, never invented', (tester) async {
      await startApp(tester);
      backend.chatResponder = (_) => lookup('Neha', 'phone');
      await send(tester, 'Neha ka number do');
      expect(find.text("Neha Email Only doesn't have a phone number saved in your contacts."), findsOneWidget);

      backend.chatResponder = (_) => lookup('Dadi', 'email');
      await send(tester, 'Dadi ka email do');
      expect(find.text("Dadi doesn't have an email address saved in your contacts."), findsOneWidget);
    });

    testWidgets('several matches: the user picks one, then sees it', (tester) async {
      await startApp(tester);
      backend.chatResponder = (_) => lookup('Rahul', 'phone');
      await send(tester, 'Rahul ka number do');

      expect(find.text('I found 2 contacts named Rahul.'), findsOneWidget);
      expect(find.text('Which one do you mean?'), findsOneWidget);
      expect(find.text('Rahul Sharma'), findsOneWidget);
      expect(find.text('Rahul Patnaik'), findsOneWidget);

      await tester.tap(find.text('Rahul Sharma'));
      await tester.pumpAndSettle();
      expect(find.text('Which one do you mean?'), findsNothing);
      expect(find.text('98111 11111'), findsOneWidget);
    });

    testWidgets('no match says the contact was not found', (tester) async {
      await startApp(tester);
      backend.chatResponder = (_) => lookup('Somebody', 'phone');
      await send(tester, 'Somebody ka number do');
      expect(find.text('I couldn\'t find a contact named "Somebody" in your phone contacts.'), findsOneWidget);
    });

    testWidgets('without Contacts permission nothing is read; Open Permissions is offered', (tester) async {
      await startApp(tester);
      os.os[AppPermission.contacts] = PermissionState.denied;
      backend.chatResponder = (_) => lookup('Mansi', 'phone');
      await send(tester, 'Mansi ka number do');

      expect(find.text('I need Contacts permission to search your phone contacts.'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Cancel'), findsOneWidget);
      expect(contacts.reads, 0);
      expect(os.dialogsShown, isEmpty, reason: 'chat never shows the system dialog itself');

      await tester.tap(find.widgetWithText(FilledButton, 'Open Permissions'));
      await tester.pumpAndSettle();
      expect(find.byType(PermissionsScreen), findsOneWidget);
    });

    testWidgets('blocked Contacts permission offers the phone Settings', (tester) async {
      await startApp(tester);
      os.os[AppPermission.contacts] = PermissionState.permanentlyDenied;
      backend.chatResponder = (_) => lookup('Mansi', 'phone');
      await send(tester, 'Mansi ka number do');

      expect(find.text('Contacts permission is blocked. Please enable it in your phone settings.'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Open Settings'));
      await tester.pumpAndSettle();
      expect(os.settingsOpened, 1);
      expect(contacts.reads, 0);
    });

    testWidgets('a permission card from the server explains Contacts is needed', (tester) async {
      await startApp(tester);
      backend.chatResponder = (_) => const FakeChatReply(
        'I need Contacts permission to search your phone contacts.',
        toolEvents: [
          {'kind': 'contacts', 'status': 'permission_required', 'permission': 'CONTACTS'},
        ],
      );
      await send(tester, 'Mansi ka number do');
      expect(find.text('Open Permissions'), findsOneWidget);
      expect(contacts.reads, 0);
    });

    testWidgets('email: the contact is resolved on the phone, shown, and sent only on Confirm', (tester) async {
      await startApp(tester);
      backend.chatResponder = (_) => emailTo('Mansi');
      await send(tester, 'Mansi ko ye details email kar do');

      // One contact with one email: chosen automatically, then shown for confirmation.
      expect(backend.chatActions, ['recipient act1']);
      expect(backend.chatActionBodies.single['address'], 'mansi@example.com');
      expect(backend.chatActionBodies.single['name'], 'Mansi Patro');
      expect(find.text('Mansi Patro <mansi@example.com>'), findsOneWidget);
      expect(find.text('Homework'), findsOneWidget);
      expect(find.text('Maths homework is page 42.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Confirm & Send'), findsOneWidget);
      expect(backend.sentEmails, isEmpty, reason: 'nothing is sent before Confirm');

      await tester.tap(find.widgetWithText(FilledButton, 'Confirm & Send'));
      await tester.pumpAndSettle();
      expect(backend.sentEmails.single['to'], 'mansi@example.com');
      expect(find.text('Email sent to Mansi Patro.'), findsOneWidget);
      expectNoAddressBookUploaded();
    });

    testWidgets('email: Cancel sends nothing', (tester) async {
      await startApp(tester);
      backend.chatResponder = (_) => emailTo('Mansi');
      await send(tester, 'Mansi ko email karo');
      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(backend.chatActions.last, 'cancel act1');
      expect(find.text("Okay, I didn't send anything."), findsOneWidget);
      expect(backend.sentEmails, isEmpty);
    });

    testWidgets('email: several contacts, the user picks one first', (tester) async {
      await startApp(tester);
      backend.chatResponder = (_) => emailTo('Rahul');
      await send(tester, 'Rahul ko email karo');
      expect(find.text('I found 2 contacts named Rahul.'), findsOneWidget);
      expect(backend.chatActions, isEmpty, reason: 'nothing is chosen for the user');

      await tester.tap(find.text('Rahul Patnaik'));
      await tester.pumpAndSettle();
      expect(backend.chatActionBodies.single['address'], 'rahul.p@example.com');
      expect(find.text('Rahul Patnaik <rahul.p@example.com>'), findsOneWidget);
    });

    testWidgets('email: no saved email asks for an address and uses exactly that', (tester) async {
      await startApp(tester);
      backend.chatResponder = (_) => emailTo('Dadi');
      await send(tester, 'Dadi ko ye details email kar do');
      expect(find.text('Dadi ke contact me email saved nahi hai. Kis email address par bheju?'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'Email address'), 'not an email');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Use this address'));
      await tester.pumpAndSettle();
      expect(find.text("That email address doesn't look right."), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Confirm & Send'), findsNothing);

      await tester.enterText(find.widgetWithText(TextField, 'Email address'), 'dadi@example.com');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Use this address'));
      await tester.pumpAndSettle();
      expect(find.text('Dadi <dadi@example.com>'), findsOneWidget);
      expect(backend.sentEmails, isEmpty);
    });

    testWidgets('email: a server failure is shown honestly', (tester) async {
      await startApp(tester);
      backend.emailFails = true;
      backend.chatResponder = (_) => emailTo('Mansi');
      await send(tester, 'Mansi ko email karo');
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm & Send'));
      await tester.pumpAndSettle();
      expect(find.textContaining("couldn't send the email"), findsOneWidget);
      expect(find.text('Email sent to Mansi Patro.'), findsNothing);
    });

    testWidgets('location email: recipient and the kind of data are shown before confirming', (tester) async {
      await startApp(tester);
      backend.chatResponder = (_) => action({
        'toolName': 'prepare_email',
        'type': 'SHARE_LOCATION',
        'channel': 'EMAIL',
        'summary': 'Share your location with Mansi by email?',
        'contactQuery': 'Mansi',
        'subject': "Child Assist - Today's Location",
        'message': "Today's location (shared from Child Assist):\n• 10:32 AM — Patia, Bhubaneswar",
        'dataSummary': "Today's location (1 saved location)",
      });
      await send(tester, 'Mansi ko meri aaj ki location email kar do');
      expect(find.text('Mansi Patro <mansi@example.com>'), findsOneWidget);
      expect(find.text("Today's location (1 saved location)"), findsOneWidget);
      expect(find.textContaining('Patia, Bhubaneswar'), findsOneWidget);
      expect(backend.sentEmails, isEmpty);
    });

    testWidgets('WhatsApp: confirmation, then WhatsApp opens with the exact number and text; never "sent"', (tester) async {
      await startApp(tester);
      backend.chatResponder = (_) => whatsAppTo('Rahul Sharma');
      await send(tester, 'Rahul Sharma ko WhatsApp karo ki main late aaunga');

      expect(find.text('Rahul Sharma\n98111 11111'), findsOneWidget);
      expect(find.text('I will be late today.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Continue to WhatsApp'), findsOneWidget);
      expect(handoff.calls, isEmpty, reason: 'nothing opens before the user confirms');

      await tester.tap(find.widgetWithText(FilledButton, 'Continue to WhatsApp'));
      await tester.pumpAndSettle();
      expect(handoff.calls, ['whatsapp 98111 11111: I will be late today.']);
      expect(backend.chatActions, ['recipient act1', 'confirm act1', 'handoff act1 whatsapp_opened']);
      expect(
        find.text('WhatsApp opened for Rahul Sharma with your message. Tap Send in WhatsApp to deliver it.'),
        findsOneWidget,
      );
      expect(find.textContaining(RegExp(r'\bsent\b', caseSensitive: false)), findsNothing);
    });

    testWidgets('WhatsApp: Cancel opens nothing', (tester) async {
      await startApp(tester);
      backend.chatResponder = (_) => whatsAppTo('Papa');
      await send(tester, 'Papa ko WhatsApp karo');
      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(handoff.calls, isEmpty);
      expect(find.text("Okay, I didn't send anything."), findsOneWidget);
    });

    testWidgets('WhatsApp: several matches need a choice first', (tester) async {
      await startApp(tester);
      backend.chatResponder = (_) => whatsAppTo('Rahul');
      await send(tester, 'Rahul ko WhatsApp karo');
      expect(find.text('I found 2 contacts named Rahul.'), findsOneWidget);
      await tester.tap(find.text('Rahul Patnaik'));
      await tester.pumpAndSettle();
      expect(backend.chatActionBodies.single['address'], '97222 22222');
    });

    testWidgets('WhatsApp: a contact without a number is never given one', (tester) async {
      await startApp(tester);
      backend.chatResponder = (_) => whatsAppTo('Neha');
      await send(tester, 'Neha ko WhatsApp karo');
      expect(find.text("This contact doesn't have a phone number saved."), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Continue to WhatsApp'), findsNothing);
      expect(backend.chatActions, isEmpty);
    });

    testWidgets('WhatsApp unavailable: says so and offers the share sheet', (tester) async {
      await startApp(tester);
      handoff.whatsAppInstalled = false;
      backend.chatResponder = (_) => whatsAppTo('Papa');
      await send(tester, 'Papa ko WhatsApp karo');
      await tester.tap(find.widgetWithText(FilledButton, 'Continue to WhatsApp'));
      await tester.pumpAndSettle();

      expect(find.text("WhatsApp isn't available on this device."), findsOneWidget);
      expect(backend.chatActions.last, 'handoff act1 unavailable');
      await tester.tap(find.widgetWithText(FilledButton, 'Share instead'));
      await tester.pumpAndSettle();
      expect(handoff.calls.last, 'share: I will be late today.');
      expect(backend.chatActions.last, 'handoff act1 share_opened');
      expect(find.textContaining('Nothing is sent until you send it'), findsOneWidget);
    });

    testWidgets('WhatsApp location share shows the recipient and the information first', (tester) async {
      await startApp(tester);
      backend.chatResponder = (_) => whatsAppTo(
        'Papa',
        message: "Today's location (shared from Child Assist):\n• 9:00 AM — School",
        extra: {
          'type': 'SHARE_LOCATION',
          'summary': 'Share your location with Papa on WhatsApp?',
          'dataSummary': "Today's location (1 saved location)",
        },
      );
      await send(tester, 'Papa ko WhatsApp par meri aaj ki location bhejo');
      expect(find.text('Share your location with Papa (+91 99887 76655) on WhatsApp?'), findsOneWidget);
      expect(find.text('Papa\n+91 99887 76655'), findsOneWidget);
      expect(find.text("Today's location (1 saved location)"), findsOneWidget);
      expect(handoff.calls, isEmpty);
    });

    testWidgets('voice: a spoken contact lookup runs the same flow', (tester) async {
      await startApp(tester);
      backend.chatResponder = (_) => lookup('Mansi', 'phone');
      await speak(tester, 'Mansi ka number do');
      expect(backend.chatRequests.single['message'], 'Mansi ka number do');
      expect(find.text('98765 43210'), findsOneWidget);
    });

    testWidgets('voice: a spoken email request shows the confirmation', (tester) async {
      await startApp(tester);
      backend.chatResponder = (_) => emailTo('Mansi');
      await speak(tester, 'Mansi ko ye details email kar do');
      expect(find.widgetWithText(FilledButton, 'Confirm & Send'), findsOneWidget);
      expect(backend.sentEmails, isEmpty);
    });

    testWidgets('voice: a spoken WhatsApp request shows the confirmation', (tester) async {
      await startApp(tester);
      backend.chatResponder = (_) => whatsAppTo('Papa');
      await speak(tester, 'Papa ko WhatsApp karo');
      expect(find.widgetWithText(FilledButton, 'Continue to WhatsApp'), findsOneWidget);
      expect(handoff.calls, isEmpty);
    });

    testWidgets('logout clears pending actions and contact results; the next account sees none', (tester) async {
      await startApp(tester);
      backend.chatResponder = (message) => message.contains('number') ? lookup('Mansi', 'phone') : emailTo('Mansi');
      await send(tester, 'Mansi ka number do');
      expect(find.text('98765 43210'), findsOneWidget);
      await send(tester, 'Mansi ko email karo');
      expect(find.widgetWithText(FilledButton, 'Confirm & Send'), findsOneWidget);

      await logOut(tester);
      await logIn(tester, 'ravi@example.com');
      await openTab(tester, 'Chat');
      expect(find.text('98765 43210'), findsNothing);
      expect(find.text('Mansi Patro'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Confirm & Send'), findsNothing);
      expect(find.text('Hey! 👋'), findsOneWidget);
    });
  });
}
