import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/features/auth/screens/login_screen.dart';
import 'package:child_assist/features/auth/screens/verify_email_screen.dart';

import 'fakes.dart';

/// Fills in and submits the Login screen.
Future<void> logIn(WidgetTester tester, String email) async {
  await tester.enterText(find.byType(TextFormField).at(0), email);
  await tester.enterText(find.byType(TextFormField).at(1), testPassword);
  await tester.tap(find.widgetWithText(FilledButton, 'Log in'));
  await tester.pumpAndSettle();
}

/// Opens Register from Login and submits the form. Leaves the app on Verify Email.
Future<void> submitRegistration(WidgetTester tester, String name, String email) async {
  await tester.tap(find.text("Don't have an account? Register"));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextFormField).at(0), name);
  await tester.enterText(find.byType(TextFormField).at(1), email);
  await tester.enterText(find.byType(TextFormField).at(2), testPassword);
  await tester.tap(find.widgetWithText(FilledButton, 'Register'));
  await tester.pumpAndSettle();
}

/// Types a code into the Verify Email screen; six digits submit it automatically.
Future<void> enterCode(WidgetTester tester, String code) async {
  await tester.enterText(find.byKey(const ValueKey('otp-input')), code);
  await tester.pumpAndSettle();
}

/// The whole new-account flow: Register, enter the emailed code, back on Login with the email
/// filled in, then log in.
Future<void> registerVerifyAndLogIn(WidgetTester tester, FakeBackend backend, String name, String email) async {
  await submitRegistration(tester, name, email);
  expect(find.byType(VerifyEmailScreen), findsOneWidget);
  await enterCode(tester, backend.inbox[email]!);
  expect(find.byType(LoginScreen), findsOneWidget);
  await tester.enterText(find.byType(TextFormField).at(1), testPassword);
  await tester.tap(find.widgetWithText(FilledButton, 'Log in'));
  await tester.pumpAndSettle();
}

/// The Dashboard greeting; present only while the Dashboard tab is showing.
Finder dashboard() => find.byKey(const ValueKey('dashboard-greeting'));

/// The user's name as shown in the Dashboard greeting.
Finder greetingFor(String name) => find.descendant(of: dashboard(), matching: find.text(name));

/// The Dashboard's small "Good morning/afternoon/evening 👋" line.
Finder timeOfDayLine() => find.textContaining(RegExp(r'^Good (morning|afternoon|evening) 👋$'));

/// Switches to a bottom-navigation tab: Dashboard, Chat, Location or Profile.
Future<void> openTab(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
  await tester.pumpAndSettle();
}

/// Logs out from the Profile tab.
Future<void> logOut(WidgetTester tester) async {
  await openTab(tester, 'Profile');
  await tapVisible(tester, find.text('Logout'));
}

/// Opens a Dashboard feature card (Photos, Documents, Permissions, Notifications), or switches
/// to the tab when [label] names one.
Future<void> openFromHome(WidgetTester tester, String label) async {
  if (const ['Dashboard', 'Chat', 'Location', 'Profile'].contains(label)) return openTab(tester, label);
  await openTab(tester, 'Dashboard');
  await tapVisible(tester, find.text(label));
}

/// Scrolls [finder] into view (building lazily-built list items if needed) and taps it.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 100, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}
