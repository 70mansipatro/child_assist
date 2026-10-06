import { z } from "zod";

export const MAX_HISTORY_LIMIT = 100;
export const DEFAULT_HISTORY_LIMIT = 50;

// Device clocks drift; allow a small skew before treating a timestamp as "in the future".
const MAX_CLOCK_SKEW_MS = 5 * 60 * 1000;

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
    capturedAt: isoDateTime("capturedAt").refine(
      (date) => date.getTime() <= Date.now() + MAX_CLOCK_SKEW_MS,
      "capturedAt cannot be in the future",
    ),
  },
  { error: "Request body must be a JSON object" },
);

// Strict, so e.g. `?userId=...` is rejected rather than silently ignored.
export const historyQuerySchema = z.strictObject({
  limit: z.coerce
    .number({ error: "limit must be a number" })
    .int("limit must be a whole number")
    .min(1, "limit must be at least 1")
    .max(MAX_HISTORY_LIMIT, `limit must be at most ${MAX_HISTORY_LIMIT}`)
    .default(DEFAULT_HISTORY_LIMIT),
  /** Only locations captured strictly before this time (for paging back through history). */
  before: isoDateTime("before").optional(),
  /** Only locations captured at or after this time (e.g. "today"). */
  since: isoDateTime("since").optional(),
});

export const deleteHistoryQuerySchema = z.strictObject({});

export const locationParamsSchema = z.object({
  id: z.uuid({ error: "Invalid location id" }),
});

export type CreateLocationInput = z.infer<typeof createLocationSchema>;
export type HistoryQuery = z.infer<typeof historyQuerySchema>;
