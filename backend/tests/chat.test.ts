// Integration tests for the Phase 7 chat persistence layer.
// Runs against the configured PostgreSQL database (DATABASE_URL) and removes the users it
// creates afterwards. Run with: npm test
import "dotenv/config";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { after, before, describe, test } from "node:test";
import { prisma } from "../src/lib/prisma";
import { HttpError } from "../src/lib/http-error";
import {
  ChatMessageRole,
  addMessage,
  createConversation,
  deleteConversation,
  getConversation,
  listConversations,
  listMessages,
  listToolCalls,
  recordToolCall,
  renameConversation,
} from "../src/modules/chat/chat.service";

const createdUserIds: string[] = [];
let userA: string;
let userB: string;

async function createUser(name: string): Promise<string> {
  const user = await prisma.user.create({
    data: { name, email: `phase7-${randomUUID()}@test.local` },
    select: { id: true },
  });
  createdUserIds.push(user.id);
  return user.id;
}

async function assertNotFound(promise: Promise<unknown>): Promise<void> {
  await assert.rejects(promise, (err: unknown) => {
    assert.ok(err instanceof HttpError);
    assert.equal(err.status, 404);
    return true;
  });
}

before(async () => {
  userA = await createUser("Chat A");
  userB = await createUser("Chat B");
});

after(async () => {
  await prisma.user.deleteMany({ where: { id: { in: createdUserIds } } });
  await prisma.$disconnect();
});

describe("chat persistence", () => {
  let aConversationId: string;
  let bConversationId: string;

  test("1. User can create a conversation", async () => {
    const conversation = await createConversation(userA, { title: "  Hey Child Assist  " });
    assert.deepEqual(Object.keys(conversation).sort(), ["createdAt", "id", "title", "updatedAt"]);
    assert.equal(conversation.title, "Hey Child Assist");
    aConversationId = conversation.id;

    const untitled = await createConversation(userA);
    assert.equal(untitled.title, null);

    const row = await prisma.chatConversation.findUniqueOrThrow({ where: { id: aConversationId } });
    assert.equal(row.userId, userA);

    bConversationId = (await createConversation(userB, { title: "B's chat" })).id;
  });

  test("2. User lists only their own conversations", async () => {
    const aList = await listConversations(userA);
    assert.equal(aList.length, 2);
    assert.ok(!aList.some((c) => c.id === bConversationId));

    const bList = await listConversations(userB);
    assert.deepEqual(bList.map((c) => c.id), [bConversationId]);
  });

  test("3. User cannot access, modify, delete or post to another user's conversation", async () => {
    await assertNotFound(getConversation(userA, bConversationId));
    await assertNotFound(renameConversation(userA, bConversationId, "hijacked"));
    await assertNotFound(deleteConversation(userA, bConversationId));
    await assertNotFound(listMessages(userA, bConversationId));
    await assertNotFound(addMessage(userA, bConversationId, { role: ChatMessageRole.CHAT_USER, content: "hi" }));
    await assertNotFound(recordToolCall(userA, bConversationId, { toolName: "location.get", status: "PENDING" }));
    // Indistinguishable from an ID that does not exist at all.
    await assertNotFound(getConversation(userA, "does-not-exist"));

    const b = await prisma.chatConversation.findUniqueOrThrow({ where: { id: bConversationId } });
    assert.equal(b.title, "B's chat");
    assert.equal(await prisma.chatMessage.count({ where: { conversationId: bConversationId } }), 0);
    assert.equal(await prisma.chatToolCall.count({ where: { conversationId: bConversationId } }), 0);
  });

  test("4. User can add messages to their conversation", async () => {
    const before = await getConversation(userA, aConversationId);
    const message = await addMessage(userA, aConversationId, {
      role: ChatMessageRole.CHAT_USER,
      content: "Hey Child Assist, what can you do?",
    });
    assert.deepEqual(Object.keys(message).sort(), ["content", "createdAt", "id", "role"]);
    assert.equal(message.role, ChatMessageRole.CHAT_USER);

    // Adding a message bumps the conversation to the top of the list.
    const afterAdd = await getConversation(userA, aConversationId);
    assert.ok(afterAdd.updatedAt >= before.updatedAt);
    assert.equal((await listConversations(userA))[0].id, aConversationId);

    await assert.rejects(addMessage(userA, aConversationId, { role: ChatMessageRole.CHAT_USER, content: "" }), HttpError);
    await assert.rejects(
      addMessage(userA, aConversationId, { role: "ADMIN" as ChatMessageRole, content: "x" }),
      HttpError,
    );
  });

  test("5. Messages are returned oldest to newest", async () => {
    await addMessage(userA, aConversationId, { role: ChatMessageRole.CHAT_ASSISTANT, content: "I'm Child Assist!" });
    await addMessage(userA, aConversationId, { role: ChatMessageRole.CHAT_USER, content: "Thanks buddy" });

    const messages = await listMessages(userA, aConversationId);
    assert.deepEqual(
      messages.map((m) => m.content),
      ["Hey Child Assist, what can you do?", "I'm Child Assist!", "Thanks buddy"],
    );
    for (let i = 1; i < messages.length; i++) {
      assert.ok(messages[i].createdAt >= messages[i - 1].createdAt);
    }

    const newestFirst = await listMessages(userA, aConversationId, { order: "desc" });
    assert.deepEqual(newestFirst.map((m) => m.id), messages.map((m) => m.id).reverse());
  });

  test("9. Tool call audit can be created", async () => {
    const call = await recordToolCall(userA, aConversationId, {
      toolName: "location.get_current",
      status: "AWAITING_CONFIRMATION",
      confirmationRequired: true,
    });
    assert.equal(call.toolName, "location.get_current");
    assert.equal(call.status, "AWAITING_CONFIRMATION");
    assert.equal(call.confirmationRequired, true);
    assert.equal(call.confirmed, false);

    const row = await prisma.chatToolCall.findUniqueOrThrow({ where: { id: call.id } });
    assert.equal(row.userId, userA);
    assert.equal(row.conversationId, aConversationId);
    assert.equal((await listToolCalls(userA, aConversationId)).length, 1);

    await assert.rejects(recordToolCall(userA, aConversationId, { toolName: "bad name; drop", status: "PENDING" }), HttpError);
    await assert.rejects(
      recordToolCall(userA, aConversationId, { toolName: "x", status: "DONE" as "PENDING" }),
      HttpError,
    );
  });

  test("10. Tool calls do not contain secrets or payloads", async () => {
    const secrets = { password: "hunter2-secret", token: "eyJhbGciOiJIUzI1NiJ9.secret", latitude: 20.2961 };
    // Extra fields a careless caller might pass must not be persisted.
    const call = await recordToolCall(userA, aConversationId, {
      toolName: "contacts.search",
      status: "SUCCEEDED",
      ...secrets,
    } as Parameters<typeof recordToolCall>[2]);

    const row = await prisma.chatToolCall.findUniqueOrThrow({ where: { id: call.id } });
    // The table has no column that could hold arguments, results or credentials.
    assert.deepEqual(Object.keys(row).sort(), [
      "confirmationRequired", "confirmed", "conversationId", "createdAt", "id", "status", "toolName", "userId",
    ]);
    const serialized = JSON.stringify(row);
    for (const value of Object.values(secrets)) {
      assert.ok(!serialized.includes(String(value)), `tool call row must not contain ${value}`);
    }
  });

  test("6 & 7. Deleting a conversation removes it with its messages and tool calls", async () => {
    assert.ok((await prisma.chatMessage.count({ where: { conversationId: aConversationId } })) > 0);

    await deleteConversation(userA, aConversationId);

    await assertNotFound(getConversation(userA, aConversationId));
    assert.equal(await prisma.chatMessage.count({ where: { conversationId: aConversationId } }), 0);
    assert.equal(await prisma.chatToolCall.count({ where: { conversationId: aConversationId } }), 0);
    await assertNotFound(deleteConversation(userA, aConversationId));
    // B's data is untouched.
    assert.equal((await getConversation(userB, bConversationId)).id, bConversationId);
  });

  test("8. Deleting a user cascades to their conversations, messages and tool calls", async () => {
    const userC = await createUser("Chat C");
    const conversation = await createConversation(userC);
    await addMessage(userC, conversation.id, { role: ChatMessageRole.CHAT_USER, content: "Hi Child Assist" });
    await recordToolCall(userC, conversation.id, { toolName: "photos.list", status: "SUCCEEDED" });

    await prisma.user.delete({ where: { id: userC } });

    assert.equal(await prisma.chatConversation.count({ where: { userId: userC } }), 0);
    assert.equal(await prisma.chatMessage.count({ where: { conversationId: conversation.id } }), 0);
    assert.equal(await prisma.chatToolCall.count({ where: { userId: userC } }), 0);
    // A still-valid token for a deleted account cannot create orphaned rows.
    await assert.rejects(createConversation(userC), (err: unknown) => err instanceof HttpError && err.status === 401);
  });
});
