import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/core/permissions/permission_service.dart';
import 'package:child_assist/features/location/models/location_history_filter.dart';
import 'package:child_assist/features/location/services/location_history_service.dart';
import 'package:child_assist/features/location/services/location_service.dart';
import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

final _searchButton = find.ancestor(of: find.text('Search History'), matching: find.bySubtype<FilledButton>());

/// Wednesday, 7 October 2026, mid-afternoon local time.
final _wednesday = DateTime(2026, 10, 7, 14, 30);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('resolveHistoryRange (local calendar, weeks Monday to Sunday)', () {
    HistoryDateRange r(String start, String end) => HistoryDateRange(DateTime.parse(start), DateTime.parse(end));

    test('today, yesterday and the day before yesterday', () {
      expect(resolveHistoryRange(LocationHistoryFilter.today, _wednesday), r('2026-10-07', '2026-10-07'));
      expect(resolveHistoryRange(LocationHistoryFilter.yesterday, _wednesday), r('2026-10-06', '2026-10-06'));
      expect(resolveHistoryRange(LocationHistoryFilter.dayBeforeYesterday, _wednesday), r('2026-10-05', '2026-10-05'));
      // Just after local midnight is still the new day, whatever the UTC date is.
      final earlyMorning = DateTime(2026, 10, 7, 0, 5);
      expect(resolveHistoryRange(LocationHistoryFilter.today, earlyMorning), r('2026-10-07', '2026-10-07'));
    });

    test('this week and last week', () {
      expect(resolveHistoryRange(LocationHistoryFilter.thisWeek, _wednesday), r('2026-10-05', '2026-10-07'));
      expect(resolveHistoryRange(LocationHistoryFilter.lastWeek, _wednesday), r('2026-09-28', '2026-10-04'));
      final monday = DateTime(2026, 10, 5, 9);
      expect(resolveHistoryRange(LocationHistoryFilter.thisWeek, monday), r('2026-10-05', '2026-10-05'));
      final sunday = DateTime(2026, 10, 11, 21);
      expect(resolveHistoryRange(LocationHistoryFilter.thisWeek, sunday), r('2026-10-05', '2026-10-11'));
      expect(resolveHistoryRange(LocationHistoryFilter.lastWeek, DateTime(2026, 1, 1)), r('2025-12-22', '2025-12-28'));
    });

    test('this month and last month', () {
      expect(resolveHistoryRange(LocationHistoryFilter.thisMonth, _wednesday), r('2026-10-01', '2026-10-07'));
      expect(resolveHistoryRange(LocationHistoryFilter.lastMonth, _wednesday), r('2026-09-01', '2026-09-30'));
      expect(resolveHistoryRange(LocationHistoryFilter.lastMonth, DateTime(2026, 1, 15)), r('2025-12-01', '2025-12-31'));
      expect(resolveHistoryRange(LocationHistoryFilter.lastMonth, DateTime(2024, 3, 31)), r('2024-02-01', '2024-02-29'));
    });

    test('this year', () {
      expect(resolveHistoryRange(LocationHistoryFilter.thisYear, _wednesday), r('2026-01-01', '2026-10-07'));
      expect(resolveHistoryRange(LocationHistoryFilter.yesterday, DateTime(2026, 1, 1, 8)), r('2025-12-31', '2025-12-31'));
    });

    test('custom date and custom range queries', () {
      final date = LocationHistoryQuery.date(DateTime(2026, 10, 5, 18, 40));
      expect(date.filter, LocationHistoryFilter.customDate);
      expect(date.range, r('2026-10-05', '2026-10-05'));
      expect(date.range!.isSingleDay, isTrue);
      final range = LocationHistoryQuery.range(DateTime(2026, 10, 1), DateTime(2026, 10, 7));
      expect(range.filter, LocationHistoryFilter.customRange);
      expect(range.range!.days, 7);
      expect(const LocationHistoryQuery.recent().isRecent, isTrue);
      expect(() => LocationHistoryQuery.preset(LocationHistoryFilter.customDate), throwsArgumentError);
    });

    test('date validation', () {
      expect(validateHistoryRange(r('2026-10-01', '2026-10-07'), now: _wednesday), isNull);
      expect(validateHistoryRange(r('2026-10-07', '2026-10-01'), now: _wednesday), contains('on or after'));
      expect(validateHistoryRange(r('2026-10-08', '2026-10-08'), now: _wednesday), contains('future'));
      expect(validateHistoryRange(r('2024-01-01', '2024-12-31'), now: _wednesday), isNull, reason: 'a leap year is one year');
      expect(validateHistoryRange(r('2025-01-01', '2026-01-02'), now: _wednesday), contains('one year or less'));
    });

    test('formatting', () {
      expect(formatApiDate(DateTime(2026, 10, 5, 23, 59)), '2026-10-05');
      expect(formatLongDate(DateTime(2026, 10, 5)), '5 October 2026');
      expect(formatShortDate(DateTime(2026, 10, 5)), '05 Oct 2026');
      expect(formatRangeLabel(r('2026-10-05', '2026-10-05')), '5 October 2026');
      expect(formatRangeLabel(r('2026-10-01', '2026-10-07')), '1 October 2026 – 7 October 2026');
    });
  });

  group('Location history search', () {
    late FakeBackend backend;
    late FakePermissionService os;
    late FakeLocationProvider gps;
    late DateTime today;

    /// Local time on a day relative to today.
    DateTime at(int daysAgo, int hour, int minute) => DateTime(today.year, today.month, today.day - daysAgo, hour, minute);

    Future<void> startApp(WidgetTester tester, {void Function()? seed, double width = 420}) async {
      tester.view.physicalSize = Size(width, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      backend = FakeBackend();
      os = FakePermissionService();
      gps = FakeLocationProvider();
      today = DateUtils.dateOnly(DateTime.now());
      seed?.call();
      final services = backend.services(os, locationProvider: gps, placeLookup: FakePlaceLookup());
      await services.authService.restoreSession();
      await tester.pumpWidget(MyApp(services: services));
      await logIn(tester, 'mansi@example.com');
      await openFromHome(tester, 'Location');
    }

    void seedTrip() {
      backend.seedLocation('u1', at(0, 0, 1), placeName: 'Home');
      backend.seedLocation('u1', at(1, 10, 32), placeName: 'Patia', address: 'Plot 12, Patia, Bhubaneswar, Odisha 751024');
      backend.seedLocation('u1', at(1, 14, 15), placeName: 'KIIT Road');
      backend.seedLocation('u1', at(2, 18, 40), placeName: 'Saheed Nagar');
      backend.seedLocation('u1', at(9, 12, 0), placeName: 'Old Town');
      backend.seedLocation('u1', at(45, 12, 0), placeName: 'Puri');
      backend.seedLocation('u1', at(400, 12, 0), placeName: 'Konark');
    }

    /// History items (not the current-location card or Today's Travel).
    final historyItems = find.byWidgetPredicate((w) {
      final key = w.key;
      return key is ValueKey<String> &&
          key.value.startsWith('location-') &&
          key.value != 'location-current' &&
          key.value != 'location-failure';
    });

    /// The seeded place names shown in the history list, top to bottom.
    List<String> placesInOrder(WidgetTester tester) {
      final names = ['Home', 'Patia', 'KIIT Road', 'Saheed Nagar', 'Old Town', 'Puri', 'Konark'];
      final shown = <(double, String)>[];
      for (final name in names) {
        final finder = find.descendant(of: historyItems, matching: find.text(name));
        if (finder.evaluate().isNotEmpty) shown.add((tester.getTopLeft(finder.first).dy, name));
      }
      shown.sort((a, b) => a.$1.compareTo(b.$1));
      return [for (final (_, name) in shown) name];
    }

    Future<void> tapChip(WidgetTester tester, LocationHistoryFilter filter) =>
        tapVisible(tester, find.byKey(ValueKey('history-filter-${filter.name}')));

    // The single-day filters do not depend on the weekday or month, so pin them exactly.
    const expectedFor = {
      LocationHistoryFilter.today: ['Home'],
      LocationHistoryFilter.yesterday: ['Patia', 'KIIT Road'],
      LocationHistoryFilter.dayBeforeYesterday: ['Saheed Nagar'],
    };

    for (final filter in LocationHistoryFilter.quick.where((f) => f != LocationHistoryFilter.recent)) {
      testWidgets('${filter.label} searches its own local days, oldest first', (tester) async {
        await startApp(tester, seed: seedTrip);
        await tapChip(tester, filter);

        final range = resolveHistoryRange(filter, DateTime.now());
        final query = backend.historyQueries.last;
        expect(query['startDate'], formatApiDate(range.start));
        expect(query['endDate'], formatApiDate(range.end));
        expect(query['utcOffsetMinutes'], '${range.start.timeZoneOffset.inMinutes}');
        expect(query.containsKey('userId'), isFalse);

        final seeded = {
          'Home': at(0, 0, 1),
          'Patia': at(1, 10, 32),
          'KIIT Road': at(1, 14, 15),
          'Saheed Nagar': at(2, 18, 40),
          'Old Town': at(9, 12, 0),
          'Puri': at(45, 12, 0),
          'Konark': at(400, 12, 0),
        };
        final expected = [
          for (final MapEntry(key: name, value: time) in seeded.entries)
            if (!DateUtils.dateOnly(time).isBefore(range.start) && !DateUtils.dateOnly(time).isAfter(range.end)) name,
        ]..sort((a, b) => seeded[a]!.compareTo(seeded[b]!));
        if (expectedFor[filter] case final pinned?) expect(expected, pinned);
        expect(placesInOrder(tester), expected);

        final chip = tester.widget<ChoiceChip>(find.byKey(ValueKey('history-filter-${filter.name}')));
        expect(chip.selected, isTrue);
        if (expected.isEmpty) {
          expect(find.text('No location history found.'), findsOneWidget);
          expect(find.text('No saved locations were found for ${formatRangeLabel(range)}.'), findsOneWidget);
        }
        // Searching history never touches GPS or asks for permission.
        expect(gps.reads, 0);
        expect(os.dialogsShown, isEmpty);
      });
    }

    testWidgets('results are grouped under each local date with time, place, address and coordinates',
        (tester) async {
      await startApp(tester, seed: seedTrip);
      // Use an explicit three-day window so the test does not depend on the weekday.
      final services = tester.widget<MyApp>(find.byType(MyApp)).services;
      await services.locationHistoryService.searchRange(at(2, 0, 0), at(0, 0, 0));
      await tester.pumpAndSettle();

      for (final daysAgo in [0, 1, 2]) {
        final day = at(daysAgo, 0, 0);
        expect(find.byKey(ValueKey('history-day-${formatApiDate(day)}')), findsOneWidget);
        expect(find.text(formatLongDate(day)), findsOneWidget);
      }
      expect(placesInOrder(tester), ['Saheed Nagar', 'Patia', 'KIIT Road', 'Home']);
      // Yesterday's header comes before its two places.
      final header = tester.getTopLeft(find.text(formatLongDate(at(1, 0, 0)))).dy;
      expect(header, lessThan(tester.getTopLeft(find.text('Patia')).dy));
      expect(find.text('10:32 AM • Accuracy: 10 m'), findsOneWidget);
      expect(find.text('2:15 PM • Accuracy: 10 m'), findsOneWidget);
      expect(find.text('6:40 PM • Accuracy: 10 m'), findsOneWidget);
      expect(find.text('Plot 12, Patia, Bhubaneswar, Odisha 751024'), findsOneWidget);
      expect(find.text('20.2961, 85.8245'), findsNWidgets(4));
      expect(find.textContaining('${formatRangeLabel(HistoryDateRange(at(2, 0, 0), at(0, 0, 0)))} • 4 saved places'),
          findsOneWidget);
    });

    testWidgets('Custom Date: pick a day, then Search History', (tester) async {
      await startApp(tester, seed: seedTrip);
      final search = _searchButton;
      expect(tester.widget<FilledButton>(search).onPressed, isNull, reason: 'no date chosen yet');
      final queriesBefore = backend.historyQueries.length;

      await tapVisible(tester, find.byKey(const ValueKey('history-date')));
      expect(find.byType(DatePickerDialog), findsOneWidget);
      // The 1st of this month (or today, when today is the 1st).
      final pick = today.day == 1 ? today : DateTime(today.year, today.month, 1);
      await tester.tap(find.descendant(of: find.byType(DatePickerDialog), matching: find.text('${pick.day}')));
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text(formatShortDate(pick)), findsOneWidget);
      expect(backend.historyQueries, hasLength(queriesBefore), reason: 'picking alone does not search');

      await tapVisible(tester, search);
      expect(backend.historyQueries.last['startDate'], formatApiDate(pick));
      expect(backend.historyQueries.last['endDate'], formatApiDate(pick));
      final shownDay = find.byKey(ValueKey('history-day-${formatApiDate(pick)}'));
      final expected = {0: 'Home', 1: 'Patia', 2: 'Saheed Nagar'}[today.difference(pick).inDays];
      if (expected == null) {
        expect(find.text('No saved locations were found for ${formatLongDate(pick)}.'), findsOneWidget);
      } else {
        expect(shownDay, findsOneWidget);
        expect(find.text(expected), findsOneWidget);
      }
    });

    testWidgets('Custom Date Range: pick From and To, then Search History', (tester) async {
      // Wide enough for the platform range picker's input header in the test font.
      await startApp(tester, seed: seedTrip, width: 700);
      await tapVisible(tester, find.text('Custom Date Range'));
      expect(find.byKey(const ValueKey('history-from')), findsOneWidget);
      expect(find.byKey(const ValueKey('history-to')), findsOneWidget);

      Future<void> enterRange(String start, String end) async {
        await tapVisible(tester, find.byKey(const ValueKey('history-from')));
        await tester.tap(find.byIcon(Icons.edit_outlined));
        await tester.pumpAndSettle();
        final fields = find.descendant(of: find.byType(DateRangePickerDialog), matching: find.byType(TextField));
        await tester.enterText(fields.at(0), start);
        await tester.enterText(fields.at(1), end);
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
      }

      String us(DateTime d) =>
          '${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}/${d.year}';

      // More than a year is refused before anything is sent.
      await enterRange(us(at(400, 0, 0)), us(at(0, 0, 0)));
      expect(find.text('Choose a range of one year or less.'), findsOneWidget);
      expect(tester.widget<FilledButton>(_searchButton).onPressed, isNull);

      await enterRange(us(at(9, 0, 0)), us(at(1, 0, 0)));
      expect(find.text('Choose a range of one year or less.'), findsNothing);
      expect(find.text(formatShortDate(at(9, 0, 0))), findsOneWidget);
      expect(find.text(formatShortDate(at(1, 0, 0))), findsOneWidget);
      await tapVisible(tester, _searchButton);

      expect(backend.historyQueries.last['startDate'], formatApiDate(at(9, 0, 0)));
      expect(backend.historyQueries.last['endDate'], formatApiDate(at(1, 0, 0)));
      expect(placesInOrder(tester), ['Old Town', 'Saheed Nagar', 'Patia', 'KIIT Road']);
    });

    testWidgets('an empty range says which dates had nothing', (tester) async {
      await startApp(tester);
      final services = tester.widget<MyApp>(find.byType(MyApp)).services;
      await services.locationHistoryService.searchRange(DateTime(2026, 1, 1), DateTime(2026, 1, 7));
      await tester.pumpAndSettle();
      expect(find.text('No location history found.'), findsOneWidget);
      expect(find.text('No saved locations were found for 1 January 2026 – 7 January 2026.'), findsOneWidget);
    });

    testWidgets('shows a loading indicator while searching', (tester) async {
      await startApp(tester, seed: seedTrip);
      backend.historyGate = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('history-filter-yesterday')));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Patia'), findsNothing, reason: 'results of another period are never shown under this one');

      backend.historyGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Patia'), findsOneWidget);
    });

    testWidgets('a slow earlier search never replaces a newer one', (tester) async {
      await startApp(tester, seed: seedTrip);
      final services = tester.widget<MyApp>(find.byType(MyApp)).services;
      final history = services.locationHistoryService;
      final gate = backend.historyGate = Completer<void>();
      final slow = history.searchFilter(LocationHistoryFilter.yesterday);
      backend.historyGate = null;
      await history.searchFilter(LocationHistoryFilter.today);
      gate.complete();
      await slow;
      await tester.pumpAndSettle();
      expect(history.query.filter, LocationHistoryFilter.today);
      expect(placesInOrder(tester), ['Home']);
    });

    testWidgets('API failures are told apart: offline, server down, invalid date', (tester) async {
      await startApp(tester, seed: seedTrip);
      backend.offline = true;
      await tapChip(tester, LocationHistoryFilter.yesterday);
      expect(find.byKey(const ValueKey('history-error-noConnection')), findsOneWidget);
      expect(find.textContaining('No internet connection'), findsOneWidget);
      backend.offline = false;

      backend.locationFailureStatus = 503;
      await tapChip(tester, LocationHistoryFilter.today);
      expect(find.byKey(const ValueKey('history-error-serverUnavailable')), findsOneWidget);
      expect(find.textContaining('server is unavailable'), findsOneWidget);
      backend.locationFailureStatus = null;

      final services = tester.widget<MyApp>(find.byType(MyApp)).services;
      await services.locationHistoryService.searchRange(at(0, 0, 0), at(3, 0, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('history-error-invalidDate')), findsOneWidget);
      expect(find.textContaining('Invalid date range.'), findsOneWidget);

      await tapChip(tester, LocationHistoryFilter.yesterday);
      expect(find.byKey(const ValueKey('history-error-invalidDate')), findsNothing);
      expect(placesInOrder(tester), ['Patia', 'KIIT Road']);
    });

    testWidgets('history works with GPS off and location permission blocked', (tester) async {
      await startApp(tester, seed: seedTrip);
      gps.serviceEnabled = false;
      os.os[AppPermission.location] = PermissionState.permanentlyDenied;
      // Re-check, as when returning to the app.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.textContaining('Location permission is blocked.'), findsOneWidget);

      await tapChip(tester, LocationHistoryFilter.yesterday);
      expect(placesInOrder(tester), ['Patia', 'KIIT Road']);
      await tapChip(tester, LocationHistoryFilter.recent);
      expect(find.text('Konark'), findsOneWidget);
      expect(gps.reads, 0);
      expect(os.dialogsShown, isEmpty);
    });

    testWidgets('Get Current Location still saves and refreshes the history being shown', (tester) async {
      await startApp(tester, seed: seedTrip);
      await tapChip(tester, LocationHistoryFilter.today);
      expect(placesInOrder(tester), ['Home']);

      gps.position = DeviceLocation(latitude: 20.2961, longitude: 85.8245, accuracy: 12, capturedAt: DateTime.now());
      await tapVisible(tester, find.text('Get Current Location'));
      expect(gps.reads, 1);
      expect(os.dialogsShown, [AppPermission.location]);
      expect(backend.locations['u1'], hasLength(8));
      expect(find.text('Location updated'), findsOneWidget);
      // Today's search was reloaded and now includes the new place.
      expect(backend.historyQueries.last['startDate'], formatApiDate(today));
      expect(find.descendant(of: historyItems, matching: find.text('Jayadev Vihar')), findsOneWidget);
      // Today's Travel shows it too.
      expect(find.descendant(of: find.byKey(const ValueKey('today-travel')), matching: find.text('Jayadev Vihar')),
          findsOneWidget);
    });

    testWidgets('more than 50 matches: 50 are shown with a note', (tester) async {
      await startApp(tester, seed: () {
        for (var i = 0; i < 55; i++) {
          backend.seedLocation('u1', at(1, 8, i), placeName: 'Stop $i');
        }
      });
      await tapChip(tester, LocationHistoryFilter.yesterday);
      expect(find.byKey(const ValueKey('history-more')), findsOneWidget);
      expect(find.textContaining('Showing the first 50 saved locations'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Location History'), -200, scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('Yesterday • 50 saved places'), findsOneWidget);
    });

    testWidgets('switching accounts clears the previous search and its results', (tester) async {
      await startApp(tester, seed: seedTrip);
      await tapChip(tester, LocationHistoryFilter.yesterday);
      expect(find.text('Patia'), findsOneWidget);
      final services = tester.widget<MyApp>(find.byType(MyApp)).services;

      await logOut(tester);
      expect(services.locationHistoryService.records, isEmpty);
      expect(services.locationHistoryService.query.isRecent, isTrue);

      await logIn(tester, 'ravi@example.com');
      await openFromHome(tester, 'Location');
      expect(find.text('Patia'), findsNothing);
      expect(find.text('No location history yet.'), findsOneWidget);
      await tapChip(tester, LocationHistoryFilter.yesterday);
      expect(find.text('Patia'), findsNothing);
      expect(find.text('No location history found.'), findsOneWidget);
    });
  });
}
