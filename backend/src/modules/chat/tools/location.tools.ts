import { z } from "zod";
import { PermissionType } from "../../../../generated/prisma/client";
import { listLocations } from "../../location/location.service";
import { defineChatTool } from "./define-tool";
import { chatProviders } from "./providers";
import { fail, ok, type ToolContext } from "./types";

export const MAX_TOOL_LOCATIONS = 50;
// Bounds a single request so a manipulated argument cannot dump years of history at once.
const MAX_RANGE_MS = 400 * 24 * 60 * 60 * 1000;

export const isoDateTime = (label: string) =>
  z.iso.datetime({ offset: true, error: `${label} must be an ISO 8601 date-time with a time zone offset` });

export function locationTools(ctx: ToolContext) {
  return {
    get_location_history: defineChatTool(ctx, {
      name: "get_location_history",
      kind: "location_history",
      // The app lists the places itself, so the user sees exactly what the tool returned.
      display: (data) => ({ data: data as Record<string, unknown> }),
      description:
        "List places the user saved in Child Assist between two moments, newest first. Only " +
        "locations the user chose to save are known; there is no background tracking. Use for " +
        "questions like 'where did I go last month?' or 'what places did I visit yesterday?'.",
      inputSchema: z.strictObject({
        startDate: isoDateTime("startDate").describe("Start of the period (inclusive), e.g. 2026-09-01T00:00:00+05:30"),
        endDate: isoDateTime("endDate").describe("End of the period (exclusive), e.g. 2026-10-01T00:00:00+05:30"),
        limit: z.number().int().min(1).max(MAX_TOOL_LOCATIONS).optional().describe("Maximum results, default 20"),
      }),
      permission: PermissionType.LOCATION,
      execute: async ({ startDate, endDate, limit }, { userId }) => {
        const since = new Date(startDate);
        const before = new Date(endDate);
        if (before <= since) return fail("INVALID_ARGUMENTS", "endDate must be after startDate.");
        if (before.getTime() - since.getTime() > MAX_RANGE_MS) {
          return fail("INVALID_ARGUMENTS", "The period can be at most about one year.");
        }

        const take = limit ?? 20;
        // One extra row tells whether there are more than were returned.
        const rows = await listLocations(userId, { since, before, limit: take + 1 });
        return ok({
          count: Math.min(rows.length, take),
          hasMore: rows.length > take,
          locations: rows.slice(0, take).map((l) => ({
            capturedAt: l.capturedAt.toISOString(),
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
