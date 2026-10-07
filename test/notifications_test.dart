import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/app_services.dart';
import 'package:child_assist/core/navigation/app_menu.dart';
import 'package:child_assist/core/notifications/notification_service.dart';
import 'package:child_assist/core/permissions/permission_service.dart';
import 'package:child_assist/features/auth/data/token_storage.dart';
import 'package:child_assist/features/chat/screens/chat_screen.dart';
import 'package:child_assist/features/location/screens/location_screen.dart';
import 'package:child_assist/features/notifications/screens/notification_settings_screen.dart';
import 'package:child_assist/features/notifications/screens/notifications_screen.dart';
import 'package:child_assist/features/permissions/screens/permissions_screen.dart';
import 'package:child_assist/features/profile/screens/profile_screen.dart';
import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  late FakeBackend backend;
  late FakePermissionService permissions;
  late FakePushPlatform push;
  late AppServices services;

  FakeNotificationsBackend server() => backend.notificationsBackend;

  /// Starts the app like main() does: push handling first, then session restore. Signs in as
  /// [email] unless [signedInAs] restores a stored session instead.
  Future<void> startApp(
    WidgetTester tester, {
    bool notificationsAllowed = true,
    PushMessage? launchedBy,
    String? email = 'mansi@example.com',
    String? signedInAs,
    bool pushSupported = true,
    void Function(FakeBackend backend)? seed,
    void Function(FakePushPlatform push)? setupPush,
  }) async {
    backend = FakeBackend();
    seed?.call(backend);
    permissions = FakePermissionService();
    if (notificationsAllowed) permissions.os[AppPermission.notifications] = PermissionState.granted;
    push = FakePushPlatform(isSupported: pushSupported)..launchMessage = launchedBy;
    setupPush?.call(push);
    services = backend.services(permissions, pushPlatform: push);
    if (signedInAs != null) await TokenStorage().write(FakeBackend.tokenFor(signedInAs));
    await services.notificationService.start();
    await services.authService.restoreSession();
    await tester.pumpWidget(MyApp(services: services));
    await tester.pumpAndSettle();
    if (signedInAs == null && email != null) await logIn(tester, email);
  }

  NotificationService notifications() => services.notificationService;

  group('push setup', () {
    testWidgets('1. FCM starts at launch and nothing is registered before sign-in', (tester) async {
      await startApp(tester, email: null);
      expect(push.initialized, isTrue);
      expect(notifications().pushAvailable, isTrue);
      expect(server().deviceCalls, isEmpty);
    });

    testWidgets('1b. without push support the app still works and keeps its history', (tester) async {
      await startApp(tester, pushSupported: false, seed: (b) => b.notificationsBackend.seed('u1'));
      expect(push.initialized, isFalse);
      expect(dashboard(), findsOneWidget);
      expect(server().deviceCalls, isEmpty);
      await openFromHome(tester, 'Notifications');
      expect(find.text('Child Assist test notification'), findsOneWidget);
    });

    testWidgets('3. after sign-in the FCM token is registered for that account only', (tester) async {
      await startApp(tester);
      expect(server().deviceCalls, ['register ${push.currentToken} (u1)']);
      final body = server().deviceBodies.single;
      expect(body['platform'], 'ANDROID');
      expect(body.containsKey('userId'), isFalse);
      expect(notifications().registered, isTrue);
    });

    testWidgets('2. notifications blocked by the OS: no registration and no dialog from push setup', (tester) async {
      await startApp(tester, notificationsAllowed: false);
      expect(server().deviceCalls, isEmpty);
      expect(permissions.dialogsShown, isNot(contains(AppPermission.notifications)));
      expect(permissions.calls, isNot(contains('request notifications')));

      // The user allows notifications (walkthrough or Permissions); the report triggers registration.
      permissions.os[AppPermission.notifications] = PermissionState.granted;
      await services.permissionSyncService.report(AppPermission.notifications, PermissionState.granted, fromRequest: true);
      await tester.pumpAndSettle();
      expect(server().deviceCalls, ['register ${push.currentToken} (u1)']);
    });

    testWidgets('2b. granting notifications in Permissions registers this phone', (tester) async {
      await startApp(tester, notificationsAllowed: false);
      await openFromHome(tester, 'Permissions');
      expect(find.byType(PermissionsScreen), findsOneWidget);
      await tapVisible(tester, find.text('Test Notifications Permission'));
      expect(find.text('Notifications: Allowed'), findsOneWidget);
      expect(server().deviceCalls, ['register ${push.currentToken} (u1)']);
    });

    testWidgets('4. a refreshed FCM token is registered again', (tester) async {
      await startApp(tester);
      final first = push.currentToken!;
      push.rotateToken();
      await tester.pumpAndSettle();
      final second = push.currentToken!;
      expect(second, isNot(first));
      expect(server().deviceCalls.last, 'register $second (u1)');
      expect(server().ownerOf(second), 'u1');
    });

    testWidgets('50. a failed registration never blocks sign-in and is retried', (tester) async {
      await startApp(tester, email: null);
      server().failureStatus = 503;
      await logIn(tester, 'mansi@example.com');
      expect(dashboard(), findsOneWidget);
      expect(notifications().registrationFailed, isTrue);

      server().failureStatus = null;
      await notifications().syncRegistration();
      await tester.pumpAndSettle();
      expect(notifications().registrationFailed, isFalse);
      expect(notifications().registered, isTrue);
    });
  });

  group('registration robustness', () {
    testWidgets('a token that is not ready yet is retried and then registered', (tester) async {
      await startApp(tester, setupPush: (p) => p.nullTokens = 1000);
      expect(server().deviceCalls, isEmpty);
      push.nullTokens = 0; // FCM finishes registering in the background.
      await tester.pump(NotificationService.retryDelays.first + const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(server().deviceCalls, ['register ${push.currentToken} (u1)']);
    });

    testWidgets('a failing FCM token request is reported and retried, never blocking sign-in', (tester) async {
      await startApp(tester, setupPush: (p) => p.tokenFailures = 2);
      expect(dashboard(), findsOneWidget);
      expect(notifications().registrationFailed, isTrue);
      expect(server().deviceCalls, isEmpty);
      for (final delay in NotificationService.retryDelays.take(2)) {
        await tester.pump(delay + const Duration(seconds: 1));
        await tester.pumpAndSettle();
      }
      expect(notifications().registrationFailed, isFalse);
      expect(server().deviceCalls, ['register ${push.currentToken} (u1)']);
    });

    testWidgets('a sync asked for while one is running is not dropped', (tester) async {
      await startApp(tester, notificationsAllowed: false);
      // Two requests back to back: the second arrives while the first is still running.
      permissions.os[AppPermission.notifications] = PermissionState.granted;
      final first = notifications().syncRegistration();
      final second = notifications().syncRegistration();
      await Future.wait([first, second]);
      await tester.pumpAndSettle();
      expect(server().deviceCalls, ['register ${push.currentToken} (u1)']);
    });

    testWidgets('after an account switch the new token is read only once the old one is deleted', (tester) async {
      await startApp(tester);
      final gate = Completer<void>();
      push.deleteGate = gate;
      await logOut(tester);
      await logIn(tester, 'ravi@example.com');
      expect(server().devices.values.where((d) => d['userId'] == 'u2'), isEmpty);
      gate.complete();
      await tester.pumpAndSettle();
      expect(push.tokenReadsDuringDelete, 0);
      expect(server().ownerOf(push.currentToken!), 'u2');
    });

    test('tokens are masked in diagnostics', () {
      const token = 'cXyZ12AbCdEfGhIjKlMnOpQrStUvWxYz0123456789:APA91bHIJKLMNOP';
      final masked = NotificationService.maskToken(token);
      expect(masked, 'len=${token.length} cXyZ12…MNOP');
      expect(masked.contains('AbCdEf'), isFalse);
    });
  });

  group('arriving notifications', () {
    testWidgets('5. a push while the app is open is shown once and updates the badge', (tester) async {
      await startApp(tester);
      final id = server().seed('u1', title: 'Location tracking started', body: 'Child Assist is now updating your travel history.');
      push.deliver(pushFor(id, type: 'TRACKING_STARTED', category: 'LOCATION', deepLink: 'childassist://location',
          title: 'Location tracking started', body: 'Child Assist is now updating your travel history.'));
      await tester.pumpAndSettle();
      expect(push.shown.map((m) => m.notificationId), [id]);
      expect(notifications().unreadCount, 1);
      expect(find.byKey(const ValueKey('dashboard-unread')), findsOneWidget);
    });

    testWidgets('19. the same push delivered twice is shown once', (tester) async {
      await startApp(tester);
      final id = server().seed('u1');
      push.deliver(pushFor(id));
      push.deliver(pushFor(id));
      await tester.pumpAndSettle();
      expect(push.shown, hasLength(1));
    });

    testWidgets('19b. chat results are not pushed on top of an open Chat, but are elsewhere', (tester) async {
      await startApp(tester);
      await openTab(tester, 'Chat');
      expect(find.byType(ChatScreen), findsOneWidget);
      final first = server().seed('u1', type: 'EMAIL_ACTION', title: 'Email sent', body: 'Your email was sent successfully.');
      push.deliver(pushFor(first, type: 'EMAIL_ACTION', category: 'COMMUNICATION', deepLink: 'childassist://chat', title: 'Email sent'));
      await tester.pumpAndSettle();
      expect(push.shown, isEmpty);
      expect(notifications().unreadCount, 1, reason: 'still counted in the history');

      await openTab(tester, 'Dashboard');
      final second = server().seed('u1', type: 'EMAIL_ACTION', title: 'Email sent', body: 'Your email was sent successfully.');
      push.deliver(pushFor(second, type: 'EMAIL_ACTION', category: 'COMMUNICATION', deepLink: 'childassist://chat', title: 'Email sent'));
      await tester.pumpAndSettle();
      expect(push.shown.map((m) => m.notificationId), [second]);
    });

    testWidgets('18. a security alert also shows inside the open app', (tester) async {
      await startApp(tester);
      final id = server().seed('u1', type: 'ACCOUNT_LOGIN', title: 'New login to Child Assist', body: 'A new device signed in to your account.', deepLink: 'childassist://profile/security');
      push.deliver(pushFor(id, type: 'ACCOUNT_LOGIN', category: 'SECURITY', deepLink: 'childassist://profile/security',
          title: 'New login to Child Assist', body: 'A new device signed in to your account.'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(push.shown, hasLength(1));
      expect(find.widgetWithText(SnackBar, 'New login to Child Assist'), findsOneWidget);
      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      expect(find.byType(NotificationsScreen), findsOneWidget);
    });

    testWidgets('6/8. tapping a notification while the app runs opens its screen and marks it read', (tester) async {
      await startApp(tester);
      final id = server().seed('u1', type: 'TRACKING_PAUSED', deepLink: 'childassist://location');
      push.tap(pushFor(id, type: 'TRACKING_PAUSED', category: 'LOCATION', deepLink: 'childassist://location'));
      await tester.pumpAndSettle();
      expect(find.byType(LocationScreen), findsOneWidget);
      expect(server().readCalls, ['$id (u1)']);
      expect(notifications().unreadCount, 0);
    });

    testWidgets('6b. a tap opens its screen even from a page pushed on top', (tester) async {
      await startApp(tester);
      await openFromHome(tester, 'Photos');
      final id = server().seed('u1', type: 'PERMISSION_CHANGED', deepLink: 'childassist://permissions/location');
      push.tap(pushFor(id, type: 'PERMISSION_CHANGED', category: 'PERMISSION', deepLink: 'childassist://permissions/location'));
      await tester.pumpAndSettle();
      expect(find.byType(PermissionsScreen), findsOneWidget);
    });

    testWidgets('7/20. a tap that launched the app opens its screen once the session is restored', (tester) async {
      final launch = pushFor('n1', type: 'WHATSAPP_ACTION', category: 'COMMUNICATION', deepLink: 'childassist://chat');
      await startApp(tester, launchedBy: launch, signedInAs: 'u1', seed: (b) => b.notificationsBackend.seed('u1'));
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(server().readCalls, ['n1 (u1)']);
      expect(notifications().pendingRoute, isNull, reason: 'opened exactly once');
    });

    testWidgets('20b. a launch tap waits for sign-in, then opens', (tester) async {
      final launch = pushFor('n1', deepLink: 'childassist://location', category: 'LOCATION');
      await startApp(tester, launchedBy: launch, email: null, seed: (b) => b.notificationsBackend.seed('u1'));
      expect(find.byType(LocationScreen), findsNothing);
      expect(notifications().pendingRoute, NotificationRoute.location);
      await logIn(tester, 'mansi@example.com');
      expect(find.byType(LocationScreen), findsOneWidget);
      expect(server().readCalls, ['n1 (u1)']);
    });

    test('9. deep links map onto the existing navigation; unknown links open Notifications', () {
      expect(NotificationRoute.parse('childassist://location').destination, AppDestination.location);
      expect(NotificationRoute.parse('childassist://chat').destination, AppDestination.chat);
      expect(NotificationRoute.parse('childassist://permissions').destination, AppDestination.permissions);
      expect(NotificationRoute.parse('childassist://permissions/location').destination, AppDestination.permissions);
      expect(NotificationRoute.parse('childassist://profile/security').destination, AppDestination.profile);
      expect(NotificationRoute.parse('childassist://documents').destination, AppDestination.documents);
      expect(NotificationRoute.parse('childassist://photos').destination, AppDestination.photos);
      expect(NotificationRoute.parse('childassist://notifications').destination, AppDestination.notifications);
      expect(NotificationRoute.parse('https://evil.example/phish').destination, AppDestination.notifications);
      expect(NotificationRoute.parse(null).destination, AppDestination.notifications);
    });
  });

  group('Notifications screen', () {
    testWidgets('groups by Today, Yesterday and Earlier with unread highlighted', (tester) async {
      final now = DateTime.now();
      await startApp(tester, seed: (b) {
        b.notificationsBackend
          ..seed('u1', title: 'Old one', createdAt: now.subtract(const Duration(days: 5)), read: true)
          ..seed('u1', title: 'Yesterday one', createdAt: now.subtract(const Duration(days: 1)))
          ..seed('u1', title: 'Today one', createdAt: now);
      });
      await openFromHome(tester, 'Notifications');
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('Earlier'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Unread')), findsNWidgets(2));
    });

    testWidgets('10/12. tapping one marks it read, updates the badges and opens its screen', (tester) async {
      await startApp(tester, seed: (b) {
        b.notificationsBackend
          ..seed('u1', title: 'Travel history updated', type: 'TRAVEL_HISTORY_UPDATED', deepLink: 'childassist://location')
          ..seed('u1', title: 'Child Assist update', type: 'SYSTEM');
      });
      expect(notifications().unreadCount, 2);
      expect(tester.widget<Text>(find.byKey(const ValueKey('dashboard-unread'))).data, '2');
      await openTab(tester, 'Profile');
      expect(find.text('2 unread'), findsOneWidget);

      await tapVisible(tester, find.text('Notifications'));
      await tester.tap(find.text('Travel history updated'));
      await tester.pumpAndSettle();
      expect(find.byType(LocationScreen), findsOneWidget);
      expect(server().readCalls, hasLength(1));
      expect(notifications().unreadCount, 1);
      await openTab(tester, 'Profile');
      expect(find.text('1 unread'), findsOneWidget);
    });

    testWidgets('11. mark all as read clears every unread mark and the badge', (tester) async {
      await startApp(tester, seed: (b) {
        b.notificationsBackend
          ..seed('u1', title: 'One')
          ..seed('u1', title: 'Two');
      });
      await openFromHome(tester, 'Notifications');
      await tester.tap(find.byTooltip('Mark all as read'));
      await tester.pumpAndSettle();
      expect(server().unread('u1'), 0);
      expect(notifications().unreadCount, 0);
      expect(find.bySemanticsLabel(RegExp('^Unread')), findsNothing);
      expect(find.byTooltip('Mark all as read'), findsNothing);
    });

    testWidgets('an empty history is honest, and offers settings and the permission', (tester) async {
      await startApp(tester);
      await openFromHome(tester, 'Notifications');
      expect(find.text('No notifications yet'), findsOneWidget);
      await tester.tap(find.text('Notification permission'));
      await tester.pumpAndSettle();
      expect(find.byType(PermissionsScreen), findsOneWidget);
    });

    testWidgets('blocked notifications show a warning but the history still loads', (tester) async {
      await startApp(tester, notificationsAllowed: false, seed: (b) => b.notificationsBackend.seed('u1', title: 'Kept here'));
      await openFromHome(tester, 'Notifications');
      expect(find.text('Notifications are off on this phone'), findsOneWidget);
      expect(find.text('Kept here'), findsOneWidget);
    });

    testWidgets('15. the screen works in dark mode', (tester) async {
      await startApp(tester, seed: (b) => b.notificationsBackend.seed('u1', title: 'Dark one'));
      services.themeMode.value = ThemeMode.dark;
      await tester.pumpAndSettle();
      await openFromHome(tester, 'Notifications');
      expect(find.text('Dark one'), findsOneWidget);
      expect(Theme.of(tester.element(find.text('Dark one'))).brightness, Brightness.dark);
      expect(tester.takeException(), isNull);
    });
  });

  group('settings', () {
    Future<void> openSettings(WidgetTester tester) async {
      await openFromHome(tester, 'Notifications');
      await tester.tap(find.byTooltip('Notification settings'));
      await tester.pumpAndSettle();
      expect(find.byType(NotificationSettingsScreen), findsOneWidget);
    }

    Switch switchFor(WidgetTester tester, String category) => tester.widget<Switch>(
      find.descendant(of: find.byKey(ValueKey('pref-$category')), matching: find.byType(Switch)),
    );

    testWidgets('16/17. categories can be switched off and stay off; Security cannot', (tester) async {
      await startApp(tester);
      await openSettings(tester);
      expect(switchFor(tester, 'SECURITY').value, isTrue);
      expect(switchFor(tester, 'SECURITY').onChanged, isNull, reason: 'security alerts are mandatory');

      await tester.tap(find.descendant(of: find.byKey(const ValueKey('pref-LOCATION')), matching: find.byType(Switch)));
      await tester.pumpAndSettle();
      expect(server().preferences['u1'], {'locationEnabled': false});
      expect(switchFor(tester, 'LOCATION').value, isFalse);

      // Reopened: loaded from the account, not the phone.
      Navigator.of(tester.element(find.byType(NotificationSettingsScreen))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Notification settings'));
      await tester.pumpAndSettle();
      expect(switchFor(tester, 'LOCATION').value, isFalse);
      expect(switchFor(tester, 'CHAT').value, isTrue);

      expect(() => notifications().setPreference(NotificationCategory.security, false), throwsA(anything));
    });

    testWidgets('settings are reachable from App Settings', (tester) async {
      await startApp(tester);
      await openTab(tester, 'Profile');
      await tapVisible(tester, find.text('App Settings'));
      await tapVisible(tester, find.text('Notification settings'));
      expect(find.byType(NotificationSettingsScreen), findsOneWidget);
    });
  });

  group('accounts', () {
    testWidgets('13. logout unregisters this phone, invalidates its token and clears state', (tester) async {
      await startApp(tester, seed: (b) => b.notificationsBackend.seed('u1'));
      final token = push.currentToken!;
      expect(server().ownerOf(token), 'u1');
      push.tap(pushFor('n-unrelated', deepLink: 'childassist://location'));
      await logOut(tester);

      expect(server().deviceCalls.last, 'unregister dev1 (u1)');
      expect(server().ownerOf(token), isNull);
      expect(push.deleteTokenCalls, 1);
      expect(push.cancelAllCalls, greaterThan(0));
      expect(notifications().unreadCount, 0);
      expect(notifications().pendingRoute, isNull);

      // A push for the old account arriving now is not shown.
      push.deliver(pushFor('n-late'));
      await tester.pumpAndSettle();
      expect(push.shown, isEmpty);
    });

    testWidgets('14/37. switching accounts: the next account never sees the previous one\'s notifications', (tester) async {
      await startApp(tester, seed: (b) {
        b.notificationsBackend
          ..seed('u1', title: "Mansi's notice")
          ..seed('u2', title: "Ravi's notice");
      });
      final tokenA = push.currentToken!;
      await openFromHome(tester, 'Notifications');
      expect(find.text("Mansi's notice"), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await logOut(tester);

      await logIn(tester, 'ravi@example.com');
      final tokenB = push.currentToken!;
      expect(tokenB, isNot(tokenA), reason: 'a fresh token for the new account');
      expect(server().ownerOf(tokenB), 'u2');
      expect(server().ownerOf(tokenA), isNull);

      await openFromHome(tester, 'Notifications');
      expect(find.text("Ravi's notice"), findsOneWidget);
      expect(find.text("Mansi's notice"), findsNothing);
      expect(notifications().unreadCount, 1);
    });

    testWidgets('Profile shows the unread count on the Notifications row', (tester) async {
      await startApp(tester, seed: (b) => b.notificationsBackend.seed('u1'));
      await openTab(tester, 'Profile');
      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(find.text('1 unread'), findsOneWidget);
    });
  });

  group('tracking state', () {
    testWidgets('Automatic Location History reports started and stopped, not each reading', (tester) async {
      await startApp(tester);
      permissions.allowLocationAllTheTime();
      await services.automaticTrackingService.enable();
      await tester.pumpAndSettle();
      await services.automaticTrackingService.recheck();
      await tester.pumpAndSettle();
      expect(server().trackingReports, ['STARTED (u1)']);
      await services.automaticTrackingService.disable();
      await tester.pumpAndSettle();
      expect(server().trackingReports, ['STARTED (u1)', 'STOPPED (u1)']);

      // Logging out is not the user stopping tracking.
      await services.automaticTrackingService.enable();
      await tester.pumpAndSettle();
      await logOut(tester);
      expect(server().trackingReports, ['STARTED (u1)', 'STOPPED (u1)', 'STARTED (u1)']);
    });
  });
}
