import { z } from "zod";
import { DevicePlatform } from "../../../generated/prisma/client";
import { TrackingState } from "./notification.service";

// Strict schemas throughout: the user is always the one in the verified JWT, so a userId (or any
// other unexpected field) in a body or query is rejected rather than silently ignored.

export const MAX_NOTIFICATION_LIMIT = 50;
export const DEFAULT_NOTIFICATION_LIMIT = 30;

export const registerDeviceSchema = z.strictObject(
  {
    // FCM registration tokens are opaque and currently ~160 characters; allow generous headroom.
    token: z
      .string({ error: "token is required" })
      .trim()
      .min(20, "token is not a valid FCM token")
      .max(4096, "token is not a valid FCM token")
      .regex(/^[\w:.-]+$/, "token is not a valid FCM token"),
    platform: z.enum(DevicePlatform, { error: "platform must be ANDROID or IOS" }),
    appVersion: z.string().trim().max(40, "appVersion must be at most 40 characters").nullable().optional(),
  },
  { error: "Request body must be a JSON object" },
);

export const idParamsSchema = z.object({
  id: z.uuid({ error: "id must be a UUID" }),
});

export const listQuerySchema = z.strictObject({
  limit: z.coerce
    .number({ error: "limit must be a number" })
    .int("limit must be a whole number")
    .min(1, "limit must be at least 1")
    .transform((n) => Math.min(n, MAX_NOTIFICATION_LIMIT))
    .default(DEFAULT_NOTIFICATION_LIMIT),
  before: z.uuid({ error: "before must be a notification id" }).optional(),
  unread: z.enum(["true", "false"], { error: "unread must be true or false" }).optional(),
});

export const emptyQuerySchema = z.strictObject({});

const flag = (name: string) => z.boolean({ error: `${name} must be true or false` }).optional();

export const updatePreferencesSchema = z
  .strictObject(
    {
      securityEnabled: flag("securityEnabled"),
      accountEnabled: flag("accountEnabled"),
      permissionEnabled: flag("permissionEnabled"),
      locationEnabled: flag("locationEnabled"),
      chatEnabled: flag("chatEnabled"),
      communicationEnabled: flag("communicationEnabled"),
      systemEnabled: flag("systemEnabled"),
    },
    { error: "Request body must be a JSON object" },
  )
  .refine((v) => Object.values(v).some((x) => x !== undefined), { error: "Nothing to update" });

export const trackingStatusSchema = z.strictObject(
  {
    state: z.enum(TrackingState, { error: "state must be STARTED, STOPPED or PAUSED" }),
  },
  { error: "Request body must be a JSON object" },
);
