import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/app_services.dart';
import 'package:child_assist/core/permissions/permission_service.dart';
import 'package:child_assist/features/permissions/models/permission_onboarding.dart';
import 'package:child_assist/features/permissions/screens/permission_onboarding_screen.dart';
import 'package:child_assist/features/permissions/screens/permissions_screen.dart';
import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  late FakeBackend backend;
  late FakePermissionService os;
  late AppServices services;

  /// Starts the app as it would on a phone. Reuses [reuseBackend]/[reuseOs] to simulate the
  /// app being closed and reopened (secure storage keeps its values between pumps).
  Future<void> startApp(
    WidgetTester tester, {
    FakeBackend? reuseBackend,
    FakePermissionService? reuseOs,
  }) async {
    backend = reuseBackend ?? FakeBackend();
    os = reuseOs ?? FakePermissionService();
    services = backend.services(os);
    await services.authService.restoreSession();
    await tester.pumpWidget(MyApp(services: services, key: UniqueKey()));
    await tester.pumpAndSettle();
  }

  Future<void> register(WidgetTester tester, String name, String email) async {
    await tester.tap(find.text("Don't have an account? Register"));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), name);
    await tester.enterText(find.byType(TextFormField).at(1), email);
    await tester.enterText(find.byType(TextFormField).at(2), testPassword);
    await tester.tap(find.widgetWithText(FilledButton, 'Register'));
    await tester.pumpAndSettle();
  }

  Future<void> tapContinue(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
  }

  Finder onboarding() => find.byType(PermissionOnboardingScreen);
  Finder home() => find.text('Quick Actions');
  Finder stepTitle(int index) => find.text(permissionOnboardingSteps[index].title);

  void expectStep(int index) {
    expect(onboarding(), findsOneWidget);
    expect(stepTitle(index), findsOneWidget);
    expect(find.text('${index + 1} of 5'), findsOneWidget);
  }

  String? newUserId() =>
      backend.users.values.where((u) => u['email'] == 'new@example.com').firstOrNull?['id']
          as String?;

  testWidgets(
    '1, 3-7, 9, 12. a new account goes through the five permissions in order, then Home',
    (tester) async {
      await startApp(tester);
      await register(tester, 'New Kid', 'new@example.com');
      final id = newUserId()!;

      expect(home(), findsNothing, reason: 'Home must not appear before the walkthrough');
      final expected = [
        AppPermission.location,
        AppPermission.camera,
        AppPermission.microphone,
        AppPermission.photos,
        AppPermission.notifications,
      ];
      for (var i = 0; i < expected.length; i++) {
        expectStep(i);
        expect(find.text(permissionOnboardingSteps[i].description), findsOneWidget);
        // The explanation comes first; the system dialog only after "Continue".
        expect(os.dialogsShown, expected.sublist(0, i));
        expect(backend.users[id]!['permissionOnboardingCompleted'], isFalse);
        await tapContinue(tester);
      }

      expect(os.dialogsShown, expected);
      expect(home(), findsOneWidget);
      expect(find.text('Welcome, New Kid'), findsOneWidget);
      expect(backend.permissions[id], {
        'LOCATION': 'GRANTED',
        'CAMERA': 'GRANTED',
        'MICROPHONE': 'GRANTED',
        'PHOTOS': 'GRANTED',
        'NOTIFICATIONS': 'GRANTED',
      });
      // Completion is recorded once, after the last permission was saved.
      expect(backend.patches.last, 'PATCH /api/profile/permission-onboarding true ($id)');
      expect(backend.patches.where((p) => p.contains('permission-onboarding')), hasLength(1));
      expect(backend.users[id]!['permissionOnboardingCompleted'], isTrue);
      expect(backend.patches.any((p) => p.contains('DOCUMENTS')), isFalse);
    },
  );

  testWidgets('2. a user who completed it goes straight to Home', (tester) async {
    await startApp(tester);
    await logIn(tester, 'mansi@example.com');
    expect(onboarding(), findsNothing);
    expect(home(), findsOneWidget);
    expect(os.calls.where((c) => c.startsWith('request')), isEmpty);
  });

  testWidgets('8, 10. denied and limited answers are saved and the walkthrough continues', (
    tester,
  ) async {
    await startApp(tester);
    os.onRequest[AppPermission.location] = PermissionState.denied;
    os.onRequest[AppPermission.camera] = PermissionState.granted;
    os.onRequest[AppPermission.microphone] = PermissionState.denied;
    os.onRequest[AppPermission.photos] = PermissionState.limited;
    os.onRequest[AppPermission.notifications] = PermissionState.denied;
    await register(tester, 'New Kid', 'new@example.com');
    final id = newUserId()!;

    for (var i = 0; i < 5; i++) {
      expectStep(i);
      await tapContinue(tester);
    }

    expect(home(), findsOneWidget);
    expect(backend.permissions[id], {
      'LOCATION': 'DENIED',
      'CAMERA': 'GRANTED',
      'MICROPHONE': 'DENIED',
      'PHOTOS': 'LIMITED',
      'NOTIFICATIONS': 'DENIED',
    });
    expect(backend.users[id]!['permissionOnboardingCompleted'], isTrue);
  });

  testWidgets(
    '11. a blocked permission is explained, never re-requested, and Settings is offered',
    (tester) async {
      await startApp(tester);
      os.os[AppPermission.location] = PermissionState.permanentlyDenied;
      await register(tester, 'New Kid', 'new@example.com');
      final id = newUserId()!;

      expectStep(0);
      expect(
        find.text('Permission is currently blocked.\n\nYou can enable it later from Settings.'),
        findsOneWidget,
      );
      expect(os.calls, isNot(contains('request location')));
      expect(backend.permissions[id]!['LOCATION'], 'DENIED');

      await tester.tap(find.text('Open Settings'));
      await tester.pumpAndSettle();
      expect(os.settingsOpened, 1);

      await tapContinue(tester);
      expectStep(1);
      expect(os.calls.where((c) => c == 'request location'), isEmpty);

      // Denying twice in the real dialog makes Android report "blocked": explained, then onward.
      os.onRequest[AppPermission.camera] = PermissionState.permanentlyDenied;
      await tapContinue(tester);
      expectStep(1);
      expect(find.textContaining('Permission is currently blocked.'), findsOneWidget);
      expect(backend.permissions[id]!['CAMERA'], 'DENIED');
      await tapContinue(tester);
      expectStep(2);
      expect(os.dialogsShown, [AppPermission.camera]);
    },
  );

  testWidgets('a blocked permission enabled in Settings meanwhile is saved as allowed', (
    tester,
  ) async {
    await startApp(tester);
    os.os[AppPermission.location] = PermissionState.permanentlyDenied;
    await register(tester, 'New Kid', 'new@example.com');
    os.os[AppPermission.location] = PermissionState.granted; // user enabled it in Settings
    await tapContinue(tester);
    expectStep(1);
    expect(backend.permissions[newUserId()!]!['LOCATION'], 'GRANTED');
  });

  testWidgets('13. the final save can be retried and Home appears only once it succeeds', (
    tester,
  ) async {
    await startApp(tester);
    await register(tester, 'New Kid', 'new@example.com');
    final id = newUserId()!;

    backend.permissionFailures = 1;
    await tapContinue(tester);
    expectStep(0);
    expect(find.textContaining('Could not save your choice to your account'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
    await tester.pumpAndSettle();
    expectStep(1);
    expect(backend.permissions[id]!['LOCATION'], 'GRANTED');
    expect(os.dialogsShown, [AppPermission.location], reason: 'retry does not ask the OS again');

    for (var i = 1; i < 4; i++) {
      await tapContinue(tester);
    }
    backend.onboardingFailures = 2;
    await tapContinue(tester); // notifications, then the completion save fails

    expect(home(), findsNothing);
    expect(find.textContaining('Could not finish setup'), findsOneWidget);
    expect(backend.users[id]!['permissionOnboardingCompleted'], isFalse);

    await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not finish setup'), findsOneWidget);
    expect(home(), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(home(), findsOneWidget);
    expect(backend.users[id]!['permissionOnboardingCompleted'], isTrue);
    expect(os.dialogsShown, hasLength(5));
  });

  testWidgets('14. the Permissions screen still lets a denied permission be allowed later', (
    tester,
  ) async {
    await startApp(tester);
    os.onRequest[AppPermission.camera] = PermissionState.denied;
    await register(tester, 'New Kid', 'new@example.com');
    final id = newUserId()!;
    for (var i = 0; i < 5; i++) {
      await tapContinue(tester);
    }
    expect(backend.permissions[id]!['CAMERA'], 'DENIED');

    await openFromHome(tester, 'Permissions');
    expect(find.byType(PermissionsScreen), findsOneWidget);
    os.onRequest[AppPermission.camera] = PermissionState.granted;
    final cameraRow = find.byKey(const ValueKey('permission-camera'));
    await tapVisible(tester, find.descendant(of: cameraRow, matching: find.text('Allow')));

    expect(os.dialogsShown.where((p) => p == AppPermission.camera), hasLength(2));
    expect(backend.permissions[id]!['CAMERA'], 'GRANTED');
    expect(backend.users[id]!['permissionOnboardingCompleted'], isTrue);
  });

  testWidgets('15. logout and login keep the completed state: no walkthrough the second time', (
    tester,
  ) async {
    await startApp(tester);
    await register(tester, 'New Kid', 'new@example.com');
    for (var i = 0; i < 5; i++) {
      await tapContinue(tester);
    }
    expect(home(), findsOneWidget);
    final requests = os.calls.where((c) => c.startsWith('request')).length;

    await logOut(tester);
    await logIn(tester, 'new@example.com');
    expect(onboarding(), findsNothing);
    expect(home(), findsOneWidget);
    expect(os.calls.where((c) => c.startsWith('request')), hasLength(requests));

    // Reinstall: local data is gone, but the backend still says completed.
    FlutterSecureStorage.setMockInitialValues({});
    await startApp(tester, reuseBackend: backend, reuseOs: os);
    await logIn(tester, 'new@example.com');
    expect(home(), findsOneWidget);
  });

  testWidgets('an existing account that never did the walkthrough gets it on next login', (
    tester,
  ) async {
    await startApp(tester);
    final id = backend.addUser('Old User', 'old@example.com');
    await logIn(tester, 'old@example.com');
    expectStep(0);
    expect(home(), findsNothing);
    for (var i = 0; i < 5; i++) {
      await tapContinue(tester);
    }
    expect(home(), findsOneWidget);
    expect(backend.users[id]!['permissionOnboardingCompleted'], isTrue);
  });

  testWidgets('an interrupted walkthrough resumes at the unfinished step after a restart', (
    tester,
  ) async {
    await startApp(tester);
    os.onRequest[AppPermission.location] = PermissionState.denied;
    await register(tester, 'New Kid', 'new@example.com');
    final id = newUserId()!;
    await tapContinue(tester); // location: denied
    await tapContinue(tester); // camera: granted
    expectStep(2);

    // App killed and reopened: the session is restored and the walkthrough picks up at
    // Microphone, without asking for Location or Camera again.
    await startApp(tester, reuseBackend: backend, reuseOs: os);
    expectStep(2);
    expect(os.dialogsShown, [AppPermission.location, AppPermission.camera]);
    await tapContinue(tester);
    await tapContinue(tester);
    await tapContinue(tester);
    expect(home(), findsOneWidget);
    expect(backend.permissions[id], {
      'LOCATION': 'DENIED',
      'CAMERA': 'GRANTED',
      'MICROPHONE': 'GRANTED',
      'PHOTOS': 'GRANTED',
      'NOTIFICATIONS': 'GRANTED',
    });
  });

  testWidgets('progress is kept per account', (tester) async {
    await startApp(tester);
    final a = backend.addUser('A', 'a@example.com');
    backend.addUser('B', 'b@example.com');
    await logIn(tester, 'a@example.com');
    await tapContinue(tester);
    await tapContinue(tester);
    expectStep(2);
    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();

    await logIn(tester, 'b@example.com');
    expectStep(0);
    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();

    await logIn(tester, 'a@example.com');
    expectStep(2);
    expect(backend.users[a]!['permissionOnboardingCompleted'], isFalse);
  });

  testWidgets('if the setup state cannot be loaded, the user can retry', (tester) async {
    await startApp(tester);
    backend.profileFailures = 1;
    await logIn(tester, 'mansi@example.com');
    expect(home(), findsNothing);
    expect(onboarding(), findsNothing);
    expect(find.text('Service unavailable'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(home(), findsOneWidget);
  });
}
