import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/features/home/dashboard_screen.dart';
import 'package:child_assist/features/profile/screens/profile_screen.dart';
import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  late FakeBackend backend;

  Future<void> startApp(WidgetTester tester) async {
    backend = FakeBackend();
    final services = backend.services(FakePermissionService());
    await services.authService.restoreSession();
    await tester.pumpWidget(MyApp(services: services));
    await tester.pumpAndSettle();
  }

  test('greeting follows the device clock', () {
    String at(int hour) => DashboardScreen.timeOfDayGreeting(DateTime(2026, 10, 7, hour, 30));
    expect(at(5), 'Good morning');
    expect(at(11), 'Good morning');
    expect(at(12), 'Good afternoon');
    expect(at(17), 'Good afternoon');
    expect(at(18), 'Good evening');
    expect(at(23), 'Good evening');
    expect(at(0), 'Good evening');
    expect(at(4), 'Good evening');
  });

  testWidgets('Dashboard greets the signed-in user by their registered name', (tester) async {
    await startApp(tester);
    await logIn(tester, 'mansi@example.com');

    expect(timeOfDayLine(), findsOneWidget);
    expect(greetingFor('Mansi'), findsOneWidget);
    expect(find.text('Welcome back! How can I help you today?'), findsOneWidget);
    expect(find.byTooltip('Your profile'), findsOneWidget, reason: 'avatar with initials');
    expect(find.text('M'), findsOneWidget);

    await tester.tap(find.byTooltip('Your profile'));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileScreen), findsOneWidget);
  });

  testWidgets('a new registration is greeted by the name it registered with', (tester) async {
    await startApp(tester);
    await tester.tap(find.text("Don't have an account? Register"));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'Rahul');
    await tester.enterText(find.byType(TextFormField).at(1), 'rahul@example.com');
    await tester.enterText(find.byType(TextFormField).at(2), testPassword);
    await tester.tap(find.widgetWithText(FilledButton, 'Register'));
    await tester.pumpAndSettle();

    // New accounts go through the permission walkthrough first; mark it done on the server.
    final id = backend.users.values.firstWhere((u) => u['email'] == 'rahul@example.com')['id'] as String;
    backend.users[id]!['permissionOnboardingCompleted'] = true;
    final services = tester.widget<MyApp>(find.byType(MyApp)).services;
    await services.permissionOnboardingService.refresh();
    await tester.pumpAndSettle();

    expect(greetingFor('Rahul'), findsOneWidget);
  });

  testWidgets('saving a new name in Profile updates the Dashboard immediately', (tester) async {
    await startApp(tester);
    await logIn(tester, 'mansi@example.com');

    await openTab(tester, 'Profile');
    expect(find.text('Mansi'), findsOneWidget);
    expect(find.text('mansi@example.com'), findsOneWidget);
    await tester.tap(find.text('Account'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'Mansi Patro');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Mansi Patro'), findsOneWidget);
    expect(backend.users['u1']!['name'], 'Mansi Patro');

    await openTab(tester, 'Dashboard');
    expect(greetingFor('Mansi Patro'), findsOneWidget);
    expect(greetingFor('Mansi'), findsNothing);
  });

  testWidgets('a name changed on the server is picked up from GET /api/profile', (tester) async {
    await startApp(tester);
    await logIn(tester, 'mansi@example.com');
    backend.users['u1']!['name'] = 'Mansi From Server';

    // Opening Profile loads GET /api/profile, which refreshes the shared signed-in user.
    await openTab(tester, 'Profile');
    await openTab(tester, 'Dashboard');
    expect(greetingFor('Mansi From Server'), findsOneWidget);
  });

  testWidgets('after logout the previous name is gone and the next account sees only theirs', (tester) async {
    await startApp(tester);
    await logIn(tester, 'mansi@example.com');
    expect(greetingFor('Mansi'), findsOneWidget);

    await logOut(tester);
    expect(find.textContaining('Mansi'), findsNothing);

    await logIn(tester, 'ravi@example.com');
    expect(greetingFor('Ravi'), findsOneWidget);
    expect(find.textContaining('Mansi'), findsNothing);
  });

  testWidgets('an account without a name gets a friendly fallback, never "null"', (tester) async {
    await startApp(tester);
    backend.addUser('', 'noname@example.com', onboardingCompleted: true);
    await logIn(tester, 'noname@example.com');

    expect(timeOfDayLine(), findsOneWidget);
    expect(find.descendant(of: dashboard(), matching: find.text('Welcome back')), findsOneWidget);
    expect(find.text('How can I help you today?'), findsOneWidget);
    expect(find.textContaining('null'), findsNothing);
    expect(find.textContaining('undefined'), findsNothing);
    expect(find.textContaining(RegExp(r'^Good (morning|afternoon|evening),')), findsNothing);
  });
}
