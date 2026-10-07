import {
  ChatActionChannel,
  ChatActionStatus,
  ChatActionType,
  ChatMessageRole,
  Prisma,
  type ChatAction,
} from "../../../../generated/prisma/client";
import { HttpError } from "../../../lib/http-error";
import { prisma } from "../../../lib/prisma";
import { addMessage, recordToolCall, transitionToolCall, type ToolCallStatus } from "../chat.service";
import type { PendingActionView, ToolContext } from "../tools/types";
import { isValidEmail, sendUserEmail } from "./email.service";

// Side-effect actions (an email, a WhatsApp message) never run inside a chat turn. The assistant
// only *prepares* one: it is stored as a PENDING ChatAction (plus an AWAITING_CONFIRMATION audit
// row with the same id) and returned to the app, which shows exactly what will be sent. Only an
// explicit POST /api/chat/actions/:id/confirm from the same user moves it on:
//
//   PENDING ──confirm──▶ CONFIRMED ──▶ COMPLETED | FAILED       (email: sent by the backend)
//   PENDING ──confirm──▶ CONFIRMED ──handoff──▶ COMPLETED       (WhatsApp: opened on the phone)
//   PENDING ──cancel───▶ CANCELLED
//   PENDING/CONFIRMED ──10 minutes──▶ EXPIRED
//
// Every transition is a single conditional UPDATE, so a double tap or two concurrent requests can
// never send twice. The recipient and content are cleared once an action reaches a final status.

export const PENDING_ACTION_TTL_MS = 10 * 60 * 1000;

/** Content cleared when an action is finished: it was only kept so the user could confirm it. */
const SCRUBBED = { recipientAddress: null, subject: null, message: null } as const;

export interface ActionDraft {
  type: ChatActionType;
  channel: ChatActionChannel;
  /** The name the user said, looked up on the phone when no address was given. */
  contactQuery: string | null;
  recipientName: string | null;
  recipientAddress: string | null;
  subject: string | null;
  message: string;
  dataSummary: string | null;
  documentQuery: string | null;
}

// ---------------------------------------------------------------------------------------------
// Views

function who(action: Pick<ChatAction, "recipientName" | "recipientAddress" | "contactQuery" | "channel">): string {
  const name = action.recipientName ?? action.contactQuery;
  const address = action.recipientAddress;
  if (name && address && name !== address) {
    return action.channel === ChatActionChannel.EMAIL ? `${name} <${address}>` : `${name} (${address})`;
  }
  return name ?? address ?? "this contact";
}

/** The confirmation question. Written here, never by the model. */
export function summaryFor(action: ChatAction): string {
  const target = who(action);
  const via = action.channel === ChatActionChannel.EMAIL ? "by email" : "on WhatsApp";
  switch (action.type) {
    case ChatActionType.SEND_EMAIL:
      return action.subject
        ? `Send an email to ${target} with the subject "${action.subject}"?`
        : `Send an email to ${target}?`;
    case ChatActionType.SEND_WHATSAPP:
      return `Send this WhatsApp message to ${target}?`;
    case ChatActionType.SHARE_LOCATION:
      return `Share your location with ${target} ${via}?`;
    case ChatActionType.SHARE_TRAVEL_HISTORY:
      return `Share your travel history with ${target} ${via}?`;
    case ChatActionType.SHARE_DOCUMENT:
      return action.documentQuery
        ? `Share the document "${action.documentQuery}" with ${target} ${via}?`
        : `Share a document with ${target} ${via}?`;
  }
}

const TOOL_NAMES: Record<ChatActionChannel, string> = {
  [ChatActionChannel.EMAIL]: "prepare_email",
  [ChatActionChannel.WHATSAPP]: "prepare_whatsapp",
};

export function toView(action: ChatAction): PendingActionView {
  return {
    id: action.id,
    toolName: TOOL_NAMES[action.channel],
    type: action.type,
    channel: action.channel,
    status: action.status,
    summary: summaryFor(action),
    contactQuery: action.contactQuery,
    recipientField: action.channel === ChatActionChannel.EMAIL ? "email" : "phone",
    recipientName: action.recipientName,
    recipientAddress: action.recipientAddress,
    subject: action.subject,
    message: action.message,
    dataSummary: action.dataSummary,
    documentQuery: action.documentQuery,
    expiresAt: action.expiresAt.toISOString(),
  };
}

// ---------------------------------------------------------------------------------------------
// Preparing (chat turn)

/** Marks every PENDING/CONFIRMED action past its deadline as EXPIRED and clears its content. */
export async function expireStaleActions(now = new Date()): Promise<void> {
  const stale = await prisma.chatAction.findMany({
    // completedAt is set while an email is being sent: never expire one mid-delivery.
    where: { status: { in: [ChatActionStatus.PENDING, ChatActionStatus.CONFIRMED] }, expiresAt: { lte: now }, completedAt: null },
    select: { id: true, userId: true, status: true },
    take: 200,
  });
  for (const action of stale) {
    const { count } = await prisma.chatAction.updateMany({
      where: { id: action.id, status: action.status, completedAt: null },
      data: { status: ChatActionStatus.EXPIRED, ...SCRUBBED },
    });
    if (count === 1) await audit(action.userId, action.id, auditStatusOf(action.status), "CANCELLED");
  }
}

/** Stores an action awaiting the user's confirmation. Does not execute anything. */
export async function preparePendingAction(ctx: ToolContext, draft: ActionDraft): Promise<PendingActionView> {
  await expireStaleActions();
  const call = await recordToolCall(ctx.userId, ctx.conversationId, {
    toolName: TOOL_NAMES[draft.channel],
    status: "AWAITING_CONFIRMATION",
    confirmationRequired: true,
  });
  const action = await prisma.chatAction.create({
    data: {
      id: call.id,
      userId: ctx.userId,
      conversationId: ctx.conversationId,
      type: draft.type,
      channel: draft.channel,
      contactQuery: draft.contactQuery,
      recipientName: draft.recipientName,
      recipientAddress: draft.recipientAddress,
      subject: draft.subject,
      message: draft.message,
      dataSummary: draft.dataSummary,
      documentQuery: draft.documentQuery,
      expiresAt: new Date(Date.now() + PENDING_ACTION_TTL_MS),
    },
  });
  const view = toView(action);
  ctx.run.pendingActions.push(view);
  return view;
}

/** Drops actions prepared during a chat turn that failed, so they can never be confirmed. */
export async function discardPendingActions(userId: string, ids: string[]): Promise<void> {
  for (const id of ids) {
    await prisma.chatAction
      .updateMany({ where: { id, userId, status: ChatActionStatus.PENDING }, data: { status: ChatActionStatus.CANCELLED, ...SCRUBBED } })
      .catch(() => undefined);
    await transitionToolCall(userId, id, "AWAITING_CONFIRMATION", "CANCELLED").catch(() => false);
  }
}

// ---------------------------------------------------------------------------------------------
// The app's calls (all authenticated; userId always from the verified JWT)

export interface ActionScope {
  /** When given, the action must also belong to this conversation. */
  conversationId?: string;
}

const notFound = () => new HttpError(404, "Action not found");

/** The user's own action, or 404: someone else's action looks exactly like a missing one. */
async function load(userId: string, id: string, scope: ActionScope): Promise<ChatAction> {
  const action = await prisma.chatAction.findFirst({
    where: { id, userId, ...(scope.conversationId ? { conversationId: scope.conversationId } : {}) },
  });
  if (!action) throw notFound();
  return action;
}

/** Explains why a conditional update matched nothing, and records expiry. */
async function rejection(userId: string, id: string, scope: ActionScope, expected: ChatActionStatus): Promise<HttpError> {
  const action = await load(userId, id, scope);
  if (action.status === ChatActionStatus.EXPIRED || (action.status === expected && action.expiresAt <= new Date())) {
    await expireStaleActions();
    return new HttpError(410, "This action has expired. Please ask Child Assist again.", "ACTION_EXPIRED");
  }
  if (action.status === expected && action.recipientAddress === null) {
    return new HttpError(409, "Choose who to send it to first.", "RECIPIENT_REQUIRED");
  }
  return new HttpError(409, "This action has already been handled", "ACTION_ALREADY_HANDLED");
}

/** A phone number as it may be dialled: digits, optionally a leading +, 7 to 15 digits. */
export function normalizePhone(raw: string): string | null {
  const trimmed = raw.trim();
  if (!/^[+\d(][\d\s().-]*$/.test(trimmed)) return null;
  const digits = trimmed.replace(/\D/g, "");
  if (digits.length < 7 || digits.length > 15) return null;
  return trimmed.startsWith("+") ? `+${digits}` : digits;
}

/**
 * Sets who a PENDING action goes to, after the app looked the contact up on the phone and the
 * user picked one. Only this one address is ever sent by the app, never the address book. It can
 * be set once: the user then confirms exactly that recipient.
 */
export async function setActionRecipient(
  userId: string,
  id: string,
  input: { name?: string; address: string },
  scope: ActionScope = {},
): Promise<PendingActionView> {
  const action = await load(userId, id, scope);
  let address: string | null;
  if (action.channel === ChatActionChannel.EMAIL) {
    address = input.address.trim();
    if (!isValidEmail(address)) throw new HttpError(400, "That email address doesn't look right.", "INVALID_EMAIL");
  } else {
    address = normalizePhone(input.address);
    if (!address) throw new HttpError(400, "That phone number doesn't look right.", "INVALID_PHONE");
  }
  const name = input.name?.trim() || action.recipientName || action.contactQuery;

  const { count } = await prisma.chatAction.updateMany({
    where: { id, userId, status: ChatActionStatus.PENDING, recipientAddress: null, expiresAt: { gt: new Date() } },
    data: { recipientAddress: address, recipientName: name },
  });
  if (count === 0) {
    const current = await load(userId, id, scope);
    if (current.status === ChatActionStatus.PENDING && current.recipientAddress !== null && current.expiresAt > new Date()) {
      throw new HttpError(409, "The recipient has already been chosen.", "RECIPIENT_ALREADY_SET");
    }
    throw await rejection(userId, id, scope, ChatActionStatus.PENDING);
  }
  return toView(await load(userId, id, scope));
}

export interface ActionOutcome extends PendingActionView {
  /** What the app shows on the card (also stored as an assistant message when final). */
  outcomeMessage: string;
  /** WhatsApp only: what the phone must open. The user still sends it in WhatsApp. */
  handoff?: { phone: string; message: string; documentQuery: string | null };
}

function outcome(action: ChatAction, outcomeMessage: string, extra: Partial<ActionOutcome> = {}): ActionOutcome {
  return { ...toView(action), outcomeMessage, ...extra };
}

/**
 * The user tapped Confirm. Email is sent now; a WhatsApp message is handed to the phone, which
 * opens WhatsApp for the user to send it themselves.
 */
export async function confirmPendingAction(userId: string, id: string, scope: ActionScope = {}): Promise<ActionOutcome> {
  await load(userId, id, scope);
  const now = new Date();
  const { count } = await prisma.chatAction.updateMany({
    where: {
      id,
      userId,
      ...(scope.conversationId ? { conversationId: scope.conversationId } : {}),
      status: ChatActionStatus.PENDING,
      expiresAt: { gt: now },
      recipientAddress: { not: null },
    },
    // The phone gets a fresh window to open WhatsApp after the user confirmed.
    data: { status: ChatActionStatus.CONFIRMED, confirmedAt: now, expiresAt: new Date(now.getTime() + PENDING_ACTION_TTL_MS) },
  });
  if (count === 0) throw await rejection(userId, id, scope, ChatActionStatus.PENDING);
  await audit(userId, id, "AWAITING_CONFIRMATION", "PENDING", { confirmed: true });

  const action = await load(userId, id, scope);
  if (action.channel === ChatActionChannel.EMAIL) return executeEmailAction(userId, id);

  return outcome(action, "Opening WhatsApp...", {
    handoff: { phone: action.recipientAddress!, message: action.message ?? "", documentQuery: action.documentQuery },
  });
}

/**
 * Sends a CONFIRMED email action: the backend's "send_email". It refuses anything the user has
 * not confirmed, so neither the model nor a crafted request can send without confirmation. It
 * claims the action first, so it sends at most once.
 */
export async function executeEmailAction(userId: string, id: string): Promise<ActionOutcome> {
  const claimed = await prisma.chatAction.updateMany({
    where: { id, userId, channel: ChatActionChannel.EMAIL, status: ChatActionStatus.CONFIRMED, completedAt: null },
    data: { completedAt: new Date() },
  });
  if (claimed.count === 0) {
    const action = await load(userId, id, {});
    if (action.status === ChatActionStatus.PENDING) {
      throw new HttpError(409, "This email has not been confirmed.", "CONFIRMATION_REQUIRED");
    }
    throw new HttpError(409, "This action has already been handled", "ACTION_ALREADY_HANDLED");
  }

  const action = await load(userId, id, {});
  const user = await prisma.user.findUnique({ where: { id: userId }, select: { name: true, email: true } });
  let delivered = false;
  try {
    ({ delivered } = await sendUserEmail({
      to: action.recipientAddress ?? "",
      toName: action.recipientName,
      subject: action.subject ?? "Message from Child Assist",
      message: action.message ?? "",
      senderName: user?.name ?? null,
      senderEmail: user?.email ?? null,
    }));
  } catch (err) {
    const e = err instanceof Error ? err : new Error(String(err));
    console.error(`Confirmed email action failed: ${e.name}`);
  }

  const name = action.recipientName ?? "them";
  const message = delivered
    ? `Email sent to ${name}.`
    : `Sorry, I couldn't send the email to ${name}. Nothing was delivered. Please try again later.`;
  const final = await prisma.chatAction.update({
    where: { id },
    data: { status: delivered ? ChatActionStatus.COMPLETED : ChatActionStatus.FAILED, completedAt: new Date(), ...SCRUBBED },
  });
  await audit(userId, id, "PENDING", delivered ? "SUCCEEDED" : "FAILED");
  await note(userId, action.conversationId, message);
  return outcome(final, message);
}

export type HandoffResult = "whatsapp_opened" | "share_opened" | "unavailable";

/**
 * The phone reports what happened after a confirmed WhatsApp action. Opening WhatsApp is not
 * sending: the user still taps Send there, so nothing here ever says the message was sent.
 */
export async function completeHandoff(
  userId: string,
  id: string,
  result: HandoffResult,
  scope: ActionScope = {},
): Promise<ActionOutcome> {
  const action = await load(userId, id, scope);
  if (action.channel !== ChatActionChannel.WHATSAPP) throw notFound();
  const name = action.recipientName ?? "your contact";

  if (result === "unavailable") {
    // Stays CONFIRMED so the user can still use the share fallback before it expires.
    if (action.status !== ChatActionStatus.CONFIRMED) throw await rejection(userId, id, scope, ChatActionStatus.CONFIRMED);
    return outcome(action, "WhatsApp isn't available on this device.");
  }

  const { count } = await prisma.chatAction.updateMany({
    where: { id, userId, status: ChatActionStatus.CONFIRMED },
    data: { status: ChatActionStatus.COMPLETED, completedAt: new Date(), ...SCRUBBED },
  });
  if (count === 0) throw await rejection(userId, id, scope, ChatActionStatus.CONFIRMED);
  await audit(userId, id, "PENDING", "SUCCEEDED");

  const message =
    result === "whatsapp_opened"
      ? `WhatsApp opened for ${name} with your message. Tap Send in WhatsApp to deliver it.`
      : `Share options opened for ${name}. Nothing is sent until you send it from the app you choose.`;
  await note(userId, action.conversationId, message);
  return outcome(await load(userId, id, scope), message);
}

/** Declines a prepared action. It can never run afterwards. */
export async function cancelPendingAction(userId: string, id: string, scope: ActionScope = {}): Promise<ActionOutcome> {
  const action = await load(userId, id, scope);
  const { count } = await prisma.chatAction.updateMany({
    where: { id, userId, status: { in: [ChatActionStatus.PENDING, ChatActionStatus.CONFIRMED] }, completedAt: null },
    data: { status: ChatActionStatus.CANCELLED, ...SCRUBBED },
  });
  if (count === 0) throw await rejection(userId, id, scope, action.status);
  await audit(userId, id, auditStatusOf(action.status), "CANCELLED");
  const message = "Okay, I didn't send anything.";
  await note(userId, action.conversationId, message);
  return outcome(await load(userId, id, scope), message);
}

// ---------------------------------------------------------------------------------------------

/** The audit row's status while the action is open: awaiting the user, or confirmed and running. */
function auditStatusOf(status: ChatActionStatus): ToolCallStatus {
  return status === ChatActionStatus.PENDING ? "AWAITING_CONFIRMATION" : "PENDING";
}

/** Keeps the ChatToolCall audit row in step. Best effort: it never blocks the action itself. */
async function audit(
  userId: string,
  id: string,
  from: ToolCallStatus,
  to: ToolCallStatus,
  data: { confirmed?: boolean } = {},
): Promise<void> {
  await transitionToolCall(userId, id, from, to, data).catch(() => false);
}

/** Records the outcome in the conversation, so the chat history says what really happened. */
async function note(userId: string, conversationId: string, content: string): Promise<void> {
  try {
    await addMessage(userId, conversationId, { role: ChatMessageRole.CHAT_ASSISTANT, content });
  } catch (err) {
    // The conversation may have been deleted meanwhile; the action outcome still stands.
    if (!(err instanceof HttpError) && !(err instanceof Prisma.PrismaClientKnownRequestError)) throw err;
  }
}
