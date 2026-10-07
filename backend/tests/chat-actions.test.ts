// Integration tests for phone-contact lookup, email and WhatsApp actions in chat.
// Runs the real app against the configured PostgreSQL database with mock Gemini models. Outgoing
// email is captured by tests/support/auth.ts, so nothing is ever delivered.
// Run with: npm test
import "dotenv/config";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, afterEach, before, beforeEach, describe, test } from "node:test";
import type { LanguageModelV4CallOptions, LanguageModelV4GenerateResult } from "@ai-sdk/provider";
import { MockLanguageModelV4 } from "ai/test";
import { PermissionStatus, PermissionType } from "../generated/prisma/client";
import { createApp } from "../src/app";
import { HttpError } from "../src/lib/http-error";
import { setEmailSender } from "../src/lib/email";
import { prisma } from "../src/lib/prisma";
import { executeEmailAction, normalizePhone } from "../src/modules/chat/actions/pending-actions";
import { isValidEmail } from "../src/modules/chat/actions/email.service";
import { setChatModels } from "../src/modules/chat/ai/models";
import { guardReply } from "../src/modules/chat/guardrails/guardrails";
import { registerVerifiedUser, sentEmails } from "./support/auth";

let server: Server;
let baseUrl: string;

interface TestUser {
  id: string;
  token: string;
  email: string;
}

let userA: TestUser;
let userB: TestUser;
const createdUserIds: string[] = [];

async function call(
  method: string,
  path: string,
  { token, body }: { token?: string; body?: unknown } = {},
): Promise<{ status: number; json: any; raw: string }> {
  const res = await fetch(`${baseUrl}${path}`, {
    method,
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const raw = await res.text();
  return { status: res.status, json: raw ? JSON.parse(raw) : null, raw };
}

async function registerUser(name: string): Promise<TestUser> {
  const email = `actions-${randomUUID()}@test.local`;
  const user = await registerVerifiedUser(call, name, email);
  createdUserIds.push(user.id);
  return { id: user.id, token: user.token, email };
}

async function setPermission(user: TestUser, permission: PermissionType, status: PermissionStatus) {
  await prisma.userPermission.upsert({
    where: { userId_permission: { userId: user.id, permission } },
    create: { userId: user.id, permission, status },
    update: { status },
  });
}

function chat(user: TestUser, body: Record<string, unknown>) {
  return call("POST", "/api/chat", { token: user.token, body });
}

const action = (user: TestUser, id: string, verb: string, body?: unknown) =>
  call("POST", `/api/chat/actions/${id}/${verb}`, { token: user.token, body });

// ---------------------------------------------------------------------------------------------
// Mock Gemini (same shapes as chat-api.test.ts)

const usage = {
  inputTokens: { total: 10, noCache: 10, cacheRead: undefined, cacheWrite: undefined },
  outputTokens: { total: 5, text: 5, reasoning: undefined },
};

function text(value: string): LanguageModelV4GenerateResult {
  return { content: [{ type: "text", text: value }], finishReason: { unified: "stop", raw: undefined }, usage, warnings: [] };
}

let callCounter = 0;
function toolCall(toolName: string, input: unknown): LanguageModelV4GenerateResult {
  return {
    content: [{ type: "tool-call", toolCallId: `call-${++callCounter}`, toolName, input: JSON.stringify(input) }],
    finishReason: { unified: "tool-calls", raw: undefined },
    usage,
    warnings: [],
  };
}

function lastToolResult(options: LanguageModelV4CallOptions): unknown {
  const last = options.prompt[options.prompt.length - 1];
  if (last?.role !== "tool") return undefined;
  const part = last.content.find((p) => p.type === "tool-result");
  if (!part || part.type !== "tool-result") return undefined;
  return part.output.type === "json" ? part.output.value : part.output;
}

/** Calls one tool, then answers with [reply] (default: the tool's raw result, for inspection). */
function toolThen(toolName: string, input: unknown, reply?: string) {
  const seen: unknown[] = [];
  const m = new MockLanguageModelV4({
    doGenerate: async (options) => {
      const system = options.prompt.filter((p) => p.role === "system").map((p) => p.content).join("");
      if (system.includes("word title")) return text("Contacts");
      const result = lastToolResult(options);
      if (result === undefined) return toolCall(toolName, input);
      seen.push(result);
      return text(reply ?? `RESULT ${JSON.stringify(result)}`);
    },
  });
  return Object.assign(m, { seen });
}

async function saveLocation(user: TestUser, placeName: string, capturedAt = new Date()) {
  const res = await call("POST", "/api/location", {
    token: user.token,
    body: { latitude: 20.2961, longitude: 85.8245, capturedAt: capturedAt.toISOString(), placeName, city: "Bhubaneswar" },
  });
  assert.equal(res.status, 201, res.raw);
}

/** Prepares an email to the contact "Mansi" and returns the pending action from the reply. */
async function prepareEmail(user: TestUser, input: Record<string, unknown> = {}) {
  setChatModels({
    chat: toolThen("prepare_email", { recipientName: "Mansi", subject: "Homework", message: "Maths homework is page 42.", ...input }, "Please check and confirm."),
  });
  const res = await chat(user, { message: "Mansi ko ye details email kar do" });
  assert.equal(res.status, 200, res.raw);
  assert.equal(res.json.pendingActions.length, 1, res.raw);
  return { res, pending: res.json.pendingActions[0], conversationId: res.json.conversationId as string };
}

async function prepareWhatsApp(user: TestUser, input: Record<string, unknown> = {}) {
  setChatModels({
    chat: toolThen("prepare_whatsapp", { recipientName: "Rahul", message: "I will be late today.", ...input }, "Ready to check."),
  });
  const res = await chat(user, { message: "Rahul ko WhatsApp karo ki main late aaunga" });
  assert.equal(res.status, 200, res.raw);
  assert.equal(res.json.pendingActions.length, 1, res.raw);
  return { res, pending: res.json.pendingActions[0], conversationId: res.json.conversationId as string };
}

// ---------------------------------------------------------------------------------------------

before(async () => {
  server = createApp().listen(0);
  await new Promise<void>((resolve) => server.once("listening", resolve));
  baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  userA = await registerUser("Asha");
  userB = await registerUser("Bilal");
});

beforeEach(async () => {
  for (const user of [userA, userB]) {
    await setPermission(user, PermissionType.CONTACTS, PermissionStatus.GRANTED);
    await setPermission(user, PermissionType.LOCATION, PermissionStatus.GRANTED);
  }
  sentEmails.length = 0;
});

afterEach(() => {
  setChatModels(null);
  // Back to the capturing sender from support/auth.ts if a test replaced it.
  setEmailSender(async (message) => {
    sentEmails.push(message);
  });
});

after(async () => {
  await prisma.user.deleteMany({ where: { id: { in: createdUserIds } } });
  await prisma.$disconnect();
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

// ---------------------------------------------------------------------------------------------

describe("contacts: find_contact", () => {
  test("without Contacts permission nothing is looked up", async () => {
    await setPermission(userA, PermissionType.CONTACTS, PermissionStatus.DENIED);
    const model = toolThen("find_contact", { query: "Mansi", field: "phone" });
    setChatModels({ chat: model });

    const res = await chat(userA, { message: "Mansi ka number do" });
    assert.equal(res.status, 200, res.raw);
    assert.deepEqual(res.json.toolEvents, [{ kind: "contacts", status: "permission_required", permission: "CONTACTS" }]);
    assert.match(JSON.stringify(model.seen), /PERMISSION_REQUIRED/);
    assert.doesNotMatch(JSON.stringify(model.seen), /handledOnDevice/);
  });

  test("a status never reported by the phone counts as not granted", async () => {
    await prisma.userPermission.deleteMany({ where: { userId: userA.id, permission: PermissionType.CONTACTS } });
    setChatModels({ chat: toolThen("find_contact", { query: "Mansi" }) });
    const res = await chat(userA, { message: "Mansi ka number do" });
    assert.equal(res.json.toolEvents[0].status, "permission_required");
  });

  test("with permission the lookup is handed to the phone, for any name", async () => {
    // Nothing is hard-coded: ordinary names, relations, unicode and made-up names all pass through.
    for (const [name, field] of [
      ["Mansi", "phone"],
      ["Papa", "phone"],
      ["Rahul", "email"],
      ["प्रिया", "any"],
      ["Zyx Qwertyson", "phone"],
    ] as const) {
      const model = toolThen("find_contact", { query: name, field });
      setChatModels({ chat: model });
      const res = await chat(userA, { message: `${name} ka number do` });
      assert.equal(res.status, 200, res.raw);
      assert.deepEqual(res.json.toolEvents, [
        { kind: "contacts", status: "device_lookup", data: { query: { name, field } } },
      ]);
      // The model is told it cannot see the result and must not invent one.
      const seen = JSON.stringify(model.seen);
      assert.match(seen, /handledOnDevice/);
      assert.match(seen, /never state, guess or invent/);
    }
  });

  test("the backend never returns or stores contact details", async () => {
    const model = toolThen("find_contact", { query: "Mansi", field: "phone" });
    setChatModels({ chat: model });
    const res = await chat(userA, { message: "Mansi ka number do" });
    assert.doesNotMatch(JSON.stringify(model.seen), /phones|emails|\d{10}/);
    assert.equal(await prisma.chatAction.count({ where: { conversationId: res.json.conversationId } }), 0);
    const audit = await prisma.chatToolCall.findFirstOrThrow({ where: { conversationId: res.json.conversationId } });
    assert.equal(audit.toolName, "find_contact");
    assert.doesNotMatch(JSON.stringify(audit), /Mansi/);
  });

  test("an address book cannot be uploaded with a chat message", async () => {
    const res = await chat(userA, {
      message: "Mansi ka number do",
      contacts: [{ name: "Mansi", phone: "9876543210" }],
    });
    assert.equal(res.status, 400, res.raw);
  });
});

describe("email: prepare and validate", () => {
  test("prepares a pending email for a contact without sending anything", async () => {
    // The model even claims it already sent it; that claim must not reach the user.
    setChatModels({
      chat: toolThen("prepare_email", { recipientName: "Mansi", subject: "Homework", message: "Page 42" }, "I've sent the email to Mansi!"),
    });
    const res = await chat(userA, { message: "Mansi ko ye details email kar do" });
    assert.equal(res.status, 200, res.raw);
    assert.equal(sentEmails.length, 0, "nothing is sent during the chat turn");
    assert.doesNotMatch(res.json.response, /I've sent/);
    assert.match(res.json.response, /nothing has been sent/i);

    const pending = res.json.pendingActions[0];
    assert.deepEqual(
      {
        type: pending.type,
        channel: pending.channel,
        status: pending.status,
        contactQuery: pending.contactQuery,
        recipientField: pending.recipientField,
        recipientAddress: pending.recipientAddress,
        subject: pending.subject,
        message: pending.message,
        summary: pending.summary,
      },
      {
        type: "SEND_EMAIL",
        channel: "EMAIL",
        status: "PENDING",
        contactQuery: "Mansi",
        recipientField: "email",
        recipientAddress: null,
        subject: "Homework",
        message: "Page 42",
        summary: 'Send an email to Mansi with the subject "Homework"?',
      },
    );
    assert.deepEqual(res.json.toolEvents, [{ kind: "send_action", status: "confirmation_required" }]);

    const row = await prisma.chatAction.findUniqueOrThrow({ where: { id: pending.id } });
    assert.equal(row.status, "PENDING");
    assert.equal(row.userId, userA.id);
    assert.ok(row.expiresAt.getTime() - Date.now() <= 10 * 60 * 1000 + 1000, "expires within 10 minutes");
    const audit = await prisma.chatToolCall.findUniqueOrThrow({ where: { id: pending.id } });
    assert.equal(audit.status, "AWAITING_CONFIRMATION");
    assert.equal(audit.confirmationRequired, true);
  });

  test("a contact name needs Contacts permission; nothing is prepared without it", async () => {
    await setPermission(userA, PermissionType.CONTACTS, PermissionStatus.DENIED);
    setChatModels({ chat: toolThen("prepare_email", { recipientName: "Mansi", message: "Hi" }) });
    const res = await chat(userA, { message: "Mansi ko email karo" });
    assert.deepEqual(res.json.pendingActions, []);
    assert.deepEqual(res.json.toolEvents, [{ kind: "send_action", status: "permission_required", permission: "CONTACTS" }]);
    assert.equal(await prisma.chatAction.count({ where: { userId: userA.id, conversationId: res.json.conversationId } }), 0);
  });

  test("an address the user typed is kept exactly and needs no contacts", async () => {
    await setPermission(userA, PermissionType.CONTACTS, PermissionStatus.DENIED);
    const { pending } = await prepareEmail(userA, { recipientName: undefined, recipientEmail: "Teacher.Name+class@School.test" });
    assert.equal(pending.recipientAddress, "Teacher.Name+class@School.test");
    assert.equal(pending.contactQuery, null);
    assert.equal(pending.summary, 'Send an email to Teacher.Name+class@School.test with the subject "Homework"?');
  });

  test("a malformed address is rejected, never fixed up", async () => {
    for (const bad of ["mansi@@example.com", "mansi example.com", "mansi@", "mansi@example"]) {
      const model = toolThen("prepare_email", { recipientEmail: bad, message: "Hi" });
      setChatModels({ chat: model });
      const res = await chat(userA, { message: `email ${bad}` });
      assert.deepEqual(res.json.pendingActions, [], bad);
      assert.match(JSON.stringify(model.seen), /INVALID_RECIPIENT/, bad);
    }
    assert.equal(isValidEmail("mansi@example.com"), true);
  });

  test("sharing today's location builds the exact data the user will see", async () => {
    await saveLocation(userA, "Asha's School");
    const { pending } = await prepareEmail(userA, { subject: undefined, message: undefined, share: "location", period: "today" });
    assert.equal(pending.type, "SHARE_LOCATION");
    assert.equal(pending.subject, "Child Assist - Today's Location");
    assert.match(pending.dataSummary, /^Today's location \(\d+ saved locations?\)$/);
    assert.match(pending.message, /Asha's School/);
    assert.match(pending.message, /maps\.google\.com\/\?q=20\.29610,85\.82450/);
    assert.equal(pending.summary, "Share your location with Mansi by email?");
    assert.doesNotMatch(pending.message, /Bilal/);
  });

  test("travel history needs Location permission and real saved places", async () => {
    await setPermission(userB, PermissionType.LOCATION, PermissionStatus.DENIED);
    setChatModels({ chat: toolThen("prepare_email", { recipientName: "Mansi", share: "travel_history" }) });
    let res = await chat(userB, { message: "Mansi ko meri travel history mail kar do" });
    assert.deepEqual(res.json.pendingActions, []);
    assert.equal(res.json.toolEvents[0].permission, "LOCATION");

    // Bilal has no saved locations: nothing to share, nothing prepared, nothing invented.
    await setPermission(userB, PermissionType.LOCATION, PermissionStatus.GRANTED);
    const model = toolThen("prepare_email", { recipientName: "Mansi", share: "travel_history", period: "yesterday" });
    setChatModels({ chat: model });
    res = await chat(userB, { message: "Mansi ko meri kal ki travel history mail kar do" });
    assert.deepEqual(res.json.pendingActions, []);
    assert.match(JSON.stringify(model.seen), /NOTHING_TO_SHARE/);
  });

  test("documents cannot be attached to email", async () => {
    const model = toolThen("prepare_email", { recipientName: "Mansi", documentName: "notes" });
    setChatModels({ chat: model });
    const res = await chat(userA, { message: "Mansi ko notes email karo" });
    assert.deepEqual(res.json.pendingActions, []);
    assert.match(JSON.stringify(model.seen), /NOT_SUPPORTED/);
  });
});

describe("email: confirmation is enforced by the server", () => {
  test("cannot be confirmed before the recipient is chosen", async () => {
    const { pending } = await prepareEmail(userA);
    const res = await action(userA, pending.id, "confirm");
    assert.equal(res.status, 409, res.raw);
    assert.equal(res.json.code, "RECIPIENT_REQUIRED");
    assert.equal(sentEmails.length, 0);
  });

  test("the recipient must be a valid address and can be chosen only once", async () => {
    const { pending, conversationId } = await prepareEmail(userA);
    const bad = await action(userA, pending.id, "recipient", { address: "not-an-email", name: "Mansi Patro" });
    assert.equal(bad.status, 400, bad.raw);

    const ok = await action(userA, pending.id, "recipient", { conversationId, address: "mansi@example.com", name: "Mansi Patro" });
    assert.equal(ok.status, 200, ok.raw);
    assert.equal(ok.json.action.recipientAddress, "mansi@example.com");
    assert.equal(ok.json.action.recipientName, "Mansi Patro");
    assert.equal(ok.json.action.summary, 'Send an email to Mansi Patro <mansi@example.com> with the subject "Homework"?');

    const again = await action(userA, pending.id, "recipient", { address: "attacker@example.com" });
    assert.equal(again.status, 409, again.raw);
    const row = await prisma.chatAction.findUniqueOrThrow({ where: { id: pending.id } });
    assert.equal(row.recipientAddress, "mansi@example.com");
  });

  test("send_email refuses an action the user has not confirmed", async () => {
    const { pending } = await prepareEmail(userA);
    await action(userA, pending.id, "recipient", { address: "mansi@example.com" });
    await assert.rejects(executeEmailAction(userA.id, pending.id), (err: unknown) => {
      return err instanceof HttpError && err.status === 409 && err.code === "CONFIRMATION_REQUIRED";
    });
    assert.equal(sentEmails.length, 0);
    assert.equal((await prisma.chatAction.findUniqueOrThrow({ where: { id: pending.id } })).status, "PENDING");
  });

  test("confirm sends exactly once, then the content is cleared", async () => {
    const { pending, conversationId } = await prepareEmail(userA);
    await action(userA, pending.id, "recipient", { address: "mansi@example.com", name: "Mansi" });

    const [first, second] = await Promise.all([
      action(userA, pending.id, "confirm", { conversationId }),
      action(userA, pending.id, "confirm", { conversationId }),
    ]);
    const statuses = [first.status, second.status].sort();
    assert.deepEqual(statuses, [200, 409], `${first.raw} ${second.raw}`);
    const confirmed = first.status === 200 ? first : second;
    assert.equal(confirmed.json.action.status, "COMPLETED");
    assert.equal(confirmed.json.action.outcomeMessage, "Email sent to Mansi.");

    assert.equal(sentEmails.length, 1, "a double tap never sends twice");
    const email = sentEmails[0];
    assert.equal(email.to, '"Mansi" <mansi@example.com>');
    assert.equal(email.subject, "Homework");
    assert.match(email.text, /Maths homework is page 42\./);
    assert.match(email.text, /Sent by Asha using Child Assist\./);
    assert.equal(email.replyTo, userA.email);

    const row = await prisma.chatAction.findUniqueOrThrow({ where: { id: pending.id } });
    assert.equal(row.status, "COMPLETED");
    assert.ok(row.confirmedAt && row.completedAt);
    assert.equal(row.recipientAddress, null, "the address is not kept after sending");
    assert.equal(row.message, null);
    const audit = await prisma.chatToolCall.findUniqueOrThrow({ where: { id: pending.id } });
    assert.equal(audit.status, "SUCCEEDED");
    assert.equal(audit.confirmed, true);

    // The chat history records the outcome with safe metadata only.
    const messages = await prisma.chatMessage.findMany({ where: { conversationId }, orderBy: { createdAt: "asc" } });
    assert.equal(messages.at(-1)?.content, "Email sent to Mansi.");
    assert.doesNotMatch(JSON.stringify(messages), /mansi@example\.com/);

    const third = await action(userA, pending.id, "confirm");
    assert.equal(third.status, 409);
    assert.equal(sentEmails.length, 1);
  });

  test("a cancelled action can never run", async () => {
    const { pending } = await prepareEmail(userA);
    await action(userA, pending.id, "recipient", { address: "mansi@example.com" });
    const cancelled = await action(userA, pending.id, "cancel");
    assert.equal(cancelled.status, 200, cancelled.raw);
    assert.equal(cancelled.json.action.status, "CANCELLED");
    assert.equal(cancelled.json.action.outcomeMessage, "Okay, I didn't send anything.");

    assert.equal((await action(userA, pending.id, "confirm")).status, 409);
    assert.equal((await action(userA, pending.id, "cancel")).status, 409, "cancel works exactly once");
    assert.equal(sentEmails.length, 0);
    assert.equal((await prisma.chatAction.findUniqueOrThrow({ where: { id: pending.id } })).recipientAddress, null);
  });

  test("an expired action cannot be confirmed", async () => {
    const { pending } = await prepareEmail(userA);
    await action(userA, pending.id, "recipient", { address: "mansi@example.com" });
    await prisma.chatAction.update({ where: { id: pending.id }, data: { expiresAt: new Date(Date.now() - 1000) } });

    const res = await action(userA, pending.id, "confirm");
    assert.equal(res.status, 410, res.raw);
    assert.equal(res.json.code, "ACTION_EXPIRED");
    assert.equal(sentEmails.length, 0);
    const row = await prisma.chatAction.findUniqueOrThrow({ where: { id: pending.id } });
    assert.equal(row.status, "EXPIRED");
    assert.equal(row.recipientAddress, null);
  });

  test("an SMTP failure is reported honestly without details", async () => {
    setEmailSender(async () => {
      throw new Error("535 5.7.8 Username and Password not accepted smtp.gmail.com secret-detail");
    });
    const { pending } = await prepareEmail(userA);
    await action(userA, pending.id, "recipient", { address: "mansi@example.com", name: "Mansi" });
    const res = await action(userA, pending.id, "confirm");
    assert.equal(res.status, 200, res.raw);
    assert.equal(res.json.action.status, "FAILED");
    assert.match(res.json.action.outcomeMessage, /couldn't send the email to Mansi\. Nothing was delivered/);
    assert.doesNotMatch(res.raw, /535|secret-detail|smtp\.gmail|stack/);
    assert.equal((await prisma.chatToolCall.findUniqueOrThrow({ where: { id: pending.id } })).status, "FAILED");
  });
});

describe("whatsapp: prepare, confirm and hand off to the phone", () => {
  test("prepares a pending WhatsApp message for a contact", async () => {
    const { pending, res } = await prepareWhatsApp(userA);
    assert.equal(pending.type, "SEND_WHATSAPP");
    assert.equal(pending.channel, "WHATSAPP");
    assert.equal(pending.recipientField, "phone");
    assert.equal(pending.contactQuery, "Rahul");
    assert.equal(pending.recipientAddress, null);
    assert.equal(pending.message, "I will be late today.");
    assert.equal(pending.summary, "Send this WhatsApp message to Rahul?");
    assert.equal(sentEmails.length, 0);
    assert.doesNotMatch(res.json.response, /\bsent\b(?! yet)/i);
  });

  test("needs Contacts permission for a contact name", async () => {
    await setPermission(userA, PermissionType.CONTACTS, PermissionStatus.DENIED);
    setChatModels({ chat: toolThen("prepare_whatsapp", { recipientName: "Rahul", message: "Hi" }) });
    const res = await chat(userA, { message: "Rahul ko WhatsApp karo" });
    assert.deepEqual(res.json.pendingActions, []);
    assert.equal(res.json.toolEvents[0].permission, "CONTACTS");
  });

  test("phone numbers are validated and normalised, never invented", async () => {
    assert.equal(normalizePhone("+91 98765-43210"), "+919876543210");
    assert.equal(normalizePhone("(0674) 2345678"), "06742345678");
    for (const bad of ["abc", "12345", "+1 234 567 890 123 456", "98765x43210"]) assert.equal(normalizePhone(bad), null, bad);

    const { pending } = await prepareWhatsApp(userA);
    assert.equal((await action(userA, pending.id, "recipient", { address: "call me" })).status, 400);
    const ok = await action(userA, pending.id, "recipient", { address: "+91 98765 43210", name: "Rahul Sharma" });
    assert.equal(ok.status, 200, ok.raw);
    assert.equal(ok.json.action.recipientAddress, "+919876543210");
    assert.equal(ok.json.action.summary, "Send this WhatsApp message to Rahul Sharma (+919876543210)?");

    const model = toolThen("prepare_whatsapp", { recipientPhone: "12", message: "Hi" });
    setChatModels({ chat: model });
    const res = await chat(userA, { message: "WhatsApp 12 hi" });
    assert.deepEqual(res.json.pendingActions, []);
    assert.match(JSON.stringify(model.seen), /INVALID_RECIPIENT/);
  });

  test("confirm hands the exact number and text to the phone; it is never reported as sent", async () => {
    const { pending, conversationId } = await prepareWhatsApp(userA);
    assert.equal((await action(userA, pending.id, "handoff", { result: "whatsapp_opened" })).status, 409, "not before confirmation");
    await action(userA, pending.id, "recipient", { address: "9876543210", name: "Rahul Sharma" });

    const confirmed = await action(userA, pending.id, "confirm", { conversationId });
    assert.equal(confirmed.status, 200, confirmed.raw);
    assert.equal(confirmed.json.action.status, "CONFIRMED");
    assert.deepEqual(confirmed.json.action.handoff, { phone: "9876543210", message: "I will be late today.", documentQuery: null });
    assert.equal(sentEmails.length, 0, "WhatsApp is never sent by the backend");
    assert.equal((await action(userA, pending.id, "confirm")).status, 409, "confirm works exactly once");

    const opened = await action(userA, pending.id, "handoff", { conversationId, result: "whatsapp_opened" });
    assert.equal(opened.status, 200, opened.raw);
    assert.equal(opened.json.action.status, "COMPLETED");
    assert.equal(
      opened.json.action.outcomeMessage,
      "WhatsApp opened for Rahul Sharma with your message. Tap Send in WhatsApp to deliver it.",
    );
    assert.doesNotMatch(opened.json.action.outcomeMessage, /\bsent\b/i);
    assert.equal((await action(userA, pending.id, "handoff", { result: "whatsapp_opened" })).status, 409);

    const row = await prisma.chatAction.findUniqueOrThrow({ where: { id: pending.id } });
    assert.equal(row.recipientAddress, null);
    assert.equal(row.message, null);
  });

  test("WhatsApp unavailable keeps the action open for the share fallback", async () => {
    const { pending } = await prepareWhatsApp(userA);
    await action(userA, pending.id, "recipient", { address: "9876543210", name: "Rahul" });
    await action(userA, pending.id, "confirm");

    const unavailable = await action(userA, pending.id, "handoff", { result: "unavailable" });
    assert.equal(unavailable.status, 200, unavailable.raw);
    assert.equal(unavailable.json.action.status, "CONFIRMED");
    assert.equal(unavailable.json.action.outcomeMessage, "WhatsApp isn't available on this device.");

    const shared = await action(userA, pending.id, "handoff", { result: "share_opened" });
    assert.equal(shared.json.action.status, "COMPLETED");
    assert.match(shared.json.action.outcomeMessage, /Nothing is sent until you send it/);
  });

  test("location and documents are summarised before confirmation", async () => {
    await saveLocation(userA, "Patia Market");
    const { pending } = await prepareWhatsApp(userA, { message: undefined, share: "location" });
    assert.equal(pending.type, "SHARE_LOCATION");
    assert.equal(pending.summary, "Share your location with Rahul on WhatsApp?");
    assert.match(pending.dataSummary, /^Today's location/);
    assert.match(pending.message, /Patia Market/);

    const doc = await prepareWhatsApp(userA, { message: undefined, documentName: "math notes" });
    assert.equal(doc.pending.type, "SHARE_DOCUMENT");
    assert.equal(doc.pending.documentQuery, "math notes");
    assert.equal(doc.pending.summary, 'Share the document "math notes" with Rahul on WhatsApp?');
  });

  test("an email action cannot be handed off as WhatsApp", async () => {
    const { pending } = await prepareEmail(userA);
    assert.equal((await action(userA, pending.id, "handoff", { result: "whatsapp_opened" })).status, 404);
  });
});

describe("actions: security", () => {
  test("every action endpoint requires a valid JWT", async () => {
    const { pending } = await prepareEmail(userA);
    for (const verb of ["recipient", "confirm", "cancel", "handoff"]) {
      assert.equal((await call("POST", `/api/chat/actions/${pending.id}/${verb}`, { body: {} })).status, 401, verb);
      assert.equal(
        (await call("POST", `/api/chat/actions/${pending.id}/${verb}`, { token: "not-a-jwt", body: {} })).status,
        401,
        verb,
      );
    }
  });

  test("another user can never see, address, confirm or cancel the action", async () => {
    const { pending } = await prepareEmail(userA);
    assert.equal((await action(userB, pending.id, "recipient", { address: "bilal@example.com" })).status, 404);
    await action(userA, pending.id, "recipient", { address: "mansi@example.com" });
    for (const verb of ["confirm", "cancel"]) assert.equal((await action(userB, pending.id, verb)).status, 404, verb);
    assert.equal(sentEmails.length, 0);
    assert.equal((await prisma.chatAction.findUniqueOrThrow({ where: { id: pending.id } })).status, "PENDING");
  });

  test("the action must belong to the conversation the app names", async () => {
    const { pending } = await prepareEmail(userA);
    const other = await call("POST", "/api/chat/conversations", { token: userA.token, body: {} });
    await action(userA, pending.id, "recipient", { address: "mansi@example.com" });
    const res = await action(userA, pending.id, "confirm", { conversationId: other.json.conversation.id });
    assert.equal(res.status, 404, res.raw);
    assert.equal(sentEmails.length, 0);
  });

  test("a userId or other unknown field in the body is rejected", async () => {
    const { pending } = await prepareEmail(userA);
    assert.equal((await action(userA, pending.id, "recipient", { address: "mansi@example.com", userId: userB.id })).status, 400);
    assert.equal((await action(userA, pending.id, "confirm", { userId: userB.id })).status, 400);
    assert.equal((await action(userA, pending.id, "confirm", { confirmed: true })).status, 400);
  });

  test("responses never contain SMTP settings or secrets", async () => {
    const { pending } = await prepareEmail(userA);
    await action(userA, pending.id, "recipient", { address: "mansi@example.com" });
    const res = await action(userA, pending.id, "confirm");
    for (const secret of [process.env.SMTP_PASSWORD, process.env.SMTP_USER, process.env.JWT_SECRET]) {
      if (secret && secret.length >= 4) assert.ok(!res.raw.includes(secret));
    }
  });

  test("a turn that fails leaves nothing confirmable", async () => {
    let calls = 0;
    const m = new MockLanguageModelV4({
      doGenerate: async () => {
        calls += 1;
        if (calls === 1) return toolCall("prepare_email", { recipientEmail: "mansi@example.com", message: "Hi" });
        throw new Error("Vertex AI unavailable");
      },
    });
    setChatModels({ chat: m });
    const before = await prisma.chatAction.count({ where: { userId: userA.id, status: "PENDING" } });
    const res = await chat(userA, { message: "Email mansi@example.com hi" });
    assert.equal(res.status, 503, res.raw);
    assert.equal(await prisma.chatAction.count({ where: { userId: userA.id, status: "PENDING" } }), before);
  });

  test("false 'sent' claims are replaced in every language the app hears", () => {
    for (const claim of [
      "I've sent the email to Mansi.",
      "I have WhatsApped it to Rahul",
      "Your email has been sent.",
      "Mansi ko email bhej diya!",
      "Maine Papa ko location share kar di.",
    ]) {
      assert.match(guardReply(claim, true), /nothing has been sent yet/, claim);
    }
    assert.equal(guardReply("I've prepared the email. Please confirm.", true), "I've prepared the email. Please confirm.");
  });
});

describe("whatsapp: sharing one contact's number with another contact", () => {
  // Generated fixtures: nothing here (or in the code) depends on any particular name or number.
  const randomDigits = (n: number) => Array.from({ length: n }, () => Math.floor(Math.random() * 10)).join("");
  function fixture() {
    const tag = randomUUID().slice(0, 6);
    return {
      contactName: `Contact ${tag}`,
      requestedPhone: `+1${randomDigits(10)}`,
      recipientName: `Recipient ${tag}`,
      recipientPhone: `+44${randomDigits(10)}`,
    };
  }

  async function prepareShare(user: TestUser, f: ReturnType<typeof fixture>, extra: Record<string, unknown> = {}) {
    // The model even writes a message with an invented number; it must be ignored.
    const model = toolThen(
      "prepare_whatsapp",
      { recipientName: f.recipientName, shareContactNumber: f.contactName, message: "Here is the number: 0000000000", ...extra },
      "Please pick the contact and confirm.",
    );
    setChatModels({ chat: model });
    const res = await chat(user, { message: `Send ${f.contactName}'s number to ${f.recipientName}` });
    assert.equal(res.status, 200, res.raw);
    return { res, model, pending: res.json.pendingActions[0], conversationId: res.json.conversationId as string };
  }

  test("prepares a pending action that keeps the shared contact apart from the recipient", async () => {
    const f = fixture();
    const { pending, model } = await prepareShare(userA, f);
    assert.equal(pending.type, "SHARE_CONTACT");
    assert.equal(pending.channel, "WHATSAPP");
    assert.equal(pending.status, "PENDING");
    assert.equal(pending.sharedContactQuery, f.contactName);
    assert.equal(pending.contactQuery, f.recipientName);
    assert.equal(pending.sharedContactPhone, null);
    assert.equal(pending.message, null, "the model's text (and its invented number) is never used");
    // Nothing about the phone's contacts reached the model.
    assert.doesNotMatch(JSON.stringify(model.seen), /0000000000|phones|\+\d{9,}/);
    const row = await prisma.chatAction.findUniqueOrThrow({ where: { id: pending.id } });
    assert.equal(row.userId, userA.id);
    assert.ok(row.expiresAt.getTime() - row.createdAt.getTime() <= 10 * 60 * 1000 + 1000);
  });

  test("needs Contacts permission", async () => {
    await setPermission(userA, PermissionType.CONTACTS, PermissionStatus.DENIED);
    const f = fixture();
    const { res } = await prepareShare(userA, f, { recipientName: undefined, recipientPhone: f.recipientPhone });
    assert.deepEqual(res.json.pendingActions, []);
    assert.equal(res.json.toolEvents[0].permission, "CONTACTS");
  });

  test("the message carries the picked contact's number, never the recipient's", async () => {
    const f = fixture();
    const { pending, conversationId } = await prepareShare(userA, f);

    // Not confirmable until both people are picked.
    await action(userA, pending.id, "recipient", { address: f.recipientPhone, name: f.recipientName });
    const early = await action(userA, pending.id, "confirm");
    assert.equal(early.status, 409, early.raw);
    assert.equal(early.json.code, "SHARED_CONTACT_REQUIRED");

    const shared = await action(userA, pending.id, "shared-contact", {
      conversationId,
      name: f.contactName,
      phone: f.requestedPhone,
    });
    assert.equal(shared.status, 200, shared.raw);
    const view = shared.json.action;
    const expected = `Here is ${f.contactName}'s phone number: ${f.requestedPhone}`;
    assert.equal(view.message, expected);
    assert.ok(view.message.includes(f.requestedPhone));
    assert.ok(!view.message.includes(f.recipientPhone), "the recipient's number is never put in the message");
    assert.equal(view.sharedContactName, f.contactName);
    assert.equal(view.sharedContactPhone, f.requestedPhone);
    assert.equal(view.recipientAddress, f.recipientPhone, "the recipient stays the recipient");
    assert.equal(view.summary, `Send this WhatsApp message to ${f.recipientName} (${f.recipientPhone})?`);

    const confirmed = await action(userA, pending.id, "confirm", { conversationId });
    assert.equal(confirmed.status, 200, confirmed.raw);
    assert.deepEqual(confirmed.json.action.handoff, { phone: f.recipientPhone, message: expected, documentQuery: null });
    assert.equal(sentEmails.length, 0);

    const again = await action(userA, pending.id, "confirm");
    assert.equal(again.status, 409, "already confirmed");
    await action(userA, pending.id, "handoff", { result: "whatsapp_opened" });
    const row = await prisma.chatAction.findUniqueOrThrow({ where: { id: pending.id } });
    assert.equal(row.status, "COMPLETED");
    assert.equal(row.sharedContactPhone, null, "numbers are cleared once done");
    assert.equal(row.recipientAddress, null);
  });

  test("works in either order, for any names and numbers", async () => {
    for (let i = 0; i < 3; i++) {
      const f = fixture();
      const { pending } = await prepareShare(userA, f);
      await action(userA, pending.id, "shared-contact", { name: f.contactName, phone: f.requestedPhone });
      const set = await action(userA, pending.id, "recipient", { address: f.recipientPhone, name: f.recipientName });
      assert.equal(set.json.action.message, `Here is ${f.contactName}'s phone number: ${f.requestedPhone}`);
      assert.equal(set.json.action.recipientAddress, f.recipientPhone);
    }
  });

  test("the shared contact is validated, set once, and only on this kind of action", async () => {
    const f = fixture();
    const { pending } = await prepareShare(userA, f);
    assert.equal((await action(userA, pending.id, "shared-contact", { name: f.contactName, phone: "not a number" })).status, 400);
    assert.equal((await action(userA, pending.id, "shared-contact", { name: f.contactName })).status, 400);
    assert.equal(
      (await action(userA, pending.id, "shared-contact", { name: f.contactName, phone: f.requestedPhone, userId: userB.id })).status,
      400,
    );
    assert.equal((await action(userA, pending.id, "shared-contact", { name: f.contactName, phone: f.requestedPhone })).status, 200);
    const swap = await action(userA, pending.id, "shared-contact", { name: f.recipientName, phone: f.recipientPhone });
    assert.equal(swap.status, 409, swap.raw);
    assert.ok((await prisma.chatAction.findUniqueOrThrow({ where: { id: pending.id } })).message?.includes(f.requestedPhone));

    const plain = await prepareWhatsApp(userA);
    assert.equal((await action(userA, plain.pending.id, "shared-contact", { name: f.contactName, phone: f.requestedPhone })).status, 404);
  });

  test("other users, missing tokens, cancelled and expired actions are refused", async () => {
    const f = fixture();
    const { pending } = await prepareShare(userA, f);
    const anonymous = await call("POST", `/api/chat/actions/${pending.id}/shared-contact`, {
      body: { name: f.contactName, phone: f.requestedPhone },
    });
    assert.equal(anonymous.status, 401);
    assert.equal((await action(userB, pending.id, "shared-contact", { name: f.contactName, phone: f.requestedPhone })).status, 404);
    await action(userA, pending.id, "shared-contact", { name: f.contactName, phone: f.requestedPhone });
    await action(userA, pending.id, "recipient", { address: f.recipientPhone });
    assert.equal((await action(userB, pending.id, "confirm")).status, 404);

    await action(userA, pending.id, "cancel");
    assert.equal((await action(userA, pending.id, "confirm")).status, 409, "cancelled");

    const late = await prepareShare(userA, fixture());
    await action(userA, late.pending.id, "shared-contact", { name: f.contactName, phone: f.requestedPhone });
    await action(userA, late.pending.id, "recipient", { address: f.recipientPhone });
    await prisma.chatAction.update({ where: { id: late.pending.id }, data: { expiresAt: new Date(Date.now() - 1000) } });
    assert.equal((await action(userA, late.pending.id, "confirm")).status, 410, "expired");
  });

  test("production code holds no contact names or phone numbers", async () => {
    const { readdir, readFile } = await import("node:fs/promises");
    const { join } = await import("node:path");
    async function files(dir: string): Promise<string[]> {
      const out: string[] = [];
      for (const entry of await readdir(dir, { withFileTypes: true })) {
        const path = join(dir, entry.name);
        if (entry.isDirectory()) out.push(...(await files(path)));
        else if (path.endsWith(".ts")) out.push(path);
      }
      return out;
    }
    for (const file of await files(join(__dirname, "..", "src"))) {
      const source = await readFile(file, "utf8");
      // The names and numbers from the reported bug, used here only as a search fixture.
      for (const banned of [/\baunty\b/i, /\bmani\b/i, /8895346468/, /7847014067/]) {
        assert.doesNotMatch(source, banned, `${file} contains ${banned}`);
      }
      assert.doesNotMatch(source, /["'`]\+?\d{10,13}["'`]/, `${file} contains a phone-number literal`);
    }
  });
});
