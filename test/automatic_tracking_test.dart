import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/app_services.dart';
import 'package:child_assist/core/api/api_client.dart';
import 'package:child_assist/core/permissions/permission_service.dart';
import 'package:child_assist/features/auth/data/auth_api.dart';
import 'package:child_assist/features/auth/data/token_storage.dart';
import 'package:child_assist/features/auth/services/auth_service.dart';
import 'package:child_assist/features/location/data/location_api.dart';
import 'package:child_assist/features/location/data/tracking_store.dart';
import 'package:child_assist/features/location/models/location_record.dart';
import 'package:child_assist/features/location/services/automatic_location_tracking_service.dart';
import 'package:child_assist/features/location/services/travel_point_filter.dart';
import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

// Home and School in Bhubaneswar, about 6.6 km apart.
const _home = (lat: 20.2961, lng: 85.8245);
const _school = (lat: 20.3555, lng: 85.8195);

TrackedPoint _at(({double lat, double lng}) place, DateTime time, {double northMeters = 0, double? accuracy = 20}) =>
    TrackedPoint(latitude: place.lat + northMeters / 111195, longitude: place.lng, capturedAt: time.toUtc(), accuracy: accuracy);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('TravelPointFilter (which readings become places)', () {
    const config = AutomaticTrackingConfig();
    final t0 = DateTime.utc(2026, 10, 7, 8, 10);
    DateTime t(int minutes) => t0.add(Duration(minutes: minutes));

    test('the first reading is the starting place; staying there saves nothing more', () {
      final filter = TravelPointFilter(config);
      expect(filter.add(_at(_home, t(0))), _at(_home, t(0)));
      // Home, Home, Home, Home, Home: one Home, not five.
      for (var i = 1; i <= 5; i++) {
        expect(filter.add(_at(_home, t(i * 30))), isNull);
      }
      expect(filter.checkStay(t(300)), isNull);
    });

    test('GPS drift under the minimum distance is ignored', () {
      final filter = TravelPointFilter(config, lastSaved: _at(_home, t(0)));
      expect(filter.add(_at(_home, t(10), northMeters: 60)), isNull);
      expect(filter.add(_at(_home, t(20), northMeters: 95)), isNull);
      expect(filter.hasPendingStop, isFalse);
    });

    test('a stop of at least five minutes is saved once, with the arrival time', () {
      final filter = TravelPointFilter(config, lastSaved: _at(_home, t(0)));
      expect(filter.add(_at(_school, t(50))), isNull, reason: 'just arrived');
      expect(filter.add(_at(_school, t(52), northMeters: 30)), isNull, reason: 'same stop, not long enough');
      expect(filter.timeUntilStay(t(52)), const Duration(minutes: 3));
      final saved = filter.add(_at(_school, t(56), northMeters: 20));
      expect(saved, isNotNull);
      expect(saved!.capturedAt, t(50), reason: 'saved with the time the phone arrived');
      expect(filter.add(_at(_school, t(90))), isNull, reason: 'School is now the last place');
    });

    test('passing through without stopping saves nothing', () {
      final filter = TravelPointFilter(config, lastSaved: _at(_home, t(0)));
      for (var i = 1; i <= 10; i++) {
        // 400 m further every minute: driving.
        expect(filter.add(_at(_home, t(i), northMeters: 400.0 * i)), isNull);
      }
    });

    test('a stationary phone is confirmed by time alone (no new readings)', () {
      final filter = TravelPointFilter(config, lastSaved: _at(_home, t(0)));
      filter.add(_at(_school, t(50)));
      expect(filter.checkStay(t(54)), isNull);
      expect(filter.checkStay(t(55))?.capturedAt, t(50));
    });

    test('coming back to the last place before the stop counts cancels it', () {
      final filter = TravelPointFilter(config, lastSaved: _at(_home, t(0)));
      filter.add(_at(_home, t(10), northMeters: 300));
      expect(filter.add(_at(_home, t(12), northMeters: 20)), isNull);
      expect(filter.hasPendingStop, isFalse);
      expect(filter.checkStay(t(30)), isNull);
    });

    test('inaccurate readings are ignored', () {
      final filter = TravelPointFilter(config, lastSaved: _at(_home, t(0)));
      expect(filter.add(_at(_school, t(10), accuracy: 900)), isNull);
      expect(filter.hasPendingStop, isFalse);
    });

    test('thresholds come from the configuration', () {
      final filter = TravelPointFilter(
        const AutomaticTrackingConfig(minimumDistanceMeters: 500, minimumStay: Duration(minutes: 10)),
        lastSaved: _at(_home, t(0)),
      );
      expect(filter.add(_at(_home, t(5), northMeters: 300)), isNull);
      expect(filter.hasPendingStop, isFalse, reason: '300 m is the same place with a 500 m threshold');
      filter.add(_at(_school, t(20)));
      expect(filter.checkStay(t(26)), isNull);
      expect(filter.checkStay(t(30)), isNotNull);
    });
  });

  group('AutomaticLocationTrackingService', () {
    late FakeBackend backend;
    late FakePermissionService os;
    late FakeBackgroundLocationSource gps;
    late FakePlaceLookup places;
    late AuthService auth;
    late DateTime now;
    final services = <AutomaticLocationTrackingService>[];

    AutomaticLocationTrackingService start() {
      final service = AutomaticLocationTrackingService(
        authService: auth,
        api: LocationApi(ApiClient(baseUrl: 'http://test', httpClient: backend.client)),
        permissionService: os,
        source: gps,
        placeLookup: places,
        store: TrackingStore(),
        clock: () => now,
      );
      services.add(service);
      return service;
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(Duration.zero);
      }
    }

    Future<void> logIn(String email) => auth.login(email: email, password: testPassword);

    Future<void> setUpWorld() async {
      backend = FakeBackend();
      os = FakePermissionService();
      gps = FakeBackgroundLocationSource();
      places = FakePlaceLookup();
      now = DateTime.now().toUtc();
      auth = AuthService(
        api: AuthApi(ApiClient(baseUrl: 'http://test', httpClient: backend.client)),
        storage: TokenStorage(),
        google: FakeGoogleAuthService(),
      );
      await logIn('mansi@example.com');
    }

    tearDown(() {
      for (final s in services) {
        s.dispose();
      }
      services.clear();
    });

    List<Map<String, dynamic>> saved([String user = 'u1']) =>
        (backend.locations[user] ?? []).where((l) => l['source'] == 'AUTOMATIC').toList();

    testWidgets('1. off by default: nothing is collected and no permission is asked', (tester) async {
      await setUpWorld();
      final tracking = start();
      await settle(tester);
      expect(tracking.enabled, isFalse);
      expect(tracking.status, AutomaticTrackingStatus.off);
      expect(gps.listening, isFalse);
      expect(os.dialogsShown, isEmpty);
      expect(os.backgroundDialogs, 0);
    });

    testWidgets('2. turning on asks location, then background location, then starts', (tester) async {
      await setUpWorld();
      final tracking = start();
      await settle(tester);
      await tracking.enable();
      expect(os.calls.where((c) => c.startsWith('request')).toList(), [
        'request location',
        'request backgroundLocation',
        'request notifications',
      ]);
      expect(tracking.status, AutomaticTrackingStatus.active);
      expect(tracking.isActive, isTrue);
      expect(gps.listening, isTrue, reason: 'the foreground service (and its notification) is running');

      // The first reading is where the user is now: saved with the device geocoder's place name.
      gps.emit(_at(_home, now));
      await settle(tester);
      expect(saved(), hasLength(1));
      expect(saved().single['placeName'], 'Jayadev Vihar');
      expect(backend.locationPosts.single.containsKey('userId'), isFalse);
      expect(tracking.savedCount, 1);
      expect(tracking.lastSaved?.source, LocationSource.automatic);
    });

    testWidgets('3. background permission denied: not tracking, says so', (tester) async {
      await setUpWorld();
      os.onBackgroundRequest = PermissionState.permanentlyDenied;
      final tracking = start();
      await settle(tester);
      await tracking.enable();
      expect(tracking.status, AutomaticTrackingStatus.permissionRequired);
      expect(tracking.issue, TrackingIssue.backgroundPermission);
      expect(tracking.isActive, isFalse);
      expect(gps.listening, isFalse);
      expect(gps.starts, 0);
    });

    testWidgets('4. location permission denied: background is never asked', (tester) async {
      await setUpWorld();
      os.onRequest[AppPermission.location] = PermissionState.denied;
      final tracking = start();
      await settle(tester);
      await tracking.enable();
      expect(tracking.status, AutomaticTrackingStatus.permissionRequired);
      expect(tracking.issue, TrackingIssue.locationPermission);
      expect(os.backgroundDialogs, 0);
      expect(gps.listening, isFalse);
    });

    testWidgets('5. location services off: paused, not active', (tester) async {
      await setUpWorld();
      gps.serviceEnabled = false;
      final tracking = start();
      await settle(tester);
      await tracking.enable();
      expect(tracking.status, AutomaticTrackingStatus.paused);
      expect(tracking.issue, TrackingIssue.servicesDisabled);
      expect(gps.listening, isFalse);
    });

    testWidgets('6. turning off stops collecting at once and keeps saved history', (tester) async {
      await setUpWorld();
      final tracking = start();
      await settle(tester);
      await tracking.enable();
      gps.emit(_at(_home, now));
      await settle(tester);
      await tracking.disable();
      expect(tracking.status, AutomaticTrackingStatus.off);
      expect(gps.listening, isFalse);
      expect(() => gps.emit(_at(_school, now)), throwsStateError, reason: 'nothing is listening any more');
      expect(saved(), hasLength(1), reason: 'history is kept when tracking stops');
    });

    testWidgets('7. same place is ignored; a five-minute stop elsewhere is confirmed and saved', (tester) async {
      await setUpWorld();
      final tracking = start();
      await settle(tester);
      await tracking.enable();
      final t0 = now;
      gps.emit(_at(_home, t0));
      await settle(tester);
      for (var i = 1; i <= 4; i++) {
        gps.emit(_at(_home, t0.add(Duration(minutes: i)), northMeters: 15.0 * i));
      }
      await settle(tester);
      expect(saved(), hasLength(1), reason: 'GPS drift at Home is not a new place');

      final arrival = t0.add(const Duration(minutes: 40));
      now = arrival;
      gps.emit(_at(_school, arrival));
      await settle(tester);
      expect(saved(), hasLength(1), reason: 'not saved on arrival');

      // The phone stays put (no readings); after five minutes one fresh reading confirms the stop.
      gps.fresh = _at(_school, arrival.add(const Duration(minutes: 5)), northMeters: 10);
      now = arrival.add(const Duration(minutes: 5, seconds: 1));
      await tester.pump(const Duration(minutes: 5, seconds: 2));
      await settle(tester);
      expect(gps.freshReads, 1);
      expect(saved(), hasLength(2));
      expect(DateTime.parse(saved().last['capturedAt'] as String), arrival);
    });

    testWidgets('8. a fresh reading back at the last place cancels a pending stop', (tester) async {
      await setUpWorld();
      final tracking = start();
      await settle(tester);
      await tracking.enable();
      gps.emit(_at(_home, now));
      await settle(tester);
      final away = now.add(const Duration(minutes: 1));
      now = away;
      gps.emit(_at(_home, away, northMeters: 400));
      await settle(tester);
      // Five minutes later the confirming reading shows the phone back at Home.
      gps.fresh = _at(_home, away.add(const Duration(minutes: 5)));
      now = away.add(const Duration(minutes: 5, seconds: 1));
      await tester.pump(const Duration(minutes: 5, seconds: 2));
      await settle(tester);
      expect(gps.freshReads, 1);
      expect(saved(), hasLength(1), reason: 'no place saved for the brief trip');
    });

    testWidgets('9. geocoder failure still saves the coordinates', (tester) async {
      await setUpWorld();
      places.error = Exception('geocoder unavailable');
      final tracking = start();
      await settle(tester);
      await tracking.enable();
      gps.emit(_at(_school, now));
      await settle(tester);
      expect(saved(), hasLength(1));
      expect(saved().single['placeName'], isNull);
      expect(saved().single['latitude'], _school.lat);
    });

    testWidgets('10. offline: the place waits in a queue, then uploads once, even if a response is lost',
        (tester) async {
      await setUpWorld();
      final tracking = start();
      await settle(tester);
      await tracking.enable();
      backend.offline = true;
      gps.emit(_at(_home, now));
      await settle(tester);
      expect(tracking.pendingUploads, 1);
      expect(tracking.uploadFailed, isTrue);
      expect(saved(), isEmpty);

      // Back online, but the first answer is lost after the server stored the place.
      backend.offline = false;
      backend.dropNextLocationResponse = true;
      await tester.pump(const AutomaticTrackingConfig().retryInterval);
      await settle(tester);
      expect(saved(), hasLength(1));
      expect(tracking.pendingUploads, 1, reason: 'the app did not hear back, so it keeps the place');

      // The retry is answered "duplicate": delivered, and still only one row.
      await tracking.recheck();
      await settle(tester);
      expect(tracking.pendingUploads, 0);
      expect(saved(), hasLength(1));
      expect(backend.locationPosts.where((b) => b['source'] == 'AUTOMATIC'), hasLength(2));
    });

    testWidgets('11. unsent places survive an app restart and upload oldest first', (tester) async {
      await setUpWorld();
      var tracking = start();
      await settle(tester);
      await tracking.enable();
      backend.offline = true;
      gps.emit(_at(_home, now.subtract(const Duration(hours: 2))));
      await settle(tester);
      tracking.dispose();
      services.remove(tracking);

      backend.offline = false;
      tracking = start();
      await settle(tester);
      expect(tracking.enabled, isTrue);
      expect(tracking.status, AutomaticTrackingStatus.active);
      expect(tracking.pendingUploads, 0);
      expect(saved(), hasLength(1));
      expect(os.backgroundDialogs, 1, reason: 'no dialog again after restart');
    });

    testWidgets('12. logout stops tracking and forgets that account\'s data on the phone', (tester) async {
      await setUpWorld();
      final tracking = start();
      await settle(tester);
      await tracking.enable();
      backend.offline = true;
      gps.emit(_at(_home, now));
      await settle(tester);
      expect(tracking.pendingUploads, 1);
      backend.offline = false;

      await auth.logout();
      await settle(tester);
      expect(gps.listening, isFalse);
      expect(tracking.status, AutomaticTrackingStatus.off);
      expect(tracking.enabled, isFalse);
      expect(tracking.pendingUploads, 0);
      final store = TrackingStore();
      expect(await store.isEnabled('u1'), isFalse);
      expect(await store.queue('u1'), isEmpty);
      expect(await store.lastPlace('u1'), isNull);
    });

    testWidgets('13. the next account starts off and never receives the previous account\'s places', (tester) async {
      await setUpWorld();
      final tracking = start();
      await settle(tester);
      await tracking.enable();
      backend.offline = true;
      gps.emit(_at(_home, now));
      await settle(tester);
      await auth.logout();
      backend.offline = false;
      await logIn('ravi@example.com');
      await settle(tester);
      await tester.pump(const AutomaticTrackingConfig().retryInterval);
      await settle(tester);
      expect(tracking.enabled, isFalse);
      expect(tracking.status, AutomaticTrackingStatus.off);
      expect(gps.listening, isFalse);
      expect(saved('u2'), isEmpty);
      expect(saved('u1'), isEmpty);
    });

    testWidgets('14. after a restart with permission still granted, tracking resumes without dialogs', (tester) async {
      await setUpWorld();
      os.allowLocationAllTheTime();
      await TrackingStore().setEnabled('u1', true);
      final tracking = start();
      await settle(tester);
      expect(tracking.status, AutomaticTrackingStatus.active);
      expect(gps.listening, isTrue);
      expect(os.dialogsShown, isEmpty);
      expect(os.backgroundDialogs, 0);
    });

    testWidgets('15. after a restart with permission revoked: paused, needs attention, no dialogs', (tester) async {
      await setUpWorld();
      os.os[AppPermission.location] = PermissionState.granted;
      os.backgroundLocation = PermissionState.denied;
      await TrackingStore().setEnabled('u1', true);
      final tracking = start();
      await settle(tester);
      expect(tracking.enabled, isTrue);
      expect(tracking.status, AutomaticTrackingStatus.permissionRequired);
      expect(tracking.isActive, isFalse);
      expect(gps.listening, isFalse);
      expect(os.dialogsShown, isEmpty);
      expect(os.calls.where((c) => c.startsWith('request')), isEmpty);
    });

    testWidgets('16. back in the app: a revoked permission stops tracking; fixing it resumes', (tester) async {
      await setUpWorld();
      final tracking = start();
      await settle(tester);
      await tracking.enable();
      expect(tracking.isActive, isTrue);

      os.backgroundLocation = PermissionState.denied; // revoked in Settings
      await tracking.recheck();
      expect(tracking.status, AutomaticTrackingStatus.permissionRequired);
      expect(gps.listening, isFalse);

      os.backgroundLocation = PermissionState.granted; // allowed again in Settings
      await tracking.recheck();
      expect(tracking.status, AutomaticTrackingStatus.active);
      expect(gps.listening, isTrue);
      expect(os.backgroundDialogs, 1, reason: 'rechecking never shows a dialog');
    });

    testWidgets('17. the OS ending the stream (permission revoked) is shown, not hidden', (tester) async {
      await setUpWorld();
      final tracking = start();
      await settle(tester);
      await tracking.enable();
      os.os[AppPermission.location] = PermissionState.denied;
      gps.fail(Exception('PermissionDeniedException'));
      await settle(tester);
      expect(tracking.status, AutomaticTrackingStatus.permissionRequired);
      expect(tracking.issue, TrackingIssue.locationPermission);
      expect(gps.listening, isFalse);
    });

    testWidgets('18. a point the server refuses, or one too old, is dropped instead of retried forever', (tester) async {
      await setUpWorld();
      await TrackingStore().setQueue('u1', [_at(_home, now.subtract(const Duration(days: 9)))]);
      final tracking = start();
      await settle(tester);
      expect(tracking.pendingUploads, 0);
      expect(backend.locationPosts, isEmpty, reason: 'too old to send');

      backend.locationFailureStatus = 400;
      await tracking.enable();
      gps.emit(_at(_home, now));
      await settle(tester);
      expect(tracking.pendingUploads, 0);
    });

    testWidgets('19. a platform without background location says so and never asks', (tester) async {
      await setUpWorld();
      gps.isSupported = false;
      final tracking = start();
      await settle(tester);
      await tracking.enable();
      expect(tracking.status, AutomaticTrackingStatus.error);
      expect(tracking.issue, TrackingIssue.unsupported);
      expect(os.dialogsShown, isEmpty);
    });
  });

  group('Automatic Location History in the app', () {
    late FakeBackend backend;
    late FakePermissionService os;
    late FakeBackgroundLocationSource gps;
    late AppServices services;

    Future<void> startApp(WidgetTester tester, {void Function()? seed}) async {
      tester.view.physicalSize = const Size(420, 5000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      backend = FakeBackend();
      os = FakePermissionService();
      gps = FakeBackgroundLocationSource();
      seed?.call();
      services = backend.services(os, backgroundLocationSource: gps);
      await services.authService.restoreSession();
      await tester.pumpWidget(MyApp(services: services));
      await tester.pumpAndSettle();
      await logIn(tester, 'mansi@example.com');
    }

    Finder status(String text) => find.textContaining('Status: $text', findRichText: true);

    Future<void> tapSwitch(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('automatic-tracking-switch')));
      await tester.pumpAndSettle();
    }

    testWidgets('the Location tab shows Automatic Location History off; Not now asks nothing', (tester) async {
      await startApp(tester);
      await openTab(tester, 'Location');
      expect(find.text('Automatic Location History'), findsOneWidget);
      expect(find.textContaining('Automatically save significant places you visit'), findsOneWidget);
      expect(status('Tracking off'), findsOneWidget);
      expect(tester.widget<Switch>(find.byKey(const ValueKey('automatic-tracking-switch'))).value, isFalse);

      await tapSwitch(tester);
      expect(find.byKey(const ValueKey('automatic-tracking-explanation')), findsOneWidget);
      expect(find.textContaining('even when the app is closed'), findsOneWidget);
      expect(find.textContaining('may use additional battery'), findsOneWidget);
      expect(find.textContaining('stop it at any time'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(os.dialogsShown, isEmpty);
      expect(os.backgroundDialogs, 0);
      expect(status('Tracking off'), findsOneWidget);
      expect(gps.listening, isFalse);
    });

    testWidgets('Continue asks the OS, then shows Tracking active here and on the Dashboard', (tester) async {
      await startApp(tester);
      await openTab(tester, 'Location');
      await tapSwitch(tester);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(os.dialogsShown, contains(AppPermission.location));
      expect(os.backgroundDialogs, 1);
      expect(status('Tracking active'), findsOneWidget);
      expect(gps.listening, isTrue);
      expect(find.text('Automatic Location History is on.'), findsOneWidget);
      // The phone's foreground location permission is mirrored to the account (for chat).
      expect(backend.permissions['u1']?['LOCATION'], 'GRANTED');

      await openTab(tester, 'Dashboard');
      expect(
        find.descendant(of: find.byKey(const ValueKey('dashboard-tracking-card')), matching: find.text('Tracking active')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('dashboard-tracking-card')));
      await tester.pumpAndSettle();
      expect(find.text('My Location'), findsOneWidget, reason: 'the card opens the Location tab');
    });

    testWidgets('background permission denied: Paused, with how to fix it', (tester) async {
      await startApp(tester);
      os.onBackgroundRequest = PermissionState.permanentlyDenied;
      await openTab(tester, 'Location');
      await tapSwitch(tester);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(status('Tracking active'), findsNothing);
      expect(status('Paused'), findsOneWidget);
      expect(find.text('Automatic location history is paused because location permission needs attention.'), findsOneWidget);
      expect(find.textContaining('Allow all the time'), findsOneWidget);
      await tester.tap(find.text('Open Settings'));
      await tester.pumpAndSettle();
      expect(os.settingsOpened, 1);
    });

    testWidgets("Today's Travel and history show automatic and manual places, marked", (tester) async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      await startApp(tester, seed: () {
        backend.seedLocation('u1', today.add(const Duration(minutes: 1)), placeName: 'Home', source: 'AUTOMATIC');
        backend.seedLocation('u1', today.add(const Duration(minutes: 2)), placeName: 'Library');
        backend.seedLocation('u1', today.add(const Duration(minutes: 3)), source: 'AUTOMATIC', latitude: 20.35);
        backend.seedLocation('u1', today.subtract(const Duration(hours: 12)), placeName: 'Park', source: 'AUTOMATIC');
      });
      await openTab(tester, 'Location');
      final todayCard = find.byKey(const ValueKey('today-travel'));
      expect(todayCard, findsOneWidget);
      Finder inToday(Finder f) => find.descendant(of: todayCard, matching: f);
      expect(inToday(find.text('Home')), findsOneWidget);
      expect(inToday(find.text('Library')), findsOneWidget);
      expect(inToday(find.text('Location unavailable')), findsOneWidget);
      expect(inToday(find.text('20.35, 85.8245')), findsOneWidget);
      expect(inToday(find.text('Park')), findsNothing, reason: 'yesterday is not today');
      expect(inToday(find.text('Auto')), findsNWidgets(2));
      expect(inToday(find.text('Manual')), findsOneWidget);

      // Date search: Yesterday includes the automatic place.
      await tapVisible(tester, find.byKey(const ValueKey('history-filter-yesterday')));
      expect(find.byKey(const ValueKey('location-loc4')), findsOneWidget);
      expect(find.byKey(const ValueKey('source-loc4')), findsOneWidget);
    });

    testWidgets('logout stops tracking; the next account starts off and sees none of it', (tester) async {
      await startApp(tester);
      await openTab(tester, 'Location');
      await tapSwitch(tester);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      gps.emit(_at(_home, DateTime.now()));
      await tester.pumpAndSettle();
      expect(backend.locations['u1'], hasLength(1));
      expect(find.descendant(of: find.byKey(const ValueKey('today-travel')), matching: find.text('Jayadev Vihar')),
          findsOneWidget, reason: 'the new place appears without a manual refresh');

      await logOut(tester);
      expect(gps.listening, isFalse);
      expect(services.automaticTrackingService.status, AutomaticTrackingStatus.off);

      await logIn(tester, 'ravi@example.com');
      await openTab(tester, 'Location');
      expect(status('Tracking off'), findsOneWidget);
      expect(find.text('Jayadev Vihar'), findsNothing);
      expect(backend.locations['u2'] ?? [], isEmpty);
    });

    testWidgets('chat shows automatic places from the location history tool', (tester) async {
      await startApp(tester);
      backend.chatResponder = (_) => const FakeChatReply(
            'I found these saved locations from your automatic location history.',
            toolEvents: [
              {
                'kind': 'location_history',
                'status': 'success',
                'data': {
                  'count': 2,
                  'hasMore': false,
                  'locations': [
                    {'capturedAt': '2026-10-06T02:40:00.000Z', 'placeName': 'Home', 'latitude': 20.29, 'longitude': 85.82, 'source': 'AUTOMATIC'},
                    {'capturedAt': '2026-10-06T03:30:00.000Z', 'placeName': 'School', 'latitude': 20.35, 'longitude': 85.81, 'source': 'MANUAL'},
                  ],
                },
              },
            ],
          );
      await openTab(tester, 'Chat');
      await tester.enterText(find.byType(TextField), 'Where did I go yesterday?');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(backend.chatRequests.single['message'], 'Where did I go yesterday?');
      expect(find.text('I found these saved locations from your automatic location history.'), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(find.textContaining('• Automatic'), findsOneWidget, reason: 'only the automatic place is marked');
    });
  });

  group('Voice question about travel history', () {
    testWidgets('speech becomes a normal chat message and the reply is read aloud', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      final backend = FakeBackend();
      final os = FakePermissionService()..os[AppPermission.microphone] = PermissionState.granted;
      final voice = FakeVoiceInput();
      final tts = FakeTextToSpeech();
      final services = backend.services(os, voiceInput: voice, textToSpeech: tts);
      backend.chatResponder = (_) => const FakeChatReply('I found a saved location at Home at 8:10 AM.');
      await services.authService.restoreSession();
      await tester.pumpWidget(MyApp(services: services));
      await tester.pumpAndSettle();
      await logIn(tester, 'mansi@example.com');
      await openTab(tester, 'Chat');
      await tester.tap(find.byTooltip('Voice replies: off'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Voice input'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      voice.finish('Where did I go yesterday?');
      await tester.pumpAndSettle();

      expect(backend.chatRequests, hasLength(1));
      expect(backend.chatRequests.single['message'], 'Where did I go yesterday?');
      expect(backend.chatRequests.single.containsKey('audio'), isFalse, reason: 'no audio is ever sent or stored');
      expect(tts.spoken, ['I found a saved location at Home at 8:10 AM.']);
    });
  });
}
