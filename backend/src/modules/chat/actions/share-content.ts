import {
  HISTORY_PERIODS,
  daysInRange,
  isLocalDate,
  localDateOf,
  localTimeOf,
  rangeToInstants,
  resolvePeriod,
  type HistoryPeriod,
  type LocalDateRange,
  type UserZone,
} from "../../../lib/local-dates";
import { searchLocations } from "../../location/location.service";

// The exact text that is shared when the user asks to email or WhatsApp their location or travel
// history. Built by the backend from the user's own saved locations when the action is prepared,
// so the confirmation shows precisely what will be sent; the model never writes this data.

/** At most this many places go into one message. */
export const MAX_SHARED_LOCATIONS = 30;

export type ShareKind = "location" | "travel_history";

export interface ShareRequest {
  kind: ShareKind;
  period?: HistoryPeriod;
  startDate?: string;
  endDate?: string;
}

export interface SharedLocations {
  /** Plain-text lines, one per place, ready for an email or a WhatsApp message. */
  text: string;
  /** e.g. "Today's travel history (3 saved locations)". */
  dataSummary: string;
  /** e.g. "Today's Location". */
  title: string;
  count: number;
}

const PERIOD_LABELS: Record<HistoryPeriod, string> = {
  today: "Today",
  yesterday: "Yesterday",
  day_before_yesterday: "Day before yesterday",
  this_week: "This week",
  last_week: "Last week",
  this_month: "This month",
  last_month: "Last month",
  this_year: "This year",
  last_year: "Last year",
};

function possessive(label: string): string {
  return /s$/i.test(label) ? `${label}'` : `${label}'s`;
}

/** "Today's travel history", "Location on 2026-10-05", "Travel history from 2026-10-01 to 2026-10-05". */
function describe(noun: string, request: ShareRequest, range: LocalDateRange): string {
  if (request.period) return `${possessive(PERIOD_LABELS[request.period])} ${noun}`;
  const capitalised = noun.charAt(0).toUpperCase() + noun.slice(1);
  return range.startDate === range.endDate
    ? `${capitalised} on ${range.startDate}`
    : `${capitalised} from ${range.startDate} to ${range.endDate}`;
}

export function resolveShareRange(request: ShareRequest, zone: UserZone, now = new Date()): LocalDateRange | null {
  const today = localDateOf(now, zone);
  if (request.period) {
    if (!HISTORY_PERIODS.includes(request.period)) return null;
    return resolvePeriod(request.period, today);
  }
  if (request.startDate) {
    const endDate = request.endDate ?? request.startDate;
    if (!isLocalDate(request.startDate) || !isLocalDate(endDate)) return null;
    const days = daysInRange(request.startDate, endDate);
    return days >= 1 && days <= 366 ? { startDate: request.startDate, endDate } : null;
  }
  return resolvePeriod("today", today);
}

/**
 * The user's saved locations for the requested period as shareable text, or null when nothing
 * was saved then. Only ever reads the given user's own rows.
 */
export async function buildSharedLocations(
  userId: string,
  request: ShareRequest,
  zone: UserZone,
  range: LocalDateRange,
): Promise<SharedLocations | null> {
  const { locations, hasMore } = await searchLocations(userId, {
    ...rangeToInstants(range, zone),
    limit: MAX_SHARED_LOCATIONS,
    order: "asc",
  });
  if (locations.length === 0) return null;

  const multiDay = range.startDate !== range.endDate;
  const lines = locations.map((l) => {
    const place = [l.placeName, l.address ?? [l.city, l.state].filter(Boolean).join(", "), l.country]
      .filter((p) => p && p.trim().length > 0)
      .filter((p, i, all) => all.indexOf(p) === i)
      .join(", ");
    const when = multiDay ? `${localDateOf(l.capturedAt, zone)} ${localTimeOf(l.capturedAt, zone)}` : localTimeOf(l.capturedAt, zone);
    const coordinates = `${l.latitude.toFixed(5)},${l.longitude.toFixed(5)}`;
    return `• ${when} — ${place || "Location unavailable"}\n  https://maps.google.com/?q=${coordinates}`;
  });

  const travel = request.kind === "travel_history";
  const described = describe(travel ? "travel history" : "location", request, range);
  const more = hasMore ? `\n(Only the first ${MAX_SHARED_LOCATIONS} saved locations are included.)` : "";
  const count = locations.length;
  return {
    text: `${described} (shared from Child Assist):\n${lines.join("\n")}${more}`,
    dataSummary: `${described} (${count} saved location${count === 1 ? "" : "s"})`,
    title: describe(travel ? "Travel History" : "Location", request, range),
    count,
  };
}
