/// Which saved locations the Location History section shows.
///
/// Every period is a set of whole days on the user's local calendar, never UTC days. Weeks
/// run Monday to Sunday everywhere in the app (the server and the assistant use the same rule).
enum LocationHistoryFilter {
  /// The most recent saved locations, newest first, with no date limit.
  recent('Recent'),
  today('Today'),
  yesterday('Yesterday'),
  dayBeforeYesterday('Day Before Yesterday'),
  thisWeek('This Week'),
  lastWeek('Last Week'),
  thisMonth('This Month'),
  lastMonth('Last Month'),
  thisYear('This Year'),
  customDate('Custom Date'),
  customRange('Custom Date Range');

  const LocationHistoryFilter(this.label);

  final String label;

  /// The filters offered as one-tap chips.
  static const quick = [recent, today, yesterday, dayBeforeYesterday, thisWeek, lastWeek, thisMonth, lastMonth, thisYear];
}

/// A run of whole local days, both ends included. Times of day are dropped.
class HistoryDateRange {
  HistoryDateRange(DateTime start, DateTime end)
      : start = dateOnly(start),
        end = dateOnly(end);

  HistoryDateRange.day(DateTime day) : this(day, day);

  final DateTime start;
  final DateTime end;

  bool get isSingleDay => start == end;

  /// Calendar days covered: the same day is 1.
  int get days => calendarDaysBetween(start, end) + 1;

  @override
  bool operator ==(Object other) => other is HistoryDateRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'HistoryDateRange(${formatApiDate(start)}..${formatApiDate(end)})';
}

/// The longest period one search may cover, matching the server (one leap year).
const maxHistoryRangeDays = 366;

/// What to load: recent history, or the locations saved on some days.
class LocationHistoryQuery {
  const LocationHistoryQuery.recent()
      : filter = LocationHistoryFilter.recent,
        range = null;

  const LocationHistoryQuery._(this.filter, this.range);

  /// A quick filter, resolved against [now] (the device's local time).
  factory LocationHistoryQuery.preset(LocationHistoryFilter filter, {DateTime? now}) {
    if (filter == LocationHistoryFilter.recent) return const LocationHistoryQuery.recent();
    if (filter == LocationHistoryFilter.customDate || filter == LocationHistoryFilter.customRange) {
      throw ArgumentError.value(filter, 'filter', 'needs a date; use LocationHistoryQuery.date or .range');
    }
    return LocationHistoryQuery._(filter, resolveHistoryRange(filter, now ?? DateTime.now()));
  }

  LocationHistoryQuery.date(DateTime day) : this._(LocationHistoryFilter.customDate, HistoryDateRange.day(day));

  LocationHistoryQuery.range(DateTime start, DateTime end)
      : this._(LocationHistoryFilter.customRange, HistoryDateRange(start, end));

  final LocationHistoryFilter filter;

  /// Null for recent history.
  final HistoryDateRange? range;

  bool get isRecent => range == null;

  @override
  bool operator ==(Object other) => other is LocationHistoryQuery && other.filter == filter && other.range == range;

  @override
  int get hashCode => Object.hash(filter, range);
}

/// The days a quick filter covers on the local calendar of [now]. Periods that are still
/// running ("This Week") end today: nothing after now can have been saved.
HistoryDateRange resolveHistoryRange(LocationHistoryFilter filter, DateTime now) {
  final today = dateOnly(now);
  // DateTime's constructor normalises overflow (day 0 is the last day of the month before),
  // and building from parts keeps local midnight even across daylight-saving changes.
  DateTime day(int offset) => DateTime(today.year, today.month, today.day + offset);
  final monday = day(-(today.weekday - DateTime.monday));
  return switch (filter) {
    LocationHistoryFilter.today => HistoryDateRange.day(today),
    LocationHistoryFilter.yesterday => HistoryDateRange.day(day(-1)),
    LocationHistoryFilter.dayBeforeYesterday => HistoryDateRange.day(day(-2)),
    LocationHistoryFilter.thisWeek => HistoryDateRange(monday, today),
    LocationHistoryFilter.lastWeek => HistoryDateRange(
      DateTime(monday.year, monday.month, monday.day - 7),
      DateTime(monday.year, monday.month, monday.day - 1),
    ),
    LocationHistoryFilter.thisMonth => HistoryDateRange(DateTime(today.year, today.month), today),
    LocationHistoryFilter.lastMonth => HistoryDateRange(
      DateTime(today.year, today.month - 1),
      DateTime(today.year, today.month, 0),
    ),
    LocationHistoryFilter.thisYear => HistoryDateRange(DateTime(today.year), today),
    LocationHistoryFilter.recent ||
    LocationHistoryFilter.customDate ||
    LocationHistoryFilter.customRange => throw ArgumentError.value(filter, 'filter', 'has no fixed range'),
  };
}

/// Why a chosen date or range cannot be searched, or null if it can.
String? validateHistoryRange(HistoryDateRange range, {DateTime? now}) {
  final today = dateOnly(now ?? DateTime.now());
  if (range.end.isBefore(range.start)) return 'The end date must be on or after the start date.';
  if (range.start.isAfter(today)) return 'Choose a date that is not in the future.';
  if (range.days > maxHistoryRangeDays) return 'Choose a range of one year or less.';
  return null;
}

DateTime dateOnly(DateTime time) => DateTime(time.year, time.month, time.day);

/// Whole calendar days from [a] to [b], unaffected by daylight-saving hours.
int calendarDaysBetween(DateTime a, DateTime b) =>
    DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

/// "2026-10-05", the date format the API expects.
String formatApiDate(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// "5 October 2026".
String formatLongDate(DateTime day) => '${day.day} ${_monthNames[day.month - 1]} ${day.year}';

/// "05 Oct 2026", for date fields.
String formatShortDate(DateTime day) =>
    '${day.day.toString().padLeft(2, '0')} ${_monthNames[day.month - 1].substring(0, 3)} ${day.year}';

/// "5 October 2026" or "1 October 2026 – 7 October 2026".
String formatRangeLabel(HistoryDateRange range) =>
    range.isSingleDay ? formatLongDate(range.start) : '${formatLongDate(range.start)} – ${formatLongDate(range.end)}';
