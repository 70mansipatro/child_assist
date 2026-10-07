import { z } from "zod";
import { MAX_TITLE_LENGTH } from "./chat.service";

/** Longest message a user can send in one turn (also bounds what is sent to Gemini). */
export const MAX_CHAT_MESSAGE_LENGTH = 4000;

// Conversation and action IDs are cuids; anything else cannot exist, so it is a plain 404/400.
const id = z.string().trim().regex(/^[a-z0-9]{20,40}$/i, "Invalid id");

const timeZone = z
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

// Strict: unknown keys such as userId are rejected outright. The user is always the one in the
// JWT; nothing in the body can change whose conversation is used.
export const chatRequestSchema = z.strictObject({
  conversationId: id.optional(),
  message: z
    .string({ error: "message is required" })
    .trim()
    .min(1, "message must not be empty")
    .max(MAX_CHAT_MESSAGE_LENGTH, `message must be at most ${MAX_CHAT_MESSAGE_LENGTH} characters`),
  timeZone: timeZone.optional(),
  // Offsets run from UTC-12:00 to UTC+14:00.
  utcOffsetMinutes: z.number().int().min(-720).max(840).optional(),
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
