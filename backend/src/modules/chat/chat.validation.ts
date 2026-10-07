import { z } from "zod";
import { timeZoneSchema, utcOffsetMinutesSchema } from "../../lib/local-dates";
import { MAX_TITLE_LENGTH } from "./chat.service";

/** Longest message a user can send in one turn (also bounds what is sent to Gemini). */
export const MAX_CHAT_MESSAGE_LENGTH = 4000;

// Conversation and action IDs are cuids; anything else cannot exist, so it is a plain 404/400.
const id = z.string().trim().regex(/^[a-z0-9]{20,40}$/i, "Invalid id");

// Strict: unknown keys such as userId are rejected outright. The user is always the one in the
// JWT; nothing in the body can change whose conversation is used.
export const chatRequestSchema = z.strictObject({
  conversationId: id.optional(),
  message: z
    .string({ error: "message is required" })
    .trim()
    .min(1, "message must not be empty")
    .max(MAX_CHAT_MESSAGE_LENGTH, `message must be at most ${MAX_CHAT_MESSAGE_LENGTH} characters`),
  timeZone: timeZoneSchema.optional(),
  utcOffsetMinutes: utcOffsetMinutesSchema.optional(),
});

export const createConversationSchema = z.strictObject({
  title: z.string().trim().max(MAX_TITLE_LENGTH).nullable().optional(),
});

export const updateConversationSchema = z.strictObject({
  title: z.string().trim().max(MAX_TITLE_LENGTH).nullable(),
});

export const listConversationsQuerySchema = z.strictObject({
  limit: z.coerce.number().int().min(1).max(100).optional(),
});

export const idParamsSchema = z.strictObject({ id });

// Action calls. Strict: a userId (or anything else) in the body is rejected outright.
export const actionScopeSchema = z.strictObject({
  conversationId: id.optional(),
});

/** The one contact address the user picked on the phone for this action, never an address book. */
export const actionRecipientSchema = z.strictObject({
  conversationId: id.optional(),
  name: z
    .string()
    .trim()
    .max(120)
    .regex(/^[^\r\n\t<>"]*$/, "Invalid name")
    .optional(),
  address: z.string({ error: "address is required" }).trim().min(1).max(320),
});

/** The one contact (name and number) the user picked on the phone for a SHARE_CONTACT action. */
export const actionSharedContactSchema = z.strictObject({
  conversationId: id.optional(),
  name: z
    .string({ error: "name is required" })
    .trim()
    .min(1)
    .max(120)
    .regex(/^[^\r\n\t<>"]*$/, "Invalid name"),
  phone: z.string({ error: "phone is required" }).trim().min(1).max(32),
});

export const actionHandoffSchema = z.strictObject({
  conversationId: id.optional(),
  result: z.enum(["whatsapp_opened", "share_opened", "unavailable"]),
});
