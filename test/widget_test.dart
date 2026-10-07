import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/features/auth/data/token_storage.dart';
import 'package:child_assist/features/auth/services/auth_service.dart';
import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('login -> home -> logout flow', (tester) async {
    final services = FakeBackend().services(FakePermissionService());
    await services.authService.restoreSession();
    await tester.pumpWidget(MyApp(services: services));

    expect(find.text('Log in'), findsWidgets);

    await tester.enterText(find.byType(TextFormField).at(0), 'mansi@example.com');
    await tester.enterText(find.byType(TextFormField).at(1), testPassword);
    await tester.tap(find.widgetWithText(FilledButton, 'Log in'));
    await tester.pumpAndSettle();

    expect(dashboard(), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);
    expect(find.text('Permissions'), findsOneWidget);
    expect(await TokenStorage().read(), FakeBackend.tokenFor('u1'));

    await logOut(tester);

    expect(dashboard(), findsNothing);
    expect(await TokenStorage().read(), isNull);
  });

  testWidgets('wrong password shows generic error', (tester) async {
    final services = FakeBackend().services(FakePermissionService());
    await services.authService.restoreSession();
    await tester.pumpWidget(MyApp(services: services));

    await tester.enterText(find.byType(TextFormField).at(0), 'mansi@example.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'nope');
    await tester.tap(find.widgetWithText(FilledButton, 'Log in'));
    await tester.pumpAndSettle();

    expect(find.text('Invalid email or password'), findsOneWidget);
    expect(await TokenStorage().read(), isNull);
  });

  test('restoreSession uses stored token, discards invalid one', () async {
    FlutterSecureStorage.setMockInitialValues({'auth_token': FakeBackend.tokenFor('u1')});
    final ok = FakeBackend().services(FakePermissionService()).authService;
    await ok.restoreSession();
    expect(ok.status, AuthStatus.authenticated);
    expect(ok.currentUser?.name, 'Mansi');

    FlutterSecureStorage.setMockInitialValues({'auth_token': 'expired'});
    final bad = FakeBackend().services(FakePermissionService()).authService;
    await bad.restoreSession();
    expect(bad.status, AuthStatus.unauthenticated);
    expect(await TokenStorage().read(), isNull);
  });
}
