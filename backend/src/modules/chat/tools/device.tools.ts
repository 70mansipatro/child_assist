import { z } from "zod";
import { PermissionType } from "../../../../generated/prisma/client";
import { redactSecrets } from "../ai/redact";
import { prepareDocumentRead } from "../documents/document-reads";
import { defineChatTool } from "./define-tool";
import { isoDateTime } from "./location.tools";
import { chatProviders, type DeviceDocument } from "./providers";
import { fail, ok, type ToolContext } from "./types";

// Photos and documents stay on the phone (Phases 5 and 6). These tools only ever see what the OS
// lets the app access, return metadata (never file paths or image bytes), and report honestly
// when the device cannot be reached.

const MAX_RESULTS = 30;
// Enough for a useful answer without pushing a whole book into the model.
export const MAX_DOCUMENT_TEXT = 12_000;

// Device IDs are opaque tokens; anything else is a manipulated argument.
const deviceId = z.string().regex(/^[A-Za-z0-9:_-]{1,128}$/, "Invalid id");

const DEVICE_UNAVAILABLE = fail(
  "INVALID_ARGUMENTS",
  "Pass the documentId of a document found with search_documents.",
);

/**
 * Without a device gateway, photo and document searches are handed to the app: it runs the
 * search on the phone, against only what the OS lets it access, and shows the matches to the
 * user directly. Nothing about the files reaches the backend or Gemini.
 */
function onDevice(query: Record<string, unknown>, note?: string) {
  return ok({
    handledOnDevice: true,
    query,
    note:
      note ??
      "The Child Assist app is searching the user's phone and will show any matches below your reply. " +
        "You cannot see the results: do not list, count or guess them. Just say you're showing what was found on their phone.",
  });
}

const DOCUMENT_SEARCH_NOTE =
  "The Child Assist app is searching the user's own documents on their phone and shows the result below " +
  "your reply: if exactly one document matches it shows that document with Open, Share and WhatsApp " +
  "buttons; if several match it asks the user which one they want; if none match it says the document " +
  "could not be found. You cannot see the results: never name, list, count or guess documents, and never " +
  "say one was found or sent. Reply with one short sentence such as \"Let me look for that document on your phone.\"";

function deviceDisplay(data: unknown) {
  const d = data as { handledOnDevice?: boolean; query?: Record<string, unknown> };
  return d.handledOnDevice ? { status: "device_lookup" as const, data: { query: d.query ?? {} } } : {};
}

function documentView(d: DeviceDocument) {
  return {
    id: d.id,
    name: d.name,
    type: d.type,
    sizeBytes: d.size ?? null,
    modifiedAt: d.modifiedAt?.toISOString() ?? null,
    addedAt: d.addedAt.toISOString(),
    available: d.available,
  };
}

export function deviceTools(ctx: ToolContext) {
  return {
    search_photos: defineChatTool(ctx, {
      name: "search_photos",
      kind: "photos",
      display: deviceDisplay,
      description:
        "Search photo metadata (name, date, type, size) in the photos the user allowed the app " +
        "to access. Never returns the images themselves.",
      inputSchema: z.strictObject({
        text: z.string().trim().max(100).optional().describe("Text the file name should contain"),
        startDate: isoDateTime("startDate").optional(),
        endDate: isoDateTime("endDate").optional(),
        limit: z.number().int().min(1).max(MAX_RESULTS).optional(),
      }),
      permission: PermissionType.PHOTOS,
      execute: async ({ text, startDate, endDate, limit }, { userId }) => {
        const device = chatProviders().device;
        if (!device.available) return onDevice({ text: text || null, startDate: startDate ?? null, endDate: endDate ?? null, limit: limit ?? 12 });
        const photos = await device.searchPhotos(userId, {
          text: text || undefined,
          since: startDate ? new Date(startDate) : undefined,
          before: endDate ? new Date(endDate) : undefined,
          limit: limit ?? 10,
        });
        return ok({
          photos: photos.slice(0, MAX_RESULTS).map((p) => ({
            id: p.id,
            name: p.name ?? null,
            takenAt: p.createdAt.toISOString(),
            modifiedAt: p.modifiedAt?.toISOString() ?? null,
            mimeType: p.mimeType ?? null,
            sizeBytes: p.fileSize ?? null,
            width: p.width ?? null,
            height: p.height ?? null,
          })),
        });
      },
    }),

    search_documents: defineChatTool(ctx, {
      name: "search_documents",
      kind: "documents",
      display: deviceDisplay,
      description:
        "Find one of the user's documents (PDF, DOC, DOCX, TXT) by name: 'send me the Python document', " +
        "'find my TCS PDF', 'show my project docx'. Always use this instead of guessing whether a document " +
        "exists. Searches only the documents the user added to Child Assist on their phone (file names and " +
        "types, never contents); there is no access to the rest of the phone.",
      inputSchema: z.strictObject({
        text: z
          .string()
          .trim()
          .max(100)
          .optional()
          .describe(
            "The words the user used for the document, e.g. 'python' or 'tcs project'. Leave out words " +
              "like send, me, my, the, document, file, and the type.",
          ),
        type: z.enum(["PDF", "DOC", "DOCX", "TXT"]).optional().describe("Only when the user named a type"),
        limit: z.number().int().min(1).max(MAX_RESULTS).optional(),
      }),
      permission: PermissionType.DOCUMENTS,
      execute: async ({ text, type, limit }, { userId }) => {
        const device = chatProviders().device;
        if (!device.available) {
          return onDevice({ text: text || null, type: type ?? null, limit: limit ?? 10 }, DOCUMENT_SEARCH_NOTE);
        }
        const documents = await device.searchDocuments(userId, { text: text || undefined, type, limit: limit ?? 10 });
        return ok({ documents: documents.slice(0, MAX_RESULTS).map(documentView) });
      },
    }),

    read_document: defineChatTool(ctx, {
      name: "read_document",
      kind: "document_text",
      display: (data) => {
        const d = data as { handledOnDevice?: boolean; requestId?: string; query?: Record<string, unknown> };
        return d.handledOnDevice
          ? { status: "device_lookup", data: { query: d.query ?? {}, requestId: d.requestId } }
          : {};
      },
      description:
        "Answer a question about what is INSIDE one of the user's documents: 'Python notes me kya hai?', " +
        "'Summarize the TCS document', 'What does this PDF say about loops?'. The app finds the document " +
        "on the phone (the user chooses if several match), checks it is still there, reads it and answers " +
        "below your reply. PDF, DOCX and TXT can be read; scanned PDFs and old DOC files cannot. Never use " +
        "this to send or share a document.",
      inputSchema: z.strictObject({
        documentId: deviceId.optional().describe("Only an id returned by search_documents with a device gateway"),
        document: z
          .string()
          .trim()
          .max(100)
          .regex(/^[^\r\n\t<>"]*$/)
          .optional()
          .describe(
            "The words the user used for the document, e.g. 'python notes'. Leave it out for 'this " +
              "document' / 'it', meaning the document already being discussed.",
          ),
        type: z.enum(["PDF", "DOC", "DOCX", "TXT"]).optional().describe("Only when the user named a type"),
        question: z
          .string()
          .trim()
          .min(1)
          .max(500)
          .optional()
          .describe(
            "What the user wants to know, in their own words and language, e.g. 'Python notes me kya hai?' " +
              "or 'what does it say about loops?'",
          ),
      }),
      permission: PermissionType.DOCUMENTS,
      execute: async ({ documentId, document, type, question }, toolCtx) => {
        const { userId } = toolCtx;
        const device = chatProviders().device;
        if (!device.available) {
          // The phone does the reading; the answer is written from that one document's text.
          const request = await prepareDocumentRead(toolCtx, {
            documentQuery: document || null,
            documentType: type ?? null,
            question: question ?? "Give a short overview of what this document contains.",
          });
          return ok({
            handledOnDevice: true,
            requestId: request.id,
            query: { text: document || null, type: type ?? null },
            note:
              "The Child Assist app is finding this document on the user's phone, checking it is still " +
              "there and reading it; the answer from its real content appears below your reply. You " +
              "cannot see the document: never guess, describe or summarise its content, and never name " +
              "it. Reply with one short sentence such as \"Let me read that document.\" in the user's language.",
          });
        }
        if (!documentId) return DEVICE_UNAVAILABLE;

        const doc = await device.readDocument(userId, documentId);
        if (!doc) return fail("DOCUMENT_NOT_FOUND", "No accessible document has that id.");
        if (!doc.available) {
          return fail("DOCUMENT_UNAVAILABLE", "The phone no longer allows access to this file. It may have been moved or deleted.");
        }
        if (doc.text === null) {
          return fail(
            "TEXT_EXTRACTION_UNAVAILABLE",
            `Reading the text of ${doc.type} files is not supported yet. The user can open it from the Documents screen.`,
          );
        }

        const text = redactSecrets(doc.text);
        return ok({
          document: documentView(doc),
          truncated: text.length > MAX_DOCUMENT_TEXT,
          text: text.slice(0, MAX_DOCUMENT_TEXT),
        });
      },
    }),
  };
}
