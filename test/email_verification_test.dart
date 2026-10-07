import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/app_services.dart';
import 'package:child_assist/core/widgets/widgets.dart';
import 'package:child_assist/features/auth/data/token_storage.dart';
import 'package:child_assist/features/auth/screens/login_screen.dart';
import 'package:child_assist/features/auth/screens/register_screen.dart';
import 'package:child_assist/features/auth/screens/verify_email_screen.dart';
import 'package:child_assist/features/auth/services/auth_service.dart';
import 'package:child_assist/features/permissions/screens/permission_onboarding_screen.dart';
import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  late FakeBackend backend;
  late FakeGoogleAuthService google;
  late AppServices services;

  const email = 'new.kid@example.com';

  Future<void> startApp(WidgetTester tester) async {
    backend = FakeBackend();
    google = FakeGoogleAuthService();
    services = backend.services(FakePermissionService(), googleAuthService: google);
    await services.authService.restoreSession();
    await tester.pumpWidget(MyApp(services: services));
    await tester.pumpAndSettle();
  }

  Finder verifyScreen() => find.byType(VerifyEmailScreen);
  Finder verifyButton() => find.widgetWithText(FilledButton, 'Verify Email');
  Finder resendButton() => find.byKey(const ValueKey('resend-code'));
  TextField codeField(WidgetTester tester) => tester.widget<TextField>(find.byKey(const ValueKey('otp-input')));
  bool enabled(WidgetTester tester, Finder button) => tester.widget<ButtonStyleButton>(button).onPressed != null;

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text));
    await tester.pumpAndSettle();
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  Future<void> tapResend(WidgetTester tester) async {
    await tester.ensureVisible(resendButton());
    await tester.pumpAndSettle();
    await tester.tap(resendButton());
    await tester.pumpAndSettle();
  }

  testWidgets('1. Register opens Verify Email for that address, without signing in', (tester) async {
    await startApp(tester);
    await submitRegistration(tester, 'New Kid', email);

    expect(verifyScreen(), findsOneWidget);
    expect(find.text('Verify Email'), findsWidgets);
    expect(find.text('We sent a 6-digit code to'), findsOneWidget);
    expect(find.byKey(const ValueKey('verify-email-address')), findsOneWidget);
    expect(find.text(email), findsOneWidget);
    expect(find.text('Code expires in 10:00'), findsOneWidget);
    expect(find.text('Change email'), findsOneWidget);

    expect(backend.codeEmails, [email]);
    expect(services.authService.status, AuthStatus.unauthenticated);
    expect(await TokenStorage().read(), isNull);
  });

  testWidgets('2. the code field takes six digits only, and Verify waits for all six', (tester) async {
    await startApp(tester);
    await submitRegistration(tester, 'New Kid', email);

    expect(enabled(tester, verifyButton()), isFalse);
    await tester.enterText(find.byKey(const ValueKey('otp-input')), '12a-3');
    await tester.pump();
    expect(codeField(tester).controller!.text, '123');
    expect(find.text('1'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(enabled(tester, verifyButton()), isFalse);
    expect(backend.verifyRequests, isEmpty);

    // Pasting a longer value keeps the first six digits, which submits automatically.
    final code = backend.inbox[email]!;
    await enterCode(tester, '$code 99');
    expect(backend.verifyRequests.single, {'email': email, 'code': code});
  });

  testWidgets('3, 8. the right code verifies, returns to Login with the email filled in, then login works',
      (tester) async {
    await startApp(tester);
    await submitRegistration(tester, 'New Kid', email);

    await enterCode(tester, backend.inbox[email]!);

    expect(verifyScreen(), findsNothing);
    expect(find.byType(RegisterScreen), findsNothing);
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('Email verified successfully. Log in to continue.'), findsOneWidget);
    expect(tester.widget<TextFormField>(find.byType(TextFormField).at(0)).controller!.text, email);
    expect(await TokenStorage().read(), isNull, reason: 'verifying does not sign in');

    await tester.enterText(find.byType(TextFormField).at(1), testPassword);
    await tester.tap(find.widgetWithText(FilledButton, 'Log in'));
    await tester.pumpAndSettle();

    final id = backend.users.values.firstWhere((u) => u['email'] == email)['id'] as String;
    expect(await TokenStorage().read(), FakeBackend.tokenFor(id));
    expect(find.byType(PermissionOnboardingScreen), findsOneWidget);
  });

  testWidgets('4. a wrong code shows the error, clears the boxes, and the right code still works', (tester) async {
    await startApp(tester);
    await submitRegistration(tester, 'New Kid', email);
    final code = backend.inbox[email]!;

    await enterCode(tester, code == '000000' ? '111111' : '000000');

    expect(verifyScreen(), findsOneWidget);
    expect(find.text(FakeBackend.invalidCode), findsOneWidget);
    expect(codeField(tester).controller!.text, isEmpty);

    // Typing again clears the error.
    await tester.enterText(find.byKey(const ValueKey('otp-input')), code.substring(0, 1));
    await tester.pump();
    expect(find.text(FakeBackend.invalidCode), findsNothing);

    await enterCode(tester, code);
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('5. an expired code: the server error is shown, and the countdown ends in "expired"', (tester) async {
    await startApp(tester);
    await submitRegistration(tester, 'New Kid', email);
    final code = backend.inbox[email]!;
    backend.expiredCodes.add(code);

    await enterCode(tester, code);
    expect(find.text(FakeBackend.invalidCode), findsOneWidget);

    await tester.pump(const Duration(minutes: 9, seconds: 50));
    expect(find.textContaining(RegExp(r'^Code expires in 00:0\d$')), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(find.text('This code has expired. Request a new code.'), findsOneWidget);
    expect(enabled(tester, verifyButton()), isFalse);
    expect(codeField(tester).enabled, isFalse);
    expect(tester.widget<TextButton>(resendButton()).onPressed, isNotNull);
  });

  testWidgets('6. Resend is disabled for 60 s, sends only the email, and restarts both countdowns', (tester) async {
    await startApp(tester);
    await submitRegistration(tester, 'New Kid', email);
    final firstCode = backend.inbox[email]!;

    expect(find.text('Resend code in 01:00'), findsOneWidget);
    expect(tester.widget<TextButton>(resendButton()).onPressed, isNull);
    await tester.pump(const Duration(seconds: 25));
    expect(find.text('Resend code in 00:35'), findsOneWidget);
    expect(find.text('Code expires in 09:35'), findsOneWidget);
    await tester.pump(const Duration(seconds: 35));
    expect(find.text('Resend Code'), findsOneWidget);

    await tapResend(tester);

    expect(backend.resendRequests.single, {'email': email});
    expect(find.text('If verification is required, a new code has been sent.'), findsOneWidget);
    expect(find.text('Resend code in 01:00'), findsOneWidget);
    expect(find.text('Code expires in 10:00'), findsOneWidget);
    expect(tester.widget<TextButton>(resendButton()).onPressed, isNull);

    final newCode = backend.inbox[email]!;
    expect(newCode, isNot(firstCode));
    await enterCode(tester, firstCode);
    expect(find.text(FakeBackend.invalidCode), findsOneWidget);
    await enterCode(tester, newCode);
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('7. login on an unverified account opens Verify Email, with no session', (tester) async {
    await startApp(tester);
    final id = backend.addUser('Late Verifier', 'late@example.com');
    backend.unverified.add(id);

    await logIn(tester, 'late@example.com');

    expect(verifyScreen(), findsOneWidget);
    expect(find.text('late@example.com'), findsOneWidget);
    expect(
      find.text('Please verify your email before logging in. Enter the latest code we emailed you.'),
      findsOneWidget,
    );
    expect(await TokenStorage().read(), isNull);
    expect(services.authService.status, AuthStatus.unauthenticated);

    await enterCode(tester, backend.inbox['late@example.com']!);
    expect(find.text('Email verified successfully. Log in to continue.'), findsOneWidget);
    // The password is still filled in, so one tap logs in.
    await tester.tap(find.widgetWithText(FilledButton, 'Log in'));
    await tester.pumpAndSettle();
    expect(await TokenStorage().read(), FakeBackend.tokenFor(id));
  });

  testWidgets('"Change email" returns to Register with the form as it was, and nothing is verified',
      (tester) async {
    await startApp(tester);
    await submitRegistration(tester, 'New Kid', email);

    await tapText(tester, 'Change email');

    expect(verifyScreen(), findsNothing);
    expect(find.byType(RegisterScreen), findsOneWidget);
    expect(tester.widget<TextFormField>(find.byType(TextFormField).at(1)).controller!.text, email);
    expect(backend.verifyRequests, isEmpty);

    // Back once more is Login.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('9. Continue with Google signs in directly, with no verification step', (tester) async {
    await startApp(tester);
    google.nextIdToken = backend.googleAccount(sub: 'g-1', email: 'kid@gmail.com', name: 'Google Kid');

    await tester.ensureVisible(find.widgetWithText(OutlinedButton, 'Continue with Google'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Continue with Google'));
    await tester.pumpAndSettle();

    expect(verifyScreen(), findsNothing);
    expect(backend.codeEmails, isEmpty);
    expect(services.authService.status, AuthStatus.authenticated);
    expect(find.byType(PermissionOnboardingScreen), findsOneWidget);
  });

  testWidgets('10. Verify shows a spinner and blocks double taps while checking', (tester) async {
    await startApp(tester);
    await submitRegistration(tester, 'New Kid', email);
    final pending = backend.verifyPending = Completer<void>();

    await tester.enterText(find.byKey(const ValueKey('otp-input')), backend.inbox[email]!);
    await tester.pump();

    final busyButton = find.ancestor(of: find.byType(ButtonSpinner), matching: find.byType(FilledButton));
    expect(busyButton, findsOneWidget);
    expect(enabled(tester, busyButton), isFalse);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Change email')).onPressed, isNull);
    expect(codeField(tester).enabled, isFalse);

    pending.complete();
    await tester.pumpAndSettle();
    expect(backend.verifyRequests, hasLength(1));
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('11. network failures show a message and leave the user where they were', (tester) async {
    await startApp(tester);
    await submitRegistration(tester, 'New Kid', email);
    final code = backend.inbox[email]!;

    backend.offline = true;
    await enterCode(tester, code);
    expect(verifyScreen(), findsOneWidget);
    expect(find.text('Could not reach the server. Check your connection.'), findsOneWidget);

    await tester.pump(const Duration(seconds: 60));
    await tapResend(tester);
    expect(find.text('Could not reach the server. Check your connection.'), findsOneWidget);
    expect(find.text('Resend Code'), findsOneWidget, reason: 'a failed resend does not start the cooldown');

    backend.offline = false;
    await enterCode(tester, code);
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('registration failing offline stays on Register with the error', (tester) async {
    await startApp(tester);
    backend.offline = true;
    await submitRegistration(tester, 'New Kid', email);
    expect(verifyScreen(), findsNothing);
    expect(find.byType(RegisterScreen), findsOneWidget);
    expect(find.text('Could not reach the server. Check your connection.'), findsOneWidget);
  });

  testWidgets('12. no code ever reaches debug output or is shown as a whole', (tester) async {
    final logs = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => logs.add(message ?? '');
    try {
      await startApp(tester);
      await submitRegistration(tester, 'New Kid', email);
      final wrongCode = backend.inbox[email] == '000000' ? '111111' : '000000';
      await enterCode(tester, wrongCode);
      await tester.pump(const Duration(seconds: 60));
      await tapResend(tester);
      final code = backend.inbox[email]!;
      await tester.enterText(find.byKey(const ValueKey('otp-input')), code);
      await tester.pump();
      expect(
        find.byWidgetPredicate((w) => w is Text && (w.data?.contains(code) ?? false)),
        findsNothing,
        reason: 'only single digits are drawn, in the boxes',
      );
      await tester.pumpAndSettle();

      for (final c in [wrongCode, code, ...backend.inbox.values]) {
        expect(logs.where((l) => l.contains(c)), isEmpty);
      }
    } finally {
      debugPrint = originalDebugPrint;
    }
  });
}
