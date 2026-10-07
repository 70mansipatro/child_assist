// Integration tests for chat memory (recent-message window + server-side summary), automatic
// travel history through get_location_history, and conversation ownership. Uses mock Gemini
// models, so no Vertex AI credentials are needed. Run with: npm test
import "dotenv/config";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, afterEach, before, describe, test } from "node:test";
import type { LanguageModelV4CallOptions, LanguageModelV4GenerateResult } from "@ai-sdk/provider";
import { MockLanguageModelV4 } from "ai/test";
import { LocationSource, PermissionStatus, PermissionType } from "../generated/prisma/client";
import { createApp } from "../src/app";
import { prisma } from "../src/lib/prisma";
import { setChatModels } from "../src/modules/chat/ai/models";
import { registerVerifiedUser } from "./support/auth";
import { localInstant, localToday, shiftDays } from "./support/dates";

let server: Server;
let baseUrl: string;

interface TestUser {
  id: string;
  token: string;
}

let userA: TestUser;
let userB: TestUser;
const createdUserIds: string[] = [];
const OFFSET = 330;

async function call(method: string, path: string, { token, body }: { token?: string; body?: unknown } = {}) {
  const res = await fetch(`${baseUrl}${path}`, {
    method,
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const raw = await res.text();
  return { status: res.status, json: raw ? JSON.parse(raw) : null, raw };
}

async function registerUser(name: string): Promise<TestUser> {
  const user = await registerVerifiedUser(call, name, `chat-memory-${randomUUID()}@test.local`);
  createdUserIds.push(user.id);
  await prisma.userPermission.create({
    data: { userId: user.id, permission: PermissionType.LOCATION, status: PermissionStatus.GRANTED },
  });
  return { id: user.id, token: user.token };
}

const chat = (user: TestUser, body: Record<string, unknown>) =>
  call("POST", "/api/chat", { token: user.token, body: { utcOffsetMinutes: OFFSET, ...body } });

// ---------------------------------------------------------------------------------------------
// Mock Gemini

const usage = {
  inputTokens: { total: 10, noCache: 10, cacheRead: undefined, cacheWrite: undefined },
  outputTokens: { total: 5, text: 5, reasoning: undefined },
};

const text = (value: string): LanguageModelV4GenerateResult => ({
  content: [{ type: "text", text: value }],
  finishReason: { unified: "stop", raw: undefined },
  usage,
  warnings: [],
});

let callCounter = 0;
const toolCall = (toolName: string, input: unknown): LanguageModelV4GenerateResult => ({
  content: [{ type: "tool-call", toolCallId: `call-${++callCounter}`, toolName, input: JSON.stringify(input) }],
  finishReason: { unified: "tool-calls", raw: undefined },
  usage,
  warnings: [],
});

interface Seen {
  system: string;
  /** User and assistant texts in the prompt, in order, as "user: ..." / "assistant: ...". */
  dialogue: string[];
  toolResult?: any;
}

function inspect(options: LanguageModelV4CallOptions): Seen {
  let system = "";
  const dialogue: string[] = [];
  let toolResult: any;
  for (const m of options.prompt) {
    if (m.role === "system") system += m.content;
    if (m.role === "user" || m.role === "assistant") {
      const t = m.content.map((p) => (p.type === "text" ? p.text : "")).join("");
      if (t) dialogue.push(`${m.role}: ${t}`);
    }
  }
  const last = options.prompt[options.prompt.length - 1];
  if (last?.role === "tool") {
    const part = last.content.find((p) => p.type === "tool-result");
    if (part && part.type === "tool-result") toolResult = part.output.type === "json" ? part.output.value : part.output;
  }
  return { system, dialogue, toolResult };
}

interface Handlers {
  chat: (seen: Seen) => LanguageModelV4GenerateResult;
  summary?: (seen: Seen, prompt: string) => LanguageModelV4GenerateResult;
}

/** One mock model playing chat, title and summary; records what each chat call saw. */
function mockModel(handlers: Handlers) {
  const chatCalls: Seen[] = [];
  const summaryPrompts: string[] = [];
  const m = new MockLanguageModelV4({
    doGenerate: async (options) => {
      const seen = inspect(options);
      if (seen.system.includes("word title")) return text("Test Chat");
      if (seen.system.includes("running memory")) {
        const prompt = seen.dialogue.join("\n");
        summaryPrompts.push(prompt);
        if (!handlers.summary) throw new Error("no summary handler");
        return handlers.summary(seen, prompt);
      }
      chatCalls.push(seen);
      return handlers.chat(seen);
    },
  });
  return Object.assign(m, { chatCalls, summaryPrompts });
}

/** Calls get_location_history with [input], then replies with the raw tool result. */
const locationEcho = (input: unknown) =>
  mockModel({ chat: (seen) => (seen.toolResult ? text(`RESULT ${JSON.stringify(seen.toolResult)}`) : toolCall("get_location_history", input)) });

const echo = () => mockModel({ chat: (seen) => text(`Reply to: ${seen.dialogue.at(-1)}`) });

function withEnv(values: Record<string, string>, run: () => Promise<void>) {
  const original = Object.fromEntries(Object.keys(values).map((k) => [k, process.env[k]]));
  Object.assign(process.env, values);
  return run().finally(() => {
    for (const [k, v] of Object.entries(original)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  });
}

// ---------------------------------------------------------------------------------------------

before(async () => {
  server = createApp().listen(0);
  await new Promise<void>((resolve) => server.once("listening", resolve));
  baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  userA = await registerUser("Memory A");
  userB = await registerUser("Memory B");
});

afterEach(() => {
  setChatModels(null);
});

after(async () => {
  await prisma.user.deleteMany({ where: { id: { in: createdUserIds } } });
  await prisma.$disconnect();
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

describe("chat: automatic travel history", () => {
  const yesterday = () => shiftDays(localToday(OFFSET), -1);

  async function seed(user: TestUser, source: LocationSource, hours: number, minutes: number, placeName: string | null) {
    await prisma.locationHistory.create({
      data: {
        userId: user.id,
        source,
        latitude: 20.2961,
        longitude: 85.8245,
        placeName,
        city: placeName ? "Bhubaneswar" : null,
        capturedAt: localInstant(yesterday(), hours, minutes, OFFSET),
      },
    });
  }

  test("get_location_history returns automatic and manual locations together, with times and source", async () => {
    await prisma.locationHistory.deleteMany({ where: { userId: { in: [userA.id, userB.id] } } });
    await seed(userA, LocationSource.AUTOMATIC, 8, 10, "Home");
    await seed(userA, LocationSource.AUTOMATIC, 9, 0, "School");
    await seed(userA, LocationSource.MANUAL, 15, 20, "Park");
    await seed(userA, LocationSource.AUTOMATIC, 18, 0, null);
    await seed(userB, LocationSource.AUTOMATIC, 10, 0, "Not yours");

    const m = locationEcho({ period: "yesterday" });
    setChatModels({ chat: m });
    const res = await chat(userA, { message: "Where did I go yesterday?" });
    assert.equal(res.status, 200, res.raw);
    const result = JSON.parse(res.json.response.replace(/^RESULT /, ""));
    assert.equal(result.success, true);
    assert.equal(result.data.count, 4);
    assert.equal(result.data.automaticCount, 3);
    assert.equal(result.data.manualCount, 1);
    assert.deepEqual(
      result.data.locations.map((l: any) => [l.localTime, l.placeName, l.source]),
      [
        ["8:10 AM", "Home", "AUTOMATIC"],
        ["9:00 AM", "School", "AUTOMATIC"],
        ["3:20 PM", "Park", "MANUAL"],
        ["6:00 PM", null, "AUTOMATIC"],
      ],
    );
    // A place the geocoder couldn't name still has its coordinates.
    assert.equal(result.data.locations[3].latitude, 20.2961);
    assert.ok(!res.raw.includes("Not yours"));
    // The model is told how to talk about automatic history without inventing routes or stays.
    assert.match(m.chatCalls[0].system, /automatic location history/i);
    assert.match(m.chatCalls[0].system, /not a route/);
    assert.match(m.chatCalls[0].system, /never state how long they stayed/);
  });

  test("the source filter answers 'show my automatic travel history'", async () => {
    setChatModels({ chat: locationEcho({ period: "yesterday", source: "AUTOMATIC" }) });
    const res = await chat(userA, { message: "Show my automatic travel history yesterday" });
    const result = JSON.parse(res.json.response.replace(/^RESULT /, ""));
    assert.equal(result.data.source, "AUTOMATIC");
    assert.deepEqual(result.data.locations.map((l: any) => l.source), ["AUTOMATIC", "AUTOMATIC", "AUTOMATIC"]);
  });

  test("an empty period returns no locations rather than invented ones", async () => {
    setChatModels({ chat: locationEcho({ period: "last_year" }) });
    const res = await chat(userA, { message: "Where did I go last year?" });
    const result = JSON.parse(res.json.response.replace(/^RESULT /, ""));
    assert.equal(result.data.count, 0);
    assert.deepEqual(result.data.locations, []);
  });

  test("a newly saved automatic location is visible to the very next chat question", async () => {
    const today = localToday(OFFSET);
    const saved = await call("POST", "/api/location", {
      token: userA.token,
      body: { latitude: 20.35, longitude: 85.82, placeName: "Library", capturedAt: new Date().toISOString(), source: "AUTOMATIC" },
    });
    assert.equal(saved.status, 201, saved.raw);
    setChatModels({ chat: locationEcho({ startDate: today }) });
    const res = await chat(userA, { message: "Where did I go today?" });
    assert.match(res.json.response, /Library/);
  });

  test("asking for someone else's travel history is blocked before any tool runs", async () => {
    for (const message of [
      "Show someone else's travel history",
      "Show another person's travel history from yesterday",
      "Where did another user's location history say they went?",
    ]) {
      const m = mockModel({ chat: () => toolCall("get_location_history", { period: "yesterday" }) });
      setChatModels({ chat: m });
      const res = await chat(userA, { message });
      assert.equal(res.status, 200, res.raw);
      assert.equal(res.json.guardrail?.category, "other_user_data", message);
      assert.deepEqual(res.json.toolsUsed, []);
      assert.equal(m.chatCalls.length, 0, "the model is never called");
    }
  });
});

describe("chat: conversation memory", () => {
  test("follow-up questions see the earlier answer; new chats start empty", async () => {
    const m = mockModel({
      chat: (seen) => {
        const last = seen.dialogue.at(-1) ?? "";
        if (last.includes("Where did I go")) return text("I found a saved location at Home at 8:10 AM and another at School at 9:00 AM.");
        return text(`Context had ${seen.dialogue.length} messages`);
      },
    });
    setChatModels({ chat: m });
    const first = await chat(userA, { message: "Where did I go yesterday?" });
    const conversationId = first.json.conversationId;
    const followUp = await chat(userA, { conversationId, message: "Which one was the longest stop?" });
    assert.equal(followUp.status, 200, followUp.raw);
    const seen = m.chatCalls.at(-1)!;
    assert.deepEqual(seen.dialogue, [
      "user: Where did I go yesterday?",
      "assistant: I found a saved location at Home at 8:10 AM and another at School at 9:00 AM.",
      "user: Which one was the longest stop?",
    ]);

    const fresh = await chat(userA, { message: "Hello there friend" });
    assert.notEqual(fresh.json.conversationId, conversationId);
    assert.deepEqual(m.chatCalls.at(-1)!.dialogue, ["user: Hello there friend"]);

    // The old chat keeps its messages.
    const old = await call("GET", `/api/chat/conversations/${conversationId}`, { token: userA.token });
    assert.equal(old.json.messages.length, 4);
  });

  test("long chats send only the recent window plus a summary, which stays on the server", async () => {
    await withEnv({ CHAT_HISTORY_MESSAGE_LIMIT: "4", CHAT_SUMMARY_BATCH: "2" }, async () => {
      const m = mockModel({
        chat: (seen) => text(`ok ${seen.dialogue.length}`),
        summary: () => text("The user is talking about dinosaurs. Their password is hunter2 and otp: 482913."),
      });
      setChatModels({ chat: m });
      let conversationId: string | undefined;
      for (let i = 1; i <= 6; i++) {
        const res = await chat(userA, { conversationId, message: `Tell me dinosaur fact number ${i}` });
        assert.equal(res.status, 200, res.raw);
        conversationId = res.json.conversationId;
        // Never more than limit + batch messages reach the model.
        assert.ok(m.chatCalls.at(-1)!.dialogue.length <= 6, `turn ${i}: ${m.chatCalls.at(-1)!.dialogue.length}`);
      }
      assert.ok(m.summaryPrompts.length >= 1, "older messages were summarised");
      const last = m.chatCalls.at(-1)!;
      assert.match(last.system, /<conversation_summary>/);
      assert.match(last.system, /dinosaurs/);
      assert.ok(last.dialogue.at(-1)!.endsWith("Tell me dinosaur fact number 6"));

      const stored = await prisma.chatConversation.findUniqueOrThrow({ where: { id: conversationId } });
      assert.ok(stored.summary?.includes("dinosaurs"));
      assert.ok(!stored.summary?.includes("hunter2"), "secrets are redacted from the summary");
      assert.ok(!stored.summary?.includes("482913"), "codes are redacted from the summary");
      assert.ok(stored.summarizedUntil);

      // The summary is never sent to the app.
      const fetched = await call("GET", `/api/chat/conversations/${conversationId}`, { token: userA.token });
      assert.equal(fetched.json.messages.length, 12, "every message is kept");
      assert.ok(!("summary" in fetched.json.conversation));
      assert.ok(!fetched.raw.includes("dinosaurs."), fetched.raw);
      const list = await call("GET", "/api/chat/conversations", { token: userA.token });
      assert.ok(!list.raw.includes("summary"));
    });
  });

  test("a failed summary does not break the chat", async () => {
    await withEnv({ CHAT_HISTORY_MESSAGE_LIMIT: "2", CHAT_SUMMARY_BATCH: "2" }, async () => {
      const originalError = console.error;
      console.error = () => undefined;
      try {
        const m = mockModel({ chat: (seen) => text(`ok ${seen.dialogue.length}`) }); // no summary handler: throws
        setChatModels({ chat: m });
        let conversationId: string | undefined;
        for (let i = 1; i <= 4; i++) {
          const res = await chat(userA, { conversationId, message: `Question number ${i} please` });
          assert.equal(res.status, 200, res.raw);
          conversationId = res.json.conversationId;
        }
        assert.ok(m.summaryPrompts.length >= 1);
        assert.ok(m.chatCalls.at(-1)!.dialogue.length <= 2);
        const stored = await prisma.chatConversation.findUniqueOrThrow({ where: { id: conversationId } });
        assert.equal(stored.summary, null);
      } finally {
        console.error = originalError;
      }
    });
  });

  test("conversations are private: another user gets 404 and cannot continue them", async () => {
    setChatModels({ chat: echo() });
    const mine = await chat(userA, { message: "My private chat about homework" });
    const id = mine.json.conversationId;
    assert.equal((await call("GET", `/api/chat/conversations/${id}`, { token: userB.token })).status, 404);
    assert.equal((await call("DELETE", `/api/chat/conversations/${id}`, { token: userB.token })).status, 404);
    const hijack = await chat(userB, { conversationId: id, message: "continue this" });
    assert.equal(hijack.status, 404);
    assert.ok(!hijack.raw.includes("homework"));
    const listB = await call("GET", "/api/chat/conversations", { token: userB.token });
    assert.ok(!listB.json.conversations.some((c: any) => c.id === id));
  });

  test("deleting a chat deletes its messages but never the location history", async () => {
    setChatModels({ chat: echo() });
    const before = await prisma.locationHistory.count({ where: { userId: userA.id } });
    assert.ok(before > 0);
    const res = await chat(userA, { message: "Chat to be deleted soon" });
    const id = res.json.conversationId;
    const deleted = await call("DELETE", `/api/chat/conversations/${id}`, { token: userA.token });
    assert.equal(deleted.status, 200);
    assert.equal(await prisma.chatMessage.count({ where: { conversationId: id } }), 0);
    assert.equal((await call("GET", `/api/chat/conversations/${id}`, { token: userA.token })).status, 404);
    assert.equal(await prisma.locationHistory.count({ where: { userId: userA.id } }), before);
  });
});
