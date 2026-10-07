import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/features/profile/services/profile_photo_service.dart';
import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

/// A valid 1x1 PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  late FakeProfilePhotoPlatform photos;

  Future<void> startApp(WidgetTester tester, {FakeProfilePhotoPlatform? platform}) async {
    photos = platform ?? FakeProfilePhotoPlatform();
    final services = FakeBackend().services(FakePermissionService(), profilePhotoPlatform: photos);
    await services.authService.restoreSession();
    await tester.pumpWidget(MyApp(services: services));
    await tester.pumpAndSettle();
  }

  Finder dashboardPhoto() => find.byKey(const ValueKey('dashboard-photo'));

  Future<void> openPhotoSheet(WidgetTester tester) async {
    await openTab(tester, 'Profile');
    await tester.tap(find.byIcon(Icons.photo_camera_rounded));
    await tester.pumpAndSettle();
  }

  testWidgets('choosing a photo shows it on Profile and the Dashboard, saved for that account', (tester) async {
    await startApp(tester);
    await logIn(tester, 'mansi@example.com');
    expect(dashboardPhoto(), findsNothing);
    expect(find.text('M'), findsOneWidget, reason: 'initials until a photo is chosen');

    photos.nextPick = _png;
    await openPhotoSheet(tester);
    await tester.tap(find.text('Choose photo'));
    await tester.pumpAndSettle();

    expect(find.text('Photo updated'), findsOneWidget);
    expect(photos.saved['u1'], _png);
    final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
    expect(avatar.foregroundImage, isA<ResizeImage>());

    await openTab(tester, 'Dashboard');
    expect(dashboardPhoto(), findsOneWidget);
    expect(find.text('M'), findsNothing);
  });

  testWidgets('cancelling the picker changes nothing', (tester) async {
    await startApp(tester);
    await logIn(tester, 'mansi@example.com');
    photos.nextPick = null;
    await openPhotoSheet(tester);
    await tester.tap(find.text('Choose photo'));
    await tester.pumpAndSettle();

    expect(find.text('Photo updated'), findsNothing);
    expect(photos.saved, isEmpty);
  });

  testWidgets('the photo can be removed', (tester) async {
    await startApp(tester, platform: FakeProfilePhotoPlatform()..saved['u1'] = _png);
    await logIn(tester, 'mansi@example.com');
    expect(dashboardPhoto(), findsOneWidget, reason: 'a saved photo is shown after login');

    await openPhotoSheet(tester);
    expect(find.text('Change photo'), findsOneWidget);
    await tester.tap(find.text('Remove photo'));
    await tester.pumpAndSettle();

    expect(find.text('Photo removed'), findsOneWidget);
    expect(photos.saved, isEmpty);
    await openTab(tester, 'Dashboard');
    expect(dashboardPhoto(), findsNothing);
    expect(find.text('M'), findsOneWidget);
  });

  testWidgets("one account never sees another account's photo", (tester) async {
    await startApp(tester, platform: FakeProfilePhotoPlatform()..saved['u1'] = _png);
    await logIn(tester, 'mansi@example.com');
    expect(dashboardPhoto(), findsOneWidget);

    await logOut(tester);
    await logIn(tester, 'ravi@example.com');
    expect(dashboardPhoto(), findsNothing);
    expect(find.text('R'), findsOneWidget);

    await logOut(tester);
    await logIn(tester, 'mansi@example.com');
    expect(dashboardPhoto(), findsOneWidget);
  });

  test('a photo over 10 MB is refused', () async {
    final platform = FakeProfilePhotoPlatform()..nextPick = Uint8List(ProfilePhotoService.maxBytes + 1);
    final services = FakeBackend().services(FakePermissionService(), profilePhotoPlatform: platform);
    FlutterSecureStorage.setMockInitialValues({'auth_token': FakeBackend.tokenFor('u1')});
    await services.authService.restoreSession();
    await expectLater(services.profilePhotoService.choosePhoto(), throwsA(isA<ProfilePhotoException>()));
    expect(platform.saved, isEmpty);
  });
}
