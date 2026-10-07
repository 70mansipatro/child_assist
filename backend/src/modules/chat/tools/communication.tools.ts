import { z } from "zod";
import { ChatActionChannel, ChatActionType, PermissionType } from "../../../../generated/prisma/client";
import { HISTORY_PERIODS, isLocalDate } from "../../../lib/local-dates";
import { emailConfigured, isSafeSubject, isValidEmail, MAX_EMAIL_BODY_LENGTH } from "../actions/email.service";
import { normalizePhone, preparePendingAction, type ActionDraft } from "../actions/pending-actions";
import { buildSharedLocations, resolveShareRange, type ShareKind } from "../actions/share-content";
import { defineChatTool, hasPermission, permissionRequired } from "./define-tool";
import { chatProviders } from "./providers";
import { fail, ok, type ToolContext, type ToolResult } from "./types";

// find_contact and web_search only read. prepare_email and prepare_whatsapp have side effects:
// they never send anything here. They prepare an action the user must confirm in the app (see
// actions/pending-actions.ts), and say so in their result.
//
// Phone contacts never reach the backend. find_contact hands the search to the app, which looks
// in the phone's own contacts and shows the match to the user. When an email or WhatsApp message
// is addressed to a contact by name, the app resolves that one contact on the phone the same way
// and sends back only the address the user picks.

// One line, no control characters or angle brackets: names are echoed into the confirmation.
const contactName = z
  .string()
  .trim()
  .min(1)
  .max(80)
  .regex(/^[^\r\n\t<>"]+$/, "Invalid name");

const localDate = (label: string) => z.string().refine(isLocalDate, `${label} must be a calendar date in YYYY-MM-DD format`);

const shareFields = {
  share: z
    .enum(["location", "travel_history"])
    .optional()
    .describe(
      "Include the user's own saved locations: 'location' for their location ('meri location'), " +
        "'travel_history' for where they went ('travel history', 'kahan kahan gaya'). The server adds " +
        "the exact places itself; never write locations into `message`.",
    ),
  period: z.enum(HISTORY_PERIODS).optional().describe("Which days to share, e.g. today ('aaj ki'). Default today."),
  startDate: localDate("startDate").optional().describe("First local day, YYYY-MM-DD, instead of period."),
  endDate: localDate("endDate").optional().describe("Last local day, YYYY-MM-DD (inclusive)."),
};

const awaitingNote =
  "Nothing has been sent. The app now shows the user exactly what will be sent (and, if the " +
  "recipient was given by name, lets them pick the contact on their phone). Tell them to check " +
  "it and confirm. Never say it was sent.";

function awaitingConfirmation(summary: string, id: string, extraNote = "") {
  return ok({
    status: "CONFIRMATION_REQUIRED",
    actionId: id,
    summary,
    note: extraNote ? `${awaitingNote} ${extraNote}` : awaitingNote,
  });
}

// The confirmation itself travels in pendingActions; the event only marks that one is waiting.
const confirmationDisplay = () => ({ status: "confirmation_required" as const });

interface Recipient {
  name: string | undefined;
  address: string | undefined;
}

interface ShareInput {
  share?: ShareKind;
  period?: (typeof HISTORY_PERIODS)[number];
  startDate?: string;
  endDate?: string;
}

/**
 * Common checks for both channels, then the draft to store. Returns a tool failure instead when
 * something is missing or not allowed; nothing is stored in that case.
 */
async function draftFor(
  ctx: ToolContext,
  channel: ChatActionChannel,
  recipient: Recipient,
  content: { message?: string; subject?: string; documentName?: string } & ShareInput,
): Promise<ToolResult<ActionDraft>> {
  if (!recipient.name && !recipient.address) {
    return fail("INVALID_ARGUMENTS", "Say who to send it to: ask the user for the contact's name.");
  }
  // A name is looked up in the phone's contacts, which needs the Contacts permission.
  if (!recipient.address && !(await hasPermission(ctx.userId, PermissionType.CONTACTS))) {
    return permissionRequired(PermissionType.CONTACTS);
  }

  let message = content.message?.trim() ?? "";
  let type: ChatActionType = channel === ChatActionChannel.EMAIL ? ChatActionType.SEND_EMAIL : ChatActionType.SEND_WHATSAPP;
  let dataSummary: string | null = null;
  let subject = content.subject?.trim() || null;

  if (content.share) {
    if (content.documentName) return fail("INVALID_ARGUMENTS", "Share either locations or a document, not both.");
    if (!(await hasPermission(ctx.userId, PermissionType.LOCATION))) return permissionRequired(PermissionType.LOCATION);
    // "Share my location" without a day means today's.
    const period = content.period ?? (content.startDate ? undefined : "today");
    const request = { kind: content.share, period, startDate: content.startDate, endDate: content.endDate };
    const range = resolveShareRange(request, ctx.zone);
    if (!range) return fail("INVALID_ARGUMENTS", "That period is not valid. Use a period, or startDate/endDate up to one year apart.");
    const shared = await buildSharedLocations(ctx.userId, request, ctx.zone, range);
    if (!shared) {
      return fail("NOTHING_TO_SHARE", "No saved locations were found for that period, so there is nothing to share. Nothing was prepared.");
    }
    message = message ? `${message}\n\n${shared.text}` : shared.text;
    type = content.share === "travel_history" ? ChatActionType.SHARE_TRAVEL_HISTORY : ChatActionType.SHARE_LOCATION;
    dataSummary = shared.dataSummary;
    subject ??= `Child Assist - ${shared.title}`;
  } else if (content.documentName) {
    if (!(await hasPermission(ctx.userId, PermissionType.DOCUMENTS))) return permissionRequired(PermissionType.DOCUMENTS);
    type = ChatActionType.SHARE_DOCUMENT;
    dataSummary = `Document: ${content.documentName}`;
  } else if (!message) {
    return fail("INVALID_ARGUMENTS", "Write the message to send. Ask the user what to say if it is not clear.");
  }

  if (message.length > MAX_EMAIL_BODY_LENGTH) return fail("INVALID_ARGUMENTS", "The message is too long.");
  return ok({
    type,
    channel,
    contactQuery: recipient.address ? null : (recipient.name ?? null),
    recipientName: recipient.name ?? null,
    recipientAddress: recipient.address ?? null,
    subject: channel === ChatActionChannel.EMAIL ? (subject ?? "Child Assist details") : null,
    message,
    dataSummary,
    documentQuery: content.documentName ?? null,
  });
}

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
      display: (data) => {
        const d = data as { query?: Record<string, unknown> };
        return { status: "device_lookup", data: { query: d.query ?? {} } };
      },
      description:
        "Look up one of the user's phone contacts by name to show its phone number or email " +
        "('Mansi ka number do', 'Papa ka email kya hai', \"What is Rahul's number?\"). Any name can " +
        "be a contact, including relations like Papa or Mummy. The search runs on the user's phone " +
        "and the app shows the result: you never see the contact details.",
      inputSchema: z.strictObject({
        query: contactName.describe("The contact's name exactly as the user said it, without words like 'ka number'"),
        field: z
          .enum(["phone", "email", "any"])
          .optional()
          .describe("What the user wants: phone (number/mobile), email, or any"),
      }),
      permission: PermissionType.CONTACTS,
      execute: async ({ query, field }) =>
        ok({
          handledOnDevice: true,
          query: { name: query, field: field ?? "any" },
          note:
            "The Child Assist app is searching the user's phone contacts and will show the result below " +
            "your reply (or ask the user to choose if several contacts match). You cannot see it: never " +
            "state, guess or invent a number or email. Just say you're checking their contacts for that name.",
        }),
    }),

    prepare_email: defineChatTool(ctx, {
      name: "prepare_email",
      kind: "send_action",
      display: confirmationDisplay,
      description:
        "Prepare an email from the user ('Mansi ko ye details email kar do', 'Mail my travel history " +
        "to Papa'). It is NOT sent: the app shows the user the recipient and the exact content, and " +
        "only sends it if they confirm. Give recipientName for a contact (the app finds their email " +
        "on the phone), or recipientEmail only when the user typed an address.",
      inputSchema: z.strictObject({
        recipientName: contactName.optional().describe("The contact's name as the user said it"),
        recipientEmail: z.string().trim().max(254).optional().describe("Only an address the user explicitly gave"),
        subject: z.string().trim().max(200).optional(),
        message: z
          .string()
          .trim()
          .max(5000)
          .optional()
          .describe("The email text. For 'ye details', write the details from this conversation."),
        documentName: z.string().trim().max(120).optional().describe("Not supported for email"),
        ...shareFields,
      }),
      selfAudited: true,
      execute: async ({ recipientName, recipientEmail, subject, message, documentName, ...share }, toolCtx) => {
        if (!emailConfigured()) {
          return fail("ACTION_NOT_CONFIGURED", "Sending email is not set up on the Child Assist server. Nothing was prepared.");
        }
        if (documentName) {
          return fail(
            "NOT_SUPPORTED",
            "Documents stay on the user's phone and cannot be attached to an email yet. They can be shared on WhatsApp instead.",
          );
        }
        if (recipientEmail !== undefined && !isValidEmail(recipientEmail)) {
          return fail(
            "INVALID_RECIPIENT",
            "That email address is not valid. Ask the user for the correct address; do not change it yourself. Nothing was prepared.",
          );
        }
        if (subject && !isSafeSubject(subject)) return fail("INVALID_ARGUMENTS", "The subject must be one short line.");

        const draft = await draftFor(toolCtx, ChatActionChannel.EMAIL, { name: recipientName, address: recipientEmail }, {
          message,
          subject,
          ...share,
        });
        if (!draft.success) return draft;
        const action = await preparePendingAction(toolCtx, draft.data);
        return awaitingConfirmation(action.summary, action.id);
      },
    }),

    prepare_whatsapp: defineChatTool(ctx, {
      name: "prepare_whatsapp",
      kind: "send_action",
      display: confirmationDisplay,
      description:
        "Prepare a WhatsApp message from the user ('Rahul ko WhatsApp karo', 'Papa ko WhatsApp par " +
        "meri location bhejo', 'Mansi ko ye document WhatsApp karo'). Nothing is sent by you or the " +
        "server: after the user confirms, the app opens WhatsApp with the message ready and the user " +
        "taps Send there. Give recipientName for a contact (the app finds the number on the phone).",
      inputSchema: z.strictObject({
        recipientName: contactName.optional().describe("The contact's name as the user said it"),
        recipientPhone: z.string().trim().max(32).optional().describe("Only a number the user explicitly gave"),
        message: z.string().trim().max(5000).optional().describe("The message text to prefill in WhatsApp"),
        documentName: z
          .string()
          .trim()
          .max(120)
          .regex(/^[^\r\n\t<>"]+$/)
          .optional()
          .describe("To share one of the user's documents: words from its file name"),
        ...shareFields,
      }),
      selfAudited: true,
      execute: async ({ recipientName, recipientPhone, message, documentName, ...share }, toolCtx) => {
        let phone: string | undefined;
        if (recipientPhone !== undefined) {
          phone = normalizePhone(recipientPhone) ?? undefined;
          if (!phone) return fail("INVALID_RECIPIENT", "That phone number is not valid. Ask the user for the correct number.");
        }
        const draft = await draftFor(toolCtx, ChatActionChannel.WHATSAPP, { name: recipientName, address: phone }, {
          message,
          documentName,
          ...share,
        });
        if (!draft.success) return draft;
        const action = await preparePendingAction(toolCtx, draft.data);
        return awaitingConfirmation(
          action.summary,
          action.id,
          "Even after they confirm, WhatsApp only opens with the message ready; the user sends it there, so never say it was sent.",
        );
      },
    }),
  };
}
