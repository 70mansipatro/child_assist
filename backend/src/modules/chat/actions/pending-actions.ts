import { ChatMessageRole, PermissionType } from "../../../../generated/prisma/client";
import { HttpError } from "../../../lib/http-error";
import { listLocations } from "../../location/location.service";
import { addMessage, getToolCall, recordToolCall, transitionToolCall } from "../chat.service";
import { hasPermission } from "../tools/define-tool";
import { chatProviders, type OutgoingMessage } from "../tools/providers";
import type { PendingActionView, ToolContext } from "../tools/types";

// Side-effect actions (send_email, share_location, share_document) never run inside a chat turn.
// The assistant only *prepares* one: it is audited as AWAITING_CONFIRMATION and returned to the
// app, which shows the backend-written summary ("Send your location details to Mansi?"). Only an
// explicit POST /api/chat/actions/:id/confirm from the same user executes it.
//
// The action's arguments (recipient, message text) are kept in memory only, never in the
// database, and expire. This is single-instance storage: running several backend instances
// needs a shared store (e.g. Redis) behind the same functions.

export const PENDING_ACTION_TTL_MS = 15 * 60 * 1000;

export type PendingPayload =
  | { kind: "send_email"; to: string; subject: string; body: string }
  | { kind: "share_location"; to: string; since?: Date; before?: Date }
  | { kind: "share_document"; to: string; documentId: string; documentName: string };

interface StoredAction {
  userId: string;
  conversationId: string;
  toolName: string;
  payload: PendingPayload;
  expiresAt: number;
}

const store = new Map<string, StoredAction>();

function sweep(now = Date.now()): void {
  for (const [id, action] of store) {
    if (action.expiresAt <= now) store.delete(id);
  }
}

/** Records and remembers an action awaiting the user's confirmation. Does not execute it. */
export async function preparePendingAction(
  ctx: ToolContext,
  toolName: string,
  payload: PendingPayload,
  summary: string,
): Promise<PendingActionView> {
  sweep();
  const call = await recordToolCall(ctx.userId, ctx.conversationId, {
    toolName,
    status: "AWAITING_CONFIRMATION",
    confirmationRequired: true,
  });
  const expiresAt = Date.now() + PENDING_ACTION_TTL_MS;
  store.set(call.id, { userId: ctx.userId, conversationId: ctx.conversationId, toolName, payload, expiresAt });

  const view: PendingActionView = { id: call.id, toolName, summary, expiresAt: new Date(expiresAt).toISOString() };
  ctx.run.pendingActions.push(view);
  return view;
}

export interface ActionOutcome {
  id: string;
  status: "SUCCEEDED" | "FAILED" | "CANCELLED";
  message: string;
}

/** Executes a prepared action after the user explicitly confirmed it. */
export async function confirmPendingAction(userId: string, id: string): Promise<ActionOutcome> {
  sweep();
  // 404 for someone else's action, exactly as for a missing one.
  const call = await getToolCall(userId, id);
  if (!call.confirmationRequired) throw new HttpError(404, "Action not found");

  const stored = store.get(id);
  if (call.status !== "AWAITING_CONFIRMATION") {
    throw new HttpError(409, "This action has already been handled", "ACTION_ALREADY_HANDLED");
  }
  if (!stored || stored.userId !== userId) {
    await transitionToolCall(userId, id, "AWAITING_CONFIRMATION", "CANCELLED");
    throw new HttpError(410, "This action has expired. Please ask Child Assist again.", "ACTION_EXPIRED");
  }

  // Claim the action atomically so a double tap cannot send twice.
  if (!(await transitionToolCall(userId, id, "AWAITING_CONFIRMATION", "PENDING", { confirmed: true }))) {
    throw new HttpError(409, "This action has already been handled", "ACTION_ALREADY_HANDLED");
  }
  store.delete(id);

  let outcome: ActionOutcome;
  try {
    outcome = await execute(userId, id, stored.payload);
  } catch (err) {
    const e = err instanceof Error ? err : new Error(String(err));
    console.error(`Confirmed action ${stored.toolName} failed: ${e.name}: ${e.message}`);
    outcome = { id, status: "FAILED", message: "Sorry, that could not be sent. Nothing was delivered." };
  }

  await transitionToolCall(userId, id, "PENDING", outcome.status);
  await addMessage(userId, call.conversationId, { role: ChatMessageRole.CHAT_ASSISTANT, content: outcome.message });
  return outcome;
}

/** Declines a prepared action. It can never run afterwards. */
export async function cancelPendingAction(userId: string, id: string): Promise<ActionOutcome> {
  const call = await getToolCall(userId, id);
  if (!call.confirmationRequired) throw new HttpError(404, "Action not found");
  if (!(await transitionToolCall(userId, id, "AWAITING_CONFIRMATION", "CANCELLED"))) {
    throw new HttpError(409, "This action has already been handled", "ACTION_ALREADY_HANDLED");
  }
  store.delete(id);
  const outcome: ActionOutcome = { id, status: "CANCELLED", message: "Okay, I didn't send anything." };
  await addMessage(userId, call.conversationId, { role: ChatMessageRole.CHAT_ASSISTANT, content: outcome.message });
  return outcome;
}

/** Drops actions prepared during a chat turn that failed, so they can never be confirmed. */
export async function discardPendingActions(userId: string, ids: string[]): Promise<void> {
  for (const id of ids) {
    store.delete(id);
    await transitionToolCall(userId, id, "AWAITING_CONFIRMATION", "CANCELLED").catch(() => false);
  }
}

async function execute(userId: string, id: string, payload: PendingPayload): Promise<ActionOutcome> {
  const communication = chatProviders().communication;
  if (!communication) {
    // Never pretend: without a provider nothing can be delivered.
    return { id, status: "FAILED", message: "Sending messages isn't set up yet, so nothing was sent." };
  }

  let message: OutgoingMessage;
  switch (payload.kind) {
    case "send_email":
      message = { to: payload.to, subject: payload.subject, body: payload.body };
      break;
    case "share_location": {
      // Permissions are checked again: they may have been revoked since the action was prepared.
      if (!(await hasPermission(userId, PermissionType.LOCATION))) {
        return { id, status: "FAILED", message: "Location access is turned off, so nothing was sent." };
      }
      const locations = await listLocations(userId, { limit: 20, since: payload.since, before: payload.before });
      const lines = locations.map((l) => {
        const place = [l.placeName, l.address ?? l.city, l.country].filter(Boolean).join(", ");
        return `- ${l.capturedAt.toISOString()}: ${place || `${l.latitude}, ${l.longitude}`}`;
      });
      message = {
        to: payload.to,
        subject: "Location details shared from Child Assist",
        body: lines.length > 0 ? lines.join("\n") : "No saved locations for this period.",
      };
      break;
    }
    case "share_document":
      if (!(await hasPermission(userId, PermissionType.DOCUMENTS))) {
        return { id, status: "FAILED", message: "Document access is turned off, so nothing was sent." };
      }
      message = {
        to: payload.to,
        subject: `Document shared from Child Assist: ${payload.documentName}`,
        body: `Shared document: ${payload.documentName}`,
        documentId: payload.documentId,
      };
      break;
  }

  const { delivered } = await communication.send(userId, message);
  return delivered
    ? { id, status: "SUCCEEDED", message: `Done! I sent it to ${payload.to}.` }
    : { id, status: "FAILED", message: `Sorry, I couldn't deliver it to ${payload.to}. Nothing was sent.` };
}

/** Test hook: forget every pending action. */
export function clearPendingActions(): void {
  store.clear();
}
