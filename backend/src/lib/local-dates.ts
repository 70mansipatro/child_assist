import { z } from "zod";

// Calendar dates in the user's own time zone. "Today", "yesterday" or "5 October" mean the
// user's local day, never a UTC day: in India (UTC+05:30) a reading at 01:30 local time on
// 5 October is 20:00 UTC on 4 October, and must still count as 5 October.

/** A local calendar date, "YYYY-MM-DD". */
export type LocalDate = string;

/**
 * The user's time zone, as the device reported it. An IANA zone (e.g. "Asia/Kolkata") handles
 * daylight saving correctly; a fixed UTC offset is the fallback. Neither means UTC.
 */
export interface UserZone {
  timeZone?: string;
  utcOffsetMinutes?: number;
}

/** Longest period one history search may cover, in calendar days (one leap year). */
export const MAX_RANGE_DAYS = 366;

/** Relative periods. Weeks run Monday to Sunday everywhere in the app. */
export const HISTORY_PERIODS = [
  "today",
  "yesterday",
  "day_before_yesterday",
  "this_week",
  "last_week",
  "this_month",
  "last_month",
  "this_year",
  "last_year",
] as const;
export type HistoryPeriod = (typeof HISTORY_PERIODS)[number];

export interface LocalDateRange {
  /** First day, inclusive. */
  startDate: LocalDate;
  /** Last day, inclusive. */
  endDate: LocalDate;
}

const DATE_PATTERN = /^(\d{4})-(\d{2})-(\d{2})$/;
const DAY_MS = 86_400_000;

export const timeZoneSchema = z
  .string()
  .trim()
  .max(64)
  .refine((zone) => {
    try {
      new Intl.DateTimeFormat("en", { timeZone: zone });
      return true;
    } catch {
      return false;
    }
  }, "Invalid time zone");

/** Offsets run from UTC-12:00 to UTC+14:00. */
export const utcOffsetMinutesSchema = z.number().int().min(-720).max(840);

/** Days since 1970-01-01 for a real calendar date, or null for anything else (2026-02-30). */
function toDayNumber(date: string): number | null {
  const match = DATE_PATTERN.exec(date);
  if (!match) return null;
  const [year, month, day] = [Number(match[1]), Number(match[2]), Number(match[3])];
  const ms = Date.UTC(year, month - 1, day);
  const back = new Date(ms);
  if (back.getUTCFullYear() !== year || back.getUTCMonth() !== month - 1 || back.getUTCDate() !== day) return null;
  return ms / DAY_MS;
}

function fromDayNumber(dayNumber: number): LocalDate {
  return new Date(dayNumber * DAY_MS).toISOString().slice(0, 10);
}

function dayNumberOf(date: LocalDate): number {
  const n = toDayNumber(date);
  if (n === null) throw new RangeError(`Invalid local date: ${date}`);
  return n;
}

export function isLocalDate(value: string): boolean {
  return toDayNumber(value) !== null;
}

export function addDays(date: LocalDate, days: number): LocalDate {
  return fromDayNumber(dayNumberOf(date) + days);
}

/** Calendar days from start to end, both included: the same day is 1. */
export function daysInRange(startDate: LocalDate, endDate: LocalDate): number {
  return dayNumberOf(endDate) - dayNumberOf(startDate) + 1;
}

/** Minutes the zone is ahead of UTC at that instant. */
export function offsetMinutesAt(instant: Date, zone: UserZone): number {
  if (!zone.timeZone) return zone.utcOffsetMinutes ?? 0;
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: zone.timeZone,
    hourCycle: "h23",
    year: "numeric",
    month: "numeric",
    day: "numeric",
    hour: "numeric",
    minute: "numeric",
    second: "numeric",
  }).formatToParts(instant);
  const get = (type: Intl.DateTimeFormatPartTypes) => Number(parts.find((p) => p.type === type)?.value);
  const wallClockAsUtc = Date.UTC(get("year"), get("month") - 1, get("day"), get("hour"), get("minute"), get("second"));
  const wholeSeconds = Math.floor(instant.getTime() / 1000) * 1000;
  return Math.round((wallClockAsUtc - wholeSeconds) / 60_000);
}

/** The user's local calendar date at that instant. */
export function localDateOf(instant: Date, zone: UserZone): LocalDate {
  return new Date(instant.getTime() + offsetMinutesAt(instant, zone) * 60_000).toISOString().slice(0, 10);
}

/** The user's local wall-clock time at that instant, e.g. "2:15 PM". */
export function localTimeOf(instant: Date, zone: UserZone): string {
  const local = new Date(instant.getTime() + offsetMinutesAt(instant, zone) * 60_000);
  const hours = local.getUTCHours();
  const minutes = String(local.getUTCMinutes()).padStart(2, "0");
  return `${hours % 12 === 0 ? 12 : hours % 12}:${minutes} ${hours < 12 ? "AM" : "PM"}`;
}

/** The instant the user's local day begins (local midnight). */
export function startOfLocalDay(date: LocalDate, zone: UserZone): Date {
  const midnightAsUtc = dayNumberOf(date) * DAY_MS;
  // The offset at the guessed instant can differ from the offset at local midnight when a
  // daylight-saving change falls in between, so correct once with the offset found there.
  const firstOffset = offsetMinutesAt(new Date(midnightAsUtc), zone);
  const guess = midnightAsUtc - firstOffset * 60_000;
  const secondOffset = offsetMinutesAt(new Date(guess), zone);
  return new Date(midnightAsUtc - secondOffset * 60_000);
}

/** The instants covering whole local days: since is inclusive, before is exclusive. */
export function rangeToInstants(range: LocalDateRange, zone: UserZone): { since: Date; before: Date } {
  return { since: startOfLocalDay(range.startDate, zone), before: startOfLocalDay(addDays(range.endDate, 1), zone) };
}

/** Monday of the week containing the date. */
function mondayOf(date: LocalDate): LocalDate {
  const n = dayNumberOf(date);
  // 1970-01-01 was a Thursday; shift so that Monday is 0.
  const weekday = (((n + 3) % 7) + 7) % 7;
  return fromDayNumber(n - weekday);
}

function firstOfMonth(date: LocalDate, monthsBack = 0): LocalDate {
  const [year, month] = date.split("-").map(Number);
  const d = new Date(Date.UTC(year, month - 1 - monthsBack, 1));
  return d.toISOString().slice(0, 10);
}

/**
 * The days a relative period covers, given the user's local "today". Periods that are still
 * running ("this week") end today: nothing after now can have been saved.
 */
export function resolvePeriod(period: HistoryPeriod, today: LocalDate): LocalDateRange {
  const year = today.slice(0, 4);
  switch (period) {
    case "today":
      return { startDate: today, endDate: today };
    case "yesterday": {
      const day = addDays(today, -1);
      return { startDate: day, endDate: day };
    }
    case "day_before_yesterday": {
      const day = addDays(today, -2);
      return { startDate: day, endDate: day };
    }
    case "this_week":
      return { startDate: mondayOf(today), endDate: today };
    case "last_week": {
      const monday = addDays(mondayOf(today), -7);
      return { startDate: monday, endDate: addDays(monday, 6) };
    }
    case "this_month":
      return { startDate: firstOfMonth(today), endDate: today };
    case "last_month":
      return { startDate: firstOfMonth(today, 1), endDate: addDays(firstOfMonth(today), -1) };
    case "this_year":
      return { startDate: `${year}-01-01`, endDate: today };
    case "last_year": {
      const last = String(Number(year) - 1).padStart(4, "0");
      return { startDate: `${last}-01-01`, endDate: `${last}-12-31` };
    }
  }
}
