import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/core/permissions/permission_service.dart';
import 'package:child_assist/features/permissions/data/permissions_api.dart';
import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  late FakeBackend backend;
  late FakePermissionService os;

  Future<void> startApp(WidgetTester tester) async {
    backend = FakeBackend();
    os = FakePermissionService();
    final services = backend.services(os);
    await services.authService.restoreSession();
    await tester.pumpWidget(MyApp(services: services));
    await logIn(tester, 'mansi@example.com');
  }

  Finder row(AppPermission p) => find.byKey(ValueKey('permission-${p.name}'));
  Finder rowText(AppPermission p, String text) =>
      find.descendant(of: row(p), matching: find.textContaining(text));

  testWidgets('opening the screen shows statuses without requesting anything', (tester) async {
    await startApp(tester);
    os.os[AppPermission.photos] = PermissionState.granted;
    await openFromHome(tester, 'Permissions');

    expect(os.dialogsShown, isEmpty);
    expect(rowText(AppPermission.location, 'Not allowed'), findsOneWidget);
    expect(rowText(AppPermission.photos, 'Allowed'), findsWidgets);
    // A plain "denied" check is not stored over UNKNOWN; the granted photos status is.
    expect(backend.patches, ['PATCH /api/permissions/PHOTOS GRANTED (u1)']);
  });

  testWidgets('Allow -> system dialog -> granted is synced', (tester) async {
    await startApp(tester);
    await openFromHome(tester, 'Permissions');

    await tapVisible(tester, find.descendant(of: row(AppPermission.location), matching: find.text('Allow')));

    expect(os.dialogsShown, [AppPermission.location]);
    expect(rowText(AppPermission.location, 'Saved to account: Allowed'), findsOneWidget);
    expect(backend.permissions['u1']!['LOCATION'], 'GRANTED');
  });

  testWidgets('test buttons: deny, permanently deny, limited', (tester) async {
    await startApp(tester);
    os.onRequest[AppPermission.microphone] = PermissionState.denied;
    os.onRequest[AppPermission.camera] = PermissionState.permanentlyDenied;
    os.onRequest[AppPermission.photos] = PermissionState.limited;
    await openFromHome(tester, 'Permissions');

    await tapVisible(tester, find.text('Test Microphone Permission'));
    expect(find.text('Microphone: Not allowed'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(backend.permissions['u1']!['MICROPHONE'], 'DENIED');

    await tapVisible(tester, find.text('Test Camera Permission'));
    expect(find.text('Camera: Blocked'), findsOneWidget);
    expect(find.textContaining('enable camera for Child Assist in your device settings'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Open settings')));
    await tester.pumpAndSettle();
    expect(os.settingsOpened, 1);
    expect(backend.permissions['u1']!['CAMERA'], 'DENIED');

    await tapVisible(tester, find.text('Test Photos Permission'));
    expect(find.text('Photos: Limited'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(backend.permissions['u1']!['PHOTOS'], 'LIMITED');

    // Already granted: no second dialog, nothing new to sync.
    await tapVisible(tester, find.text('Test Notifications Permission'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    final patchCount = backend.patches.length;
    await tapVisible(tester, find.text('Test Notifications Permission'));
    expect(find.text('Notifications: Allowed'), findsOneWidget);
    expect(os.dialogsShown.where((p) => p == AppPermission.notifications), hasLength(1));
    expect(backend.patches, hasLength(patchCount));
  });

  testWidgets('a change made in system Settings is picked up on refresh', (tester) async {
    await startApp(tester);
    await openFromHome(tester, 'Permissions');
    await tapVisible(tester, find.text('Test Location Permission'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(backend.permissions['u1']!['LOCATION'], 'GRANTED');

    os.os[AppPermission.location] = PermissionState.denied; // user revoked it in Settings
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();

    expect(backend.permissions['u1']!['LOCATION'], 'DENIED');
    await tester.scrollUntilVisible(row(AppPermission.location), -100,
        scrollable: find.byType(Scrollable).first);
    expect(rowText(AppPermission.location, 'Not allowed · Saved to account: Not allowed'), findsOneWidget);
  });

  testWidgets('permission records stay with their own user across logout/login', (tester) async {
    await startApp(tester);
    await openFromHome(tester, 'Permissions');
    await tapVisible(tester, find.descendant(of: row(AppPermission.location), matching: find.text('Allow')));
    await tester.pageBack();
    await tester.pumpAndSettle();
    await logOut(tester);

    // A second account on the same device: OS permissions are per device, so Ravi's record
    // picks up the granted location, but it is his own row, and his denial stays his.
    os.onRequest[AppPermission.microphone] = PermissionState.denied;
    await logIn(tester, 'ravi@example.com');
    await openFromHome(tester, 'Permissions');
    expect(rowText(AppPermission.location, 'Saved to account: Allowed'), findsOneWidget);
    expect(rowText(AppPermission.microphone, 'Saved to account: Not recorded'), findsOneWidget);
    await tapVisible(tester, find.descendant(of: row(AppPermission.microphone), matching: find.text('Allow')));
    expect(backend.permissions['u2'], {'LOCATION': 'GRANTED', 'MICROPHONE': 'DENIED'});
    await tester.pageBack();
    await tester.pumpAndSettle();
    await logOut(tester);

    await logIn(tester, 'mansi@example.com');
    await openFromHome(tester, 'Permissions');
    expect(rowText(AppPermission.location, 'Saved to account: Allowed'), findsOneWidget);
    expect(rowText(AppPermission.microphone, 'Saved to account: Not recorded'), findsOneWidget);
    expect(backend.permissions['u1'], {'LOCATION': 'GRANTED'});
  });

  group('PermissionService', () {
    test('desktop platforms report unavailable without touching the plugin', () async {
      final service = PermissionService(isWeb: false, platform: TargetPlatform.windows);
      for (final p in AppPermission.values) {
        expect(await service.status(p), PermissionState.unavailable);
        expect(await service.request(p), PermissionState.unavailable);
      }
      expect(await service.openSettings(), isFalse);
    });

    test('web has no photos permission', () async {
      final service = PermissionService(isWeb: true);
      expect(await service.photoStatus(), PermissionState.unavailable);
    });
  });

  test('OS states map to the statuses the backend accepts', () {
    expect(SyncedPermissionStatus.fromDevice(PermissionState.granted), SyncedPermissionStatus.granted);
    expect(SyncedPermissionStatus.fromDevice(PermissionState.denied), SyncedPermissionStatus.denied);
    expect(SyncedPermissionStatus.fromDevice(PermissionState.permanentlyDenied), SyncedPermissionStatus.denied);
    expect(SyncedPermissionStatus.fromDevice(PermissionState.restricted), SyncedPermissionStatus.restricted);
    expect(SyncedPermissionStatus.fromDevice(PermissionState.limited), SyncedPermissionStatus.limited);
    expect(SyncedPermissionStatus.fromDevice(PermissionState.unavailable), isNull);
    for (final p in AppPermission.values) {
      expect(FakeBackend.supportedPermissions, contains(p.wireName));
    }
  });
}
