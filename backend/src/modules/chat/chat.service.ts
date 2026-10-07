import { ChatMessageRole, Prisma } from "../../../generated/prisma/client";
import { prisma } from "../../lib/prisma";
import { HttpError } from "../../lib/http-error";

// Persistence for conversations with the Child Assist assistant (Phase 7).
// Every function takes the owner's userId, which callers must take from the verified JWT and
// never from the request body. A conversation owned by someone else gives the same 404 as a
// missing one, so IDs cannot be probed.

export { ChatMessageRole };

/** Upper bound on a single stored message, to keep one row from growing without limit. */
export const MAX_MESSAGE_LENGTH = 20_000;
export const MAX_TITLE_LENGTH = 255;

export const TOOL_CALL_STATUSES = [
  "PENDING",
  "AWAITING_CONFIRMATION",
  "SUCCEEDED",
  "FAILED",
  "CANCELLED",
  // Refused before running, e.g. a missing device permission.
  "BLOCKED",
] as const;
export type ToolCallStatus = (typeof TOOL_CALL_STATUSES)[number];

// Tool names are identifiers like "location.get_current", never free text that could carry data.
const TOOL_NAME_PATTERN = /^[a-z][a-z0-9_.-]{0,99}$/i;

const conversationSelect = { id: true, title: true, createdAt: true, updatedAt: true } as const;
const messageSelect = { id: true, role: true, content: true, createdAt: true } as const;
const toolCallSelect = {
  id: true,
  toolName: true,
  status: true,
  confirmationRequired: true,
  confirmed: true,
  createdAt: true,
} as const;

export type ConversationRecord = Prisma.ChatConversationGetPayload<{ select: typeof conversationSelect }>;
export type MessageRecord = Prisma.ChatMessageGetPayload<{ select: typeof messageSelect }>;
export type ToolCallRecord = Prisma.ChatToolCallGetPayload<{ select: typeof toolCallSelect }>;

export interface AddMessageInput {
  role: ChatMessageRole;
  content: string;
}

export interface ToolCallInput {
  toolName: string;
  status: ToolCallStatus;
  confirmationRequired?: boolean;
  confirmed?: boolean;
}

function notFound(): HttpError {
  return new HttpError(404, "Conversation not found");
}

function normalizeTitle(title: string | null | undefined): string | null {
  const trimmed = title?.trim();
  if (!trimmed) return null;
  if (trimmed.length > MAX_TITLE_LENGTH) {
    throw new HttpError(400, `Title must be at most ${MAX_TITLE_LENGTH} characters`);
  }
  return trimmed;
}

// Foreign key violation on a user reference: the token is valid but the account no longer exists.
function rethrowMissingUser(err: unknown): never {
  if (err instanceof Prisma.PrismaClientKnownRequestError && err.code === "P2003") {
    throw new HttpError(401, "Invalid or expired token");
  }
  throw err;
}

export async function createConversation(
  userId: string,
  input: { title?: string | null } = {},
): Promise<ConversationRecord> {
  const title = normalizeTitle(input.title);
  try {
    return await prisma.chatConversation.create({ data: { userId, title }, select: conversationSelect });
  } catch (err) {
    rethrowMissingUser(err);
  }
}

/** The user's own conversations, most recently active first. */
export async function listConversations(
  userId: string,
  options: { limit?: number } = {},
): Promise<ConversationRecord[]> {
  return prisma.chatConversation.findMany({
    where: { userId },
    orderBy: [{ updatedAt: "desc" }, { id: "desc" }],
    take: options.limit ?? 50,
    select: conversationSelect,
  });
}

export async function getConversation(userId: string, id: string): Promise<ConversationRecord> {
  const row = await prisma.chatConversation.findFirst({ where: { id, userId }, select: conversationSelect });
  if (!row) throw notFound();
  return row;
}

export async function renameConversation(
  userId: string,
  id: string,
  title: string | null,
): Promise<ConversationRecord> {
  const { count } = await prisma.chatConversation.updateMany({
    where: { id, userId },
    data: { title: normalizeTitle(title) },
  });
  if (count === 0) throw notFound();
  return getConversation(userId, id);
}

/** Deletes the conversation; its messages and tool-call records go with it (ON DELETE CASCADE). */
export async function deleteConversation(userId: string, id: string): Promise<void> {
  const { count } = await prisma.chatConversation.deleteMany({ where: { id, userId } });
  if (count === 0) throw notFound();
}

/** Appends a message and marks the conversation as recently active. */
export async function addMessage(
  userId: string,
  conversationId: string,
  input: AddMessageInput,
): Promise<MessageRecord> {
  if (!Object.values(ChatMessageRole).includes(input.role)) {
    throw new HttpError(400, "Invalid message role");
  }
  if (typeof input.content !== "string" || input.content.length === 0) {
    throw new HttpError(400, "Message content is required");
  }
  if (input.content.length > MAX_MESSAGE_LENGTH) {
    throw new HttpError(400, `Message must be at most ${MAX_MESSAGE_LENGTH} characters`);
  }

  return prisma.$transaction(async (tx) => {
    // The ownership check and the activity bump are one statement, so a message can never be
    // attached to a conversation the user does not own.
    const { count } = await tx.chatConversation.updateMany({
      where: { id: conversationId, userId },
      data: { updatedAt: new Date() },
    });
    if (count === 0) throw notFound();
    return tx.chatMessage.create({
      data: { conversationId, role: input.role, content: input.content },
      select: messageSelect,
    });
  });
}

/** Messages in a conversation, oldest first by default. */
export async function listMessages(
  userId: string,
  conversationId: string,
  options: { order?: "asc" | "desc"; limit?: number } = {},
): Promise<MessageRecord[]> {
  await getConversation(userId, conversationId);
  const order = options.order ?? "asc";
  return prisma.chatMessage.findMany({
    where: { conversationId },
    orderBy: [{ createdAt: order }, { id: order }],
    take: options.limit,
    select: messageSelect,
  });
}

export interface ConversationMemory {
  summary: string | null;
  /** createdAt of the last message the summary covers; later messages are not in it. */
  summarizedUntil: Date | null;
}

/** The server-only summary of the user's conversation, or 404. Never sent to the app. */
export async function getConversationMemory(userId: string, id: string): Promise<ConversationMemory> {
  const row = await prisma.chatConversation.findFirst({
    where: { id, userId },
    select: { summary: true, summarizedUntil: true },
  });
  if (!row) throw notFound();
  return row;
}

/** The user's own user and assistant messages after [after] (all when null), oldest first, at most [limit] of the newest. */
export async function listDialogueSince(
  userId: string,
  conversationId: string,
  after: Date | null,
  limit: number,
): Promise<MessageRecord[]> {
  const rows = await prisma.chatMessage.findMany({
    where: {
      conversationId,
      conversation: { userId },
      role: { in: [ChatMessageRole.CHAT_USER, ChatMessageRole.CHAT_ASSISTANT] },
      ...(after ? { createdAt: { gt: after } } : {}),
    },
    orderBy: [{ createdAt: "desc" }, { id: "desc" }],
    take: limit,
    select: messageSelect,
  });
  return rows.reverse();
}

/** Stores a new summary for the user's conversation. A conversation deleted meanwhile is ignored. */
export async function saveConversationSummary(
  userId: string,
  id: string,
  summary: string,
  summarizedUntil: Date,
): Promise<void> {
  await prisma.chatConversation.updateMany({ where: { id, userId }, data: { summary, summarizedUntil } });
}

/**
 * Records that a tool was invoked. Only the fields below are stored: tool arguments and results
 * (locations, contacts, photos, documents, credentials) are never written to this table.
 */
export async function recordToolCall(
  userId: string,
  conversationId: string,
  input: ToolCallInput,
): Promise<ToolCallRecord> {
  if (!TOOL_NAME_PATTERN.test(input.toolName)) {
    throw new HttpError(400, "Invalid tool name");
  }
  if (!TOOL_CALL_STATUSES.includes(input.status)) {
    throw new HttpError(400, "Invalid tool call status");
  }

  await getConversation(userId, conversationId);
  try {
    return await prisma.chatToolCall.create({
      data: {
        conversationId,
        userId,
        toolName: input.toolName,
        status: input.status,
        confirmationRequired: input.confirmationRequired === true,
        confirmed: input.confirmed === true,
      },
      select: toolCallSelect,
    });
  } catch (err) {
    // The conversation was deleted between the check and the insert.
    if (err instanceof Prisma.PrismaClientKnownRequestError && err.code === "P2003") throw notFound();
    throw err;
  }
}

export async function listToolCalls(userId: string, conversationId: string): Promise<ToolCallRecord[]> {
  await getConversation(userId, conversationId);
  return prisma.chatToolCall.findMany({
    where: { conversationId, userId },
    orderBy: [{ createdAt: "asc" }, { id: "asc" }],
    select: toolCallSelect,
  });
}

/**
 * Removes one message from the user's conversation. Used to roll back a user message when the
 * assistant could not answer, so a retry does not leave a duplicate behind.
 */
export async function deleteMessage(userId: string, messageId: string): Promise<void> {
  await prisma.chatMessage.deleteMany({ where: { id: messageId, conversation: { userId } } });
}

/** The user's own tool call, or 404. */
export async function getToolCall(
  userId: string,
  id: string,
): Promise<ToolCallRecord & { conversationId: string }> {
  const row = await prisma.chatToolCall.findFirst({
    where: { id, userId },
    select: { ...toolCallSelect, conversationId: true },
  });
  if (!row) throw new HttpError(404, "Action not found");
  return row;
}

/**
 * Moves the user's tool call from one status to another in a single statement, and reports
 * whether it did. Two concurrent confirmations cannot both win, so an action runs at most once.
 */
export async function transitionToolCall(
  userId: string,
  id: string,
  from: ToolCallStatus,
  to: ToolCallStatus,
  data: { confirmed?: boolean } = {},
): Promise<boolean> {
  const { count } = await prisma.chatToolCall.updateMany({
    where: { id, userId, status: from },
    data: { status: to, ...data },
  });
  return count === 1;
}
