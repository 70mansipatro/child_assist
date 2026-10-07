import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/app_services.dart';
import 'package:child_assist/features/auth/data/token_storage.dart';
import 'package:child_assist/features/auth/services/auth_service.dart';
import 'package:child_assist/features/auth/services/google_auth_service.dart';
import 'package:child_assist/features/auth/widgets/auth_widgets.dart';
import 'package:child_assist/features/permissions/screens/permission_onboarding_screen.dart';
import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  late FakeBackend backend;
  late FakeGoogleAuthService google;
  late AppServices services;

  Future<void> startApp(WidgetTester tester, {bool googleAvailable = true}) async {
    backend = FakeBackend();
    google = FakeGoogleAuthService(isAvailable: googleAvailable);
    services = backend.services(FakePermissionService(), googleAuthService: google);
    await services.authService.restoreSession();
    await tester.pumpWidget(MyApp(services: services));
    await tester.pumpAndSettle();
  }

  Finder googleButton() => find.widgetWithText(OutlinedButton, 'Continue with Google');

  Future<void> tapGoogle(WidgetTester tester) async {
    await tester.ensureVisible(googleButton());
    await tester.pumpAndSettle();
    await tester.tap(googleButton());
    await tester.pumpAndSettle();
  }

  /// A Google account that already has a Child Assist account (set up and onboarded).
  String linkedGoogleUser({String name = 'Mansi Patro', String email = 'mansi.patro@gmail.com'}) {
    final id = backend.addUser(name, email, onboardingCompleted: true);
    backend.googleSubjects[id] = 'google-sub-$id';
    backend.passwordless.add(id);
    google.nextIdToken = backend.googleAccount(sub: 'google-sub-$id', email: email, name: name);
    return id;
  }

  testWidgets('1. Login shows "OR" and the Continue with Google button with the official mark', (tester) async {
    await startApp(tester);

    expect(find.text('Log in'), findsWidgets);
    expect(find.text('OR'), findsOneWidget);
    expect(googleButton(), findsOneWidget);
    expect(
      find.descendant(of: googleButton(), matching: find.byType(Image)),
      findsOneWidget,
      reason: 'the official G asset, not a drawn imitation',
    );
    expect(find.bySemanticsLabel('Continue with Google'), findsOneWidget);
  });

  testWidgets('Register also offers Continue with Google', (tester) async {
    await startApp(tester);
    await openRegister(tester);
    expect(find.text('Create account'), findsOneWidget);
    expect(googleButton(), findsOneWidget);
  });

  testWidgets('the button is hidden where Google sign-in is unavailable (e.g. web)', (tester) async {
    await startApp(tester, googleAvailable: false);
    expect(googleButton(), findsNothing);
    expect(find.text('OR'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Log in'), findsOneWidget);
  });

  testWidgets('2/3. cancelling the Google picker shows a calm message and creates no session', (tester) async {
    await startApp(tester);
    google.nextError = GoogleAuthException.cancelledByUser;

    await tapGoogle(tester);

    expect(google.signInCalls, 1);
    expect(find.text('Google sign-in was cancelled.'), findsOneWidget);
    expect(backend.googleTokens, isEmpty, reason: 'nothing is sent to the server');
    expect(services.authService.status, AuthStatus.unauthenticated);
    expect(await TokenStorage().read(), isNull);
    expect(dashboard(), findsNothing);
  });

  testWidgets('a Google configuration error shows a friendly message', (tester) async {
    await startApp(tester);
    google.nextError = GoogleAuthException.notConfigured;

    await tapGoogle(tester);

    expect(find.text('Google Sign-In is not configured correctly.\nPlease try again later.'), findsOneWidget);
    expect(await TokenStorage().read(), isNull);
  });

  testWidgets('4-8. Google login stores the Child Assist JWT and shows the account on Dashboard and Profile',
      (tester) async {
    await startApp(tester);
    final id = linkedGoogleUser();

    await tapGoogle(tester);

    // Only the Google ID token goes to the backend; the session is the backend's own JWT.
    expect(backend.googleTokens, ['google-id-token-google-sub-$id']);
    expect(await TokenStorage().read(), FakeBackend.tokenFor(id));
    expect(services.authService.currentUser?.name, 'Mansi Patro');

    expect(dashboard(), findsOneWidget);
    expect(greetingFor('Mansi Patro'), findsOneWidget);

    await openTab(tester, 'Profile');
    expect(find.text('Mansi Patro'), findsOneWidget);
    expect(find.text('mansi.patro@gmail.com'), findsOneWidget);
    expect(find.textContaining('google-sub'), findsNothing, reason: 'Google account IDs are never shown');
  });

  testWidgets('a new Google user gets an account and starts the permission walkthrough', (tester) async {
    await startApp(tester);
    google.nextIdToken = backend.googleAccount(sub: 'new-sub', email: 'new.user@gmail.com', name: 'New User');
    final before = backend.users.length;

    await tapGoogle(tester);

    expect(backend.users.length, before + 1);
    final id = backend.googleSubjects.entries.single.key;
    expect(backend.users[id]!['name'], 'New User');
    expect(await TokenStorage().read(), FakeBackend.tokenFor(id));
    expect(find.byType(PermissionOnboardingScreen), findsOneWidget);
  });

  testWidgets('9. logout clears the session and the app\'s Google sign-in, and returns to Login', (tester) async {
    await startApp(tester);
    linkedGoogleUser();
    await tapGoogle(tester);
    expect(dashboard(), findsOneWidget);

    await logOut(tester);

    expect(dashboard(), findsNothing);
    expect(googleButton(), findsOneWidget);
    expect(await TokenStorage().read(), isNull);
    expect(services.authService.currentUser, isNull);
    expect(google.signOutCalls, 1);
  });

  testWidgets('signing in with Google again uses the same Child Assist account', (tester) async {
    await startApp(tester);
    final id = linkedGoogleUser();
    await tapGoogle(tester);
    await logOut(tester);
    final usersBefore = backend.users.length;

    await tapGoogle(tester);

    expect(services.authService.currentUser?.id, id);
    expect(backend.users.length, usersBefore, reason: 'no duplicate account');
    expect(greetingFor('Mansi Patro'), findsOneWidget);
  });

  testWidgets('an email that belongs to a password account is not merged', (tester) async {
    await startApp(tester);
    // mansi@example.com (u1) is an existing password account.
    google.nextIdToken = backend.googleAccount(sub: 'other-sub', email: 'mansi@example.com', name: 'Someone');

    await tapGoogle(tester);

    expect(find.textContaining('An account already exists with this email.'), findsOneWidget);
    expect(await TokenStorage().read(), isNull);
    expect(services.authService.status, AuthStatus.unauthenticated);
    expect(backend.googleSubjects, isEmpty);
    expect(backend.users['u1']!['name'], 'Mansi');
    expect(google.signOutCalls, 1, reason: 'so the user can pick another Google account');
  });

  testWidgets('10. email/password login still works next to Google', (tester) async {
    await startApp(tester);

    await logIn(tester, 'mansi@example.com');

    expect(dashboard(), findsOneWidget);
    expect(greetingFor('Mansi'), findsOneWidget);
    expect(await TokenStorage().read(), FakeBackend.tokenFor('u1'));
    expect(google.signInCalls, 0);
  });

  testWidgets('password login on a Google-only account says to continue with Google', (tester) async {
    await startApp(tester);
    linkedGoogleUser(email: 'google.only@gmail.com');

    await logIn(tester, 'google.only@gmail.com');

    expect(find.text('This account uses Google Sign-In. Please continue with Google.'), findsOneWidget);
    expect(await TokenStorage().read(), isNull);
  });

  testWidgets('the button shows progress and blocks the password form while signing in', (tester) async {
    await startApp(tester);
    final id = linkedGoogleUser();
    google.pending = Completer<void>();

    await tester.ensureVisible(googleButton());
    await tester.tap(googleButton());
    await tester.pump();

    expect(tester.widget<GoogleSignInButton>(find.byType(GoogleSignInButton)).busy, isTrue);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Log in')).onPressed, isNull);

    google.pending!.complete();
    await tester.pumpAndSettle();
    expect(services.authService.currentUser?.id, id);
  });
}
