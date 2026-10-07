import { z } from "zod";
import { LocationSource } from "../../../generated/prisma/client";
import { automaticLocationConfig } from "../../config/env";
import { HttpError } from "../../lib/http-error";
import {
  MAX_RANGE_DAYS,
  daysInRange,
  isLocalDate,
  rangeToInstants,
  timeZoneSchema,
  utcOffsetMinutesSchema,
  type LocalDateRange,
} from "../../lib/local-dates";

/** No request returns more than this; larger limits are clamped, not rejected. */
export const MAX_HISTORY_LIMIT = 50;
export const DEFAULT_HISTORY_LIMIT = 50;

// Device clocks drift; allow a small skew before treating a timestamp as "in the future".
const MAX_CLOCK_SKEW_MS = 5 * 60 * 1000;

// No phone reports a reading from before this; an earlier time means a broken clock.
const EARLIEST_CAPTURED_AT = Date.UTC(2000, 0, 1);

export const LOCATION_SOURCES = [LocationSource.MANUAL, LocationSource.AUTOMATIC] as const;
const sourceSchema = z.enum(LOCATION_SOURCES, { error: "source must be MANUAL or AUTOMATIC" });

const isoDateTime = (label: string) =>
  z.iso
    .datetime({ offset: true, error: `${label} must be an ISO 8601 date-time` })
    .transform((value) => new Date(value));

// Optional place text from the device's geocoder. Blank becomes null.
const placeText = (label: string, max: number) =>
  z
    .string({ error: `${label} must be a string or null` })
    .trim()
    .max(max, `${label} must be at most ${max} characters`)
    .transform((value) => value || null)
    .nullable()
    .optional();

// Strict: unknown keys (userId, id, ...) are rejected, so a record can never be created for
// anyone other than the authenticated user.
export const createLocationSchema = z.strictObject(
  {
    latitude: z
      .number({ error: "Invalid latitude" })
      .min(-90, "Invalid latitude: must be between -90 and 90")
      .max(90, "Invalid latitude: must be between -90 and 90"),
    longitude: z
      .number({ error: "Invalid longitude" })
      .min(-180, "Invalid longitude: must be between -180 and 180")
      .max(180, "Invalid longitude: must be between -180 and 180"),
    // Accuracy radius in metres. Upper bound keeps it inside DECIMAL(10, 2).
    accuracy: z
      .number({ error: "Invalid accuracy" })
      .min(0, "Invalid accuracy: must not be negative")
      .max(10_000_000, "Invalid accuracy: too large")
      .nullable()
      .optional(),
    placeName: placeText("placeName", 255),
    address: placeText("address", 1000),
    street: placeText("street", 255),
    locality: placeText("locality", 255),
    city: placeText("city", 255),
    state: placeText("state", 255),
    postalCode: placeText("postalCode", 32),
    country: placeText("country", 255),
    capturedAt: isoDateTime("capturedAt")
      .refine((date) => date.getTime() <= Date.now() + MAX_CLOCK_SKEW_MS, "capturedAt cannot be in the future")
      .refine((date) => date.getTime() >= EARLIEST_CAPTURED_AT, "capturedAt is too far in the past"),
    /** MANUAL ("Get Current Location", the default) or AUTOMATIC (Automatic Location History). */
    source: sourceSchema.default(LocationSource.MANUAL),
  },
  { error: "Request body must be a JSON object" },
).superRefine((input, ctx) => {
  // An automatic point is uploaded soon after it was collected, or from a short offline queue.
  // Anything older is stale or comes from a wrong clock, and would rewrite past days' history.
  // Zod still runs this when a field failed, so capturedAt may not be a Date here.
  if (!(input.capturedAt instanceof Date)) return;
  if (input.source === LocationSource.AUTOMATIC && input.capturedAt.getTime() < Date.now() - automaticLocationConfig().maxAgeMs) {
    ctx.addIssue({ code: "custom", path: ["capturedAt"], message: "capturedAt is too old for an automatic location" });
  }
});

// Strict, so e.g. `?userId=...` is rejected rather than silently ignored.
export const historyQuerySchema = z.strictObject({
  limit: z.coerce
    .number({ error: "limit must be a number" })
    .int("limit must be a whole number")
    .min(1, "limit must be at least 1")
    .default(DEFAULT_HISTORY_LIMIT)
    .transform((limit) => Math.min(limit, MAX_HISTORY_LIMIT)),
  /** Only locations captured strictly before this time (for paging back through history). */
  before: isoDateTime("before").optional(),
  /** Only locations captured at or after this time. */
  since: isoDateTime("since").optional(),
  /** First local calendar day to search, YYYY-MM-DD. */
  startDate: z.string().optional(),
  /** Last local calendar day to search (inclusive), YYYY-MM-DD. Defaults to startDate. */
  endDate: z.string().optional(),
  /** The user's zone, so a date means their local day. Without one, dates are UTC days. */
  timeZone: timeZoneSchema.optional(),
  utcOffsetMinutes: z.coerce.number({ error: "Invalid utcOffsetMinutes" }).pipe(utcOffsetMinutesSchema).optional(),
  /** Only manual or only automatic locations. Both when omitted. */
  source: sourceSchema.optional(),
});


export interface ResolvedHistoryQuery {
  limit: number;
  source?: LocationSource;
  since?: Date;
  before?: Date;
  /** Set for a date search, which is listed oldest first. */
  range?: LocalDateRange;
}

/**
 * Turns a date search into the instants that bound the user's local days. Date problems are
 * plain 400s with a readable message, never a stack trace.
 */
export function resolveHistoryQuery(query: HistoryQuery): ResolvedHistoryQuery {
  const { limit, since, before, startDate, endDate, source } = query;
  if (startDate === undefined && endDate === undefined) return { limit, since, before, source };

  if (since || before) throw new HttpError(400, "Use either startDate/endDate or since/before, not both.");
  if (startDate === undefined) throw new HttpError(400, "startDate is required when endDate is given.");
  if (!isLocalDate(startDate) || (endDate !== undefined && !isLocalDate(endDate))) {
    throw new HttpError(400, "Invalid date. Use the format YYYY-MM-DD.");
  }
  const range = { startDate, endDate: endDate ?? startDate };
  const days = daysInRange(range.startDate, range.endDate);
  if (days < 1) throw new HttpError(400, "Invalid date range.");
  if (days > MAX_RANGE_DAYS) throw new HttpError(400, "Invalid date range. A search can cover at most one year.");

  const zone = { timeZone: query.timeZone, utcOffsetMinutes: query.utcOffsetMinutes };
  return { limit, source, ...rangeToInstants(range, zone), range };
}

export const deleteHistoryQuerySchema = z.strictObject({});

export const locationParamsSchema = z.object({
  id: z.uuid({ error: "Invalid location id" }),
});

export type CreateLocationInput = z.infer<typeof createLocationSchema>;
export type HistoryQuery = z.infer<typeof historyQuerySchema>;
