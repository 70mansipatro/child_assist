// Local-calendar helpers for tests, written independently of src/lib/local-dates.ts so the
// tests check the server's date logic instead of repeating it.

export type Period =
  | "today"
  | "yesterday"
  | "day_before_yesterday"
  | "this_week"
  | "last_week"
  | "this_month"
  | "last_month"
  | "this_year"
  | "last_year";

export const PERIODS: Period[] = [
  "today",
  "yesterday",
  "day_before_yesterday",
  "this_week",
  "last_week",
  "this_month",
  "last_month",
  "this_year",
  "last_year",
];

const iso = (d: Date) => d.toISOString().slice(0, 10);
const parse = (date: string) => new Date(`${date}T00:00:00Z`);

/** The local date at a fixed UTC offset. */
export function localToday(offsetMinutes: number, now = Date.now()): string {
  return iso(new Date(now + offsetMinutes * 60_000));
}

export function shiftDays(date: string, days: number): string {
  const d = parse(date);
  d.setUTCDate(d.getUTCDate() + days);
  return iso(d);
}

/** The instant of a local wall-clock time at a fixed UTC offset. */
export function localInstant(date: string, hours: number, minutes: number, offsetMinutes: number): Date {
  const d = parse(date);
  return new Date(d.getTime() + (hours * 60 + minutes - offsetMinutes) * 60_000);
}

/** The days a period covers; weeks start on Monday, running periods end today. */
export function expectedRange(period: Period, today: string): { startDate: string; endDate: string } {
  const t = parse(today);
  const y = t.getUTCFullYear();
  const m = t.getUTCMonth();
  const daysSinceMonday = (t.getUTCDay() + 6) % 7;
  const monday = shiftDays(today, -daysSinceMonday);
  switch (period) {
    case "today":
      return { startDate: today, endDate: today };
    case "yesterday":
      return { startDate: shiftDays(today, -1), endDate: shiftDays(today, -1) };
    case "day_before_yesterday":
      return { startDate: shiftDays(today, -2), endDate: shiftDays(today, -2) };
    case "this_week":
      return { startDate: monday, endDate: today };
    case "last_week":
      return { startDate: shiftDays(monday, -7), endDate: shiftDays(monday, -1) };
    case "this_month":
      return { startDate: iso(new Date(Date.UTC(y, m, 1))), endDate: today };
    case "last_month":
      return { startDate: iso(new Date(Date.UTC(y, m - 1, 1))), endDate: iso(new Date(Date.UTC(y, m, 0))) };
    case "this_year":
      return { startDate: `${y}-01-01`, endDate: today };
    case "last_year":
      return { startDate: `${y - 1}-01-01`, endDate: `${y - 1}-12-31` };
  }
}
