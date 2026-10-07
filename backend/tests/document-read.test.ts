// Integration tests for reading one of the user's documents for the assistant: the request the
// assistant opens, the text the phone posts for the one document it read, and the answer written
// from that text only. Runs the real app against the configured PostgreSQL database with mock
// Gemini models. Every document name and text here is generated: nothing depends on fixed values.
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
import { prisma } from "../src/lib/prisma";
import { setChatModels } from "../src/modules/chat/ai/models";
import { CHUNK_CHARS, MAX_DOCUMENT_CHARS, splitIntoChunks } from "../src/modules/chat/documents/document-answer";
import { registerVerifiedUser } from "./support/auth";

let server: Server;
let baseUrl: string;

interface TestUser {
  id: string;
  token: string;
}

let userA: TestUser;
let userB: TestUser;
const createdUserIds: string[] = [];

async function call(
  method: string,
  path: string,
  { token, body, raw }: { token?: string; body?: unknown; raw?: string } = {},
): Promise<{ status: number; json: any; raw: string }> {
  const res = await fetch(`${baseUrl}${path}`, {
    method,
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: raw ?? (body === undefined ? undefined : JSON.stringify(body)),
  });
  const text = await res.text();
  let json: any = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = null;
  }
  return { status: res.status, json, raw: text };
}

async function registerUser(name: string): Promise<TestUser> {
  const user = await registerVerifiedUser(call, name, `reads-${randomUUID()}@test.local`);
  createdUserIds.push(user.id);
  return { id: user.id, token: user.token };
}

async function setPermission(user: TestUser, permission: PermissionType, status: PermissionStatus) {
  await prisma.userPermission.upsert({
    where: { userId_permission: { userId: user.id, permission } },
    create: { userId: user.id, permission, status },
    update: { status },
  });
}

const word = () => randomUUID().replace(/[^a-z]/g, "").slice(0, 8) || "word";
const docId = () => `doc_${randomUUID().replace(/-/g, "").slice(0, 16)}`;

// ---------------------------------------------------------------------------------------------
// Mock Gemini. One model serves the chat turn (which calls read_document) and the document
// answer calls, told apart by their instructions. Every prompt it receives is recorded.

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

function flatten(options: LanguageModelV4CallOptions): string {
  return options.prompt
    .map((p) =>
      typeof p.content === "string"
        ? p.content
        : p.content.map((c) => ("text" in c ? c.text : JSON.stringify(c))).join(""),
    )
    .join("\n");
}

interface Recorder {
  /** Prompts of the chat turn (the tool-calling run). */
  turns: string[];
  /** Prompts of the per-part note calls for long documents. */
  notes: string[];
  /** Prompts of the final answer calls. */
  answers: string[];
}

/**
 * A model whose chat turn calls [toolName] with [input]; answer calls reply [answer], note calls
 * reply "- a note". With [failAnswers] the answer calls throw.
 */
function scripted(toolName: string, input: unknown, answer = "Here is what the document covers.", failAnswers = false) {
  const seen: Recorder = { turns: [], notes: [], answers: [] };
  const model = new MockLanguageModelV4({
    doGenerate: async (options) => {
      const all = flatten(options);
      if (all.includes("word title")) return text("Documents");
      if (all.includes("reading one part of the user's own document")) {
        seen.notes.push(all);
        return text("- a note");
      }
      if (all.includes("chose ONE of their own documents")) {
        seen.answers.push(all);
        if (failAnswers) throw new Error(`provider exploded while reading: ${all.slice(0, 2000)}`);
        return text(answer);
      }
      seen.turns.push(all);
      const last = options.prompt[options.prompt.length - 1];
      if (last?.role === "tool") return text("Let me read that document.");
      return toolCall(toolName, input);
    },
  });
  return { model, seen };
}

async function chat(user: TestUser, message: string, conversationId?: string) {
  return call("POST", "/api/chat", { token: user.token, body: { message, ...(conversationId ? { conversationId } : {}) } });
}

/** Asks about a document; returns the read request the phone must answer. */
async function askAbout(user: TestUser, input: Record<string, unknown>, answer?: string, failAnswers = false) {
  const { model, seen } = scripted("read_document", input, answer, failAnswers);
  setChatModels({ chat: model });
  const res = await chat(user, String(input.question ?? "What is in it?"));
  assert.equal(res.status, 200, res.raw);
  const event = res.json.toolEvents.find((e: any) => e.kind === "document_text");
  assert.ok(event, res.raw);
  return { res, seen, event, requestId: event.data?.requestId as string, conversationId: res.json.conversationId as string };
}

const answerPath = (id: string) => `/api/chat/document-reads/${id}/answer`;
const failPath = (id: string) => `/api/chat/document-reads/${id}/fail`;

function documentBody(content: string, extra: Record<string, unknown> = {}) {
  return { documentId: docId(), name: `${word()} ${word()}.pdf`, type: "PDF", text: content, ...extra };
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
  for (const user of [userA, userB]) await setPermission(user, PermissionType.DOCUMENTS, PermissionStatus.GRANTED);
});

afterEach(() => setChatModels(null));

after(async () => {
  await prisma.user.deleteMany({ where: { id: { in: createdUserIds } } });
  await prisma.$disconnect();
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

// ---------------------------------------------------------------------------------------------

describe("reading: the request", () => {
  test("a content question opens a read request for the phone; the model sees no content", async () => {
    const kw = word();
    const { res, seen, event, requestId } = await askAbout(userA, { document: `${kw} notes`, question: `${kw} notes me kya hai?` });
    assert.deepEqual(event, {
      kind: "document_text",
      status: "device_lookup",
      data: { query: { text: `${kw} notes`, type: null }, requestId },
    });
    assert.equal(res.json.response, "Let me read that document.");
    assert.deepEqual(res.json.pendingActions, [], "reading never prepares a share");

    const row = await prisma.documentReadRequest.findUniqueOrThrow({ where: { id: requestId } });
    assert.equal(row.userId, userA.id);
    assert.equal(row.status, "PENDING");
    assert.equal(row.documentQuery, `${kw} notes`);
    assert.equal(row.question, `${kw} notes me kya hai?`);
    assert.ok(row.expiresAt.getTime() - Date.now() <= 10 * 60 * 1000 + 1000);

    const told = seen.turns.join("\n");
    assert.match(told, /never guess, describe or summarise its content/);
    assert.equal(await prisma.chatAction.count({ where: { userId: userA.id, conversationId: res.json.conversationId } }), 0);
  });

  test("'this document' leaves the query empty; a type is passed through", async () => {
    const { event } = await askAbout(userA, { type: "PDF", question: "Summarize it" });
    assert.deepEqual(event.data.query, { text: null, type: "PDF" });
  });

  test("without Documents permission nothing is requested", async () => {
    await setPermission(userA, PermissionType.DOCUMENTS, PermissionStatus.DENIED);
    const before = await prisma.documentReadRequest.count({ where: { userId: userA.id } });
    const { model } = scripted("read_document", { document: "notes", question: "What is in my notes?" });
    setChatModels({ chat: model });
    const res = await chat(userA, "What is in my notes?");
    assert.deepEqual(res.json.toolEvents, [{ kind: "document_text", status: "permission_required", permission: "DOCUMENTS" }]);
    assert.equal(await prisma.documentReadRequest.count({ where: { userId: userA.id } }), before);
  });

  test("tool arguments cannot carry a path, URI or user id", async () => {
    for (const input of [
      { document: "notes", path: "/sdcard/notes.pdf" },
      { document: "notes", uri: "content://x/1" },
      { document: "notes", userId: "someone" },
      { documentId: "../../etc/passwd" },
    ]) {
      const { model } = scripted("read_document", input);
      setChatModels({ chat: model });
      const res = await chat(userA, "Read my notes");
      assert.equal(res.status, 200, res.raw);
      assert.ok(!res.json.toolEvents.some((e: any) => e.status === "device_lookup"), JSON.stringify(input));
    }
  });
});

describe("reading: the answer", () => {
  test("answers from that document's text only and stores only the answer", async () => {
    const kw = word();
    const marker = `Unique ${word()} ${word()} sentence about ${kw} loops`;
    const { seen, requestId, conversationId } = await askAbout(
      userA,
      { document: `${kw} notes`, question: `What does ${kw} notes say about loops?` },
      `The notes explain ${kw} loops.`,
    );
    const body = documentBody(`Chapter 1\n${marker}\nChapter 2\nFunctions.`);
    const res = await call("POST", answerPath(requestId), { token: userA.token, body: { ...body, conversationId } });
    assert.equal(res.status, 200, res.raw);
    assert.equal(res.json.message.role, "CHAT_ASSISTANT");
    assert.equal(res.json.message.content, `The notes explain ${kw} loops.`);
    assert.equal(res.json.request.status, "COMPLETED");

    // Exactly this document's text, with the user's question, went to the model; the chat turn never saw it.
    assert.equal(seen.answers.length, 1);
    assert.match(seen.answers[0]!, new RegExp(marker));
    assert.match(seen.answers[0]!, new RegExp(`What does ${kw} notes say about loops\\?`));
    assert.ok(seen.turns.every((t) => !t.includes(marker)));

    // Nothing of the text is kept: not in the request, not in the chat history.
    const row = await prisma.documentReadRequest.findUniqueOrThrow({ where: { id: requestId } });
    assert.equal(row.question, null);
    assert.equal(row.documentId, body.documentId);
    const messages = await prisma.chatMessage.findMany({ where: { conversationId } });
    assert.ok(messages.every((m) => !m.content.includes(marker)));
    assert.ok(messages.some((m) => m.content === `The notes explain ${kw} loops.`));
  });

  test("secrets inside the document are redacted before the model sees them", async () => {
    const { seen, requestId } = await askAbout(userA, { document: "notes", question: "What is in it?" });
    const res = await call("POST", answerPath(requestId), {
      token: userA.token,
      body: documentBody("Wifi password is hunter2zz and the trip is on Monday."),
    });
    assert.equal(res.status, 200, res.raw);
    assert.doesNotMatch(seen.answers.join(""), /hunter2zz/);
  });

  test("a long document is read in parts, then answered from the notes", async () => {
    const { seen, requestId } = await askAbout(userA, { document: "book", question: "Summarize it" });
    const paragraph = `${"lorem ipsum dolor sit amet ".repeat(40)}\n\n`;
    const long = paragraph.repeat(Math.ceil((CHUNK_CHARS * 3.5) / paragraph.length));
    const res = await call("POST", answerPath(requestId), {
      token: userA.token,
      body: documentBody(long, { truncated: true }),
    });
    assert.equal(res.status, 200, res.raw);
    const parts = splitIntoChunks(long);
    assert.ok(parts.length >= 4);
    assert.equal(seen.notes.length, parts.length, "one note call per part");
    assert.ok(seen.notes.every((p) => p.length < CHUNK_CHARS + 3000), "each call carries one part only");
    assert.equal(seen.answers.length, 1);
    assert.ok(seen.answers[0]!.length < CHUNK_CHARS, "the answer is written from notes, not the whole text");
    assert.match(seen.answers[0]!, /only have its beginning/, "the model is told the text was cut");
  });

  test("text over the limit, empty text, paths, URIs and unknown fields are rejected", async () => {
    const { requestId } = await askAbout(userA, { document: "notes", question: "What is in it?" });
    const good = documentBody("Some text.");
    for (const bad of [
      { ...good, text: "x".repeat(MAX_DOCUMENT_CHARS + 1) },
      { ...good, text: "   \n " },
      { ...good, documentId: "/storage/emulated/0/Download/notes.pdf" },
      { ...good, documentId: "content://com.android.providers.downloads.documents/document/7" },
      { ...good, documentId: "https://example.com/notes.pdf" },
      { ...good, name: "../secret.pdf" },
      { ...good, type: "EXE" },
      { ...good, path: "/sdcard/notes.pdf" },
      { ...good, uri: "content://x/1" },
      { ...good, url: "https://example.com/x.pdf" },
      { ...good, userId: userB.id },
    ]) {
      const res = await call("POST", answerPath(requestId), { token: userA.token, body: bad });
      assert.equal(res.status, 400, `${JSON.stringify(bad).slice(0, 120)} -> ${res.status}`);
    }
    assert.equal((await prisma.documentReadRequest.findUniqueOrThrow({ where: { id: requestId } })).status, "PENDING");
  });

  test("a large document within the limit is accepted (beyond the app-wide body limit)", async () => {
    const { requestId } = await askAbout(userA, { document: "book", question: "What is in it?" });
    const res = await call("POST", answerPath(requestId), {
      token: userA.token,
      body: documentBody("é".repeat(MAX_DOCUMENT_CHARS - 10)),
    });
    assert.equal(res.status, 200, res.raw);
    // Every other route keeps the small limit.
    const big = await call("POST", "/api/chat", { token: userA.token, raw: JSON.stringify({ message: "x".repeat(200_000) }) });
    assert.equal(big.status, 413);
  });

  test("when no model can answer: a clear failure, nothing invented, nothing logged", async () => {
    const marker = `Private ${word()} ${word()} content`;
    const name = `${word()}-${word()}.pdf`;
    const logged: string[] = [];
    const originals = { log: console.log, info: console.info, warn: console.warn, error: console.error };
    for (const level of ["log", "info", "warn", "error"] as const) {
      console[level] = (...args: unknown[]) => {
        logged.push(args.map(String).join(" "));
      };
    }
    let res;
    let requestId: string;
    try {
      ({ requestId } = await askAbout(userA, { document: "notes", question: "What is in it?" }, undefined, true));
      res = await call("POST", answerPath(requestId), {
        token: userA.token,
        body: documentBody(marker, { name }),
      });
      await call("POST", answerPath(requestId), { token: userA.token, body: documentBody(marker, { documentId: "/sdcard/x.pdf" }) });
    } finally {
      Object.assign(console, originals);
    }
    assert.equal(res.status, 503, res.raw);
    assert.equal(res.json.code, "AI_UNAVAILABLE");
    assert.equal((await prisma.documentReadRequest.findUniqueOrThrow({ where: { id: requestId! } })).status, "FAILED");
    const all = logged.join("\n");
    assert.ok(logged.some((l) => /Document answer model failed/.test(l)), "the failure itself is logged");
    assert.doesNotMatch(all, new RegExp(marker), "document content is never logged");
    assert.doesNotMatch(all, new RegExp(name.replace(/[.]/g, "\\.")), "file names are never logged");
    assert.doesNotMatch(all, /\/sdcard|content:\/\//, "paths are never logged");
  });
});

describe("reading: failures reported by the phone", () => {
  test("each reason stores an honest message; the request closes", async () => {
    const expected: Record<string, RegExp> = {
      not_found: /couldn't find that document/,
      unavailable: /no longer available/,
      unsupported: /can't read the text of this type/,
      no_text: /couldn't find any readable text.*scanned/,
      encrypted: /password-protected/,
      unreadable: /couldn't read this document/,
      cancelled: /didn't read the document/,
    };
    for (const [reason, message] of Object.entries(expected)) {
      const { requestId } = await askAbout(userA, { document: word(), question: "What is in it?" });
      const res = await call("POST", failPath(requestId), { token: userA.token, body: { reason } });
      assert.equal(res.status, 200, res.raw);
      assert.match(res.json.message.content, message, reason);
      assert.equal(res.json.request.status, reason === "cancelled" ? "CANCELLED" : "FAILED");
      assert.equal((await prisma.documentReadRequest.findUniqueOrThrow({ where: { id: requestId } })).question, null);
    }
    const { requestId } = await askAbout(userA, { document: word(), question: "What is in it?" });
    assert.equal((await call("POST", failPath(requestId), { token: userA.token, body: { reason: "deleted" } })).status, 400);
  });
});

describe("reading: security", () => {
  test("another user can never answer, fail or learn about the request", async () => {
    const { requestId } = await askAbout(userA, { document: "notes", question: "What is in it?" });
    assert.equal((await call("POST", answerPath(requestId), { body: documentBody("x") })).status, 401);
    assert.equal((await call("POST", answerPath(requestId), { token: "nope", body: documentBody("x") })).status, 401);
    assert.equal((await call("POST", answerPath(requestId), { token: userB.token, body: documentBody("x") })).status, 404);
    assert.equal((await call("POST", failPath(requestId), { token: userB.token, body: { reason: "cancelled" } })).status, 404);
    assert.equal((await prisma.documentReadRequest.findUniqueOrThrow({ where: { id: requestId } })).status, "PENDING");
  });

  test("the request must belong to the conversation the app names", async () => {
    const { requestId } = await askAbout(userA, { document: "notes", question: "What is in it?" });
    const other = await call("POST", "/api/chat/conversations", { token: userA.token, body: {} });
    const res = await call("POST", answerPath(requestId), {
      token: userA.token,
      body: documentBody("x", { conversationId: other.json.conversation.id }),
    });
    assert.equal(res.status, 404);
  });

  test("a request is answered once, and never after it expired", async () => {
    const { requestId } = await askAbout(userA, { document: "notes", question: "What is in it?" });
    assert.equal((await call("POST", answerPath(requestId), { token: userA.token, body: documentBody("One.") })).status, 200);
    const again = await call("POST", answerPath(requestId), { token: userA.token, body: documentBody("Two.") });
    assert.equal(again.status, 409);
    assert.equal(again.json.code, "REQUEST_ALREADY_HANDLED");
    assert.equal((await call("POST", failPath(requestId), { token: userA.token, body: { reason: "cancelled" } })).status, 409);

    const late = await askAbout(userA, { document: "notes", question: "What is in it?" });
    await prisma.documentReadRequest.update({ where: { id: late.requestId }, data: { expiresAt: new Date(Date.now() - 1000) } });
    const expired = await call("POST", answerPath(late.requestId), { token: userA.token, body: documentBody("Late.") });
    assert.equal(expired.status, 410);
    assert.equal(expired.json.code, "REQUEST_EXPIRED");
    assert.equal((await prisma.documentReadRequest.findUniqueOrThrow({ where: { id: late.requestId } })).status, "EXPIRED");
  });

  test("sharing never opens a read request, and reading never prepares a share", async () => {
    const before = await prisma.documentReadRequest.count({ where: { userId: userA.id } });
    await setPermission(userA, PermissionType.CONTACTS, PermissionStatus.GRANTED);
    const { model } = scripted("prepare_whatsapp", { recipientName: `Contact ${word()}`, documentName: "notes" });
    setChatModels({ chat: model });
    const res = await chat(userA, "Send my notes on WhatsApp");
    assert.equal(res.json.pendingActions[0]?.type, "SHARE_DOCUMENT");
    assert.equal(await prisma.documentReadRequest.count({ where: { userId: userA.id } }), before);
    assert.equal(res.json.pendingActions[0]?.message, "", "no document content is put into the message");
  });
});
