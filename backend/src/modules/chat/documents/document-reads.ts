import { ChatMessageRole, DocumentReadStatus, type DocumentReadRequest } from "../../../../generated/prisma/client";
import { HttpError } from "../../../lib/http-error";
import { prisma } from "../../../lib/prisma";
import { getChatModels } from "../ai/models";
import { guardReply } from "../guardrails/guardrails";
import { addMessage, type MessageRecord } from "../chat.service";
import type { ToolContext } from "../tools/types";
import { answerFromDocument } from "./document-answer";

// Reading one of the user's documents for the assistant. Documents never leave the phone except
// for this: the assistant opens a request (read_document), the phone finds the document in the
// signed-in user's own list, checks it is still there, extracts its text locally and posts the
// text of that ONE document here. The request belongs to the user from the JWT and that
// conversation, can be answered once, and expires after a few minutes.
//
//   PENDING ──answer──▶ COMPLETED | FAILED (no model could answer)
//   PENDING ──fail────▶ FAILED (not found, unavailable, unreadable) | CANCELLED
//   PENDING ──10 minutes──▶ EXPIRED
//
// The document text is used for the answer and then dropped: it is never stored or logged. Only
// the answer is kept, as the assistant's chat message, like any other reply.

export const DOCUMENT_READ_TTL_MS = 10 * 60 * 1000;

export type DocumentReadFailure =
  | "not_found"
  | "unavailable"
  | "unsupported"
  | "no_text"
  | "encrypted"
  | "unreadable"
  | "cancelled";

/** What the user is told, written here rather than by the model so it can never invent content. */
const FAILURE_MESSAGES: Record<DocumentReadFailure, string> = {
  not_found: "I couldn't find that document on your phone, so I couldn't read it.",
  unavailable: "This document is no longer available, so I couldn't read it.",
  unsupported: "I can't read the text of this type of document yet. You can still open it from Documents.",
  no_text:
    "I couldn't find any readable text in this document. It may be a scanned image, so I can't tell what it says. You can still open it from Documents.",
  encrypted: "This document is password-protected, so I couldn't read it. You can still open it from Documents.",
  unreadable: "I couldn't read this document. You can still open it from Documents.",
  cancelled: "Okay, I didn't read the document.",
};

export const ANSWER_FAILED_MESSAGE = "Sorry, I couldn't read the document right now. Please try again in a moment.";

export interface DocumentReadView {
  id: string;
  status: DocumentReadStatus;
  documentQuery: string | null;
  documentType: string | null;
  expiresAt: string;
}

function toView(r: DocumentReadRequest): DocumentReadView {
  return {
    id: r.id,
    status: r.status,
    documentQuery: r.documentQuery,
    documentType: r.documentType,
    expiresAt: r.expiresAt.toISOString(),
  };
}

export async function expireStaleDocumentReads(now = new Date()): Promise<void> {
  await prisma.documentReadRequest.updateMany({
    // completedAt marks a request whose answer is being written: never expire one mid-answer.
    where: { status: DocumentReadStatus.PENDING, expiresAt: { lte: now }, completedAt: null },
    data: { status: DocumentReadStatus.EXPIRED, question: null },
  });
}

/** Opens a request for the phone to read one document (chat turn). Reads nothing itself. */
export async function prepareDocumentRead(
  ctx: ToolContext,
  input: { documentQuery: string | null; documentType: string | null; question: string },
): Promise<DocumentReadView> {
  await expireStaleDocumentReads();
  const request = await prisma.documentReadRequest.create({
    data: {
      userId: ctx.userId,
      conversationId: ctx.conversationId,
      documentQuery: input.documentQuery,
      documentType: input.documentType,
      question: input.question,
      expiresAt: new Date(Date.now() + DOCUMENT_READ_TTL_MS),
    },
  });
  return toView(request);
}

export interface ReadScope {
  conversationId?: string;
}

/** The user's own request, or 404: someone else's looks exactly like a missing one. */
async function load(userId: string, id: string, scope: ReadScope): Promise<DocumentReadRequest> {
  const request = await prisma.documentReadRequest.findFirst({
    where: { id, userId, ...(scope.conversationId ? { conversationId: scope.conversationId } : {}) },
  });
  if (!request) throw new HttpError(404, "Request not found");
  return request;
}

/** Claims a PENDING request so it can be answered (or failed) exactly once. */
async function claim(userId: string, id: string, scope: ReadScope, documentId: string | null): Promise<DocumentReadRequest> {
  const request = await load(userId, id, scope);
  const { count } = await prisma.documentReadRequest.updateMany({
    where: { id, userId, status: DocumentReadStatus.PENDING, completedAt: null, expiresAt: { gt: new Date() } },
    data: { completedAt: new Date(), ...(documentId ? { documentId } : {}) },
  });
  if (count === 1) return request;
  if (request.status === DocumentReadStatus.EXPIRED || (request.status === DocumentReadStatus.PENDING && request.expiresAt <= new Date())) {
    await expireStaleDocumentReads();
    throw new HttpError(410, "This request has expired. Please ask Child Assist again.", "REQUEST_EXPIRED");
  }
  throw new HttpError(409, "This request has already been handled.", "REQUEST_ALREADY_HANDLED");
}

async function finish(userId: string, id: string, status: DocumentReadStatus): Promise<void> {
  await prisma.documentReadRequest.updateMany({
    where: { id, userId },
    data: { status, completedAt: new Date(), question: null },
  });
}

export interface DocumentAnswerInput {
  documentId: string;
  name: string;
  type: "PDF" | "DOC" | "DOCX" | "TXT";
  text: string;
  truncated: boolean;
}

/**
 * The phone sends the text of the one document it read for this request; the answer is written
 * from that text alone and saved as the assistant's reply. The text itself is not kept.
 */
export async function answerDocumentRead(
  userId: string,
  id: string,
  input: DocumentAnswerInput,
  scope: ReadScope = {},
): Promise<{ request: DocumentReadView; message: MessageRecord }> {
  const request = await claim(userId, id, scope, input.documentId);
  const models = getChatModels();
  const candidates = [models.chat, models.fallback].filter((m) => m !== undefined);

  let answer: string | null = null;
  if (candidates.length > 0) {
    try {
      answer = await answerFromDocument(candidates, {
        question: request.question ?? "Give a short overview of what this document contains.",
        name: input.name,
        type: input.type,
        text: input.text,
        truncated: input.truncated,
      });
    } catch {
      // Already logged by name only; the text never reaches the log.
      answer = null;
    }
  }

  if (!answer) {
    await finish(userId, id, DocumentReadStatus.FAILED);
    await note(userId, request.conversationId, ANSWER_FAILED_MESSAGE);
    throw new HttpError(503, ANSWER_FAILED_MESSAGE, "AI_UNAVAILABLE");
  }

  await finish(userId, id, DocumentReadStatus.COMPLETED);
  const message = await addMessage(userId, request.conversationId, {
    role: ChatMessageRole.CHAT_ASSISTANT,
    content: guardReply(answer, false),
  });
  return { request: toView(await load(userId, id, scope)), message };
}

/** The phone could not read a document for this request (or the user cancelled). */
export async function failDocumentRead(
  userId: string,
  id: string,
  reason: DocumentReadFailure,
  scope: ReadScope = {},
): Promise<{ request: DocumentReadView; message: MessageRecord | null }> {
  const request = await claim(userId, id, scope, null);
  await finish(userId, id, reason === "cancelled" ? DocumentReadStatus.CANCELLED : DocumentReadStatus.FAILED);
  const message = await note(userId, request.conversationId, FAILURE_MESSAGES[reason]);
  return { request: toView(await load(userId, id, scope)), message };
}

async function note(userId: string, conversationId: string, content: string): Promise<MessageRecord | null> {
  try {
    return await addMessage(userId, conversationId, { role: ChatMessageRole.CHAT_ASSISTANT, content });
  } catch {
    // The conversation may have been deleted meanwhile.
    return null;
  }
}
