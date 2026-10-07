import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/app_services.dart';
import 'package:child_assist/features/auth/data/token_storage.dart';
import 'package:child_assist/features/auth/screens/forgot_password_screen.dart';
import 'package:child_assist/features/auth/screens/login_screen.dart';
import 'package:child_assist/features/auth/screens/reset_password_screen.dart';
import 'package:child_assist/features/auth/screens/verify_reset_code_screen.dart';
import 'package:child_assist/features/auth/services/auth_service.dart';
import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  late FakeBackend backend;
  late AppServices services;

  const email = 'mansi@example.com'; // u1 in the fake backend, a password account.
  const newPassword = 'brand-new-pass';

  Future<void> startApp(WidgetTester tester) async {
    backend = FakeBackend();
    services = backend.services(FakePermissionService(), googleAuthService: FakeGoogleAuthService());
    await services.authService.restoreSession();
    await tester.pumpWidget(MyApp(services: services));
    await tester.pumpAndSettle();
  }

  Finder forgotScreen() => find.byType(ForgotPasswordScreen);
  Finder verifyScreen() => find.byType(VerifyResetCodeScreen);
  Finder resetScreen() => find.byType(ResetPasswordScreen);
  Finder button(String label) => find.widgetWithText(FilledButton, label);
  Finder resendButton() => find.byKey(const ValueKey('resend-reset-code'));
  bool enabled(WidgetTester tester, Finder b) => tester.widget<ButtonStyleButton>(b).onPressed != null;
  String fieldText(WidgetTester tester, int index) =>
      tester.widget<TextFormField>(find.byType(TextFormField).at(index)).controller!.text;

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> openForgot(WidgetTester tester) => tap(tester, find.byKey(const ValueKey('forgot-password')));

  Future<void> sendCode(WidgetTester tester, String address) async {
    await tester.enterText(find.byType(TextFormField).first, address);
    await tap(tester, button('Send Code'));
  }

  Future<void> enterCode(WidgetTester tester, String code) async {
    await tester.enterText(find.byKey(const ValueKey('otp-input')), code);
    await tester.pumpAndSettle();
  }

  /// Login -> Forgot Password -> code. Leaves the app on Create New Password.
  Future<void> reachResetScreen(WidgetTester tester) async {
    await openForgot(tester);
    await sendCode(tester, email);
    await enterCode(tester, backend.resetInbox[email]!);
    expect(resetScreen(), findsOneWidget);
  }

  Future<void> submitNewPassword(WidgetTester tester, String password, [String? confirm]) async {
    await tester.enterText(find.byType(TextFormField).at(0), password);
    await tester.enterText(find.byType(TextFormField).at(1), confirm ?? password);
    await tap(tester, button('Reset Password'));
  }

  testWidgets('Login shows "Forgot Password?" between the password and Log in, and it opens Forgot Password',
      (tester) async {
    await startApp(tester);
    final link = find.byKey(const ValueKey('forgot-password'));
    expect(find.descendant(of: link, matching: find.text('Forgot Password?')), findsOneWidget);
    final linkY = tester.getCenter(link).dy;
    expect(tester.getCenter(find.byType(TextFormField).at(1)).dy, lessThan(linkY));
    expect(tester.getCenter(button('Log in')).dy, greaterThan(linkY));
    expect(find.text('Continue with Google'), findsOneWidget);

    // Whatever was typed into Login is carried over.
    await tester.enterText(find.byType(TextFormField).at(0), email);
    await openForgot(tester);

    expect(forgotScreen(), findsOneWidget);
    expect(find.text('Forgot Password?'), findsOneWidget);
    expect(find.text('Enter the email address associated with your Child Assist account.'), findsOneWidget);
    expect(fieldText(tester, 0), email);
    expect(button('Send Code'), findsOneWidget);

    await tap(tester, find.text('Back to Login'));
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(backend.forgotRequests, isEmpty);
  });

  testWidgets('Forgot Password validates the email before sending anything', (tester) async {
    await startApp(tester);
    await openForgot(tester);

    await tap(tester, button('Send Code'));
    expect(find.text('Please enter your email'), findsOneWidget);

    await sendCode(tester, 'not-an-email');
    expect(find.text('Please enter a valid email'), findsOneWidget);
    expect(backend.forgotRequests, isEmpty);
    expect(verifyScreen(), findsNothing);
  });

  testWidgets('Send Code sends only the email and opens Verify Reset Code with the generic message',
      (tester) async {
    await startApp(tester);
    await openForgot(tester);
    await sendCode(tester, '  Mansi@Example.com ');

    expect(backend.forgotRequests.single, {'email': email});
    expect(backend.resetCodeEmails, [email]);
    expect(verifyScreen(), findsOneWidget);
    expect(find.text('Verify Reset Code'), findsOneWidget);
    expect(find.text('We sent a 6-digit code to your email.'), findsOneWidget);
    expect(find.text(ForgotPasswordScreen.sentNotice), findsOneWidget);
    expect(find.text('Code expires in 10:00'), findsOneWidget);
    expect(find.text('Change Email'), findsOneWidget);
    expect(services.authService.status, AuthStatus.unauthenticated);
  });

  testWidgets('an unknown email gets exactly the same screens, and no code', (tester) async {
    await startApp(tester);
    await openForgot(tester);
    await sendCode(tester, 'nobody@example.com');

    expect(verifyScreen(), findsOneWidget);
    expect(find.text(ForgotPasswordScreen.sentNotice), findsOneWidget);
    expect(backend.resetCodeEmails, isEmpty);
  });

  testWidgets('Verify takes six digits only, waits for all six, and the right code opens Create New Password',
      (tester) async {
    await startApp(tester);
    await openForgot(tester);
    await sendCode(tester, email);

    expect(enabled(tester, button('Verify Code')), isFalse);
    await tester.enterText(find.byKey(const ValueKey('otp-input')), '12a-3');
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('otp-input'))).controller!.text, '123');
    expect(enabled(tester, button('Verify Code')), isFalse);
    expect(backend.verifyResetRequests, isEmpty);

    final code = backend.resetInbox[email]!;
    await enterCode(tester, code);
    expect(backend.verifyResetRequests.single, {'email': email, 'code': code});
    expect(resetScreen(), findsOneWidget);
    expect(find.text('Create New Password'), findsOneWidget);
    expect(await TokenStorage().read(), isNull, reason: 'verifying a code never signs in');
  });

  testWidgets('a wrong code shows a friendly error, clears the boxes, and the right code still works',
      (tester) async {
    await startApp(tester);
    await openForgot(tester);
    await sendCode(tester, email);
    final code = backend.resetInbox[email]!;

    await enterCode(tester, code == '000000' ? '111111' : '000000');
    expect(verifyScreen(), findsOneWidget);
    expect(find.text(FakeBackend.invalidResetCode), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('otp-input'))).controller!.text, isEmpty);

    await enterCode(tester, code);
    expect(resetScreen(), findsOneWidget);
  });

  testWidgets('an expired code: the server error is shown, and the countdown ends in "expired"', (tester) async {
    await startApp(tester);
    await openForgot(tester);
    await sendCode(tester, email);
    final code = backend.resetInbox[email]!;
    backend.expiredResetCodes.add(code);

    await enterCode(tester, code);
    expect(find.text(FakeBackend.invalidResetCode), findsOneWidget);
    expect(resetScreen(), findsNothing);

    await tester.pump(VerifyResetCodeScreen.codeLifetime);
    await tester.pumpAndSettle();
    expect(find.text('This code has expired. Request a new code.'), findsOneWidget);
    expect(enabled(tester, button('Verify Code')), isFalse);
  });

  testWidgets('Resend counts down 60 seconds, then sends one new code and restarts the countdown',
      (tester) async {
    await startApp(tester);
    await openForgot(tester);
    await sendCode(tester, email);
    final first = backend.resetInbox[email]!;

    expect(find.text('Resend code in 01:00'), findsOneWidget);
    expect(tester.widget<TextButton>(resendButton()).onPressed, isNull);
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('Resend code in 00:30'), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(find.text('Resend Code'), findsOneWidget);

    await tap(tester, resendButton());
    expect(backend.resendResetRequests.single, {'email': email});
    expect(backend.resetInbox[email], isNot(first));
    expect(find.text(FakeBackend.resetRequested), findsOneWidget);
    expect(find.text('Resend code in 01:00'), findsOneWidget);

    // Tapping during the countdown does nothing.
    await tester.tap(resendButton(), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(backend.resendResetRequests, hasLength(1));
  });

  testWidgets('Change Email returns to Forgot Password with the email kept', (tester) async {
    await startApp(tester);
    await openForgot(tester);
    await sendCode(tester, email);

    await tap(tester, find.text('Change Email'));
    expect(verifyScreen(), findsNothing);
    expect(forgotScreen(), findsOneWidget);
    expect(fieldText(tester, 0), email);
  });

  testWidgets('Create New Password uses the Register rules and needs a matching confirmation', (tester) async {
    await startApp(tester);
    await reachResetScreen(tester);

    await submitNewPassword(tester, 'short');
    expect(find.text('Password must be at least 8 characters'), findsOneWidget);

    await submitNewPassword(tester, newPassword, '$newPassword-typo');
    expect(find.text('Passwords do not match'), findsOneWidget);

    await submitNewPassword(tester, newPassword, '');
    expect(find.text('Please confirm your new password'), findsOneWidget);

    expect(backend.resetPasswordRequests, isEmpty);
    expect(resetScreen(), findsOneWidget);
  });

  testWidgets('a successful reset returns to Login, signed out, and only the new password works', (tester) async {
    await startApp(tester);
    await reachResetScreen(tester);
    await submitNewPassword(tester, newPassword);

    expect(backend.resetPasswordRequests.single, {
      'resetToken': 'reset-token-1',
      'newPassword': newPassword,
      'confirmPassword': newPassword,
    });
    expect(resetScreen(), findsNothing);
    expect(verifyScreen(), findsNothing);
    expect(forgotScreen(), findsNothing);
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('Password reset successfully. Please log in with your new password.'), findsOneWidget);
    expect(fieldText(tester, 0), email);
    expect(fieldText(tester, 1), isEmpty);
    expect(services.authService.status, AuthStatus.unauthenticated);
    expect(await TokenStorage().read(), isNull, reason: 'a reset never signs in');

    // The old password is refused...
    await logIn(tester, email);
    expect(find.text('Invalid email or password'), findsOneWidget);
    expect(services.authService.status, AuthStatus.unauthenticated);

    // ...the new one works.
    await tester.enterText(find.byType(TextFormField).at(1), newPassword);
    await tap(tester, button('Log in'));
    expect(services.authService.status, AuthStatus.authenticated);
    expect(await TokenStorage().read(), FakeBackend.tokenFor('u1'));
  });

  testWidgets('going back from Create New Password keeps the verified code; an expired session asks for a new one',
      (tester) async {
    await startApp(tester);
    await reachResetScreen(tester);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(verifyScreen(), findsOneWidget);
    await tap(tester, button('Create New Password'));
    expect(resetScreen(), findsOneWidget);
    expect(backend.verifyResetRequests, hasLength(1), reason: 'no second code was needed');

    backend.resetTokensExpired = true;
    await submitNewPassword(tester, newPassword);
    expect(find.text(FakeBackend.invalidResetToken), findsOneWidget);

    await tap(tester, button('Request a New Code'));
    expect(verifyScreen(), findsOneWidget);
    expect(find.text('Your reset session has expired. Request a new code to continue.'), findsOneWidget);
    expect(button('Verify Code'), findsOneWidget);
  });

  testWidgets('a Google-only account: no code, a hint to use Google, and Login says to continue with Google',
      (tester) async {
    await startApp(tester);
    final id = backend.addUser('Gia', 'gia@example.com', onboardingCompleted: true);
    backend.passwordless.add(id);

    await openForgot(tester);
    await sendCode(tester, 'gia@example.com');
    // The same screens as for any email: nothing reveals the account type...
    expect(verifyScreen(), findsOneWidget);
    expect(find.text(ForgotPasswordScreen.sentNotice), findsOneWidget);
    expect(backend.resetCodeEmails, isEmpty);
    // ...but the screen always explains what Google users should do.
    expect(
      find.textContaining('Signed up with Google? Your account has no password to reset.'),
      findsOneWidget,
    );

    await tap(tester, find.text('Change Email'));
    await tap(tester, find.text('Back to Login'));
    await logIn(tester, 'gia@example.com');
    expect(find.text('This account uses Google Sign-In. Please continue with Google.'), findsOneWidget);
    expect(backend.passwords, isEmpty, reason: 'no password was ever set');
  });

  testWidgets('loading and error states: buttons lock while waiting, and network errors are shown',
      (tester) async {
    await startApp(tester);
    await openForgot(tester);

    backend.offline = true;
    await sendCode(tester, email);
    expect(find.text('Could not reach the server. Check your connection.'), findsOneWidget);
    expect(forgotScreen(), findsOneWidget);
    backend.offline = false;

    await sendCode(tester, email);
    final pending = backend.verifyResetPending = Completer<void>();
    await tester.enterText(find.byKey(const ValueKey('otp-input')), backend.resetInbox[email]!);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(enabled(tester, find.byType(FilledButton).first), isFalse);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Change Email')).onPressed, isNull);

    pending.complete();
    await tester.pumpAndSettle();
    expect(resetScreen(), findsOneWidget);
  });
}

