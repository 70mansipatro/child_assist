import { z } from "zod";
import { timeZoneSchema, utcOffsetMinutesSchema } from "../../lib/local-dates";
import { MAX_TITLE_LENGTH } from "./chat.service";
import { MAX_DOCUMENT_CHARS } from "./documents/document-answer";

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

/**
 * The one document the user picked on the phone for a SHARE_DOCUMENT action: the app's opaque id
 * for it and its display name and type. A path, URI or anything else is rejected outright: the
 * backend never learns where the file is, and the phone only ever shares from the signed-in
 * user's own document list.
 */
export const actionDocumentSchema = z.strictObject({
  conversationId: id.optional(),
  documentId: z
    .string({ error: "documentId is required" })
    .trim()
    .regex(/^doc_[a-z0-9]{4,60}$/, "Invalid document id"),
  name: z
    .string({ error: "name is required" })
    .trim()
    .min(1)
    .max(255)
    // A file's display name: one line, no path separators or markup.
    .regex(/^[^\u0000-\u001f\u007f/\\<>"]+$/, "Invalid document name"),
  type: z.enum(["PDF", "DOC", "DOCX", "TXT"]),
});

/**
 * The text of the ONE document the phone read for a read request: the app's opaque id for it,
 * its display name and type, and the text it extracted locally. Paths, URIs, URLs and anything
 * else are rejected outright.
 */
export const documentReadAnswerSchema = z.strictObject({
  conversationId: id.optional(),
  documentId: actionDocumentSchema.shape.documentId,
  name: actionDocumentSchema.shape.name,
  type: actionDocumentSchema.shape.type,
  text: z
    .string({ error: "text is required" })
    .max(MAX_DOCUMENT_CHARS, `text must be at most ${MAX_DOCUMENT_CHARS} characters`)
    .refine((t) => t.trim().length > 0, "text must not be empty"),
  truncated: z.boolean().optional(),
});

/** Why the phone could not read the document (the server writes the message the user sees). */
export const documentReadFailSchema = z.strictObject({
  conversationId: id.optional(),
  reason: z.enum(["not_found", "unavailable", "unsupported", "no_text", "encrypted", "unreadable", "cancelled"]),
});

export const actionHandoffSchema = z.strictObject({
  conversationId: id.optional(),
  result: z.enum(["whatsapp_opened", "share_opened", "unavailable"]),
});

// Photos. Only the server's opaque photo ids (photo_...) ever travel: never a path, a content URI,
// a device asset id or a file name. Strict: a userId (or anything else) in the body is rejected.

export const photoIdSchema = z.string({ error: "photoId is required" }).regex(/^photo_[a-f0-9]{20}$/, "Invalid photo id");

export const photoParamsSchema = z.strictObject({ photoId: photoIdSchema });

/** One photo the phone SHOWED for a search: when it was taken, its size, and the matched place. */
const shownPhotoSchema = z.strictObject({
  capturedAt: z.iso.datetime({ offset: true }).transform((s) => new Date(s)),
  width: z.number().int().min(1).max(100_000).optional(),
  height: z.number().int().min(1).max(100_000).optional(),
  place: z
    .strictObject({
      // The user's own saved place name, echoed into the chat history: one short line, no markup.
      name: z.string().trim().min(1).max(120).regex(/^[^\u0000-\u001f\u007f<>"]+$/, "Invalid place name"),
      evidence: z.enum(["gps", "time"]),
    })
    .optional(),
});

export const photoSearchResultSchema = z.strictObject({
  conversationId: id.optional(),
  outcome: z.enum(["found", "none", "permission_denied", "failed"]),
  photos: z.array(shownPhotoSchema).max(12).default([]),
  total: z.number().int().min(0).max(100_000).optional(),
  reason: z.enum(["no_visits", "content_only", "no_name_match"]).optional(),
  limited: z.boolean().optional(),
});

/** Largest base64 image accepted in a body (the decoded image is limited to 5 MB). */
export const MAX_IMAGE_BASE64 = 7_000_000;

/** The ONE photo the phone sends for an analysis request: its opaque id and the image itself. */
export const photoAnalysisAnswerSchema = z.strictObject({
  conversationId: id.optional(),
  photoId: photoIdSchema,
  image: z
    .string({ error: "image is required" })
    .min(1)
    .max(MAX_IMAGE_BASE64, "image is too large")
    .regex(/^[A-Za-z0-9+/]+={0,2}$/, "image must be base64"),
});

export const photoAnalysisFailSchema = z.strictObject({
  conversationId: id.optional(),
  reason: z.enum(["not_found", "unavailable", "permission", "unsupported", "too_large", "cancelled"]),
});
