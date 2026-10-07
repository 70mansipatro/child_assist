import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart' show Placemark;

import 'package:child_assist/core/permissions/permission_service.dart';
import 'package:child_assist/features/location/models/location_record.dart';
import 'package:child_assist/features/location/screens/location_screen.dart';
import 'package:child_assist/features/location/services/location_service.dart';
import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

final _at = DateTime.utc(2026, 10, 6, 5, 0);

DeviceLocation _gps({double lat = 20.2961, double lng = 85.8245, double? accuracy = 12.4}) =>
    DeviceLocation(latitude: lat, longitude: lng, accuracy: accuracy, capturedAt: _at);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('DeviceLocation place details', () {
    test('converts a full placemark', () {
      final loc = _gps().withPlacemark(const Placemark(
        name: 'Jayadev Vihar',
        street: 'Jayadev Vihar',
        subLocality: 'Nayapalli',
        locality: 'Bhubaneswar',
        subAdministrativeArea: 'Khordha',
        administrativeArea: 'Odisha',
        postalCode: '751013',
        country: 'India',
        isoCountryCode: 'IN',
      ));
      expect(loc.latitude, 20.2961);
      expect(loc.accuracy, 12.4);
      expect(loc.capturedAt, _at);
      expect(loc.placeName, 'Jayadev Vihar');
      expect(loc.city, 'Bhubaneswar');
      expect(loc.state, 'Odisha');
      expect(loc.postalCode, '751013');
      expect(loc.isoCountryCode, 'IN');
      expect(loc.areaLine, 'Bhubaneswar, Odisha, India');
      // The repeated "Jayadev Vihar" (name and street) appears once.
      expect(loc.address, 'Jayadev Vihar, Nayapalli, Bhubaneswar, Odisha, India');
      expect(loc.hasPlace, isTrue);
    });

    test('Android placemark: the formatted line in `street` is the address, not repeated', () {
      // Shape returned by the Pixel 7 emulator's native geocoder.
      const line = '786/92, near 7th battalion square, Doordarshan Colony, Gajapati Nagar, '
          'Bhubaneswar, Odisha 751013, India';
      final loc = _gps().withPlacemark(const Placemark(
        name: 'Gajapati Nagar',
        street: line,
        subLocality: 'Gajapati Nagar',
        locality: 'Bhubaneswar',
        subAdministrativeArea: 'Khordha',
        administrativeArea: 'Odisha',
        postalCode: '751013',
        country: 'India',
      ));
      expect(loc.placeName, 'Gajapati Nagar');
      expect(loc.areaLine, 'Bhubaneswar, Odisha, India');
      expect(loc.address, line);
      expect(loc.street, isNull, reason: 'no thoroughfare reported');

      final withRoad = _gps().withPlacemark(const Placemark(
          name: 'KIIT Campus', street: '12, KIIT Rd, Bhubaneswar, Odisha 751024, India',
          thoroughfare: 'KIIT Rd', subThoroughfare: '12', locality: 'Bhubaneswar'));
      expect(withRoad.street, '12 KIIT Rd');
      expect(withRoad.address, 'KIIT Campus, 12, KIIT Rd, Bhubaneswar, Odisha 751024, India');
    });

    test('blank and missing fields become null; no place at all is handled', () {
      final loc = _gps().withPlacemark(const Placemark(name: '  ', street: '', country: null));
      expect(loc.name, isNull);
      expect(loc.street, isNull);
      expect(loc.placeName, isNull);
      expect(loc.address, isNull);
      expect(loc.areaLine, isNull);
      expect(loc.hasPlace, isFalse);
      expect(_gps().placeName, isNull);
    });

    test('place name falls back: name -> locality -> district -> state', () {
      expect(_gps().withPlacemark(const Placemark(locality: 'Bhubaneswar', administrativeArea: 'Odisha')).placeName,
          'Bhubaneswar');
      expect(_gps().withPlacemark(const Placemark(subAdministrativeArea: 'Khordha', administrativeArea: 'Odisha')).placeName,
          'Khordha');
      expect(_gps().withPlacemark(const Placemark(administrativeArea: 'Odisha', country: 'India')).placeName, 'Odisha');
    });

    test('house numbers and Plus Codes are not used as the place name', () {
      final numbered = _gps().withPlacemark(const Placemark(
          name: '221', street: '221 KIIT Road', locality: 'Bhubaneswar', administrativeArea: 'Odisha'));
      expect(numbered.placeName, 'Bhubaneswar');
      expect(numbered.address, 'Bhubaneswar, 221 KIIT Road, Odisha');

      final plusCode = _gps().withPlacemark(const Placemark(name: '7MXF+2Q', locality: 'Puri'));
      expect(plusCode.placeName, 'Puri');
    });

    test('city-only place does not repeat itself', () {
      final loc = _gps().withPlacemark(
          const Placemark(locality: 'Bhubaneswar', administrativeArea: 'Odisha', country: 'India'));
      expect(loc.placeName, 'Bhubaneswar');
      expect(loc.areaLine, 'Odisha, India');
      expect(loc.address, 'Bhubaneswar, Odisha, India');
    });

    test('joinParts drops empties and case-insensitive repeats', () {
      expect(joinParts(['A', null, ' ', 'a', 'B', 'b ', 'C']), 'A, B, C');
      expect(joinParts([null, '']), isNull);
      expect(joinParts(['X', 'Y'], exclude: ['x']), 'Y');
    });
  });

  group('LocationRecord.fromJson', () {
    test('parses a server record with place details', () {
      final r = LocationRecord.fromJson({
        'id': 'abc123',
        'latitude': 20.2961,
        'longitude': 85.8245,
        'accuracy': 12.5,
        'placeName': 'Jayadev Vihar',
        'address': 'Jayadev Vihar, Bhubaneswar, Odisha, India',
        'city': 'Bhubaneswar',
        'state': 'Odisha',
        'country': 'India',
        'capturedAt': '2026-10-06T10:30:00.000Z',
      });
      expect(r.id, 'abc123');
      expect(r.latitude, 20.2961);
      expect(r.accuracy, 12.5);
      expect(r.placeName, 'Jayadev Vihar');
      expect(r.address, 'Jayadev Vihar, Bhubaneswar, Odisha, India');
      expect(r.areaLine, 'Bhubaneswar, Odisha, India');
      expect(r.capturedAt.toUtc(), DateTime.utc(2026, 10, 6, 10, 30));
      expect(r.capturedAt.isUtc, isFalse, reason: 'shown in local time');
    });

    test('accepts numeric strings and missing/blank place fields', () {
      final r = LocationRecord.fromJson({
        'id': 'x',
        'latitude': 20,
        'longitude': '85.5',
        'accuracy': null,
        'placeName': '  ',
        'capturedAt': '2026-10-06T10:30:00Z',
      });
      expect(r.latitude, 20.0);
      expect(r.longitude, 85.5);
      expect(r.accuracy, isNull);
      expect(r.placeName, isNull);
      expect(r.areaLine, isNull);
    });

    test('rejects malformed records', () {
      final valid = {'id': 'x', 'latitude': 1, 'longitude': 1, 'capturedAt': '2026-10-06T10:30:00Z'};
      for (final broken in [
        {...valid, 'id': null},
        {...valid, 'latitude': 'north'},
        {...valid, 'longitude': null},
        {...valid, 'capturedAt': 'yesterday'},
      ]) {
        expect(() => LocationRecord.fromJson(broken), throwsFormatException, reason: '$broken');
      }
    });
  });

  group('formatting', () {
    final now = DateTime(2026, 10, 6, 15, 0);
    test('captured-at labels', () {
      expect(formatCapturedAt(DateTime(2026, 10, 6, 10, 30), now: now), 'Today, 10:30 AM');
      expect(formatCapturedAt(DateTime(2026, 10, 5, 18, 20), now: now), 'Yesterday, 6:20 PM');
      expect(formatCapturedAt(DateTime(2026, 9, 30, 0, 5), now: now), '30 Sep 2026, 12:05 AM');
    });
    test('updated, accuracy and coordinates', () {
      expect(formatUpdated(now.subtract(const Duration(seconds: 20)), now: now), 'Just now');
      expect(formatUpdated(now.subtract(const Duration(minutes: 5)), now: now), '5 min ago');
      expect(formatAccuracy(12.4), '12 m');
      expect(formatAccuracy(null), 'Unknown');
      expect(formatCoordinate(20.2961), '20.2961');
      expect(formatCoordinate(-33.86880049), '-33.8688');
      expect(formatCoordinate(10), '10');
    });
  });

  group('LocationService', () {
    late FakePermissionService os;
    late FakeLocationProvider gps;
    late FakePlaceLookup geocoder;
    late LocationService service;

    setUp(() {
      os = FakePermissionService();
      gps = FakeLocationProvider();
      geocoder = FakePlaceLookup();
      service = LocationService(permissionService: os, provider: gps, placeLookup: geocoder);
    });

    test('success: asks once, reads the position and reverse geocodes it', () async {
      final result = await service.getCurrentLocation();
      expect(result.isSuccess, isTrue);
      expect(result.location!.latitude, 20.2961);
      expect(result.location!.placeName, 'Jayadev Vihar');
      expect(result.location!.areaLine, 'Bhubaneswar, Odisha, India');
      expect(result.permission, PermissionState.granted);
      expect(os.dialogsShown, [AppPermission.location]);

      await service.getCurrentLocation();
      expect(os.dialogsShown, hasLength(1), reason: 'already granted: no second dialog');
      expect(gps.reads, 2);
      expect(geocoder.lookups, 2);
    });

    test('a failed, empty or slow place lookup still returns the coordinates', () async {
      geocoder.error = StateError('geocoder offline');
      var result = await service.getCurrentLocation();
      expect(result.isSuccess, isTrue);
      expect(result.location!.latitude, 20.2961);
      expect(result.location!.hasPlace, isFalse);

      geocoder
        ..error = null
        ..placemark = null;
      result = await service.getCurrentLocation();
      expect(result.isSuccess, isTrue);
      expect(result.location!.hasPlace, isFalse);

      final slow = LocationService(
        permissionService: os,
        provider: gps,
        placeLookup: _NeverAnswers(),
        placeTimeLimit: const Duration(milliseconds: 10),
      );
      result = await slow.getCurrentLocation();
      expect(result.isSuccess, isTrue);
      expect(result.location!.hasPlace, isFalse);
    });

    test('location services off: no dialog, no read, no lookup', () async {
      gps.serviceEnabled = false;
      final result = await service.getCurrentLocation();
      expect(result.failure, LocationFailure.servicesDisabled);
      expect(os.dialogsShown, isEmpty);
      expect(gps.reads, 0);
      expect(geocoder.lookups, 0);
    });

    test('denied, permanently denied and restricted never read the position', () async {
      os.onRequest[AppPermission.location] = PermissionState.denied;
      expect((await service.getCurrentLocation()).failure, LocationFailure.permissionDenied);

      os.onRequest[AppPermission.location] = PermissionState.permanentlyDenied;
      expect((await service.getCurrentLocation()).failure, LocationFailure.permissionPermanentlyDenied);
      // Blocked: the OS will not show a dialog again.
      expect((await service.getCurrentLocation()).failure, LocationFailure.permissionPermanentlyDenied);
      expect(os.dialogsShown, hasLength(2));

      os.os[AppPermission.location] = PermissionState.restricted;
      expect((await service.getCurrentLocation()).failure, LocationFailure.permissionRestricted);
      expect(gps.reads, 0);
    });

    test('GPS timeouts and plugin errors are reported, not thrown', () async {
      gps.error = TimeoutException('no fix');
      expect((await service.getCurrentLocation()).failure, LocationFailure.timeout);
      gps.error = StateError('hardware gone');
      expect((await service.getCurrentLocation()).failure, LocationFailure.unavailable);
      expect(geocoder.lookups, 0);
    });
  });

  group('LocationScreen', () {
    late FakeBackend backend;
    late FakePermissionService os;
    late FakeLocationProvider gps;
    late FakePlaceLookup geocoder;

    Future<void> startApp(WidgetTester tester, {String email = 'mansi@example.com'}) async {
      // A tall phone-sized screen, so the whole Location page is laid out at once.
      tester.view.physicalSize = const Size(420, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      backend = FakeBackend();
      os = FakePermissionService();
      gps = FakeLocationProvider();
      geocoder = FakePlaceLookup();
      final services = backend.services(os, locationProvider: gps, placeLookup: geocoder);
      await services.authService.restoreSession();
      await tester.pumpWidget(MyApp(services: services));
      await logIn(tester, email);
    }

    Future<void> tapGetLocation(WidgetTester tester) =>
        tapVisible(tester, find.textContaining(RegExp(r'^(Get Current|Refresh) Location$')));

    Finder inCurrentCard(Finder finder) =>
        find.descendant(of: find.byKey(const ValueKey('location-current')), matching: finder);
    Finder currentCard(String text) => inCurrentCard(find.text(text));
    Finder historyItem(String id) => find.byKey(ValueKey('location-$id'));

    testWidgets('Location is a bottom-navigation tab', (tester) async {
      await startApp(tester);
      expect(dashboard(), findsOneWidget);
      expect(find.descendant(of: find.byType(NavigationBar), matching: find.text('Location')), findsOneWidget);
      expect(find.byType(LocationScreen), findsNothing, reason: 'tabs are built when first opened');
    });

    testWidgets('opening the screen does not ask for permission', (tester) async {
      await startApp(tester);
      await openFromHome(tester, 'Location');

      expect(find.text('My Location'), findsOneWidget);
      expect(os.dialogsShown, isEmpty);
      expect(gps.reads, 0);
      expect(find.textContaining('does not track your location continuously'), findsOneWidget);
      expect(currentCard('Tap "Get Current Location" to see your real device location.'), findsOneWidget);
      expect(find.text('No location history yet.'), findsOneWidget);
      expect(find.textContaining('Your saved locations will appear here'), findsOneWidget);
      expect(find.byKey(const ValueKey('location-failure')), findsNothing);
      final clear = tester.widget<OutlinedButton>(
          find.ancestor(of: find.text('Clear Location History'), matching: find.bySubtype<OutlinedButton>()));
      expect(clear.onPressed, isNull, reason: 'nothing to clear yet');
    });

    testWidgets('shows "Getting location..." and ignores taps while busy', (tester) async {
      await startApp(tester);
      final pending = Completer<DeviceLocation>();
      gps.pending = pending;
      await openFromHome(tester, 'Location');

      await tester.tap(find.text('Get Current Location'));
      await tester.pump();
      expect(currentCard('Getting location...'), findsOneWidget);
      expect(find.textContaining('Please wait while we get your current location'), findsOneWidget);
      final button = tester.widget<FilledButton>(
          find.ancestor(of: find.text('Getting location...').last, matching: find.bySubtype<FilledButton>()));
      expect(button.onPressed, isNull);

      pending.complete(_gps());
      await tester.pumpAndSettle();
      expect(gps.reads, 1);
      expect(backend.locations['u1'], hasLength(1));
    });

    testWidgets('Get Current Location -> allow -> place shown, saved and listed', (tester) async {
      await startApp(tester);
      await openFromHome(tester, 'Location');
      await tapGetLocation(tester);

      expect(os.dialogsShown, [AppPermission.location]);
      expect(currentCard('Location updated'), findsOneWidget);
      expect(currentCard('Jayadev Vihar'), findsOneWidget);
      expect(currentCard('Bhubaneswar, Odisha, India'), findsOneWidget);
      expect(currentCard('20.2961'), findsOneWidget);
      expect(currentCard('85.8245'), findsOneWidget);
      expect(currentCard('12 m'), findsOneWidget);
      expect(currentCard('Just now'), findsOneWidget);
      expect(find.text('Refresh Location'), findsOneWidget);

      final saved = backend.locations['u1']!.single;
      expect(saved['latitude'], 20.2961);
      expect(saved['placeName'], 'Jayadev Vihar');
      expect(saved['address'], 'Jayadev Vihar, Bhubaneswar, Odisha, India');
      expect(saved['street'], 'Jayadev Vihar');
      expect(saved['locality'], 'Bhubaneswar');
      expect(saved['city'], 'Bhubaneswar');
      expect(saved['state'], 'Odisha');
      expect(saved['postalCode'], '751013');
      expect(saved['country'], 'India');
      expect(backend.permissions['u1']!['LOCATION'], 'GRANTED');

      final first = historyItem('loc1');
      expect(find.descendant(of: first, matching: find.text('Jayadev Vihar')), findsOneWidget);
      expect(find.descendant(of: first, matching: find.text('Bhubaneswar, Odisha, India')), findsOneWidget);
      expect(find.descendant(of: first, matching: find.text('20.2961, 85.8245')), findsOneWidget);
      expect(find.descendant(of: first, matching: find.textContaining(RegExp(r'^Today, .* • Accuracy: 12 m$'))),
          findsOneWidget);

      // Refresh Location saves a second record; newest first.
      gps.position = _gps(lat: 20.3547, lng: 85.8175, accuracy: 18);
      geocoder.placemark = const Placemark(
          name: 'KIIT Road', locality: 'Bhubaneswar', administrativeArea: 'Odisha', country: 'India');
      await tapGetLocation(tester);
      expect(backend.locations['u1'], hasLength(2));
      expect(os.dialogsShown, hasLength(1));
      expect(currentCard('KIIT Road'), findsOneWidget);
      final items = find.byWidgetPredicate(
          (w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('location-loc'));
      expect(items, findsNWidgets(2));
      expect(tester.widget(items.first).key, const ValueKey('location-loc2'));
    });

    testWidgets('reverse geocoding failure: coordinates shown and saved without a place', (tester) async {
      await startApp(tester);
      geocoder.error = StateError('no geocoder');
      await openFromHome(tester, 'Location');
      await tapGetLocation(tester);

      expect(currentCard('20.2961, 85.8245'), findsOneWidget);
      expect(currentCard('Place name unavailable'), findsOneWidget);
      expect(currentCard('Location updated'), findsOneWidget);
      expect(find.text('Refresh Location'), findsOneWidget);

      final saved = backend.locations['u1']!.single;
      expect(saved['latitude'], 20.2961);
      expect(saved['placeName'], isNull);
      expect(saved['address'], isNull);
      expect(find.descendant(of: historyItem('loc1'), matching: find.text('20.2961, 85.8245')), findsOneWidget);
      expect(find.descendant(of: historyItem('loc1'), matching: find.text('Place name unavailable')), findsOneWidget);
    });

    testWidgets('denied permission shows Allow Location, which asks again', (tester) async {
      await startApp(tester);
      os.onRequest[AppPermission.location] = PermissionState.denied;
      await openFromHome(tester, 'Location');
      await tapGetLocation(tester);

      expect(find.text('Location permission is required to get your current location.'), findsOneWidget);
      expect(gps.reads, 0);
      expect(backend.locations['u1'] ?? [], isEmpty);

      os.onRequest[AppPermission.location] = PermissionState.granted;
      await tapVisible(tester, find.text('Allow Location'));
      expect(os.dialogsShown, hasLength(2));
      expect(find.byKey(const ValueKey('location-failure')), findsNothing);
      expect(backend.locations['u1'], hasLength(1));
    });

    testWidgets('permanently denied shows Open Settings; returning from Settings re-checks', (tester) async {
      await startApp(tester);
      os.os[AppPermission.location] = PermissionState.permanentlyDenied;
      await openFromHome(tester, 'Location');

      // Shown from a status check alone, without any dialog.
      expect(find.textContaining('Location permission is blocked.'), findsOneWidget);
      expect(find.textContaining('from your device Settings'), findsOneWidget);
      expect(os.dialogsShown, isEmpty);
      await tapVisible(tester, find.text('Open Settings'));
      expect(os.settingsOpened, 1);

      os.os[AppPermission.location] = PermissionState.granted;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('location-failure')), findsNothing);

      await tapGetLocation(tester);
      expect(backend.locations['u1'], hasLength(1));
    });

    testWidgets('location services off shows Open Settings for location', (tester) async {
      await startApp(tester);
      gps.serviceEnabled = false;
      await openFromHome(tester, 'Location');
      await tapGetLocation(tester);

      expect(find.textContaining('Location services are turned off.'), findsOneWidget);
      expect(os.dialogsShown, isEmpty);
      expect(gps.reads, 0);
      await tapVisible(tester, find.text('Open Settings'));
      expect(gps.settingsOpened, 1);
      expect(os.settingsOpened, 0);
    });

    testWidgets('unavailable GPS asks the user to try again', (tester) async {
      await startApp(tester);
      gps.error = TimeoutException('no fix');
      await openFromHome(tester, 'Location');
      await tapGetLocation(tester);
      expect(find.textContaining('Location is currently unavailable.'), findsOneWidget);
      expect(backend.locations['u1'] ?? [], isEmpty);
    });

    testWidgets('clear history asks first and only clears on confirm', (tester) async {
      await startApp(tester);
      await openFromHome(tester, 'Location');
      await tapGetLocation(tester);
      await tapGetLocation(tester);
      expect(backend.locations['u1'], hasLength(2));

      await tapVisible(tester, find.text('Clear Location History'));
      expect(find.text('Clear Location History?'), findsOneWidget);
      expect(find.textContaining('permanently delete'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(backend.locations['u1'], hasLength(2));

      await tapVisible(tester, find.text('Clear Location History'));
      await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
      await tester.pumpAndSettle();
      expect(backend.locations['u1'], isEmpty);
      expect(find.text('Deleted 2 saved locations'), findsOneWidget);
      expect(find.text('No location history yet.'), findsOneWidget);
    });

    testWidgets('API errors are shown without crashing', (tester) async {
      await startApp(tester);
      backend.locationFailureStatus = 500;
      await openFromHome(tester, 'Location');
      expect(find.textContaining('Could not load your location history'), findsOneWidget);

      await tapGetLocation(tester);
      // The reading is still shown even though saving failed.
      expect(currentCard('Jayadev Vihar'), findsOneWidget);
      expect(currentCard('Location updated'), findsNothing);
      expect(find.textContaining('Could not save this location'), findsOneWidget);

      backend.locationFailureStatus = null;
      await tapVisible(tester, find.text('Refresh'));
      expect(find.textContaining('Could not load'), findsNothing);
      expect(find.text('No location history yet.'), findsOneWidget);
    });

    testWidgets('each user sees only their own locations', (tester) async {
      await startApp(tester);
      await openFromHome(tester, 'Location');
      await tapGetLocation(tester);
      await logOut(tester);

      await logIn(tester, 'ravi@example.com');
      await openFromHome(tester, 'Location');
      expect(find.text('No location history yet.'), findsOneWidget);
      expect(find.text('Jayadev Vihar'), findsNothing);

      gps.position = _gps(lat: 28.6139, lng: 77.209);
      geocoder.placemark = const Placemark(name: 'Connaught Place', locality: 'New Delhi', country: 'India');
      await tapGetLocation(tester);
      expect(find.descendant(of: historyItem('loc2'), matching: find.text('Connaught Place')), findsOneWidget);
      await logOut(tester);

      await logIn(tester, 'mansi@example.com');
      await openFromHome(tester, 'Location');
      expect(find.descendant(of: historyItem('loc1'), matching: find.text('Jayadev Vihar')), findsOneWidget);
      expect(find.text('Connaught Place'), findsNothing);
      expect(backend.locations['u1']!.single['placeName'], 'Jayadev Vihar');
      expect(backend.locations['u2']!.single['placeName'], 'Connaught Place');
    });

    testWidgets('logout closes the Location screen and forgets the history', (tester) async {
      await startApp(tester);
      await openFromHome(tester, 'Location');
      await tapGetLocation(tester);
      final services = tester.widget<MyApp>(find.byType(MyApp)).services;
      await services.authService.logout();
      await tester.pumpAndSettle();
      expect(find.text('My Location'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Log in'), findsOneWidget);
      expect(services.locationHistoryService.records, isEmpty);
    });
  });
}

class _NeverAnswers implements PlaceLookup {
  @override
  Future<Placemark?> placemarkAt(double latitude, double longitude) => Completer<Placemark?>().future;
}
