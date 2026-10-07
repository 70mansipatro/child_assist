import { z } from "zod";
import { PermissionType } from "../../../../generated/prisma/client";
import { preparePendingAction } from "../actions/pending-actions";
import { defineChatTool } from "./define-tool";
import { isoDateTime } from "./location.tools";
import { chatProviders } from "./providers";
import { fail, ok, type ToolContext } from "./types";

// find_contact and web_search only read. send_email, share_location and share_document have side
// effects: they never send anything here. They prepare an action the user must confirm in the
// app (see actions/pending-actions.ts), and say so in their result.

// One line, no control characters: recipients are echoed into the confirmation prompt.
const recipient = z
  .string()
  .trim()
  .min(1)
  .max(120)
  .regex(/^[^\r\n\t<>]+$/, "Invalid recipient")
  .describe("The contact's name or email address, as the user said it");

const NOT_CONFIGURED = fail(
  "ACTION_NOT_CONFIGURED",
  "Sending messages is not set up in Child Assist yet. Nothing was sent.",
);

function awaitingConfirmation(summary: string, id: string) {
  return ok({
    status: "CONFIRMATION_REQUIRED",
    actionId: id,
    summary,
    note: "Nothing has been sent. The app will ask the user to confirm. Do not say it was sent.",
  });
}

// The confirmation itself travels in pendingActions; the event only marks that one is waiting.
const confirmationDisplay = () => ({ status: "confirmation_required" as const });

export function webTools(ctx: ToolContext) {
  return {
    web_search: defineChatTool(ctx, {
      name: "web_search",
      kind: "web_search",
      description: "Search the live web, e.g. for a restaurant's menu or opening hours.",
      inputSchema: z.strictObject({ query: z.string().trim().min(1).max(300) }),
      execute: async ({ query }) => {
        const provider = chatProviders().webSearch;
        if (!provider) {
          return fail(
            "WEB_SEARCH_NOT_CONFIGURED",
            "Live web search is not configured. Do not guess or invent web information such as menus or prices.",
          );
        }
        const results = await provider.searchWeb(query);
        return ok({ results: results.slice(0, 8).map(({ title, url, snippet }) => ({ title, url, snippet })) });
      },
    }),
  };
}

export function communicationTools(ctx: ToolContext) {
  return {
    find_contact: defineChatTool(ctx, {
      name: "find_contact",
      kind: "contacts",
      description: "Look up one of the user's contacts by name.",
      inputSchema: z.strictObject({ name: z.string().trim().min(1).max(100) }),
      execute: async ({ name }, { userId }) => {
        const provider = chatProviders().contacts;
        if (!provider) return fail("CONTACTS_NOT_CONFIGURED", "Contacts are not available to the assistant yet.");
        const contacts = await provider.findContacts(userId, name);
        return ok({ contacts: contacts.slice(0, 5).map((c) => ({ name: c.name, email: c.email ?? null })) });
      },
    }),

    send_email: defineChatTool(ctx, {
      name: "send_email",
      kind: "send_action",
      display: confirmationDisplay,
      description:
        "Prepare an email to someone. It is NOT sent: the user must confirm it in the app first.",
      inputSchema: z.strictObject({
        to: recipient,
        subject: z.string().trim().min(1).max(200),
        body: z.string().trim().min(1).max(5000),
      }),
      selfAudited: true,
      execute: async ({ to, subject, body }, toolCtx) => {
        if (!chatProviders().communication) return NOT_CONFIGURED;
        const summary = `Send an email to ${to} with the subject "${subject}"?`;
        const action = await preparePendingAction(toolCtx, "send_email", { kind: "send_email", to, subject, body }, summary);
        return awaitingConfirmation(summary, action.id);
      },
    }),

    share_location: defineChatTool(ctx, {
      name: "share_location",
      kind: "send_action",
      display: confirmationDisplay,
      description:
        "Prepare sending the user's saved location details for a period to someone. It is NOT " +
        "sent: the user must confirm it in the app first.",
      inputSchema: z.strictObject({
        to: recipient,
        startDate: isoDateTime("startDate").optional(),
        endDate: isoDateTime("endDate").optional(),
      }),
      permission: PermissionType.LOCATION,
      selfAudited: true,
      execute: async ({ to, startDate, endDate }, toolCtx) => {
        if (!chatProviders().communication) return NOT_CONFIGURED;
        const summary = `Send your location details to ${to}?`;
        const action = await preparePendingAction(
          toolCtx,
          "share_location",
          {
            kind: "share_location",
            to,
            since: startDate ? new Date(startDate) : undefined,
            before: endDate ? new Date(endDate) : undefined,
          },
          summary,
        );
        return awaitingConfirmation(summary, action.id);
      },
    }),

    share_document: defineChatTool(ctx, {
      name: "share_document",
      kind: "send_action",
      display: confirmationDisplay,
      description:
        "Prepare sending one of the user's documents (found with search_documents) to someone. " +
        "It is NOT sent: the user must confirm it in the app first.",
      inputSchema: z.strictObject({
        to: recipient,
        documentId: z.string().regex(/^[A-Za-z0-9:_-]{1,128}$/, "Invalid id"),
      }),
      permission: PermissionType.DOCUMENTS,
      selfAudited: true,
      execute: async ({ to, documentId }, toolCtx) => {
        if (!chatProviders().communication) return NOT_CONFIGURED;
        const device = chatProviders().device;
        if (!device.available) {
          return fail("DEVICE_DATA_UNAVAILABLE", "Documents stay on the phone and the assistant cannot reach them yet.");
        }
        const doc = await device.readDocument(toolCtx.userId, documentId);
        if (!doc || !doc.available) return fail("DOCUMENT_NOT_FOUND", "No accessible document has that id.");

        const summary = `Send the document "${doc.name}" to ${to}?`;
        const action = await preparePendingAction(
          toolCtx,
          "share_document",
          { kind: "share_document", to, documentId, documentName: doc.name },
          summary,
        );
        return awaitingConfirmation(summary, action.id);
      },
    }),
  };
}
