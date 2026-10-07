import { z } from "zod";
import { PermissionType } from "../../../../generated/prisma/client";
import {
  HISTORY_PERIODS,
  MAX_RANGE_DAYS,
  daysInRange,
  isLocalDate,
  localDateOf,
  localTimeOf,
  rangeToInstants,
  resolvePeriod,
  type LocalDateRange,
} from "../../../lib/local-dates";
import { LocationSource, searchLocations } from "../../location/location.service";
import { defineChatTool } from "./define-tool";
import { chatProviders } from "./providers";
import { fail, ok, type ToolContext } from "./types";

export const MAX_TOOL_LOCATIONS = 50;

export const isoDateTime = (label: string) =>
  z.iso.datetime({ offset: true, error: `${label} must be an ISO 8601 date-time with a time zone offset` });

const localDate = (label: string) =>
  z.string().refine(isLocalDate, `${label} must be a calendar date in YYYY-MM-DD format`);

export function locationTools(ctx: ToolContext) {
  return {
    get_location_history: defineChatTool(ctx, {
      name: "get_location_history",
      kind: "location_history",
      // The app lists the places itself, so the user sees exactly what the tool returned.
      display: (data) => ({ data: data as Record<string, unknown> }),
      description:
        "List the user's saved locations on given days of their own calendar, oldest first. Each has a " +
        "source: MANUAL (the user tapped 'Get Current Location') or AUTOMATIC (saved by Automatic Location " +
        "History, which records significant places the user stopped at while it was switched on; it does " +
        "not record routes). Use for questions like 'where did I go yesterday?', 'which places did I visit " +
        "this week?', 'did I visit school yesterday?' or 'where did I go on 5 October?'. Pass either " +
        "`period` for a relative period, or `startDate` (and `endDate` for a range) as local calendar " +
        "dates. The server works out the exact times in the user's time zone.",
      inputSchema: z.strictObject({
        period: z
          .enum(HISTORY_PERIODS)
          .optional()
          .describe(
            "A relative period in the user's local calendar. Weeks run Monday to Sunday; this_week, " +
              "this_month and this_year end today.",
          ),
        startDate: localDate("startDate")
          .optional()
          .describe("First local day (inclusive), YYYY-MM-DD, e.g. 2026-10-05. Use instead of period."),
        endDate: localDate("endDate")
          .optional()
          .describe("Last local day (inclusive), YYYY-MM-DD. Omit, or repeat startDate, for a single day."),
        source: z
          .enum([LocationSource.MANUAL, LocationSource.AUTOMATIC])
          .optional()
          .describe(
            "Only when the user asks for one kind: AUTOMATIC for 'automatic travel history', MANUAL for " +
              "locations they saved themselves. Omit to include both (the usual case).",
          ),
        limit: z
          .number()
          .int()
          .min(1)
          .max(MAX_TOOL_LOCATIONS)
          .optional()
          .describe(`Maximum results, default and maximum ${MAX_TOOL_LOCATIONS}`),
      }),
      permission: PermissionType.LOCATION,
      execute: async ({ period, startDate, endDate, source, limit }, { userId, zone }) => {
        const today = localDateOf(new Date(), zone);

        let range: LocalDateRange;
        if (period && (startDate || endDate)) {
          return fail("INVALID_ARGUMENTS", "Pass either period or startDate/endDate, not both.");
        } else if (period) {
          range = resolvePeriod(period, today);
        } else if (startDate) {
          range = { startDate, endDate: endDate ?? startDate };
        } else {
          return fail("INVALID_ARGUMENTS", "Pass a period or a startDate.");
        }

        const days = daysInRange(range.startDate, range.endDate);
        if (days < 1) return fail("INVALID_ARGUMENTS", "endDate must not be before startDate.");
        if (days > MAX_RANGE_DAYS) return fail("INVALID_ARGUMENTS", "The period can be at most one year.");

        const base = {
          ...(period ? { period } : {}),
          ...(source ? { source } : {}),
          startDate: range.startDate,
          endDate: range.endDate,
          today,
        };
        // Nothing can have been saved in the future; say so rather than search.
        if (range.startDate > today) {
          return ok({
            ...base,
            count: 0,
            hasMore: false,
            future: true,
            note: "This period is in the future. Only locations that were already saved can be shown.",
            locations: [],
          });
        }

        const take = limit ?? MAX_TOOL_LOCATIONS;
        const { locations, hasMore } = await searchLocations(userId, {
          ...rangeToInstants(range, zone),
          limit: take,
          order: "asc",
          source,
        });
        const automatic = locations.filter((l) => l.source === LocationSource.AUTOMATIC).length;
        return ok({
          ...base,
          count: locations.length,
          automaticCount: automatic,
          manualCount: locations.length - automatic,
          hasMore,
          ...(hasMore
            ? { note: `More than ${take} locations were saved in this period; only the first ${take} are listed.` }
            : {}),
          locations: locations.map((l) => ({
            source: l.source,
            capturedAt: l.capturedAt.toISOString(),
            // The user's own wall clock, so times are never read out in UTC.
            localDate: localDateOf(l.capturedAt, zone),
            localTime: localTimeOf(l.capturedAt, zone),
            placeName: l.placeName,
            address: l.address,
            city: l.city,
            state: l.state,
            country: l.country,
            latitude: l.latitude,
            longitude: l.longitude,
          })),
        });
      },
    }),

    get_current_location: defineChatTool(ctx, {
      name: "get_current_location",
      kind: "current_location",
      description:
        "Get the device's live location. Only works when the app provides it securely; otherwise " +
        "the user can tap 'Get Current Location' in the Location screen.",
      inputSchema: z.strictObject({}),
      permission: PermissionType.LOCATION,
      execute: async (_input, { userId }) => {
        const device = chatProviders().device;
        // No GPS reading is ever invented: without a secure device handoff this is unavailable.
        const location = device.available ? await device.getCurrentLocation(userId) : null;
        if (!location) {
          return fail(
            "CURRENT_LOCATION_UNAVAILABLE",
            "Live location is not available to the assistant. The user can get it from the Location screen.",
          );
        }
        return ok({
          latitude: location.latitude,
          longitude: location.longitude,
          accuracyMeters: location.accuracy ?? null,
          capturedAt: location.capturedAt.toISOString(),
        });
      },
    }),
  };
}
