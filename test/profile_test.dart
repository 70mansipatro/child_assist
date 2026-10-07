import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<FakeBackend> startApp(WidgetTester tester) async {
    final backend = FakeBackend();
    final services = backend.services(FakePermissionService());
    await services.authService.restoreSession();
    await tester.pumpWidget(MyApp(services: services));
    return backend;
  }

  testWidgets('view and edit profile name; the signed-in user follows', (tester) async {
    final backend = await startApp(tester);
    await logIn(tester, 'mansi@example.com');
    await openFromHome(tester, 'Profile');

    expect(find.text('Mansi'), findsOneWidget);
    expect(find.text('mansi@example.com'), findsOneWidget);
    expect(find.byIcon(Icons.person), findsOneWidget, reason: 'placeholder when no image');

    await tester.tap(find.text('Account'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), '  Mansi K  ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Mansi K'), findsOneWidget);
    expect(find.text('Profile saved'), findsOneWidget);
    expect(backend.users['u1']!['name'], 'Mansi K');

    final services = tester.widget<MyApp>(find.byType(MyApp)).services;
    expect(services.authService.currentUser?.name, 'Mansi K');
  });

  testWidgets('empty name is rejected before calling the server', (tester) async {
    final backend = await startApp(tester);
    await logIn(tester, 'mansi@example.com');
    await openFromHome(tester, 'Profile');

    await tester.tap(find.text('Account'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), '   ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Name is required'), findsOneWidget);
    expect(backend.patches, isEmpty);
  });

  testWidgets('an expired session on the profile screen returns to Login', (tester) async {
    final backend = await startApp(tester);
    await logIn(tester, 'mansi@example.com');
    backend.users.remove('u1'); // token no longer maps to an account -> 401
    await openFromHome(tester, 'Profile');

    expect(find.widgetWithText(FilledButton, 'Log in'), findsOneWidget);
    expect(find.text('Profile'), findsNothing);
  });

  testWidgets('each user sees only their own profile', (tester) async {
    await startApp(tester);
    await logIn(tester, 'mansi@example.com');
    await openFromHome(tester, 'Profile');
    expect(find.text('mansi@example.com'), findsOneWidget);
    await logOut(tester);

    await logIn(tester, 'ravi@example.com');
    await openFromHome(tester, 'Profile');
    expect(find.text('ravi@example.com'), findsOneWidget);
    expect(find.text('mansi@example.com'), findsNothing);
  });
}
