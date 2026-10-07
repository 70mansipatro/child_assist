import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/app_services.dart';
import 'package:child_assist/features/chat/screens/chat_screen.dart';
import 'package:child_assist/features/location/screens/location_screen.dart';
import 'package:child_assist/features/notifications/screens/notifications_screen.dart';
import 'package:child_assist/features/permissions/screens/permissions_screen.dart';
import 'package:child_assist/features/photos/screens/photos_screen.dart';
import 'package:child_assist/features/profile/screens/profile_screen.dart';
import 'package:child_assist/features/settings/screens/app_settings_screen.dart';
import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  late FakeBackend backend;
  late FakeTextToSpeech tts;
  late AppServices services;

  Future<void> startApp(WidgetTester tester) async {
    backend = FakeBackend();
    tts = FakeTextToSpeech();
    services = backend.services(FakePermissionService(), textToSpeech: tts);
    await services.authService.restoreSession();
    await tester.pumpWidget(MyApp(services: services));
    await tester.pumpAndSettle();
    await logIn(tester, 'mansi@example.com');
  }

  /// The Android system back button.
  Future<void> systemBack(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  Finder selectedTab() => find.byWidgetPredicate((w) => w is NavigationBar);
  int selectedIndex(WidgetTester tester) => tester.widget<NavigationBar>(selectedTab()).selectedIndex;

  testWidgets('Dashboard opens after login with greeting and feature cards', (tester) async {
    await startApp(tester);
    expect(dashboard(), findsOneWidget);
    expect(find.text('How can I help you today?'), findsOneWidget);
    expect(find.text('View your photos and memories'), findsOneWidget);
    expect(find.text('Find your notes and files'), findsOneWidget);
    expect(find.text('Manage your app permissions'), findsOneWidget);
    expect(find.text('View your notifications'), findsOneWidget);
    expect(selectedIndex(tester), 0);
  });

  testWidgets('tabs switch, and only one navigation bar exists anywhere', (tester) async {
    await startApp(tester);
    await openTab(tester, 'Chat');
    expect(find.byType(ChatScreen), findsOneWidget);
    await openTab(tester, 'Location');
    expect(find.byType(LocationScreen), findsOneWidget);
    await openTab(tester, 'Profile');
    expect(find.byType(ProfileScreen), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    await openTab(tester, 'Dashboard');
    expect(dashboard(), findsOneWidget);
  });

  testWidgets('"Ask Child Assist" on the Dashboard opens the Chat tab', (tester) async {
    await startApp(tester);
    await tester.tap(find.text('Ask Child Assist'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(selectedIndex(tester), 1);
  });

  testWidgets('Android back: other tab -> Dashboard; pushed screen -> its tab', (tester) async {
    await startApp(tester);
    await openTab(tester, 'Location');
    await systemBack(tester);
    expect(dashboard(), findsOneWidget);
    expect(selectedIndex(tester), 0);

    await openFromHome(tester, 'Photos');
    expect(find.byType(PhotosScreen), findsOneWidget);
    await systemBack(tester);
    expect(find.byType(PhotosScreen), findsNothing);
    expect(dashboard(), findsOneWidget);

    await openTab(tester, 'Profile');
    await tapVisible(tester, find.text('App Settings'));
    await systemBack(tester);
    expect(find.byType(AppSettingsScreen), findsNothing);
    expect(find.byType(ProfileScreen), findsOneWidget);
  });

  testWidgets('a chat in progress survives switching tabs', (tester) async {
    await startApp(tester);
    await openTab(tester, 'Chat');
    await tester.enterText(find.byType(TextField), 'Remember me');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    await openTab(tester, 'Location');
    await openTab(tester, 'Chat');
    expect(find.text('Remember me'), findsOneWidget);
    expect(backend.chatRequests, hasLength(1));
  });

  testWidgets('Notifications shows an honest empty state from Dashboard and Profile', (tester) async {
    await startApp(tester);
    await openFromHome(tester, 'Notifications');
    expect(find.byType(NotificationsScreen), findsOneWidget);
    expect(find.text('No notifications yet'), findsOneWidget);
    await tester.tap(find.text('Notification permission'));
    await tester.pumpAndSettle();
    expect(find.byType(PermissionsScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    await openTab(tester, 'Profile');
    await tapVisible(tester, find.text('Notifications'));
    expect(find.byType(NotificationsScreen), findsOneWidget);
  });

  testWidgets('Profile lists Account, Permissions, Notifications, App Settings and Logout', (tester) async {
    await startApp(tester);
    await openTab(tester, 'Profile');
    expect(find.text('mansi@example.com'), findsOneWidget);
    for (final label in ['Account', 'Permissions', 'Notifications', 'App Settings', 'Logout']) {
      await tester.scrollUntilVisible(find.text(label), 100, scrollable: find.byType(Scrollable).first);
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tapVisible(tester, find.text('Permissions'));
    expect(find.byType(PermissionsScreen), findsOneWidget);
  });

  testWidgets('App Settings: voice replies is shared with Chat, theme changes the app', (tester) async {
    await startApp(tester);
    await openTab(tester, 'Profile');
    await tapVisible(tester, find.text('App Settings'));

    expect(find.text('English'), findsOneWidget);
    expect(tts.repliesEnabled, isFalse, reason: 'voice replies default to off');
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(tts.repliesEnabled, isTrue);

    await tester.tap(find.text('Theme'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(services.themeMode.value, ThemeMode.dark);
    expect(Theme.of(tester.element(find.byType(AppSettingsScreen))).brightness, Brightness.dark);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await openTab(tester, 'Chat');
    expect(find.byTooltip('Voice replies: on'), findsOneWidget);
  });

  testWidgets('logout from App Settings returns to Login', (tester) async {
    await startApp(tester);
    await openTab(tester, 'Profile');
    await tapVisible(tester, find.text('App Settings'));
    await tapVisible(tester, find.text('Logout'));
    expect(find.widgetWithText(FilledButton, 'Log in'), findsOneWidget);
    expect(find.byType(AppSettingsScreen), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('the next user starts on the Dashboard tab', (tester) async {
    await startApp(tester);
    await openTab(tester, 'Location');
    await logOut(tester);
    await logIn(tester, 'ravi@example.com');
    expect(dashboard(), findsOneWidget);
    expect(selectedIndex(tester), 0);
  });
}
